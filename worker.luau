--!strict
-- Child Lune worker process: runs exactly one sample inside the hardened sandbox.
-- Designed to be spawned and force-killed by main.luau if an infinite loop occurs,
-- while flushing logs and dumped layers incrementally to disk.

local DateTime = require("@lune/datetime")
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local Logger = require("./src/logger")
local Sandbox = require("./src/sandbox")

local function parseArgs(args: { string }): { [string]: any }
	local parsed: { [string]: any } = {
		outDir = "out",
		quiet = false,
	}
	local i = 1
	while i <= #args do
		local arg = args[i]
		if arg == "--sample" and args[i + 1] then
			parsed.sample = args[i + 1]
			i += 2
		elseif arg == "--out" and args[i + 1] then
			parsed.outDir = args[i + 1]
			i += 2
		elseif arg == "--c2-stub" and args[i + 1] then
			parsed.c2StubUrl = args[i + 1]
			i += 2
		elseif arg == "--max-layers" and args[i + 1] then
			parsed.maxLayers = tonumber(args[i + 1])
			i += 2
		elseif arg == "--max-waits" and args[i + 1] then
			parsed.maxWaits = tonumber(args[i + 1])
			i += 2
		elseif arg == "--client" then
			parsed.isClient = true
			i += 1
		elseif arg == "--quiet" then
			parsed.quiet = true
			i += 1
		else
			i += 1
		end
	end
	return parsed
end

local function ensureCleanLayersDir(layersDir: string)
	if fs.isDir(layersDir) then
		for _, entry in fs.readDir(layersDir) do
			local full = layersDir .. "/" .. entry
			if fs.isFile(full) then
				pcall(fs.removeFile, full)
			end
		end
	else
		fs.writeDir(layersDir)
	end
end

local function basename(path: string): string
	local name = string.match(path, "([^/\\]+)$")
	return name or path
end

local opts = parseArgs(process.args)
if not opts.sample or not fs.isFile(opts.sample) then
	stdio.ewrite("Usage: lune run worker.luau --sample <file> [--out <dir>] [--c2-stub <url>] [--max-layers N] [--max-waits N] [--quiet]\n")
	process.exit(2)
end

local samplePath: string = opts.sample
local outDir: string = opts.outDir
local layersDir = outDir .. "/layers"

if not fs.isDir(outDir) then
	fs.writeDir(outDir)
end
ensureCleanLayersDir(layersDir)

local source = fs.readFile(samplePath)
local sampleName = basename(samplePath)
local sampleSha256 = serde.hash("sha256", source)
local metaPath = outDir .. "/worker_meta.json"
local logsPath = outDir .. "/logs.json"

local function writeMeta(meta: { [string]: any })
	pcall(fs.writeFile, metaPath, serde.encode("json", meta, true))
end

writeMeta({
	status = "running",
	sample = sampleName,
	samplePath = samplePath,
	sampleSha256 = sampleSha256,
	startedAt = DateTime.now():toRfc3339(),
	ok = false,
	layerCount = 0,
	layers = {},
})

local logger = Logger.new({
	sampleName = sampleName,
	outputPath = logsPath,
	flushEvery = 20,
})

local sandbox = Sandbox.create({
	logger = logger,
	layersDir = layersDir,
	c2StubUrl = opts.c2StubUrl,
	quietPrint = opts.quiet,
	gameOptions = {
		isServer = not opts.isClient,
	},
	limits = {
		maxLayers = opts.maxLayers,
		maxWaits = opts.maxWaits,
	},
})

local result = sandbox.run(source, "voidscope_entry")
logger:flush()

writeMeta({
	status = if result.ok then "completed" else "error",
	sample = sampleName,
	samplePath = samplePath,
	sampleSha256 = sampleSha256,
	ok = result.ok,
	error = result.error,
	layerCount = result.layerCount,
	totalLayerBytes = result.totalLayerBytes,
	layers = result.layers,
	waitCount = result.waitCount,
	spawnCount = result.spawnCount,
	durationMs = result.durationMs,
	finishedAt = DateTime.now():toRfc3339(),
})

process.exit(0)
