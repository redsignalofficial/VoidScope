--!strict
-- Scans dumped loadstring layers, original sample source, and execution logs
-- to extract, deduplicate, and classify Indicators of Compromise (IOCs).

local fs = require("@lune/fs")
local Patterns = require("./patterns")

local Extract = {}

export type IocEntry = {
	type: string,
	value: string,
	severity: "critical" | "high" | "medium" | "low",
	ruleIds: { string },
	count: number,
	sources: { string },
}

export type ExtractResult = {
	totalUnique: number,
	bySeverity: { [string]: number },
	byType: { [string]: number },
	iocs: { IocEntry },
	webhooks: { string },
	urls: { string },
	assetIds: { number },
	placeIds: { number },
	userIds: { number },
	groupIds: { number },
	tokens: { string },
}

local SEVERITY_RANK: { [string]: number } = {
	critical = 4,
	high = 3,
	medium = 2,
	low = 1,
}

local function addUniqueString(list: { string }, item: string, maxItems: number?)
	for _, existing in list do
		if existing == item then
			return
		end
	end
	if not maxItems or #list < maxItems then
		table.insert(list, item)
	end
end

local function isWebhookUrl(url: string): boolean
	for _, rule in Patterns.rules do
		if rule.iocType == "webhook" and rule.re:isMatch(url) then
			return true
		end
	end
	return false
end

local function collectDetailStrings(value: any, out: { string }, depth: number)
	if depth > 4 then
		return
	end
	local t = type(value)
	if t == "string" then
		if #value > 0 then
			table.insert(out, value)
		end
	elseif t == "table" then
		for k, v in value do
			if type(k) == "string" and #k > 0 then
				table.insert(out, k)
			end
			collectDetailStrings(v, out, depth + 1)
		end
	end
end

