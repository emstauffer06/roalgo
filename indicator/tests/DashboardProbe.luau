-- Studio-only behavioral smoke probe. All values below are synthetic test fixtures.
local Probe = {}

function Probe.run(parent)
	local module = script.Parent:FindFirstChild("Dashboard") or script.Parent.Parent:FindFirstChild("Dashboard", true)
	assert(module and module:IsA("ModuleScript"), "Dashboard module unavailable to probe")
	local Dashboard = require(module)
	local calls = {}
	local ui = Dashboard.mount(parent, {
		run = function(symbol, days) calls.run = { symbol, days } end,
		stop = function() calls.stop = true end,
		select = function(symbol) calls.select = symbol end,
		replay = function() calls.replay = true end,
		viewRig = function() calls.viewRig = true end,
	})
	local ok, result = pcall(function()
		assert(ui.screenGui.Parent == parent, "mount must use supplied Edit-mode GUI parent")
		ui:setStatus("SYNTHETIC UI PROBE — NOT MARKET RESULTS")
		ui:setProgress(16, 32)
		assert(ui.screenGui:GetAttribute("Progress") == 0.5, "progress must reflect supplied work")
		ui:testActivate("QQQ")
		ui:testActivate("20")
		ui:testActivate("Run")
		ui:testActivate("Stop")
		ui:testActivate("Replay")
		ui:testActivate("ViewPhysics")
		assert(calls.select == "QQQ" and calls.run[1] == "QQQ" and calls.run[2] == 20, "selected run arguments")
		assert(calls.stop and calls.replay and calls.viewRig, "control callbacks")
		ui:setSelection("SPY",60)
		ui:testActivate("Run")
		assert(calls.run[1] == "SPY" and calls.run[2] == 60, "programmatic run selection must update controls")
		ui:setSelection("QQQ",5)
		ui:testActivate("Run")
		assert(calls.run[1] == "QQQ" and calls.run[2] == 5, "programmatic QQQ selection must replace defaults")
		ui:testActivate("Collapse")
		assert(ui.screenGui:GetAttribute("Collapsed") == true, "collapse must preserve mounted GUI")
		ui:testActivate("Collapse")
		local rows = {}
		for index = 1, 32 do
			rows[index] = {
				t = 1700000000 + index * 300, label = "SYNTHETIC " .. tostring(index), close = 100 + index * 0.1,
				fast = math.sin(index / 5), medium = math.sin(index / 7), slow = math.sin(index / 9),
				signal = index == 8 and "BUY" or (index == 24 and "SELL" or "HOLD"),
				reason = "synthetic probe", equity = 10000, position = index >= 9 and index < 25,
				executions = index == 9 and { { side = "BUY", price = 100.9, t = 1700000000 + index * 300 } }
					or (index == 25 and { { side = "SELL", price = 102.5, t = 1700000000 + index * 300 } } or {}),
			}
		end
		ui:render({
			rows = rows, config = { symbol = "QQQ", feeBps = 1, slippageBps = 1 },
			summary = { netReturn = 0.025, maxDrawdown = 0.01, tradeCount = 1, winRate = 1, openPosition = false },
			trades = { { entryT = rows[9].t, exitT = rows[25].t, entryLabel = rows[9].label,
				exitLabel = rows[25].label, entryPrice = 100.9, exitPrice = 102.5, netReturn = 0.0158,
				reason = "synthetic probe" } },
		}, nil, { status = "Synthetic probe / untrained" })
		assert(ui.screenGui:FindFirstChild("NetReturnValue", true).Text == "+2.50%", "summary must render exact reported return")
		assert(ui.screenGui:GetAttribute("SignalMarkers") == 2, "signal markers must come from close decisions")
		assert(ui.screenGui:GetAttribute("ExecutionMarkers") == 2, "execution markers must come from fills")
		for index = 33, 260 do
			ui:append({ t = 1700000000 + index * 300, label = "SYNTHETIC " .. tostring(index),
				close = 100 + index / 100, fast = 0.2, medium = 0.1, slow = 0, signal = "HOLD", reason = "synthetic probe" })
		end
		assert(ui.screenGui:GetAttribute("ChartPoints") == 180, "chart window must remain bounded")
		local descendants = #ui.screenGui:GetDescendants()
		assert(descendants < 1800, "bounded chart must not accumulate per-bar objects")
		ui:render({ rows = {}, trades = {}, summary = {}, config = {} })
		assert(ui.screenGui:FindFirstChild("NetReturnValue", true).Text == "—", "missing metric must not become fabricated zero")
		return { passed = true, synthetic = true, callbackChecks = 6, windowBars = 180, descendantCount = descendants }
	end)
	local gui = ui.screenGui
	ui:destroy()
	assert(gui.Parent == nil, "destroy must remove the mounted GUI")
	if not ok then error(result) end
	return result
end

return Probe
