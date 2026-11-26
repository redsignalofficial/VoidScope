--!strict
-- Mocks InsertService and sandboxed global require(assetId / ModuleScript).
-- Never calls the host Lune require() function.

local Proxy = require("../proxy")

local InsertMock = {}

export type InsertMockOptions = {
	maxRequires: number?,
}

local DEFAULT_MAX_REQUIRES = 100

function InsertMock.create(logger: any, options: InsertMockOptions?): any
	local opts = options or {}
	local maxRequires = opts.maxRequires or DEFAULT_MAX_REQUIRES
	local requireCount = 0

	local function buildMockMainModule(label: string, assetId: number?): any
		local moduleOverrides: { [string]: any } = {
			Source = "-- [VoidScope stubbed MainModule]",
		}
		return Proxy.create(label, logger, {
			typeName = "Instance",
			className = "ModuleScript",
			overrides = moduleOverrides,
		})
	end

	local function hookedRequire(target: any): any
		requireCount += 1
		if requireCount > maxRequires then
			logger:log("limit", "require_max_exceeded", {
				requireCount = requireCount,
				maxRequires = maxRequires,
			}, true)
			error("VoidScope: require() call limit exceeded", 2)
		end

		local targetType = type(target)
		local numericId = if targetType == "number"
			then target
			elseif targetType == "string" and string.match(target, "^%d+$") then tonumber(target)
			else nil

		if numericId ~= nil then
			logger:log("insert", "require_asset", {
				assetId = numericId,
				rawTarget = target,
			}, true)
			return buildMockMainModule("RequireAsset(" .. tostring(numericId) .. ")", numericId)
		elseif Proxy.isProxy(target) then
			local path = Proxy.getPath(target) or tostring(target)
			logger:log("insert", "require_instance", {
				path = path,
			})
			return buildMockMainModule("Require(" .. path .. ")")
		else
			logger:log("insert", "require_other", {
				targetType = targetType,
				target = tostring(target),
			}, true)
			return buildMockMainModule("Require(" .. tostring(target) .. ")")
		end
	end

	local insertMethods: { [string]: any } = {
		AllowClientInsertModels = false,

		LoadAsset = function(_self, assetId: any): any
			local numId = tonumber(assetId) or assetId
			logger:log("insert", "LoadAsset", {
				assetId = numId,
			}, true)

			local model = Proxy.create("InsertService.Asset_" .. tostring(numId), logger, {
				typeName = "Instance",
				className = "Model",
			})
			local innerModule = buildMockMainModule("InsertService.Asset_" .. tostring(numId) .. ".MainModule", tonumber(assetId))
			innerModule.Parent = model
			return model
		end,

		LoadAssetVersion = function(_self, assetVersionId: any): any
			local numId = tonumber(assetVersionId) or assetVersionId
			logger:log("insert", "LoadAssetVersion", {
				assetVersionId = numId,
			}, true)
			return Proxy.create("InsertService.AssetVersion_" .. tostring(numId), logger, {
				typeName = "Instance",
				className = "Model",
			})
		end,

		GetLatestAssetVersionAsync = function(_self, assetId: any): number
			logger:log("insert", "GetLatestAssetVersionAsync", {
				assetId = tonumber(assetId) or assetId,
			})
			return 1
		end,

		GetCollection = function(_self, categoryId: any): { any }
			logger:log("insert", "GetCollection", { categoryId = categoryId })
			return {}
		end,

		GetFreeModels = function(_self, searchText: string, pageNum: number?): { any }
			logger:log("insert", "GetFreeModels", {
				searchText = tostring(searchText),
				pageNum = pageNum or 0,
			})
			return { { CurrentStartIndex = 0, TotalCount = 0, Results = {} } }
		end,
	}

	local service = Proxy.create("game.InsertService", logger, {
		typeName = "Instance",
		className = "InsertService",
		overrides = insertMethods,
	})

	return {
		service = service,
		requireFn = hookedRequire,
	}
end

return InsertMock
