--!strict
-- Writes structured JSON IOC output (out/iocs.json) and abuse-report-ready
-- Markdown evidence report (out/report.md).

local DateTime = require("@lune/datetime")
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Report = {}

export type ReportInput = {
	sampleName: string,
	samplePath: string,
	sampleSha256: string,
	timedOut: boolean,
	workerOk: boolean,
	workerCode: number?,
	workerMeta: { [string]: any }?,
	logData: { [string]: any },
	iocs: { [string]: any },
	c2Fingerprint: { [string]: any },
	intelReport: { [string]: any }?,
	layers: { { [string]: any } },
	c2StubRequests: { any }?,
}

local function escapeMd(text: any): string
	local s = tostring(text or "")
	s = string.gsub(s, "|", "\\|")
	s = string.gsub(s, "[\r\n]+", " ")
	return s
end

local function computeRiskAssessment(input: ReportInput): (string, { string })
	local reasons: { string } = {}
	local score = 0

	local iocs = input.iocs
	local webhooks = iocs.webhooks or {}
	local tokens = iocs.tokens or {}
	local assetIds = iocs.assetIds or {}
	local placeIds = iocs.placeIds or {}
	local urls = iocs.urls or {}
	local c2 = input.c2Fingerprint
	local entries = input.logData.entries or {}

	if #webhooks > 0 then
		score += 40
		table.insert(reasons, string.format("Webhook exfiltration endpoint(s) detected (%d)", #webhooks))
	end
	if #tokens > 0 then
		score += 35
		table.insert(reasons, string.format("Embedded token/secret/auth key indicator(s) (%d)", #tokens))
	end
	if #input.layers > 0 then
		score += 20
		table.insert(reasons, string.format("Dynamic loadstring deobfuscation chain (%d layer(s))", #input.layers))
	end
	if #assetIds > 0 then
		score += 25
		table.insert(reasons, string.format("External Roblox asset/module loading (%d asset ID(s))", #assetIds))
	end
	if #placeIds > 0 then
		score += 20
		table.insert(reasons, string.format("TeleportService redirection target(s) (%d place ID(s))", #placeIds))
	end
	if c2.beaconingDetected then
		score += 30
		table.insert(reasons, "C2 beaconing pattern: " .. tostring(c2.beaconingReason or "repeated HTTP polling"))
	elseif (c2.requestCount or 0) > 0 or #urls > 0 then
		score += 15
		table.insert(reasons, string.format("External HTTP communication / URLs (%d URL(s), %d request(s))", #urls, c2.requestCount or 0))
	end

	local sawSourceWrite = false
	local sawEscapeProbe = false
	for _, entry in entries do
		if entry.category == "script" and entry.action == "source_write" then
			sawSourceWrite = true
		elseif entry.category == "sandbox" and (entry.action == "getfenv_stack_probe" or entry.action == "getmetatable_string_probe" or entry.action == "setfenv_blocked_level0") then
			sawEscapeProbe = true
		end
	end

	if sawSourceWrite then
		score += 30
		table.insert(reasons, "Runtime Script.Source modification (persistence / infection behavior)")
	end
	if sawEscapeProbe then
		score += 15
		table.insert(reasons, "Environment / anti-tamper probing (getfenv / metatable inspection)")
	end
	if input.timedOut then
		score += 10
		table.insert(reasons, "Worker process hit execution timeout (possible infinite loop / stall)")
	end

	local verdict = "LOW"
	if score >= 70 then
		verdict = "CRITICAL"
	elseif score >= 45 then
		verdict = "HIGH"
	elseif score >= 20 then
		verdict = "MEDIUM"
	end

	if #reasons == 0 then
		table.insert(reasons, "No high-risk backdoor indicators triggered during sandbox execution.")
	end

	return verdict, reasons
end

function Report.generateMarkdown(input: ReportInput): string
	local verdict, reasons = computeRiskAssessment(input)
	local meta = input.workerMeta or {}
	local entries = input.logData.entries or {}
	local iocs = input.iocs
	local c2 = input.c2Fingerprint
	local lines: { string } = {}

	local function add(line: string)
		table.insert(lines, line)
	end

	add("# VoidScope Analysis Report: `" .. escapeMd(input.sampleName) .. "`")
	add("")
	add(string.format("- **Generated:** %s", DateTime.now():toRfc3339()))
	add(string.format("- **Sample Path:** `%s`", input.samplePath))
	add(string.format("- **Sample SHA-256:** `%s`", input.sampleSha256))
	add(string.format("- **Verdict:** **%s**", verdict))
	add(string.format(
		"- **Execution:** `%s` (timedOut=%s, exitCode=%s, duration=%.1fms)",
		tostring(meta.status or (if input.timedOut then "timeout" else "unknown")),
		tostring(input.timedOut),
		tostring(input.workerCode or "nil"),
		tonumber(meta.durationMs) or 0
	))
	add(string.format(
		"- **Telemetry:** %d log event(s), %d dumped layer(s), %d unique IOC(s)",
		#entries,
		#input.layers,
		iocs.totalUnique or 0
	))
	add("")

	add("## Risk Assessment")
	add("")
	for _, r in reasons do
		add("- " .. r)
	end
	add("")

	add("## Indicators of Compromise (IOCs)")
	add("")
	local iocList = iocs.iocs or {}
	if #iocList == 0 then
		add("_No indicators extracted._")
	else
		add("| Severity | Type | Value | Count | Sources |")
		add("| :--- | :--- | :--- | ---: | :--- |")
		for _, item in iocList do
			local srcs = table.concat(item.sources or {}, ", ")
			if #srcs > 80 then
				srcs = string.sub(srcs, 1, 77) .. "..."
			end
			add(string.format(
				"| `%s` | `%s` | `%s` | %d | %s |",
				escapeMd(item.severity),
				escapeMd(item.type),
				escapeMd(item.value),
				item.count or 1,
				escapeMd(srcs)
			))
		end
	end
	add("")

	add("## Roblox Asset Attribution (Abuse Report Evidence)")
	add("")
	local intel = input.intelReport
	if not intel or not intel.enabled then
		add("_External Roblox API lookup was disabled for this run (run with `--intel` to resolve asset IDs to creators/groups)._")
	elseif #(intel.assets or {}) == 0 then
		add("_No Roblox Asset IDs were found to enrich._")
	else
		add("| Asset ID | Name | Creator Type | Creator / Username | Group Owner | Links | Status |")
		add("| ---: | :--- | :--- | :--- | :--- | :--- | :--- |")
		for _, asset in intel.assets do
			if asset.ok and asset.creator then
				local cr = asset.creator
				local creatorDisplay = cr.username or cr.name or tostring(cr.creatorId)
				local ownerStr = if cr.groupOwnerName
					then string.format("%s (%s)", cr.groupOwnerName, tostring(cr.groupOwnerId or ""))
					else "-"
				local status = if cr.isBanned then "BANNED" else "Active"
				add(string.format(
					"| `%d` | %s | `%s` | `%s` (`%d`) | %s | [Asset](%s) · [Creator](%s) | %s |",
					asset.assetId,
					escapeMd(asset.name or "-"),
					escapeMd(cr.creatorType),
					escapeMd(creatorDisplay),
					cr.creatorId,
					escapeMd(ownerStr),
					asset.assetUrl,
					cr.profileUrl,
					status
				))
			else
				add(string.format(
					"| `%d` | - | - | - | - | [Asset](%s) | Lookup failed: %s |",
					asset.assetId,
					asset.assetUrl,
					escapeMd(asset.error or "error")
				))
			end
		end
	end
	add("")

	add("## C2 Behavioral Fingerprint")
	add("")
	if (c2.requestCount or 0) == 0 then
		add("_No HTTP/C2 requests captured._")
	else
		add(string.format("- **Total HTTP Requests:** %d", c2.requestCount))
		add(string.format("- **Beaconing Detected:** %s%s", tostring(c2.beaconingDetected), if c2.beaconingReason then " (" .. c2.beaconingReason .. ")" else ""))
		if c2.estimatedPollIntervalSeconds then
			add(string.format("- **Estimated Poll Interval:** `%.2fs`", c2.estimatedPollIntervalSeconds))
		end
		if #(c2.userAgents or {}) > 0 then
			add("- **User-Agent(s):** `" .. table.concat(c2.userAgents, "`, `") .. "`")
		end
		if #(c2.headerKeys or {}) > 0 then
			add("- **Header Names:** `" .. table.concat(c2.headerKeys, "`, `") .. "`")
		end
		if #(c2.authKeys or {}) > 0 then
			add("- **Auth Keys / Tokens Observed:** `" .. table.concat(c2.authKeys, "`, `") .. "`")
		end
		add("")
		if #(c2.endpoints or {}) > 0 then
			add("| Endpoint URL | Methods | Hits |")
			add("| :--- | :--- | ---: |")
			for _, ep in c2.endpoints do
				add(string.format(
					"| `%s` | `%s` | %d |",
					escapeMd(ep.url),
					escapeMd(table.concat(ep.methods or {}, ", ")),
					ep.count or 1
				))
			end
		end
		if #(c2.sampleBodies or {}) > 0 then
			add("")
			add("### Sample HTTP Request Bodies")
			for i, body in c2.sampleBodies do
				add(string.format("%d. `%s`", i, escapeMd(body)))
			end
		end
	end
	add("")

	if input.c2StubRequests and #input.c2StubRequests > 0 then
		add("### Local C2 Stub Server Captures")
		add("")
		add(string.format("Captured %d request(s) on local loopback C2 stub server.", #input.c2StubRequests))
		add("")
	end

	add("## Deobfuscation Layers")
	add("")
	if #input.layers == 0 then
		add("_No dynamic `loadstring` layers captured._")
	else
		add("| Layer | Depth | Bytes | SHA-256 | File |")
		add("| ---: | ---: | ---: | :--- | :--- |")
		for _, layer in input.layers do
			add(string.format(
				"| `%s` | %d | %d | `%s` | `%s` |",
				tostring(layer.id or "?"),
				tonumber(layer.depth) or 1,
				tonumber(layer.bytes) or 0,
				escapeMd(layer.sha256 or ""),
				escapeMd(layer.filePath or "")
			))
		end
	end
	add("")

	add("## High-Priority Event Timeline")
	add("")
	local notableCategories: { [string]: boolean } = {
		loadstring = true,
		http = true,
		insert = true,
		messaging = true,
		teleport = true,
		marketplace = true,
		datastore = true,
		script = true,
		remote = true,
		player = true,
		group = true,
		limit = true,
		sandbox = true,
		strings = true,
	}
	local shown = 0
	for _, entry in entries do
		if notableCategories[entry.category] then
			if shown == 0 then
				add("| # | Time (ms) | Layer | Category | Action | Summary |")
				add("| ---: | ---: | ---: | :--- | :--- | :--- |")
			end
			shown += 1
			if shown > 60 then
				add("| ... | ... | ... | ... | ... | _(truncated, see logs.json)_ |")
				break
			end
			local ok, detailJson = pcall(serde.encode, "json", entry.detail or {}, false)
			local summary = if ok then detailJson else "{}"
			if #summary > 140 then
				summary = string.sub(summary, 1, 137) .. "..."
			end
			add(string.format(
				"| %d | %.2f | %d | `%s` | `%s` | `%s` |",
				tonumber(entry.seq) or shown,
				tonumber(entry.timestampMs) or 0,
				tonumber(entry.layer) or 0,
				escapeMd(entry.category),
				escapeMd(entry.action),
				escapeMd(summary)
			))
		end
	end
	if shown == 0 then
		add("_No notable events recorded._")
	end
	add("")

	return table.concat(lines, "\n")
end

function Report.writeOutputs(outDir: string, input: ReportInput): { iocsPath: string, reportPath: string, verdict: string }
	if not fs.isDir(outDir) then
		fs.writeDir(outDir)
	end

	local iocsPath = outDir .. "/iocs.json"
	local reportPath = outDir .. "/report.md"

	local iocsPayload = {
		sample = input.sampleName,
		sampleSha256 = input.sampleSha256,
		generatedAt = DateTime.now():toRfc3339(),
		totalUnique = input.iocs.totalUnique,
		bySeverity = input.iocs.bySeverity,
		byType = input.iocs.byType,
		iocs = input.iocs.iocs,
		c2Fingerprint = input.c2Fingerprint,
		intel = input.intelReport,
	}

	fs.writeFile(iocsPath, serde.encode("json", iocsPayload, true))
	local md = Report.generateMarkdown(input)
	fs.writeFile(reportPath, md)

	local verdict = computeRiskAssessment(input)
	return {
		iocsPath = iocsPath,
		reportPath = reportPath,
		verdict = verdict,
	}
end

return Report
