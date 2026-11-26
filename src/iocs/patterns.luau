--!strict
-- Compiled regular expression patterns for Roblox backdoor IOC extraction.

local regex = require("@lune/regex")

export type PatternRule = {
	id: string,
	iocType: string,
	severity: "critical" | "high" | "medium" | "low",
	re: regex.Regex,
	captureGroup: number?,
	validator: ((value: string) -> boolean)?,
}

local Patterns = {}

local function notLoopbackIp(ip: string): boolean
	if string.sub(ip, 1, 7) == "0.0.0.0" then
		return false
	end
	return true
end

Patterns.rules = {
	{
		id = "discord_webhook",
		iocType = "webhook",
		severity = "critical",
		re = regex.new("https?://(?:ptb\\.|canary\\.)?discord(?:app)?\\.com/api(?:/v\\d+)?/webhooks/\\d+/[A-Za-z0-9._-]+"),
	},
	{
		id = "slack_webhook",
		iocType = "webhook",
		severity = "critical",
		re = regex.new("https?://hooks\\.slack\\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]+"),
	},
	{
		id = "guilded_webhook",
		iocType = "webhook",
		severity = "critical",
		re = regex.new("https?://media\\.guilded\\.gg/webhooks/[A-Za-z0-9-]+/[A-Za-z0-9._-]+"),
	},
	{
		id = "url",
		iocType = "url",
		severity = "medium",
		re = regex.new("(?:https?|wss?)://[^\\s\"'<>`()\\[\\]{}\\\\]+"),
	},
	{
		id = "ipv4",
		iocType = "ip_address",
		severity = "medium",
		re = regex.new("\\b(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)(?:\\.(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)){3}(?::\\d{1,5})?\\b"),
		validator = notLoopbackIp,
	},
	{
		id = "roblox_cookie",
		iocType = "token",
		severity = "critical",
		re = regex.new("_\\|WARNING:-DO-NOT-SHARE-THIS\\.--Sharing-this-will-allow-someone-to-log-in-as-you-and-to-steal-your-ROBUX-and-items\\.\\|_[A-Za-z0-9]+"),
	},
	{
		id = "discord_token",
		iocType = "token",
		severity = "critical",
		re = regex.new("\\b[MN][A-Za-z0-9_-]{23,28}\\.[A-Za-z0-9_-]{6}\\.[A-Za-z0-9_-]{27,}\\b"),
	},
	{
		id = "github_token",
		iocType = "token",
		severity = "critical",
		re = regex.new("\\b(?:gh[pous]_[A-Za-z0-9_]{36,}|github_pat_[A-Za-z0-9_]{22,})\\b"),
	},
	{
		id = "bearer_token",
		iocType = "token",
		severity = "high",
		re = regex.new("(?i)Bearer\\s+([A-Za-z0-9._~+/=-]{12,})"),
		captureGroup = 1,
	},
	{
		id = "auth_assignment",
		iocType = "token",
		severity = "high",
		re = regex.new("(?i)(?:auth[_-]?key|api[_-]?key|secret[_-]?key|webhook[_-]?url|token)\\s*[=:]\\s*[\"']([^\"'\\r\\n]{6,})[\"']"),
		captureGroup = 1,
	},
	{
		id = "rbxassetid_uri",
		iocType = "asset_id",
		severity = "high",
		re = regex.new("rbxassetid://(\\d{5,15})"),
		captureGroup = 1,
	},
	{
		id = "roblox_asset_url",
		iocType = "asset_id",
		severity = "high",
		re = regex.new("roblox\\.com/(?:asset/\\?id=|library/|catalog/|games/|places/|bundles/)(\\d{5,15})"),
		captureGroup = 1,
	},
	{
		id = "require_asset_id",
		iocType = "asset_id",
		severity = "high",
		re = regex.new("require\\s*\\(\\s*(\\d{5,15})\\s*\\)"),
		captureGroup = 1,
	},
	{
		id = "insert_asset_id",
		iocType = "asset_id",
		severity = "high",
		re = regex.new("LoadAsset(?:Version)?\\s*\\(\\s*(\\d{5,15})\\s*\\)"),
		captureGroup = 1,
	},
	{
		id = "marketplace_asset_id",
		iocType = "asset_id",
		severity = "medium",
		re = regex.new("GetProductInfo\\s*\\(\\s*(\\d{5,15})"),
		captureGroup = 1,
	},
	{
		id = "teleport_place_id",
		iocType = "place_id",
		severity = "high",
		re = regex.new("Teleport(?:Async|ToPlaceInstance|PartyAsync|ToPrivateServer)?\\s*\\(\\s*(\\d{5,15})"),
		captureGroup = 1,
	},
	{
		id = "roblox_user_url",
		iocType = "user_id",
		severity = "medium",
		re = regex.new("roblox\\.com/users/(\\d{4,15})"),
		captureGroup = 1,
	},
	{
		id = "roblox_group_url",
		iocType = "group_id",
		severity = "medium",
		re = regex.new("roblox\\.com/(?:groups|communities)/(\\d{4,15})"),
		captureGroup = 1,
	},
	{
		id = "group_check_id",
		iocType = "group_id",
		severity = "medium",
		re = regex.new("(?:GetRankInGroup|IsInGroup|GetRoleInGroup|GetGroupInfoAsync)\\s*\\(\\s*(\\d{4,15})"),
		captureGroup = 1,
	},
	{
		id = "user_id_assignment",
		iocType = "user_id",
		severity = "low",
		re = regex.new("(?i)\\b(?:UserId|CreatorId|TargetUserId)\\s*[=:]\\s*(\\d{4,15})"),
		captureGroup = 1,
	},
	{
		id = "group_id_assignment",
		iocType = "group_id",
		severity = "low",
		re = regex.new("(?i)\\bGroupId\\s*[=:]\\s*(\\d{4,15})"),
		captureGroup = 1,
	},
} :: { PatternRule }

function Patterns.findAll(rule: PatternRule, text: string): { string }
	local matches: { string } = {}
	if #text == 0 then
		return matches
	end

	local offset = 1
	local len = #text
	local guard = 0

	while offset <= len and guard < 2000 do
		guard += 1
		local slice = string.sub(text, offset)
		local caps = rule.re:captures(slice)
		if not caps then
			break
		end

		local full = caps:get(0)
		if not full then
			break
		end

		local targetMatch = if rule.captureGroup then caps:get(rule.captureGroup) else full
		if targetMatch and #targetMatch.text > 0 then
			local value = targetMatch.text
			if not rule.validator or rule.validator(value) then
				table.insert(matches, value)
			end
		end

		local advance = math.max(full.finish, 1)
		offset += advance
	end

	return matches
end

return Patterns
