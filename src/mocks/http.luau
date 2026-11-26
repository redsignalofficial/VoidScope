--!strict
-- Fake Roblox HttpService: logs URL, method, headers, and body while returning
-- safe stub responses (or forwarding to a local-only loopback C2 stub server).
-- Never performs external network calls.

local net = require("@lune/net")
local serde = require("@lune/serde")
local Proxy = require("../proxy")

local HttpMock = {}

export type StubRequest = {
	method: string,
	originalUrl: string,
	path: string,
	query: string?,
	headers: { [string]: string },
	body: string,
}

export type StubResponse = {
	statusCode: number?,
	statusMessage: string?,
	headers: { [string]: string }?,
	body: string?,
}

export type HttpMockOptions = {
	c2StubUrl: string?,
	c2StubHandler: ((req: StubRequest) -> StubResponse)?,
	maxRequests: number?,
	onDecode: ((source: string, value: string) -> ())?,
}

local DEFAULT_MAX_REQUESTS = 100

local function isLoopbackUrl(url: string): boolean
	return string.match(url, "^https?://127%.0%.0%.1[:/]") ~= nil
		or string.match(url, "^https?://localhost[:/]") ~= nil
		or string.match(url, "^https?://%[::1%][:/]") ~= nil
end

local function extractPathAndQuery(url: string): (string, string?)
	local afterScheme = string.gsub(url, "^https?://[^/]+", "")
	if afterScheme == "" or afterScheme == url then
		return "/", nil
	end
	local path, query = string.match(afterScheme, "^([^?]+)%?(.*)$")
	if path then
		return path, query
	end
	return afterScheme, nil
end

local function normalizeHeaders(raw: any): { [string]: string }
	local out: { [string]: string } = {}
	if type(raw) ~= "table" then
		return out
	end
	for k, v in raw do
		out[tostring(k)] = tostring(v)
	end
	return out
end

local function generateUuidV4(): string
	local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
	local result = string.gsub(template, "[xy]", function(c)
		local v = if c == "x" then math.random(0, 15) else math.random(8, 11)
		return string.format("%x", v)
	end)
	return result
end

