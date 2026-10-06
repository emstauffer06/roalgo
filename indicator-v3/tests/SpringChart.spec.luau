-- SpringChart spec (contract D17 style). Self-running: luau.exe tests/SpringChart.spec.luau
-- Roblox is replaced by a small mock injected through options.env. These checks cover data mapping and wiring;
-- they do not prove how the chart renders in Studio.
local loaded, SpringChart = pcall(require, "../src/SpringChart")
assert(loaded and type(SpringChart) == "table" and type(SpringChart.mount) == "function", "SpringChart must load: " .. tostring(SpringChart))
local passed = 0
local function test(name, fn) fn(); passed += 1; print("PASS " .. name) end

local function mock()
	local R = { created = {} }
	local Inst, methods = {}, {}
	local function signal()
		local s = { handlers = {} }
		function s:Connect(fn)
			local c = { Connected = true }
			table.insert(self.handlers, { fn = fn, c = c })
			function c:Disconnect() self.Connected = false end
			return c
		end
		function s:Fire(...) for _, h in self.handlers do if h.c.Connected then h.fn(...) end end end
		return s
	end
	local function new(className)
		local i = setmetatable({}, Inst)
		rawset(i, "ClassName", className); rawset(i, "_p", { Name = className }); rawset(i, "_a", {}); rawset(i, "_c", {})
		rawset(i, "_s", {}); rawset(i, "_dead", false)
		table.insert(R.created, i)
		return i
	end
	Inst.__index = function(self, k)
		if methods[k] then return methods[k] end
		if k == "Parent" then return rawget(self, "_parent") end
		if type(k) == "string" and string.sub(k, 1, 5) == "Mouse" then local s = rawget(self, "_s"); s[k] = s[k] or signal(); return s[k] end
		return rawget(self, "_p")[k]
	end
	Inst.__newindex = function(self, k, v)
		if k == "Parent" then
			assert(not rawget(self, "_dead"), "parent locked")
			rawset(self, "_parent", v)
			if v then table.insert(rawget(v, "_c"), self) end
			return
		end
		rawget(self, "_p")[k] = v
	end
	function methods:SetAttribute(k, v) rawget(self, "_a")[k] = v end
	function methods:GetAttribute(k) return rawget(self, "_a")[k] end
	function methods:FindFirstChild(name) for _, c in rawget(self, "_c") do if c.Name == name then return c end end return nil end
	function methods:GetDescendants()
		local out = {}
		local function walk(x) for _, c in rawget(x, "_c") do table.insert(out, c); walk(c) end end
		walk(self)
		return out
	end
	function methods:Destroy()
		if rawget(self, "_dead") then return end
		for _, c in table.clone(rawget(self, "_c")) do c:Destroy() end
		rawset(self, "_dead", true); rawset(self, "_parent", nil)
	end
	local function udim(s, o) return { Scale = s or 0, Offset = o or 0 } end
	R.env = {
		Instance = { new = new },
		UDim = { new = udim },
		UDim2 = { new = function(xs, xo, ys, yo) return { X = udim(xs, xo), Y = udim(ys, yo) } end,
			fromOffset = function(x, y) return { X = udim(0, x), Y = udim(0, y) } end,
			fromScale = function(x, y) return { X = udim(x, 0), Y = udim(y, 0) } end },
		Color3 = { fromRGB = function(r, g, b) return { R = r, G = g, B = b } end, new = function(r, g, b) return { R = r, G = g, B = b } end },
		Vector2 = { new = function(x, y) return { X = x, Y = y } end },
		Enum = setmetatable({}, { __index = function(_, g) return setmetatable({}, { __index = function(_, i) return g .. "." .. i end }) end }),
	}
	function R.root() local r = new("CoreGui"); return r end
	function R.live() local n = 0 for _, i in R.created do if not rawget(i, "_dead") then n += 1 end end return n end
	function R.p(i) return rawget(i, "_p") end
	return R
end

-- Synthetic bars: a gentle uptrend; a BUY decided on row 20 fills on row 21, a target CLOSE on row 30, a SELL on 40.
local function fixture(n)
	local bars = { t = {}, o = {}, h = {}, l = {}, c = {} }
	local rows = {}
	for i = 1, n do
		local base = 100 + i * 0.1
		bars.t[i] = 1000 + i * 300; bars.o[i] = base; bars.c[i] = base + 0.05; bars.h[i] = base + 0.2; bars.l[i] = base - 0.2
		rows[i] = { fa = "HOLD", fs = "physics", po = 0, eq = 1 }
	end
	rows[20].fa = "BUY"
	rows[21].ex = { { a = "BUY", p = bars.o[21] + 0.01, r = "entry", s = "physics" } }
	for i = 21, 29 do rows[i].po = 1; rows[i].sp = bars.o[21] - 0.6; rows[i].tg = bars.o[21] + 0.9 end
	rows[30].ex = { { a = "CLOSE", p = bars.o[21] + 0.9, r = "target", s = "risk" } }
	rows[40].fa = "SELL"
	return bars, rows
