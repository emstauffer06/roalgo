-- SpringLaneCapture: the multi-lane capture of spring-live-contract.md section 1b (L15-L21), behind the SpringLiveCapture
-- interface, so the reviewed SpringLive controller drives it unchanged:
--     SpringLive.start({..., deps = {modules = {SpringLiveCapture = SpringLaneCapture.module({lanes = 8, runId = runId})}}})
-- ENGINE CODE: Studio Edit mode, plugin context. Written 2026-10-05 at the owner's request ("let the parallelized live physics
-- run start").
--
--   L15  Only raw candles come from outside. new() GETs every page from the :47627 data server and runs the capture-time
--        Features (SpringV2Features, pinned) once over all bars in order inside Studio (SpringFeaturesPass), no physics.
--   L16  N copies of the unchanged capture-time Engine (SpringV2Engine, pinned) at CAPTURE_ORIGIN + (0, 0, offsetZ) from
--        SpringLaneLayout.plan. Every copy is checked against the 2024 native.config (deep-equal), masses and rest
--        geometry, and the measured part boxes are checked against the plan (SpringLaneLayout.verifyBuilt).
--   L17  ONE VerifiedStepper (pinned, unchanged) over every lane's 48 bodies plus two metronomes: one StepPhysics(1/60, all
--        parts) request per step, the capture's barrier, metronome and quiet-frame protocol, 12 steps per bar on every lane.
--        Each copy's own runner is destroyed unused. Drives are applied before the step and read after it exactly as
--        Engine:step does (Rig:drive / Rig:read / Rig:state / numeric:step). Any corrupt or fractional step faults the run.
--   L18  SpringBlockSchedule: 5-session blocks, round robin, each block from rest one session early (warm-up rows are
--        stepped and counted, never decided on).
--   L19  Rows reach the controller strictly in time order: cap:step(bar) waits until the lane that owns the bar has stepped
--        it. A producer thread steps all lanes continuously, so decisions run between physics frames. A row is final once
--        stepped, so deciding row by row gives exactly what deciding after the whole block would.
--   L21  One label per lane with its block dates and a warm-up tag.
--   The lane plan (N, layout, schedule, features digest, module hashes) is sealed as the write-once chunk "lanes" before
--   the first bar is stepped. It never touches Workspace.RoAlgoResearchPhysics, never runs Play, never moves the camera.
local SpringLaneCapture = {}

local PLACE_ID = 0
local MECHANICS_SCHEMA = "roalgo-mechanics-v2-1"
local STEPPER_SCHEMA = "verified-stepper-v2-2"
local NODE_COUNT, EDGE_COUNT = 24, 37
local EXPECTED_MASS = 3.375
local STEPS_PER_BAR = 12
local ISOLATION_LIMIT = 1e-6
local VECTOR_SIZE = 51
local VARIANTS = { "coupled", "independent", "numeric" }
local EXPECT_BARS, EXPECT_SESSIONS = 36402, 469
-- luau.exe digest of the 36,402-bar features pass (groundwork lane, 2026-10-05); Studio's is compared and disclosed.
local OFFLINE_DIGEST = "sfp1-hex:36402:8b1dffdb7cf50c5280e454969d511fd377b775edb1da9b34b78ce4e2a764c787"
local DEFAULT_BASE_URL = "http://127.0.0.1:47627"
local LIVE_CONTROL = "RoAlgoSpringLiveControl"
local LANE_MODULES = { "SpringLaneCapture", "SpringLaneLayout", "SpringLaneDisplay", "SpringBlockSchedule", "SpringFeaturesPass", "SpringLiveCapture" }
local AMBER, BLACK, WHITE = Color3.fromRGB(251, 139, 30), Color3.fromRGB(0, 0, 0), Color3.fromRGB(230, 230, 230)
local ZERO8 = table.freeze(table.create(8, 0))

SpringLaneCapture.SCHEMA = "roalgo-spring-lane-capture-1"
SpringLaneCapture.CONTAINER_NAME = "RoAlgoSpringLiveLanes"
SpringLaneCapture.OFFLINE_DIGEST = OFFLINE_DIGEST

local active: any = nil -- the one live lane capture (never two)
local retainedProbe: any = nil -- kept for the L21 screenshot until explicit releaseProbe()

local function fmt(x: any): string
	if type(x) == "number" then return string.format("%.17g", x) end
	return tostring(x)
end
local function check(condition: any, message: string) if not condition then error(message, 0) end end
local function near(a: any, b: number): boolean return type(a) == "number" and math.abs(a - b) <= 1e-6 end
local function deepCopy(x: any): any
	if type(x) ~= "table" then return x end
	local out = {}
	for k, v in next, x do out[k] = deepCopy(v) end
	return out
end

local function sibling(name: string): any
	local m = script.Parent:FindFirstChild(name)
	check(m ~= nil and m:IsA("ModuleScript"), "SpringLaneCapture: ModuleScript " .. name .. " is missing beside it")
	return m
end

