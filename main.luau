--!strict
-- VoidScope entry point: spawns a killable worker Lune process per sample,
-- enforces wall-clock timeout, runs IOC extraction, C2 fingerprinting,
-- optional Roblox API intel enrichment, and generates JSON/Markdown reports.

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

local Extract = require("./src/iocs/extract")
local Fingerprint = require("./src/c2/fingerprint")
local StubServer = require("./src/c2/stub_server")
local RobloxApi = require("./src/intel/roblox_api")
local Report = require("./src/report")

local DEFAULT_TIMEOUT_SECONDS = 8

local function printUsage()
	stdio.write([[
VoidScope - Luau Backdoor Sandbox & IOC Analyzer

Usage:
  lune run main.luau [sample_file_or_dir] [options]

Options:
  --out <dir>         Output directory (default: out)
  --timeout <sec>     Per-sample worker timeout in seconds (default: 8)
  --c2-stub           Start local loopback C2 stub server for HTTP samples
  --intel             Query Roblox API to attribute extracted asset IDs
  --max-layers <n>    Override max loadstring layer limit
  --max-waits <n>     Override max virtual wait iteration limit
  --client            Emulate Roblox client (IsClient=true, Players.LocalPlayer set)
  --quiet             Suppress sandbox print/warn stdout chatter
  -h, --help          Show this help message
]])
end

local function parseArgs(args: { string })
	local opts: { [string]: any } = {
		target = nil,
		outDir = "out",
		timeout = DEFAULT_TIMEOUT_SECONDS,
		c2Stub = false,
		intel = false,
		quiet = false,
	}

	local i = 1
	while i <= #args do
		local arg = args[i]
		if arg == "-h" or arg == "--help" then
			opts.help = true
			i += 1
		elseif arg == "--out" and args[i + 1] then
			opts.outDir = args[i + 1]
			i += 2
		elseif arg == "--timeout" and args[i + 1] then
			opts.timeout = tonumber(args[i + 1]) or DEFAULT_TIMEOUT_SECONDS
			i += 2
		elseif arg == "--c2-stub" then
			opts.c2Stub = true
			i += 1
		elseif arg == "--intel" then
			opts.intel = true
			i += 1
		elseif arg == "--max-layers" and args[i + 1] then
			opts.maxLayers = tonumber(args[i + 1])
			i += 2
		elseif arg == "--max-waits" and args[i + 1] then
			opts.maxWaits = tonumber(args[i + 1])
			i += 2
		elseif arg == "--client" then
			opts.client = true
			i += 1
		elseif arg == "--quiet" then
			opts.quiet = true
			i += 1
		elseif string.sub(arg, 1, 1) ~= "-" and not opts.target then
			opts.target = arg
			i += 1
		else
			i += 1
		end
	end

	return opts
end

local function basename(path: string): string
	local name = string.match(path, "([^/\\]+)$")
	return name or path
end

local function stem(filename: string): string
	return (string.gsub(filename, "%.luau?$", ""))
end

local function resolveWorkerPath(): string
	if fs.isFile("worker.luau") then
		return "worker.luau"
	end
	local srcPath = debug.info(1, "s") or ""
	local dir = string.match(srcPath, "^(.+)[/\\][^/\\]+$")
	if dir and fs.isFile(dir .. "/worker.luau") then
		return dir .. "/worker.luau"
	end
	error("VoidScope: unable to locate worker.luau")
end

local function collectSamples(target: string?): { string }
	local resolved = target or "samples"
	if fs.isFile(resolved) then
		return { resolved }
	elseif fs.isDir(resolved) then
		local out: { string } = {}
		local entries = fs.readDir(resolved)
		table.sort(entries)
		for _, entry in entries do
			local full = resolved .. "/" .. entry
			if fs.isFile(full) and (string.match(entry, "%.luau$") or string.match(entry, "%.lua$")) then
				table.insert(out, full)
			end
		end
		return out
	end
	return {}
end

