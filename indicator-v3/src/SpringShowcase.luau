-- Spring Indicator showcase controller (Studio, Edit mode). Written 2026-10-05 for the lean install the owner asked for
-- ("cut it off early and just publish and measure"); it stands apart from App so the six-model forecast UI is untouched.
-- Loads one roalgo-spring-indicator-v1 result through the local bridge (GET /saved, sha256-pinned), mounts
-- SpringReplayView (Workspace.RoAlgoSpringReplay) and SpringPanel (CoreGui.RoAlgoSpringPanel) and drives ONE shared
-- cursor: every update shows the same precomputed row in the scene and the panel. Decorative only: no physics, no
-- Engine, no market data beyond the saved result, and the camera is framed once and never held (contract D25).
local SpringStudy = require(script.Parent.SpringStudy)
local SpringReplayView = require(script.Parent.SpringReplayView)
local SpringPanel = require(script.Parent.SpringPanel)
local SpringChart = require(script.Parent.SpringChart)
local SpringBigRigMirror = require(script.Parent.SpringBigRigMirror)

local Http = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")

local BRIDGE = "http://127.0.0.1:47624"
local CONTROL_NAME = "RoAlgoSpringControl"
local SHORT_LABELS = { coupled = "Coupled", zero = "Zero", frozen = "Frozen", independent = "Independent", numeric = "Numeric",
	ema_baseline = "EMA base", no_trade = "No trade" }

local LAUNCHER_NAME = "RoAlgoSpringLauncher"

local SpringShowcase = {}
local lastReopen = nil -- set when the user exits spring mode; the launcher button calls it

local function vector(value)
	if typeof(value) == "Vector3" then return value end
	return nil
end

local function removeLauncher()
	local old = CoreGui:FindFirstChild(LAUNCHER_NAME)
	if old then old:Destroy() end
end

-- After a user Exit, a small bottom-left button reopens the replay where it was left (same row, run, speed, smoothing).
-- Programmatic exits (a restart, the live run taking over) never show it.
local function showLauncher(reopen, label)
	removeLauncher()
	lastReopen = reopen
	local gui = Instance.new("ScreenGui")
	gui.Name = LAUNCHER_NAME
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 41
	local button = Instance.new("TextButton")
	button.Name = "Reopen"
	button.AnchorPoint = Vector2.new(0, 1)
	button.Position = UDim2.new(0, 12, 1, -12)
	button.Size = UDim2.fromOffset(330, 34)
	button.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	button.BackgroundTransparency = 0.02
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.TextSize = 12
	button.TextColor3 = Color3.fromRGB(251, 139, 30)
	button.Text = "◆  SPRING INDICATOR · reopen " .. label
	button.AutoButtonColor = true
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(251, 139, 30)
	stroke.Transparency = 0.3
	stroke.Parent = button
	button.Parent = gui
	local dismiss = Instance.new("TextButton")
	dismiss.Name = "Dismiss"
	dismiss.AnchorPoint = Vector2.new(0, 1)
	dismiss.Position = UDim2.new(0, 348, 1, -12)
	dismiss.Size = UDim2.fromOffset(34, 34)
	dismiss.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	dismiss.BackgroundTransparency = 0.02
	dismiss.BorderSizePixel = 0
	dismiss.Font = Enum.Font.GothamBold
	dismiss.TextSize = 14
	dismiss.TextColor3 = Color3.fromRGB(144, 162, 181)
	dismiss.Text = "×"
	Instance.new("UICorner", dismiss).CornerRadius = UDim.new(0, 8)
	dismiss.Parent = gui
	button.MouseButton1Click:Connect(function()
		button.Text = "opening…"
		local ok, err = pcall(reopen)
		if not ok then
			warn("Spring indicator reopen failed: " .. tostring(err))
			button.Text = "◆  reopen failed (see Output) · try again"
		end
	end)
	dismiss.MouseButton1Click:Connect(function() removeLauncher() end)
	gui.Parent = CoreGui
end

