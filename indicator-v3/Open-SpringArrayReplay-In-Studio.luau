-- Run in RoAlgo Studio Edit mode through Roblox MCP. Opens the synchronized filming presentation.
assert(game.PlaceId == 0, "Expected RoAlgo")
assert(not game:GetService("RunService"):IsRunning(), "Use Edit mode")
local control = game.CoreGui:FindFirstChild("RoAlgoSpringArrayReplayControl")
if control then
	control:Invoke("pause")
	control:Invoke("frame")
	return control:Invoke("status")
end
local storage = game:GetService("ServerStorage")
local installed = storage:FindFirstChild("RoAlgoSpringArrayReplayExtras")
local main = storage:FindFirstChild("RoAlgoMarketLab")
local modules = installed or (main and main:FindFirstChild("src"))
assert(modules and modules:FindFirstChild("SpringArrayReplay") and modules:FindFirstChild("SpringNodeColors"), "Install the eight spring presentation sidecar modules first")
if not game.CoreGui:FindFirstChild("RoAlgoSpringLiveControl") then
	assert(main and main:FindFirstChild("src"), "Installed trading viewer is required")
	require(main.src.SpringLive).replay({ runId = "live_lanes8_1791232619", baseUrl = "http://127.0.0.1:47627",
		index = 2269, frame = false, viewRun = "coupled", compareRun = "independent", rate = 6 })
end
return require(modules.SpringArrayReplay).start({ runId = "live_lanes8_1791232619", frame = true }):Invoke("status")
