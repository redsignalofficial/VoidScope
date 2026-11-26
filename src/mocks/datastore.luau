--!strict
-- Stateful in-memory Roblox DataStoreService stub with call logging.

local Proxy = require("../proxy")

local DataStoreMock = {}

function DataStoreMock.create(logger: any): any
	local stores: { [string]: { [string]: any } } = {}

	local function getStoreBacking(storeKey: string): { [string]: any }
		if not stores[storeKey] then
			stores[storeKey] = {}
		end
		return stores[storeKey]
	end

	local function buildStoreProxy(name: string, scope: string, isOrdered: boolean): any
		local storeKey = scope .. "/" .. name
		local backing = getStoreBacking(storeKey)

		local overrides: { [string]: any } = {
			GetAsync = function(_self, key: string): (any, any)
				local k = tostring(key)
				local val = backing[k]
				logger:log("datastore", "GetAsync", {
					store = name,
					scope = scope,
					key = k,
					found = val ~= nil,
				})
				return val, { CreatedTime = 0, UpdatedTime = 0, Version = "1", GetUserIds = function() return {} end, GetMetadata = function() return {} end }
			end,

			SetAsync = function(_self, key: string, value: any, userIds: any, options: any): string
				local k = tostring(key)
				backing[k] = value
				logger:log("datastore", "SetAsync", {
					store = name,
					scope = scope,
					key = k,
					value = value,
					userIds = userIds,
					options = options,
				}, true)
				return "v1"
			end,

			UpdateAsync = function(_self, key: string, transformFn: (any, any?) -> (any, any?, any?)): (any, any)
				local k = tostring(key)
				local current = backing[k]
				local nextVal = current
				if type(transformFn) == "function" then
					local ok, transformed = pcall(transformFn, current)
					if ok then
						nextVal = transformed
					end
				end
				backing[k] = nextVal
				logger:log("datastore", "UpdateAsync", {
					store = name,
					scope = scope,
					key = k,
					previousValue = current,
					newValue = nextVal,
				}, true)
				return nextVal, nil
			end,

			IncrementAsync = function(_self, key: string, delta: number?): number
				local k = tostring(key)
				local step = delta or 1
				local cur = tonumber(backing[k]) or 0
				local nextVal = cur + step
				backing[k] = nextVal
				logger:log("datastore", "IncrementAsync", {
					store = name,
					scope = scope,
					key = k,
					delta = step,
					newValue = nextVal,
				})
				return nextVal
			end,

			RemoveAsync = function(_self, key: string): any
				local k = tostring(key)
				local prev = backing[k]
				backing[k] = nil
				logger:log("datastore", "RemoveAsync", {
					store = name,
					scope = scope,
					key = k,
					previousValue = prev,
				}, true)
				return prev
			end,

			OnUpdate = function(_self, key: string, callback: any)
				logger:log("datastore", "OnUpdate", {
					store = name,
					scope = scope,
					key = tostring(key),
				})
				local sig = Proxy.createSignal("DataStore." .. storeKey .. ".OnUpdate", logger)
				return sig:Connect(callback)
			end,
		}

		if isOrdered then
			overrides.GetSortedAsync = function(_self, ascending: boolean, pageSize: number, minValue: number?, maxValue: number?)
				logger:log("datastore", "GetSortedAsync", {
					store = name,
					scope = scope,
					ascending = ascending,
					pageSize = pageSize,
					minValue = minValue,
					maxValue = maxValue,
				})
				local entries = {}
				for k, v in backing do
					if type(v) == "number" then
						if (not minValue or v >= minValue) and (not maxValue or v <= maxValue) then
							table.insert(entries, { key = k, value = v })
						end
					end
				end
				table.sort(entries, function(a, b)
					if ascending then
						return a.value < b.value
					end
					return a.value > b.value
				end)
				return Proxy.create("DataStorePages", logger, {
					className = "DataStorePages",
					overrides = {
						IsFinished = true,
						GetCurrentPage = function()
							return entries
						end,
						AdvanceToNextPageAsync = function() end,
					},
				})
			end
		end

		return Proxy.create("game.DataStoreService." .. storeKey, logger, {
			typeName = "Instance",
			className = if isOrdered then "OrderedDataStore" else "DataStore",
			overrides = overrides,
		})
	end

	return Proxy.create("game.DataStoreService", logger, {
		typeName = "Instance",
		className = "DataStoreService",
		overrides = {
			GetDataStore = function(_self, name: string, scope: string?)
				local sName = tostring(name)
				local sScope = if scope ~= nil then tostring(scope) else "global"
				logger:log("datastore", "GetDataStore", { name = sName, scope = sScope })
				return buildStoreProxy(sName, sScope, false)
			end,
			GetGlobalDataStore = function()
				logger:log("datastore", "GetGlobalDataStore", {})
				return buildStoreProxy("__global", "global", false)
			end,
			GetOrderedDataStore = function(_self, name: string, scope: string?)
				local sName = tostring(name)
				local sScope = if scope ~= nil then tostring(scope) else "global"
				logger:log("datastore", "GetOrderedDataStore", { name = sName, scope = sScope })
				return buildStoreProxy(sName, sScope, true)
			end,
			ListDataStoresAsync = function(_self, prefix: string?)
				logger:log("datastore", "ListDataStoresAsync", { prefix = prefix })
				return Proxy.create("DataStoreListingPages", logger, {
					className = "DataStoreListingPages",
					overrides = {
						IsFinished = true,
						GetCurrentPage = function() return {} end,
						AdvanceToNextPageAsync = function() end,
					},
				})
			end,
		},
	})
end

return DataStoreMock
