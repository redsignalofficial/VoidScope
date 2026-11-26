--!strict
-- Local-only HTTP C2 stub server (strictly bound to 127.0.0.1).
-- Captures incoming C2 beacons and returns benign test commands so multi-stage
-- polling backdoors reveal their protocol, headers, and second-stage behavior.

local DateTime = require("@lune/datetime")
local net = require("@lune/net")
local serde = require("@lune/serde")

local StubServer = {}

export type CapturedRequest = {
	seq: number,
	receivedAt: string,
	method: string,
	path: string,
	query: { [string]: string? },
	headers: { [string]: string },
	body: string,
	originalUrl: string?,
}

export type StubServerOptions = {
	port: number?,
	maxPortAttempts: number?,
	benignScript: string?,
	routes: { [string]: string }?,
}

export type StubServerHandle = {
	url: string,
	port: number,
	getRequests: () -> { CapturedRequest },
	clearRequests: () -> (),
	handleRaw: (req: {
		method: string,
		path: string,
		query: { [string]: string? }?,
		headers: { [string]: string }?,
		body: string?,
		originalUrl: string?,
	}) -> { status: number, headers: { [string]: string }, body: string },
	stop: () -> (),
}

local DEFAULT_BASE_PORT = 18420
local DEFAULT_BENIGN_SCRIPT = 'print("[VoidScope C2 Stub] benign command executed")'

local function createDispatcher(options: StubServerOptions?)
	local opts = options or {}
	local requests: { CapturedRequest } = {}
	local benignScript = opts.benignScript or DEFAULT_BENIGN_SCRIPT
	local customRoutes = opts.routes or {}

	local function handleRaw(req: {
		method: string,
		path: string,
		query: { [string]: string? }?,
		headers: { [string]: string }?,
		body: string?,
		originalUrl: string?,
	}): { status: number, headers: { [string]: string }, body: string }
		local hdrs = req.headers or {}
		local seq = #requests + 1
		local captured: CapturedRequest = {
			seq = seq,
			receivedAt = DateTime.now():toRfc3339(),
			method = string.upper(req.method or "GET"),
			path = req.path or "/",
			query = req.query or {},
			headers = hdrs,
			body = req.body or "",
			originalUrl = req.originalUrl or hdrs["x-voidscope-original-url"] or hdrs["X-VoidScope-Original-Url"],
		}
		table.insert(requests, captured)

		local path = captured.path
		if customRoutes[path] then
			return {
				status = 200,
				headers = { ["Content-Type"] = "text/plain" },
				body = customRoutes[path],
			}
		end

		local lowerPath = string.lower(path)
		if string.match(lowerPath, "%.luau?$")
			or string.find(lowerPath, "/script", 1, true)
			or string.find(lowerPath, "/payload", 1, true)
			or string.find(lowerPath, "/raw", 1, true)
		then
			return {
				status = 200,
				headers = { ["Content-Type"] = "text/plain" },
				body = benignScript,
			}
		end

		local jsonBody = serde.encode("json", {
			ok = true,
			status = "active",
			command = "noop",
			script = benignScript,
			interval = 5,
			seq = seq,
		})

		return {
			status = 200,
			headers = { ["Content-Type"] = "application/json" },
			body = jsonBody,
		}
	end

	return requests, handleRaw
end

function StubServer.createHandler(options: StubServerOptions?)
	local requests, handleRaw = createDispatcher(options)
	return {
		getRequests = function()
			return requests
		end,
		handleRaw = handleRaw,
	}
end

function StubServer.start(options: StubServerOptions?): StubServerHandle
	local opts = options or {}
	local basePort = opts.port or DEFAULT_BASE_PORT
	local maxAttempts = opts.maxPortAttempts or 20
	local requests, handleRaw = createDispatcher(opts)

	local serveHandle: net.ServeHandle? = nil
	local boundPort = basePort
	local lastErr: any = nil

	for offset = 0, maxAttempts - 1 do
		local candidatePort = basePort + offset
		local ok, handleOrErr = pcall(net.serve, candidatePort, {
			address = "http://127.0.0.1",
			handleRequest = function(req)
				return handleRaw({
					method = req.method,
					path = req.path,
					query = req.query,
					headers = req.headers,
					body = req.body,
				})
			end,
		})
		if ok and handleOrErr then
			serveHandle = handleOrErr
			boundPort = candidatePort
			break
		else
			lastErr = handleOrErr
		end
	end

	if not serveHandle then
		error("VoidScope StubServer: failed to bind local 127.0.0.1 port: " .. tostring(lastErr))
	end

	local handle = serveHandle :: net.ServeHandle

	return {
		url = "http://127.0.0.1:" .. tostring(boundPort),
		port = boundPort,
		getRequests = function()
			return requests
		end,
		clearRequests = function()
			table.clear(requests)
		end,
		handleRaw = handleRaw,
		stop = function()
			pcall(function()
				handle:stop()
			end)
		end,
	}
end

return StubServer
