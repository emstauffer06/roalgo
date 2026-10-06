-- RoAlgo historical research dashboard. UI consumes reported Core values only.
-- Edit-mode compatible: mount under CoreGui; no plugin, PlayerGui, assets or network.
local Dashboard = {}
local WINDOW = 180
local WIDTH, HEIGHT = 1140, 830
local C = {
	bg = Color3.fromRGB(12, 17, 25), panel = Color3.fromRGB(18, 25, 36),
	raised = Color3.fromRGB(23, 32, 45), border = Color3.fromRGB(42, 55, 71),
	text = Color3.fromRGB(231, 238, 246), muted = Color3.fromRGB(143, 159, 181),
	faint = Color3.fromRGB(92, 110, 134), cyan = Color3.fromRGB(99, 214, 235),
	green = Color3.fromRGB(100, 224, 163), red = Color3.fromRGB(255, 127, 141),
	amber = Color3.fromRGB(240, 199, 113), violet = Color3.fromRGB(176, 158, 244),
}

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function number(value, places)
	return finite(value) and string.format("%." .. tostring(places or 2) .. "f", value) or "—"
end

local function percent(value, signed)
	if not finite(value) then return "—" end
	return string.format(signed and "%+.2f%%" or "%.2f%%", value * 100)
end

local function textOf(value, fallback)
	if value == nil or value == "" then return fallback or "—" end
	return tostring(value)
end

local function make(className, parent, properties)
	local item = Instance.new(className)
	for key, value in pairs(properties or {}) do item[key] = value end
	item.Parent = parent
	return item
end

local function corner(parent, radius)
	make("UICorner", parent, { CornerRadius = UDim.new(0, radius or 8) })
end

local function border(parent, color)
	make("UIStroke", parent, { Color = color or C.border, Thickness = 1, Transparency = 0.2 })
end

local function panel(parent, name, x, y, w, h)
	local result = make("Frame", parent, { Name = name, Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(w, h), BackgroundColor3 = C.panel, BorderSizePixel = 0 })
	corner(result, 10)
	border(result)
	return result
end

local function label(parent, name, value, x, y, w, h, size, color, font)
	return make("TextLabel", parent, { Name = name, Text = value, Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(w, h), BackgroundTransparency = 1, BorderSizePixel = 0,
		Font = font or Enum.Font.Gotham, TextSize = size or 13, TextColor3 = color or C.text,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd, RichText = false })
end

local function rule(parent, y, w)
	return make("Frame", parent, { Position = UDim2.fromOffset(16, y), Size = UDim2.fromOffset(w, 1),
		BackgroundColor3 = C.border, BackgroundTransparency = 0.4, BorderSizePixel = 0 })
end

local function positiveColor(value)
	return finite(value) and (value < 0 and C.red or C.green) or C.text
end

