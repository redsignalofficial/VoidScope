--!strict
-- Recursive Roblox-compatible object proxy that logs unknown property reads,
-- mutations, and method/function invocations without crashing execution.

local Proxy = {}

export type ProxyOptions = {
	typeName: string?,
	className: string?,
	parent: any?,
	depth: number?,
	maxDepth: number?,
	overrides: { [string]: any }?,
	onWrite: ((key: any, value: any) -> ())?,
}

type ProxyMetaRecord = {
	typeName: string,
	className: string,
	path: string,
}

-- Weak-key registry lets sandbox typeof() identify mock Instances/Signals safely
-- while keeping userdata metatables locked against script tampering.
local proxyRegistry: { [any]: ProxyMetaRecord } = setmetatable({}, { __mode = "k" }) :: any
local childAdders: { [any]: (child: any) -> () } = setmetatable({}, { __mode = "k" }) :: any

local DEFAULT_MAX_DEPTH = 16

function Proxy.isProxy(value: any): boolean
	return proxyRegistry[value] ~= nil
end

function Proxy.getTypeName(value: any): string?
	local rec = proxyRegistry[value]
	return if rec then rec.typeName else nil
end

function Proxy.getPath(value: any): string?
	local rec = proxyRegistry[value]
	return if rec then rec.path else nil
end

function Proxy.registerType(value: any, typeName: string, className: string?, path: string?)
	proxyRegistry[value] = {
		typeName = typeName,
		className = className or typeName,
		path = path or typeName,
	}
end

local function lastPathSegment(path: string): string
	local dot = string.match(path, "([^%.]+)$")
	return dot or path
end

local function createSignalStub(signalPath: string, logger: any): any
	local signal = newproxy(true)
	local callbacks: { (...any) -> ...any } = {}

	local function makeConnection(): any
		local conn = newproxy(true)
		local connected = true
		local connMt = getmetatable(conn)
		connMt.__metatable = "The metatable is locked"
		connMt.__index = function(_self, key)
			if key == "Connected" then
				return connected
			elseif key == "Disconnect" or key == "disconnect" then
				return function()
					connected = false
				end
			end
			return nil
		end
		connMt.__tostring = function()
			return "Connection"
		end
		Proxy.registerType(conn, "RBXScriptConnection", "RBXScriptConnection", signalPath .. ".Connection")
		return conn
	end

	local mt = getmetatable(signal)
	mt.__metatable = "The metatable is locked"
	mt.__index = function(_self, key)
		if key == "Connect" or key == "connect" or key == "Once" then
			return function(_s, fn)
				logger:log("signal", "connect", { signal = signalPath, method = tostring(key) })
				if type(fn) == "function" then
					table.insert(callbacks, fn)
				end
				return makeConnection()
			end
		elseif key == "Wait" or key == "wait" then
			return function()
				logger:log("signal", "wait", { signal = signalPath })
				return 0.016
			end
		elseif key == "Fire" then
			return function(_s, ...)
				logger:log("signal", "fire", { signal = signalPath, args = { ... } })
				for _, fn in callbacks do
					pcall(fn, ...)
				end
			end
		end
		return nil
	end
	mt.__tostring = function()
		return "Signal " .. lastPathSegment(signalPath)
	end
	Proxy.registerType(signal, "RBXScriptSignal", "RBXScriptSignal", signalPath)
	return signal
end

Proxy.createSignal = createSignalStub