local function readJsonOrDefault(path: string, fallback: { [string]: any }): { [string]: any }
	if not fs.isFile(path) then
		return fallback
	end
	local ok, decoded = pcall(serde.decode, "json", fs.readFile(path))
	if ok and type(decoded) == "table" then
		return decoded
	end
	return fallback
end

local function readLayerFiles(layersDir: string): { { [string]: any } }
	if not fs.isDir(layersDir) then
		return {}
	end
	local files = fs.readDir(layersDir)
	table.sort(files)
	local out: { { [string]: any } } = {}
	for idx, fname in files do
		local fullPath = layersDir .. "/" .. fname
		if fs.isFile(fullPath) then
			local content = fs.readFile(fullPath)
			local idStr, depthStr = string.match(fname, "^layer_(%d+)_d(%d+)%.luau$")
			table.insert(out, {
				id = tonumber(idStr) or idx,
				depth = tonumber(depthStr) or 1,
				bytes = #content,
				sha256 = serde.hash("sha256", content),
				filePath = fullPath,
			})
		end
	end
	return out
end

local function analyzeOneSample(
	workerPath: string,
	samplePath: string,
	sampleOutDir: string,
	opts: { [string]: any },
	stubServer: StubServer.StubServerHandle?
)
	if not fs.isDir(sampleOutDir) then
		fs.writeDir(sampleOutDir)
	end

	local workerArgs = {
		"run",
		workerPath,
		"--sample",
		samplePath,
		"--out",
		sampleOutDir,
	}
	if stubServer then
		stubServer.clearRequests()
		table.insert(workerArgs, "--c2-stub")
		table.insert(workerArgs, stubServer.url)
	end
	if opts.maxLayers then
		table.insert(workerArgs, "--max-layers")
		table.insert(workerArgs, tostring(opts.maxLayers))
	end
	if opts.maxWaits then
		table.insert(workerArgs, "--max-waits")
		table.insert(workerArgs, tostring(opts.maxWaits))
	end
	if opts.client then
		table.insert(workerArgs, "--client")
	end
	if opts.quiet then
		table.insert(workerArgs, "--quiet")
	end

	local child = process.create("lune", workerArgs)

	local stdoutChunks: { string } = {}
	local stderrChunks: { string } = {}
	task.spawn(function()
		local ok, data = pcall(function()
			return child.stdout:readToEnd()
		end)
		if ok and data and #data > 0 then
			table.insert(stdoutChunks, data)
		end
	end)
	task.spawn(function()
		local ok, data = pcall(function()
			return child.stderr:readToEnd()
		end)
		if ok and data and #data > 0 then
			table.insert(stderrChunks, data)
		end
	end)

	local finished = false
	local statusResult: { ok: boolean, code: number }? = nil
	task.spawn(function()
		statusResult = child:status()
		finished = true
	end)

	local timeoutSec = math.max(opts.timeout or DEFAULT_TIMEOUT_SECONDS, 0.2)
	local deadline = os.clock() + timeoutSec
	while not finished and os.clock() < deadline do
		task.wait(0.05)
	end

	local timedOut = false
	if not finished then
		timedOut = true
		pcall(function()
			child:kill()
		end)
		task.wait(0.1)
	end

	if not opts.quiet and #stdoutChunks > 0 then
		stdio.write(table.concat(stdoutChunks))
	end
	if not opts.quiet and #stderrChunks > 0 then
		stdio.ewrite(table.concat(stderrChunks))
	end

	local sampleSource = fs.readFile(samplePath)
	local sampleName = basename(samplePath)
	local sampleSha256 = serde.hash("sha256", sampleSource)

	local logData = readJsonOrDefault(sampleOutDir .. "/logs.json", {
		sample = sampleName,
		totalEntries = 0,
		entries = {},
	})
	local workerMeta = readJsonOrDefault(sampleOutDir .. "/worker_meta.json", {
		status = if timedOut then "timeout" else "unknown",
		durationMs = timeoutSec * 1000,
	})
	if timedOut then
		workerMeta.status = "timeout"
		workerMeta.timedOut = true
		pcall(fs.writeFile, sampleOutDir .. "/worker_meta.json", serde.encode("json", workerMeta, true))
	end

	local layersDir = sampleOutDir .. "/layers"
	local layers = if type(workerMeta.layers) == "table" and #workerMeta.layers > 0
		then workerMeta.layers
		else readLayerFiles(layersDir)

	local logEntries = logData.entries or {}
	local iocs = Extract.extract({
		sampleSource = sampleSource,
		sampleName = sampleName,
		layers = layers,
		layersDir = layersDir,
		logEntries = logEntries,
	})
	local c2Fingerprint = Fingerprint.analyze(logEntries)
	local intelReport = RobloxApi.enrichAssets(iocs.assetIds, {
		enabled = opts.intel == true,
	})

	local reportRes = Report.writeOutputs(sampleOutDir, {
		sampleName = sampleName,
		samplePath = samplePath,
		sampleSha256 = sampleSha256,
		timedOut = timedOut,
		workerOk = if statusResult then statusResult.ok else false,
		workerCode = if statusResult then statusResult.code else nil,
		workerMeta = workerMeta,
		logData = logData,
		iocs = iocs,
		c2Fingerprint = c2Fingerprint,
		intelReport = intelReport,
		layers = layers,
		c2StubRequests = if stubServer then stubServer.getRequests() else nil,
	})

	return {
		sampleName = sampleName,
		outDir = sampleOutDir,
		verdict = reportRes.verdict,
		timedOut = timedOut,
		layers = #layers,
		events = #logEntries,
		iocs = iocs.totalUnique,
		reportPath = reportRes.reportPath,
	}
