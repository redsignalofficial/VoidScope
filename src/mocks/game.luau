--!strict
-- Mocks Roblox DataModel (game), workspace, Players, RunService, GroupService,
-- script, Instance.new, Enum, and core Roblox value types.

local DateTimeLune = require("@lune/datetime")
local Proxy = require("../proxy")

local GameMock = {}

export type GameMockOptions = {
	placeId: number?,
	gameId: number?,
	creatorId: number?,
	jobId: string?,
	isServer: boolean?,
	isStudio: boolean?,
}

local function buildEnumMock(): any
	local enumCache: { [string]: any } = {}
	local function makeEnumItem(groupName: string, groupObj: any, itemName: string, val: number): any
		local item = newproxy(true)
		local mt = getmetatable(item)
		mt.__metatable = "The metatable is locked"
		mt.__index = function(_s, prop)
			if prop == "Name" then
				return itemName
			elseif prop == "Value" then
				return val
			elseif prop == "EnumType" then
				return groupObj
			end
			return nil
		end
		mt.__tostring = function()
			return "Enum." .. groupName .. "." .. itemName
		end
		Proxy.registerType(item, "EnumItem", "EnumItem", "Enum." .. groupName .. "." .. itemName)
		return item
	end

	local enumRoot = setmetatable({
		GetEnums = function()
			local out = {}
			for _, grp in enumCache do
				table.insert(out, grp)
			end
			return out
		end,
	}, {
		__index = function(_self, groupName: string)
			local key = tostring(groupName)
			if enumCache[key] then
				return enumCache[key]
			end
			local itemCache: { [string]: any } = {}
			local group
			group = setmetatable({
				GetEnumItems = function()
					local out = {}
					for _, item in itemCache do
						table.insert(out, item)
					end
					return out
				end,
				FromName = function(_s, name: string)
					return group[tostring(name)]
				end,
				FromValue = function(_s, val: number)
					for _, item in itemCache do
						if item.Value == val then
							return item
						end
					end
					return makeEnumItem(key, group, "Value_" .. tostring(val), tonumber(val) or 0)
				end,
			}, {
				__index = function(grp, itemName: string)
					local itemKey = tostring(itemName)
					if itemCache[itemKey] then
						return itemCache[itemKey]
					end
					local item = makeEnumItem(key, grp, itemKey, 0)
					itemCache[itemKey] = item
					return item
				end,
				__tostring = function()
					return key
				end,
			})
			Proxy.registerType(group, "Enum", "Enum", "Enum." .. key)
			enumCache[key] = group
			return group
		end,
	})
	Proxy.registerType(enumRoot, "Enums", "Enums", "Enums")
	return enumRoot
end