function Proxy.create(path: string, logger: any, options: ProxyOptions?): any
	local opts = options or {}
	local depth = opts.depth or 0
	local maxDepth = opts.maxDepth or DEFAULT_MAX_DEPTH
	local typeName = opts.typeName or "Instance"
	local className = opts.className or lastPathSegment(path)
	local overrides = opts.overrides or {}

	local childrenCache: { [string]: any } = {}
	local writtenProps: { [any]: any } = {}
	local attributes: { [string]: any } = {}
	local registeredChildren: { any } = {}

	local proxy = newproxy(true)
	Proxy.registerType(proxy, typeName, className, path)

	local function getOrCreateChildProxy(childName: string, subOverrides: { [string]: any }?): any
		if childrenCache[childName] ~= nil then
			return childrenCache[childName]
		end
		if depth >= maxDepth then
			logger:log("proxy", "max_depth", { path = path, key = childName, depth = depth })
			return proxy
		end
		local child = Proxy.create(path .. "." .. childName, logger, {
			typeName = "Instance",
			className = childName,
			parent = proxy,
			depth = depth + 1,
			maxDepth = maxDepth,
			overrides = subOverrides,
		})
		childrenCache[childName] = child
		return child
	end

	local baseMethods: { [string]: any } = {
		GetFullName = function()
			return path
		end,
		IsA = function(_self, targetClass: string)
			return targetClass == className or targetClass == "Instance" or targetClass == "Object"
		end,
		GetChildren = function()
			local copy = {}
			for i, child in registeredChildren do
				copy[i] = child
			end
			return copy
		end,
		GetDescendants = function()
			local copy = {}
			for i, child in registeredChildren do
				copy[i] = child
			end
			return copy
		end,
		FindFirstChild = function(_self, name: string)
			local key = tostring(name)
			logger:log("proxy", "FindFirstChild", { path = path, target = key })
			for _, child in registeredChildren do
				if child.Name == key then
					return child
				end
			end
			return nil
		end,
		FindFirstChildOfClass = function(_self, targetClass: string)
			logger:log("proxy", "FindFirstChildOfClass", { path = path, className = tostring(targetClass) })
			for _, child in registeredChildren do
				if child.ClassName == targetClass then
					return child
				end
			end
			return nil
		end,
		FindFirstChildWhichIsA = function(_self, targetClass: string)
			logger:log("proxy", "FindFirstChildWhichIsA", { path = path, className = tostring(targetClass) })
			for _, child in registeredChildren do
				if child:IsA(targetClass) then
					return child
				end
			end
			return nil
		end,
		WaitForChild = function(_self, name: string)
			local key = tostring(name)
			logger:log("proxy", "WaitForChild", { path = path, target = key })
			for _, child in registeredChildren do
				if child.Name == key then
					return child
				end
			end
			return getOrCreateChildProxy(key)
		end,
		Clone = function()
			logger:log("proxy", "Clone", { path = path })
			return Proxy.create(path .. "_Clone", logger, {
				typeName = typeName,
				className = className,
				depth = depth,
				maxDepth = maxDepth,
				overrides = overrides,
			})
		end,
		Destroy = function()
			logger:log("proxy", "Destroy", { path = path })
		end,
		ClearAllChildren = function()
			logger:log("proxy", "ClearAllChildren", { path = path })
			table.clear(registeredChildren)
		end,
		GetAttribute = function(_self, attrName: string)
			return attributes[tostring(attrName)]
		end,
		SetAttribute = function(_self, attrName: string, value: any)
			logger:log("proxy", "SetAttribute", { path = path, attribute = tostring(attrName), value = value })
			attributes[tostring(attrName)] = value
		end,
		GetAttributes = function()
			return table.clone(attributes)
		end,
		IsDescendantOf = function()
			return false
		end,
		IsAncestorOf = function()
			return false
		end,
		-- Common remote / signal hooks if invoked directly on an unknown child proxy
		FireServer = function(_self, ...)
			logger:log("remote", "FireServer", { path = path, args = { ... } }, true)
		end,
		FireAllClients = function(_self, ...)
			logger:log("remote", "FireAllClients", { path = path, args = { ... } }, true)
		end,
		FireClient = function(_self, player, ...)
			logger:log("remote", "FireClient", { path = path, player = tostring(player), args = { ... } }, true)
		end,
		InvokeServer = function(_self, ...)
			logger:log("remote", "InvokeServer", { path = path, args = { ... } }, true)
			return nil
		end,
		InvokeClient = function(_self, player, ...)
			logger:log("remote", "InvokeClient", { path = path, player = tostring(player), args = { ... } }, true)
			return nil
		end,
	}

	local mt = getmetatable(proxy)
	mt.__metatable = "The metatable is locked"

	mt.__index = function(_self, key)
		if overrides[key] ~= nil then
			return overrides[key]
		end
		if writtenProps[key] ~= nil then
			return writtenProps[key]
		end
		if key == "Name" then
			return lastPathSegment(path)
		elseif key == "ClassName" then
			return className
		elseif key == "Parent" then
			return opts.parent
		elseif key == "Archivable" then
			return true
		elseif key == "Changed" or key == "ChildAdded" or key == "ChildRemoved" or key == "DescendantAdded" or key == "OnServerEvent" or key == "OnClientEvent" then
			local sig = createSignalStub(path .. "." .. tostring(key), logger)
			writtenProps[key] = sig
			return sig
		elseif baseMethods[key] ~= nil then
			return baseMethods[key]
		end

		local keyStr = tostring(key)
		logger:log("proxy", "index", { path = path, key = keyStr })
		return getOrCreateChildProxy(keyStr)
	end

	mt.__newindex = function(_self, key, value)
		local keyStr = tostring(key)
		logger:log("proxy", "newindex", { path = path, key = keyStr, value = value })
		if opts.onWrite then
			opts.onWrite(key, value)
		end
		if keyStr == "Parent" and Proxy.isProxy(value) then
			local addFn = childAdders[value]
			if addFn then
				addFn(proxy)
			end
		end
		writtenProps[key] = value
	end

	mt.__call = function(_self, ...)
		local args = table.pack(...)
		local isMethod = false
		local loggedArgs = {}
		local startIdx = 1
		if opts.parent ~= nil and args[1] == opts.parent then
			isMethod = true
			startIdx = 2
		end
		for i = startIdx, args.n do
			table.insert(loggedArgs, args[i])
		end
		logger:log("proxy", "call", {
			target = path,
			isMethod = isMethod,
			args = loggedArgs,
		})
		return getOrCreateChildProxy("__result")
	end

	mt.__tostring = function()
		return lastPathSegment(path)
	end

	mt.__concat = function(a, b)
		return tostring(a) .. tostring(b)
	end

	childAdders[proxy] = function(childProxy: any)
		table.insert(registeredChildren, childProxy)
	end

	return proxy
end

return Proxy
