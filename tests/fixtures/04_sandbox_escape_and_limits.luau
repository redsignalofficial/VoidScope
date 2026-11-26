-- Fixture 4: Probes sandbox isolation & resource limits safely.
local results = {}

-- 1. Attempt getfenv(0) / getfenv(2) / out-of-range getfenv(-1, 999) escape
local env0 = getfenv(0)
local env2 = getfenv(2)
local okNeg = pcall(getfenv, -1)
local okHigh, envHigh = pcall(getfenv, 999)
results.hasOsExecute = env0.os and env0.os.execute ~= nil
results.hasProcess = env0.process ~= nil or env2.process ~= nil or (okHigh and type(envHigh) == "table" and envHigh.process ~= nil) or false
results.hasFs = env0.fs ~= nil
assert(not okNeg and not okHigh, "Out-of-range getfenv levels must throw")

-- 2. Nested sandbox function setfenv(1, ...) allowed; setfenv(0) and high-level frames blocked
local function nestedCustom()
	setfenv(1, setmetatable({ customMarker = "inside_sandbox" }, { __index = getfenv(0) }))
	return customMarker
end
results.nestedSetfenvOk = nestedCustom() == "inside_sandbox"
local okSet0 = pcall(function()
	setfenv(0, {})
end)
local okSet10 = pcall(function()
	setfenv(10, {})
end)
results.setfenvEscapeBlocked = (not okSet0) and (not okSet10)

-- 3. debug.info high stack frame does not leak host paths
local dbgSrc = debug.info(10, "s")
results.debugSafe = dbgSrc == "[sandbox]" or dbgSrc == "[C]"

-- 4. Attempt string metatable inspection/tampering
local strMt = getmetatable("")
results.strMt = strMt

-- 5. Attempt calling Lune stdlib via require
local luneFs = require("@lune/fs")
results.luneFsIsReal = type(luneFs) == "table" and type(luneFs.readFile) == "function" and luneFs.readFile == nil

-- 6. Attempt memory DoS via huge string.rep
local okRep, errRep = pcall(function()
	return string.rep("A", 50000000)
end)
results.repBlocked = not okRep
results.repErr = tostring(errRep)

-- 7. Attempt excessive loadstring recursion/layers (sandbox configured with low cap in tests)
local layerLimitHit = false
for i = 1, 20 do
	local fn, err = loadstring("local x = " .. tostring(i), "loop_" .. tostring(i))
	if not fn then
		layerLimitHit = true
		results.layerErr = err
		break
	end
	fn()
end
results.layerLimitHit = layerLimitHit

-- 8. typeof check on Roblox mock types
results.gameType = typeof(game)
results.vecType = typeof(Vector3.new(1, 2, 3))

print(table.concat({
	"escape_probe_summary",
	"hasOsExecute=" .. tostring(results.hasOsExecute),
	"hasProcess=" .. tostring(results.hasProcess),
	"hasFs=" .. tostring(results.hasFs),
	"nestedSetfenvOk=" .. tostring(results.nestedSetfenvOk),
	"setfenvEscapeBlocked=" .. tostring(results.setfenvEscapeBlocked),
	"debugSafe=" .. tostring(results.debugSafe),
	"strMt=" .. tostring(results.strMt),
	"luneFsIsReal=" .. tostring(results.luneFsIsReal),
	"repBlocked=" .. tostring(results.repBlocked),
	"layerLimitHit=" .. tostring(results.layerLimitHit),
	"gameType=" .. tostring(results.gameType),
	"vecType=" .. tostring(results.vecType),
}, "|"))
