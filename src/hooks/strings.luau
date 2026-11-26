--!strict
-- Hooks string reconstruction and obfuscation primitives:
-- string.char, string.rep, string.reverse, string.gsub, table.concat, utf8.char,
-- plus byte-stream accumulation and common decode helpers.

local serde = require("@lune/serde")

local StringsHook = {}

export type StringsHookOptions = {
	maxRepBytes: number?,
	minCharLogLen: number?,
	minConcatLogLen: number?,
	maxUniqueLogs: number?,
}

export type StringsHookResult = {
	stringLib: { [string]: any },
	tableLib: { [string]: any },
	utf8Lib: { [string]: any },
	bufferLib: { [string]: any },
	flushBuffers: () -> (),
	inspectDecoded: (source: string, decoded: string) -> (),
}

local DEFAULT_MAX_REP_BYTES = 1024 * 1024 -- 1 MB cap to prevent OOM
local DEFAULT_MIN_CHAR_LEN = 4
local DEFAULT_MIN_CONCAT_LEN = 6
local DEFAULT_MAX_UNIQUE_LOGS = 500

local function looksInteresting(str: string): boolean
	local lower = string.lower(str)
	local keywords = {
		"http://",
		"https://",
		"ws://",
		"wss://",
		"discord",
		"webhook",
		"roblox",
		"rbxassetid",
		"require",
		"loadstring",
		"getfenv",
		"setfenv",
		"httpservice",
		"insertservice",
		"teleport",
		"marketplace",
		"datastore",
		"token",
		"bearer",
		"auth",
	}
	for _, kw in keywords do
		if string.find(lower, kw, 1, true) ~= nil then
			return true
		end
	end
	return false
end

local function isMostlyPrintable(str: string): boolean
	if #str == 0 then
		return false
	end
	local printable = 0
	local sampleLen = math.min(#str, 256)
	for i = 1, sampleLen do
		local b = string.byte(str, i)
		if (b >= 32 and b <= 126) or b == 9 or b == 10 or b == 13 then
			printable += 1
		end
	end
	return (printable / sampleLen) >= 0.7
end

function StringsHook.create(logger: any, options: StringsHookOptions?): StringsHookResult
	local opts = options or {}
	local maxRepBytes = opts.maxRepBytes or DEFAULT_MAX_REP_BYTES
	local minCharLen = opts.minCharLogLen or DEFAULT_MIN_CHAR_LEN
	local minConcatLen = opts.minConcatLogLen or DEFAULT_MIN_CONCAT_LEN
	local maxUniqueLogs = opts.maxUniqueLogs or DEFAULT_MAX_UNIQUE_LOGS

	local seenValues: { [string]: number } = {}
	local uniqueCount = 0
	local charStream: { string } = {}
	local charStreamLen = 0

	local function recordOnceOrThrottled(action: string, value: string, extra: { [string]: any }?)
		if #value == 0 then
			return
		end
		if not isMostlyPrintable(value) and not looksInteresting(value) then
			return
		end
		local key = action .. ":" .. serde.hash("sha256", value)
		local count = (seenValues[key] or 0) + 1
		seenValues[key] = count
		if count > 1 then
			return
		end
		if uniqueCount >= maxUniqueLogs and not looksInteresting(value) then
			return
		end
		uniqueCount += 1

		local detail: { [string]: any } = {
			value = value,
			length = #value,
			interesting = looksInteresting(value),
		}
		if extra then
			for k, v in extra do
				detail[k] = v
			end
		end
		logger:log("strings", action, detail, looksInteresting(value))
	end

	local function flushCharStream()
		if charStreamLen == 0 then
			return
		end
		local combined = table.concat(charStream)
		table.clear(charStream)
		charStreamLen = 0
		if #combined >= minCharLen then
			recordOnceOrThrottled("char_stream", combined)
		end
	end

	-- Clone standard libraries safely so sandbox never mutates host globals
	local stringLib: { [string]: any } = table.clone(string)
	local tableLib: { [string]: any } = table.clone(table)
	local utf8Lib: { [string]: any } = table.clone(utf8)
	local bufferLib: { [string]: any } = table.clone(buffer)

	stringLib.char = function(...: number): string
		local out = string.char(...)
		if #out >= minCharLen then
			flushCharStream()
			recordOnceOrThrottled("char", out)
		elseif #out > 0 then
			local b = string.byte(out, 1)
			if (b >= 32 and b <= 126) or b == 9 or b == 10 or b == 13 then
				table.insert(charStream, out)
				charStreamLen += #out
				if charStreamLen >= 512 then
					flushCharStream()
				end
			else
				flushCharStream()
			end
		end
		return out
	end

	stringLib.rep = function(s: string, n: number, sep: string?): string
		if type(s) == "string" and type(n) == "number" then
			local sepLen = if type(sep) == "string" then #sep else 0
			local est = if n > 0 then (#s * n + sepLen * math.max(n - 1, 0)) else 0
			if est > maxRepBytes then
				logger:log("limit", "string_rep_exceeded", {
					requestedBytes = est,
					maxBytes = maxRepBytes,
					count = n,
				}, true)
				error("VoidScope: string.rep output exceeds safety limit (" .. tostring(maxRepBytes) .. " bytes)", 2)
			end
		end
		local out = string.rep(s, n, sep :: any)
		if #out >= 64 or (type(n) == "number" and n >= 16) then
			recordOnceOrThrottled("rep", out, { count = n })
		end
		return out
	end

	stringLib.reverse = function(s: string): string
		local out = string.reverse(s)
		if #out >= minConcatLen and (looksInteresting(out) or #out >= 10) then
			recordOnceOrThrottled("reverse", out)
		end
		return out
	end

	stringLib.gsub = function(s: string, pattern: string, repl: any, n: number?): (string, number)
		local out, count = string.gsub(s, pattern, repl, n)
		if count > 0 and #out >= minConcatLen then
			if looksInteresting(out) or type(repl) == "function" or type(repl) == "table" then
				recordOnceOrThrottled("gsub", out, { replacements = count })
			end
		end
		return out, count
	end

	tableLib.concat = function(list: { any }, sep: string?, i: number?, j: number?): string
		local out = table.concat(list, sep, i, j)
		if #out >= minConcatLen or looksInteresting(out) then
			recordOnceOrThrottled("concat", out)
		end
		return out
	end

	utf8Lib.char = function(...: number): string
		local out = utf8.char(...)
		if #out >= minCharLen then
			recordOnceOrThrottled("utf8_char", out)
		end
		return out
	end

	bufferLib.readstring = function(b: buffer, offset: number, count: number): string
		local out = buffer.readstring(b, offset, count)
		if #out >= minCharLen then
			recordOnceOrThrottled("buffer_readstring", out)
		end
		return out
	end

	bufferLib.tostring = function(b: buffer): string
		local out = buffer.tostring(b)
		if #out >= minCharLen and (looksInteresting(out) or isMostlyPrintable(out)) then
			recordOnceOrThrottled("buffer_tostring", out)
		end
		return out
	end

	local function inspectDecoded(source: string, decoded: string)
		if #decoded >= minCharLen then
			recordOnceOrThrottled("decode_" .. source, decoded)
		end
	end

	return {
		stringLib = stringLib,
		tableLib = tableLib,
		utf8Lib = utf8Lib,
		bufferLib = bufferLib,
		flushBuffers = flushCharStream,
		inspectDecoded = inspectDecoded,
	}
end

return StringsHook
