--!strict
-- Extracts C2 behavioral fingerprints from HTTP logs and task wait timings:
-- User-Agent, auth headers, endpoint paths, poll intervals, and auth keys.

local serde = require("@lune/serde")

local Fingerprint = {}

export type EndpointSummary = {
	url: string,
	host: string,
	path: string,
	methods: { string },
	count: number,
}

export type C2Fingerprint = {
	requestCount: number,
	methods: { [string]: number },
	userAgents: { string },
	headerKeys: { string },
	authHeaders: { [string]: { string } },
	authKeys: { string },
	endpoints: { EndpointSummary },
	pollIntervalsSeconds: { number },
	estimatedPollIntervalSeconds: number?,
	observedDeltasMs: { number },
	beaconingDetected: boolean,
	beaconingReason: string?,
	sampleBodies: { string },
}

local AUTH_HEADER_NAMES: { [string]: boolean } = {
	authorization = true,
	["x-api-key"] = true,
	["x-auth-key"] = true,
	["x-auth-token"] = true,
	["x-access-token"] = true,
	["x-token"] = true,
	["api-key"] = true,
	["auth-key"] = true,
	token = true,
	secret = true,
	cookie = true,
}

local AUTH_PARAM_NAMES: { [string]: boolean } = {
	key = true,
	apikey = true,
	api_key = true,
	auth = true,
	authkey = true,
	auth_key = true,
	token = true,
	secret = true,
	password = true,
	pass = true,
}

local function addUnique(list: { string }, value: string)
	for _, existing in list do
		if existing == value then
			return
		end
	end
	table.insert(list, value)
end

local function parseUrlParts(url: string): (string, string, string?)
	local host = string.match(url, "^https?://([^/?#]+)") or "unknown"
	local afterHost = string.gsub(url, "^https?://[^/?#]+", "")
	if afterHost == "" or afterHost == url then
		return host, "/", nil
	end
	local path, query = string.match(afterHost, "^([^?]+)%?(.*)$")
	if path then
		return host, path, query
	end
	return host, afterHost, nil
end

local function extractQueryAuthKeys(query: string?, out: { string })
	if not query or #query == 0 then
		return
	end
	for pair in string.gmatch(query, "[^&]+") do
		local k, v = string.match(pair, "^([^=]+)=?(.*)$")
		if k and v and #v > 0 and AUTH_PARAM_NAMES[string.lower(k)] then
			addUnique(out, k .. "=" .. v)
		end
	end
end

local function extractBodyAuthKeys(body: string, out: { string })
	if #body == 0 then
		return
	end
	local ok, decoded = pcall(serde.decode, "json", body)
	if ok and type(decoded) == "table" then
		for k, v in decoded do
			if type(k) == "string" and AUTH_PARAM_NAMES[string.lower(k)] and (type(v) == "string" or type(v) == "number") then
				addUnique(out, k .. "=" .. tostring(v))
			end
		end
	end
end

