-- Recorded endpoint playback for the eight-lane showcase. No physics or trading computation.
local Replay = {}
local CONTROL = "RoAlgoSpringArrayReplayControl"
local GUI = "RoAlgoSpringArrayReplayPanel"
local RUN = "live_lanes8_1791232619"
local MANIFEST_SHA = "d2210c5b218c227d5b4854dc79484480149fc78813b162d100c44edb78e5f4d2"

local function finite(n)
	return type(n) == "number" and n == n and math.abs(n) < math.huge
end

function Replay.start(options)
	options = options or {}
	assert(game.PlaceId == 0, "SpringArrayReplay: wrong Studio place")
	assert(not game:GetService("RunService"):IsRunning(), "SpringArrayReplay: Edit mode required")
	local core = game:GetService("CoreGui")
	assert(not core:FindFirstChild(CONTROL), "SpringArrayReplay: existing array controller; exit it first")
	local oldControl = core:FindFirstChild("RoAlgoSpringLiveControl")
	if oldControl then
		local current = oldControl:Invoke("status")
		assert(not current.running and not current.busy, "SpringArrayReplay: native capture is active")
		oldControl:Invoke("pause")
	end
	assert(not workspace:FindFirstChild("RoAlgoSpringLiveLanes"), "SpringArrayReplay: release completed native capture first")
	local source = game:GetService("ServerStorage"):FindFirstChild("RoAlgoMarketLab")
	assert(source and source:FindFirstChild("src"), "SpringArrayReplay: installed frozen modules missing")
	local frozen = require(source.src.SpringFrozenV1)
	local Data = require(script.Parent.SpringArrayReplayData)
	local View = require(script.Parent.SpringArrayReplayView)
	local Presentation = require(script.Parent.SpringArrayPresentation)
	local Companion = require(script.Parent.SpringArrayCompanionView)
	local Motion = require(script.Parent.SpringPresentationMotion)
	local Resize = require(script.Parent.SpringPanelResize)
	local NodeColors = require(script.Parent.SpringNodeColors)
	local http = game:GetService("HttpService")
	local baseUrl = options.baseUrl or "http://127.0.0.1:47627"
	assert(baseUrl == "http://127.0.0.1:47627", "SpringArrayReplay: expected recorded-data server")
	local runId = options.runId or RUN
	assert(runId == RUN, "SpringArrayReplay: this installation is pinned to the completed run")
	local state = { phase = "loading", playing = false, tick = 1, rate = 6,
		selectedLane = math.clamp(math.floor(tonumber(options.selectedLane) or 7), 1, 8), loadedChunks = 0,
		totalChunks = 94, loadedRows = 0, runId = runId, physicsRunning = false, uiErrors = 0 }
	local connections, hidden, accumulator = {}, {}, 0
	local data, view, presentation, resizer, companion, motion, nodeColors, smallRig, destroyed, control, fail
	local previousSamples, previousTick, previousLane = {}, nil, nil
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.IgnoreGuiInset, gui.DisplayOrder = GUI, false, true, 90
	local panel = Instance.new("Frame")
	panel.Name = "Controls"
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0, 16, 1, -16)
	panel.Size = UDim2.fromOffset(620, 126)
	panel.BackgroundColor3 = Color3.fromRGB(12, 20, 28)
	panel.BackgroundTransparency, panel.BorderSizePixel = 0.12, 0
	panel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel
	local function label(name, x, y, w, h, size)
		local text = Instance.new("TextLabel")
		text.Name, text.BackgroundTransparency = name, 1
		text.Position, text.Size = UDim2.fromOffset(x, y), UDim2.fromOffset(w, h)
		text.Font, text.TextSize = Enum.Font.Gotham, size or 13
		text.TextColor3 = Color3.fromRGB(221, 234, 244)
		text.TextXAlignment = Enum.TextXAlignment.Left
		text.TextTruncate = Enum.TextTruncate.AtEnd
		text.Parent = panel
		return text
	end
	local title = label("Title", 12, 8, 520, 22, 15)
	title.Font, title.Text = Enum.Font.GothamSemibold, "SPRING CLUSTER"
	local detail = label("Detail", 12, 31, 596, 20, 12)
	local progress = label("Progress", 420, 66, 188, 22, 12)
	progress.TextXAlignment = Enum.TextXAlignment.Right
	local function button(name, caption, x, w, fn)
		local b = Instance.new("TextButton")
		b.Name, b.Text = name, caption
		b.Position, b.Size = UDim2.fromOffset(x, 62), UDim2.fromOffset(w, 30)
		b.BackgroundColor3 = Color3.fromRGB(30, 47, 61)
		b.TextColor3, b.Font, b.TextSize = Color3.fromRGB(225, 241, 249), Enum.Font.GothamSemibold, 12
		b.BorderSizePixel = 0
		b.Parent = panel
		table.insert(connections, b.MouseButton1Click:Connect(fn))
		return b
	end
	local playButton
	local function updateUI()
		if destroyed then return end
		playButton.Text = if state.playing then "Pause" else "Run"
		if state.phase == "loading" then
			detail.Text = string.format("Loading nodes: %d / %d", state.loadedChunks, state.totalChunks)
			progress.Text = string.format("%d bars loaded", state.loadedRows)
		elseif state.phase == "error" then
			detail.Text = "Display load/update failed; previous viewer preserved."
			progress.Text = "See controller status"
		else
			detail.Text = "8 layers / 384 nodes"
			progress.Text = string.format("Tick %d / %d", state.tick, data.totalTicks)
		end
	end
	local function render(animate)
		local started = os.clock()
		local samples = {}
		local continuous = animate == true and previousTick == state.tick - 1 and previousLane == state.selectedLane
		for lane = 1, data.laneCount do
			local sample = data:sample(lane, state.tick)
			samples[lane] = sample
			local previous = previousSamples[lane]
			if not previous or previous.phase ~= sample.phase or previous.blockId ~= sample.blockId then continuous = false end
		end
		if motion then motion:capture() end
		for lane = 1, data.laneCount do view:updateLane(samples[lane]) end
		local sample = samples[state.selectedLane]
		if presentation then presentation:update(sample, state) end
		if companion then companion:update(sample) end
		if smallRig then
			-- The retained viewer supplies the exact selected row; hide it during unrecorded gaps.
			smallRig.Parent = if sample.phase == "recorded" then workspace else script.Parent
			local card = smallRig:FindFirstChild("Header") and smallRig.Header:FindFirstChild("Card")
			if card then
				card.Title.Text = "SPRING CLUSTER · COUPLED"
				card.Detail.Text = "LAYER " .. state.selectedLane .. " · " .. (sample.label or "")
				card.Notice.Visible, card.Scope.Visible = false, false
			end
		end
		if motion then motion:transition(if continuous then 1 / 6 else 0) end
		if nodeColors then nodeColors:update() end
		previousSamples, previousTick, previousLane = samples, state.tick, state.selectedLane
		updateUI()
		state.lastRenderMs = (os.clock() - started) * 1000
		state.maxRenderMs = math.max(state.maxRenderMs or 0, state.lastRenderMs)
		state.renderCount = (state.renderCount or 0) + 1
		state.totalRenderMs = (state.totalRenderMs or 0) + state.lastRenderMs
	end
	local function seek(tick)
		if state.phase ~= "ready" then return false end
		assert(finite(tick), "SpringArrayReplay: finite tick required")
		state.tick = math.clamp(math.floor(tick), 1, data.totalTicks)
		accumulator = 0
		local ok, failure = pcall(render)
		if not ok then fail(failure); return false end
		return state.tick
	end
	local function play(value)
		if state.phase ~= "ready" then return false end
		if value and state.tick == data.totalTicks and not seek(1) then return false end
		state.playing = value == true
		accumulator = 0
		local ok, failure = pcall(function()
			if not state.playing and motion then motion:snap() end
			if presentation then presentation:update(data:sample(state.selectedLane, state.tick), state) end
			if nodeColors then nodeColors:update() end
		end)
		if not ok then fail(failure); return false end
		updateUI()
		return state.playing
	end
	local function frame()
		if not view or not view.model then return false end
		local model = view.model
		local at, focus = model:GetAttribute("ViewPosition"), model:GetAttribute("FocusPosition")
		if typeof(at) ~= "Vector3" or typeof(focus) ~= "Vector3" then return false end
		task.delay(0.5, function()
			if destroyed then return end
			local camera = workspace.CurrentCamera
			if camera then
				camera.CFrame = CFrame.lookAt(at, focus)
				camera.Focus = CFrame.new(focus)
				camera.FieldOfView = model:GetAttribute("ViewFieldOfView") or 50
			end
		end)
		return true
	end
	local function restorePrevious()
		for _, h in hidden do
			if h.instance.Parent ~= nil then
				if h.properties then
					for key, value in h.properties do h.instance[key] = value end
				elseif h.enabled ~= nil then h.instance.Enabled = h.enabled else h.instance.Parent = h.parent end
			end
		end
		table.clear(hidden)
	end
	local function dispose(object)
		if not object then return end
		local ok, failure = pcall(function() object:destroy() end)
		if not ok then
			state.cleanupError = tostring(failure)
			warn(state.cleanupError)
		end
	end
	fail = function(failure)
		if destroyed then return end
		dispose(motion); motion = nil
		dispose(nodeColors); nodeColors = nil
		dispose(resizer); resizer = nil
		dispose(presentation); presentation = nil
		dispose(companion); companion = nil
		dispose(view); view = nil
		restorePrevious()
		panel.Visible = true
		state.phase, state.playing, state.error = "error", false, tostring(failure)
		state.uiErrors += 1
		warn(state.error); updateUI()
	end
	local function destroy()
		if destroyed then return end
		destroyed, state.playing = true, false
		for _, c in connections do c:Disconnect() end
		dispose(motion)
		dispose(nodeColors)
		dispose(resizer)
		dispose(presentation)
		dispose(companion)
		dispose(view)
		gui:Destroy()
		if control then control:Destroy() end
		restorePrevious()
	end
	playButton = button("PlayPause", "Run", 12, 68, function() play(not state.playing) end)
	button("Frame", "View array", 352, 78, frame)
	local exitButton = Instance.new("TextButton")
	exitButton.Name, exitButton.Text = "Exit", "Close"
	exitButton.Position, exitButton.Size = UDim2.fromOffset(554, 8), UDim2.fromOffset(54, 22)
	exitButton.BackgroundTransparency = 1
	exitButton.TextColor3, exitButton.Font, exitButton.TextSize = Color3.fromRGB(162, 180, 194), Enum.Font.Gotham, 12
	exitButton.Parent = panel
	table.insert(connections, exitButton.MouseButton1Click:Connect(destroy))
	local track = Instance.new("TextButton")
	track.Name, track.Text, track.AutoButtonColor = "Timeline", "", false
	track.Position, track.Size = UDim2.fromOffset(12, 104), UDim2.fromOffset(596, 10)
	track.BackgroundColor3, track.BorderSizePixel = Color3.fromRGB(39, 58, 73), 0
	track.Parent = panel
	local fill = Instance.new("Frame")
	fill.Name, fill.Size = "Progress", UDim2.fromScale(0, 1)
	fill.BackgroundColor3, fill.BorderSizePixel = Color3.fromRGB(57, 207, 187), 0
	fill.Parent = track
	local dragging = false
	local function scrub(input)
		if state.phase ~= "ready" then return end
		play(false)
		local width = track.AbsoluteSize.X
		if width > 0 then seek(1 + math.clamp((input.Position.X - track.AbsolutePosition.X) / width, 0, 1) * (data.totalTicks - 1)) end
	end
	table.insert(connections, track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true; scrub(input)
		end
	end))
	local inputService = game:GetService("UserInputService")
	table.insert(connections, inputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then scrub(input) end
	end))
	table.insert(connections, inputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end))
	control = Instance.new("BindableFunction")
	control.Name = CONTROL
	control.OnInvoke = function(command, arg)
		if command == "status" then
			local out = table.clone(state)
			out.data = data and data:stats() or nil
			out.view = view and view:stats() or nil
			out.presentation = presentation and presentation:stats() or nil
			out.companion = companion and companion:stats() or nil
			out.motion = motion and motion:stats() or nil
			out.nodeColors = nodeColors and nodeColors:stats() or nil
			out.layout = resizer and resizer:stats() or nil
			out.destroyed = destroyed == true
			return out
		elseif command == "play" then return play(true)
		elseif command == "pause" then return play(false)
		elseif command == "seek" then return seek(arg)
		elseif command == "seekrow" then
			if state.phase ~= "ready" then return false end
			assert(finite(arg), "SpringArrayReplay: row must be finite")
			local row = math.clamp(math.floor(arg), 1, data.totalRows)
			local location = data:locateRow(row)
			play(false)
			state.selectedLane = location.lane
			if not seek(location.tick) then return false end
			return row
		elseif command == "rate" then
			assert(finite(arg), "SpringArrayReplay: rate must be finite")
			assert(arg == 6, "SpringArrayReplay: filming rate is fixed at six ticks per second")
			return state.rate
		elseif command == "lane" then
			assert(finite(arg), "SpringArrayReplay: lane must be finite")
			state.selectedLane = math.clamp(math.floor(arg), 1, 8)
			if state.phase == "ready" then
				local ok, failure = pcall(render)
				if not ok then fail(failure); return false end
			end
			return state.selectedLane
		elseif command == "frame" then return frame()
		elseif command == "exit" then destroy(); return true end
		error("SpringArrayReplay: unsupported command " .. tostring(command))
	end
	control.Parent, gui.Parent = core, core
	updateUI()
	local function get(name, sha)
		assert(not destroyed, "SpringArrayReplay: loading cancelled")
		local url = baseUrl .. "/spring-live/chunk?runId=" .. runId .. "&name=" .. name .. "&sha256=" .. sha
		local response = http:RequestAsync({ Url = url, Method = "GET" })
		assert(response.Success, string.format("SpringArrayReplay: %s HTTP %s", name, tostring(response.StatusCode)))
		local found
		for key, value in response.Headers or {} do if string.lower(key) == "x-content-sha256" then found = value end end
		assert(found == sha, "SpringArrayReplay: server hash receipt mismatch for " .. name)
		return http:JSONDecode(response.Body)
	end
	task.spawn(function()
		local ok, failure = pcall(function()
			local manifest = get("manifest", MANIFEST_SHA)
			assert(manifest.status == "complete" and manifest.runId == runId and manifest.unsavedRows == 0,
				"SpringArrayReplay: complete saved run required")
			local plan = get("plan", manifest.planSha256)
			assert(plan.runId == runId, "SpringArrayReplay: plan identity mismatch")
			local seal = manifest.native.capture.seal
			assert(seal.name == "lanes", "SpringArrayReplay: lane seal missing")
			local laneSeal = get("lanes", seal.sha256)
			assert(laneSeal.runId == runId and laneSeal.lanes == 8, "SpringArrayReplay: lane identity mismatch")
			data = Data.new(laneSeal, manifest.lastSavedIndex)
			state.totalChunks = #manifest.chunks
			local previous, nextIndex = manifest.planSha256, 1
			for index, receipt in manifest.chunks do
				local envelope = get(receipt.name, receipt.sha256)
				assert(envelope.runId == runId and envelope.seq == index and envelope.firstIndex == nextIndex
					and envelope.prevSha256 == previous, "SpringArrayReplay: broken archive chain")
				data:append(envelope.chunk)
				previous, nextIndex = receipt.sha256, envelope.lastIndex + 1
				state.loadedChunks, state.loadedRows = index, envelope.lastIndex
				updateUI()
				task.wait()
			end
			assert(previous == manifest.lastChunkSha256 and nextIndex - 1 == manifest.lastSavedIndex,
				"SpringArrayReplay: incomplete recording")
			data:finish()
			state.totalTicks = data.totalTicks
			assert(not destroyed, "SpringArrayReplay: loading cancelled")
			view = View.mount(workspace, frozen.descriptor, frozen.nativeConfig2024, { laneCount = 8, layerSpacing = 800 })
			assert(oldControl, "SpringArrayReplay: retained trading viewer required")
			oldControl:Invoke("pause")
			oldControl:Invoke("run", "coupled")
			oldControl:Invoke("compare", "independent")
			presentation = Presentation.mount(core, oldControl, {
				play = play, seek = seek,
				seekRow = function(value) return control:Invoke("seekrow", value) end,
				descriptor = frozen.descriptor, nativeConfig = frozen.nativeConfig2024,
				rate = function(value) return control:Invoke("rate", value) end,
				lane = function(value) return control:Invoke("lane", value) end,
			})
			resizer = Resize.mount(core, { storage = script.Parent, lifecycle = control })
			smallRig = workspace:FindFirstChild("RoAlgoSpringReplay") or script.Parent:FindFirstChild("RoAlgoSpringReplay")
			if smallRig then
				table.insert(hidden, { instance = smallRig, parent = smallRig.Parent })
				smallRig.Parent = workspace
				for _, beam in smallRig:GetDescendants() do
					if beam:IsA("Beam") and beam:GetAttribute("Coupling") == true then
						table.insert(hidden, { instance = beam, properties = { Width0 = beam.Width0, Width1 = beam.Width1 } })
						beam.Width0, beam.Width1 = 3.2, 3.2
					end
				end
				local card = smallRig:FindFirstChild("Header") and smallRig.Header:FindFirstChild("Card")
				if card then
					for _, name in { "Title", "Detail", "Notice", "Scope" } do
						local label = card:FindFirstChild(name)
						if label then table.insert(hidden, { instance = label, properties = { Visible = label.Visible, Text = label.Text } }) end
					end
				end
			end
			local bigRig = workspace:FindFirstChild("RoAlgoResearchPhysics")
			if bigRig then companion = Companion.mount(bigRig, frozen.descriptor) end
			local models = { view.model }
			if companion then table.insert(models, companion.model) end
			if smallRig then table.insert(models, smallRig) end
			motion = Motion.new(models)
			nodeColors = NodeColors.mount(models, { D = frozen.descriptor.D, lifecycle = control, autoUpdate = false })
			state.phase, state.playing = "ready", false
			panel.Visible = false
			seek(options.initialTick or data.firstAllRecordedTick or 1)
			if options.frame == true then frame() end
			if options.playing == true then play(true) end
		end)
		if not ok and not destroyed then
			fail(failure)
		end
	end)
	table.insert(connections, game:GetService("RunService").Heartbeat:Connect(function(dt)
		if destroyed or state.phase ~= "ready" then return end
		if motion then
			local ok, failure = pcall(function()
				motion:advance(dt)
				if nodeColors then nodeColors:update() end
			end)
			if not ok then fail(failure); return end
		end
		fill.Size = UDim2.fromScale((state.tick - 1) / math.max(data.totalTicks - 1, 1), 1)
		if not state.playing then return end
		accumulator += dt * state.rate
		local count = math.floor(accumulator)
		if count < 1 then return end
		accumulator -= count
		state.tick = math.min(state.tick + count, data.totalTicks)
		if state.tick == data.totalTicks then state.playing = false end
		local ok, failure = pcall(render, true)
		if not ok then
			fail(failure)
		end
	end))
	return control
end

return Replay
