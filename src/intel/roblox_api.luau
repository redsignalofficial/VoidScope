--!strict
-- Roblox asset intelligence lookup: asset ID -> creator -> username / group details.
-- This is the ONLY module in VoidScope permitted to make external network requests,
-- and only when explicitly enabled via options.enabled = true.

local net = require("@lune/net")
local serde = require("@lune/serde")

local RobloxApi = {}

export type FetcherFn = (url: string) -> {
	ok: boolean,
	statusCode: number,
	body: string,
}

export type CreatorIntel = {
	creatorType: string,
	creatorId: number,
	name: string?,
	username: string?,
	displayName: string?,
	isBanned: boolean?,
	groupOwnerId: number?,
	groupOwnerName: string?,
	memberCount: number?,
	profileUrl: string,
}

export type AssetIntel = {
	assetId: number,
	ok: boolean,
	error: string?,
	name: string?,
	description: string?,
	assetTypeId: number?,
	created: string?,
	updated: string?,
	assetUrl: string,
	creator: CreatorIntel?,
}

export type IntelReport = {
	enabled: boolean,
	queriedCount: number,
	assets: { AssetIntel },
	warnings: { string },
}

export type IntelOptions = {
	enabled: boolean?,
	maxLookups: number?,
	fetcher: FetcherFn?,
}

local DEFAULT_MAX_LOOKUPS = 20

local function defaultFetcher(url: string)
	local ok, res = pcall(net.request, {
		url = url,
		method = "GET",
		headers = {
			["Accept"] = "application/json",
			["User-Agent"] = "VoidScope-Analyzer/1.0",
		},
	})
	if not ok or not res then
		return {
			ok = false,
			statusCode = 0,
			body = tostring(res),
		}
	end
	return {
		ok = res.ok,
		statusCode = res.statusCode,
		body = res.body,
	}
end

local function fetchJson(fetcher: FetcherFn, url: string): (boolean, any, string?)
	local res = fetcher(url)
	if not res.ok then
		return false, nil, string.format("HTTP %d from %s", res.statusCode, url)
	end
	local ok, decoded = pcall(serde.decode, "json", res.body)
	if not ok then
		return false, nil, "JSON decode failed: " .. tostring(decoded)
	end
	return true, decoded, nil
end

function RobloxApi.enrichAssets(assetIds: { number }, options: IntelOptions?): IntelReport
	local opts = options or {}
	if not opts.enabled then
		return {
			enabled = false,
			queriedCount = 0,
			assets = {},
			warnings = { "External Roblox API lookup disabled (pass --intel to query creator details)." },
		}
	end

	local fetcher = opts.fetcher or defaultFetcher
	local maxLookups = opts.maxLookups or DEFAULT_MAX_LOOKUPS

	local userCache: { [number]: any } = {}
	local groupCache: { [number]: any } = {}
	local assets: { AssetIntel } = {}
	local warnings: { string } = {}
	local seenAssets: { [number]: boolean } = {}

	local function resolveCreator(rawCreator: any): CreatorIntel?
		if type(rawCreator) ~= "table" then
			return nil
		end
		local creatorType = tostring(rawCreator.CreatorType or "User")
		local targetId = tonumber(rawCreator.CreatorTargetId or rawCreator.Id) or 0
		local baseName = if rawCreator.Name then tostring(rawCreator.Name) else nil

		if creatorType == "Group" and targetId > 0 then
			local groupData = groupCache[targetId]
			if groupData == nil then
				local ok, data, err = fetchJson(fetcher, string.format("https://groups.roblox.com/v1/groups/%d", targetId))
				if ok and type(data) == "table" then
					groupData = data
					groupCache[targetId] = data
				elseif err then
					table.insert(warnings, err)
					groupCache[targetId] = false
				end
			end
			local owner = if type(groupData) == "table" and type(groupData.owner) == "table" then groupData.owner else nil
			return {
				creatorType = "Group",
				creatorId = targetId,
				name = if type(groupData) == "table" and groupData.name then tostring(groupData.name) else baseName,
				groupOwnerId = if owner and owner.userId then tonumber(owner.userId) else nil,
				groupOwnerName = if owner and owner.username then tostring(owner.username) else nil,
				memberCount = if type(groupData) == "table" and groupData.memberCount then tonumber(groupData.memberCount) else nil,
				profileUrl = string.format("https://www.roblox.com/communities/%d", targetId),
			}
		elseif targetId > 0 then
			local userData = userCache[targetId]
			if userData == nil then
				local ok, data, err = fetchJson(fetcher, string.format("https://users.roblox.com/v1/users/%d", targetId))
				if ok and type(data) == "table" then
					userData = data
					userCache[targetId] = data
				elseif err then
					table.insert(warnings, err)
					userCache[targetId] = false
				end
			end
			return {
				creatorType = "User",
				creatorId = targetId,
				name = baseName,
				username = if type(userData) == "table" and userData.name then tostring(userData.name) else baseName,
				displayName = if type(userData) == "table" and userData.displayName then tostring(userData.displayName) else nil,
				isBanned = if type(userData) == "table" then userData.isBanned == true else nil,
				profileUrl = string.format("https://www.roblox.com/users/%d/profile", targetId),
			}
		end

		return nil
	end

	for _, assetId in assetIds do
		if seenAssets[assetId] then
			continue
		end
		seenAssets[assetId] = true

		if #assets >= maxLookups then
			table.insert(warnings, string.format("Lookup cap reached (%d assets)", maxLookups))
			break
		end

		local assetUrl = string.format("https://www.roblox.com/library/%d", assetId)
		local detailsUrl = string.format("https://economy.roblox.com/v2/assets/%d/details", assetId)
		local ok, data, err = fetchJson(fetcher, detailsUrl)

		if ok and type(data) == "table" then
			table.insert(assets, {
				assetId = assetId,
				ok = true,
				name = if data.Name then tostring(data.Name) else nil,
				description = if data.Description then tostring(data.Description) else nil,
				assetTypeId = tonumber(data.AssetTypeId),
				created = if data.Created then tostring(data.Created) else nil,
				updated = if data.Updated then tostring(data.Updated) else nil,
				assetUrl = assetUrl,
				creator = resolveCreator(data.Creator),
			})
		else
			table.insert(assets, {
				assetId = assetId,
				ok = false,
				error = err or "Unknown lookup error",
				assetUrl = assetUrl,
			})
		end
	end

	return {
		enabled = true,
		queriedCount = #assets,
		assets = assets,
		warnings = warnings,
	}
end

return RobloxApi
