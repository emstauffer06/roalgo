-- SpringLiveCapture: the capture-time v2 rig for the live forward test.
-- Contract: spring-live-contract.md W2 (decisions L1, L3, L4, L13, L14). ENGINE CODE: Studio Edit mode, plugin context.
--
-- Orchestration only. It builds SpringV2Engine (the 2024 capture Engine from RoAlgoV2_SPY_1791205420530_source.json,
-- one require line changed) at the 2024 capture origin and steps exactly one bar per call, exactly like the 2024 App loop:
--     feature = features:step(bar); states = engine:step(feature.drive, feature.reset)
-- It fails closed on anything that would make the live rig differ from the 2024 calibration rig: module Source hashes,
-- rig identity, part list, masses, runner options, geometry, and a deep-equal of engine.config against the 2024
-- native.config (passed in as opts.nativeConfig2024, so this module holds no data).
-- It never calls StepPhysics itself (only VerifiedStepper does, with the rig's 50-part list), never touches
-- Workspace.RoAlgoResearchPhysics, never runs Play and never moves the camera.
-- Roblox objects and the two capture modules are injectable through opts.env, so tests/SpringLiveCapture.spec.luau can
-- exercise the orchestration in luau.exe with doubles. Native physics itself can only be verified in Studio.
local SpringLiveCapture = {}

local PLACE_ID = 0
local MECHANICS_SCHEMA = "roalgo-mechanics-v2-1"
local STEPPER_SCHEMA = "verified-stepper-v2-2"
local NODE_COUNT, EDGE_COUNT, PART_COUNT = 24, 37, 50
local EXPECTED_MASS = 3.375 -- 2024 measured AssemblyMass of every node (1.5-stud cube, density 1)
local STEPS_PER_BAR = 12
local ISOLATION_LIMIT = 1e-6
local DEFAULT_TOLERANCE = 0.002
local ORIGIN = { 0, 1024, 1024 } -- capture-time Engine.luau:100 default, the 2024 capture origin
local CAPTURE_FOCUS = { 0, 1280, 1920 } -- origin + (0, spacing, 3.5*spacing), Engine.luau:108 FocusPosition attribute
local VARIANTS = { "coupled", "independent", "numeric" }
local VECTOR_SIZE = 51

SpringLiveCapture.SCHEMA = "roalgo-spring-live-capture-1"
SpringLiveCapture.PLACE_ID = PLACE_ID
SpringLiveCapture.DEFAULT_NAME = "RoAlgoSpringLiveRig"
SpringLiveCapture.REPLAY_NAME = "RoAlgoSpringLivePreflight"
SpringLiveCapture.FORBIDDEN_NAME = "RoAlgoResearchPhysics"
SpringLiveCapture.CAPTURE_ORIGIN_XYZ = table.freeze(table.clone(ORIGIN))
SpringLiveCapture.CAPTURE_ORIGIN = if Vector3 ~= nil then Vector3.new(ORIGIN[1], ORIGIN[2], ORIGIN[3]) else nil
SpringLiveCapture.ISOLATION_LIMIT = ISOLATION_LIMIT
SpringLiveCapture.DEFAULT_TOLERANCE = DEFAULT_TOLERANCE
SpringLiveCapture.EXPECTED_MASS = EXPECTED_MASS
SpringLiveCapture.RUNNER_OPTIONS = table.freeze({
	dt = 1 / 60, stepsPerBar = 12, settleSteps = 0, lossFrames = 3, postBarQuietFrames = 2, warmupFrames = 20, maxReissues = 30,
})
-- Identity of every module the live rig executes. SHA-256 of the exact ModuleScript Source (LF, as on disk).
-- SpringV2Mechanics/SpringV2Features are verbatim copies of indicator-v2/src; Regime and VerifiedStepper are the v3 files,
-- byte-identical to the capture; SpringV2Engine is the capture Engine with line 5 changed (see CAPTURE_SOURCE).
SpringLiveCapture.MODULE_ORDER = table.freeze({ "SpringV2Mechanics", "VerifiedStepper", "SpringV2Engine", "Regime", "SpringV2Features" })
SpringLiveCapture.MODULE_PINS = table.freeze({
	SpringV2Mechanics = "d4680345e89cf738b5b9d0ca00bf88750b1b01b697cae9747ff6156d1c2b3e28",
	VerifiedStepper = "1ee4c13cac93f1dafea47c0f5d8a595558a0a03d14decb357fef36eb14a31fa4",
	SpringV2Engine = "fcf8784e92f758746f761aaa941fc5959c88e298f98f4c437c42a095349d0d47",
	Regime = "5b8ac36eac95fb2e9f7c100c89202bbe9267f24ff0787fafbdf8bbe35bdb0d4f",
	SpringV2Features = "c1ac95b23491d9fb76cc574e72a556d9c2ad621d934fa90ee798256c8e066c76",
})
SpringLiveCapture.CAPTURE_SOURCE = table.freeze({
	sourceJson = "indicator-v2/results/RoAlgoV2_SPY_1791205420530_source.json",
	sourceJsonSha256 = "ecbee1e2e639acd7e9b51d0b81a0d9541e24cc1ec23fdc4e033a2860a16dee58",
	engineSha256 = "5dbebef9c245bf26a0e327b630612c3a43a3b214d747f90e25fa32be2a91f486",
	engineChangedLine = 5,
	engineChange = "line 5 requires script.Parent.SpringV2Mechanics instead of script.Parent.Mechanics",
	studioVersion = "0.741.19.7411056",
	placeId = PLACE_ID,
})

-- Live capture engines built by this module and not yet destroyed (never two engines at the capture origin).
local registry: { [any]: string } = {}

local Capture = {}
Capture.__index = Capture

local function finite(x: any): boolean
	return type(x) == "number" and x == x and math.abs(x) < math.huge
end
local function fmt(x: any): string
	if type(x) == "number" then return string.format("%.17g", x) end
	return tostring(x)
end
local function check(condition: any, message: string)
	if not condition then error(message, 0) end
end
local function near(a: any, b: number): boolean
	return type(a) == "number" and math.abs(a - b) <= 1e-6
end

------------------------------------------------------------------------------------------------------------------------
-- SHA-256 (FIPS 180-4) over a Lua string, so Studio can measure the ModuleScript Source it is about to execute.
local K256 = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local function sha256(message: string): string
	assert(type(message) == "string", "SpringLiveCapture.sha256: string required")
	local band, bxor, bnot, rrotate, rshift = bit32.band, bit32.bxor, bit32.bnot, bit32.rrotate, bit32.rshift
	local M = 4294967296
	local length = #message
	-- message length in bits as a 64-bit big-endian integer: length*8 = high*2^32 + low
	local high, low = math.floor(length / 0x20000000), (length % 0x20000000) * 8
	local padded = message .. "\128" .. string.rep("\0", (55 - length) % 64) .. string.pack(">I4I4", high, low)
	local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
	local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
	local w = table.create(64, 0)
	for block = 1, #padded, 64 do
		for j = 1, 16 do
			w[j] = (string.unpack(">I4", padded, block + (j - 1) * 4))
		end
		for j = 17, 64 do
			local w15, w2 = w[j - 15], w[j - 2]
			local s0 = bxor(rrotate(w15, 7), rrotate(w15, 18), rshift(w15, 3))
			local s1 = bxor(rrotate(w2, 17), rrotate(w2, 19), rshift(w2, 10))
			w[j] = (w[j - 16] + s0 + w[j - 7] + s1) % M
		end
		local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
		for j = 1, 64 do
			local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
			local ch = bxor(band(e, f), band(bnot(e), g))
			local t1 = (h + S1 + ch + K256[j] + w[j]) % M
			local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
			local maj = bxor(band(a, b), band(a, c), band(b, c))
			local t2 = (S0 + maj) % M
			h, g, f, e, d, c, b, a = g, f, e, (d + t1) % M, c, b, a, (t1 + t2) % M
		end
		h0, h1, h2, h3 = (h0 + a) % M, (h1 + b) % M, (h2 + c) % M, (h3 + d) % M
		h4, h5, h6, h7 = (h4 + e) % M, (h5 + f) % M, (h6 + g) % M, (h7 + h) % M
	end
	return string.format(string.rep("%08x", 8), h0, h1, h2, h3, h4, h5, h6, h7)
end
SpringLiveCapture.sha256 = sha256

-- Exact structural equality: same key sets both ways, numbers compared with == (a 1-ulp difference is a difference,
-- NaN never equals). Returns true, or false and the path of the first difference.
local function keyPath(path: string, k: any): string
	if type(k) == "string" then return path .. "." .. k end
	return path .. "[" .. tostring(k) .. "]"
end
local function deepEqual(a: any, b: any, path: string?): (boolean, string?)
	local here = path or "value"
	if type(a) ~= type(b) then
		return false, here .. " (type " .. type(a) .. " vs " .. type(b) .. ")"
	end
	if type(a) ~= "table" then
		if a == b then return true, nil end
		return false, here .. " (" .. fmt(a) .. " vs " .. fmt(b) .. ")"
	end
	if a == b then return true, nil end
	for k, v in next, a do
		local same, where = deepEqual(v, b[k], keyPath(here, k))
		if not same then return false, where end
	end
	for k in next, b do
		if a[k] == nil then return false, keyPath(here, k) .. " (missing on the left)" end
	end
	return true, nil
end
SpringLiveCapture.deepEqual = deepEqual

local function deepCopy(x: any): any
	if type(x) ~= "table" then return x end
	local out = {}
	for k, v in next, x do out[k] = deepCopy(v) end
	return out
end

------------------------------------------------------------------------------------------------------------------------
-- Environment. Default: the real Studio globals and the sibling ModuleScripts. Tests inject every key.
local function studioModuleHash(name: string): (string, any)
	local folder = script.Parent
	local module = folder:FindFirstChild(name)
	if module == nil or not module:IsA("ModuleScript") then
		error("ModuleScript " .. name .. " is missing beside SpringLiveCapture", 0)
	end
	local ok, source = pcall(function() return module.Source end)
	if not ok or type(source) ~= "string" then
		error("cannot read the Source of " .. name .. " (plugin or Command Bar context required): " .. tostring(source), 0)
	end
	local stamp = module:FindFirstChild("SourceSHA256")
	return sha256(source), { attribute = module:GetAttribute("sha256"), sourceSHA256 = if stamp then stamp.Value else nil }
end

local INJECTED_KEYS = { "game", "workspace", "Vector3", "Engine", "Features", "moduleHash" }
local function resolveEnv(env: any): any
	if env ~= nil then
		if type(env) ~= "table" then error("SpringLiveCapture: opts.env must be a table", 3) end
		for _, key in INJECTED_KEYS do
			if env[key] == nil then error("SpringLiveCapture: injected opts.env lacks " .. key, 3) end
		end
		return {
			injected = true, game = env.game, workspace = env.workspace, Vector3 = env.Vector3,
			loadEngine = function() return env.Engine end,
			loadFeatures = function() return env.Features end,
			moduleHash = env.moduleHash, version = env.version, settings = env.settings,
		}
	end
	if script == nil or game == nil or workspace == nil or Vector3 == nil then
		error("SpringLiveCapture: Roblox Studio is required (CLI tests inject opts.env)", 3)
	end
	return {
		injected = false, game = game, workspace = workspace, Vector3 = Vector3,
		-- Required only after verifyModules has measured every Source against MODULE_PINS.
		loadEngine = function() return require(script.Parent.SpringV2Engine) end,
		loadFeatures = function() return require(script.Parent.SpringV2Features) end,
		moduleHash = studioModuleHash, version = version, settings = settings,
	}
end

local function studioSettings(env: any): any
	local ws = env.workspace
	local out: any = {}
	local function try(key: string, read: () -> any)
		local ok, value = pcall(read)
		if ok and value ~= nil then
			out[key] = if type(value) == "number" or type(value) == "boolean" or type(value) == "string" then value else tostring(value)
		end
	end
	try("placeId", function() return env.game.PlaceId end)
	try("studioVersion", function() return env.version() end)
	try("gravity", function() return ws.Gravity end)
	try("physicsSteppingMethod", function() return ws.PhysicsSteppingMethod end)
	try("fluidForces", function() return ws.FluidForces end)
	try("airDensity", function() return ws.AirDensity end)
	try("allowSleep", function() return env.settings().Physics.AllowSleep end)
	try("physicsEnvironmentalThrottle", function() return env.settings().Physics.PhysicsEnvironmentalThrottle end)
	return out
end

local function checkGuard(guard: any, phase: string)
	local ok, allowed, why = pcall(guard)
	if not ok then error("SpringLiveCapture: guard raised during " .. phase .. ": " .. tostring(allowed), 0) end
	if allowed ~= true then
		error("SpringLiveCapture: guard refused " .. phase .. " (L14): " .. tostring(why or "another controller or stepper is active"), 0)
	end
end

local function verifyModules(env: any): any
	local receipts, problems = {}, {}
	for _, name in SpringLiveCapture.MODULE_ORDER do
		local pin = SpringLiveCapture.MODULE_PINS[name]
		local ok, measured, stamps = pcall(env.moduleHash, name)
		if not ok then
			table.insert(problems, name .. ": " .. tostring(measured))
		elseif measured ~= pin then
			table.insert(problems, name .. ": Source sha256 " .. tostring(measured) .. " differs from pinned " .. pin)
		else
			local receipt = { sha256 = measured, pin = pin }
			if type(stamps) == "table" then
				for kind, value in next, stamps do
					if value ~= pin then
						table.insert(problems, name .. ": installed " .. tostring(kind) .. " stamp " .. tostring(value) .. " differs from pinned " .. pin)
					end
					receipt[kind] = value
				end
			end
			receipts[name] = receipt
		end
	end
	if #problems > 0 then
		error("SpringLiveCapture: refusing to build the live rig; module identity differs: " .. table.concat(problems, "; "), 0)
	end
	return receipts
end

-- Refuses while any other capture-origin engine exists: one built here and not destroyed, a model with one of the
-- reserved names, or any engine model whose FocusPosition marks the capture origin (e.g. a rig kept from a run).
local function refuseOtherEngines(env: any, name: string)
	local alive = {}
	for _, n in registry do table.insert(alive, n) end
	if #alive > 0 then
		error("SpringLiveCapture: another capture engine is alive (" .. table.concat(alive, ", ")
			.. "); destroy it first (never two engines at the capture origin)", 0)
	end
	local ws = env.workspace
	for _, n in { name, SpringLiveCapture.DEFAULT_NAME, SpringLiveCapture.REPLAY_NAME } do
		if ws:FindFirstChild(n) ~= nil then
			error("SpringLiveCapture: Workspace." .. n .. " already exists; remove it first (never two engines at the capture origin)", 0)
		end
	end
	for _, child in ws:GetChildren() do
		if child:GetAttribute("MechanicsSchema") ~= nil then
			local focus = child:GetAttribute("FocusPosition")
			if focus ~= nil and near(focus.X, CAPTURE_FOCUS[1]) and near(focus.Y, CAPTURE_FOCUS[2]) and near(focus.Z, CAPTURE_FOCUS[3]) then
				error("SpringLiveCapture: engine model Workspace." .. tostring(child.Name) .. " already sits at the capture origin", 0)
			end
		end
	end
end

local function preflight(opts: any, env: any, name: any): any
	if type(opts.guard) ~= "function" then error("SpringLiveCapture: opts.guard function required (L14)", 0) end
	checkGuard(opts.guard, "construction")
	if env.game:GetService("RunService"):IsRunning() then
		error("SpringLiveCapture: Studio Edit mode required; never Play or Run", 0)
	end
	if env.game.PlaceId ~= PLACE_ID then
		error("SpringLiveCapture: the capture place is " .. PLACE_ID .. ", not " .. tostring(env.game.PlaceId), 0)
	end
	if type(name) ~= "string" or not string.match(name, "^[%w_]+$") then error("SpringLiveCapture: invalid model name", 0) end
	if name == SpringLiveCapture.FORBIDDEN_NAME then
		error("SpringLiveCapture: the live rig is never Workspace." .. SpringLiveCapture.FORBIDDEN_NAME .. " (L13)", 0)
	end
	if type(opts.nativeConfig2024) ~= "table" then
		error("SpringLiveCapture: opts.nativeConfig2024 (the 2024 manifest native.config) is required", 0)
	end
	refuseOtherEngines(env, name)
	return verifyModules(env)
end

------------------------------------------------------------------------------------------------------------------------
-- Isolation: every unanchored BasePart in Workspace that is not part of the rig must not move (L13).
local function readMotion(part: any): { number }
	local p, l, a = part.Position, part.AssemblyLinearVelocity, part.AssemblyAngularVelocity
	return { p.X, p.Y, p.Z, l.X, l.Y, l.Z, a.X, a.Y, a.Z }
end
local function snapshotIsolation(ws: any): { any }
	local entries = {}
	for _, inst in ws:GetDescendants() do
		if inst:IsA("BasePart") and inst.Anchored == false then
			table.insert(entries, { part = inst, values = readMotion(inst) })
		end
	end
	return entries
end
local function measureIsolation(entries: { any }): (number, any, number)
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
				if d > maxDelta then maxDelta, worst = d, part end
			end
		end
	end
	return maxDelta, worst, missing
end
local function fullName(part: any): string?
	if part == nil then return nil end
	local ok, name = pcall(function() return part:GetFullName() end)
	return if ok then name else tostring(part)
end

------------------------------------------------------------------------------------------------------------------------
-- Rig identity (contract W2: identities, part count, masses, runner options, config deep-equal).
local function checkEngine(engine: any, env: any, name: string, reference: any)
	check(type(engine) == "table", "Engine.new returned no engine")
	local c = engine.config
	check(type(c) == "table" and c.schema == MECHANICS_SCHEMA, "mechanics schema must be " .. MECHANICS_SCHEMA)
	local protocol = c.nativeProtocol
	check(type(protocol) == "table" and protocol.schema == STEPPER_SCHEMA and protocol.lossFrames == 3
		and protocol.postBarQuietFrames == 2, "native protocol must be " .. STEPPER_SCHEMA .. " with 3 loss and 2 quiet frames")
	local same, where = deepEqual(c, reference, "engine.config")
	check(same, "engine.config differs from the 2024 native.config at " .. tostring(where))
	local model = engine.model
	check(model ~= nil and model.Name == name and model.Parent == env.workspace, "the rig model must be Workspace." .. name)
	check(model:GetAttribute("MechanicsSchema") == MECHANICS_SCHEMA, "rig model MechanicsSchema attribute")
	check(engine.destroyed == false and engine.busy == false and engine.fault == nil and engine.failedBars == 0
		and engine.clippedInputs == 0, "the engine must be fresh (not destroyed, busy or faulted)")
	check(#c.nodes == NODE_COUNT and #c.edges == EDGE_COUNT, "config must have 24 nodes and 37 edges")
	local coupled, independent = engine.coupledRig, engine.independentRig
	check(type(coupled) == "table" and type(independent) == "table" and coupled.coupled == true and independent.coupled == false,
		"one coupled and one independent rig required")
	check(#coupled.nodes == NODE_COUNT and #independent.nodes == NODE_COUNT and #coupled.parts == NODE_COUNT
		and #independent.parts == NODE_COUNT, "each rig must have 24 nodes")
	check(#coupled.couplings == EDGE_COUNT and #independent.couplings == 0,
		"37 coupling springs on the coupled rig and none on the independent rig")
	local independentOffset = 11 * c.spacing -- capture Engine.luau:115
	for i, n in c.nodes do
		for r, rig in { coupled, independent } do
			local node = rig.nodes[i]
			local dz = if r == 1 then 0 else independentOffset
			local rest, part = node.rest, node.part
			check(near(rest.X, ORIGIN[1]) and near(rest.Y, ORIGIN[2] + n.y) and near(rest.Z, ORIGIN[3] + dz + n.z),
				"node " .. i .. " rest must be the capture origin (0,1024,1024) + (0, y, z" .. (if r == 2 then " + 2816" else "") .. ")")
			check(part == rig.parts[i] and part.Anchored == false and part:IsDescendantOf(model), "node " .. i .. " part identity")
			local position = part.Position
			check(near(position.X, rest.X) and near(position.Y, rest.Y) and near(position.Z, rest.Z), "node " .. i .. " must start at rest")
			check(part.AssemblyMass == EXPECTED_MASS and n.mass == EXPECTED_MASS,
				"node " .. i .. " AssemblyMass " .. fmt(part.AssemblyMass) .. " must equal the 2024 mass 3.375")
		end
	end
	local runner = engine.runner
	local o = runner.options
	check(o.dt == 1 / 60 and o.stepsPerBar == STEPS_PER_BAR and o.settleSteps == 0 and o.lossFrames == 3
		and o.postBarQuietFrames == 2 and o.parent == model, "runner options must equal the 2024 capture (1/60, 12, 0, 3, 2)")
	check(o.stepper == nil and o.waitFrame == nil and o.metronome == nil and o.warmupFrames == nil and o.maxReissues == nil,
		"the runner must use the default StepPhysics stepper, Heartbeat wait, metronomes and default bounds")
	check(runner.lossFrames == 3 and runner.postBarQuietFrames == 2 and runner.warmupFrames == 20 and runner.maxReissues == 30,
		"runner bounds must be lossFrames 3, quiet frames 2, warm-up 20, re-issues 30")
	check(#runner.reservoirs == 2 and runner.reservoirs[1] == coupled and runner.reservoirs[2] == independent,
		"runner reservoirs must be {coupled, independent}")
	check(#runner.metronomes == 2 and runner.metronomes[1].Name == "MetronomeA" and runner.metronomes[2].Name == "MetronomeB",
		"two metronomes required")
	check(#runner.parts == PART_COUNT, "the StepPhysics part list must hold exactly 50 parts, got " .. #runner.parts)
	local seen = {}
	for i, p in runner.parts do
		local expected = if i <= NODE_COUNT then coupled.parts[i]
			elseif i <= 2 * NODE_COUNT then independent.parts[i - NODE_COUNT]
			else runner.metronomes[i - 2 * NODE_COUNT]
		check(p == expected and not seen[p], "stepped part " .. i .. " must be the expected rig part, once")
		check(p.Anchored == false and p:IsDescendantOf(model), "stepped part " .. i .. " must be an unanchored part inside the rig model")
		seen[p] = true
	end
	check(runner.totalSteps == 0 and runner.totalBars == 0 and runner.corrupt == 0 and runner.settleCount == 1,
		"a fresh runner has 0 steps, 0 bars, 0 corrupt steps and one constructor settle")
	local numeric = engine.numeric
	check(type(numeric) == "table" and numeric.config == c and numeric.coupled == true and numeric.totalSteps == 0
		and numeric.totalBars == 0, "the numeric comparator must be fresh, coupled and share the engine config")
end

local function buildEngine(env: any, name: string, reference: any): any
	local Engine = env.loadEngine()
	local origin = env.Vector3.new(ORIGIN[1], ORIGIN[2], ORIGIN[3])
	local engine = Engine.new(env.workspace, { name = name, origin = origin })
	local ok, err = pcall(checkEngine, engine, env, name, reference)
	if not ok then
		local destroyed = pcall(function() engine:destroy() end)
		error("SpringLiveCapture: rig identity check failed (rig destroyed: " .. tostring(destroyed) .. "): " .. tostring(err), 0)
	end
	return engine
end

-- The capture-time Features cold start (indicator-v2/src/Features.luau:17), exactly as the 2024 App created it.
local function checkFeatures(features: any, prehistory: any, symbol: string)
	check(type(features) == "table", "Features.new returned nothing")
	check(features.prehistory == prehistory, "Features must hold the supplied prehistory")
	check(features.observations == 0 and features.previous == nil and features.regimeModel == nil
		and features.volumeMean == nil and features.tradeMean == nil, "Features must be a cold start")
	check(features.trend == 0 and features.var == 1e-8 and features.alpha == 0.05, "Features scalars must be trend 0, var 1e-8, alpha 0.05")
	check(type(features.driveScales) == "table" and #features.driveScales == 7, "Features must have 7 drive scales")
	for _, s in features.driveScales do check(s == 1e-6, "every drive scale must start at 1e-6") end
	local options = features.options
	local count = 0
	if type(options) == "table" then for _ in next, options do count += 1 end end
	check(type(options) == "table" and options.symbol == symbol and count == 1, "Features options must be exactly {symbol=" .. symbol .. "}")
end

------------------------------------------------------------------------------------------------------------------------
-- SpringLiveCapture.new({prehistory, symbol="SPY", name="RoAlgoSpringLiveRig", guard=fn, nativeConfig2024, env?,
--   requireRegimeFit=true}) --> cap
function SpringLiveCapture.new(opts: any): any
	if type(opts) ~= "table" then error("SpringLiveCapture.new: options table required", 2) end
	local env = resolveEnv(opts.env)
	local symbol = if opts.symbol == nil then "SPY" else opts.symbol
	if symbol ~= "SPY" then error("SpringLiveCapture.new: the live forward test is SPY only (L1)", 2) end
	local prehistory = opts.prehistory
	if type(prehistory) ~= "table" or type(prehistory.targetDaily) ~= "table" then
		error("SpringLiveCapture.new: prehistory with targetDaily required", 2)
	end
	local name = if opts.name == nil then SpringLiveCapture.DEFAULT_NAME else opts.name
	local ok, receipts = pcall(preflight, opts, env, name)
	if not ok then error("SpringLiveCapture.new: " .. tostring(receipts), 2) end
	local studioAtStart = studioSettings(env)
	local entries = snapshotIsolation(env.workspace) -- before any rig part exists
	local Features = env.loadFeatures()
	local features = Features.new(prehistory, { symbol = symbol }) -- 2024 App: Features.new(data.prehistory,{symbol=...})
	local featuresOk, featuresErr = pcall(checkFeatures, features, prehistory, symbol)
	if not featuresOk then error("SpringLiveCapture.new: Features cold start differs: " .. tostring(featuresErr), 2) end
	local engine = buildEngine(env, name, opts.nativeConfig2024)
	local self = setmetatable({
		engine = engine, features = features, name = name, guard = opts.guard, env = env,
		requireRegimeFit = opts.requireRegimeFit ~= false,
		index = 0, resets = 0, resetIndices = {}, firstT = nil, lastT = nil,
		busy = false, fault = nil, destroyed = false,
		modules = receipts, studioAtStart = studioAtStart,
		isolation = { entries = entries, parts = #entries, checks = 0, lastMaxDelta = nil, maxDelta = 0, missing = 0, worst = nil },
	}, Capture)
	registry[self] = name
	local isolated, isolationErr = pcall(function() return self:verifyIsolation() end)
	if not isolated then
		pcall(function() engine:destroy() end)
		registry[self] = nil
		self.destroyed = true
		error("SpringLiveCapture.new: " .. tostring(isolationErr), 2)
	end
	return self
end

-- Exactly one bar, exactly like the 2024 App loop. Yields while the rig steps (about 19 frames at 60 Hz).
-- A guard refusal raises before anything changes. Any later error faults the capture for good (L4: abort, no
-- in-place recovery, a re-run starts from row 1).
function Capture:step(bar: any): any
	if self.destroyed then error("SpringLiveCapture: the capture was destroyed", 2) end
	if self.fault ~= nil then
		error("SpringLiveCapture: the capture is faulted (L4: abort; a re-run starts from row 1): " .. tostring(self.fault), 2)
	end
	if self.busy then error("SpringLiveCapture: a step is already in progress (exactly one bar at a time)", 2) end
	local nextIndex = self.index + 1
	local guarded, guardErr = pcall(checkGuard, self.guard, "bar " .. nextIndex)
	if not guarded then error(guardErr, 2) end
	self.busy = true
	local ok, result = pcall(function()
		if type(bar) ~= "table" then error("bar table required", 0) end
		local feature = self.features:step(bar)
		local states = self.engine:step(feature.drive, feature.reset)
		return { bar = bar, feature = feature, states = states }
	end)
	self.busy = false
	if ok then
		ok, result = pcall(function()
			local runner, numeric = self.engine.runner, self.engine.numeric
			check(runner.totalSteps == STEPS_PER_BAR * nextIndex and runner.totalBars == nextIndex and runner.corrupt == 0
				and numeric.totalBars == nextIndex, string.format("native counters after bar %d: totalSteps %s (expected %d), totalBars %s, corrupt %s, numeric bars %s",
				nextIndex, fmt(runner.totalSteps), STEPS_PER_BAR * nextIndex, fmt(runner.totalBars), fmt(runner.corrupt), fmt(numeric.totalBars)))
			for _, variant in VARIANTS do
				local state = result.states[variant]
				check(type(state) == "table" and type(state.vector) == "table" and #state.vector == VECTOR_SIZE,
					"state " .. variant .. " must carry a 51-value vector")
			end
			if nextIndex == 1 and self.requireRegimeFit then
				local regime = self.features:info().regime
				check(regime.status == "fit", "the regime HMM must be fitted on the prehistory at bar 1 (status " .. tostring(regime.status) .. ")")
			end
			return result
		end)
	end
	if not ok then
		self.fault = tostring(result)
		error("SpringLiveCapture: bar " .. nextIndex .. " failed; capture faulted (L4): " .. tostring(result), 2)
	end
	self.index = nextIndex
	if result.feature.reset then
		self.resets += 1
		if #self.resetIndices < 100 then table.insert(self.resetIndices, nextIndex) end
	end
	if self.firstT == nil then self.firstT = bar.t end
	self.lastT = bar.t
	return result
end

-- Max absolute change of Position, AssemblyLinearVelocity and AssemblyAngularVelocity over every unanchored part that
-- existed outside the rig at construction. Raises (and faults the capture) when it is not below 1e-6.
function Capture:verifyIsolation(): (number, any)
	if self.destroyed then error("SpringLiveCapture: the capture was destroyed", 2) end
	local iso = self.isolation
	local maxDelta, worst, missing = measureIsolation(iso.entries)
	iso.checks += 1
	iso.lastMaxDelta, iso.missing, iso.worst = maxDelta, missing, fullName(worst)
	if maxDelta > iso.maxDelta then iso.maxDelta = maxDelta end
	local report = { parts = iso.parts, maxDelta = maxDelta, missing = missing, worst = iso.worst, limit = ISOLATION_LIMIT }
	if not (maxDelta < ISOLATION_LIMIT) then
		self.fault = "isolation breach " .. fmt(maxDelta) .. " at " .. tostring(iso.worst)
		error("SpringLiveCapture: isolation breach (L13): an unrelated unanchored part changed by " .. fmt(maxDelta)
			.. " (" .. tostring(iso.worst) .. ")", 2)
	end
	return maxDelta, report
end

-- engine:stats() (2024 keys, config deep-copied) + capture, isolation and Studio/physics settings.
function Capture:stats(): any
	local s = self.engine:stats()
	s.config = deepCopy(s.config)
	local regime = nil
	local okRegime, info = pcall(function() return self.features:info().regime end)
	if okRegime and type(info) == "table" then
		regime = { status = info.status, trainCount = info.trainCount, iterations = info.iterations, filterSteps = info.filterSteps }
	end
	s.capture = {
		schema = SpringLiveCapture.SCHEMA, name = self.name, origin = table.clone(ORIGIN), bars = self.index,
		expectedSteps = STEPS_PER_BAR * self.index, resets = self.resets, resetIndices = table.clone(self.resetIndices),
		firstT = self.firstT, lastT = self.lastT, fault = self.fault, destroyed = self.destroyed,
		injectedEnvironment = self.env.injected, requireRegimeFit = self.requireRegimeFit,
		modules = deepCopy(self.modules), captureSource = deepCopy(SpringLiveCapture.CAPTURE_SOURCE), regime = regime,
	}
	local iso = self.isolation
	s.isolation = { parts = iso.parts, checks = iso.checks, lastMaxDelta = iso.lastMaxDelta, maxDelta = iso.maxDelta,
		missing = iso.missing, worst = iso.worst, limit = ISOLATION_LIMIT }
	s.studio = studioSettings(self.env)
	s.studioAtStart = deepCopy(self.studioAtStart)
	return s
end

-- Destroys the rig. L13 keeps the rig after a run for inspection: the controller simply does not call this then.
function Capture:destroy()
	if self.destroyed then return end
	if self.busy then error("SpringLiveCapture: cannot destroy during a step", 2) end
	self.engine:destroy()
	self.destroyed = true
	registry[self] = nil
end

function SpringLiveCapture.activeCount(): number
	local n = 0
	for _ in registry do n += 1 end
	return n
end

------------------------------------------------------------------------------------------------------------------------
-- Pre-flight (L3a): re-step saved rows natively on a temporary rig and compare with the saved vectors.
-- rows[i] = {index?, t?, drive={8} | hex, reset=boolean, coupled={51} | hex, independent={51} | hex, numeric={51} | hex}
-- (hex = little-endian doubles, string.pack("<d")). opts = {guard, nativeConfig2024, tolerance=0.002, name?, env?}.
local function decodeVector(value: any, n: number, label: string): { number }
	local out = table.create(n, 0)
	if type(value) == "string" then
		check(#value == 16 * n and string.match(value, "^%x+$") ~= nil, label .. ": hex of " .. n .. " little-endian doubles required")
		local bytes = (string.gsub(value, "%x%x", function(h) return string.char(tonumber(h, 16) :: number) end))
		for i = 1, n do out[i] = (string.unpack("<d", bytes, (i - 1) * 8 + 1)) end
	else
		check(type(value) == "table" and #value == n, label .. ": " .. n .. " numbers required")
		for i = 1, n do out[i] = value[i] end
	end
	for i = 1, n do check(finite(out[i]), label .. "[" .. i .. "] must be finite") end
	return out
end

function SpringLiveCapture.replayCheck(rows: any, opts: any): any
	if type(rows) ~= "table" or #rows < 1 then error("SpringLiveCapture.replayCheck: at least one saved row required", 2) end
	if type(opts) ~= "table" then error("SpringLiveCapture.replayCheck: opts with guard and nativeConfig2024 required", 2) end
	local tolerance = if opts.tolerance == nil then DEFAULT_TOLERANCE else opts.tolerance
	if not finite(tolerance) or tolerance < 0 then error("SpringLiveCapture.replayCheck: finite tolerance >= 0 required", 2) end
	local decoded = table.create(#rows)
	local okRows, rowsErr = pcall(function()
		for i = 1, #rows do
			local row = rows[i]
			local label = "row " .. i
			check(type(row) == "table" and type(row.reset) == "boolean", label .. ": reset boolean required")
			if row.index ~= nil then
				check(rows[1].index ~= nil and row.index == rows[1].index + i - 1, label .. ": indices must be consecutive")
			end
			local d = { index = if row.index ~= nil then row.index else i, reset = row.reset, drive = decodeVector(row.drive, 8, label .. " drive") }
			for _, variant in VARIANTS do d[variant] = decodeVector(row[variant], VECTOR_SIZE, label .. " " .. variant) end
			decoded[i] = d
		end
		check(decoded[1].reset == true, "the replay must start at a segment reset (2024 record 1 has reset=true)")
	end)
	if not okRows then error("SpringLiveCapture.replayCheck: " .. tostring(rowsErr), 2) end
	local env = resolveEnv(opts.env)
	local name = if opts.name == nil then SpringLiveCapture.REPLAY_NAME else opts.name
	local okPre, receipts = pcall(preflight, opts, env, name)
	if not okPre then error("SpringLiveCapture.replayCheck: " .. tostring(receipts), 2) end
	local entries = snapshotIsolation(env.workspace)
	local engine = buildEngine(env, name, opts.nativeConfig2024)
	local token = {}
	registry[token] = name
	local ok, result = pcall(function()
		local maxAbs = { coupled = 0, independent = 0, numeric = 0 }
		local worst = {}
		for i, row in decoded do
			checkGuard(opts.guard, "replay row " .. i)
			local states = engine:step(row.drive, row.reset)
			for _, variant in VARIANTS do
				local vector = type(states) == "table" and type(states[variant]) == "table" and states[variant].vector
				check(type(vector) == "table" and #vector == VECTOR_SIZE, "replayed " .. variant .. " must carry a 51-value vector")
				local saved = row[variant]
				for k = 1, VECTOR_SIZE do
					local diff = math.abs(vector[k] - saved[k])
					if diff ~= diff then diff = math.huge end
					if diff > maxAbs[variant] then
						maxAbs[variant] = diff
						worst[variant] = { index = row.index, component = k, saved = saved[k], replayed = vector[k] }
					end
				end
			end
		end
		local runner = engine.runner
		check(runner.totalSteps == STEPS_PER_BAR * #decoded and runner.totalBars == #decoded and runner.corrupt == 0,
			"native counters after the replay must be 12 steps per row and 0 corrupt")
		local isoDelta, isoWorst, isoMissing = measureIsolation(entries)
		local native = engine:stats()
		native.config = nil
		local numericExact = maxAbs.numeric == 0
		local nativeWithin = maxAbs.coupled <= tolerance and maxAbs.independent <= tolerance
		local isolated = isoDelta < ISOLATION_LIMIT
		local pass = numericExact and nativeWithin and isolated
		return {
			schema = "roalgo-spring-live-replay-check-1", count = #decoded, firstIndex = decoded[1].index,
			lastIndex = decoded[#decoded].index, maxAbs = maxAbs, worst = worst, tolerance = tolerance,
			numericExact = numericExact, nativeWithinTolerance = nativeWithin, pass = pass,
			verdict = if pass then "re-captured physics matches the 2024 calibration capture within tolerance"
				else "re-captured physics differs from the 2024 calibration capture",
			isolation = { parts = #entries, maxDelta = isoDelta, missing = isoMissing, worst = fullName(isoWorst), limit = ISOLATION_LIMIT },
			native = native, modules = receipts, injectedEnvironment = env.injected,
		}
	end)
	local destroyed, destroyErr = pcall(function() engine:destroy() end)
	if destroyed then registry[token] = nil end
	if not ok then
		error("SpringLiveCapture.replayCheck failed (temporary rig destroyed: " .. tostring(destroyed) .. "): " .. tostring(result), 2)
	end
	if not destroyed then error("SpringLiveCapture.replayCheck: could not destroy the temporary rig: " .. tostring(destroyErr), 2) end
	result.destroyed = true
	return result
end

return SpringLiveCapture