function Extract.extract(input: {
	sampleSource: string?,
	sampleName: string?,
	layers: { { id: number?, filePath: string, content: string? } }?,
	layersDir: string?,
	logEntries: { any }?,
}): ExtractResult
	local map: { [string]: IocEntry } = {}

	local function recordIoc(iocType: string, value: string, severity: "critical" | "high" | "medium" | "low", ruleId: string, source: string)
		local trimmed = string.gsub(value, "^%s*(.-)%s*$", "%1")
		if #trimmed == 0 then
			return
		end
		-- Trim trailing punctuation often caught after URLs in strings
		if iocType == "url" or iocType == "webhook" then
			trimmed = string.gsub(trimmed, "[.,;]+$", "")
		end

		local key = iocType .. "::" .. trimmed
		local existing = map[key]
		if existing then
			existing.count += 1
			if SEVERITY_RANK[severity] > SEVERITY_RANK[existing.severity] then
				existing.severity = severity
			end
			addUniqueString(existing.ruleIds, ruleId, 16)
			addUniqueString(existing.sources, source, 24)
		else
			map[key] = {
				type = iocType,
				value = trimmed,
				severity = severity,
				ruleIds = { ruleId },
				count = 1,
				sources = { source },
			}
		end
	end

	local function scanText(text: string, sourceLabel: string)
		if #text == 0 then
			return
		end
		for _, rule in Patterns.rules do
			local hits = Patterns.findAll(rule, text)
			for _, hit in hits do
				-- Avoid duplicating a webhook URL as both "webhook" and generic "url"
				if rule.iocType == "url" and isWebhookUrl(hit) then
					continue
				end
				recordIoc(rule.iocType, hit, rule.severity, rule.id, sourceLabel)
			end
		end
	end

	-- 1. Scan original sample source
	if input.sampleSource and #input.sampleSource > 0 then
		scanText(input.sampleSource, "sample:" .. (input.sampleName or "input"))
	end

	-- 2. Scan dumped layers (explicit list or directory scan)
	local scannedFiles: { [string]: boolean } = {}
	if input.layers then
		for _, layer in input.layers do
			local label = "layer:" .. (layer.filePath or tostring(layer.id or "?"))
			local content = layer.content
			if not content and layer.filePath and fs.isFile(layer.filePath) then
				content = fs.readFile(layer.filePath)
			end
			if content then
				scannedFiles[layer.filePath] = true
				scanText(content, label)
			end
		end
	end

	if input.layersDir and fs.isDir(input.layersDir) then
		local entries = fs.readDir(input.layersDir)
		table.sort(entries)
		for _, entry in entries do
			local fullPath = input.layersDir .. "/" .. entry
			if not scannedFiles[fullPath] and fs.isFile(fullPath) then
				scanText(fs.readFile(fullPath), "layer:" .. entry)
			end
		end
	end

	-- 3. Scan structured execution logs
	if input.logEntries then
		for _, entry in input.logEntries do
			local seq = tostring(entry.seq or "?")
			local cat = tostring(entry.category or "")
			local act = tostring(entry.action or "")
			local detail = entry.detail or {}
			local srcLabel = string.format("log#%s(%s.%s)", seq, cat, act)

			if cat == "http" and type(detail.url) == "string" then
				local iocType = if isWebhookUrl(detail.url) then "webhook" else "url"
				local sev: "critical" | "high" = if iocType == "webhook" then "critical" else "high"
				recordIoc(iocType, detail.url, sev, "runtime_http", srcLabel)
			elseif cat == "insert" and detail.assetId ~= nil then
				recordIoc("asset_id", tostring(detail.assetId), "high", "runtime_" .. act, srcLabel)
			elseif cat == "marketplace" then
				if detail.assetId ~= nil then
					recordIoc("asset_id", tostring(detail.assetId), "medium", "runtime_" .. act, srcLabel)
				end
				if detail.productId ~= nil then
					recordIoc("asset_id", tostring(detail.productId), "medium", "runtime_" .. act, srcLabel)
				end
			elseif cat == "teleport" and detail.placeId ~= nil then
				recordIoc("place_id", tostring(detail.placeId), "high", "runtime_" .. act, srcLabel)
			elseif (cat == "player" or cat == "group") and detail.groupId ~= nil then
				recordIoc("group_id", tostring(detail.groupId), "medium", "runtime_" .. act, srcLabel)
			elseif (cat == "players" or cat == "group") and detail.userId ~= nil then
				recordIoc("user_id", tostring(detail.userId), "medium", "runtime_" .. act, srcLabel)
			elseif cat == "script" and act == "source_write" then
				recordIoc("persistence", "Script.Source modified", "critical", "runtime_source_write", srcLabel)
			end

			-- Scan any string fields inside detail (handles decoded strings, headers, POST bodies, script writes)
			local strings: { string } = {}
			collectDetailStrings(detail, strings, 0)
			for _, s in strings do
				scanText(s, srcLabel)
			end
		end
	end

	local iocs: { IocEntry } = {}
	local bySeverity: { [string]: number } = { critical = 0, high = 0, medium = 0, low = 0 }
	local byType: { [string]: number } = {}

	local webhooks: { string } = {}
	local urls: { string } = {}
	local assetIdsMap: { [number]: boolean } = {}
	local placeIdsMap: { [number]: boolean } = {}
	local userIdsMap: { [number]: boolean } = {}
	local groupIdsMap: { [number]: boolean } = {}
	local tokens: { string } = {}

	for _, item in map do
		table.insert(iocs, item)
		bySeverity[item.severity] = (bySeverity[item.severity] or 0) + 1
		byType[item.type] = (byType[item.type] or 0) + 1

		if item.type == "webhook" then
			table.insert(webhooks, item.value)
		elseif item.type == "url" then
			table.insert(urls, item.value)
		elseif item.type == "token" then
			table.insert(tokens, item.value)
		elseif item.type == "asset_id" then
			local n = tonumber(item.value)
			if n then
				assetIdsMap[n] = true
			end
		elseif item.type == "place_id" then
			local n = tonumber(item.value)
			if n then
				placeIdsMap[n] = true
			end
		elseif item.type == "user_id" then
			local n = tonumber(item.value)
			if n then
				userIdsMap[n] = true
			end
		elseif item.type == "group_id" then
			local n = tonumber(item.value)
			if n then
				groupIdsMap[n] = true
			end
		end
	end

	table.sort(iocs, function(a, b)
		local rankA = SEVERITY_RANK[a.severity] or 0
		local rankB = SEVERITY_RANK[b.severity] or 0
		if rankA ~= rankB then
			return rankA > rankB
		end
		if a.type ~= b.type then
			return a.type < b.type
		end
		return a.value < b.value
	end)

	local function sortedNumbers(numSet: { [number]: boolean }): { number }
		local out = {}
		for n in numSet do
			table.insert(out, n)
		end
		table.sort(out)
		return out
	end

	table.sort(webhooks)
	table.sort(urls)
	table.sort(tokens)

	return {
		totalUnique = #iocs,
		bySeverity = bySeverity,
		byType = byType,
		iocs = iocs,
		webhooks = webhooks,
		urls = urls,
		assetIds = sortedNumbers(assetIdsMap),
		placeIds = sortedNumbers(placeIdsMap),
		userIds = sortedNumbers(userIdsMap),
		groupIds = sortedNumbers(groupIdsMap),
		tokens = tokens,
	}
end

return Extract