local function buildDataTypes(): { [string]: any }
	local Vector3 = {}
	function Vector3.new(x: number?, y: number?, z: number?): any
		local v = { X = x or 0, Y = y or 0, Z = z or 0 }
		v.Magnitude = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		v.Unit = v
		Proxy.registerType(v, "Vector3", "Vector3", "Vector3")
		return v
	end
	Vector3.zero = Vector3.new(0, 0, 0)
	Vector3.one = Vector3.new(1, 1, 1)

	local Vector2 = {}
	function Vector2.new(x: number?, y: number?): any
		local v = { X = x or 0, Y = y or 0 }
		Proxy.registerType(v, "Vector2", "Vector2", "Vector2")
		return v
	end
	Vector2.zero = Vector2.new(0, 0)

	local CFrame = {}
	function CFrame.new(x: number?, y: number?, z: number?): any
		local cf = {
			Position = Vector3.new(x or 0, y or 0, z or 0),
			X = x or 0,
			Y = y or 0,
			Z = z or 0,
			LookVector = Vector3.new(0, 0, -1),
			RightVector = Vector3.new(1, 0, 0),
			UpVector = Vector3.new(0, 1, 0),
		}
		Proxy.registerType(cf, "CFrame", "CFrame", "CFrame")
		return cf
	end
	CFrame.Angles = function()
		return CFrame.new(0, 0, 0)
	end
	CFrame.lookAt = function(at: any)
		return CFrame.new(if at then at.X else 0, if at then at.Y else 0, if at then at.Z else 0)
	end
	CFrame.identity = CFrame.new(0, 0, 0)

	local Color3 = {}
	function Color3.new(r: number?, g: number?, b: number?): any
		local c = { R = r or 0, G = g or 0, B = b or 0 }
		Proxy.registerType(c, "Color3", "Color3", "Color3")
		return c
	end
	function Color3.fromRGB(r: number?, g: number?, b: number?): any
		return Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
	end
	function Color3.fromHSV(h: number?, s: number?, v: number?): any
		return Color3.new(h or 0, s or 0, v or 0)
	end
	function Color3.fromHex(hex: string): any
		return Color3.new(1, 1, 1)
	end

	local UDim = {}
	function UDim.new(scale: number?, offset: number?): any
		local u = { Scale = scale or 0, Offset = offset or 0 }
		Proxy.registerType(u, "UDim", "UDim", "UDim")
		return u
	end

	local UDim2 = {}
	function UDim2.new(xs: number?, xo: number?, ys: number?, yo: number?): any
		local u = { X = UDim.new(xs, xo), Y = UDim.new(ys, yo) }
		Proxy.registerType(u, "UDim2", "UDim2", "UDim2")
		return u
	end
	function UDim2.fromScale(xs: number?, ys: number?): any
		return UDim2.new(xs, 0, ys, 0)
	end
	function UDim2.fromOffset(xo: number?, yo: number?): any
		return UDim2.new(0, xo, 0, yo)
	end

	local BrickColor = {}
	function BrickColor.new(val: any): any
		local bc = { Name = tostring(val or "Medium stone grey"), Number = 194, Color = Color3.new(0.64, 0.64, 0.65) }
		Proxy.registerType(bc, "BrickColor", "BrickColor", "BrickColor")
		return bc
	end

	local TweenInfo = {}
	function TweenInfo.new(...): any
		local ti = { Time = select(1, ...) or 1 }
		Proxy.registerType(ti, "TweenInfo", "TweenInfo", "TweenInfo")
		return ti
	end

	local NumberRange = {}
	function NumberRange.new(minVal: number?, maxVal: number?): any
		local nr = { Min = minVal or 0, Max = maxVal or minVal or 0 }
		Proxy.registerType(nr, "NumberRange", "NumberRange", "NumberRange")
		return nr
	end

	local Rect = {}
	function Rect.new(a: number?, b: number?, c: number?, d: number?): any
		local r = { Min = Vector2.new(a, b), Max = Vector2.new(c, d) }
		Proxy.registerType(r, "Rect", "Rect", "Rect")
		return r
	end

	local Ray = {}
	function Ray.new(origin: any, dir: any): any
		local ray = { Origin = origin or Vector3.zero, Direction = dir or Vector3.zero }
		Proxy.registerType(ray, "Ray", "Ray", "Ray")
		return ray
	end

	local Region3 = {}
	function Region3.new(minV: any, maxV: any): any
		local reg = { CFrame = CFrame.identity, Size = Vector3.one }
		Proxy.registerType(reg, "Region3", "Region3", "Region3")
		return reg
	end

	local Random = {}
	function Random.new(seed: number?): any
		return {
			NextInteger = function(_s, minI: number, maxI: number)
				return math.random(minI, maxI)
			end,
			NextNumber = function(_s, minN: number?, maxN: number?)
				if minN and maxN then
					return minN + math.random() * (maxN - minN)
				end
				return math.random()
			end,
			NextUnitVector = function()
				return Vector3.new(0, 1, 0)
			end,
			Shuffle = function(_s, tbl: { any })
				if type(tbl) == "table" then
					for i = #tbl, 2, -1 do
						local j = math.random(1, i)
						tbl[i], tbl[j] = tbl[j], tbl[i]
					end
				end
			end,
			Clone = function(s)
				return s
			end,
		}
	end

	local ColorSequenceKeypoint = {}
	function ColorSequenceKeypoint.new(timeVal: number?, colorVal: any): any
		local kp = { Time = timeVal or 0, Value = colorVal or Color3.new(1, 1, 1) }
		Proxy.registerType(kp, "ColorSequenceKeypoint", "ColorSequenceKeypoint", "ColorSequenceKeypoint")
		return kp
	end

	local ColorSequence = {}
	function ColorSequence.new(a: any, b: any): any
		local cs = { Keypoints = if type(a) == "table" and a[1] then a else { ColorSequenceKeypoint.new(0, a), ColorSequenceKeypoint.new(1, b or a) } }
		Proxy.registerType(cs, "ColorSequence", "ColorSequence", "ColorSequence")
		return cs
	end

	local NumberSequenceKeypoint = {}
	function NumberSequenceKeypoint.new(timeVal: number?, val: number?, env: number?): any
		local kp = { Time = timeVal or 0, Value = val or 0, Envelope = env or 0 }
		Proxy.registerType(kp, "NumberSequenceKeypoint", "NumberSequenceKeypoint", "NumberSequenceKeypoint")
		return kp
	end

	local NumberSequence = {}
	function NumberSequence.new(a: any, b: any): any
		local ns = { Keypoints = if type(a) == "table" and a[1] then a else { NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(1, b or a) } }
		Proxy.registerType(ns, "NumberSequence", "NumberSequence", "NumberSequence")
		return ns
	end

	local RaycastParams = {}
	function RaycastParams.new(): any
		local rp = {
			FilterDescendantsInstances = {},
			FilterType = nil,
			IgnoreWater = false,
			CollisionGroup = "Default",
			RespectCanCollide = false,
			BruteForceAllSlow = false,
		}
		Proxy.registerType(rp, "RaycastParams", "RaycastParams", "RaycastParams")
		return rp
	end

	local OverlapParams = {}
	function OverlapParams.new(): any
		local op = {
			FilterDescendantsInstances = {},
			FilterType = nil,
			MaxParts = 0,
			CollisionGroup = "Default",
			RespectCanCollide = false,
		}
		Proxy.registerType(op, "OverlapParams", "OverlapParams", "OverlapParams")
		return op
	end

	local PhysicalProperties = {}
	function PhysicalProperties.new(density: number?, friction: number?, elasticity: number?, fw: number?, ew: number?): any
		local pp = {
			Density = density or 0.7,
			Friction = friction or 0.3,
			Elasticity = elasticity or 0.5,
			FrictionWeight = fw or 1,
			ElasticityWeight = ew or 1,
		}
		Proxy.registerType(pp, "PhysicalProperties", "PhysicalProperties", "PhysicalProperties")
		return pp
	end

	local Axes = {}
	function Axes.new(...): any
		local ax = { X = false, Y = false, Z = false, Top = false, Bottom = false, Left = false, Right = false, Back = false, Front = false }
		Proxy.registerType(ax, "Axes", "Axes", "Axes")
		return ax
	end

	local Faces = {}
	function Faces.new(...): any
		local fc = { Top = false, Bottom = false, Left = false, Right = false, Back = false, Front = false }
		Proxy.registerType(fc, "Faces", "Faces", "Faces")
		return fc
	end

	local Vector3int16 = {}
	function Vector3int16.new(x: number?, y: number?, z: number?): any
		local v = { X = x or 0, Y = y or 0, Z = z or 0 }
		Proxy.registerType(v, "Vector3int16", "Vector3int16", "Vector3int16")
		return v
	end

	local Region3int16 = {}
	function Region3int16.new(minV: any, maxV: any): any
		local r = { Min = minV or Vector3int16.new(), Max = maxV or Vector3int16.new() }
		Proxy.registerType(r, "Region3int16", "Region3int16", "Region3int16")
		return r
	end

	local PathWaypoint = {}
	function PathWaypoint.new(pos: any, action: any, label: string?): any
		local pw = { Position = pos or Vector3.zero, Action = action, Label = label or "" }
		Proxy.registerType(pw, "PathWaypoint", "PathWaypoint", "PathWaypoint")
		return pw
	end

	local CatalogSearchParams = {}
	function CatalogSearchParams.new(): any
		local csp = { SearchKeyword = "", MinPrice = 0, MaxPrice = 0, SortType = nil }
		Proxy.registerType(csp, "CatalogSearchParams", "CatalogSearchParams", "CatalogSearchParams")
		return csp
	end

	local Font = {}
	function Font.new(family: string?, weight: any, style: any): any
		local f = { Family = family or "rbxasset://fonts/families/SourceSansPro.json", Weight = weight, Style = style, Bold = false }
		Proxy.registerType(f, "Font", "Font", "Font")
		return f
	end
	function Font.fromEnum(enumItem: any): any
		return Font.new(tostring(enumItem))
	end
	function Font.fromId(id: number, weight: any, style: any): any
		return Font.new("rbxassetid://" .. tostring(id), weight, style)
	end
	function Font.fromName(name: string, weight: any, style: any): any
		return Font.new("rbxasset://fonts/families/" .. tostring(name) .. ".json", weight, style)
	end

	local Path2DControlPoint = {}
	function Path2DControlPoint.new(pos: any, leftTan: any, rightTan: any): any
		local cp = {
			Position = pos or UDim2.new(0, 0, 0, 0),
			LeftTangent = leftTan or UDim2.new(0, 0, 0, 0),
			RightTangent = rightTan or UDim2.new(0, 0, 0, 0),
		}
		Proxy.registerType(cp, "Path2DControlPoint", "Path2DControlPoint", "Path2DControlPoint")
		return cp
	end

	local RobloxDateTime = {
		now = function()
			return DateTimeLune.now()
		end,
		fromUnixTimestamp = function(ts: number)
			return DateTimeLune.fromUnixTimestamp(ts)
		end,
		fromUnixTimestampMillis = function(ms: number)
			return DateTimeLune.fromUnixTimestamp(ms / 1000)
		end,
		fromUniversalTime = function(y: number, mo: number?, d: number?, h: number?, mi: number?, s: number?, ms: number?)
			return DateTimeLune.fromUniversalTime({
				year = y,
				month = mo or 1,
				day = d or 1,
				hour = h or 0,
				minute = mi or 0,
				second = s or 0,
				millisecond = ms or 0,
			})
		end,
		fromLocalTime = function(y: number, mo: number?, d: number?, h: number?, mi: number?, s: number?, ms: number?)
			return DateTimeLune.fromLocalTime({
				year = y,
				month = mo or 1,
				day = d or 1,
				hour = h or 0,
				minute = mi or 0,
				second = s or 0,
				millisecond = ms or 0,
			})
		end,
		fromIsoDate = function(iso: string)
			return DateTimeLune.fromRfc3339(iso)
		end,
	}

	return {
		Vector3 = Vector3,
		Vector2 = Vector2,
		CFrame = CFrame,
		Color3 = Color3,
		BrickColor = BrickColor,
		UDim = UDim,
		UDim2 = UDim2,
		TweenInfo = TweenInfo,
		NumberRange = NumberRange,
		Rect = Rect,
		Ray = Ray,
		Region3 = Region3,
		Random = Random,
		ColorSequenceKeypoint = ColorSequenceKeypoint,
		ColorSequence = ColorSequence,
		NumberSequenceKeypoint = NumberSequenceKeypoint,
		NumberSequence = NumberSequence,
		RaycastParams = RaycastParams,
		OverlapParams = OverlapParams,
		PhysicalProperties = PhysicalProperties,
		Axes = Axes,
		Faces = Faces,
		Vector3int16 = Vector3int16,
		Region3int16 = Region3int16,
		PathWaypoint = PathWaypoint,
		CatalogSearchParams = CatalogSearchParams,
		Font = Font,
		Path2DControlPoint = Path2DControlPoint,
		DateTime = RobloxDateTime,
	}
