-- SpringLiveCapture spec (contract D17 style). Self-running: luau.exe tests/SpringLiveCapture.spec.luau
-- Orchestration only: Roblox objects, the capture Engine and the module-hash reader are doubles injected through
-- opts.env. Features is the REAL SpringV2Features (pure Luau) and the rig config is built from the REAL
-- SpringV2Mechanics.config() exactly as the capture Engine post-processes it. Native physics, StepPhysics scoping,
-- Source hashing of installed ModuleScripts and Studio settings are NOT exercised here; they need Studio.
local loaded, SpringLiveCapture = pcall(require, "../src/SpringLiveCapture")
assert(loaded and type(SpringLiveCapture) == "table", "SpringLiveCapture must load without Roblox globals: " .. tostring(SpringLiveCapture))
local loadedMechanics, Mechanics = pcall(require, "../src/SpringV2Mechanics")
assert(loadedMechanics and type(Mechanics) == "table", "SpringV2Mechanics must load: " .. tostring(Mechanics))
local loadedFeatures, RealFeatures = pcall(require, "../src/SpringV2Features")
assert(loadedFeatures and type(RealFeatures) == "table", "SpringV2Features must load: " .. tostring(RealFeatures))

local passed = 0
local function test(name, fn)
	fn()
	assert(SpringLiveCapture.activeCount() == 0, name .. ": a capture engine leaked (registry not empty)")
	passed += 1
	print("PASS " .. name)
end
local function rejects(fn, fragment)
	local ok, err = pcall(fn)
	assert(not ok, "expected a rejection containing '" .. fragment .. "'")
	assert(string.find(tostring(err), fragment, 1, true), "wrong rejection: " .. tostring(err) .. " (expected '" .. fragment .. "')")
	return tostring(err)
end
local PINS = SpringLiveCapture.MODULE_PINS

