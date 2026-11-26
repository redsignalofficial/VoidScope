--!strict
-- Hardened Luau sandbox integrating logger, recursive proxies, string/loadstring hooks,
-- Roblox service mocks, execution limits, and anti-escape defenses.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local task = require("@lune/task")

local Proxy = require("./proxy")
local StringsHook = require("./hooks/strings")
local LoadstringHook = require("./hooks/loadstring")
local HttpMock = require("./mocks/http")
local InsertMock = require("./mocks/insert")
local MessagingMock = require("./mocks/messaging")
local DataStoreMock = require("./mocks/datastore")
local GameMock = require("./mocks/game")

local Sandbox = {}

export type SandboxLimits = {
	maxLayers: number?,
	maxLayerBytes: number?,
	maxTotalBytes: number?,
	maxRepBytes: number?,
	maxWaits: number?,
	maxSpawns: number?,
	maxHttpRequests: number?,
	maxRequires: number?,
	realWaitCapSeconds: number?,
}

export type SandboxOptions = {
	logger: any,
	layersDir: string,
	c2StubUrl: string?,
	c2StubHandler: ((req: any) -> any)?,
	limits: SandboxLimits?,
	gameOptions: GameMock.GameMockOptions?,
	quietPrint: boolean?,
}

export type SandboxRunResult = {
	ok: boolean,
	error: string?,
	layerCount: number,
	totalLayerBytes: number,
	layers: { LoadstringHook.LayerRecord },
	waitCount: number,
	spawnCount: number,
	durationMs: number,
}

local DEFAULT_MAX_WAITS = 25
local DEFAULT_MAX_SPAWNS = 50
local DEFAULT_REAL_WAIT_CAP = 0.01

local function sanitizeTraceback(trace: string): string
	local lines = string.split(trace, "\n")
	local clean = {}
	for _, line in lines do
		if string.find(line, "voidscope_entry", 1, true) or string.find(line, "voidscope_layer_", 1, true) then
			table.insert(clean, line)
		end
	end
	if #clean == 0 then
		return "stack traceback:\n\t[sandbox]: in main chunk"
	end
	return table.concat(clean, "\n")
end