end

function GameMock.create(
	logger: any,
	wiredServices: {
		http: any,
		insert: any,
		messaging: any,
		datastore: any,
	},
	options: GameMockOptions?
): { [string]: any }
	local opts = options or {}
	local placeId = opts.placeId or 1818456789
	local gameId = opts.gameId or 987654321
	local creatorId = opts.creatorId or 12345678
	local jobId = opts.jobId or "voidscope-job-00000000-0000-4000-8000-000000000001"
	local isServer = if opts.isServer == nil then true else opts.isServer
	local isStudio = if opts.isStudio == nil then false else opts.isStudio

	local enumMock = buildEnumMock()
	local dataTypes = buildDataTypes()

	local function makePlayer(name: string, userId: number): any
		local player: any
		player = Proxy.create("game.Players." .. name, logger, {
			typeName = "Instance",
			className = "Player",
			overrides = {
				Name = name,
				DisplayName = name,
				UserId = userId,
				AccountAge = 420,
				MembershipType = enumMock.MembershipType.None,
				Character = Proxy.create("game.Workspace." .. name, logger, { className = "Model" }),
				Backpack = Proxy.create("game.Players." .. name .. ".Backpack", logger, { className = "Backpack" }),
				PlayerGui = Proxy.create("game.Players." .. name .. ".PlayerGui", logger, { className = "PlayerGui" }),
				Kick = function(_self, reason: string?)
					logger:log("player", "Kick", {
						player = name,
						userId = userId,
						reason = reason or "",
					}, true)
				end,
				GetRankInGroup = function(_self, groupId: number): number
					logger:log("player", "GetRankInGroup", {
						player = name,
						userId = userId,
						groupId = tonumber(groupId) or groupId,
					}, true)
					return 0
				end,
				IsInGroup = function(_self, groupId: number): boolean
					logger:log("player", "IsInGroup", {
						player = name,
						userId = userId,
						groupId = tonumber(groupId) or groupId,
					}, true)
					return false
				end,
				GetRoleInGroup = function(_self, groupId: number): string
					logger:log("player", "GetRoleInGroup", {
						player = name,
						userId = userId,
						groupId = tonumber(groupId) or groupId,
					}, true)
					return "Guest"
				end,
			},
		})
		return player
	end

	local player1 = makePlayer("Player1", 10000001)
	local player2 = makePlayer("VictimPlayer", 10000002)
	local fakePlayers = { player1, player2 }

	local playersService = Proxy.create("game.Players", logger, {
		typeName = "Instance",
		className = "Players",
		overrides = {
			LocalPlayer = if isServer then nil else player1,
			MaxPlayers = 50,
			PlayerAdded = Proxy.createSignal("game.Players.PlayerAdded", logger),
			PlayerRemoving = Proxy.createSignal("game.Players.PlayerRemoving", logger),
			GetPlayers = function()
				logger:log("players", "GetPlayers", { count = #fakePlayers })
				return table.clone(fakePlayers)
			end,
			GetPlayerByUserId = function(_self, uid: number)
				logger:log("players", "GetPlayerByUserId", { userId = tonumber(uid) or uid })
				for _, p in fakePlayers do
					if p.UserId == uid then
						return p
					end
				end
				return nil
			end,
			GetUserIdFromNameAsync = function(_self, username: string): number
				logger:log("players", "GetUserIdFromNameAsync", { username = tostring(username) }, true)
				return 10000099
			end,
			GetNameFromUserIdAsync = function(_self, uid: number): string
				logger:log("players", "GetNameFromUserIdAsync", { userId = tonumber(uid) or uid }, true)
				return "RobloxUser_" .. tostring(uid)
			end,
		},
	})

	local runService = Proxy.create("game.RunService", logger, {
		typeName = "Instance",
		className = "RunService",
		overrides = {
			IsServer = function()
				return isServer
			end,
			IsClient = function()
				return not isServer
			end,
			IsStudio = function()
				return isStudio
			end,
			IsRunning = function()
				return true
			end,
			Heartbeat = Proxy.createSignal("game.RunService.Heartbeat", logger),
			Stepped = Proxy.createSignal("game.RunService.Stepped", logger),
			RenderStepped = Proxy.createSignal("game.RunService.RenderStepped", logger),
		},
	})

	local groupService = Proxy.create("game.GroupService", logger, {
		typeName = "Instance",
		className = "GroupService",
		overrides = {
			GetGroupInfoAsync = function(_self, groupId: number)
				logger:log("group", "GetGroupInfoAsync", { groupId = tonumber(groupId) or groupId }, true)
				return {
					Name = "StubGroup_" .. tostring(groupId),
					Id = tonumber(groupId) or groupId,
					Owner = { Name = "StubOwner", Id = 1 },
					Roles = { { Name = "Guest", Rank = 0 }, { Name = "Owner", Rank = 255 } },
				}
			end,
			GetGroupsAsync = function(_self, userId: number)
				logger:log("group", "GetGroupsAsync", { userId = tonumber(userId) or userId }, true)
				return {}
			end,
		},
	})

	local workspaceService = Proxy.create("game.Workspace", logger, {
		typeName = "Instance",
		className = "Workspace",
		overrides = {
			Name = "Workspace",
			Gravity = 196.2,
			DistributedGameTime = 12.5,
			Terrain = Proxy.create("game.Workspace.Terrain", logger, { className = "Terrain" }),
			CurrentCamera = Proxy.create("game.Workspace.CurrentCamera", logger, { className = "Camera" }),
			Baseplate = Proxy.create("game.Workspace.Baseplate", logger, { className = "Part" }),
		},
	})

	local replicatedStorage = Proxy.create("game.ReplicatedStorage", logger, { className = "ReplicatedStorage" })
	local serverScriptService = Proxy.create("game.ServerScriptService", logger, { className = "ServerScriptService" })
	local serverStorage = Proxy.create("game.ServerStorage", logger, { className = "ServerStorage" })
	local lighting = Proxy.create("game.Lighting", logger, { className = "Lighting" })
	local starterGui = Proxy.create("game.StarterGui", logger, { className = "StarterGui" })

	local scriptObj = Proxy.create("game.ServerScriptService.MainScript", logger, {
		typeName = "Instance",
		className = "Script",
		parent = serverScriptService,
		overrides = {
			Name = "MainScript",
			Enabled = true,
			Disabled = false,
			Source = "",
		},
		onWrite = function(key, value)
			if key == "Source" then
				logger:log("script", "source_write", {
					target = "MainScript",
					source = tostring(value),
				}, true)
			end
		end,
	})
	scriptObj.Parent = serverScriptService

	local services: { [string]: any } = {
		HttpService = wiredServices.http.service,
		InsertService = wiredServices.insert.service,
		MessagingService = wiredServices.messaging.MessagingService,
		TeleportService = wiredServices.messaging.TeleportService,
		MarketplaceService = wiredServices.messaging.MarketplaceService,
		DataStoreService = wiredServices.datastore,
		Players = playersService,
		RunService = runService,
		GroupService = groupService,
		Workspace = workspaceService,
		workspace = workspaceService,
		ReplicatedStorage = replicatedStorage,
		ServerScriptService = serverScriptService,
		ServerStorage = serverStorage,
		Lighting = lighting,
		StarterGui = starterGui,
	}

	local function getService(_self: any, serviceName: string): any
		local name = tostring(serviceName)
		if services[name] then
			logger:log("game", "GetService", { service = name })
			return services[name]
		end
		logger:log("game", "GetService", { service = name, genericProxy = true })
		local dynamicSvc = Proxy.create("game." .. name, logger, {
			typeName = "Instance",
			className = name,
		})
		services[name] = dynamicSvc
		return dynamicSvc
	end

	local gameObj = Proxy.create("game", logger, {
		typeName = "Instance",
		className = "DataModel",
		overrides = {
			Name = "Game",
			PlaceId = placeId,
			GameId = gameId,
			PlaceVersion = 42,
			CreatorId = creatorId,
			CreatorType = enumMock.CreatorType.User,
			JobId = jobId,
			PrivateServerId = "",
			PrivateServerOwnerId = 0,
			Workspace = workspaceService,
			Players = playersService,
			ReplicatedStorage = replicatedStorage,
			ServerScriptService = serverScriptService,
			ServerStorage = serverStorage,
			Lighting = lighting,
			StarterGui = starterGui,
			HttpService = wiredServices.http.service,
			InsertService = wiredServices.insert.service,
			MessagingService = wiredServices.messaging.MessagingService,
			TeleportService = wiredServices.messaging.TeleportService,
			MarketplaceService = wiredServices.messaging.MarketplaceService,
			DataStoreService = wiredServices.datastore,
			RunService = runService,
			GroupService = groupService,
			GetService = getService,
			FindService = getService,
			HttpGet = function(_self, url: string, nocache: boolean?, headers: any)
				return wiredServices.http.httpGet(url, nocache, headers)
			end,
			HttpGetAsync = function(_self, url: string, nocache: boolean?, headers: any)
				return wiredServices.http.httpGet(url, nocache, headers)
			end,
			HttpPost = function(_self, url: string, data: string, contentType: any, headers: any)
				return wiredServices.http.httpPost(url, data, contentType, headers)
			end,
			HttpPostAsync = function(_self, url: string, data: string, contentType: any, headers: any)
				return wiredServices.http.httpPost(url, data, contentType, headers)
			end,
			GetObjects = function(_self, assetUrl: string)
				logger:log("insert", "game_GetObjects", { assetUrl = tostring(assetUrl) }, true)
				local idStr = string.match(tostring(assetUrl), "(%d+)")
				return { wiredServices.insert.service:LoadAsset(tonumber(idStr) or 0) }
			end,
			BindToClose = function(_self, fn: any)
				logger:log("game", "BindToClose", { hasCallback = type(fn) == "function" })
			end,
		},
	})

	local instanceCounter = 0
	local function buildPath2DOverrides(dt: { [string]: any }): { [string]: any }
		local controlPoints: { any } = {}
		local function evalBezier(t: number): (number, number, number, number)
			if #controlPoints == 0 then
				return 0, 0, 0, 0
			elseif #controlPoints == 1 then
				local p = controlPoints[1].Position
				return p.X.Scale, p.X.Offset, p.Y.Scale, p.Y.Offset
			end
			local clamped = math.clamp(t, 0, 1)
			local segCount = #controlPoints - 1
			local scaled = clamped * segCount
			local idx = math.min(math.floor(scaled) + 1, segCount)
			local u = scaled - (idx - 1)
			local p0 = controlPoints[idx]
			local p3 = controlPoints[idx + 1]
			local function comp(getVal: (any) -> number): number
				local a = getVal(p0.Position)
				local b = a + getVal(p0.RightTangent)
				local d = getVal(p3.Position)
				local c = d + getVal(p3.LeftTangent)
				local inv = 1 - u
				return (inv ^ 3) * a + 3 * (inv ^ 2) * u * b + 3 * inv * (u ^ 2) * c + (u ^ 3) * d
			end
			return comp(function(v) return v.X.Scale end),
				comp(function(v) return v.X.Offset end),
				comp(function(v) return v.Y.Scale end),
				comp(function(v) return v.Y.Offset end)
		end
		return {
			SetControlPoints = function(_self, pts: { any })
				controlPoints = if type(pts) == "table" then table.clone(pts) else {}
			end,
			GetControlPoints = function()
				return table.clone(controlPoints)
			end,
			GetLength = function()
				if #controlPoints < 2 then
					return 0
				end
				local total = 0
				local prevXs, prevXo, prevYs, prevYo = evalBezier(0)
				for step = 1, 16 do
					local xs, xo, ys, yo = evalBezier(step / 16)
					local dx = (xs - prevXs) + (xo - prevXo)
					local dy = (ys - prevYs) + (yo - prevYo)
					total += math.sqrt(dx * dx + dy * dy)
					prevXs, prevXo, prevYs, prevYo = xs, xo, ys, yo
				end
				return total
			end,
			GetPositionOnCurve = function(_self, t: number)
				local xs, xo, ys, yo = evalBezier(t or 0)
				return dt.UDim2.new(xs, xo, ys, yo)
			end,
			GetPositionOnCurveArcLength = function(_self, t: number)
				local xs, xo, ys, yo = evalBezier(t or 0)
				return dt.UDim2.new(xs, xo, ys, yo)
			end,
			GetTangentOnCurve = function()
				return dt.UDim2.new(0, 1, 0, 0)
			end,
			GetTangentOnCurveArcLength = function()
				return dt.UDim2.new(0, 1, 0, 0)
			end,
		}
	end

	local InstanceCtor = {
		new = function(className: string, parent: any?): any
			instanceCounter += 1
			local cls = tostring(className)
			logger:log("instance", "new", {
				className = cls,
				parent = if parent ~= nil then tostring(parent) else nil,
			}, cls == "Script" or cls == "LocalScript" or cls == "ModuleScript" or cls == "RemoteEvent" or cls == "RemoteFunction")

			local overrides = if cls == "Path2D" then buildPath2DOverrides(dataTypes) else nil
			local inst = Proxy.create("Instance_" .. cls .. "_" .. tostring(instanceCounter), logger, {
				typeName = "Instance",
				className = cls,
				parent = parent,
				overrides = overrides,
				onWrite = function(key, value)
					if key == "Source" then
						logger:log("script", "source_write", {
							className = cls,
							source = tostring(value),
						}, true)
					end
				end,
			})
			if parent ~= nil then
				inst.Parent = parent
			end
			return inst
		end,
	}

	return {
		game = gameObj,
		Game = gameObj,
		workspace = workspaceService,
		Workspace = workspaceService,
		Players = playersService,
		script = scriptObj,
		Instance = InstanceCtor,
		Enum = enumMock,
		dataTypes = dataTypes,
	}
end

return GameMock