-- Pinned capture modules must match exactly; the lane modules are recorded (sealed) but have no 2024 pin.
local function moduleReceipts(Live: any): any
	local receipts, problems = { pinned = {}, lane = {} }, {}
	for _, name in Live.MODULE_ORDER do
		local m = sibling(name)
		local measured = Live.sha256(m.Source)
		local pin = Live.MODULE_PINS[name]
		local stamp = m:FindFirstChild("SourceSHA256")
		if measured ~= pin then table.insert(problems, name .. " Source sha256 " .. measured .. " differs from pinned " .. pin) end
		receipts.pinned[name] = { sha256 = measured, pin = pin, attribute = m:GetAttribute("sha256"), stamp = if stamp then stamp.Value else nil }
	end
	for _, name in LANE_MODULES do
		local m = sibling(name)
		local stamp = m:FindFirstChild("SourceSHA256")
		receipts.lane[name] = { sha256 = Live.sha256(m.Source), attribute = m:GetAttribute("sha256"), stamp = if stamp then stamp.Value else nil }
	end
	check(#problems == 0, "SpringLaneCapture: module identity differs: " .. table.concat(problems, "; "))
	return receipts
end

local function studioSettings(): any
	local out = {}
	local function try(key: string, read: () -> any)
		local ok, value = pcall(read)
		if ok and value ~= nil then
			out[key] = if type(value) == "number" or type(value) == "boolean" or type(value) == "string" then value else tostring(value)
		end
	end
	try("placeId", function() return game.PlaceId end)
	try("studioVersion", function() return version() end)
	try("gravity", function() return workspace.Gravity end)
	try("physicsSteppingMethod", function() return workspace.PhysicsSteppingMethod end)
	try("allowSleep", function() return settings().Physics.AllowSleep end)
	try("physicsEnvironmentalThrottle", function() return settings().Physics.PhysicsEnvironmentalThrottle end)
	return out
end

-- Isolation (L13): every unanchored BasePart that existed before the lanes were built must not move.
local function readMotion(part: any): { number }
	local p, l, a = part.Position, part.AssemblyLinearVelocity, part.AssemblyAngularVelocity
	return { p.X, p.Y, p.Z, l.X, l.Y, l.Z, a.X, a.Y, a.Z }
end
local function snapshotIsolation(): { any }
	local entries = {}
	for _, inst in workspace:GetDescendants() do
		if inst:IsA("BasePart") and inst.Anchored == false then table.insert(entries, { part = inst, values = readMotion(inst) }) end
	end
	return entries
end
local function measureIsolation(entries: { any }): (number, string?, number)
	local maxDelta, worst, missing = 0, nil, 0
	for _, entry in entries do
		local part = entry.part
		if part.Parent == nil then
			missing += 1
		else
			local now = readMotion(part)
			for k = 1, 9 do
				local d = math.abs(now[k] - entry.values[k])
				if d ~= d then d = math.huge end
				if d > maxDelta then maxDelta, worst = d, part:GetFullName() end
			end
		end
	end
	return maxDelta, worst, missing
end

------------------------------------------------------------------------------------------------------------------------
-- Lanes: N unchanged capture Engines, checked, their own runners removed, one shared VerifiedStepper.
local function checkLane(engine: any, k: number, origin: Vector3, reference: any, container: Instance, Live: any)
	local c = engine.config
	check(type(c) == "table" and c.schema == MECHANICS_SCHEMA, "lane " .. k .. ": mechanics schema must be " .. MECHANICS_SCHEMA)
	local protocol = c.nativeProtocol
	check(type(protocol) == "table" and protocol.schema == STEPPER_SCHEMA and protocol.lossFrames == 3 and protocol.postBarQuietFrames == 2,
		"lane " .. k .. ": native protocol must be " .. STEPPER_SCHEMA)
	local same, where = Live.deepEqual(c, reference, "engine.config")
	check(same, "lane " .. k .. ": engine.config differs from the 2024 native.config at " .. tostring(where))
	check(engine.model.Parent == container, "lane " .. k .. ": the engine model must sit in " .. container.Name)
	check(engine.destroyed == false and engine.busy == false and engine.fault == nil and engine.failedBars == 0, "lane " .. k .. ": fresh engine required")
	check(#c.nodes == NODE_COUNT and #c.edges == EDGE_COUNT, "lane " .. k .. ": 24 nodes and 37 edges required")
	local coupled, independent = engine.coupledRig, engine.independentRig
	check(coupled.coupled == true and independent.coupled == false and #coupled.couplings == EDGE_COUNT and #independent.couplings == 0,
		"lane " .. k .. ": one coupled rig with 37 couplings and one independent rig with none")
	local independentOffset = 11 * c.spacing
	for i, n in c.nodes do
		for r, rig in { coupled, independent } do
			local node = rig.nodes[i]
			local dz = if r == 1 then 0 else independentOffset
			local rest, part = node.rest, node.part
			check(near(rest.X, origin.X) and near(rest.Y, origin.Y + n.y) and near(rest.Z, origin.Z + dz + n.z),
				"lane " .. k .. " node " .. i .. ": rest must be the lane origin + (0, y, z)")
			local p = part.Position
			check(part == rig.parts[i] and part.Anchored == false and near(p.X, rest.X) and near(p.Y, rest.Y) and near(p.Z, rest.Z),
				"lane " .. k .. " node " .. i .. ": unanchored and at rest")
			check(part.AssemblyMass == EXPECTED_MASS and n.mass == EXPECTED_MASS,
				"lane " .. k .. " node " .. i .. ": AssemblyMass " .. fmt(part.AssemblyMass) .. " must equal the 2024 mass 3.375")
		end
	end
	local numeric = engine.numeric
	check(type(numeric) == "table" and numeric.config == c and numeric.coupled == true and numeric.totalSteps == 0,
		"lane " .. k .. ": fresh coupled numeric comparator required")
end

local function v3(v: Vector3): any return { x = v.X, y = v.Y, z = v.Z } end

local function measuredParts(engine: any): { any }
	local out = {}
	for _, rig in { engine.coupledRig, engine.independentRig } do
		for _, n in rig.nodes do
			table.insert(out, { pos = v3(n.guide.Position), size = v3(n.guide.Size), moving = false })
			table.insert(out, { pos = v3(n.anchor.Position), size = v3(n.anchor.Size), moving = false })
			table.insert(out, { pos = v3(n.rest), size = v3(n.part.Size), moving = true })
		end
	end
	return out
end

-- Select the smallest valid spacing on Layout's quantum grid without moving the capture origin. Each lane/zone pair
-- whose full footprints overlap in X and Y forbids one CLOSED interval of spacings along Z. Sorting those intervals
-- permits one finite pass: at most count * #excluded intervals, jumping strictly beyond a containing interval's end.
-- The result is bounded by max(minimum spacing, largest positive forbidden endpoint + one quantum). There is no
-- trial construction, unbounded search, ignored exclusion, or movement of the research rig. A fixed middle lane that
-- intersects a zone cannot be repaired by spacing and is refused. The unchanged Layout validates the final plan.
local function selectLanePlan(Layout: any, reference: any, count: number, excluded: any): any
	local base = Layout.plan(reference, { count = count, gap = 512, excluded = {} })
	local footprint, intervals = base.footprint, {}
	for z, zone in excluded do
		local xGap = math.max(footprint.min.x - zone.max.x, zone.min.x - footprint.max.x)
		local yGap = math.max(footprint.min.y - zone.max.y, zone.min.y - footprint.max.y)
		if xGap <= 0 and yGap <= 0 then
			for k = 1, count do
				local multiplier = k - (count + 1) / 2
				if multiplier == 0 then
					check(not Layout.intersects(footprint, zone),
						"SpringLaneCapture: fixed center lane intersects excluded zone " .. z .. "; spacing cannot clear it")
				else
					local a = (zone.min.z - footprint.max.z) / multiplier
					local b = (zone.max.z - footprint.min.z) / multiplier
					table.insert(intervals, { lo = math.min(a, b), hi = math.max(a, b) })
				end
			end
		end
	end
	table.sort(intervals, function(a, b) return a.lo < b.lo end)
	local spacing, quantum = base.spacing, base.quantum
	for _, interval in intervals do
		if spacing < interval.lo then break end
		if spacing <= interval.hi then
			spacing = (math.floor(interval.hi / quantum) + 1) * quantum
			check(spacing < math.huge and spacing > interval.hi,
				"SpringLaneCapture: excluded zones require spacing beyond finite quantum precision")
		end
	end
	return Layout.plan(reference, { count = count, gap = base.gap, quantum = quantum, spacing = spacing, excluded = excluded })
end

-- Builds N lanes and the shared stepper. Probe and production share the same scene-aware placement selection.
-- Raises (after removing everything it made) on any check failure.
local function buildLanes(count: number, reference: any, Live: any): any
	local Layout = require(sibling("SpringLaneLayout"))
	local Engine = require(sibling("SpringV2Engine"))
	local Stepper = require(sibling("VerifiedStepper"))
	local excluded = Layout.metronomeZones()
	local big = workspace:FindFirstChild(Live.FORBIDDEN_NAME)
	if big and big:IsA("Model") then
		local cf, size = big:GetBoundingBox()
		local half = size / 2
		table.insert(excluded, { min = v3(cf.Position - half), max = v3(cf.Position + half) })
	end
	local plan = selectLanePlan(Layout, reference, count, excluded)
	Layout.verify(plan, reference)
	check(workspace:FindFirstChild(SpringLaneCapture.CONTAINER_NAME) == nil,
		"Workspace." .. SpringLaneCapture.CONTAINER_NAME .. " already exists; remove it first")
	local container = Instance.new("Model")
	container.Name = SpringLaneCapture.CONTAINER_NAME
	container:SetAttribute("Schema", SpringLaneCapture.SCHEMA)
	container:SetAttribute("Lanes", count)
	container:SetAttribute("Spacing", plan.spacing)
	container:SetAttribute("Scope", "Live native multi-lane capture: N unchanged capture Engines stepped by one VerifiedStepper")
	container.Parent = workspace
	local lanes, built = {}, {}
	local ok, err = pcall(function()
		for k = 1, count do
			local o = plan.lanes[k].origin
			local origin = Vector3.new(o.x, o.y, o.z)
			local engine = Engine.new(container, { name = string.format("Lane%02d", k), origin = origin })
			checkLane(engine, k, origin, reference, container, Live)
			engine.runner:destroy() -- its metronomes; the lane is stepped only by the shared runner below
			engine.model:SetAttribute("LaneIndex", k)
			engine.model:SetAttribute("LaneOffsetZ", plan.lanes[k].offsetZ)
			lanes[k] = { index = k, engine = engine, coupled = engine.coupledRig, independent = engine.independentRig,
				numeric = engine.numeric, config = engine.config, offsetZ = plan.lanes[k].offsetZ }
			built[k] = measuredParts(engine)
		end
	end)
	if not ok then
		for _, lane in lanes do pcall(function() lane.engine:destroy() end) end
		container:Destroy()
		error("SpringLaneCapture: building lane " .. (#lanes + 1) .. " failed: " .. tostring(err), 0)
	end
	local okBuilt, report = pcall(Layout.verifyBuilt, plan, built)
	local reservoirs = {}
	for _, lane in lanes do
		table.insert(reservoirs, lane.coupled)
		table.insert(reservoirs, lane.independent)
	end
	local okRunner, runner = false, nil
	if okBuilt then
		okRunner, runner = pcall(Stepper.new, reservoirs, { dt = 1 / 60, stepsPerBar = 12, settleSteps = 0, parent = container,
			lossFrames = 3, postBarQuietFrames = 2 })
	end
	if not okBuilt or not okRunner then
		for _, lane in lanes do pcall(function() lane.engine:destroy() end) end
		container:Destroy()
		error("SpringLaneCapture: " .. (if okBuilt then "shared stepper: " .. tostring(runner) else "built lanes leave the plan: " .. tostring(report)), 0)
	end
	check(#runner.parts == 2 * NODE_COUNT * count + 2 and #runner.metronomes == 2,
		"the shared StepPhysics list must hold 48 bodies per lane plus two metronomes")
	runner:recover()
	runner:resetSegment()
	local Display = require(sibling("SpringLaneDisplay"))
	local okDisplay, display = pcall(Display.mount, container, lanes, { runner = runner })
	if not okDisplay then
		pcall(function() runner:destroy() end)
		for _, lane in lanes do pcall(function() lane.engine:destroy() end) end
		container:Destroy()
		error("SpringLaneCapture: translated display: " .. tostring(display), 0)
	end
	return { plan = plan, built = report, container = container, lanes = lanes, runner = runner, display = display }
end

------------------------------------------------------------------------------------------------------------------------
local function httpJson(Http: any, url: string): any
	local body = Http:GetAsync(url)
	return Http:JSONDecode(body)
end

local function postChunk(Http: any, baseUrl: string, runId: string, name: string, payload: any): any
	local body = Http:JSONEncode({ runId = runId, name = name, payload = payload })
	local response = Http:RequestAsync({ Url = baseUrl .. "/spring-live/chunk", Method = "POST",
		Headers = { ["Content-Type"] = "application/json" }, Body = body })
	check(response.Success == true and (response.StatusCode == 200 or response.StatusCode == 201),
		"POST " .. name .. " -> HTTP " .. tostring(response.StatusCode) .. " " .. string.sub(tostring(response.Body), 1, 200))
	local receipt = Http:JSONDecode(response.Body)
	check(type(receipt) == "table" and receipt.ok == true and type(receipt.sha256) == "string", "POST " .. name .. ": invalid receipt")
	return { name = name, sha256 = receipt.sha256, bytes = receipt.bytes, path = receipt.path }
end

-- The capture-time Features cold start, exactly as SpringLiveCapture checks it.
local function checkFeatures(features: any, prehistory: any)
	check(type(features) == "table" and features.prehistory == prehistory, "Features must hold the supplied prehistory")
	check(features.observations == 0 and features.previous == nil and features.regimeModel == nil, "Features must be a cold start")
	check(features.trend == 0 and features.var == 1e-8 and features.alpha == 0.05, "Features scalars must be trend 0, var 1e-8, alpha 0.05")
	check(type(features.driveScales) == "table" and #features.driveScales == 7, "Features must have 7 drive scales")
	for _, s in features.driveScales do check(s == 1e-6, "every drive scale must start at 1e-6") end
end

local Capture = {}
Capture.__index = Capture

local function laneLabel(lane: any, container: Instance, display: any?)
	local adornee = if display then display.labelAnchors[lane.index] else lane.coupled.nodes[1].guide
	local gui = Instance.new("BillboardGui")
	gui.Name = string.format("Lane%02dLabel", lane.index)
	gui.Adornee = adornee
	gui.AlwaysOnTop = true
	gui.MaxDistance = 0
	gui.LightInfluence = 0
	gui.Size = UDim2.fromOffset(300, 34)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 80, 0)
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundColor3 = BLACK
	text.BackgroundTransparency = 0.35
	text.BorderSizePixel = 0
	text.TextColor3 = AMBER
	text.TextTransparency = 0.1
	text.Font = Enum.Font.RobotoMono
	text.TextSize = 12
	text.TextWrapped = true
	text.Text = string.format("LANE %d", lane.index)
	text.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Color = AMBER
	stroke.Transparency = 0.4
	stroke.Parent = text
	gui:SetAttribute("VisualOnly", true)
	gui.Parent = container
	lane.label = text
end

local function blockDays(block: any): (string, string)
	return block.days[1], block.days[#block.days]
end

function Capture:_setLabel(lane: any)
	if not lane.label then return end
	local block = lane.block
	if block == nil then
		lane.label.Text = string.format("LANE %d · done · %d blocks", lane.index, lane.blocksDone)
		lane.label.TextColor3 = WHITE
		return
	end
	local first, last = blockDays(block)
	local warm = lane.cursor < block.firstIndex
	lane.label.Text = string.format("LANE %d · block %d · %s → %s%s", lane.index, block.id, first, last,
		if warm then " · WARM-UP" else "")
	lane.label.TextColor3 = if warm then WHITE else AMBER
end

function Capture:_reset(lane: any)
	lane.coupled:reset()
	lane.independent:reset()
	lane.numeric:reset()
	lane.resets += 1
end

function Capture:_nextBlock(lane: any)
	lane.slot += 1
	local id = lane.queue[lane.slot]
	if id == nil then
		if lane.block then lane.blocksDone += 1 end
		lane.block, lane.cursor = nil, nil
		self:_reset(lane) -- idle lanes sit exactly at rest with zero drive
	else
		if lane.block then lane.blocksDone += 1 end
		local block = self.schedule.blocks[id]
		check(block.id == id and block.lane == lane.index, "schedule block " .. id .. " is not on lane " .. lane.index)
		lane.block = block
		lane.cursor = if block.warmBars > 0 then block.warmFirstIndex else block.firstIndex
		lane.needsReset = true
	end
	self:_setLabel(lane)
end

-- One bar on every lane: exactly one runner:stepBar over all lanes (12 verified steps of every part).
-- Returns false when no lane has work left.
function Capture:_globalStep(): boolean
	local lanes, Mechanics = self.lanes, self.Mechanics
	local inputs, work = table.create(2 * #lanes), {}
	for k, lane in lanes do
		local drive = ZERO8
		if lane.block then
			local i = lane.cursor
			local feature = self.pass:get(i)
			Mechanics.project(lane.config, feature.drive) -- validate completely before any mutation (as Engine:step)
			if lane.needsReset or feature.reset then
				self:_reset(lane)
				lane.needsReset = false
				if feature.reset then lane.featureResets += 1 end
			end
			for _, value in feature.drive do if math.abs(value) > 2 then lane.clippedInputs += 1 end end
			drive = feature.drive
			work[k] = { i = i, feature = feature, decided = i >= lane.block.firstIndex, block = lane.block.id }
		end
		inputs[2 * k - 1], inputs[2 * k] = drive, drive
	end
	if next(work) == nil then return false end
	local before, corruptBefore = self.runner.totalSteps, self.runner.corrupt
	local arrays = self.runner:stepBar(inputs) -- yields; raises CORRUPT_STEP on any non-unit or disagreeing increment
	local applied = self.runner.totalSteps - before
	check(applied == STEPS_PER_BAR and self.runner.corrupt == corruptBefore,
		string.format("global bar %d applied %s verified steps (expected 12), corrupt %s", self.runner.totalBars, fmt(applied), fmt(self.runner.corrupt)))
	self.globalBars += 1
	for k, lane in lanes do
		local w = work[k]
		if w then
			local states = { coupled = lane.coupled:state(arrays[2 * k - 1]), independent = lane.independent:state(arrays[2 * k]),
				numeric = lane.numeric:step(w.feature.drive) }
			for _, variant in VARIANTS do
				local s = states[variant]
				check(type(s) == "table" and type(s.vector) == "table" and #s.vector == VECTOR_SIZE,
					"lane " .. k .. " row " .. w.i .. ": state " .. variant .. " must carry a 51-value vector")
			end
			for _, rig in { lane.coupled, lane.independent } do
				for _, n in rig.nodes do
					local delta = n.part.Position - n.rest
					local offAxis = math.max(math.abs(delta.Y), math.abs(delta.Z))
					lane.maxAbsX = math.max(lane.maxAbsX, math.abs(delta.X))
					lane.maxOffAxis = math.max(lane.maxOffAxis, offAxis)
					if math.abs(delta.X) >= lane.config.railLimit - 0.01 then lane.saturationObservations += 1 end
					if offAxis > 0.01 then lane.offAxisObservations += 1 end
				end
			end
			if w.decided then
				check(self.buffer[w.i] == nil and w.i > self.index, "row " .. w.i .. " stepped twice")
				self.buffer[w.i] = { feature = w.feature, states = states, lane = k, block = w.block }
				self.buffered += 1
				lane.decidedBars += 1
				lane.decidedSteps += applied
				self.decidedSteps += applied
			else
				lane.warmupBars += 1
				lane.warmupSteps += applied
			end
			lane.cursor += 1
			if lane.cursor > lane.block.lastIndex then self:_nextBlock(lane) else self:_setLabel(lane) end
		else
			lane.idleBars += 1
			lane.idleSteps += applied
		end
	end
	return true
end

function Capture:_controllerRunning(): boolean
	if self.isRunning then return self.isRunning() == true end
	local control = game:GetService("CoreGui"):FindFirstChild(LIVE_CONTROL)
	if not control then return false end
	local ok, status = pcall(function() return control:Invoke("status") end)
	if not ok or type(status) ~= "table" then return false end
	return status.running ~= false and status.stopRequested ~= true
end

function Capture:_produce()
	local ok, err = pcall(function()
		while self.halted == nil and self.haltRequested == nil do
			if self.fault then self.halted = "fault"; break end
			if not self:_controllerRunning() then self.halted = "controller not running"; break end
			local okGuard, allowed, why = pcall(self.guard)
			check(okGuard and allowed == true, "guard refused stepping (L14): " .. tostring(if okGuard then why else allowed))
			if self.fault then self.halted = "fault"; break end
			if self.halted or self.haltRequested then break end
			self.stepping = true
			local stepped, more = pcall(self._globalStep, self)
			self.stepping = false
			if not stepped then error(more, 0) end
			if not more then self.halted = "complete" end
		end
	end)
	if not ok then
		self.fault, self.halted = tostring(err), "fault"
	end
	self.stepping = false
	self.producing = false
end

-- Stop only at the shared runner's verified bar boundary. In-flight native work is allowed to finish, then joined
-- before the controller reads terminal isolation/stats. The lanes remain intact for L13 inspection.
function Capture:shutdown(reason: string?): boolean
	if self.destroyed then return true end
	self.haltRequested = self.haltRequested or reason or "shutdown"
	self.halted = self.halted or self.haltRequested
	while self.producing or self.stepping do task.wait() end
	self.shutdownComplete = true
	return true
end

------------------------------------------------------------------------------------------------------------------------
-- new(opts, config): opts as SpringLiveCapture.new ({prehistory, symbol, name, guard, nativeConfig2024});
-- config = {lanes = 8, runId (required), baseUrl = :47627, isRunning = fn?}.
function SpringLaneCapture.new(opts: any, config: any): any
	check(type(opts) == "table", "SpringLaneCapture.new: options table required")
	check(type(opts.guard) == "function", "SpringLaneCapture.new: opts.guard function required (L14)")
	check(type(opts.nativeConfig2024) == "table", "SpringLaneCapture.new: opts.nativeConfig2024 required")
	check(type(opts.prehistory) == "table" and type(opts.prehistory.targetDaily) == "table", "SpringLaneCapture.new: prehistory required")
	check(opts.symbol == nil or opts.symbol == "SPY", "SpringLaneCapture.new: SPY only (L1)")
	local okGuard, allowed, why = pcall(opts.guard)
	check(okGuard and allowed == true, "SpringLaneCapture.new: guard refused construction (L14): " .. tostring(if okGuard then why else allowed))
	check(not game:GetService("RunService"):IsRunning(), "SpringLaneCapture: Studio Edit mode required; never Play or Run")
	check(game.PlaceId == PLACE_ID, "SpringLaneCapture: the capture place is " .. PLACE_ID)
	check(active == nil, "SpringLaneCapture: another lane capture is alive")
	check(retainedProbe == nil, "SpringLaneCapture: a probe is retained; call releaseProbe() first")
	local Live = require(sibling("SpringLiveCapture"))
	check(Live.activeCount() == 0, "SpringLaneCapture: a single-lane SpringLiveCapture is alive")
	for _, n in { Live.DEFAULT_NAME, Live.REPLAY_NAME, SpringLaneCapture.CONTAINER_NAME } do
		check(workspace:FindFirstChild(n) == nil, "SpringLaneCapture: Workspace." .. n .. " already exists; remove it first")
	end
	local count = config.lanes or 8
	check(type(count) == "number" and count % 1 == 0 and count >= 1 and count <= 64, "SpringLaneCapture: lanes must be an integer 1..64")
	local runId = config.runId
	check(type(runId) == "string" and string.match(runId, "^[%w_-]+$") ~= nil, "SpringLaneCapture: config.runId required")
	local baseUrl = config.baseUrl or DEFAULT_BASE_URL
	local Http = game:GetService("HttpService")
	local started = os.clock()

	local receipts = moduleReceipts(Live)
	local studioAtStart = studioSettings()
	local entries = snapshotIsolation() -- before any lane part exists

	-- L15: the in-Studio features pass over every raw bar, in order, before any physics.
	local Features = require(sibling("SpringV2Features"))
	local FeaturesPass = require(sibling("SpringFeaturesPass"))
	local features = Features.new(opts.prehistory, { symbol = "SPY" })
	checkFeatures(features, opts.prehistory)
	local pass = FeaturesPass.new({ features = features, yieldEvery = 512 })
	local manifest = httpJson(Http, baseUrl .. "/spring-live/manifest")
	check(manifest.bars == EXPECT_BARS, "manifest bars " .. tostring(manifest.bars) .. " (expected 36402)")
	local times, sessions = table.create(EXPECT_BARS), {}
	local expected = 1
	for k = 1, manifest.pageCount do
		local page = httpJson(Http, baseUrl .. "/spring-live/page?index=" .. k)
		check(page.datasetId == manifest.datasetId and page.page == k and page.firstIndex == expected
			and page.lastIndex == expected + #page.bars - 1, "page " .. k .. " is not contiguous at " .. expected)
		for j, bar in page.bars do
			local i = expected + j - 1
			times[i] = bar.t
			local last = sessions[#sessions]
			if last == nil or last.day ~= bar.day then
				check(last == nil or (type(bar.day) == "string" and bar.day > last.day), "bar " .. i .. ": day order")
				table.insert(sessions, { day = bar.day, firstIndex = i, lastIndex = i })
			else
				last.lastIndex = i
			end
		end
		pass:pushPage(page.bars)
		expected += #page.bars
	end
	check(pass:count() == EXPECT_BARS and #sessions == EXPECT_SESSIONS,
		"features pass " .. pass:count() .. " bars over " .. #sessions .. " sessions (expected 36402 / 469)")
	local regime = features:info().regime
	check(type(regime) == "table" and regime.status == "fit", "the regime HMM must be fitted (status " .. tostring(regime and regime.status) .. ")")
	local digest = pass:digest()
	local featuresSeconds = os.clock() - started

	-- L18: the block schedule.
	local Schedule = require(sibling("SpringBlockSchedule"))
	local schedule = Schedule.build(sessions, { lanes = count })
	Schedule.verify(schedule, sessions)

	-- L16/L17: lanes and the one stepper.
	local built = buildLanes(count, opts.nativeConfig2024, Live)
	local self = setmetatable({
		Mechanics = require(sibling("SpringV2Mechanics")),
		guard = opts.guard, isRunning = config.isRunning, runId = runId, baseUrl = baseUrl,
		pass = pass, features = features, times = times, schedule = schedule, plan = built.plan,
		container = built.container, lanes = built.lanes, runner = built.runner, display = built.display,
		engine = built.lanes[1].engine, engineConfig = built.lanes[1].engine.config,
		driveNames = features:info().driveNames,
		buffer = {}, buffered = 0, index = 0, globalBars = 0, decidedSteps = 0,
		producing = false, stepping = false, halted = nil, fault = nil, destroyed = false, shutdownComplete = false,
		modules = receipts, studioAtStart = studioAtStart, digest = digest, featuresSeconds = featuresSeconds,
		isolation = { entries = entries, parts = #entries, checks = 0, lastMaxDelta = nil, maxDelta = 0, missing = 0, worst = nil },
	}, Capture)
	for k, lane in self.lanes do
		lane.queue = schedule.laneQueues[k]
		lane.slot, lane.blocksDone, lane.resets, lane.featureResets, lane.clippedInputs = 0, 0, 0, 0, 0
		lane.decidedBars, lane.warmupBars, lane.idleBars, lane.decidedSteps, lane.warmupSteps, lane.idleSteps = 0, 0, 0, 0, 0, 0
		lane.maxAbsX, lane.maxOffAxis, lane.saturationObservations, lane.offAxisObservations = 0, 0, 0, 0
		laneLabel(lane, self.container, self.display)
		self:_nextBlock(lane)
	end
	active = self
	local ok, err = pcall(function()
		self:verifyIsolation()
		-- Seal the lane plan before the first bar is stepped (write-once; a repeat gives 409).
		local blocks = {}
		for _, b in schedule.blocks do
			local first, last = blockDays(b)
			table.insert(blocks, { id = b.id, lane = b.lane, firstIndex = b.firstIndex, lastIndex = b.lastIndex,
				warmFirstIndex = b.warmFirstIndex, warmLastIndex = b.warmLastIndex, firstDay = first, lastDay = last })
		end
		local offsets = {}
		for k, lane in self.plan.lanes do offsets[k] = lane.offsetZ end
		local stats = schedule.stats
		self.seal = postChunk(Http, baseUrl, runId, "lanes", {
			schema = SpringLaneCapture.SCHEMA, runId = runId, lanes = count,
			statement = "Multi-lane native capture per spring-live-contract.md section 1b (L15-L21). Sealed before the first bar is stepped.",
			layout = { spacing = self.plan.spacing, gap = self.plan.gap, depth = self.plan.depth, offsetsZ = offsets,
				spacingSelection = "smallest-valid-quantized-spacing-v1", quantum = self.plan.quantum,
				excluded = deepCopy(self.plan.excluded), zoneClearance = self.plan.zoneClearance,
				maxAbsCoordinate = self.plan.maxAbsCoordinate, worstFloat32Ulp = self.plan.worstFloat32Ulp,
				builtMinLaneSeparation = built.built.minLaneSeparation, builtMaxLooseness = built.built.maxLooseness },
			schedule = { schema = schedule.schema, blockSessions = schedule.config.blockSessions, warmupSessions = schedule.config.warmupSessions,
				blocks = blocks, warmupBars = stats.warmupBars, steppedBars = stats.steppedBars, maxLaneBars = stats.maxLaneBars,
				overheadFraction = stats.overheadFraction },
			features = { digest = digest, offlineDigest = OFFLINE_DIGEST, digestMatchesOffline = digest == OFFLINE_DIGEST,
				bars = pass:count(), sessions = #sessions, seconds = featuresSeconds },
			stepper = { parts = #self.runner.parts, metronomes = #self.runner.metronomes, stepsPerBar = STEPS_PER_BAR,
				protocol = STEPPER_SCHEMA },
			display = if self.display then self.display:describe() else nil,
			modules = receipts,
		})
	end)
	if not ok then
		self:destroy()
		error("SpringLaneCapture.new: " .. tostring(err), 0)
	end
	return self
end

-- Exactly the SpringLiveCapture contract: the record of the next bar in time order. Waits (between frames) while the lane
-- that owns it has not stepped it yet. Any producer fault faults the capture for good (L4).
function Capture:step(bar: any): any
	if self.destroyed then error("SpringLaneCapture: the capture was destroyed", 2) end
	if self.fault then error("SpringLaneCapture: faulted (L4: abort; a re-run starts from row 1): " .. tostring(self.fault), 2) end
	local i = self.index + 1
	local okGuard, allowed, why = pcall(self.guard)
	if not okGuard or allowed ~= true then error("SpringLaneCapture: guard refused bar " .. i .. " (L14): " .. tostring(if okGuard then why else allowed), 2) end
	if type(bar) ~= "table" or bar.t ~= self.times[i] then
		error("SpringLaneCapture: bar " .. i .. " t " .. tostring(type(bar) == "table" and bar.t) .. " differs from the features pass t " .. tostring(self.times[i]), 2)
	end
	if not self.producing and self.halted == nil then
		self.producing = true
		task.spawn(self._produce, self)
	end
	while self.buffer[i] == nil do
		if self.fault then error("SpringLaneCapture: row " .. i .. ": " .. tostring(self.fault), 2) end
		if self.halted then error("SpringLaneCapture: the lanes halted (" .. tostring(self.halted) .. ") before row " .. i, 2) end
		task.wait()
	end
	-- Publishing a row and then faulting/losing exclusivity can happen before this consumer is resumed. Never decide
	-- that row after a failed producer merely because its buffer slot exists. A normally completed producer may drain.
	if self.destroyed then error("SpringLaneCapture: the capture was destroyed", 2) end
	if self.fault then error("SpringLaneCapture: row " .. i .. ": " .. tostring(self.fault), 2) end
	if self.haltRequested or (self.halted and self.halted ~= "complete") then
		error("SpringLaneCapture: the lanes halted (" .. tostring(self.haltRequested or self.halted) .. ") before consuming row " .. i, 2)
	end
	okGuard, allowed, why = pcall(self.guard)
	if not okGuard or allowed ~= true then error("SpringLaneCapture: guard refused bar " .. i .. " after wait (L14): " .. tostring(if okGuard then why else allowed), 2) end
	local record = self.buffer[i]
	self.buffer[i] = nil
	self.buffered -= 1
	self.index = i
	return { bar = bar, feature = record.feature, states = record.states, lane = record.lane, block = record.block }
end

function Capture:verifyIsolation(): (number, any)
	if self.destroyed then error("SpringLaneCapture: the capture was destroyed", 2) end
	local iso = self.isolation
	local maxDelta, worst, missing = measureIsolation(iso.entries)
	iso.checks += 1
	iso.lastMaxDelta, iso.missing, iso.worst = maxDelta, missing, worst
	if maxDelta > iso.maxDelta then iso.maxDelta = maxDelta end
	if not (maxDelta < ISOLATION_LIMIT) then
		self.fault = "isolation breach " .. fmt(maxDelta) .. " at " .. tostring(worst)
		error("SpringLaneCapture: isolation breach (L13): an unrelated unanchored part changed by " .. fmt(maxDelta) .. " (" .. tostring(worst) .. ")", 2)
	end
	return maxDelta, { parts = iso.parts, maxDelta = maxDelta, missing = missing, worst = worst, limit = ISOLATION_LIMIT }
end

-- totalSteps = verified StepPhysics steps applied to decided rows, summed per lane (12 x rows when every row got exactly
-- 12). globalSteps = StepPhysics steps issued over all lanes at once.
function Capture:stats(): any
	local r = self.runner:stats()
	local lanes = {}
	for k, lane in self.lanes do
		lanes[k] = { index = k, offsetZ = lane.offsetZ, blocks = #lane.queue, blocksDone = lane.blocksDone, currentBlock = lane.block and lane.block.id,
			decidedBars = lane.decidedBars, warmupBars = lane.warmupBars, idleBars = lane.idleBars, decidedSteps = lane.decidedSteps,
			warmupSteps = lane.warmupSteps, idleSteps = lane.idleSteps, resets = lane.resets, featureResets = lane.featureResets,
			clippedInputs = lane.clippedInputs, maxAbsX = lane.maxAbsX, maxOffAxis = lane.maxOffAxis,
			saturationObservations = lane.saturationObservations, offAxisObservations = lane.offAxisObservations }
	end
	local iso = self.isolation
	return {
		schema = SpringLaneCapture.SCHEMA,
		totalSteps = self.decidedSteps, globalSteps = r.totalSteps, globalBars = self.globalBars,
		runner = r, config = deepCopy(self.engineConfig),
		lanes = lanes, laneCount = #self.lanes, spacing = self.plan.spacing,
		capture = { runId = self.runId, rowsDelivered = self.index, buffered = self.buffered, producing = self.producing,
			stepping = self.stepping, haltRequested = self.haltRequested, shutdownComplete = self.shutdownComplete,
			halted = self.halted, fault = self.fault, destroyed = self.destroyed, seal = self.seal, modules = deepCopy(self.modules),
			featuresDigest = self.digest, featuresDigestMatchesOffline = self.digest == OFFLINE_DIGEST, featuresSeconds = self.featuresSeconds },
		isolation = { parts = iso.parts, checks = iso.checks, lastMaxDelta = iso.lastMaxDelta, maxDelta = iso.maxDelta,
			missing = iso.missing, worst = iso.worst, limit = ISOLATION_LIMIT },
		studio = studioSettings(), studioAtStart = deepCopy(self.studioAtStart),
		display = if self.display then self.display:describe() else nil,
	}
end

-- L13 keeps the lanes after a run for inspection: the controller does not call this then.
function Capture:destroy()
	if self.destroyed then return end
	check(not self.producing and not self.stepping, "SpringLaneCapture: cannot destroy while producing or stepping; shutdown first")
	if self.display then self.display:destroy() end -- remove owned attachments before their native parts
	self.halted = self.halted or "destroyed"
	self.destroyed = true
	pcall(function() self.runner:destroy() end)
	for _, lane in self.lanes do pcall(function() lane.engine:destroy() end) end
	pcall(function() self.container:Destroy() end)
	if active == self then active = nil end
end

-- Explicit terminal cleanup, never automatic at run completion. Keep the controller handle until this succeeds.
function Capture:release(): boolean
	if self.destroyed then return false end
	check(not self.producing and not self.stepping, "SpringLaneCapture: cannot release while producing or stepping")
	check(not self:_controllerRunning(), "SpringLaneCapture: cannot release while the controller is running")
	check(self.halted ~= nil, "SpringLaneCapture: shutdown is required before release")
	self:destroy()
	return true
end

-- The table injected as deps.modules.SpringLiveCapture.
function SpringLaneCapture.module(config: any): any
	config = config or {}
	local Live = require(sibling("SpringLiveCapture"))
	return {
		SCHEMA = SpringLaneCapture.SCHEMA,
		replayCheck = function(...)
			check(active == nil and retainedProbe == nil, "SpringLaneCapture: release the existing capture or probe before replayCheck")
			return Live.replayCheck(...)
		end,
		activeCount = function() return if active or retainedProbe then 1 else 0 end,
		new = function(opts) return SpringLaneCapture.new(opts, config) end,
	}
end

-- Explicit cleanup of a completed inspection probe. A running probe owns its runner until its current bar returns.
function SpringLaneCapture.releaseProbe(): boolean
	if retainedProbe == nil then return false end
	check(not retainedProbe.busy, "SpringLaneCapture.releaseProbe: the probe is still running or stepping")
	local built = retainedProbe.built
	if built then
		if built.display then built.display:destroy() end -- preserve sources until visual cleanup has checked them
		local problems = {}
		local function remove(fn)
			local ok, err = pcall(fn)
			if not ok then table.insert(problems, tostring(err)) end
		end
		remove(function() built.runner:destroy() end)
		for _, lane in built.lanes do remove(function() lane.engine:destroy() end) end
		remove(function() built.container:Destroy() end)
		check(#problems == 0, "SpringLaneCapture.releaseProbe: " .. table.concat(problems, "; "))
	end
	retainedProbe = nil
	return true
end

-- Frame-rate probe (L16). opts.guard is the caller's L14 controller/stepper guard. The default removes every probe
-- resource; keep=true retains labeled lanes for L21's screen capture. Call releaseProbe() before starting the run.
function SpringLaneCapture.probe(opts: any): any
	check(type(opts) == "table", "SpringLaneCapture.probe: options required")
	check(type(opts.guard) == "function", "SpringLaneCapture.probe: opts.guard function required (L14)")
	check(type(opts.nativeConfig2024) == "table", "SpringLaneCapture.probe: nativeConfig2024 required")
	check(type(opts.lanes) == "number" and opts.lanes % 1 == 0 and opts.lanes >= 1 and opts.lanes <= 64,
		"SpringLaneCapture.probe: lanes must be an integer 1..64")
	check(type(opts.bars) == "number" and opts.bars % 1 == 0 and opts.bars >= 1, "SpringLaneCapture.probe: bars must be a positive integer")
	check(not game:GetService("RunService"):IsRunning() and game.PlaceId == PLACE_ID, "SpringLaneCapture.probe: RoAlgo Edit mode only")
	check(active == nil, "SpringLaneCapture.probe: a lane capture is alive")
	check(retainedProbe == nil, "SpringLaneCapture.probe: a probe is retained; call releaseProbe() first")
	local Live = require(sibling("SpringLiveCapture"))
	local function guard()
		local ok, allowed, why = pcall(opts.guard)
		check(ok and allowed == true, "SpringLaneCapture.probe: guard refused (L14): " .. tostring(if ok then why else allowed))
		check(active == nil and Live.activeCount() == 0, "SpringLaneCapture.probe: another capture is alive")
	end
	guard()
	for _, name in { Live.DEFAULT_NAME, Live.REPLAY_NAME, SpringLaneCapture.CONTAINER_NAME } do
		check(workspace:FindFirstChild(name) == nil, "SpringLaneCapture.probe: Workspace." .. name .. " already exists; release it first")
	end
	local receipts = moduleReceipts(Live)
	local studioAtStart = studioSettings()
	local entries = snapshotIsolation()
	local probe = { busy = true }
	retainedProbe = probe
	local ok, result = pcall(function()
		local built = buildLanes(opts.lanes, opts.nativeConfig2024, Live)
		probe.built = built
		for _, lane in built.lanes do
			laneLabel(lane, built.container, built.display)
			lane.label.Text = string.format("LANE %d · INSPECTION PROBE · ZERO DRIVE", lane.index)
		end
		local inputs = table.create(2 * opts.lanes, ZERO8)
		guard()
		built.runner:stepBar(inputs) -- includes the 20-frame construction warm-up
		local t0, s0, f0 = os.clock(), built.runner.totalSteps, built.runner.framesWaited
		for _ = 1, opts.bars do
			guard()
			built.runner:stepBar(inputs)
		end
		guard()
		local seconds = os.clock() - t0
		local maxDelta, worst, missing = measureIsolation(entries)
		check(maxDelta < ISOLATION_LIMIT, "SpringLaneCapture.probe: isolation breach (L13): " .. fmt(maxDelta) .. " at " .. tostring(worst))
		return { lanes = opts.lanes, bars = opts.bars, seconds = seconds, barsPerSecondPerLane = opts.bars / seconds,
			steps = built.runner.totalSteps - s0, framesWaited = built.runner.framesWaited - f0, parts = #built.runner.parts,
			dropped = built.runner.dropped, corrupt = built.runner.corrupt, spacing = built.plan.spacing,
			minLaneSeparation = built.built.minLaneSeparation, isolationMaxDelta = maxDelta, isolationMissing = missing,
			kept = opts.keep == true, containerName = SpringLaneCapture.CONTAINER_NAME, layout = deepCopy(built.plan),
			display = if built.display then built.display:describe() else nil,
			modules = receipts, studioAtStart = studioAtStart, studio = studioSettings() }
	end)
	probe.busy = false
	if not ok or opts.keep ~= true then
		local removed, removeErr = pcall(SpringLaneCapture.releaseProbe)
		if not removed then error("SpringLaneCapture.probe cleanup: " .. tostring(removeErr), 0) end
	end
	if not ok then error("SpringLaneCapture.probe: " .. tostring(result), 0) end
	return result
end

return SpringLaneCapture
