-- Recorded experiment replay (plan Task 8). ENGINE CODE, presentation only.
--
-- Rebuilds the reservoir geometry as an ANCHORED display model (Workspace.MarketReservoirLabReplay) and moves
-- its nodes only to positions read from the saved state records (x = 3 * state[i]). Between two saved states the
-- motion is interpolated and the board says so. Nothing here steps physics or feeds back into any readout.
-- The board shows the bar's New York time, decision time and target time, each model's frozen forecast, and the
-- realized eight-hour return only once the replay clock has reached that forecast's outcome time.
--
-- data (built by the bridge's /replay endpoint from saved artifacts):
--   {profileId, preset, drive, dateNY, label, rows = {{t, decisionTime, outcomeTime, hourNY, x = {D}, state = {48},
--     forecasts = {[modelId] = {spy, qqq}}, actual = {spy, qqq}?}}, projection = 24xD, aggregate = {...}?}
local Config = require("../Config")
local Reservoir = require("../Physics/Reservoir")

local Replay = {}

local MODEL_LABELS = {
	{ "RAW_PHYSICS", "Raw + physics" },
	{ "RAW", "Raw ridge" },
	{ "MARKOV", "Markov" },
	{ "PHYSICS", "Physics only" },
	{ "ZERO", "No change" },
}

local function fmtTime(unix: number): string
	return DateTime.fromUnixTimestamp(unix):FormatUniversalTime("YYYY-MM-DD HH:mm", "en-us") .. " UTC"
end

local function bps(x: number?): string
	if x == nil then
		return "--"
	end
	return string.format("%+.1f bp", x * 10000)
end

local function makeBoard(parent: Instance, position: Vector3)
	local board = Instance.new("Part")
	board.Name = "Board"
	board.Anchored = true
	board.CanCollide = false
	board.Size = Vector3.new(0.4, 18, 30)
	board.CFrame = CFrame.new(position) * CFrame.Angles(0, math.rad(90), 0)
	board.Color = Color3.fromRGB(18, 20, 26)
	board.Material = Enum.Material.SmoothPlastic
	board.Parent = parent
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.CanvasSize = Vector2.new(1500, 900)
	gui.LightInfluence = 0
	gui.Parent = board
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.TextColor3 = Color3.fromRGB(230, 233, 238)
	text.Font = Enum.Font.RobotoMono
	text.TextSize = 34
	text.TextWrapped = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 40)
	pad.PaddingTop = UDim.new(0, 30)
	pad.Parent = text
	return text
end

-- args = {data, secondsPerBar?, framesPerBar?}. Returns a summary when playback ends.
function Replay.play(ctx: any, args: any)
	local data = args.data
	local physics = Config.values.physics
	local old = workspace:FindFirstChild("MarketReservoirLabReplay")
	if old then
		old:Destroy()
	end
	local root = Instance.new("Model")
	root.Name = "MarketReservoirLabReplay"
	root:SetAttribute("Kind", "recorded experiment replay")
	root.Parent = workspace
	local r = Reservoir.build(root, {
		physics = physics,
		presetId = data.preset,
		projection = data.projection,
		driveDisplacement = data.drive,
		name = "ReplayReservoir",
		origin = Vector3.new(0, 0, 0),
		visual = true,
	})
	for _, n in r.nodes do
		n.part.Anchored = true -- display only: positions come from the record, never from simulation
	end
	local text = makeBoard(root, Vector3.new(-14, 16, 10))
	local secondsPerBar = args.secondsPerBar or 1.2
	local frames = args.framesPerBar or 36
	local prevX = table.create(24, 0)
	local revealed = {}
	local shownRows = 0
	for k, row in data.rows do
		r:drive(row.x) -- colours only (the reservoir's drive force is irrelevant: nodes are anchored)
		local targetX = table.create(24, 0)
		for i = 1, 24 do
			targetX[i] = 3 * row.state[i]
		end
		-- The replay clock is this bar's decision time: a forecast's realized return becomes visible only when its
		-- outcome time has been reached.
		local clockNow = row.decisionTime
		local resolving = nil
		for _, other in data.rows do
			if other.actual and other.outcomeTime <= clockNow then
				revealed[other.t] = true
				if other.outcomeTime == clockNow then
					resolving = other
				end
			end
		end
		local lines = {
			"RECORDED EXPERIMENT REPLAY   (" .. tostring(data.label or "") .. ")",
			string.format("%s  profile %s  preset %s  drive %.2f studs", data.dateNY, data.profileId, data.preset, data.drive),
			"SPY = S&P 500 ETF proxy   QQQ = Nasdaq-100 ETF",
			"",
			"bar start   " .. fmtTime(row.t) .. string.format("   (NY %02d:00)", row.hourNY),
			"decision    " .. fmtTime(row.decisionTime),
			"target      " .. fmtTime(row.outcomeTime) .. (if row.scored
				then "   (+8 h, same NY date: scored)"
				elseif row.forecasts then "   (+8 h; not scored: " .. string.gsub(tostring(row.exclusionReason or "outside the scored population"), "_", " ") .. ")"
				else "   (+8 h)"),
			"",
			"forecast of the 8-hour log return     SPY        QQQ",
		}
		for _, pair in MODEL_LABELS do
			local f = row.forecasts and row.forecasts[pair[1]]
			if f then
				table.insert(lines, string.format("  %-16s                %10s %10s", pair[2], bps(f[1]), bps(f[2])))
			end
		end
		if not row.forecasts then
			table.insert(lines, "  (warm-up observation: forecasts start at the 4th bar of the day)")
		elseif row.scored then
			table.insert(lines, "  realized: hidden until " .. fmtTime(row.outcomeTime))
		else
			table.insert(lines, "  issued and frozen, but outside the scored population (reason on the target line)")
		end
		table.insert(lines, "")
		if resolving and revealed[resolving.t] then
			table.insert(lines, "resolving now: forecast made at " .. fmtTime(resolving.decisionTime))
			for _, pair in MODEL_LABELS do
				local f = resolving.forecasts and resolving.forecasts[pair[1]]
				if f then
					table.insert(lines, string.format("  %-16s                %10s %10s", pair[2], bps(f[1]), bps(f[2])))
				end
			end
			table.insert(lines, string.format("  REALIZED                        %10s %10s", bps(resolving.actual[1]), bps(resolving.actual[2])))
		end
		table.insert(lines, "")
		table.insert(lines, "node motion between saved states is interpolated for display")
		text.Text = table.concat(lines, "\n")
		for f = 1, frames do
			local a = f / frames
			for i, n in r.nodes do
				local x = prevX[i] + (targetX[i] - prevX[i]) * a
				n.part.CFrame = CFrame.new(n.rest + Vector3.new(x, 0, 0))
			end
			task.wait(secondsPerBar / frames)
		end
		prevX = targetX
		shownRows = k
	end
	return { ok = true, rows = shownRows, model = root:GetFullName() }
end

return Replay
