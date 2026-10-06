-- Spring Indicator price chart (owner request, 2026-10-05: "include the actual chart where it buys and sells as a visual while
-- the recorded visual of the springs replay"; then "can the buy and sell decision indicator be bigger ... and it doesn't
-- really show me its PNL"). Pure presentation, docked bottom-left beside the SpringPanel.
--   Price pane: SPY 5-minute candles UP TO the replay cursor only (never a bar after the cursor), large outlined decision
--   markers with captions on the decision bar, fill dots at the fill price on the fill bar, the closed trade's net P&L at
--   its exit fill, the open position (tinted columns) and the open trade's stop/target.
--   P&L pane: cumulative net P&L of the selected run (equity - 1) per bar, green above zero and red below.
-- P&L comes only from the ledger equity in the rows it is given (fees, slippage and borrow included); it never computes
-- signals or ledgers. All Roblox globals are injectable through options.env for the CLI spec.
local SpringChart = {}

local GUI_NAME = "RoAlgoSpringChart"
local WINDOWS = { { id = "1D", bars = 78 }, { id = "3D", bars = 234 }, { id = "1W", bars = 390 } }
local MAX_BARS = 390
local MAX_MARKS = 160
local HEADER = 26
local PAD_LEFT, PAD_RIGHT, PAD_TOP, PAD_BOTTOM = 10, 78, 8, 20
local PRICE_SHARE = 0.72 -- of the plot height; the P&L pane takes the rest
local PANE_GAP = 6
local MIN_RATE, MAX_RATE = 0.25, 30 -- replay speed, candles per second
local SPEED_LEFT, TRACK_WIDTH = 206, 150
local SPEED_WIDTH = 214 + TRACK_WIDTH
local ROBLOX_GLOBALS = { "Instance", "UDim2", "UDim", "Color3", "Enum", "Vector2" }

local Chart = {}
Chart.__index = Chart

local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function isInteger(x) return finite(x) and x % 1 == 0 end
local function fail(message) error("SpringChart: " .. message, 3) end
local function fmt(x) return if finite(x) then string.format("%.2f", x) else "—" end
local function pct(x) return if finite(x) then string.format("%+.2f%%", x * 100) else "—" end

local function resolveEnv(options)
	local injected = options.env
	if injected ~= nil and type(injected) ~= "table" then fail("options.env must be a table") end
	local defaults = { Instance = Instance, UDim2 = UDim2, UDim = UDim, Color3 = Color3, Enum = Enum, Vector2 = Vector2 }
	local env = {}
	for _, name in ROBLOX_GLOBALS do
		local value = injected and injected[name]
		if value == nil then value = defaults[name] end
		if value == nil then fail("Roblox global " .. name .. " is unavailable; inject it through options.env") end
		env[name] = value
	end
	return env
end

local function barsProblem(bars)
	if type(bars) ~= "table" then return "bars table required" end
	local n = bars.t and #bars.t
	if not isInteger(n) or n < 1 then return "bars.t must be a non-empty array" end
	for _, key in { "o", "h", "l", "c" } do
		if type(bars[key]) ~= "table" or #bars[key] ~= n then return "bars." .. key .. " must hold " .. n .. " values" end
	end
	return nil
end

-- Exact per-trade net P&L from ledger equity (full-equity sizing, flat between trades):
-- net = equity at the close of the exit-fill bar / equity at the close of the bar before the entry fill - 1.
-- Only rows 1..index are read. Returns trades (exitRow -> net), wins, losses, the open trade's marked P&L and the last net.
local function tradeStats(rows, index)
	local nets, wins, losses, last = {}, 0, 0, nil
	local entryEquity = nil
	for i = 1, index do
		local r = rows[i]
		for _, f in r.ex or {} do
			if f.a == "BUY" or f.a == "SELL" then
				entryEquity = if i > 1 then rows[i - 1].eq else 1
			elseif f.a == "CLOSE" and entryEquity and finite(r.eq) and finite(entryEquity) and entryEquity > 0 then
				local net = r.eq / entryEquity - 1
				nets[i] = net
				last = net
				if net > 0 then wins += 1 elseif net < 0 then losses += 1 end
				entryEquity = nil
			end
		end
	end
	local cur = rows[index]
	local open = if cur.po ~= 0 and entryEquity and finite(cur.eq) and entryEquity > 0 then cur.eq / entryEquity - 1 else nil
	return nets, wins, losses, open, last
end

function SpringChart.mount(parent, options)
	options = options or {}
	if type(options) ~= "table" then fail("options must be a table") end
	local env = resolveEnv(options)
	if parent == nil or (type(parent) ~= "table" and type(parent) ~= "userdata") then fail("parent instance required") end
	local rightInset = options.rightInset or 452
	local height = options.height or 310
	local UD2, C3, E = env.UDim2, env.Color3, env.Enum
	-- Terminal palette (owner request, 2026-10-05): black, amber accent, white values, green up / red down, blue target.
	local C = {
		bg = C3.fromRGB(0, 0, 0), plot = C3.fromRGB(8, 8, 8), grid = C3.fromRGB(40, 40, 40), text = C3.fromRGB(240, 240, 240),
		muted = C3.fromRGB(150, 150, 150), up = C3.fromRGB(74, 232, 90), down = C3.fromRGB(255, 67, 61),
		long = C3.fromRGB(0, 110, 40), short = C3.fromRGB(130, 20, 20), close = C3.fromRGB(251, 139, 30),
		stop = C3.fromRGB(255, 67, 61), target = C3.fromRGB(32, 104, 255), cursor = C3.fromRGB(240, 240, 240),
		outline = C3.fromRGB(0, 0, 0), buy = C3.fromRGB(74, 232, 90), sell = C3.fromRGB(255, 67, 61),
		accent = C3.fromRGB(251, 139, 30), warn = C3.fromRGB(255, 214, 0),
	}
	local self = setmetatable({ env = env, _destroyed = false, _connections = {}, _handlers = {}, _window = 78, _hidden = false,
		_colors = C, _last = nil }, Chart)
	local created = {}
	local function make(className, parentInstance, props)
		local instance = env.Instance.new(className)
		table.insert(created, instance)
		for key, value in props do instance[key] = value end
		if parentInstance then instance.Parent = parentInstance end
		return instance
	end
	self._created = created

	local gui = make("ScreenGui", nil, { Name = GUI_NAME, ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 40,
		ZIndexBehavior = E.ZIndexBehavior.Sibling })
	gui:SetAttribute("SpringChart", true)
	self.screenGui = gui
	local frame = make("Frame", gui, { Name = "Chart", AnchorPoint = env.Vector2.new(0, 1), Position = UD2.new(0, 12, 1, -12),
		Size = UD2.new(1, -(rightInset + 12), 0, height), BackgroundColor3 = C.bg, BackgroundTransparency = 0.02, BorderSizePixel = 0 })
	make("UIStroke", frame, { Color = C.grid, Thickness = 1 })
	make("UICorner", frame, { CornerRadius = env.UDim.new(0, 8) })
	self._frame = frame
	local function label(parentInstance, name, props)
		local base = { Name = name, BackgroundTransparency = 1, TextColor3 = C.text, Font = E.Font.Gotham, TextSize = 11,
			TextXAlignment = E.TextXAlignment.Left, TextYAlignment = E.TextYAlignment.Center, Text = "" }
		for k, v in props do base[k] = v end
		return make("TextLabel", parentInstance, base)
	end
	self._title = label(frame, "Title", { Position = UD2.fromOffset(12, 4), Size = UD2.fromOffset(190, 18), Font = E.Font.GothamBold,
		TextColor3 = C.accent, Text = "SPY 5-MIN · DECISIONS" })
	self._readout = label(frame, "Readout", { AnchorPoint = env.Vector2.new(1, 0), Position = UD2.new(1, -150, 0, 4),
		Size = UD2.new(1, -(SPEED_LEFT + SPEED_WIDTH + 160), 0, 18), TextXAlignment = E.TextXAlignment.Right, TextColor3 = C.text,
		Font = E.Font.RobotoMono, RichText = true })

	-- Replay speed slider (log scale, MIN_RATE..MAX_RATE candles per second) and the smooth toggle. Shown only when the
	-- host passes onRate; the chart itself never plays anything, it only reports the chosen rate and smoothing.
	self._onRate, self._onSmooth = options.onRate, options.onSmooth
	self._smooth = options.smooth ~= false
	local speed = make("Frame", frame, { Name = "Speed", Position = UD2.fromOffset(SPEED_LEFT, 3), Size = UD2.fromOffset(SPEED_WIDTH, 20),
		BackgroundTransparency = 1, Visible = type(options.onRate) == "function" })
	self._speed = speed
	label(speed, "SpeedLabel", { Size = UD2.fromOffset(44, 20), TextSize = 10, Font = E.Font.GothamBold, TextColor3 = C.muted, Text = "SPEED" })
	local track = make("TextButton", speed, { Name = "SpeedTrack", Position = UD2.fromOffset(46, 0), Size = UD2.fromOffset(TRACK_WIDTH, 20),
		BackgroundTransparency = 1, Text = "", AutoButtonColor = false, BorderSizePixel = 0 })
	make("Frame", track, { Name = "Rail", AnchorPoint = env.Vector2.new(0, 0.5), Position = UD2.new(0, 0, 0.5, 0), Size = UD2.new(1, 0, 0, 4),
		BackgroundColor3 = C.grid, BorderSizePixel = 0 })
	self._speedFill = make("Frame", track, { Name = "SpeedFill", AnchorPoint = env.Vector2.new(0, 0.5), Position = UD2.new(0, 0, 0.5, 0),
		Size = UD2.new(0, 0, 0, 4), BackgroundColor3 = C.accent, BorderSizePixel = 0 })
	self._speedKnob = make("Frame", track, { Name = "SpeedKnob", AnchorPoint = env.Vector2.new(0.5, 0.5), Position = UD2.new(0, 0, 0.5, 0),
		Size = UD2.fromOffset(12, 12), BackgroundColor3 = C.text, BorderSizePixel = 0 })
	make("UICorner", self._speedKnob, { CornerRadius = env.UDim.new(1, 0) })
	self._speedValue = label(speed, "SpeedValue", { Position = UD2.fromOffset(52 + TRACK_WIDTH, 0), Size = UD2.fromOffset(78, 20), TextSize = 10,
		Font = E.Font.GothamMedium })
	local smooth = make("TextButton", speed, { Name = "Smooth", Position = UD2.fromOffset(134 + TRACK_WIDTH, 2), Size = UD2.fromOffset(78, 16),
		BackgroundColor3 = C.grid, TextColor3 = C.text, TextSize = 10, Font = E.Font.GothamMedium, BorderSizePixel = 0, AutoButtonColor = true })
	self._smoothButton = smooth
	local dragging = false
	local function fromX(px)
		local pos, size = track.AbsolutePosition, track.AbsoluteSize
		if not pos or not size or not finite(size.X) or size.X <= 0 or not finite(px) then return end
		self:_setSpeedFraction(math.clamp((px - pos.X) / size.X, 0, 1), true)
	end
	self._handlers.Speed = function(fraction) self:_setSpeedFraction(fraction, true) end
	self._handlers.Smooth = function() self:setSmooth(not self._smooth, true) end
	table.insert(self._connections, track.MouseButton1Down:Connect(function(px) if not self._destroyed then dragging = true; fromX(px) end end))
	table.insert(self._connections, track.MouseMoved:Connect(function(px) if dragging and not self._destroyed then fromX(px) end end))
	table.insert(self._connections, track.MouseButton1Up:Connect(function() dragging = false end))
	table.insert(self._connections, track.MouseLeave:Connect(function() dragging = false end))
	table.insert(self._connections, smooth.MouseButton1Click:Connect(function() if not self._destroyed then self._handlers.Smooth() end end))
	local buttons = {}
	for k, w in WINDOWS do
		local b = make("TextButton", frame, { Name = "Window_" .. w.id, Text = w.id, AnchorPoint = env.Vector2.new(1, 0),
			Position = UD2.new(1, -46 - (#WINDOWS - k) * 34, 0, 4), Size = UD2.fromOffset(30, 18), BackgroundColor3 = C.grid,
			TextColor3 = C.text, TextSize = 10, Font = E.Font.GothamMedium, BorderSizePixel = 0, AutoButtonColor = true })
		local handler = function() self:setWindow(w.id) end
		self._handlers[b.Name] = handler
		table.insert(self._connections, b.MouseButton1Click:Connect(function() if not self._destroyed then handler() end end))
		buttons[w.id] = b
	end
	local hide = make("TextButton", frame, { Name = "Hide", Text = "hide", AnchorPoint = env.Vector2.new(1, 0),
		Position = UD2.new(1, -8, 0, 4), Size = UD2.fromOffset(34, 18), BackgroundTransparency = 1, TextColor3 = C.muted, TextSize = 10,
		Font = E.Font.Gotham, BorderSizePixel = 0 })
	self._windowButtons = buttons
	self._hideButton = hide
	self._handlers.Hide = function() self:setHidden(not self._hidden) end
	table.insert(self._connections, hide.MouseButton1Click:Connect(function() if not self._destroyed then self._handlers.Hide() end end))

	local plot = make("Frame", frame, { Name = "Plot", Position = UD2.fromOffset(PAD_LEFT, HEADER + PAD_TOP),
		Size = UD2.new(1, -(PAD_LEFT + PAD_RIGHT), 1, -(HEADER + PAD_TOP + PAD_BOTTOM)), BackgroundTransparency = 1, BorderSizePixel = 0 })
	self._plot = plot
	local price = make("Frame", plot, { Name = "PricePane", Size = UD2.new(1, 0, PRICE_SHARE, -PANE_GAP / 2), BackgroundColor3 = C.plot,
		BackgroundTransparency = 0.2, BorderSizePixel = 0, ClipsDescendants = true })
	local pnl = make("Frame", plot, { Name = "PnlPane", Position = UD2.new(0, 0, PRICE_SHARE, PANE_GAP / 2),
		Size = UD2.new(1, 0, 1 - PRICE_SHARE, -PANE_GAP / 2), BackgroundColor3 = C.plot, BackgroundTransparency = 0.2, BorderSizePixel = 0,
		ClipsDescendants = true })
	self._price, self._pnl = price, pnl
	self._pnlTitle = label(pnl, "PnlTitle", { Position = UD2.fromOffset(6, 2), Size = UD2.fromOffset(260, 14), TextSize = 10,
		TextColor3 = C.muted, ZIndex = 6, Text = "CUMULATIVE NET P&L (fees, slippage, borrow included)" })

	self._axis = {}
	for k = 1, 3 do
		self._axis[k] = label(frame, "Axis" .. k, { AnchorPoint = env.Vector2.new(0, 0.5), Position = UD2.new(1, -PAD_RIGHT + 6, 0, 0),
			Size = UD2.fromOffset(PAD_RIGHT - 8, 14), TextSize = 11, TextColor3 = C.accent, Font = E.Font.RobotoMono })
	end
	self._pnlAxis = label(frame, "PnlAxis", { AnchorPoint = env.Vector2.new(0, 0.5), Position = UD2.new(1, -PAD_RIGHT + 6, 1, -PAD_BOTTOM - 20),
		Size = UD2.fromOffset(PAD_RIGHT - 8, 16), TextSize = 12, Font = E.Font.GothamBold, TextColor3 = C.text })
	self._timeLeft = label(frame, "TimeLeft", { AnchorPoint = env.Vector2.new(0, 1), Position = UD2.new(0, PAD_LEFT, 1, -3),
		Size = UD2.new(0.18, 0, 0, 14), TextSize = 10, TextColor3 = C.muted, Font = E.Font.RobotoMono })
	self._timeRight = label(frame, "TimeRight", { AnchorPoint = env.Vector2.new(1, 1), Position = UD2.new(1, -PAD_RIGHT, 1, -3),
		Size = UD2.new(0.18, 0, 0, 14), TextSize = 10, TextColor3 = C.muted, TextXAlignment = E.TextXAlignment.Right, Font = E.Font.RobotoMono })
	self._legend = label(frame, "Legend", { AnchorPoint = env.Vector2.new(0.5, 1), Position = UD2.new(0.5, 0, 1, -3),
		Size = UD2.new(0.6, 0, 0, 14), TextSize = 10, TextColor3 = C.muted, TextXAlignment = E.TextXAlignment.Center,
		TextTruncate = E.TextTruncate.AtEnd,
		Text = "▲ BUY  ▼ SELL  × CLOSE on the decision bar · ● fill · % = closed trade net P&L · tint = position · no bar after the cursor" })

	-- Price pane pools: one column (tint + wick + body) per drawable bar, markers + captions, fill dots, trade P&L labels.
	self._columns = table.create(MAX_BARS)
	for k = 1, MAX_BARS do
		local tint = make("Frame", price, { Name = "Tint" .. k, BorderSizePixel = 0, BackgroundTransparency = 1, Visible = false, ZIndex = 1,
			Size = UD2.new(0, 0, 1, 0), Position = UD2.new(0, 0, 0, 0) })
		local wick = make("Frame", price, { Name = "Wick" .. k, BorderSizePixel = 0, AnchorPoint = env.Vector2.new(0.5, 0), Visible = false, ZIndex = 2,
			Size = UD2.new(0, 1, 0, 0) })
		local body = make("Frame", price, { Name = "Body" .. k, BorderSizePixel = 0, AnchorPoint = env.Vector2.new(0.5, 0), Visible = false, ZIndex = 3 })
		local bar = make("Frame", pnl, { Name = "PnlBar" .. k, BorderSizePixel = 0, AnchorPoint = env.Vector2.new(0.5, 0), Visible = false, ZIndex = 2,
			BackgroundTransparency = 0.25 })
		self._columns[k] = { tint = tint, wick = wick, body = body, pnl = bar }
	end
	self._marks, self._captions, self._dots, self._tradeLabels = table.create(MAX_MARKS), table.create(MAX_MARKS), table.create(MAX_MARKS), table.create(MAX_MARKS)
	for k = 1, MAX_MARKS do
		self._marks[k] = label(price, "Mark" .. k, { AnchorPoint = env.Vector2.new(0.5, 0.5), Size = UD2.fromOffset(30, 30), TextSize = 28,
			Font = E.Font.GothamBlack, TextXAlignment = E.TextXAlignment.Center, TextStrokeColor3 = C.outline, TextStrokeTransparency = 0.1,
			Visible = false, ZIndex = 8 })
		self._captions[k] = label(price, "Caption" .. k, { AnchorPoint = env.Vector2.new(0.5, 0.5), Size = UD2.fromOffset(48, 14), TextSize = 11,
			Font = E.Font.GothamBlack, TextXAlignment = E.TextXAlignment.Center, TextStrokeColor3 = C.outline, TextStrokeTransparency = 0.2,
			Visible = false, ZIndex = 8 })
		local dot = make("Frame", price, { Name = "Fill" .. k, AnchorPoint = env.Vector2.new(0.5, 0.5), Size = UD2.fromOffset(11, 11),
			BorderSizePixel = 0, Visible = false, ZIndex = 9 })
		make("UICorner", dot, { CornerRadius = env.UDim.new(1, 0) })
		make("UIStroke", dot, { Color = C.outline, Thickness = 1.5 })
		self._dots[k] = dot
		self._tradeLabels[k] = label(price, "TradePnl" .. k, { AnchorPoint = env.Vector2.new(0.5, 1), Size = UD2.fromOffset(64, 16), TextSize = 13,
			Font = E.Font.GothamBlack, TextXAlignment = E.TextXAlignment.Center, TextStrokeColor3 = C.outline, TextStrokeTransparency = 0.1,
			Visible = false, ZIndex = 10 })
	end
	self._levels = {}
	for _, name in { "Stop", "Target", "Last" } do
		self._levels[name] = make("Frame", price, { Name = name .. "Level", BorderSizePixel = 0, Size = UD2.new(1, 0, 0, 1), Visible = false, ZIndex = 4,
			BackgroundColor3 = if name == "Stop" then C.stop elseif name == "Target" then C.target else C.cursor, BackgroundTransparency = 0.25 })
	end
	self._cursor = make("Frame", price, { Name = "Cursor", BorderSizePixel = 0, AnchorPoint = env.Vector2.new(0.5, 0), Size = UD2.new(0, 1, 1, 0),
		BackgroundColor3 = C.cursor, BackgroundTransparency = 0.55, Visible = false, ZIndex = 4 })
	self._zero = make("Frame", pnl, { Name = "ZeroLine", BorderSizePixel = 0, Size = UD2.new(1, 0, 0, 1), BackgroundColor3 = C.muted,
		BackgroundTransparency = 0.3, Visible = false, ZIndex = 3 })
	gui.Parent = parent
	self:_highlightWindow()
	self:setRate(options.rate or 6)
	self:setSmooth(self._smooth, false)
	return self
end

local function rateFromFraction(f) return MIN_RATE * (MAX_RATE / MIN_RATE) ^ math.clamp(f, 0, 1) end
local function fractionFromRate(r) return math.clamp(math.log(r / MIN_RATE) / math.log(MAX_RATE / MIN_RATE), 0, 1) end
SpringChart.rateFromFraction, SpringChart.fractionFromRate = rateFromFraction, fractionFromRate

function Chart:_showRate(rate)
	local f = fractionFromRate(rate)
	self._speedKnob.Position = self.env.UDim2.new(f, 0, 0.5, 0)
	self._speedFill.Size = self.env.UDim2.new(f, 0, 0, 4)
	self._speedValue.Text = if rate >= 1 then string.format("%.1f candles/s", rate) else string.format("1 candle / %.1fs", 1 / rate)
	self.screenGui:SetAttribute("Rate", rate)
end

-- Sets the displayed rate without calling back (the host already knows it).
function Chart:setRate(rate)
	if self._destroyed then return end
	rate = math.clamp(tonumber(rate) or 6, MIN_RATE, MAX_RATE)
	self._rate = rate
	self:_showRate(rate)
end

function Chart:_setSpeedFraction(fraction, notify)
	if self._destroyed or not finite(fraction) then return end
	local rate = rateFromFraction(fraction)
	self._rate = rate
	self:_showRate(rate)
	if notify and type(self._onRate) == "function" then pcall(self._onRate, rate) end
end

function Chart:setSmooth(on, notify)
	if self._destroyed then return end
	self._smooth = on == true
	self._smoothButton.Text = if self._smooth then "smooth: on" else "smooth: off"
	self._smoothButton.BackgroundColor3 = if self._smooth then self._colors.accent else self._colors.grid
	self._smoothButton.TextColor3 = if self._smooth then self._colors.bg else self._colors.accent
	self.screenGui:SetAttribute("Smooth", self._smooth)
	if notify and type(self._onSmooth) == "function" then pcall(self._onSmooth, self._smooth) end
end

function Chart:_highlightWindow()
	for _, w in WINDOWS do
		local b = self._windowButtons[w.id]
		local selected = w.bars == self._window
		b.BackgroundColor3 = if selected then self._colors.accent else self._colors.grid
		b.TextColor3 = if selected then self._colors.bg else self._colors.accent
	end
end

function Chart:setWindow(id)
	if self._destroyed then return false end
	for _, w in WINDOWS do
		if w.id == id then
			self._window = w.bars
			self:_highlightWindow()
			self.screenGui:SetAttribute("Window", id)
			if self._last then self:update(table.unpack(self._last)) end
			return true
		end
	end
	return false
end

function Chart:setHidden(hidden)
	if self._destroyed then return end
	self._hidden = hidden == true
	self._fullSize = self._fullSize or self._frame.Size
	self._plot.Visible = not self._hidden
	self._frame.Size = if self._hidden then self.env.UDim2.new(self._fullSize.X.Scale, self._fullSize.X.Offset, 0, 26) else self._fullSize
	self._hideButton.Text = if self._hidden then "show" else "hide"
	for _, l in self._axis do l.Visible = not self._hidden end
	self._pnlAxis.Visible = not self._hidden
	self._timeLeft.Visible, self._timeRight.Visible, self._legend.Visible = not self._hidden, not self._hidden, not self._hidden
end

function Chart:testActivate(id, ...)
	assert(not self._destroyed, "SpringChart: destroyed")
	local handler = self._handlers[id]
	assert(handler, "SpringChart: unknown control " .. tostring(id))
	handler(...)
	return true
end

-- update(index, bars, rows, info): index = replay cursor (1-based); bars = {t,o,h,l,c} arrays; rows = the selected run's
-- compact rows (fa/fs final action and source, ex fills {a,p,r,s}, po position, sp/tg stop/target, eq equity);
-- info = {runLabel, label (cursor time text), labels (optional per-row time labels)}.
function Chart:update(index, bars, rows, info)
	if self._destroyed then fail("update after destroy") end
	local problem = barsProblem(bars)
	if problem then fail(problem) end
	local n = #bars.t
	if not isInteger(index) or index < 1 or index > n then fail("index out of range") end
	if type(rows) ~= "table" or #rows ~= n then fail("rows must hold one compact row per bar") end
	info = info or {}
	self._fullSize = self._fullSize or self._frame.Size
	self._last = { index, bars, rows, info }
	local C, UD2 = self._colors, self.env.UDim2
	local W = self._window
	local first = math.max(1, index - W + 1)
	local count = index - first + 1
	local cur = rows[index]
	local nets, wins, losses, openPnl, lastNet = tradeStats(rows, index)

	-- Price range over the drawn bars (never beyond the cursor), plus the open trade's levels.
	local lo, hi = math.huge, -math.huge
	for i = first, index do lo = math.min(lo, bars.l[i]); hi = math.max(hi, bars.h[i]) end
	if cur.po ~= 0 then
		if finite(cur.sp) then lo = math.min(lo, cur.sp); hi = math.max(hi, cur.sp) end
		if finite(cur.tg) then lo = math.min(lo, cur.tg); hi = math.max(hi, cur.tg) end
	end
	local span = math.max(hi - lo, 1e-9)
	lo, hi = lo - span * 0.12, hi + span * 0.12 -- headroom for the large markers
	span = hi - lo
	local function y(p) return math.clamp((hi - p) / span, 0, 1) end
	local function x(k) return (k - 0.5) / W end
	local width = 1 / W

	-- Cumulative P&L range over the drawn bars (equity - 1); zero always visible.
	local pLo, pHi = 0, 0
	for i = first, index do
		local v = if finite(rows[i].eq) then rows[i].eq - 1 else 0
		pLo, pHi = math.min(pLo, v), math.max(pHi, v)
	end
	local pSpan = math.max(pHi - pLo, 0.0005)
	pLo, pHi = pLo - pSpan * 0.15, pHi + pSpan * 0.15
	pSpan = pHi - pLo
	local function py(v) return math.clamp((pHi - v) / pSpan, 0, 1) end
	local zeroY = py(0)

	for k = 1, MAX_BARS do
		local col = self._columns[k]
		if k <= count then
			local i = first + k - 1
			local o, h, l, c = bars.o[i], bars.h[i], bars.l[i], bars.c[i]
			local color = if c >= o then C.up else C.down
			col.wick.Visible, col.body.Visible = true, true
			col.wick.BackgroundColor3 = color
			col.wick.Position = UD2.new(x(k), 0, y(h), 0)
			col.wick.Size = UD2.new(0, 1, math.max(y(l) - y(h), 0), 1)
			col.body.BackgroundColor3 = color
			col.body.Position = UD2.new(x(k), 0, y(math.max(o, c)), 0)
			col.body.Size = UD2.new(width * 0.62, 0, math.max(y(math.min(o, c)) - y(math.max(o, c)), 0), 1)
			local pos = rows[i].po
			col.tint.Visible = pos ~= 0
			if pos ~= 0 then
				col.tint.BackgroundColor3 = if pos == 1 then C.long else C.short
				col.tint.BackgroundTransparency = 0.78
				col.tint.Position = UD2.new((k - 1) / W, 0, 0, 0)
				col.tint.Size = UD2.new(width, 1, 1, 0)
			end
			local v = if finite(rows[i].eq) then rows[i].eq - 1 else 0
			local vy = py(v)
			col.pnl.Visible = true
			col.pnl.BackgroundColor3 = if v >= 0 then C.up else C.down
			col.pnl.Position = UD2.new(x(k), 0, math.min(vy, zeroY), 0)
			col.pnl.Size = UD2.new(width * 0.9, 1, math.abs(vy - zeroY), 1)
			col.pnl:SetAttribute("Pnl", v)
		else
			col.wick.Visible, col.body.Visible, col.tint.Visible, col.pnl.Visible = false, false, false, false
		end
	end

	-- Decision markers (large, outlined, captioned) on the decision bar; fills at the fill price; trade P&L at exits.
	local m, d, tl = 0, 0, 0
	for k = 1, count do
		local i = first + k - 1
		local r = rows[i]
		local action = r.fa
		if (action == "BUY" or action == "SELL" or action == "CLOSE") and m < MAX_MARKS then
			m += 1
			local mark, caption = self._marks[m], self._captions[m]
			mark.Visible, caption.Visible = true, true
			if action == "BUY" then
				mark.Text, mark.TextColor3 = "▲", C.buy
				mark.Position = UD2.new(x(k), 0, y(bars.l[i]), 16)
				caption.Text, caption.TextColor3 = "BUY", C.buy
				caption.Position = UD2.new(x(k), 0, y(bars.l[i]), 38)
			elseif action == "SELL" then
				mark.Text, mark.TextColor3 = "▼", C.sell
				mark.Position = UD2.new(x(k), 0, y(bars.h[i]), -16)
				caption.Text, caption.TextColor3 = "SELL", C.sell
				caption.Position = UD2.new(x(k), 0, y(bars.h[i]), -38)
			else
				mark.Text, mark.TextColor3 = "×", C.close
				mark.Position = UD2.new(x(k), 0, y(bars.h[i]), -16)
				caption.Text, caption.TextColor3 = "CLOSE", C.close
				caption.Position = UD2.new(x(k), 0, y(bars.h[i]), -38)
			end
			mark:SetAttribute("Row", i); mark:SetAttribute("Action", action); mark:SetAttribute("Source", r.fs)
		end
		for _, f in r.ex or {} do
			if d < MAX_MARKS and finite(f.p) then
				d += 1
				local dot = self._dots[d]
				dot.Visible = true
				dot.BackgroundColor3 = if f.a == "BUY" then C.buy elseif f.a == "SELL" then C.sell
					elseif f.r == "target" then C.target elseif f.r == "stop" or f.r == "stop_gap" then C.stop else C.cursor
				dot.Position = UD2.new(x(k), 0, y(f.p), 0)
				dot:SetAttribute("Row", i); dot:SetAttribute("Action", f.a); dot:SetAttribute("Reason", f.r); dot:SetAttribute("Price", f.p)
				if f.a == "CLOSE" and nets[i] ~= nil and tl < MAX_MARKS then
					tl += 1
					local t = self._tradeLabels[tl]
					t.Visible = true
					t.Text = pct(nets[i])
					t.TextColor3 = if nets[i] >= 0 then C.buy else C.sell
					t.Position = UD2.new(x(k), 0, y(f.p), -9)
					t:SetAttribute("Row", i); t:SetAttribute("Net", nets[i])
				end
			end
		end
	end
	for k = m + 1, MAX_MARKS do self._marks[k].Visible = false; self._captions[k].Visible = false end
	for k = d + 1, MAX_MARKS do self._dots[k].Visible = false end
	for k = tl + 1, MAX_MARKS do self._tradeLabels[k].Visible = false end

	local open = cur.po ~= 0
	self._levels.Stop.Visible = open and finite(cur.sp)
	if self._levels.Stop.Visible then self._levels.Stop.Position = UD2.new(0, 0, y(cur.sp), 0) end
	self._levels.Target.Visible = open and finite(cur.tg)
	if self._levels.Target.Visible then self._levels.Target.Position = UD2.new(0, 0, y(cur.tg), 0) end
	self._levels.Last.Visible = true
	self._levels.Last.Position = UD2.new(0, 0, y(bars.c[index]), 0)
	self._cursor.Visible = true
	self._cursor.Position = UD2.new(x(count), 0, 0, 0)
	self._zero.Visible = true
	self._zero.Position = UD2.new(0, 0, zeroY, 0)

	-- Axis labels in frame coordinates: the price pane is the top PRICE_SHARE of the plot area.
	local top = HEADER + PAD_TOP
	local function axisAt(fraction)
		local s = fraction * PRICE_SHARE
		return UD2.new(1, -PAD_RIGHT + 6, s, top - s * (top + PAD_BOTTOM))
	end
	local lastFraction = y(bars.c[index])
	self._axis[1].Text, self._axis[1].Position = fmt(hi), axisAt(0)
	self._axis[3].Text, self._axis[3].Position = fmt(lo), axisAt(1)
	self._axis[2].Text, self._axis[2].Position = fmt(bars.c[index]), axisAt(lastFraction)
	self._axis[2].TextColor3 = C.cursor
	self._axis[1].Visible = not self._hidden and lastFraction > 0.08
	self._axis[3].Visible = not self._hidden and lastFraction < 0.92
	self._axis[2]:SetAttribute("PriceFraction", lastFraction)
	local total = if finite(cur.eq) then cur.eq - 1 else nil
	local pnlFraction = PRICE_SHARE + (1 - PRICE_SHARE) * py(total or 0)
	self._pnlAxis.Text = pct(total)
	self._pnlAxis.TextColor3 = if (total or 0) >= 0 then C.buy else C.sell
	self._pnlAxis.Position = UD2.new(1, -PAD_RIGHT + 6, pnlFraction, top - pnlFraction * (top + PAD_BOTTOM))

	local labels = info.labels
	self._timeLeft.Text = if labels and labels[first] then tostring(labels[first]) else ""
	self._timeRight.Text = if labels and labels[index] then tostring(labels[index]) else (info.label or "")
	local position = if cur.po == 1 then "LONG" elseif cur.po == -1 then "SHORT" else "FLAT"
	self._title.Text = string.format("SPY 5-MIN · %s", string.upper(tostring(info.runLabel or "")))
	local function colored(text, value)
		local hex = if (value or 0) >= 0 then "#4AE85A" else "#FF433D"
		return string.format('<font color="%s"><b>%s</b></font>', hex, text)
	end
	self._readout.Text = string.format("%s · close %s · %s%s · P&amp;L %s · trades W%d / L%d%s", tostring(info.label or ""), fmt(bars.c[index]), position,
		if openPnl then " " .. colored(pct(openPnl), openPnl) else "", colored(pct(total), total), wins, losses,
		if lastNet then " · last " .. colored(pct(lastNet), lastNet) else "")
	local g = self.screenGui
	g:SetAttribute("Index", index); g:SetAttribute("FirstDrawn", first); g:SetAttribute("Markers", m); g:SetAttribute("Fills", d)
	g:SetAttribute("TradeLabels", tl); g:SetAttribute("Wins", wins); g:SetAttribute("Losses", losses)
	g:SetAttribute("TotalPnl", total); g:SetAttribute("OpenPnl", openPnl)
	return { first = first, last = index, markers = m, fills = d, tradeLabels = tl, wins = wins, losses = losses, totalPnl = total, openPnl = openPnl }
end

function Chart:destroy()
	if self._destroyed then return end
	self._destroyed = true
	for _, c in self._connections do c:Disconnect() end
	if self.screenGui then self.screenGui:Destroy() end
	for _, inst in self._created do pcall(function() inst:Destroy() end) end
end

SpringChart.WINDOWS = WINDOWS
return SpringChart