function Fingerprint.analyze(logEntries: { any }): C2Fingerprint
	local requestCount = 0
	local methods: { [string]: number } = {}
	local userAgents: { string } = {}
	local headerKeys: { string } = {}
	local authHeaders: { [string]: { string } } = {}
	local authKeys: { string } = {}
	local endpointMap: { [string]: EndpointSummary } = {}
	local endpointTimestamps: { [string]: { number } } = {}
	local observedDeltasMs: { number } = {}
	local pollIntervalsSeconds: { number } = {}
	local sampleBodies: { string } = {}

	local pendingWaitDuration: number? = nil
	local sawHttp = false

	for _, entry in logEntries do
		local cat = tostring(entry.category or "")
		local act = tostring(entry.action or "")
		local detail = entry.detail or {}

		if cat == "task" and act == "wait" and type(detail.requestedSeconds) == "number" then
			if sawHttp then
				pendingWaitDuration = detail.requestedSeconds
			elseif pendingWaitDuration == nil then
				pendingWaitDuration = detail.requestedSeconds
			end
		elseif cat == "http" and (act == "GetAsync" or act == "PostAsync" or act == "RequestAsync" or act == "HttpGet" or act == "HttpPost") then
			requestCount += 1
			local url = tostring(detail.url or "")
			local method = string.upper(tostring(detail.method or "GET"))
			methods[method] = (methods[method] or 0) + 1

			if sawHttp and pendingWaitDuration ~= nil then
				table.insert(pollIntervalsSeconds, pendingWaitDuration)
				pendingWaitDuration = nil
			end
			sawHttp = true

			local host, path, query = parseUrlParts(url)
			extractQueryAuthKeys(query, authKeys)

			if type(detail.headers) == "table" then
				for hk, hv in detail.headers do
					local keyStr = tostring(hk)
					local valStr = tostring(hv)
					local lowerKey = string.lower(keyStr)
					addUnique(headerKeys, keyStr)
					if lowerKey == "user-agent" then
						addUnique(userAgents, valStr)
					elseif AUTH_HEADER_NAMES[lowerKey] or string.find(lowerKey, "auth", 1, true) or string.find(lowerKey, "token", 1, true) then
						if not authHeaders[keyStr] then
							authHeaders[keyStr] = {}
						end
						addUnique(authHeaders[keyStr], valStr)
						addUnique(authKeys, keyStr .. ": " .. valStr)
					end
				end
			end

			if type(detail.body) == "string" and #detail.body > 0 then
				extractBodyAuthKeys(detail.body, authKeys)
				if #sampleBodies < 10 then
					addUnique(sampleBodies, string.sub(detail.body, 1, 512))
				end
			elseif type(detail.body) == "table" and type(detail.body.preview) == "string" then
				if #sampleBodies < 10 then
					addUnique(sampleBodies, detail.body.preview)
				end
			end

			local epKey = host .. path
			local ep = endpointMap[epKey]
			if ep then
				ep.count += 1
				addUnique(ep.methods, method)
			else
				endpointMap[epKey] = {
					url = url,
					host = host,
					path = path,
					methods = { method },
					count = 1,
				}
			end

			local ts = tonumber(entry.timestampMs)
			if ts then
				local list = endpointTimestamps[epKey]
				if not list then
					list = {}
					endpointTimestamps[epKey] = list
				end
				if #list > 0 then
					local delta = math.floor((ts - list[#list]) * 100) / 100
					table.insert(observedDeltasMs, delta)
				end
				table.insert(list, ts)
			end
		end
	end

	local endpoints: { EndpointSummary } = {}
	local repeatedEndpoint: string? = nil
	for _, ep in endpointMap do
		table.insert(endpoints, ep)
		if ep.count >= 2 then
			repeatedEndpoint = ep.url
		end
	end

	table.sort(endpoints, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.url < b.url
	end)
	table.sort(userAgents)
	table.sort(headerKeys)
	table.sort(authKeys)

	local estimatedPoll: number? = nil
	if #pollIntervalsSeconds > 0 then
		local sum = 0
		for _, v in pollIntervalsSeconds do
			sum += v
		end
		estimatedPoll = math.floor((sum / #pollIntervalsSeconds) * 1000) / 1000
	end

	local beaconingDetected = repeatedEndpoint ~= nil or #pollIntervalsSeconds > 0
	local beaconingReason: string? = nil
	if repeatedEndpoint then
		beaconingReason = "Repeated HTTP polling to " .. repeatedEndpoint
	elseif #pollIntervalsSeconds > 0 then
		beaconingReason = "HTTP requests separated by timed wait interval"
	end

	return {
		requestCount = requestCount,
		methods = methods,
		userAgents = userAgents,
		headerKeys = headerKeys,
		authHeaders = authHeaders,
		authKeys = authKeys,
		endpoints = endpoints,
		pollIntervalsSeconds = pollIntervalsSeconds,
		estimatedPollIntervalSeconds = estimatedPoll,
		observedDeltasMs = observedDeltasMs,
		beaconingDetected = beaconingDetected,
		beaconingReason = beaconingReason,
		sampleBodies = sampleBodies,
	}
end

return Fingerprint