------------------------------------------------------------------------------------------------------------------------
-- Doubles
local function makeWorld()
	local W = { created = 0, state = { running = false } }
	local Inst = {}
	Inst.__index = Inst
	function W.new(className, name, parent)
		local self = setmetatable({ ClassName = className, Name = name, _children = {}, _attrs = {} }, Inst)
		if parent then self:_setParent(parent) end
		W.created += 1
		return self
	end
	function Inst:_setParent(parent)
		local old = rawget(self, "Parent")
		if old then
			local list = old._children
			for i = #list, 1, -1 do if list[i] == self then table.remove(list, i) end end
		end
		self.Parent = parent
		if parent then table.insert(parent._children, self) end
	end
	function Inst:IsA(className)
		if className == "BasePart" then return self.ClassName == "Part" or self.ClassName == "Terrain" end
		return self.ClassName == className
	end
	function Inst:GetChildren() return table.clone(self._children) end
	function Inst:GetDescendants()
		local out = {}
		local function walk(x) for _, c in x._children do table.insert(out, c); walk(c) end end
		walk(self)
		return out
	end
	function Inst:FindFirstChild(name) for _, c in self._children do if c.Name == name then return c end end return nil end
	function Inst:IsDescendantOf(ancestor)
		local p = self.Parent
		while p do if p == ancestor then return true end p = p.Parent end
		return false
	end
	function Inst:GetAttribute(k) return self._attrs[k] end
	function Inst:SetAttribute(k, v) self._attrs[k] = v end
	function Inst:GetFullName()
		local names, p = {}, self
		while p do table.insert(names, 1, p.Name); p = p.Parent end
		return table.concat(names, ".")
	end
	function Inst:Destroy()
		for _, c in table.clone(self._children) do c:Destroy() end
		self:_setParent(nil)
		self._destroyed = true
	end
	local V3mt = {}
	local function V3(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, V3mt) end
	V3mt.__add = function(a, b) return V3(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
	W.V3 = V3
	W.Vector3 = { new = V3 }
	W.zero = V3(0, 0, 0)
	function W.part(name, position, anchored, parent)
		local p = W.new("Part", name, parent)
		p.Anchored = anchored; p.Position = position; p.AssemblyMass = 3.375
		p.AssemblyLinearVelocity = W.zero; p.AssemblyAngularVelocity = W.zero
		return p
	end
	W.workspace = W.new("Workspace", "Workspace")
	W.workspace.Gravity = 196.2
	W.workspace.PhysicsSteppingMethod = "Enum.PhysicsSteppingMethod.Fixed"
	local runService = { IsRunning = function() return W.state.running end }
	W.game = { PlaceId = 0, GetService = function(_, name) assert(name == "RunService"); return runService end }
	return W
end

-- The 2024 rig config: SpringV2Mechanics.config() plus the capture Engine.new post-processing with AssemblyMass 3.375.
local function engineConfig()
	local c = Mechanics.config()
	c.nativeProtocol = { schema = "verified-stepper-v2-2", lossFrames = 3, postBarQuietFrames = 2,
		recovery = "reject corrupted capture; explicit reset and replay required" }
	local actual = 3.375
	for _, n in c.nodes do n.mass = actual; n.k = actual * n.omega ^ 2; n.c = 2 * n.zeta * actual * n.omega end
	c.massSource = "coupled native Part.AssemblyMass, checked identical to independent rig"
	for _, e in c.edges do
		e.k = c.couplingStiffnessRatio * math.sqrt(c.nodes[e.a].k * c.nodes[e.b].k)
		e.c = c.couplingDampingRatio * math.sqrt(c.nodes[e.a].c * c.nodes[e.b].c)
	end
	return c
end

local function fakeVector(drive, bar, scale, size)
	local n = size or 51
	local v = table.create(n, 0)
	for k = 1, n do v[k] = scale * (drive[(k - 1) % 8 + 1] + bar / 1000) / k end
	return v
end

-- Engine double with the field layout of the capture Engine (SpringV2Engine) and VerifiedStepper.
local function makeEngine(W, knobs)
	knobs = knobs or {}
	local E = { news = {}, steps = {}, destroys = 0, log = knobs.log }
	local EngineMT = {}
	EngineMT.__index = EngineMT
	function E.new(parent, options)
		table.insert(E.news, { parent = parent, options = options })
		if E.log then table.insert(E.log, "Engine.new") end
		local origin = knobs.origin or options.origin
		local c = engineConfig()
		local model = W.new("Model", options.name or "RoAlgoResearchPhysics", parent)
		model:SetAttribute("MechanicsSchema", c.schema)
		model:SetAttribute("FocusPosition", origin + W.V3(0, c.spacing, 3.5 * c.spacing))
		local function rig(offset, coupled)
			local rm = W.new("Model", if coupled then "Coupled" else "Independent", model)
			local r = { model = rm, config = c, nodes = {}, parts = {}, couplings = {}, coupled = coupled }
			for i, n in c.nodes do
				local rest = origin + offset + W.V3(0, n.y, n.z)
				local p = W.part(n.name, rest, false, rm)
				r.nodes[i] = { part = p, rest = rest }
				r.parts[i] = p
			end
			if coupled then for i = 1, #c.edges do r.couplings[i] = W.new("SpringConstraint", "Couple" .. i, rm) end end
			return r
		end
		local coupled = rig(W.V3(0, 0, 0), true)
		local independent = rig(W.V3(0, 0, 11 * c.spacing), false)
		local metronomes = { W.part("MetronomeA", W.V3(-400, 5000, -500), false, model), W.part("MetronomeB", W.V3(400, 5000, -500), false, model) }
		local parts = {}
		for _, p in coupled.parts do table.insert(parts, p) end
		for _, p in independent.parts do table.insert(parts, p) end
		for _, m in metronomes do table.insert(parts, m) end
		local runner = {
			options = { dt = 1 / 60, stepsPerBar = 12, settleSteps = 0, parent = model, lossFrames = 3, postBarQuietFrames = 2 },
			reservoirs = { coupled, independent }, parts = parts, metronomes = metronomes, lossFrames = 3, postBarQuietFrames = 2,
			maxReissues = 30, warmupFrames = 20, totalSteps = 0, totalBars = 0, corrupt = 0, settleCount = 1,
		}
		local engine = setmetatable({
			model = model, config = c, coupledRig = coupled, independentRig = independent, runner = runner,
			numeric = { config = c, coupled = true, totalSteps = 0, totalBars = 0 },
			destroyed = false, busy = false, fault = nil, failedBars = 0, clippedInputs = 0,
		}, EngineMT)
		if knobs.mutate then knobs.mutate(engine, W) end
		E.last = engine
		return engine
	end
	function EngineMT:step(drive, reset)
		assert(not self.destroyed and not self.busy, "Engine: step unavailable")
		table.insert(E.steps, { drive = drive, reset = reset })
		if E.log then table.insert(E.log, "engine:step") end
		self.busy = true
		if knobs.onStep then
			local ok, err = pcall(knobs.onStep, self, drive, reset, #E.steps)
			if not ok then
				self.busy = false; self.failedBars += 1; self.fault = tostring(err)
				error(err, 0)
			end
		end
		self.busy = false
		local r = self.runner
		r.totalSteps += knobs.stepsPerBar or 12
		r.totalBars += 1
		self.numeric.totalSteps += 12
		self.numeric.totalBars += 1
		local bar = r.totalBars
		return {
			coupled = { vector = fakeVector(drive, bar, 1) },
			independent = { vector = fakeVector(drive, bar, 2) },
			numeric = { vector = fakeVector(drive, bar, 3, knobs.vectorSize) },
		}
	end
	function EngineMT:stats()
		return { totalSteps = self.runner.totalSteps, totalBars = self.runner.totalBars, corruptSteps = self.runner.corrupt,
			parts = #self.runner.parts, schema = self.config.schema, config = self.config }
	end
	function EngineMT:destroy()
		if self.destroyed then return end
		assert(not self.busy, "Engine: active step must finish before destruction")
		self.destroyed = true
		E.destroys += 1
		self.model:Destroy()
	end
	return E
end

-- Spy around the REAL SpringV2Features.
local function makeFeatures(knobs)
	knobs = knobs or {}
	local F = { news = {}, steps = 0, log = knobs.log }
	function F.new(prehistory, options)
		table.insert(F.news, { prehistory = prehistory, options = options })
		if F.log then table.insert(F.log, "Features.new") end
		local f = RealFeatures.new(prehistory, options)
		local realStep = f.step
		f.step = function(self, bar)
			F.steps += 1
			if F.log then table.insert(F.log, "features:step") end
			local feature = realStep(self, bar)
			F.lastFeature = feature
			return feature
		end
		if knobs.mutate then knobs.mutate(f) end
		return f
	end
	return F
end

local function makeEnv(W, E, F, hashes)
	hashes = hashes or {}
	return {
		game = W.game, workspace = W.workspace, Vector3 = W.Vector3, Engine = E, Features = F,
		moduleHash = function(name)
			local h = hashes[name]
			if h == false then error("ModuleScript " .. name .. " is missing beside SpringLiveCapture", 0) end
			local stamps = hashes.stamps and hashes.stamps[name]
			return h or PINS[name], stamps
		end,
		version = function() return "0.741.test" end,
		settings = function() return { Physics = { AllowSleep = true, PhysicsEnvironmentalThrottle = "DefaultAuto" } } end,
	}
end

local START_T = 1735828200 -- 2025-01-02 09:30 ET
local function prehistory(count)
	local rows = {}
	for i = 1, count do
		local c = 100 + 3 * math.sin(i * 1.7) + i / 10
		rows[i] = { t = START_T - (count + 1 - i) * 86400, day = string.format("2024-%03d", i), availableT = START_T - (count + 1 - i) * 86400 + 23400,
			o = c - 0.5, c = c, h = c + 1 + (i % 3), l = c - 1 - (i % 5) / 2 }
	end
	return { targetDaily = rows }
end
local function bar(i)
	local c = 590 + math.sin(i) + i / 50
	return { t = START_T + (i - 1) * 300, day = "2025-01-02", minute = 570 + (i - 1) * 5, o = c - 0.2, h = c + 0.4, l = c - 0.5,
		c = c, v = 100000 + 37 * i, n = 900 + i, vwap = c - 0.05, availableT = START_T + i * 300, label = "bar " .. i, contexts = {} }
end

local function setup(knobs)
	knobs = knobs or {}
	local W = makeWorld()
	local E = makeEngine(W, knobs.engine)
	local F = makeFeatures(knobs.features)
	local env = makeEnv(W, E, F, knobs.hashes)
	local guardState = { allowed = true, calls = 0, why = "RoAlgoMarketControl busy" }
	local function guard()
		guardState.calls += 1
		if knobs.log then table.insert(knobs.log, "guard") end
		if guardState.allowed then return true end
		return false, guardState.why
	end
	local opts = { prehistory = prehistory(60), symbol = "SPY", guard = guard, nativeConfig2024 = engineConfig(), env = env }
	return { W = W, E = E, F = F, env = env, guard = guardState, opts = opts }
end

------------------------------------------------------------------------------------------------------------------------
test("module loads without Roblox globals and publishes the capture identity", function()
	local o = SpringLiveCapture.CAPTURE_ORIGIN_XYZ
	assert(o[1] == 0 and o[2] == 1024 and o[3] == 1024 and #o == 3 and table.isfrozen(o), "capture origin (0,1024,1024)")
	assert(SpringLiveCapture.CAPTURE_ORIGIN == nil, "no Vector3 outside Studio")
	assert(SpringLiveCapture.DEFAULT_NAME == "RoAlgoSpringLiveRig" and SpringLiveCapture.FORBIDDEN_NAME == "RoAlgoResearchPhysics", "names")
	assert(SpringLiveCapture.DEFAULT_TOLERANCE == 0.002 and SpringLiveCapture.ISOLATION_LIMIT == 1e-6, "L3 tolerance and L13 limit")
	local count = 0
	for _, name in SpringLiveCapture.MODULE_ORDER do
		count += 1
		assert(type(PINS[name]) == "string" and #PINS[name] == 64 and string.match(PINS[name], "^[0-9a-f]+$"), "pin " .. name)
	end
	assert(count == 5 and table.isfrozen(PINS), "five pinned modules")
	assert(PINS.SpringV2Engine ~= SpringLiveCapture.CAPTURE_SOURCE.engineSha256, "the edited Engine copy cannot carry the capture hash")
	local r = SpringLiveCapture.RUNNER_OPTIONS
	assert(r.dt == 1 / 60 and r.stepsPerBar == 12 and r.settleSteps == 0 and r.lossFrames == 3 and r.postBarQuietFrames == 2, "runner")
end)

test("sha256 matches FIPS 180-4 vectors and every padding boundary", function()
	local h = SpringLiveCapture.sha256
	assert(h("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "empty")
	assert(h("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "abc")
	assert(h("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "448 bits")
	assert(h("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")
		== "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1", "896 bits")
	local expected = {
		[55] = "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
		[56] = "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
		[63] = "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
		[64] = "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
		[65] = "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
		[119] = "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb",
		[1000] = "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3",
	}
	for n, hex in expected do assert(h(string.rep("a", n)) == hex, "length " .. n) end
	local bytes = {}
	for i = 0, 255 do bytes[i + 1] = string.char(i) end
	assert(h(table.concat(bytes)) == "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880", "all byte values")
end)

test("deepEqual is exact: 1 ulp, missing or extra keys, types and NaN all differ", function()
	local eq = SpringLiveCapture.deepEqual
	local a, b = engineConfig(), engineConfig()
	assert(eq(a, b), "two builds of the 2024 config are equal")
	b.edges[17].k = b.edges[17].k * (1 + 2 ^ -52)
	local same, where = eq(a, b, "config")
	assert(not same and where and string.find(where, "config.edges[17].k", 1, true), "1-ulp edge stiffness: " .. tostring(where))
	b = engineConfig(); b.extra = 1
	same, where = eq(a, b); assert(not same and string.find(where, "extra", 1, true), "extra key")
	b = engineConfig(); b.nodes[24] = nil
	same, where = eq(a, b); assert(not same and string.find(where, "nodes[24]", 1, true), "missing node")
	b = engineConfig(); b.D = "64"
	assert(not eq(a, b), "number vs string")
	b = engineConfig(); table.insert(b.bankNames, "Extra")
	assert(not eq(a, b), "array length")
	assert(not eq({ x = 0 / 0 }, { x = 0 / 0 }), "NaN never equals")
	assert(eq(table.freeze({ 1, { 2 } }), { 1, { 2 } }), "frozen tables compare by value")
end)

test("new builds the capture rig once at (0,1024,1024) after a cold SpringV2Features with exactly {symbol}", function()
	local log = {}
	local s = setup({ log = log, engine = { log = log }, features = { log = log } })
	local cap = SpringLiveCapture.new(s.opts)
	assert(#s.E.news == 1 and s.E.news[1].parent == s.W.workspace, "Engine.new(workspace, ...) once")
	local options = s.E.news[1].options
	local keys = 0
	for _ in options do keys += 1 end
	assert(keys == 2 and options.name == "RoAlgoSpringLiveRig", "options are {name, origin} only")
	assert(options.origin.X == 0 and options.origin.Y == 1024 and options.origin.Z == 1024, "capture origin")
	assert(#s.F.news == 1 and s.F.news[1].prehistory == s.opts.prehistory, "Features.new gets the prehistory table")
	local fo = s.F.news[1].options
	keys = 0
	for _ in fo do keys += 1 end
	assert(keys == 1 and fo.symbol == "SPY", "Features options exactly {symbol='SPY'} as the 2024 App")
	assert(log[1] == "guard" and log[2] == "Features.new" and log[3] == "Engine.new", "guard, then Features, then Engine: " .. table.concat(log, ","))
	assert(s.W.workspace:FindFirstChild("RoAlgoSpringLiveRig") == cap.engine.model, "rig is Workspace.RoAlgoSpringLiveRig")
	assert(SpringLiveCapture.activeCount() == 1, "registered")
	local st = cap:stats()
	assert(st.capture.bars == 0 and st.capture.injectedEnvironment == true and st.isolation.checks == 1, "fresh stats")
	cap:destroy()
end)

test("new refuses before building anything: guard, mode, place, names, symbol, inputs, other engines", function()
	local cases = {
		{ "guard refused", function(s) s.guard.allowed = false end, "guard refused construction" },
		{ "guard raised", function(s) s.opts.guard = function() error("probe exploded") end end, "probe exploded" },
		{ "no guard", function(s) s.opts.guard = nil end, "opts.guard function required" },
		{ "Play mode", function(s) s.W.state.running = true end, "Edit mode required" },
		{ "wrong place", function(s) s.W.game.PlaceId = 1 end, "capture place" },
		{ "presentation name", function(s) s.opts.name = "RoAlgoResearchPhysics" end, "never Workspace.RoAlgoResearchPhysics" },
		{ "name taken", function(s) s.W.new("Model", "RoAlgoSpringLiveRig", s.W.workspace) end, "already exists" },
		{ "kept live rig under a custom name", function(s)
			s.opts.name = "RoAlgoSpringLiveRig2"; s.W.new("Model", "RoAlgoSpringLiveRig", s.W.workspace)
		end, "Workspace.RoAlgoSpringLiveRig already exists" },
		{ "leftover preflight rig", function(s) s.W.new("Model", "RoAlgoSpringLivePreflight", s.W.workspace) end, "RoAlgoSpringLivePreflight already exists" },
		{ "renamed engine at the capture origin", function(s)
			local m = s.W.new("Model", "OldRig", s.W.workspace)
			m:SetAttribute("MechanicsSchema", "roalgo-mechanics-v2-1"); m:SetAttribute("FocusPosition", s.W.V3(0, 1280, 1920))
		end, "already sits at the capture origin" },
		{ "QQQ", function(s) s.opts.symbol = "QQQ" end, "SPY only" },
		{ "no prehistory", function(s) s.opts.prehistory = nil end, "prehistory" },
		{ "no 2024 config", function(s) s.opts.nativeConfig2024 = nil end, "nativeConfig2024" },
		{ "Engine copy edited", function(s) s.env.moduleHash = makeEnv(s.W, s.E, s.F, { SpringV2Engine = string.rep("0", 64) }).moduleHash end, "SpringV2Engine: Source sha256" },
		{ "Mechanics copy edited", function(s) s.env.moduleHash = makeEnv(s.W, s.E, s.F, { SpringV2Mechanics = string.rep("1", 64) }).moduleHash end, "SpringV2Mechanics: Source sha256" },
		{ "Features copy edited", function(s) s.env.moduleHash = makeEnv(s.W, s.E, s.F, { SpringV2Features = string.rep("2", 64) }).moduleHash end, "SpringV2Features: Source sha256" },
		{ "Regime edited", function(s) s.env.moduleHash = makeEnv(s.W, s.E, s.F, { Regime = string.rep("3", 64) }).moduleHash end, "Regime: Source sha256" },
		{ "VerifiedStepper edited", function(s) s.env.moduleHash = makeEnv(s.W, s.E, s.F, { VerifiedStepper = string.rep("4", 64) }).moduleHash end, "VerifiedStepper: Source sha256" },
		{ "module missing", function(s) s.env.moduleHash = makeEnv(s.W, s.E, s.F, { SpringV2Engine = false }).moduleHash end, "is missing" },
		{ "install stamp disagrees", function(s)
			s.env.moduleHash = makeEnv(s.W, s.E, s.F, { stamps = { Regime = { attribute = string.rep("5", 64) } } }).moduleHash
		end, "installed attribute stamp" },
	}
	for _, case in cases do
		local s = setup()
		case[2](s)
		local before = #s.W.workspace:GetChildren()
		local err = rejects(function() SpringLiveCapture.new(s.opts) end, case[3])
		assert(#s.E.news == 0 and #s.F.news == 0, case[1] .. ": nothing may be built (" .. err .. ")")
		assert(#s.W.workspace:GetChildren() == before, case[1] .. ": workspace unchanged")
	end
	-- a live capture blocks a second one
	local s = setup()
	local cap = SpringLiveCapture.new(s.opts)
	local s2 = setup()
	rejects(function() SpringLiveCapture.new(s2.opts) end, "another capture engine is alive")
	assert(#s2.E.news == 0, "second rig not built")
	cap:destroy()
	-- outside Studio without an injected env
	local plain = setup().opts
	plain.env = nil
	rejects(function() SpringLiveCapture.new(plain) end, "Roblox Studio is required")
	rejects(function() SpringLiveCapture.new({ env = { game = 1 }, guard = function() return true end, prehistory = prehistory(1), nativeConfig2024 = {} }) end, "lacks")
end)

test("rig identity defects are refused and the rig is destroyed", function()
	local function mutateNode(fn) return function(engine) fn(engine) end end
	local cases = {
		{ "one node mass 3.376", mutateNode(function(e) e.independentRig.nodes[7].part.AssemblyMass = 3.376 end), "AssemblyMass" },
		{ "config mass measured differently", function(e) local n = e.config.nodes[3]; n.mass = 3.37; n.k = 3.37 * n.omega ^ 2 end, "engine.config differs" },
		{ "edge stiffness 1 ulp off", function(e) e.config.edges[5].k *= 1 + 2 ^ -52 end, "engine.config.edges[5].k" },
		{ "extra config key", function(e) e.config.layout = "showcase" end, "engine.config.layout" },
		{ "wrong mechanics schema", function(e) e.config.schema = "roalgo-mechanics-v3-1" end, "mechanics schema" },
		{ "metronome missing from the part list", function(e) table.remove(e.runner.parts) end, "exactly 50 parts" },
		{ "unrelated part in the part list", function(e, W) e.runner.parts[50] = W.part("Sentinel", W.zero, false, W.workspace) end, "stepped part 50" },
		{ "stepped part outside the model", function(e, W) e.runner.metronomes[2]:_setParent(W.workspace) end, "inside the rig model" },
		{ "loss frames 2", function(e) e.runner.options.lossFrames = 2 end, "runner options" },
		{ "settle steps 1", function(e) e.runner.options.settleSteps = 1 end, "runner options" },
		{ "injected stepper", function(e) e.runner.options.stepper = function() end end, "default StepPhysics stepper" },
		{ "no warm-up", function(e) e.runner.warmupFrames = 0 end, "warm-up 20" },
		{ "independent rig coupled", function(e, W) e.independentRig.couplings[1] = W.new("SpringConstraint", "X", e.model) end, "none on the independent rig" },
		{ "spawn-relative origin", nil, "rest must be the capture origin" },
		{ "independent rig not offset", function(e, W)
			for i, node in e.independentRig.nodes do node.rest = e.coupledRig.nodes[i].rest; node.part.Position = node.rest end
		end, "+ 2816" },
		{ "node not at rest", function(e, W) e.coupledRig.nodes[2].part.Position = e.coupledRig.nodes[2].rest + W.V3(1, 0, 0) end, "start at rest" },
		{ "node anchored", function(e) e.coupledRig.nodes[9].part.Anchored = true end, "part identity" },
		{ "numeric comparator with its own config", function(e) e.numeric.config = engineConfig() end, "numeric comparator" },
		{ "runner already stepped", function(e) e.runner.totalSteps = 12 end, "fresh runner" },
		{ "faulted engine", function(e) e.fault = "x" end, "fresh" },
		{ "model renamed", function(e) e.model.Name = "Other" end, "Workspace.RoAlgoSpringLiveRig" },
	}
	for _, case in cases do
		local knobs = { mutate = case[2] }
		if case[1] == "spawn-relative origin" then knobs = { origin = makeWorld().V3(-1536, 847.5, -896) } end
		local s = setup({ engine = knobs })
		local err = rejects(function() SpringLiveCapture.new(s.opts) end, case[3])
		assert(string.find(err, "rig identity check failed", 1, true), case[1] .. ": " .. err)
		assert(#s.E.news == 1 and s.E.destroys == 1 and s.E.last.destroyed, case[1] .. ": the rig must be destroyed")
		assert(s.W.workspace:FindFirstChild("RoAlgoSpringLiveRig") == nil, case[1] .. ": no rig left in Workspace")
	end
	local s = setup()
	local cap = SpringLiveCapture.new(s.opts)
	cap:destroy()
end)

test("Features cold-start defects are refused before the rig is built", function()
	local cases = {
		{ "alpha 0.1", function(f) f.alpha = 0.1 end },
		{ "drive scale warmed", function(f) f.driveScales[3] = 1e-5 end },
		{ "already stepped", function(f) f.observations = 1 end },
		{ "extra option", function(f) f.options.hmm = { iterations = 5 } end },
		{ "variance", function(f) f.var = 1e-6 end },
	}
	for _, case in cases do
		local s = setup({ features = { mutate = case[2] } })
		rejects(function() SpringLiveCapture.new(s.opts) end, "Features cold start differs")
		assert(#s.E.news == 0, case[1] .. ": no rig built")
	end
end)

test("step runs guard, features:step(bar), engine:step(feature.drive, feature.reset) and returns {bar, feature, states}", function()
	local log = {}
	local s = setup({ log = log, engine = { log = log }, features = { log = log } })
	local cap = SpringLiveCapture.new(s.opts)
	table.clear(log)
	local records = {}
	for i = 1, 14 do
		local b = bar(i)
		local record = cap:step(b)
		records[i] = record
		local call = s.E.steps[i]
		assert(record.bar == b and record.feature == s.F.lastFeature, "record carries the bar and the Features output")
		assert(call.drive == record.feature.drive and call.reset == record.feature.reset, "engine gets that bar's drive table and reset")
		assert(#call.drive == 8, "eight v2 drives")
		assert(record.states.coupled.vector[1] == fakeVector(call.drive, i, 1)[1], "states are the engine's return")
	end
	for i = 1, 14 do
		assert(log[3 * i - 2] == "guard" and log[3 * i - 1] == "features:step" and log[3 * i] == "engine:step", "order at bar " .. i)
	end
	assert(records[1].feature.reset == true and records[2].feature.reset == false, "one reset at bar 1 only")
	assert(records[11].feature.ready == false and records[12].feature.ready == true, "ready after 12 observations")
	local st = cap:stats()
	assert(st.capture.bars == 14 and st.capture.resets == 1 and st.capture.resetIndices[1] == 1, "bars and resets")
	assert(st.capture.firstT == START_T and st.capture.lastT == START_T + 13 * 300, "time span")
	assert(st.capture.regime.status == "fit" and st.capture.regime.trainCount == 59, "HMM fitted on the prehistory")
	assert(st.totalSteps == 168 and st.capture.expectedSteps == 168, "12 verified steps per bar")
	cap:destroy()
end)

test("a guard refusal stops between bars without advancing anything", function()
	local s = setup()
	local cap = SpringLiveCapture.new(s.opts)
	cap:step(bar(1)); cap:step(bar(2))
	s.guard.allowed = false
	rejects(function() cap:step(bar(3)) end, "RoAlgoMarketControl busy")
	assert(s.F.steps == 2 and #s.E.steps == 2 and cap.index == 2 and cap.fault == nil, "nothing advanced, not faulted")
	s.guard.allowed = true
	cap:step(bar(3))
	assert(cap.index == 3 and #s.E.steps == 3, "continues once the guard allows it")
	cap:destroy()
end)

test("a failed bar faults the capture for good (L4: no in-place recovery)", function()
	local s = setup({ engine = { onStep = function(_, _, _, n) if n == 2 then error("ExplicitRunner: CORRUPT_STEP increments 2.00000 / 2.00000") end end } })
	local cap = SpringLiveCapture.new(s.opts)
	cap:step(bar(1))
	rejects(function() cap:step(bar(2)) end, "CORRUPT_STEP")
	assert(cap.fault ~= nil and cap.index == 1, "faulted at bar 2")
	rejects(function() cap:step(bar(3)) end, "faulted")
	rejects(function() cap:step(bar(2)) end, "faulted")
	assert(s.F.steps == 2 and #s.E.steps == 2, "no further Features or engine step after the fault")
	assert(cap:stats().capture.fault ~= nil, "fault reported in stats")
	cap:destroy()
	-- a malformed bar is also fatal
	local s2 = setup()
	local cap2 = SpringLiveCapture.new(s2.opts)
	rejects(function() cap2:step(nil) end, "bar table required")
	rejects(function() cap2:step(bar(1)) end, "faulted")
	cap2:destroy()
end)

test("re-entrant stepping is refused before Features advance (one request stream only)", function()
	local inner
	local s
	s = setup({ engine = { onStep = function(_, _, _, n)
		if n == 1 then inner = { pcall(function() return s.cap:step(bar(2)) end) } end
	end } })
	s.cap = SpringLiveCapture.new(s.opts)
	s.cap:step(bar(1))
	assert(inner and inner[1] == false and string.find(tostring(inner[2]), "already in progress", 1, true), "inner step refused: " .. tostring(inner and inner[2]))
	assert(s.F.steps == 1 and #s.E.steps == 1 and s.cap.index == 1 and s.cap.fault == nil, "outer bar unaffected")
	s.cap:destroy()
	-- destroying from inside a step is refused too
	local during
	local s2
	s2 = setup({ engine = { onStep = function() during = { pcall(function() s2.cap:destroy() end) } end } })
	s2.cap = SpringLiveCapture.new(s2.opts)
	s2.cap:step(bar(1))
	assert(during and during[1] == false and string.find(tostring(during[2]), "cannot destroy during a step", 1, true), "destroy refused mid-step")
	assert(not s2.cap.destroyed and not s2.E.last.destroyed, "rig intact")
	s2.cap:destroy()
end)

test("native counter and state-shape invariants fault the capture", function()
	local s = setup({ engine = { stepsPerBar = 11 } })
	local cap = SpringLiveCapture.new(s.opts)
	rejects(function() cap:step(bar(1)) end, "totalSteps 11 (expected 12)")
	assert(cap.fault ~= nil, "faulted")
	cap:destroy()
	local s2 = setup({ engine = { vectorSize = 50 } })
	local cap2 = SpringLiveCapture.new(s2.opts)
	rejects(function() cap2:step(bar(1)) end, "state numeric must carry a 51-value vector")
	cap2:destroy()
	local s3 = setup({ engine = { onStep = function(e) e.runner.corrupt = 1 end } })
	local cap3 = SpringLiveCapture.new(s3.opts)
	rejects(function() cap3:step(bar(1)) end, "corrupt 1")
	cap3:destroy()
end)

test("the regime HMM must be fitted on the prehistory at bar 1 unless explicitly waived", function()
	local s = setup()
	s.opts.prehistory = { targetDaily = {} }
	local cap = SpringLiveCapture.new(s.opts)
	rejects(function() cap:step(bar(1)) end, "regime HMM must be fitted")
	assert(cap.fault ~= nil, "faulted")
	cap:destroy()
	local s2 = setup()
	s2.opts.prehistory = { targetDaily = {} }
	s2.opts.requireRegimeFit = false
	local cap2 = SpringLiveCapture.new(s2.opts)
	cap2:step(bar(1))
	local st = cap2:stats()
	assert(st.capture.requireRegimeFit == false and st.capture.regime.status == "insufficient-history", "waiver is recorded")
	cap2:destroy()
end)

test("isolation: every other unanchored part is snapshotted and any change >= 1e-6 is a breach", function()
	local function world(s)
		local W = s.W
		local sentinel = W.part("Sentinel", W.V3(5000, 100, 5000), false, W.workspace)
		local fixed = W.part("Fixed", W.V3(10, 10, 10), true, W.workspace)
		local folder = W.new("Folder", "Presentation", W.workspace)
		local nested = W.part("PresentationNode", W.V3(-1536, 847.5, -896), false, folder)
		nested.AssemblyLinearVelocity = W.V3(3, 0, 0)
		local terrain = W.new("Terrain", "Terrain", W.workspace); terrain.Anchored = true
		terrain.Position = W.zero; terrain.AssemblyLinearVelocity = W.zero; terrain.AssemblyAngularVelocity = W.zero
		return sentinel, fixed, nested
	end
	local s = setup()
	local sentinel, fixed, nested = world(s)
	local cap = SpringLiveCapture.new(s.opts)
	assert(cap:stats().isolation.parts == 2, "exactly the two unanchored outside parts are watched")
	cap:step(bar(1))
	fixed.Position = s.W.V3(99, 99, 99)
	cap.engine.coupledRig.nodes[1].part.Position = s.W.V3(0, 0, 0)
	local d = cap:verifyIsolation()
	assert(d == 0, "anchored parts and rig parts are not isolation subjects")
	nested.AssemblyAngularVelocity = s.W.V3(0, 5e-7, 0)
	local d2, report = cap:verifyIsolation()
	assert(d2 == 5e-7 and report.worst == "Workspace.Presentation.PresentationNode", "sub-limit change measured: " .. tostring(d2))
	sentinel.Position = s.W.V3(5000, 100, 5000.000002)
	rejects(function() cap:verifyIsolation() end, "isolation breach")
	assert(cap.fault ~= nil, "a breach faults the capture")
	rejects(function() cap:step(bar(2)) end, "faulted")
	local st = cap:stats()
	assert(st.isolation.checks == 4 and st.isolation.maxDelta > 1e-6 and string.find(st.isolation.worst, "Sentinel", 1, true), "breach reported")
	cap:destroy()
	-- velocity changes count; destroyed parts are reported as missing, not as motion
	local s2 = setup()
	local sentinel2, _, nested2 = world(s2)
	local cap2 = SpringLiveCapture.new(s2.opts)
	nested2:Destroy()
	local d3, report3 = cap2:verifyIsolation()
	assert(d3 == 0 and report3.missing == 1, "missing part counted")
	sentinel2.AssemblyLinearVelocity = s2.W.V3(0, -196.2 / 60, 0)
	rejects(function() cap2:verifyIsolation() end, "isolation breach")
	cap2:destroy()
	-- a rig whose construction moves an unrelated body is refused
	local s3
	s3 = setup({ engine = { mutate = function(_, W) W.workspace:FindFirstChild("Sentinel").Position = W.V3(5001, 100, 5000) end } })
	world(s3)
	rejects(function() SpringLiveCapture.new(s3.opts) end, "isolation breach")
	assert(s3.E.destroys == 1 and s3.W.workspace:FindFirstChild("RoAlgoSpringLiveRig") == nil, "rig removed after the breach")
end)

test("stats: engine stats with a detached config copy, capture, isolation and Studio settings", function()
	local s = setup()
	local cap = SpringLiveCapture.new(s.opts)
	cap:step(bar(1))
	local st = cap:stats()
	assert(st.totalSteps == 12 and st.totalBars == 1 and st.schema == "roalgo-mechanics-v2-1", "engine stats kept")
	assert(SpringLiveCapture.deepEqual(st.config, cap.engine.config) and st.config ~= cap.engine.config, "config copied")
	st.config.nodes[1].k = 0
	assert(cap.engine.config.nodes[1].k ~= 0, "mutating stats cannot change the live config")
	assert(st.studio.gravity == 196.2 and st.studio.studioVersion == "0.741.test" and st.studio.placeId == 0, "studio settings")
	assert(st.studio.physicsSteppingMethod == "Enum.PhysicsSteppingMethod.Fixed" and st.studio.allowSleep == true, "physics settings")
	assert(st.studioAtStart.gravity == 196.2, "settings at start")
	for _, name in SpringLiveCapture.MODULE_ORDER do
		assert(st.capture.modules[name].sha256 == PINS[name], "module receipt " .. name)
	end
	assert(st.capture.captureSource.engineSha256 == "5dbebef9c245bf26a0e327b630612c3a43a3b214d747f90e25fa32be2a91f486", "capture source pin")
	assert(st.isolation.limit == 1e-6 and st.isolation.checks == 1, "isolation")
	cap:destroy()
end)

test("destroy removes the rig once, blocks further steps and allows a new capture", function()
	local s = setup()
	local cap = SpringLiveCapture.new(s.opts)
	cap:step(bar(1))
	cap:destroy(); cap:destroy()
	assert(s.E.destroys == 1 and s.W.workspace:FindFirstChild("RoAlgoSpringLiveRig") == nil, "destroyed once")
	rejects(function() cap:step(bar(2)) end, "destroyed")
	rejects(function() cap:verifyIsolation() end, "destroyed")
	assert(SpringLiveCapture.activeCount() == 0, "released")
	local again = SpringLiveCapture.new(setup().opts)
	again:destroy()
end)

------------------------------------------------------------------------------------------------------------------------
-- replayCheck
local function savedRows(n, perturb)
	local rows = {}
	for i = 1, n do
		local drive = {}
		for j = 1, 8 do drive[j] = math.sin(i * 0.37 + j) * 1.5 end
		local row = { index = i, t = START_T + (i - 1) * 300, drive = drive, reset = i == 1,
			coupled = fakeVector(drive, i, 1), independent = fakeVector(drive, i, 2), numeric = fakeVector(drive, i, 3) }
		if perturb then perturb(row, i) end
		rows[i] = row
	end
	return rows
end
local function replayOpts(s, extra)
	local o = { guard = s.opts.guard, nativeConfig2024 = engineConfig(), env = s.env }
	for k, v in extra or {} do o[k] = v end
	return o
end
local function hex(values)
	return (string.gsub(string.pack("<" .. string.rep("d", #values), table.unpack(values)), ".", function(c) return string.format("%02x", string.byte(c)) end))
end

test("replayCheck re-steps saved drives on a temporary capture-origin rig and reports max |diff| per variant", function()
	local s = setup()
	local rows = savedRows(6, function(row, i)
		if i == 2 then row.coupled[3] += 0.001 end
		if i == 5 then row.independent[40] -= 0.0015 end
	end)
	local result = SpringLiveCapture.replayCheck(rows, replayOpts(s))
	assert(result.pass == true and result.count == 6 and result.firstIndex == 1 and result.lastIndex == 6, "passes")
	assert(math.abs(result.maxAbs.coupled - 0.001) < 1e-12 and math.abs(result.maxAbs.independent - 0.0015) < 1e-12, "native diffs measured")
	assert(result.maxAbs.numeric == 0 and result.numericExact and result.tolerance == 0.002, "numeric exact; default tolerance")
	assert(result.worst.coupled.index == 2 and result.worst.coupled.component == 3, "worst coupled located")
	assert(result.worst.independent.index == 5 and result.worst.independent.component == 40, "worst independent located")
	assert(#s.E.news == 1 and s.E.news[1].options.name == "RoAlgoSpringLivePreflight", "temporary rig name")
	local o = s.E.news[1].options.origin
	assert(o.X == 0 and o.Y == 1024 and o.Z == 1024, "at the capture origin")
	assert(#s.E.steps == 6, "one engine step per row")
	for i, call in s.E.steps do
		assert(call.reset == rows[i].reset, "reset flag row " .. i)
		for j = 1, 8 do assert(call.drive[j] == rows[i].drive[j], "drive row " .. i) end
	end
	assert(result.destroyed and s.E.destroys == 1 and s.W.workspace:FindFirstChild("RoAlgoSpringLivePreflight") == nil, "rig destroyed")
	assert(result.native.config == nil and result.native.totalSteps == 72 and result.isolation.maxDelta == 0, "native stats without config")
end)

test("replayCheck: numeric must be exact and native must stay within the tolerance", function()
	local function run(perturb, extra)
		local s = setup()
		return SpringLiveCapture.replayCheck(savedRows(4, perturb), replayOpts(s, extra))
	end
	local r = run(function(row, i) if i == 3 then row.numeric[51] *= 1 + 2 ^ -52 end end)
	assert(r.pass == false and r.numericExact == false and r.maxAbs.numeric > 0, "1 ulp of numeric fails")
	assert(r.verdict == "re-captured physics differs from the 2024 calibration capture", "disclosed label")
	r = run(function(row, i) if i == 4 then row.coupled[10] += 0.0021 end end)
	assert(r.pass == false and r.nativeWithinTolerance == false, "coupled 0.0021 > 0.002 fails")
	r = run(function(row, i) if i == 1 then row.independent[2] -= 0.0021 end end)
	assert(r.pass == false, "independent 0.0021 fails")
	r = run(function(row, i) if i == 4 then row.coupled[10] += 0.0021 end end, { tolerance = 0.003 })
	assert(r.pass == true and r.tolerance == 0.003, "opts.tolerance respected")
	r = run(function(row, i) if i == 2 then row.coupled[1] += 0.0019 end end)
	assert(r.pass == true, "0.0019 passes the default")
end)

test("replayCheck accepts hex-packed exact doubles", function()
	local rows = savedRows(3)
	for _, row in rows do
		row.drive = hex(row.drive)
		for _, v in { "coupled", "independent", "numeric" } do row[v] = hex(row[v]) end
	end
	local s = setup()
	local result = SpringLiveCapture.replayCheck(rows, replayOpts(s))
	assert(result.pass and result.maxAbs.numeric == 0 and result.maxAbs.coupled == 0, "hex rows replay exactly")
	local bad = savedRows(2)
	bad[2].numeric = string.sub(hex(bad[2].numeric), 1, -3)
	rejects(function() SpringLiveCapture.replayCheck(bad, replayOpts(setup())) end, "hex of 51")
end)

test("replayCheck destroys the temporary rig when a step or the guard fails, and rethrows", function()
	local s = setup({ engine = { onStep = function(_, _, _, n) if n == 3 then error("ExplicitRunner: CORRUPT_STEP cumulative") end end } })
	rejects(function() SpringLiveCapture.replayCheck(savedRows(5), replayOpts(s)) end, "CORRUPT_STEP")
	assert(s.E.destroys == 1 and s.W.workspace:FindFirstChild("RoAlgoSpringLivePreflight") == nil, "destroyed after a failed step")
	local s2Guard
	local s2 = setup({ engine = { onStep = function(_, _, _, n) if n == 2 then s2Guard.allowed = false end end } })
	s2Guard = s2.guard
	rejects(function() SpringLiveCapture.replayCheck(savedRows(5), replayOpts(s2)) end, "guard refused replay row 3")
	assert(s2.E.destroys == 1 and #s2.E.steps == 2, "stopped between rows and destroyed")
	local s3 = setup({ engine = { mutate = function(e) e.runner.options.lossFrames = 2 end } })
	rejects(function() SpringLiveCapture.replayCheck(savedRows(2), replayOpts(s3)) end, "rig identity check failed")
	assert(s3.E.destroys == 1, "identity failure destroys the temporary rig")
	assert(SpringLiveCapture.replayCheck(savedRows(2), replayOpts(setup())).pass, "a later replay works")
end)

test("replayCheck refuses while another engine exists or the rows are malformed", function()
	local s = setup()
	local cap = SpringLiveCapture.new(s.opts)
	local r = setup()
	rejects(function() SpringLiveCapture.replayCheck(savedRows(2), replayOpts(r)) end, "another capture engine is alive")
	assert(#r.E.news == 0, "no temporary rig")
	cap:destroy()
	local cases = {
		{ "kept live rig", function(x) x.W.new("Model", "RoAlgoSpringLiveRig", x.W.workspace) end, "RoAlgoSpringLiveRig already exists" },
		{ "leftover temporary rig", function(x) x.W.new("Model", "RoAlgoSpringLivePreflight", x.W.workspace) end, "RoAlgoSpringLivePreflight already exists" },
		{ "guard refused", function(x) x.guard.allowed = false end, "guard refused construction" },
		{ "Play mode", function(x) x.W.state.running = true end, "Edit mode" },
		{ "module edited", function(x) x.env.moduleHash = makeEnv(x.W, x.E, x.F, { SpringV2Mechanics = string.rep("9", 64) }).moduleHash end, "module identity differs" },
	}
	for _, case in cases do
		local x = setup()
		case[2](x)
		rejects(function() SpringLiveCapture.replayCheck(savedRows(2), replayOpts(x)) end, case[3])
		assert(#x.E.news == 0, case[1] .. ": no temporary rig")
	end
	local rowCases = {
		{ "first row is not a reset", function(rows) rows[1].reset = false end, "must start at a segment reset" },
		{ "seven drives", function(rows) rows[2].drive[8] = nil end, "drive: 8 numbers required" },
		{ "NaN saved value", function(rows) rows[2].coupled[4] = 0 / 0 end, "coupled[4] must be finite" },
		{ "50-value vector", function(rows) rows[1].independent[51] = nil end, "independent: 51 numbers required" },
		{ "gap in indices", function(rows) rows[2].index = 3 end, "consecutive" },
		{ "reset missing", function(rows) rows[2].reset = nil end, "reset boolean required" },
	}
	for _, case in rowCases do
		local x = setup()
		local rows = savedRows(3)
		case[2](rows)
		rejects(function() SpringLiveCapture.replayCheck(rows, replayOpts(x)) end, case[3])
		assert(#x.E.news == 0, case[1] .. ": rows validated before any rig")
	end
	rejects(function() SpringLiveCapture.replayCheck({}, replayOpts(setup())) end, "at least one saved row")
	rejects(function() SpringLiveCapture.replayCheck(savedRows(1), replayOpts(setup(), { tolerance = -1 })) end, "tolerance")
	local x = setup()
	local o = replayOpts(x)
	o.nativeConfig2024 = nil
	rejects(function() SpringLiveCapture.replayCheck(savedRows(1), o) end, "nativeConfig2024")
end)

test("the replay rig and the live rig are never alive together", function()
	local seenLive
	local s = setup({ engine = { onStep = function()
		local probe = setup()
		seenLive = { pcall(SpringLiveCapture.new, probe.opts) }
	end } })
	assert(SpringLiveCapture.replayCheck(savedRows(1), replayOpts(s)).pass, "replay passes")
	assert(seenLive and seenLive[1] == false and string.find(tostring(seenLive[2]), "another capture engine is alive", 1, true),
		"a live capture cannot start while the temporary rig exists: " .. tostring(seenLive and seenLive[2]))
end)

print("SpringLiveCapture: " .. passed .. " tests passed")