function Dashboard.mount(parent, callbacks)
	assert(typeof(parent) == "Instance", "Dashboard.mount requires a GUI parent such as CoreGui")
	callbacks = callbacks or {}
	local ui = { buttons = {}, _handlers = {}, _connections = {}, _rows = {}, _destroyed = false,
		_symbol = "SPY", _days = 5, _collapsed = false, _trades = {}, _summary = {}, _config = {} }
	local gui = make("ScreenGui", parent, { Name = "RoAlgoDashboard", ResetOnSpawn = false,
		IgnoreGuiInset = true, DisplayOrder = 50, ZIndexBehavior = Enum.ZIndexBehavior.Sibling })
	ui.screenGui = gui
	gui:SetAttribute("HistoricalResearch", true)
	gui:SetAttribute("Collapsed", false)
	local surface = make("Frame", gui, { Name = "ResponsiveSurface", Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1, BorderSizePixel = 0 })
	local main = make("Frame", surface, { Name = "Terminal", AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(WIDTH, HEIGHT),
		BackgroundColor3 = C.bg, BorderSizePixel = 0 })
	corner(main, 14)
	border(main)
	local scale = make("UIScale", main, { Scale = 1 })
	local function resize()
		local size = surface.AbsoluteSize
		if size.X <= 0 or size.Y <= 0 then return end
		scale.Scale = math.min(1, (size.X - 28) / WIDTH, (size.Y - 28) / HEIGHT)
	end
	table.insert(ui._connections, surface:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize))
	resize()

	label(main, "Brand", "ROALGO", 24, 18, 174, 33, 27, C.text, Enum.Font.GothamBold)
	make("Frame", main, { Position = UDim2.fromOffset(178, 27), Size = UDim2.fromOffset(5, 18),
		BackgroundColor3 = C.cyan, BorderSizePixel = 0 })
	label(main, "Subtitle", "NATIVE PHYSICS  /  MARKET RESEARCH", 202, 21, 460, 18, 11, C.muted, Enum.Font.GothamMedium)
	label(main, "Context", "5-minute completed bars   ·   Long / flat   ·   Next-open execution", 202, 42, 590, 16, 11, C.faint)
	local badge = panel(main, "HistoricalBadge", 848, 22, 224, 29)
	badge.BackgroundColor3 = Color3.fromRGB(43, 36, 24)
	label(badge, "Text", "HISTORICAL  /  EXPLORATORY", 12, 0, 206, 29, 10, C.amber, Enum.Font.GothamBold)

	local function setStatus(value)
		if ui._destroyed then return end
		ui._status.Text = textOf(value, "Ready")
		local lower = string.lower(tostring(value or ""))
		ui._status.TextColor3 = (string.find(lower, "error", 1, true) or string.find(lower, "failed", 1, true)) and C.red or C.muted
		ui._compactStatus.Text = textOf(value, "Ready")
		gui:SetAttribute("Status", textOf(value, "Ready"))
	end
	local function invoke(name, ...)
		local callback = callbacks[name]
		if type(callback) ~= "function" then return end
		local ok, err = pcall(callback, ...)
		if not ok then setStatus("Error: " .. tostring(err)) end
	end
	local function button(parentFrame, id, caption, x, y, w, h, action, style)
		local b = make("TextButton", parentFrame, { Name = id, Text = caption,
			Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h),
			BackgroundColor3 = style == "primary" and C.cyan or C.raised, BorderSizePixel = 0,
			TextColor3 = style == "primary" and C.bg or C.text, Font = Enum.Font.GothamMedium,
			TextSize = 12, AutoButtonColor = true, Active = true, Interactable = true })
		corner(b, 6)
		if style ~= "primary" then border(b) end
		local function activate()
			if not ui._destroyed then action() end
		end
		ui.buttons[id] = b
		ui._handlers[id] = activate
		-- Desktop Studio controls use the mouse event, not the client-only Activated event.
		table.insert(ui._connections, b.MouseButton1Click:Connect(activate))
		return b
	end
	local compact = panel(surface, "CompactTerminal", 14, 14, 342, 96)
	compact.Visible = false
	label(compact, "Brand", "ROALGO  /  HISTORICAL RESEARCH", 14, 10, 260, 19, 11, C.cyan, Enum.Font.GothamBold)
	ui._compactStatus = label(compact, "Status", "Ready", 14, 36, 312, 20, 11, C.muted)
	local function setCollapsed(value)
		ui._collapsed = value == true
		main.Visible = not ui._collapsed
		compact.Visible = ui._collapsed
		gui:SetAttribute("Collapsed", ui._collapsed)
	end
	local function collapse() setCollapsed(not ui._collapsed) end
	button(main, "Collapse", "−", 1084, 20, 32, 32, collapse)
	button(compact, "Expand", "Open terminal", 14, 65, 147, 22, collapse)
	button(compact, "CompactStop", "Stop run", 178, 65, 148, 22, function() invoke("stop") end)

	local toolbar = panel(main, "Controls", 24, 76, 1092, 57)
	label(toolbar, "SymbolLabel", "SYMBOL", 14, 6, 126, 12, 8, C.faint, Enum.Font.GothamBold)
	local function updateSelectors()
		gui:SetAttribute("SelectedSymbol", ui._symbol)
		gui:SetAttribute("SelectedSessions", ui._days)
		for _, symbol in ipairs({ "SPY", "QQQ" }) do
			ui.buttons[symbol].BackgroundColor3 = ui._symbol == symbol and C.cyan or C.raised
			ui.buttons[symbol].TextColor3 = ui._symbol == symbol and C.bg or C.text
		end
		for _, days in ipairs({ 5, 20, 60 }) do
			ui.buttons[tostring(days)].BackgroundColor3 = ui._days == days and Color3.fromRGB(50, 71, 91) or C.raised
			ui.buttons[tostring(days)].TextColor3 = ui._days == days and C.cyan or C.muted
		end
	end
	for index, symbol in ipairs({ "SPY", "QQQ" }) do
		button(toolbar, symbol, symbol, 14 + (index - 1) * 69, 23, 61, 25, function()
			ui._symbol = symbol
			updateSelectors()
			invoke("select", symbol)
		end)
	end
	label(toolbar, "SessionsLabel", "HISTORICAL SESSIONS", 178, 6, 200, 12, 8, C.faint, Enum.Font.GothamBold)
	for index, days in ipairs({ 5, 20, 60 }) do
		button(toolbar, tostring(days), tostring(days), 178 + (index - 1) * 49, 23, 41, 25, function()
			ui._days = days
			updateSelectors()
		end)
	end
	button(toolbar, "Run", "▶  Run history", 350, 13, 146, 32, function() invoke("run", ui._symbol, ui._days) end, "primary")
	button(toolbar, "Stop", "■  Stop", 508, 13, 88, 32, function() invoke("stop") end)
	button(toolbar, "Replay", "↻  Replay", 608, 13, 115, 32, function() invoke("replay") end)
	button(toolbar, "ViewPhysics", "View physics  ↗", 735, 13, 147, 32, function() invoke("viewRig") end)
	ui._progressText = label(toolbar, "ProgressLabel", "Ready", 902, 15, 174, 28, 11, C.muted)
	ui._progressText.TextXAlignment = Enum.TextXAlignment.Right
	updateSelectors()
	function ui:setSelection(symbol, days)
		assert(symbol == "SPY" or symbol == "QQQ", "Unsupported dashboard symbol")
		assert(days == 5 or days == 20 or days == 60, "Unsupported dashboard session count")
		self._symbol, self._days = symbol, days
		updateSelectors()
	end
	local progressTrack = make("Frame", main, { Name = "ProgressTrack", Position = UDim2.fromOffset(26, 138),
		Size = UDim2.fromOffset(1088, 2), BackgroundColor3 = C.border, BorderSizePixel = 0 })
	ui._progressFill = make("Frame", progressTrack, { Name = "ProgressFill", Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = C.cyan, BorderSizePixel = 0 })

	ui._metrics = {}
	for index, definition in ipairs({
		{ "NetReturn", "NET RETURN", "After execution costs" },
		{ "Drawdown", "MAX DRAWDOWN", "From marked equity" },
		{ "Trades", "CLOSED TRADES", "Executed round trips" },
		{ "WinRate", "WIN RATE", "Closed trades only" },
	}) do
		local card = panel(main, definition[1] .. "Card", 24 + (index - 1) * 277, 151, 261, 75)
		label(card, "Heading", definition[2], 14, 11, 233, 12, 9, C.muted, Enum.Font.GothamBold)
		ui._metrics[definition[1]] = label(card, definition[1] .. "Value", "—", 14, 27, 236, 27, 25, C.text, Enum.Font.GothamMedium)
		label(card, "Explanation", definition[3], 14, 57, 236, 11, 9, C.faint)
	end

	local chart = panel(main, "PriceChart", 24, 239, 750, 273)
	ui._chartTitle = label(chart, "Title", "SPY  /  CLOSE PRICE", 16, 13, 270, 20, 13, C.text, Enum.Font.GothamBold)
	ui._lastPrice = label(chart, "LastPrice", "—", 550, 10, 182, 23, 18, C.cyan, Enum.Font.GothamMedium)
	ui._lastPrice.TextXAlignment = Enum.TextXAlignment.Right
	label(chart, "MarkerLegend", "B / S  close signal     ◆  executed fill", 16, 36, 450, 15, 10, C.muted)
	ui._windowText = label(chart, "WindowLabel", "Waiting for historical bars", 425, 38, 307, 13, 9, C.faint)
	ui._windowText.TextXAlignment = Enum.TextXAlignment.Right
	local plotW, plotH = 651, 155
	local plot = make("Frame", chart, { Name = "ClosePlot", Position = UDim2.fromOffset(18, 65),
		Size = UDim2.fromOffset(plotW, plotH), BackgroundTransparency = 1, BorderSizePixel = 0, ClipsDescendants = false })
	ui._priceAxes = {}
	for index = 1, 5 do
		local y = (index - 1) * plotH / 4
		make("Frame", plot, { Name = "Grid", Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(plotW, 1),
			BackgroundColor3 = C.border, BackgroundTransparency = 0.58, BorderSizePixel = 0 })
		ui._priceAxes[index] = label(chart, "PriceAxis" .. index, "—", 677, 57 + y, 54, 17, 10, C.faint, Enum.Font.Code)
		ui._priceAxes[index].TextXAlignment = Enum.TextXAlignment.Right
	end
	ui._chartEmpty = label(plot, "EmptyState", "RUN A HISTORICAL SESSION", 30, 49, 591, 24, 15, C.muted, Enum.Font.GothamMedium)
	ui._chartEmpty.TextXAlignment = Enum.TextXAlignment.Center
	ui._chartEmptyDetail = label(plot, "EmptyDetail", "Measured physics → close decision → next-open fill", 20, 78, 611, 19, 11, C.faint)
	ui._chartEmptyDetail.TextXAlignment = Enum.TextXAlignment.Center
	ui._firstTime = label(chart, "FirstTime", "—", 18, 232, 353, 16, 10, C.faint)
	ui._lastTime = label(chart, "LastTime", "—", 381, 232, 351, 16, 10, C.faint)
	ui._lastTime.TextXAlignment = Enum.TextXAlignment.Right
	label(chart, "TimeBasis", "NEW YORK TIME  ·  RECENT 180 BARS  ·  GAPS ARE NOT CONNECTED", 18, 254, 705, 11, 8, C.faint)

	local oscillator = panel(main, "Oscillator", 24, 525, 750, 112)
	label(oscillator, "Title", "MEASURED NATIVE PHYSICS", 16, 12, 350, 16, 10, C.muted, Enum.Font.GothamBold)
	label(oscillator, "FastLegend", "━  FAST", 477, 12, 91, 16, 10, C.cyan)
	local oscW, oscH = 651, 47
	local oscPlot = make("Frame", oscillator, { Name = "ResponsePlot", Position = UDim2.fromOffset(18, 41),
		Size = UDim2.fromOffset(oscW, oscH), BackgroundTransparency = 1, BorderSizePixel = 0 })
	make("Frame", oscPlot, { Position = UDim2.fromOffset(0, oscH / 2), Size = UDim2.fromOffset(oscW, 1),
		BackgroundColor3 = C.border, BorderSizePixel = 0 })
	ui._oscTop = label(oscillator, "OscTop", "—", 677, 35, 55, 16, 9, C.faint, Enum.Font.Code)
	ui._oscBottom = label(oscillator, "OscBottom", "—", 677, 79, 55, 16, 9, C.faint, Enum.Font.Code)
	label(oscillator, "OscNote", "Signed engine displacement  ·  Shared zero / auto scale", 18, 96, 708, 11, 8, C.faint)
	-- Separate legend colors avoid implying that both traces are the same channel.
	label(oscillator, "SlowLegend", "━  SLOW", 575, 12, 154, 16, 10, C.violet)

	local side = panel(main, "ResearchContext", 790, 239, 326, 398)
	label(side, "ControlTitle", "NUMERICAL CONTROL", 16, 15, 294, 17, 10, C.muted, Enum.Font.GothamBold)
	label(side, "ControlExplanation", "Same bars, execution rules and costs", 16, 36, 294, 16, 10, C.faint)
	label(side, "NativeHeading", "NATIVE", 104, 64, 90, 13, 9, C.cyan, Enum.Font.GothamBold)
	label(side, "NumericHeading", "CONTROL", 219, 64, 91, 13, 9, C.violet, Enum.Font.GothamBold)
	ui._comparison = {}
	for index, definition in ipairs({ { "Return", "Return" }, { "Drawdown", "Drawdown" }, { "Trades", "Trades" } }) do
		local y = 88 + (index - 1) * 26
		label(side, definition[1] .. "Label", definition[2], 16, y, 86, 18, 11, C.muted)
		ui._comparison[definition[1] .. "Native"] = label(side, definition[1] .. "Native", "—", 104, y, 95, 18, 12, C.text, Enum.Font.Code)
		ui._comparison[definition[1] .. "Control"] = label(side, definition[1] .. "Control", "—", 219, y, 91, 18, 12, C.text, Enum.Font.Code)
	end
	rule(side, 172, 294)
	label(side, "ModelHeading", "EXPERIMENTAL ENTRY FILTER", 16, 184, 294, 17, 10, C.muted, Enum.Font.GothamBold)
	ui._metaStatus = label(side, "ModelStatus", "Untrained", 16, 208, 294, 21, 15, C.amber, Enum.Font.GothamMedium)
	ui._metaDetail = label(side, "ModelDetail", "No fitted model supplied", 16, 233, 294, 38, 10, C.faint)
	ui._metaDetail.TextWrapped = true
	ui._metaDetail.TextTruncate = Enum.TextTruncate.None
	ui._metaDetail.TextYAlignment = Enum.TextYAlignment.Top
	rule(side, 279, 294)
	label(side, "StateHeading", "LATEST COMPLETED BAR", 16, 290, 294, 15, 10, C.muted, Enum.Font.GothamBold)
	ui._signal = label(side, "Signal", "WAITING", 16, 312, 137, 24, 19, C.muted, Enum.Font.GothamBold)
	ui._position = label(side, "Position", "Position —", 161, 315, 149, 18, 11, C.faint)
	ui._position.TextXAlignment = Enum.TextXAlignment.Right
	ui._reason = label(side, "DecisionReason", "Run history to generate causal signals.", 16, 343, 294, 39, 11, C.muted)
	ui._reason.TextWrapped = true
	ui._reason.TextTruncate = Enum.TextTruncate.None
	ui._reason.TextYAlignment = Enum.TextYAlignment.Top

	local ledger = panel(main, "TradeLedger", 24, 650, 1092, 131)
	label(ledger, "Title", "RECENT EXECUTED TRADES", 16, 10, 340, 18, 10, C.muted, Enum.Font.GothamBold)
	ui._ledgerNote = label(ledger, "LedgerNote", "Open positions are marked, never counted as an invented sale", 432, 11, 642, 16, 9, C.faint)
	ui._ledgerNote.TextXAlignment = Enum.TextXAlignment.Right
	for _, column in ipairs({ { "ENTRY → EXIT (NEW YORK)", 16, 292 }, { "FILL PRICES", 316, 190 },
		{ "NET RETURN", 516, 134 }, { "EXIT REASON", 664, 410 } }) do
		label(ledger, "Column", column[1], column[2], 35, column[3], 11, 8, C.faint, Enum.Font.GothamBold)
	end
	ui._ledgerRows = {}
	for index = 1, 4 do
		local y = 52 + (index - 1) * 18
		ui._ledgerRows[index] = {
			time = label(ledger, "TradeTime" .. index, "", 16, y, 292, 17, 10, C.muted),
			price = label(ledger, "TradePrices" .. index, "", 316, y, 190, 17, 10, C.text, Enum.Font.Code),
			pnl = label(ledger, "TradeReturn" .. index, "", 516, y, 134, 17, 10, C.text, Enum.Font.Code),
			reason = label(ledger, "TradeReason" .. index, "", 664, y, 410, 17, 10, C.muted),
		}
	end
	ui._ledgerEmpty = label(ledger, "EmptyLedger", "No closed trades reported. Signals and pending orders are not executed trades.", 16, 61, 1058, 21, 11, C.faint)
	ui._status = label(main, "RunStatus", "Ready · select a symbol and run history", 24, 792, 688, 17, 11, C.muted)
	ui._costs = label(main, "Costs", "Costs — awaiting run configuration", 715, 792, 401, 17, 10, C.faint)
	ui._costs.TextXAlignment = Enum.TextXAlignment.Right
	label(main, "Disclosure", "EXPLORATORY HISTORICAL RESEARCH  ·  NO LIVE ORDERS  ·  PERFORMANCE IS NOT PROOF OF AN EDGE", 24, 814, 1092, 10, 8, C.faint)

	local priceLines, fastLines, slowLines, signalMarkers, executionMarkers = {}, {}, {}, {}, {}
	local function getLine(pool, index, destination, color)
		if not pool[index] then
			pool[index] = make("Frame", destination, { Name = "CurveSegment", AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundColor3 = color, BorderSizePixel = 0, ZIndex = 2 })
		end
		return pool[index]
	end
	local function drawLine(pool, index, destination, color, x1, y1, x2, y2, visible)
		local line = getLine(pool, index, destination, color)
		line.Visible = visible
		if visible then
			local dx, dy = x2 - x1, y2 - y1
			line.Position = UDim2.fromOffset((x1 + x2) / 2, (y1 + y2) / 2)
			line.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy) + 0.6, 1.7)
			line.Rotation = math.deg(math.atan2(dy, dx))
		end
	end
	local function hideAfter(pool, count)
		for index = count + 1, #pool do pool[index].Visible = false end
	end
	local function connected(previous, row)
		if finite(previous.t) and finite(row.t) then return row.t - previous.t == 300 end
		return true
	end
	local function executionList(row)
		return type(row.executions) == "table" and row.executions or {}
	end
	local function paintChart()
		local rows = ui._rows
		local count = #rows
		local low, high, responseRange = math.huge, -math.huge, 0
		for _, row in ipairs(rows) do
			if finite(row.close) then low = math.min(low, row.close); high = math.max(high, row.close) end
			for _, execution in ipairs(executionList(row)) do
				if finite(execution.price) then low = math.min(low, execution.price); high = math.max(high, execution.price) end
			end
			for _, key in ipairs({ "fast", "slow" }) do
				if finite(row[key]) then responseRange = math.max(responseRange, math.abs(row[key])) end
			end
		end
		local hasPrices = low ~= math.huge
		if not hasPrices then low, high = 0, 1 end
		local pad = math.max((high - low) * 0.14, math.abs(high) * 0.0001, 0.001)
		low, high = low - pad, high + pad
		responseRange = math.max(responseRange * 1.12, 0.0001)
		local function x(index) return count <= 1 and plotW / 2 or (index - 1) * plotW / (count - 1) end
		local function py(value) return plotH - (value - low) / (high - low) * plotH end
		local function oy(value) return oscH / 2 - value / responseRange * (oscH / 2) end
		for index, axis in ipairs(ui._priceAxes) do axis.Text = hasPrices and number(high - (index - 1) * (high - low) / 4) or "—" end
		ui._oscTop.Text = count > 0 and number(responseRange, 3) or "—"
		ui._oscBottom.Text = count > 0 and number(-responseRange, 3) or "—"
		ui._chartEmpty.Visible = count == 0
		ui._chartEmptyDetail.Visible = count == 0
		local signalCount, executionCount = 0, 0
		for index, row in ipairs(rows) do
			if index > 1 then
				local previous = rows[index - 1]
				local join = connected(previous, row)
				for _, track in ipairs({ { "close", priceLines, plot, C.cyan }, { "fast", fastLines, oscPlot, C.cyan }, { "slow", slowLines, oscPlot, C.violet } }) do
					local a, b = previous[track[1]], row[track[1]]
					local valid = join and finite(a) and finite(b)
					local map = track[1] == "close" and py or oy
					drawLine(track[2], index - 1, track[3], track[4], x(index - 1), valid and map(a) or 0, x(index), valid and map(b) or 0, valid)
				end
			end
			if (row.signal == "BUY" or row.signal == "SELL") and finite(row.close) then
				signalCount += 1
				if not signalMarkers[signalCount] then
					local marker = label(plot, "SignalMarker", "", 0, 0, 17, 16, 9, C.bg, Enum.Font.GothamBold)
					marker.AnchorPoint = Vector2.new(0.5, 0.5)
					marker.TextXAlignment = Enum.TextXAlignment.Center
					marker.BackgroundTransparency = 0
					marker.ZIndex = 4
					corner(marker, 4)
					signalMarkers[signalCount] = marker
				end
				local marker = signalMarkers[signalCount]
				marker.Visible = true
				marker.Text = row.signal == "BUY" and "B" or "S"
				marker.BackgroundColor3 = row.signal == "BUY" and C.green or C.red
				marker.Position = UDim2.fromOffset(x(index), math.clamp(py(row.close) + (row.signal == "BUY" and 14 or -14), 8, plotH - 8))
				marker:SetAttribute("Timestamp", finite(row.t) and row.t + 300 or nil)
				marker:SetAttribute("BarTimestamp", row.t)
				marker:SetAttribute("Meaning", "Close-time signal")
			end
			for _, execution in ipairs(executionList(row)) do
				if finite(execution.price) then
					executionCount += 1
					if not executionMarkers[executionCount] then
						local marker = make("Frame", plot, { Name = "ExecutionMarker", Size = UDim2.fromOffset(7, 7),
							AnchorPoint = Vector2.new(0.5, 0.5), Rotation = 45, BackgroundColor3 = C.text,
							BorderSizePixel = 0, ZIndex = 3 })
						border(marker, C.bg)
						executionMarkers[executionCount] = marker
					end
					local marker = executionMarkers[executionCount]
					marker.Visible = true
					marker.Position = UDim2.fromOffset(x(index), py(execution.price))
					marker.BackgroundColor3 = execution.side == "BUY" and C.green or C.red
					marker:SetAttribute("Timestamp", execution.t or row.t)
					marker:SetAttribute("Meaning", "Actual execution")
				end
			end
		end
		for _, pool in ipairs({ priceLines, fastLines, slowLines }) do hideAfter(pool, math.max(0, count - 1)) end
		hideAfter(signalMarkers, signalCount)
		hideAfter(executionMarkers, executionCount)
		gui:SetAttribute("ChartPoints", count)
		gui:SetAttribute("SignalMarkers", signalCount)
		gui:SetAttribute("ExecutionMarkers", executionCount)
		ui._windowText.Text = count > 0 and tostring(count) .. " recent completed bars" or "Waiting for historical bars"
		local latest = rows[count]
		ui._firstTime.Text = count > 0 and textOf(rows[1].label) or "—"
		ui._lastTime.Text = latest and textOf(latest.label) or "—"
		ui._lastPrice.Text = latest and number(latest.close) or "—"
		ui._signal.Text = latest and textOf(latest.signal, "HOLD") or "WAITING"
		ui._signal.TextColor3 = latest and (latest.signal == "BUY" and C.green or latest.signal == "SELL" and C.red or C.muted) or C.muted
		ui._reason.Text = latest and textOf(latest.reason, "No decision reason supplied") or "Run history to generate causal signals."
		ui._position.Text = latest and latest.position ~= nil and (latest.position and "Position LONG" or "Position FLAT") or "Position —"
		ui._position.TextColor3 = latest and latest.position and C.green or C.faint
	end

	function ui:setStatus(value) setStatus(value) end
	function ui:setCollapsed(value)
		if not self._destroyed then setCollapsed(value) end
	end
	function ui:setProgress(done, total)
		if self._destroyed then return end
		local ratio = finite(done) and finite(total) and total > 0 and math.clamp(done / total, 0, 1) or 0
		self._progressFill.Size = UDim2.fromScale(ratio, 1)
		self._progressText.Text = finite(done) and finite(total) and total > 0
			and string.format("%d / %d  ·  %.0f%%", done, total, ratio * 100) or "Ready"
		gui:SetAttribute("Progress", ratio)
	end

	function ui:render(result, comparison, meta)
		if self._destroyed then return end
		result = type(result) == "table" and result or {}
		local summary = type(result.summary) == "table" and result.summary or {}
		local control = type(comparison) == "table" and (comparison.summary or comparison) or {}
		local config = type(result.config) == "table" and result.config or {}
		self._summary, self._config = summary, config
		self._trades = type(result.trades) == "table" and result.trades or {}
		self._rows = {}
		local sourceRows = type(result.rows) == "table" and result.rows or {}
		for index = math.max(1, #sourceRows - WINDOW + 1), #sourceRows do table.insert(self._rows, sourceRows[index]) end
		self._chartTitle.Text = textOf(config.symbol, self._symbol) .. "  /  CLOSE PRICE"
		self._metrics.NetReturn.Text = percent(summary.netReturn, true)
		self._metrics.NetReturn.TextColor3 = positiveColor(summary.netReturn)
		self._metrics.Drawdown.Text = percent(summary.maxDrawdown, false)
		self._metrics.Trades.Text = finite(summary.tradeCount) and tostring(summary.tradeCount) or "—"
		self._metrics.WinRate.Text = percent(summary.winRate, false)
		for _, entry in ipairs({ { "Native", summary }, { "Control", control } }) do
			self._comparison["Return" .. entry[1]].Text = percent(entry[2].netReturn, true)
			self._comparison["Return" .. entry[1]].TextColor3 = positiveColor(entry[2].netReturn)
			self._comparison["Drawdown" .. entry[1]].Text = percent(entry[2].maxDrawdown, false)
			self._comparison["Trades" .. entry[1]].Text = finite(entry[2].tradeCount) and tostring(entry[2].tradeCount) or "—"
		end
		self._costs.Text = "Each side: fee " .. number(config.feeBps, 1) .. " bp + slippage " .. number(config.slippageBps, 1) .. " bp"
		meta = type(meta) == "table" and meta or {}
		self._metaStatus.Text = textOf(meta.status, "Untrained")
		self._metaDetail.Text = textOf(meta.reason, "No fitted model supplied")
		if finite(meta.trainTrades) then
			self._metaDetail.Text = tostring(meta.trainTrades) .. " earlier training trades"
				.. (meta.cutoffLabel and " · evaluation starts " .. tostring(meta.cutoffLabel) or "")
				.. "\n" .. textOf(meta.reason, "Chronological exploratory split; score is not confidence.")
		end
		self._ledgerEmpty.Visible = #self._trades == 0
		self._ledgerNote.Text = summary.openPosition == true and "OPEN EXPOSURE MARKED AT LAST CLOSE  ·  NO FINAL SALE INVENTED"
			or "Open positions are marked, never counted as an invented sale"
		self._ledgerNote.TextColor3 = summary.openPosition == true and C.amber or C.faint
		for index, line in ipairs(self._ledgerRows) do
			local trade = self._trades[#self._trades - index + 1]
			line.time.Text = trade and textOf(trade.entryLabel, tostring(trade.entryT or "—")) .. " → " .. textOf(trade.exitLabel, tostring(trade.exitT or "—")) or ""
			line.price.Text = trade and number(trade.entryPrice) .. " → " .. number(trade.exitPrice) or ""
			line.pnl.Text = trade and percent(trade.netReturn, true) or ""
			line.pnl.TextColor3 = trade and positiveColor(trade.netReturn) or C.text
			line.reason.Text = trade and textOf(trade.reason) .. (trade.ambiguous and " · STOP-FIRST AMBIGUITY" or "") or ""
		end
		paintChart()
	end

	function ui:append(row)
		if self._destroyed or type(row) ~= "table" then return end
		-- Controller throttles this call. GUI objects are pooled and bounded by WINDOW.
		table.insert(self._rows, row)
		if #self._rows > WINDOW then table.remove(self._rows, 1) end
		paintChart()
	end

	function ui:testActivate(name)
		assert(self._handlers[name], "Unknown dashboard control: " .. tostring(name))
		self._handlers[name]()
	end

	function ui:destroy()
		if self._destroyed then return end
		self._destroyed = true
		for _, connection in ipairs(self._connections) do connection:Disconnect() end
		self._connections = {}
		self._rows, self._trades, self._handlers, self.buttons = {}, {}, {}, {}
		gui:Destroy()
	end

	ui:render({})
	return ui
end

return Dashboard