function Sandbox.create(options: SandboxOptions): any
	local logger = options.logger
	local limits = options.limits or {}
	local maxWaits = limits.maxWaits or DEFAULT_MAX_WAITS
	local maxSpawns = limits.maxSpawns or DEFAULT_MAX_SPAWNS
	local realWaitCap = limits.realWaitCapSeconds or DEFAULT_REAL_WAIT_CAP

	local virtualClock = 0
	local waitCount = 0
	local spawnCount = 0
	local activeTasks = 0

	-- Weak-key map tracking strictly sandbox-owned closures and their environments.
	local fnEnvs: { [any]: { [string]: any } } = setmetatable({}, { __mode = "k" }) :: any
	local sandboxEnv: { [string]: any } = {}
	local protectedTables: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

	local function isSandboxClosure(fn: any): boolean
		if type(fn) ~= "function" then
			return false
		end
		if fnEnvs[fn] ~= nil then
			return true
		end
		local src = debug.info(fn, "s")
		return type(src) == "string"
			and (src == '[string "voidscope_entry"]' or string.sub(src, 1, 25) == '[string "voidscope_layer_')
	end

	local stringsHook = StringsHook.create(logger, {
		maxRepBytes = limits.maxRepBytes,
	})

	local httpMock = HttpMock.create(logger, {
		c2StubUrl = options.c2StubUrl,
		c2StubHandler = options.c2StubHandler,
		maxRequests = limits.maxHttpRequests,
		onDecode = stringsHook.inspectDecoded,
	})

	local insertMock = InsertMock.create(logger, {
		maxRequires = limits.maxRequires,
	})

	local messagingMock = MessagingMock.create(logger)
	local datastoreMock = DataStoreMock.create(logger)

	local gameEnv = GameMock.create(logger, {
		http = httpMock,
		insert = insertMock,
		messaging = messagingMock,
		datastore = datastoreMock,
	}, options.gameOptions)

	local pendingLayerWrites: { { filePath: string, content: string } } = {}
	local layersDirReady = false

	local function flushPendingLayers()
		if #pendingLayerWrites == 0 then
			return
		end
		if not layersDirReady then
			if not fs.isDir(options.layersDir) then
				pcall(fs.writeDir, options.layersDir)
			end
			layersDirReady = true
		end
		local batch = table.clone(pendingLayerWrites)
		table.clear(pendingLayerWrites)
		for _, item in batch do
			pcall(fs.writeFile, item.filePath, item.content)
		end
	end

	local loadstringHook = LoadstringHook.create(logger, {
		getEnv = function()
			return sandboxEnv
		end,
		registerFunction = function(fn, env)
			fnEnvs[fn] = env
		end,
	}, {
		layersDir = options.layersDir,
		maxLayers = limits.maxLayers,
		maxLayerBytes = limits.maxLayerBytes,
		maxTotalBytes = limits.maxTotalBytes,
		onLayerDump = function(filePath, content)
			table.insert(pendingLayerWrites, { filePath = filePath, content = content })
		end,
	})

	-- Virtualized wait prevents C2 polling loops (e.g. while task.wait(30) do) from
	-- burning wall-clock time while still capturing intended poll intervals in logs.
	local function virtualWait(duration: number?): number
		local requested = if type(duration) == "number" and duration >= 0 then duration else 0.03
		waitCount += 1
		logger:log("task", "wait", {
			requestedSeconds = requested,
			waitCount = waitCount,
			virtualClock = virtualClock,
		})
		if waitCount > maxWaits then
			logger:log("limit", "max_waits_exceeded", {
				waitCount = waitCount,
				maxWaits = maxWaits,
			}, true)
			error("VoidScope: max wait iterations exceeded", 2)
		end
		virtualClock += requested
		local slice = math.min(requested, realWaitCap)
		if slice > 0 then
			task.wait(slice)
		else
			task.wait()
		end
		return requested
	end

	local function trackedSpawn(kind: string, delaySec: number?, fnOrThread: any, ...: any): thread?
		spawnCount += 1
		logger:log("task", kind, {
			delaySeconds = delaySec,
			spawnCount = spawnCount,
			targetType = type(fnOrThread),
		})
		if spawnCount > maxSpawns then
			logger:log("limit", "max_spawns_exceeded", {
				spawnCount = spawnCount,
				maxSpawns = maxSpawns,
			}, true)
			error("VoidScope: max task spawns exceeded", 2)
		end
		if type(fnOrThread) ~= "function" then
			return nil
		end
		local packedArgs = table.pack(...)
		activeTasks += 1
		return task.spawn(function()
			local myThread = coroutine.running()
			logger:addSafeFlushThread(myThread)
			logger:log("task", kind .. "_exec_start", { spawnCount = spawnCount, delaySeconds = delaySec })
			if delaySec and delaySec > 0 then
				virtualClock += delaySec
				-- Skip real wait to avoid cooperative scheduler starvation from caller thread
			end
			local ok, err = pcall(fnOrThread, table.unpack(packedArgs, 1, packedArgs.n))
			activeTasks -= 1
			logger:log("task", kind .. "_exec_end", { spawnCount = spawnCount, ok = ok })
			if not ok then
				logger:log("task", "spawned_error", { error = tostring(err) }, true)
			end
			logger:removeSafeFlushThread(myThread)
		end)
	end

	local safeTask = {
		wait = virtualWait,
		spawn = function(fn: any, ...: any)
			return trackedSpawn("spawn", nil, fn, ...)
		end,
		defer = function(fn: any, ...: any)
			return trackedSpawn("defer", 0, fn, ...)
		end,
		delay = function(sec: number, fn: any, ...: any)
			return trackedSpawn("delay", if type(sec) == "number" then sec else 0, fn, ...)
		end,
		cancel = function(th: thread)
			logger:log("task", "cancel", {})
			pcall(task.cancel, th)
		end,
	}

	local safeOs = {
		clock = function()
			return os.clock() + virtualClock
		end,
		time = function()
			return math.floor(os.time() + virtualClock)
		end,
		date = os.date,
		difftime = os.difftime,
	}

	local hostFnNames: { [any]: string } = setmetatable({}, { __mode = "k" }) :: any

	local function maskHostDebugInfo(target: any, what: string): ...any
		local results: { any } = {}
		local n = 0
		for i = 1, #what do
			local ch = string.sub(what, i, i)
			if ch == "s" then
				n += 1
				results[n] = "[C]"
			elseif ch == "l" then
				n += 1
				results[n] = -1
			elseif ch == "n" then
				n += 1
				results[n] = if type(target) == "function" then (hostFnNames[target] or "") else ""
			elseif ch == "a" then
				n += 1
				results[n] = 0
				n += 1
				results[n] = true
			elseif ch == "f" then
				n += 1
				results[n] = if type(target) == "function" then target else nil
			end
		end
		return table.unpack(results, 1, n)
	end

	local safeDebug = {
		traceback = function(msgOrThread: any, levelOrMsg: any): string
			logger:log("sandbox", "debug_traceback", {})
			local raw = debug.traceback(msgOrThread, levelOrMsg)
			return sanitizeTraceback(raw)
		end,
		info = function(target: any, what: string): ...any
			local whatStr = tostring(what or "sln")
			logger:log("sandbox", "debug_info", { what = whatStr, targetType = type(target) })
			if type(target) == "function" then
				if isSandboxClosure(target) then
					return debug.info(target, whatStr)
				end
				return maskHostDebugInfo(target, whatStr)
			elseif type(target) == "number" and target >= 1 then
				local frameFn = debug.info(target + 1, "f")
				if frameFn and isSandboxClosure(frameFn) then
					return debug.info(target + 1, whatStr)
				end
				return maskHostDebugInfo(nil, whatStr)
			end
			return maskHostDebugInfo(nil, whatStr)
		end,
		profilebegin = function() end,
		profileend = function() end,
		setmemorycategory = function() end,
		resetmemorycategory = function() end,
	}

	local function safeGetfenv(target: any): { [string]: any }
		if target == nil then
			local callerFn = debug.info(2, "f")
			if callerFn and isSandboxClosure(callerFn) then
				return fnEnvs[callerFn] or sandboxEnv
			end
			return sandboxEnv
		elseif type(target) == "number" then
			if target < 0 then
				logger:log("sandbox", "getfenv_stack_probe", { level = target }, true)
				error("invalid argument #1 to 'getfenv' (level must be non-negative)", 2)
			elseif target == 0 then
				logger:log("sandbox", "getfenv_stack_probe", { level = 0 }, true)
				return sandboxEnv
			end
			if target > 1 then
				logger:log("sandbox", "getfenv_stack_probe", { level = target }, true)
			end
			local callerFn = debug.info(target + 1, "f")
			if callerFn == nil then
				error("invalid argument #1 to 'getfenv' (invalid level)", 2)
			end
			if isSandboxClosure(callerFn) then
				return fnEnvs[callerFn] or sandboxEnv
			end
			return sandboxEnv
		elseif type(target) == "function" then
			if isSandboxClosure(target) then
				return fnEnvs[target] or sandboxEnv
			end
			logger:log("sandbox", "getfenv_host_fn_probe", {}, true)
			return sandboxEnv
		end
		error("bad argument #1 to 'getfenv' (number or function expected)", 2)
	end

	local function safeSetfenv(target: any, newEnv: { [string]: any }): any
		if type(newEnv) ~= "table" then
			error("bad argument #2 to 'setfenv' (table expected)", 2)
		end
		if type(target) == "function" then
			if not isSandboxClosure(target) then
				logger:log("sandbox", "setfenv_blocked_host_fn", {
					name = debug.info(target, "n") or "",
				})
				error("'setfenv' cannot change environment of given object", 2)
			end
			fnEnvs[target] = newEnv
			return setfenv(target, newEnv)
		elseif type(target) == "number" then
			logger:log("sandbox", "setfenv_stack", { level = target })
			if target <= 0 then
				logger:log("sandbox", "setfenv_blocked_level0", {}, true)
				error("'setfenv' cannot change environment of given object", 2)
			end
			local callerFn = debug.info(target + 1, "f")
			if not callerFn or not isSandboxClosure(callerFn) then
				logger:log("sandbox", "setfenv_blocked_host_frame", { level = target }, true)
				error("'setfenv' cannot change environment of given object", 2)
			end
			fnEnvs[callerFn] = newEnv
			return setfenv(callerFn, newEnv)
		end
		error("bad argument #1 to 'setfenv'", 2)
	end

	local function safeGetmetatable(obj: any): any
		if type(obj) == "string" or Proxy.isProxy(obj) or protectedTables[obj] then
			if type(obj) == "string" then
				logger:log("sandbox", "getmetatable_string_probe", {}, true)
			end
			return "The metatable is locked"
		end
		return getmetatable(obj)
	end

	local function safeSetmetatable(tbl: any, mt: any): any
		if type(tbl) ~= "table" or protectedTables[tbl] then
			error("Cannot change a protected metatable", 2)
		end
		return setmetatable(tbl, mt)
	end

	local function safeTypeof(value: any): string
		local custom = Proxy.getTypeName(value)
		if custom then
			return custom
		end
		return type(value)
	end

	local function formatPrintArgs(...: any): string
		local args = table.pack(...)
		local parts = {}
		for i = 1, args.n do
			parts[i] = tostring(args[i])
		end
		return table.concat(parts, "\t")
	end

	-- Populate isolated sandbox environment
	sandboxEnv = {
		_VERSION = "Luau",
		_G = {},
		shared = {},

		assert = assert,
		error = error,
		ipairs = ipairs,
		next = next,
		pairs = pairs,
		pcall = pcall,
		xpcall = xpcall,
		select = select,
		tonumber = tonumber,
		tostring = tostring,
		type = type,
		typeof = safeTypeof,
		unpack = unpack,
		rawequal = rawequal,
		rawget = rawget,
		rawlen = rawlen,
		rawset = rawset,
		newproxy = newproxy,

		getmetatable = safeGetmetatable,
		setmetatable = safeSetmetatable,
		getfenv = safeGetfenv,
		setfenv = safeSetfenv,

		math = table.clone(math),
		bit32 = table.clone(bit32),
		coroutine = table.clone(coroutine),
		buffer = stringsHook.bufferLib,
		string = stringsHook.stringLib,
		table = stringsHook.tableLib,
		utf8 = stringsHook.utf8Lib,
		os = safeOs,
		debug = safeDebug,
		task = safeTask,

		wait = virtualWait,
		delay = safeTask.delay,
		spawn = safeTask.spawn,
		tick = function()
			return os.time() + virtualClock
		end,
		time = function()
			return virtualClock
		end,
		elapsedTime = function()
			return os.clock() + virtualClock
		end,

		print = function(...: any)
			local msg = formatPrintArgs(...)
			logger:log("output", "print", { message = msg })
			if not options.quietPrint then
				print("[sandbox]", msg)
			end
		end,
		warn = function(...: any)
			local msg = formatPrintArgs(...)
			logger:log("output", "warn", { message = msg })
			if not options.quietPrint then
				warn("[sandbox]", msg)
			end
		end,

		loadstring = loadstringHook.fn,
		load = loadstringHook.fn,
		require = insertMock.requireFn,

		game = gameEnv.game,
		Game = gameEnv.Game,
		workspace = gameEnv.workspace,
		Workspace = gameEnv.Workspace,
		Players = gameEnv.Players,
		script = gameEnv.script,
		Instance = gameEnv.Instance,
		Enum = gameEnv.Enum,
	}

	for dtName, dtVal in gameEnv.dataTypes do
		sandboxEnv[dtName] = dtVal
	end

	for k, v in sandboxEnv do
		if type(v) == "function" then
			hostFnNames[v] = k
		elseif type(v) == "table" and k ~= "_G" and k ~= "shared" then
			for mk, mv in v do
				if type(mv) == "function" then
					hostFnNames[mv] = mk
				end
			end
		end
	end

	-- Protect critical sandbox tables from metatable replacement and log missing global reads
	local missingGlobalsLogged: { [string]: boolean } = {}
	setmetatable(sandboxEnv, {
		__metatable = "The metatable is locked",
		__index = function(_t, key)
			local kStr = tostring(key)
			if not missingGlobalsLogged[kStr] then
				missingGlobalsLogged[kStr] = true
				logger:log("sandbox", "missing_global_read", { key = kStr })
			end
			return nil
		end,
	})
	protectedTables[sandboxEnv] = true
	protectedTables[sandboxEnv.string] = true
	protectedTables[sandboxEnv.table] = true
	protectedTables[sandboxEnv.buffer] = true
	protectedTables[sandboxEnv.os] = true
	protectedTables[sandboxEnv.debug] = true
	protectedTables[sandboxEnv.task] = true

	local instance = {}

	function instance.run(source: string, chunkName: string?): SandboxRunResult
		local startClock = os.clock()
		logger:setLayer(0)
		logger:log("sandbox", "start", {
			chunkName = chunkName or "sample",
			bytes = #source,
		}, true)

		local compileOk, bytecodeOrErr = pcall(luau.compile, source, {
			optimizationLevel = 1,
			coverageLevel = 0,
			debugLevel = 1,
		})
		if not compileOk then
			local errMsg = tostring(bytecodeOrErr)
			logger:log("sandbox", "compile_error", { error = errMsg }, true)
			logger:flush()
			return {
				ok = false,
				error = errMsg,
				layerCount = 0,
				totalLayerBytes = 0,
				layers = {},
				waitCount = waitCount,
				spawnCount = spawnCount,
				durationMs = (os.clock() - startClock) * 1000,
			}
		end

		local loadOk, fnOrErr = pcall(luau.load, bytecodeOrErr, {
			debugName = chunkName or "voidscope_entry",
			environment = sandboxEnv,
			injectGlobals = false,
			codegenEnabled = false,
		})
		if not loadOk then
			local errMsg = tostring(fnOrErr)
			logger:log("sandbox", "load_error", { error = errMsg }, true)
			logger:flush()
			return {
				ok = false,
				error = errMsg,
				layerCount = 0,
				totalLayerBytes = 0,
				layers = {},
				waitCount = waitCount,
				spawnCount = spawnCount,
				durationMs = (os.clock() - startClock) * 1000,
			}
		end

		local entryFn = fnOrErr :: () -> ()
		fnEnvs[entryFn] = sandboxEnv

		local running = true
		local flusherThread = task.spawn(function()
			while running do
				flushPendingLayers()
				logger:flush()
				task.wait(0.05)
			end
		end)

		local entryDone = false
		local execOk = false
		local execErr: any = nil
		local entryTask = task.spawn(function()
			local myThread = coroutine.running()
			logger:addSafeFlushThread(myThread)
			execOk, execErr = pcall(entryFn)
			logger:removeSafeFlushThread(myThread)
			entryDone = true
		end)
		local _ = entryTask

		local settleStart = os.clock()
		while not entryDone and (os.clock() - settleStart) < 5.0 do
			task.wait(0.01)
		end

		if entryDone and not execOk then
			logger:log("sandbox", "runtime_error", { error = tostring(execErr) }, true)
		elseif not entryDone then
			logger:log("sandbox", "entry_yield_timeout", {}, true)
		end

		-- Allow bounded spawned/delayed tasks to drain briefly before flushing
		local drainStart = os.clock()
		while activeTasks > 0 and (os.clock() - drainStart) < 0.5 do
			task.wait(0.01)
		end

		running = false
		pcall(task.cancel, flusherThread)

		stringsHook.flushBuffers()
		flushPendingLayers()
		logger:log("sandbox", "finish", {
			ok = execOk,
			layerCount = #loadstringHook.getLayers(),
			waitCount = waitCount,
			spawnCount = spawnCount,
		}, true)
		logger:flush()

		return {
			ok = execOk,
			error = if execOk then nil else tostring(execErr),
			layerCount = #loadstringHook.getLayers(),
			totalLayerBytes = loadstringHook.getTotalBytes(),
			layers = loadstringHook.getLayers(),
			waitCount = waitCount,
			spawnCount = spawnCount,
			durationMs = (os.clock() - startClock) * 1000,
		}
	end

	return instance
end

return Sandbox
