--!strict
-- End-to-end verification suite for VoidScope.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local Logger = require("../src/logger")
local Sandbox = require("../src/sandbox")
local Extract = require("../src/iocs/extract")
local Fingerprint = require("../src/c2/fingerprint")
local StubServer = require("../src/c2/stub_server")
local RobloxApi = require("../src/intel/roblox_api")
local Report = require("../src/report")

local passed = 0
local failed = 0

local function assertTrue(cond: any, msg: string)
	if not cond then
		error("ASSERTION FAILED: " .. msg, 2)
	end
end

local function assertEq(actual: any, expected: any, msg: string)
	if actual ~= expected then
		error(string.format("ASSERTION FAILED (%s): expected %s, got %s", msg, tostring(expected), tostring(actual)), 2)
	end
end

local function runTest(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		stdio.write("[PASS] " .. name .. "\n")
	else
		failed += 1
		stdio.ewrite("[FAIL] " .. name .. " -> " .. tostring(err) .. "\n")
	end
end

local TEST_TMP = "out/_test_tmp"
if fs.isDir(TEST_TMP) then
	fs.removeDir(TEST_TMP)
end
fs.writeDir(TEST_TMP)

local function makeTestDirs(sub: string): (string, string)
	local dir = TEST_TMP .. "/" .. sub
	local layers = dir .. "/layers"
	fs.writeDir(dir)
	fs.writeDir(layers)
	return dir, layers
end

-- 1. Fixture 1: Layered loadstring + string hooks + IOC extraction
runTest("Fixture 01: layered loadstring dump & string hooks", function()
	local dir, layersDir = makeTestDirs("f01")
	local logger = Logger.new({ sampleName = "01_layered_loadstring.luau", outputPath = dir .. "/logs.json" })
	local sb = Sandbox.create({ logger = logger, layersDir = layersDir, quietPrint = true })

	local src = fs.readFile("tests/fixtures/01_layered_loadstring.luau")
	local res = sb.run(src, "voidscope_entry")
	assertTrue(res.ok, "Fixture 01 should run cleanly: " .. tostring(res.error))
	assertEq(res.layerCount, 2, "Expected 2 dumped loadstring layers")
	assertTrue(fs.isFile(layersDir .. "/layer_0001_d1.luau"), "Layer 1 file missing")
	assertTrue(fs.isFile(layersDir .. "/layer_0002_d2.luau"), "Layer 2 file missing")

	local iocs = Extract.extract({
		sampleSource = src,
		sampleName = "01_layered_loadstring.luau",
		layers = res.layers,
		layersDir = layersDir,
		logEntries = logger:getEntries(),
	})

	assertTrue(#iocs.webhooks >= 1, "Expected decoded Discord webhook IOC")
	assertTrue(table.find(iocs.assetIds, 456789123) ~= nil, "Expected require asset ID 456789123")
	assertTrue(#iocs.urls >= 1, "Expected reversed URL IOC")
end)

-- 2. Fixture 2: Local C2 stub server + HTTP beaconing + C2 fingerprint
runTest("Fixture 02: local C2 stub server & fingerprinting", function()
	local dir, layersDir = makeTestDirs("f02")
	local stub = StubServer.start({ port = 18520 })
	local okTest, errTest = pcall(function()
		local logger = Logger.new({ sampleName = "02_http_c2_beacon.luau", outputPath = dir .. "/logs.json" })
		local sb = Sandbox.create({
			logger = logger,
			layersDir = layersDir,
			c2StubUrl = stub.url,
			quietPrint = true,
		})

		local src = fs.readFile("tests/fixtures/02_http_c2_beacon.luau")
		local res = sb.run(src, "voidscope_entry")
		assertTrue(res.ok, "Fixture 02 should succeed: " .. tostring(res.error))
		assertEq(res.layerCount, 3, "Expected 3 loadstring layers from C2 stub commands")

		local stubReqs = stub.getRequests()
		assertEq(#stubReqs, 3, "Stub server should receive 3 forwarded HTTP polls")

		local fp = Fingerprint.analyze(logger:getEntries())
		assertEq(fp.requestCount, 3, "Expected 3 HTTP requests in fingerprint")
		assertTrue(fp.beaconingDetected, "Expected beaconingDetected = true")
		assertEq(fp.estimatedPollIntervalSeconds, 15, "Expected 15s virtual poll interval")
		assertTrue(table.find(fp.userAgents, "VoidBeacon/2.1") ~= nil, "Expected User-Agent VoidBeacon/2.1")
		assertTrue(#fp.authKeys >= 3, "Expected auth keys extracted from query, headers, and body")
	end)
	stub.stop()
	if not okTest then
		error(errTest)
	end
end)

-- 3. Fixture 3: Roblox service mocks & proxy fallback
runTest("Fixture 03: Roblox services & recursive proxy", function()
	local dir, layersDir = makeTestDirs("f03")
	local logger = Logger.new({ sampleName = "03_roblox_services.luau", outputPath = dir .. "/logs.json" })
	local sb = Sandbox.create({ logger = logger, layersDir = layersDir, quietPrint = true })

	local src = fs.readFile("tests/fixtures/03_roblox_services.luau")
	local res = sb.run(src, "voidscope_entry")
	assertTrue(res.ok, "Fixture 03 should succeed: " .. tostring(res.error))

	local iocs = Extract.extract({
		sampleSource = src,
		sampleName = "03_roblox_services.luau",
		logEntries = logger:getEntries(),
	})

	assertTrue(table.find(iocs.assetIds, 777888999) ~= nil, "Missing require asset 777888999")
	assertTrue(table.find(iocs.assetIds, 112233445) ~= nil, "Missing InsertService asset 112233445")
	assertTrue(table.find(iocs.assetIds, 998877665) ~= nil, "Missing Marketplace asset 998877665")
	assertTrue(table.find(iocs.placeIds, 666555444) ~= nil, "Missing Teleport place 666555444")
	assertTrue(table.find(iocs.placeIds, 333222111) ~= nil, "Missing Teleport place 333222111")
	assertTrue(table.find(iocs.groupIds, 424242) ~= nil, "Missing GroupId 424242")
	assertTrue(#iocs.webhooks >= 1, "Missing DataStore webhook IOC")
end)

-- 4. Fixture 4: Sandbox escape defenses & limits
runTest("Fixture 04: anti-escape defenses & resource limits", function()
	local dir, layersDir = makeTestDirs("f04")
	local logger = Logger.new({ sampleName = "04_sandbox_escape_and_limits.luau", outputPath = dir .. "/logs.json" })
	local sb = Sandbox.create({
		logger = logger,
		layersDir = layersDir,
		quietPrint = true,
		limits = {
			maxLayers = 5,
			maxRepBytes = 1024 * 1024,
		},
	})

	local src = fs.readFile("tests/fixtures/04_sandbox_escape_and_limits.luau")
	local res = sb.run(src, "voidscope_entry")
	assertTrue(res.ok, "Fixture 04 should complete safely: " .. tostring(res.error))
	assertEq(res.layerCount, 5, "Expected maxLayers=5 cap enforced")

	local sawEscapeProbe = false
	local sawLimit = false
	local sawPrint = false
	for _, entry in logger:getEntries() do
		if entry.category == "sandbox" and entry.action == "getfenv_stack_probe" then
			sawEscapeProbe = true
		elseif entry.category == "limit" then
			sawLimit = true
		elseif entry.category == "output" and entry.action == "print" then
			sawPrint = true
			local msg = tostring(entry.detail.message)
			assertTrue(string.find(msg, "hasOsExecute=false", 1, true) ~= nil, "os.execute must not exist")
			assertTrue(string.find(msg, "hasProcess=false", 1, true) ~= nil, "process global must not exist")
			assertTrue(string.find(msg, "hasFs=false", 1, true) ~= nil, "fs global must not exist")
			assertTrue(string.find(msg, "nestedSetfenvOk=true", 1, true) ~= nil, "nested sandbox setfenv should work")
			assertTrue(string.find(msg, "setfenvEscapeBlocked=true", 1, true) ~= nil, "setfenv escape must be blocked")
			assertTrue(string.find(msg, "debugSafe=true", 1, true) ~= nil, "debug.info must not leak host path")
			assertTrue(string.find(msg, "strMt=The metatable is locked", 1, true) ~= nil, "String metatable should be locked")
			assertTrue(string.find(msg, "luneFsIsReal=false", 1, true) ~= nil, "require('@lune/fs') must be mocked")
			assertTrue(string.find(msg, "repBlocked=true", 1, true) ~= nil, "Huge string.rep must be blocked")
			assertTrue(string.find(msg, "layerLimitHit=true", 1, true) ~= nil, "Excessive loadstring layers must be blocked")
			assertTrue(string.find(msg, "gameType=Instance", 1, true) ~= nil, "typeof(game) should be Instance")
			assertTrue(string.find(msg, "vecType=Vector3", 1, true) ~= nil, "typeof(Vector3) should be Vector3")
		end
	end
	assertTrue(sawEscapeProbe, "Expected getfenv stack probe logged")
	assertTrue(sawLimit, "Expected resource limit event logged")
	assertTrue(sawPrint, "Expected summary print event")
end)

-- 5. Intel module (Roblox API attribution) with mock fetcher
runTest("Roblox API intel enrichment (mocked fetcher)", function()
	local mockFetcher = function(url: string)
		if string.find(url, "economy.roblox.com/v2/assets/123456/details", 1, true) then
			return {
				ok = true,
				statusCode = 200,
				body = serde.encode("json", {
					Name = "TotallyNormalScript",
					Description = "Not a backdoor",
					AssetTypeId = 10,
					Creator = {
						CreatorType = "User",
						CreatorTargetId = 777111,
						Name = "SuspectDev",
					},
				}),
			}
		elseif string.find(url, "users.roblox.com/v1/users/777111", 1, true) then
			return {
				ok = true,
				statusCode = 200,
				body = serde.encode("json", {
					name = "SuspectDev",
					displayName = "SusDev",
					isBanned = false,
				}),
			}
		end
		return { ok = false, statusCode = 404, body = "{}" }
	end

	local intel = RobloxApi.enrichAssets({ 123456 }, {
		enabled = true,
		fetcher = mockFetcher,
	})
	assertEq(intel.queriedCount, 1, "Expected 1 asset queried")
	assertTrue(intel.assets[1].ok, "Asset lookup should succeed")
	assertEq(intel.assets[1].name, "TotallyNormalScript", "Asset name mismatch")
	assertEq((intel.assets[1].creator :: any).username, "SuspectDev", "Creator username mismatch")
end)

-- 6. End-to-end main.luau worker spawn + timeout kill on infinite loop
runTest("Fixture 05: main.luau spawns killable worker & enforces timeout", function()
	local outDir = TEST_TMP .. "/f05_main"
	local res = process.exec("lune", {
		"run",
		"main.luau",
		"tests/fixtures/05_infinite_loop.luau",
		"--out",
		outDir,
		"--timeout",
		"1.2",
		"--quiet",
	})
	assertTrue(res.ok, "main.luau should handle worker timeout gracefully: " .. res.stderr)
	assertTrue(fs.isFile(outDir .. "/logs.json"), "logs.json should exist after timeout kill")
	assertTrue(fs.isFile(outDir .. "/iocs.json"), "iocs.json should exist after timeout kill")
	assertTrue(fs.isFile(outDir .. "/report.md"), "report.md should exist after timeout kill")

	local iocsData = serde.decode("json", fs.readFile(outDir .. "/iocs.json"))
	local reportMd = fs.readFile(outDir .. "/report.md")
	assertTrue(string.find(reportMd, "timedOut=true", 1, true) ~= nil, "report.md should record timedOut=true")
	assertTrue(string.find(reportMd, "555666777888", 1, true) ~= nil, "Partial webhook IOC before loop should be in report.md")
	assertTrue((iocsData.totalUnique or 0) >= 1, "Expected partial IOC extracted from flushed logs")
end)

-- 7. End-to-end main.luau on samples/demo_backdoor.luau with --c2-stub
runTest("End-to-end main.luau on demo_backdoor.luau with --c2-stub", function()
	local outDir = TEST_TMP .. "/demo_main"
	local res = process.exec("lune", {
		"run",
		"main.luau",
		"samples/demo_backdoor.luau",
		"--out",
		outDir,
		"--c2-stub",
		"--quiet",
	})
	assertTrue(res.ok, "main.luau demo run failed: " .. res.stderr)
	assertTrue(fs.isFile(outDir .. "/layers/layer_0001_d1.luau"), "Expected dumped layer 1")
	assertTrue(fs.isFile(outDir .. "/logs.json"), "Expected logs.json")
	assertTrue(fs.isFile(outDir .. "/iocs.json"), "Expected iocs.json")
	assertTrue(fs.isFile(outDir .. "/report.md"), "Expected report.md")
end)

fs.removeDir(TEST_TMP)

stdio.write(string.format("\nTests finished: %d passed, %d failed\n", passed, failed))
if failed > 0 then
	process.exit(1)
end
process.exit(0)