end

-- Adds ledger equity: the long (fill 21, exit 30) nets +0.40%; with `short`, a short filled on 41 and stopped on 45
-- nets 1.0028 / 1.004 - 1 (a loss).
local function withEquity(bars, rows, short)
	for i = 21, 29 do rows[i].eq = 0.9997 + 0.0005 * (i - 21) end
	for i = 30, #rows do rows[i].eq = 1.004 end
	if short then
		rows[41].ex = { { a = "SELL", p = bars.o[41] - 0.01, r = "entry", s = "physics" } }
		for i = 41, 44 do rows[i].po = -1; rows[i].eq = 1.0035; rows[i].sp = bars.o[41] + 0.6; rows[i].tg = bars.o[41] - 0.9 end
		rows[45].ex = { { a = "CLOSE", p = bars.o[45], r = "stop", s = "risk" } }
		for i = 45, #rows do rows[i].eq = 1.0028 end
	end
	return bars, rows
end

local function visibleNamed(root, prefix)
	local n = 0
	for _, d in root:GetDescendants() do
		local name = d.Name
		if type(name) == "string" and string.sub(name, 1, #prefix) == prefix and string.match(string.sub(name, #prefix + 1), "^%d+$") and d.Visible then n += 1 end
	end
	return n
end
local function find(root, name) for _, d in root:GetDescendants() do if d.Name == name then return d end end return nil end

test("mount builds a docked ScreenGui and pooled columns under the given parent", function()
	local R = mock(); local root = R.root()
	local chart = SpringChart.mount(root, { env = R.env })
	assert(root:FindFirstChild("RoAlgoSpringChart") == chart.screenGui)
	assert(find(root, "Body390") and find(root, "Wick1") and find(root, "Tint1") and find(root, "Mark160") and find(root, "Fill160"))
	assert(visibleNamed(root, "Body") == 0, "nothing drawn before the first update")
	chart:destroy()
end)

test("draws exactly the bars up to the cursor and never a later bar", function()
	local R = mock(); local root = R.root()
	local chart = SpringChart.mount(root, { env = R.env })
	local bars, rows = fixture(120)
	local info = chart:update(30, bars, rows, { runLabel = "Coupled", label = "row30" })
	assert(info.first == 1 and info.last == 30)
	assert(visibleNamed(root, "Body") == 30 and visibleNamed(root, "Wick") == 30, "30 candles at cursor 30")
	assert(chart.screenGui:GetAttribute("Index") == 30)
	-- The SELL decided on row 40 is in the future: no marker for it.
	for _, d in root:GetDescendants() do
		if d.Visible and d:GetAttribute("Row") then assert(d:GetAttribute("Row") <= 30, "a mark beyond the cursor was drawn") end
	end
	chart:update(100, bars, rows, {})
	assert(visibleNamed(root, "Body") == 78, "the 1D window holds 78 bars")
	assert(chart.screenGui:GetAttribute("FirstDrawn") == 23)
	chart:destroy()
end)

test("decision markers sit on the decision bar with the right symbol; fills sit at the fill price", function()
	local R = mock(); local root = R.root()
	local chart = SpringChart.mount(root, { env = R.env })
	local bars, rows = fixture(60)
	local info = chart:update(45, bars, rows, {})
	assert(info.markers == 2 and info.fills == 2, "BUY and SELL markers; entry and exit fills")
	local buy, sell, entry, exit
	for _, d in root:GetDescendants() do
		if d.Visible and d:GetAttribute("Action") == "BUY" and d.ClassName == "TextLabel" then buy = d end
		if d.Visible and d:GetAttribute("Action") == "SELL" and d.ClassName == "TextLabel" then sell = d end
		if d.Visible and d.ClassName == "Frame" and d:GetAttribute("Reason") == "entry" then entry = d end
		if d.Visible and d.ClassName == "Frame" and d:GetAttribute("Reason") == "target" then exit = d end
	end
	assert(buy and buy.Text == "▲" and buy:GetAttribute("Row") == 20 and buy.Position.Y.Offset > 0, "BUY triangle below the decision bar's low")
	assert(sell and sell.Text == "▼" and sell:GetAttribute("Row") == 40 and sell.Position.Y.Offset < 0, "SELL triangle above the high")
	assert(entry and entry:GetAttribute("Row") == 21 and math.abs(entry:GetAttribute("Price") - (bars.o[21] + 0.01)) < 1e-12, "entry fill on the next bar at its price")
	assert(exit and exit:GetAttribute("Row") == 30, "target fill on row 30")
	assert(exit.Position.Y.Scale < entry.Position.Y.Scale, "a higher fill price is drawn higher (smaller y)")
	chart:destroy()
end)

test("position tint covers held bars only; stop/target show only while a trade is open", function()
	local R = mock(); local root = R.root()
	local chart = SpringChart.mount(root, { env = R.env })
	local bars, rows = fixture(60)
	chart:update(25, bars, rows, {})
	assert(visibleNamed(root, "Tint") == 5, "rows 21..25 are long")
	assert(find(root, "StopLevel").Visible and find(root, "TargetLevel").Visible, "open long shows its levels")
	assert(find(root, "TargetLevel").Position.Y.Scale < find(root, "StopLevel").Position.Y.Scale, "a long's target is above its stop")
	chart:update(35, bars, rows, {})
	assert(visibleNamed(root, "Tint") == 9 and not find(root, "StopLevel").Visible and not find(root, "TargetLevel").Visible, "flat: no levels")
	chart:destroy()
end)

test("window buttons change the drawn span and hide collapses the plot", function()
	local R = mock(); local root = R.root()
	local chart = SpringChart.mount(root, { env = R.env })
	local bars, rows = fixture(500)
	chart:update(500, bars, rows, {})
	assert(chart:testActivate("Window_3D") and chart.screenGui:GetAttribute("FirstDrawn") == 267)
	assert(visibleNamed(root, "Body") == 234)
	assert(chart:testActivate("Window_1W") and visibleNamed(root, "Body") == 390)
	chart:testActivate("Hide")
	assert(find(root, "Plot").Visible == false and find(root, "Hide").Text == "show")
	chart:testActivate("Hide")
	assert(find(root, "Plot").Visible == true)
	chart:destroy()
end)

test("rejects malformed input instead of drawing a partial chart", function()
	local R = mock(); local root = R.root()
	local chart = SpringChart.mount(root, { env = R.env })
	local bars, rows = fixture(50)
	assert(not pcall(chart.update, chart, 51, bars, rows, {}), "index past the data")
	assert(not pcall(chart.update, chart, 0, bars, rows, {}), "index 0")
	local short = table.clone(rows); short[50] = nil
	assert(not pcall(chart.update, chart, 10, bars, short, {}), "row count mismatch")
	local broken = table.clone(bars); broken.c = { 1, 2 }
	assert(not pcall(chart.update, chart, 1, broken, rows, {}), "column length mismatch")
	assert(visibleNamed(root, "Body") == 0, "nothing drawn by rejected updates")
	chart:destroy()
end)

test("decision markers are large, outlined and captioned", function()
	local R = mock(); local root = R.root()
	local chart = SpringChart.mount(root, { env = R.env })
	local bars, rows = fixture(60)
	chart:update(45, bars, rows, {})
	local buy, caption
	for _, d in root:GetDescendants() do
		if d.Visible and d:GetAttribute("Action") == "BUY" and d.ClassName == "TextLabel" then buy = d end
		if d.Visible and type(d.Name) == "string" and string.match(d.Name, "^Caption%d+$") and d.Text == "BUY" then caption = d end
	end
	assert(buy.TextSize >= 24 and buy.Size.X.Offset >= 28, "BUY marker is large")
	assert(buy.TextStrokeTransparency <= 0.2, "marker has a dark outline")
	assert(caption and caption.Position.Y.Offset > buy.Position.Y.Offset, "BUY caption sits below its marker")
	chart:destroy()
end)

test("closed-trade P&L is exact from ledger equity and shown at the exit fill", function()
	local R = mock(); local root = R.root()
	local chart = SpringChart.mount(root, { env = R.env })
	local bars, rows = withEquity(fixture(60))
	local info = chart:update(35, bars, rows, {})
	local label
	for _, d in root:GetDescendants() do
		if d.Visible and type(d.Name) == "string" and string.match(d.Name, "^TradePnl%d+$") then label = d end
	end
	assert(info.tradeLabels == 1 and label and label:GetAttribute("Row") == 30, "one closed trade, labelled at its exit row")
	assert(math.abs(label:GetAttribute("Net") - (1.004 / 1 - 1)) < 1e-12 and label.Text == "+0.40%", "net = exit equity / pre-entry equity - 1")
	assert(info.wins == 1 and info.losses == 0 and math.abs(info.totalPnl - 0.004) < 1e-12 and info.openPnl == nil)
	chart:destroy()
end)

test("open trade P&L, losing trades and the cumulative P&L pane", function()
	local R = mock(); local root = R.root()
	local chart = SpringChart.mount(root, { env = R.env })
	local baseBars, baseRows = fixture(60)
	local bars, rows = withEquity(baseBars, baseRows, true)
	local open = chart:update(25, bars, rows, {})
	assert(math.abs(open.openPnl - (rows[25].eq / 1 - 1)) < 1e-12, "open long marked against pre-entry equity")
	local info = chart:update(50, bars, rows, {})
	assert(info.wins == 1 and info.losses == 1, "the short stopped out is a loss")
	assert(math.abs(info.totalPnl - (1.0028 - 1)) < 1e-12)
	local bars2, negative, positive = 0, 0, 0
	for _, d in root:GetDescendants() do
		if d.Visible and type(d.Name) == "string" and string.match(d.Name, "^PnlBar%d+$") then
			bars2 += 1
			if d:GetAttribute("Pnl") < 0 then negative += 1 else positive += 1 end
		end
	end
	assert(bars2 == 50, "one P&L bar per drawn price bar")
	assert(negative == 1 and positive == 49, "only row 21 (entry costs) is below zero; the rest are at or above")
	assert(chart.screenGui:GetAttribute("Losses") == 1 and math.abs(chart.screenGui:GetAttribute("TotalPnl") - 0.0028) < 1e-12)
	-- No future: at cursor 44 the short is still open and its loss is not yet counted.
	local mid = chart:update(44, bars, rows, {})
	assert(mid.losses == 0 and mid.openPnl ~= nil, "a trade closing after the cursor is not counted")
	chart:destroy()
end)

test("speed slider maps a log scale 0.25..30 candles/s and reports through onRate", function()
	local R = mock(); local root = R.root()
	local quiet = SpringChart.mount(root, { env = R.env })
	assert(find(root, "Speed").Visible == false, "no slider without an onRate host")
	quiet:destroy()
	root = R.root()
	local got = {}
	local chart = SpringChart.mount(root, { env = R.env, rate = 6, onRate = function(r) table.insert(got, r) end })
	assert(find(root, "Speed").Visible == true and #got == 0, "initial rate is shown, not reported")
	assert(math.abs(chart.screenGui:GetAttribute("Rate") - 6) < 1e-12)
	chart:testActivate("Speed", 0)
	assert(math.abs(got[1] - 0.25) < 1e-12 and find(root, "SpeedValue").Text == "1 candle / 4.0s")
	chart:testActivate("Speed", 1)
	assert(math.abs(got[2] - 30) < 1e-9 and find(root, "SpeedValue").Text == "30.0 candles/s")
	chart:testActivate("Speed", 0.5)
	assert(math.abs(got[3] - math.sqrt(0.25 * 30)) < 1e-9, "midpoint is the geometric mean")
	chart:setRate(1)
	assert(#got == 3, "setRate does not call back")
	assert(math.abs(find(root, "SpeedKnob").Position.X.Scale - SpringChart.fractionFromRate(1)) < 1e-12)
	-- dragging along the track (absolute pixels) sets the rate from the pointer position
	local track = find(root, "SpeedTrack")
	R.p(track).AbsolutePosition = { X = 100, Y = 0 }; R.p(track).AbsoluteSize = { X = 150, Y = 20 }
	track.MouseButton1Down:Fire(250, 10)
	assert(math.abs(got[4] - 30) < 1e-9, "pointer at the right end = maximum")
	track.MouseMoved:Fire(100, 10)
	assert(math.abs(got[5] - 0.25) < 1e-12, "drag to the left end = minimum")
	track.MouseButton1Up:Fire(); track.MouseMoved:Fire(175, 10)
	assert(#got == 5, "no change after release")
	chart:destroy()
end)

test("smooth toggle reports through onSmooth", function()
	local R = mock(); local root = R.root()
	local seen = {}
	local chart = SpringChart.mount(root, { env = R.env, onRate = function() end, onSmooth = function(on) table.insert(seen, on) end })
	assert(find(root, "Smooth").Text == "smooth: on" and chart.screenGui:GetAttribute("Smooth") == true, "smooth defaults on")
	chart:testActivate("Smooth")
	assert(seen[1] == false and find(root, "Smooth").Text == "smooth: off")
	chart:setSmooth(true, false)
	assert(#seen == 1 and chart.screenGui:GetAttribute("Smooth") == true)
	chart:destroy()
end)

test("destroy removes every instance and later updates fail", function()
	local R = mock(); local root = R.root()
	local chart = SpringChart.mount(root, { env = R.env })
	local bars, rows = fixture(40)
	chart:update(40, bars, rows, {})
	chart:destroy()
	assert(R.live() == 1, "only the mock parent remains")
	assert(not pcall(chart.update, chart, 10, bars, rows, {}), "update after destroy must fail")
end)

print("SpringChart: " .. passed .. " tests passed")
