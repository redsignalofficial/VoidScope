--!strict
-- Hooks loadstring / load inside the sandbox: validates size & depth limits,
-- dumps every decoded layer to out/layers/, compiles via Luau source compiler
-- (blocking raw bytecode injection), and recurses inside the sandboxed environment.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local LoadstringHook = {}

export type LayerRecord = {
	id: number,
	depth: number,
	parentId: number,
	chunkName: string,
	bytes: number,
	sha256: string,
	filePath: string,
}

export type LoadstringOptions = {
	layersDir: string,
	maxLayers: number?,
	maxLayerBytes: number?,
	maxTotalBytes: number?,
	onLayerDump: ((filePath: string, content: string) -> ())?,
}

export type SandboxBridge = {
	getEnv: () -> { [string]: any },
	registerFunction: (fn: (...any) -> ...any, env: { [string]: any }) -> (),
}

export type LoadstringHandle = {
	fn: (code: any, chunkName: string?) -> ((...any) -> ...any?, string?),
	getLayers: () -> { LayerRecord },
	getTotalBytes: () -> number,
	getCurrentDepth: () -> number,
}

local DEFAULT_MAX_LAYERS = 64
local DEFAULT_MAX_LAYER_BYTES = 2 * 1024 * 1024
local DEFAULT_MAX_TOTAL_BYTES = 16 * 1024 * 1024

local function ensureDir(path: string)
	if not fs.isDir(path) then
		fs.writeDir(path)
	end
end

function LoadstringHook.create(logger: any, bridge: SandboxBridge, options: LoadstringOptions): LoadstringHandle
	local layersDir = options.layersDir
	local maxLayers = options.maxLayers or DEFAULT_MAX_LAYERS
	local maxLayerBytes = options.maxLayerBytes or DEFAULT_MAX_LAYER_BYTES
	local maxTotalBytes = options.maxTotalBytes or DEFAULT_MAX_TOTAL_BYTES

	local layers: { LayerRecord } = {}
	local totalBytes = 0
	local depthStack: { number } = {}
	local layerStack: { number } = {}

	local function currentDepth(): number
		return depthStack[#depthStack] or 0
	end

	local function currentLayerId(): number
		return layerStack[#layerStack] or 0
	end

	local function hookedLoadstring(code: any, chunkName: string?): ((...any) -> ...any?, string?)
		if type(code) ~= "string" then
			return nil, "bad argument #1 to 'loadstring' (string expected, got " .. type(code) .. ")"
		end

		local size = #code
		if size > maxLayerBytes then
			logger:log("limit", "loadstring_layer_bytes_exceeded", {
				bytes = size,
				maxLayerBytes = maxLayerBytes,
			}, true)
			return nil, "VoidScope: loadstring payload exceeds maxLayerBytes"
		end

		if #layers >= maxLayers then
			logger:log("limit", "loadstring_max_layers_exceeded", {
				layerCount = #layers,
				maxLayers = maxLayers,
			}, true)
			return nil, "VoidScope: max loadstring layers exceeded"
		end

		if totalBytes + size > maxTotalBytes then
			logger:log("limit", "loadstring_total_bytes_exceeded", {
				totalBytes = totalBytes + size,
				maxTotalBytes = maxTotalBytes,
			}, true)
			return nil, "VoidScope: total dumped layer bytes exceeded"
		end

		local layerId = #layers + 1
		local depth = currentDepth() + 1
		local parentId = currentLayerId()
		local name = if type(chunkName) == "string" and #chunkName > 0
			then chunkName
			else ("layer_" .. tostring(layerId))

		totalBytes += size
		local sha256 = serde.hash("sha256", code)
		local filePath = string.format("%s/layer_%04d_d%d.luau", layersDir, layerId, depth)
		if options.onLayerDump then
			options.onLayerDump(filePath, code)
		else
			ensureDir(layersDir)
			fs.writeFile(filePath, code)
		end

		local record: LayerRecord = {
			id = layerId,
			depth = depth,
			parentId = parentId,
			chunkName = name,
			bytes = size,
			sha256 = sha256,
			filePath = filePath,
		}
		table.insert(layers, record)

		logger:log("loadstring", "dump", {
			layerId = layerId,
			depth = depth,
			parentId = parentId,
			chunkName = name,
			bytes = size,
			sha256 = sha256,
			filePath = filePath,
		}, true)

		-- Compile source text first so raw Luau bytecode cannot be passed into luau.load.
		local compileOk, compiledOrErr = pcall(luau.compile, code, {
			optimizationLevel = 1,
			coverageLevel = 0,
			debugLevel = 1,
		})
		if not compileOk then
			logger:log("loadstring", "compile_error", {
				layerId = layerId,
				error = tostring(compiledOrErr),
			})
			return nil, tostring(compiledOrErr)
		end

		local env = bridge.getEnv()
		local loadOk, chunkOrErr = pcall(luau.load, compiledOrErr, {
			debugName = string.format("voidscope_layer_%04d", layerId),
			environment = env,
			injectGlobals = false,
			codegenEnabled = false,
		})
		if not loadOk then
			logger:log("loadstring", "load_error", {
				layerId = layerId,
				error = tostring(chunkOrErr),
			})
			return nil, tostring(chunkOrErr)
		end

		local loadedFn = chunkOrErr :: (...any) -> ...any
		bridge.registerFunction(loadedFn, env)

		local wrappedFn = function(...: any): ...any
			table.insert(depthStack, depth)
			table.insert(layerStack, layerId)
			local prevLayer = logger:getLayer()
			logger:setLayer(layerId)
			logger:log("loadstring", "exec_start", {
				layerId = layerId,
				depth = depth,
			})

			local res = table.pack(pcall(loadedFn, ...))

			logger:setLayer(prevLayer)
			table.remove(layerStack)
			table.remove(depthStack)

			if not res[1] then
				logger:log("loadstring", "exec_error", {
					layerId = layerId,
					depth = depth,
					error = tostring(res[2]),
				})
				error(res[2], 0)
			end

			logger:log("loadstring", "exec_end", {
				layerId = layerId,
				depth = depth,
			})
			return table.unpack(res, 2, res.n)
		end

		bridge.registerFunction(wrappedFn, env)
		return wrappedFn, nil
	end

	return {
		fn = hookedLoadstring,
		getLayers = function()
			return layers
		end,
		getTotalBytes = function()
			return totalBytes
		end,
		getCurrentDepth = currentDepth,
	}
end

return LoadstringHook
