--!strict
-- Structured, bounded, incrementally flushable event logger for VoidScope.

local DateTime = require("@lune/datetime")
local fs = require("@lune/fs")
local serde = require("@lune/serde")

export type LogEntry = {
	seq: number,
	timestampMs: number,
	isoTime: string,
	layer: number,
	category: string,
	action: string,
	detail: { [string]: any },
}

export type LoggerOptions = {
	maxEntries: number?,
	maxFieldLen: number?,
	outputPath: string?,
	flushEvery: number?,
	sampleName: string?,
}

local DEFAULT_MAX_ENTRIES = 5000
local DEFAULT_MAX_FIELD_LEN = 4096
local DEFAULT_FLUSH_EVERY = 20

local Logger = {}
Logger.__index = Logger

export type Logger = typeof(setmetatable(
	{} :: {
		_entries: { LogEntry },
		_seq: number,
		_dropped: number,
		_startClock: number,
		_currentLayer: number,
		_maxEntries: number,
		_maxFieldLen: number,
		_outputPath: string?,
		_flushEvery: number,
		_sinceFlush: number,
		_sampleName: string,
		_safeFlushThreads: { [thread]: boolean },
	},
	Logger
))

local function truncateString(str: string, maxLen: number): any
	if #str <= maxLen then
		return str
	end
	return {
		truncated = true,
		originalLength = #str,
		preview = string.sub(str, 1, maxLen),
	}
end

local function isDenseArray(tbl: { [any]: any }): (boolean, number)
	local count = 0
	local maxIndex = 0
	for k in tbl do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
			return false, 0
		end
		count += 1
		if k > maxIndex then
			maxIndex = k
		end
	end
	if count == 0 then
		return true, 0
	end
	return count == maxIndex, maxIndex
end

-- Converts arbitrary Luau values (circular tables, NaN/Inf, functions, userdata, buffers)
-- into strictly JSON-serializable values so log serialization can never fail.
local function sanitizeValue(value: any, maxFieldLen: number, depth: number, seen: { [any]: boolean }): any
	local valueType = type(value)

	if value == nil or valueType == "boolean" then
		return value
	elseif valueType == "number" then
		if value ~= value then
			return "NaN"
		elseif value == math.huge then
			return "Infinity"
		elseif value == -math.huge then
			return "-Infinity"
		end
		return value
	elseif valueType == "string" then
		return truncateString(value, maxFieldLen)
	elseif valueType == "buffer" then
		local ok, str = pcall(buffer.tostring, value)
		return {
			_type = "buffer",
			len = buffer.len(value),
			preview = if ok then truncateString(str, math.min(maxFieldLen, 512)) else "<unreadable>",
		}
	elseif valueType == "function" or valueType == "thread" or valueType == "userdata" then
		local ok, text = pcall(tostring, value)
		return if ok then text else ("<" .. valueType .. ">")
	elseif valueType == "table" then
		if seen[value] then
			return "<circular>"
		end
		if depth >= 6 then
			return "<max_depth>"
		end
		seen[value] = true

		local dense, maxIdx = isDenseArray(value)
		local out: { [any]: any } = {}
		if dense then
			for i = 1, math.min(maxIdx, 200) do
				out[i] = sanitizeValue(value[i], maxFieldLen, depth + 1, seen)
			end
			if maxIdx > 200 then
				out[201] = string.format("<... %d more items>", maxIdx - 200)
			end
		else
			local keyCount = 0
			for k, v in value do
				keyCount += 1
				if keyCount > 200 then
					out["__truncated_keys"] = true
					break
				end
				local keyStr = tostring(k)
				out[keyStr] = sanitizeValue(v, maxFieldLen, depth + 1, seen)
			end
		end

		seen[value] = nil
		return out
	end

	return tostring(value)
end

function Logger.new(options: LoggerOptions?): Logger
	local opts = options or {}
	local self = setmetatable({
		_entries = {},
		_seq = 0,
		_dropped = 0,
		_startClock = os.clock(),
		_currentLayer = 0,
		_maxEntries = opts.maxEntries or DEFAULT_MAX_ENTRIES,
		_maxFieldLen = opts.maxFieldLen or DEFAULT_MAX_FIELD_LEN,
		_outputPath = opts.outputPath,
		_flushEvery = opts.flushEvery or DEFAULT_FLUSH_EVERY,
		_sinceFlush = 0,
		_sampleName = opts.sampleName or "unknown",
		_safeFlushThreads = {},
	}, Logger)
	return self
end

function Logger:addSafeFlushThread(th: thread)
	self._safeFlushThreads[th] = true
end

function Logger:removeSafeFlushThread(th: thread)
	self._safeFlushThreads[th] = nil
end

function Logger:setLayer(layerId: number)
	self._currentLayer = layerId
end

function Logger:getLayer(): number
	return self._currentLayer
end

function Logger:log(category: string, action: string, data: { [string]: any }?, critical: boolean?)
	if #self._entries >= self._maxEntries then
		self._dropped += 1
		return
	end

	self._seq += 1
	local elapsedMs = math.floor((os.clock() - self._startClock) * 100000) / 100
	local detail = if data ~= nil
		then sanitizeValue(data, self._maxFieldLen, 0, {})
		else {}

	if type(detail) ~= "table" then
		detail = { value = detail }
	end

	local entry: LogEntry = {
		seq = self._seq,
		timestampMs = elapsedMs,
		isoTime = DateTime.now():toRfc3339(),
		layer = self._currentLayer,
		category = category,
		action = action,
		detail = detail,
	}

	table.insert(self._entries, entry)
	self._sinceFlush += 1

	-- Only flush inline when running directly on a registered Lune scheduler thread
	-- (never inside a user coroutine.create or proxy metamethod, since fs.writeFile yields).
	if self._outputPath
		and self._safeFlushThreads[coroutine.running()] == true
		and category ~= "proxy"
		and (critical == true or self._sinceFlush >= self._flushEvery)
	then
		self:flush()
	end
end

function Logger:getEntries(): { LogEntry }
	return self._entries
end

function Logger:count(): number
	return #self._entries
end

function Logger:droppedCount(): number
	return self._dropped
end

function Logger:toPayload(): { [string]: any }
	return {
		sample = self._sampleName,
		totalEntries = #self._entries,
		droppedEntries = self._dropped,
		generatedAt = DateTime.now():toRfc3339(),
		entries = self._entries,
	}
end

function Logger:toJson(pretty: boolean?): string
	local usePretty = if pretty == nil then true else pretty
	return serde.encode("json", self:toPayload(), usePretty)
end

function Logger:flush(): boolean
	if not self._outputPath then
		return false
	end
	local ok, encoded = pcall(function()
		return self:toJson(true)
	end)
	if not ok then
		return false
	end
	local writeOk = pcall(fs.writeFile, self._outputPath, encoded)
	if writeOk then
		self._sinceFlush = 0
	end
	return writeOk
end

return Logger