-- Reopens the last replay the user exited (same as clicking the launcher). Returns false when there is nothing to reopen.
function SpringShowcase.reopen()
	if lastReopen == nil then return false end
	lastReopen()
	return true
end

function SpringShowcase.start(options)
	assert(type(options) == "table", "SpringShowcase.start: options table required")
	local name = options.name
	assert(type(name) == "string" and string.match(name, "^[%w_%-]+%.json$"), "SpringShowcase.start: result file name required")
	assert(options.sha256 == nil or (type(options.sha256) == "string" and string.match(options.sha256, "^%x+$") and #options.sha256 == 64),
		"SpringShowcase.start: sha256 must be 64 hex characters")
	local existing = CoreGui:FindFirstChild(CONTROL_NAME)
	if existing then pcall(function() existing:Invoke("exit") end) end
	removeLauncher()

	local url = BRIDGE .. "/saved?name=" .. name .. (if options.sha256 then "&sha256=" .. string.lower(options.sha256) else "")
	local result = Http:JSONDecode(Http:GetAsync(url))
	local valid, reason = SpringStudy.validateResult(result)
	assert(valid, "SpringShowcase: invalid spring result: " .. tostring(reason))

	local N = result.recordCount
	local state = { runId = options.runId or "coupled", compareId = options.compareId or "ema_baseline", index = 1,
		playing = false, rate = options.rate or 6, name = name, smooth = options.smooth ~= false }
	local view, panel, chart, heartbeat, control, mirror
	local mirrorStatus = "big rig mirror off"
	local exited = false
	local states = result.states

	-- Big-rig replay (kinematic, recorded states, restored on exit). On unless options.bigRig == false.
	local function attachMirror()
		if mirror or workspace:FindFirstChild("RoAlgoResearchPhysics") == nil then return end
		local ok, m = pcall(SpringBigRigMirror.attach, { finalX = { coupled = states.coupled.x[N], independent = states.independent.x[N] } })
		if ok then
			mirror = m
			mirrorStatus = string.format("big rig mirrors recorded states (rest spread %.1e studs)", m.restSpread)
		else
			mirrorStatus = "big rig mirror unavailable: " .. tostring(m)
		end
	end
	local function detachMirror()
		if not mirror then return 0 end
		local worst = mirror:restore()
		mirror = nil
		mirrorStatus = string.format("big rig restored to its saved pose (max offset %.1e studs)", worst)
		return worst
	end

	-- Price companion for the chart (display only): must belong to this exact result and match every timestamp.
	local runsById = {}
	for _, run in result.runs do runsById[run.id] = run end
	local labels = table.create(N)
	for i = 1, N do labels[i] = result.timeline[i].l end
	local bars, barsStatus = nil, "no price file"
	local barsName = options.barsName or string.gsub(name, "%.json$", "_bars.json")
	local okBars, barsErr = pcall(function()
		local value = Http:JSONDecode(Http:GetAsync(BRIDGE .. "/saved?name=" .. barsName))
		assert(value.schema == "roalgo-spring-bars-v1" and value.recordCount == N, "price file schema/count mismatch")
		assert(value.resultName == name, "price file belongs to " .. tostring(value.resultName))
		if options.sha256 then assert(value.resultSha256 == string.lower(options.sha256), "price file is for a different result hash") end
		for i = 1, N do assert(value.t[i] == result.timeline[i].t, "price file timestamp mismatch at row " .. i) end
		bars = value
	end)
	barsStatus = if okBars then "prices " .. barsName else "chart off: " .. tostring(barsErr)

	local function context()
		local key = "coupled_vs_" .. (if state.runId == "coupled" then state.compareId else state.runId)
		local comparison = result.comparisons[key]
		return {
			rowCount = N,
			comparisons = comparison and comparison.all or nil,
			evidence = result.evidence,
			provenance = { result = name, protocol = result.protocol.id, study = result.studyVersion },
		}
	end
	local function render()
		local row = SpringStudy.displayRow(result, state.runId, state.index)
		local compareRow = SpringStudy.displayRow(result, state.compareId, state.index)
		view:update(row)
		panel:update(row, compareRow, context())
		if chart then
			chart:update(state.index, bars, runsById[state.runId].fullHistory.rows,
				{ runLabel = SHORT_LABELS[state.runId] or state.runId, label = labels[state.index], labels = labels })
		end
		if mirror then
			local ok, err = pcall(function() mirror:pose(states.coupled.x[state.index], states.independent.x[state.index], labels[state.index]) end)
			if not ok then mirrorStatus = "big rig mirror error: " .. tostring(err) end
		end
	end
	local function seek(index)
		state.index = math.clamp(math.floor(tonumber(index) or 1), 1, N)
		render()
		return state.index
	end
	local function setPlaying(playing)
		local was = state.playing
		state.playing = playing == true
		if panel then panel:setPlaying(state.playing) end
		-- Leaving play snaps the scene back to the exact recorded row (drops any interpolated pose).
		if was and not state.playing and view and not exited then pcall(render) end
	end
	-- userExit = true when the person pressed Exit: leave a reopen button that restores this exact view.
	local function exit(userExit)
		if exited then return true end
		exited = true
		state.playing = false
		if heartbeat then heartbeat:Disconnect() end
		if panel then pcall(function() panel:destroy() end) end
		if chart then pcall(function() chart:destroy() end) end
		if view then pcall(function() view:destroy() end) end
		if control then control:Destroy() end
		pcall(detachMirror)
		if userExit then
			local reopenOptions = table.clone(options)
			reopenOptions.index, reopenOptions.runId, reopenOptions.compareId = state.index, state.runId, state.compareId
			reopenOptions.rate, reopenOptions.smooth, reopenOptions.frame = state.rate, state.smooth, false
			showLauncher(function() SpringShowcase.start(reopenOptions) end, "2024 replay (row " .. state.index .. ")")
		end
		return true
	end

	view = SpringReplayView.mount(workspace, result.descriptor, {})
	panel = SpringPanel.mount(CoreGui, {
		descriptor = result.descriptor,
		callbacks = {
			onRun = function(id) state.runId = id; render() end,
			onPlay = function() setPlaying(true) end,
			onPause = function() setPlaying(false) end,
			onStep = function(delta) setPlaying(false); seek(state.index + (tonumber(delta) or 1)) end,
			onScrub = function(index) seek(index) end,
			onExit = function() exit(true) end,
		},
	})
	local runs = SpringStudy.runs(result)
	for _, run in runs do run.label = SHORT_LABELS[run.id] or run.label end
	panel:setRuns(runs)
	if options.bigRig ~= false then attachMirror() end
	if bars then
		chart = SpringChart.mount(CoreGui, { rightInset = 452, rate = state.rate, smooth = state.smooth,
			onRate = function(rate) state.rate = rate end,
			onSmooth = function(on) state.smooth = on; if not on then render() end end })
	end
	panel:setStatus(barsStatus)

	-- Visual interpolation (smooth on): between two recorded endpoints only the 3D markers glide, by a straight blend of
	-- the two recorded x/v snapshots, and the header says so. Decisions, the panel and the chart change only at exact
	-- recorded rows. The recording holds endpoints only, so the blend is not the springs' true path between them.
	local INTERP_NOTE = " · visual interpolation between recorded 5-minute endpoints (not recorded motion)"
	local lastTween = 0
	local function blend(a, b, fraction)
		if type(a) ~= "table" or type(b) ~= "table" then return a end
		local out = table.create(24)
		for k = 1, 24 do out[k] = a[k] + (b[k] - a[k]) * fraction end
		return out
	end
	local function renderTween(fraction)
		if state.index >= N then return end
		if mirror then
			local i = state.index
			pcall(function()
				mirror:pose(blend(states.coupled.x[i], states.coupled.x[i + 1], fraction),
					blend(states.independent.x[i], states.independent.x[i + 1], fraction), labels[i] .. " · visual interpolation")
			end)
		end
		local a = SpringStudy.displayRow(result, state.runId, state.index)
		if a.x == nil then return end
		local b = SpringStudy.displayRow(result, state.runId, state.index + 1)
		if b.x == nil then return end
		local x, v = table.create(24), table.create(24)
		for k = 1, 24 do
			x[k] = a.x[k] + (b.x[k] - a.x[k]) * fraction
			v[k] = a.v[k] + (b.v[k] - a.v[k]) * fraction
		end
		a.x, a.v = x, v
		a.header = a.header .. INTERP_NOTE
		pcall(function() view:update(a) end)
	end

	local accumulated = 0
	heartbeat = RunService.Heartbeat:Connect(function(dt)
		if not state.playing or exited then accumulated = 0; return end
		accumulated += dt * state.rate
		if accumulated >= 1 then
			local steps = math.floor(accumulated)
			accumulated -= steps
			if state.index + steps >= N then setPlaying(false); accumulated = 0; seek(N); return end
			seek(state.index + steps)
		end
		local now = os.clock()
		if state.smooth and state.rate <= 20 and now - lastTween >= 1 / 40 then
			lastTween = now
			renderTween(accumulated)
		end
	end)

	control = Instance.new("BindableFunction")
	control.Name = CONTROL_NAME
	control.OnInvoke = function(command, ...)
		local args = { ... }
		if exited then return false end
		if command == "status" then
			return { result = name, runId = state.runId, compareId = state.compareId, index = state.index, rowCount = N,
				playing = state.playing, rate = state.rate, evidence = result.evidence.physicsDependence, chart = barsStatus,
				bigRig = mirrorStatus }
		elseif command == "bigrig" then
			if args[1] == false then return detachMirror() end
			attachMirror(); render(); return mirrorStatus
		elseif command == "window" then return chart ~= nil and chart:setWindow(args[1])
		elseif command == "run" then state.runId = args[1]; render(); return true
		elseif command == "compare" then state.compareId = args[1]; render(); return true
		elseif command == "seek" then return seek(args[1])
		elseif command == "play" then setPlaying(true); return true
		elseif command == "pause" then setPlaying(false); return true
		elseif command == "rate" then
			state.rate = math.clamp(tonumber(args[1]) or 6, 0.25, 30)
			if chart then chart:setRate(state.rate) end
			return state.rate
		elseif command == "smooth" then
			state.smooth = args[1] ~= false
			if chart then chart:setSmooth(state.smooth, false) end
			if not state.smooth then render() end
			return state.smooth
		elseif command == "find" then
			-- First row at or after `from` whose final action (or fill) matches, in the selected run.
			local runId, action, from = args[1] or state.runId, args[2], tonumber(args[3]) or 1
			for _, run in result.runs do
				if run.id == runId then
					for i = math.max(1, from), N do
						local r = run.fullHistory.rows[i]
						if r.fa == action then return i end
					end
				end
			end
			return nil
		elseif command == "exit" then return exit(false) -- programmatic: no reopen button
		elseif command == "close" then return exit(true) -- same as the panel's Exit button
		end
		error("RoAlgoSpringControl: unknown command " .. tostring(command))
	end
	control.Parent = CoreGui

	seek(options.index or 1)
	-- Initial framing only (D25): look at the replay once; the camera stays free to orbit.
	local model = workspace:FindFirstChild("RoAlgoSpringReplay")
	local focus, viewAt = model and vector(model:GetAttribute("FocusPosition")), model and vector(model:GetAttribute("ViewPosition"))
	if focus and viewAt and options.frame ~= false then
		local camera = workspace.CurrentCamera
		camera.CFrame = CFrame.lookAt(viewAt, focus)
		camera.Focus = CFrame.new(focus)
		local fov = model:GetAttribute("ViewFieldOfView")
		if type(fov) == "number" then camera.FieldOfView = fov end
	end
	return control
end

return SpringShowcase
