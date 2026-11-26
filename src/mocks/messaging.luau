--!strict
-- Mocks Roblox MessagingService, TeleportService, and MarketplaceService.

local Proxy = require("../proxy")

local MessagingMock = {}

function MessagingMock.create(logger: any): any
	local messagingService = Proxy.create("game.MessagingService", logger, {
		typeName = "Instance",
		className = "MessagingService",
		overrides = {
			PublishAsync = function(_self, topic: string, message: any)
				logger:log("messaging", "PublishAsync", {
					topic = tostring(topic),
					message = message,
				}, true)
			end,
			SubscribeAsync = function(_self, topic: string, callback: any)
				logger:log("messaging", "SubscribeAsync", {
					topic = tostring(topic),
					hasCallback = type(callback) == "function",
				}, true)
				local sig = Proxy.createSignal("game.MessagingService." .. tostring(topic), logger)
				return sig:Connect(callback)
			end,
		},
	})

	local teleportService = Proxy.create("game.TeleportService", logger, {
		typeName = "Instance",
		className = "TeleportService",
		overrides = {
			Teleport = function(_self, placeId: any, player: any, teleportData: any)
				logger:log("teleport", "Teleport", {
					placeId = tonumber(placeId) or placeId,
					player = if player ~= nil then tostring(player) else nil,
					teleportData = teleportData,
				}, true)
			end,
			TeleportAsync = function(_self, placeId: any, players: any, teleportOptions: any)
				logger:log("teleport", "TeleportAsync", {
					placeId = tonumber(placeId) or placeId,
					players = players,
					teleportOptions = teleportOptions,
				}, true)
				return { PrivateServerId = "" }
			end,
			TeleportToPlaceInstance = function(_self, placeId: any, instanceId: string, player: any, spawnName: string?, teleportData: any)
				logger:log("teleport", "TeleportToPlaceInstance", {
					placeId = tonumber(placeId) or placeId,
					instanceId = tostring(instanceId),
					player = if player ~= nil then tostring(player) else nil,
					spawnName = spawnName,
					teleportData = teleportData,
				}, true)
			end,
			TeleportPartyAsync = function(_self, placeId: any, players: any, teleportData: any)
				logger:log("teleport", "TeleportPartyAsync", {
					placeId = tonumber(placeId) or placeId,
					players = players,
					teleportData = teleportData,
				}, true)
				return "voidscope_party_job"
			end,
			ReserveServer = function(_self, placeId: any): (string, string)
				logger:log("teleport", "ReserveServer", {
					placeId = tonumber(placeId) or placeId,
				}, true)
				return "voidscope_reserved_access_code", "voidscope_private_server_id"
			end,
			TeleportToPrivateServer = function(_self, placeId: any, reservedCode: string, players: any, spawnName: string?, teleportData: any)
				logger:log("teleport", "TeleportToPrivateServer", {
					placeId = tonumber(placeId) or placeId,
					reservedCode = tostring(reservedCode),
					players = players,
					spawnName = spawnName,
					teleportData = teleportData,
				}, true)
			end,
			GetPlayerPlaceInstanceAsync = function(_self, userId: any): (boolean, string, number, string)
				logger:log("teleport", "GetPlayerPlaceInstanceAsync", {
					userId = tonumber(userId) or userId,
				})
				return true, "", 1818456789, "voidscope-job-0001"
			end,
		},
	})

	local marketplaceService = Proxy.create("game.MarketplaceService", logger, {
		typeName = "Instance",
		className = "MarketplaceService",
		overrides = {
			PromptPurchase = function(_self, player: any, assetId: any, equipIfPurchased: boolean?, currencyType: any)
				logger:log("marketplace", "PromptPurchase", {
					player = tostring(player),
					assetId = tonumber(assetId) or assetId,
					equipIfPurchased = equipIfPurchased,
					currencyType = if currencyType ~= nil then tostring(currencyType) else nil,
				}, true)
			end,
			PromptProductPurchase = function(_self, player: any, productId: any)
				logger:log("marketplace", "PromptProductPurchase", {
					player = tostring(player),
					productId = tonumber(productId) or productId,
				}, true)
			end,
			PromptGamePassPurchase = function(_self, player: any, gamePassId: any)
				logger:log("marketplace", "PromptGamePassPurchase", {
					player = tostring(player),
					gamePassId = tonumber(gamePassId) or gamePassId,
				}, true)
			end,
			PromptBundlePurchase = function(_self, player: any, bundleId: any)
				logger:log("marketplace", "PromptBundlePurchase", {
					player = tostring(player),
					bundleId = tonumber(bundleId) or bundleId,
				}, true)
			end,
			PromptSubscriptionPurchase = function(_self, player: any, subscriptionId: any)
				logger:log("marketplace", "PromptSubscriptionPurchase", {
					player = tostring(player),
					subscriptionId = tostring(subscriptionId),
				}, true)
			end,
			UserOwnsGamePassAsync = function(_self, userId: any, gamePassId: any): boolean
				logger:log("marketplace", "UserOwnsGamePassAsync", {
					userId = tonumber(userId) or userId,
					gamePassId = tonumber(gamePassId) or gamePassId,
				})
				return true
			end,
			PlayerOwnsAsset = function(_self, player: any, assetId: any): boolean
				logger:log("marketplace", "PlayerOwnsAsset", {
					player = tostring(player),
					assetId = tonumber(assetId) or assetId,
				})
				return true
			end,
			GetProductInfo = function(_self, assetId: any, infoType: any): { [string]: any }
				local numId = tonumber(assetId) or assetId
				logger:log("marketplace", "GetProductInfo", {
					assetId = numId,
					infoType = if infoType ~= nil then tostring(infoType) else "Asset",
				}, true)
				return {
					AssetId = numId,
					ProductId = numId,
					Name = "StubAsset_" .. tostring(numId),
					Description = "",
					AssetTypeId = 10,
					Creator = {
						Id = 1,
						Name = "Roblox",
						CreatorType = "User",
						CreatorTargetId = 1,
					},
					PriceInRobux = 0,
					IsForSale = false,
					IsPublicDomain = false,
				}
			end,
		},
	})

	return {
		MessagingService = messagingService,
		TeleportService = teleportService,
		MarketplaceService = marketplaceService,
	}
end

return MessagingMock