end

local opts = parseArgs(process.args)
if opts.help then
	printUsage()
	process.exit(0)
end

local samples = collectSamples(opts.target)
if #samples == 0 then
	stdio.ewrite("No .luau/.lua samples found in '" .. tostring(opts.target or "samples") .. "'.\n")
	printUsage()
	process.exit(1)
end

local workerPath = resolveWorkerPath()
local stubServer: StubServer.StubServerHandle? = nil
if opts.c2Stub then
	stubServer = StubServer.start()
	stdio.write(string.format("[VoidScope] Local C2 stub server listening at %s\n", (stubServer :: StubServer.StubServerHandle).url))
end

local batchMode = #samples > 1
local summaries = {}

local okRun, runErr = pcall(function()
	for _, samplePath in samples do
		local sampleOutDir = if batchMode
			then opts.outDir .. "/" .. stem(basename(samplePath))
			else opts.outDir
		local res = analyzeOneSample(workerPath, samplePath, sampleOutDir, opts, stubServer)
		table.insert(summaries, res)
		stdio.write(string.format(
			"[VoidScope] %s -> verdict=%s layers=%d events=%d iocs=%d timedOut=%s (%s)\n",
			res.sampleName,
			res.verdict,
			res.layers,
			res.events,
			res.iocs,
			tostring(res.timedOut),
			res.reportPath
		))
	end

	if batchMode then
		local sumLines = { "# VoidScope Batch Summary", "" }
		table.insert(sumLines, "| Sample | Verdict | Layers | Events | IOCs | Timed Out | Report |")
		table.insert(sumLines, "| :--- | :--- | ---: | ---: | ---: | :--- | :--- |")
		for _, res in summaries do
			table.insert(sumLines, string.format(
				"| `%s` | **%s** | %d | %d | %d | %s | `%s` |",
				res.sampleName,
				res.verdict,
				res.layers,
				res.events,
				res.iocs,
				tostring(res.timedOut),
				res.reportPath
			))
		end
		table.insert(sumLines, "")
		if not fs.isDir(opts.outDir) then
			fs.writeDir(opts.outDir)
		end
		fs.writeFile(opts.outDir .. "/summary.md", table.concat(sumLines, "\n"))
	end
end)

if stubServer then
	stubServer.stop()
end

if not okRun then
	stdio.ewrite("[VoidScope] Fatal error: " .. tostring(runErr) .. "\n")
	process.exit(1)
end

process.exit(0)