function HttpMock.create(logger: any, options: HttpMockOptions?): any
	local opts = options or {}
	local maxRequests = opts.maxRequests or DEFAULT_MAX_REQUESTS
	local requestCount = 0

	if opts.c2StubUrl and not isLoopbackUrl(opts.c2StubUrl) then
		error("VoidScope HttpMock: c2StubUrl must be a local loopback URL (127.0.0.1 / localhost)")
	end

	local function buildStubResponse(method: string, url: string, headers: { [string]: string }, body: string): (number, string, { [string]: string }, string)
		local path, query = extractPathAndQuery(url)

		if opts.c2StubHandler then
			local ok, resp = pcall(opts.c2StubHandler, {
				method = method,
				originalUrl = url,
				path = path,
				query = query,
				headers = headers,
				body = body,
			})
			if ok and type(resp) == "table" then
				return resp.statusCode or 200,
					resp.statusMessage or "OK",
					resp.headers or { ["content-type"] = "application/json" },
					resp.body or ""
			end
		end

		if opts.c2StubUrl then
			local targetUrl = string.gsub(opts.c2StubUrl, "/$", "") .. path
			if query and #query > 0 then
				targetUrl ..= "?" .. query
			end
			local forwardHeaders = table.clone(headers)
			forwardHeaders["X-VoidScope-Original-Url"] = url
			forwardHeaders["Host"] = nil
			local ok, res = pcall(net.request, {
				url = targetUrl,
				method = (method :: any),
				headers = forwardHeaders,
				body = if #body > 0 then body else nil,
			})
			if ok and res then
				local respHeaders: { [string]: string } = {}
				for k, v in res.headers do
					respHeaders[tostring(k)] = if type(v) == "table" then table.concat(v, ", ") else tostring(v)
				end
				return res.statusCode, res.statusMessage, respHeaders, res.body
			end
		end

		local lowerUrl = string.lower(url)
		if string.match(lowerUrl, "%.luau?$")
			or string.find(lowerUrl, "raw.githubusercontent", 1, true)
			or string.find(lowerUrl, "pastebin", 1, true)
			or string.find(lowerUrl, "hastebin", 1, true)
		then
			return 200,
				"OK",
				{ ["content-type"] = "text/plain" },
				'print("[VoidScope] stubbed remote script for ' .. string.gsub(url, '["\r\n]', "") .. '")'
		end

		local stubJson = serde.encode("json", {
			ok = true,
			status = "active",
			command = "noop",
			script = 'print("[VoidScope] stubbed C2 command")',
			interval = 5,
			data = {},
		})
		return 200, "OK", { ["content-type"] = "application/json" }, stubJson
	end

	local function performRequest(actionName: string, method: string, url: string, headers: { [string]: string }, body: string, extra: { [string]: any }?): { [string]: any }
		requestCount += 1
		if requestCount > maxRequests then
			logger:log("limit", "http_max_requests_exceeded", {
				requestCount = requestCount,
				maxRequests = maxRequests,
				lastUrl = url,
			}, true)
			error("VoidScope: HttpService request limit exceeded", 2)
		end

		local detail: { [string]: any } = {
			url = url,
			method = method,
			headers = headers,
			body = body,
			requestIndex = requestCount,
		}
		if extra then
			for k, v in extra do
				detail[k] = v
			end
		end

		local statusCode, statusMsg, respHeaders, respBody = buildStubResponse(method, url, headers, body)
		detail.stubStatusCode = statusCode
		detail.stubResponseBytes = #respBody
		logger:log("http", actionName, detail, true)

		return {
			Success = statusCode >= 200 and statusCode < 300,
			StatusCode = statusCode,
			StatusMessage = statusMsg,
			Headers = respHeaders,
			Body = respBody,
		}
	end

	local methods: { [string]: any } = {
		HttpEnabled = true,

		GetAsync = function(_self, url: string, nocache: boolean?, headers: any): string
			local resp = performRequest("GetAsync", "GET", tostring(url), normalizeHeaders(headers), "", {
				nocache = nocache == true,
			})
			return resp.Body
		end,

		PostAsync = function(_self, url: string, data: string, contentType: any, compress: boolean?, headers: any): string
			local hdrs = normalizeHeaders(headers)
			if contentType ~= nil and hdrs["Content-Type"] == nil and hdrs["content-type"] == nil then
				hdrs["Content-Type"] = tostring(contentType)
			end
			local resp = performRequest("PostAsync", "POST", tostring(url), hdrs, tostring(data), {
				contentType = if contentType ~= nil then tostring(contentType) else "ApplicationJson",
				compress = compress == true,
			})
			return resp.Body
		end,

		RequestAsync = function(_self, reqOptions: { [string]: any }): { [string]: any }
			if type(reqOptions) ~= "table" or type(reqOptions.Url) ~= "string" then
				error("HttpService:RequestAsync requires a table with a string Url", 2)
			end
			local method = string.upper(tostring(reqOptions.Method or "GET"))
			local hdrs = normalizeHeaders(reqOptions.Headers)
			local body = if reqOptions.Body ~= nil then tostring(reqOptions.Body) else ""
			return performRequest("RequestAsync", method, reqOptions.Url, hdrs, body, {
				compress = reqOptions.Compress,
			})
		end,

		JSONEncode = function(_self, input: any): string
			return serde.encode("json", input)
		end,

		JSONDecode = function(_self, input: string): any
			local raw = tostring(input)
			if opts.onDecode then
				opts.onDecode("json", raw)
			end
			local ok, decoded = pcall(serde.decode, "json", raw)
			if not ok then
				error("Can't parse JSON: " .. tostring(decoded), 2)
			end
			if #raw >= 12 then
				logger:log("http", "JSONDecode", {
					raw = raw,
					length = #raw,
				})
			end
			return decoded
		end,

		GenerateGUID = function(_self, wrapInCurlyBraces: boolean?): string
			local uuid = generateUuidV4()
			if wrapInCurlyBraces == false then
				return uuid
			end
			return "{" .. uuid .. "}"
		end,

		UrlEncode = function(_self, input: string): string
			return net.urlEncode(tostring(input))
		end,
	}

	local service = Proxy.create("game.HttpService", logger, {
		typeName = "Instance",
		className = "HttpService",
		overrides = methods,
	})

	return {
		service = service,
		httpGet = function(url: string, nocache: boolean?, headers: any): string
			local resp = performRequest("HttpGet", "GET", tostring(url), normalizeHeaders(headers), "", {
				nocache = nocache == true,
				viaGameMethod = true,
			})
			return resp.Body
		end,
		httpPost = function(url: string, data: string, contentType: any, headers: any): string
			local resp = performRequest("HttpPost", "POST", tostring(url), normalizeHeaders(headers), tostring(data), {
				contentType = if contentType ~= nil then tostring(contentType) else nil,
				viaGameMethod = true,
			})
			return resp.Body
		end,
	}
end

return HttpMock
