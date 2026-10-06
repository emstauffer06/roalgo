-- SYNTHETIC FIXTURES for the Spring Indicator (protocol spring-consensus-v1). Synthetic fixture · not historical evidence.
-- Every sample, record, price, label and score built here is invented test data. The only real content is the
-- saved v2 native.config architecture metadata (node/edge geometry, projections) and the drive-channel names,
-- copied from manifest RoAlgoV2_SPY_1791205420530.json (SHA-256 bd4ef4f0...8b38828). No market data is embedded.
-- Ships with the plugin (contract D16) so the Studio synthetic fixture scene can use it.
local SpringPolicy = if script then require(script.Parent.Parent.src.SpringPolicy) else require("../src/SpringPolicy")
local SpringState = if script then require(script.Parent.Parent.src.SpringState) else require("../src/SpringState")

local Fixtures = {}
Fixtures.KIND = "synthetic_fixture"
Fixtures.HEADER = "Synthetic fixture · not historical evidence"
Fixtures.T0 = 1800000000 -- synthetic epoch seconds (multiple of 300); not a market date
Fixtures.SESSION = 78

local NAN = 0 / 0
Fixtures.NAN = NAN

local function deepCopy(t)
	local out = {}
	for k, v in t do out[k] = if type(v) == "table" then deepCopy(v) else v end
	return out
end
Fixtures.deepCopy = deepCopy

-- Saved v2 native.config (architecture metadata only; generated from the manifest, not hand-typed).
local SAVED_V2_CONFIG = {
 D=64,
 anchorOffset=512,
 bankChannels={
  {2,3,4},
  {1,5,6},
  {7,8,1}
 },
 bankNames={"Fast","Medium","Slow"},
 couplingDampingRatio=0.08,
 couplingFreeLength=192,
 couplingStiffnessRatio=0.18,
 driveLimit=2,
 dt=0.016666666666666666,
 edges={
  {a=1,b=2,c=2.0142572186434244,dy=0,dz=256,freeLength=192,k=11.526227678571427,maxForce=1000000,transverse=256},
  {a=2,b=3,c=2.4018856192710816,dy=0,dz=256,freeLength=192,k=12.688536352040817,maxForce=1000000,transverse=256},
  {a=3,b=4,c=2.8164419191923122,dy=0,dz=256,freeLength=192,k=13.906635841836733,maxForce=1000000,transverse=256},
  {a=4,b=5,c=2.5891543690824568,dy=0,dz=256,freeLength=192,k=15.180526147959178,maxForce=1000000,transverse=256},
  {a=5,b=6,c=2.4107245714066288,dy=0,dz=256,freeLength=192,k=16.510207270408163,maxForce=1000000,transverse=256},
  {a=6,b=7,c=2.852467145082571,dy=0,dz=256,freeLength=192,k=17.895679209183676,maxForce=1000000,transverse=256},
  {a=7,b=8,c=3.321113020724916,dy=0,dz=256,freeLength=192,k=19.336941964285717,maxForce=1000000,transverse=256},
  {a=9,b=10,c=1.0071286093217122,dy=0,dz=256,freeLength=192,k=2.8815569196428568,maxForce=1000000,transverse=256},
  {a=10,b=11,c=1.2009428096355408,dy=0,dz=256,freeLength=192,k=3.1721340880102042,maxForce=1000000,transverse=256},
  {a=11,b=12,c=1.4082209595961561,dy=0,dz=256,freeLength=192,k=3.4766589604591833,maxForce=1000000,transverse=256},
  {a=12,b=13,c=1.2945771845412284,dy=0,dz=256,freeLength=192,k=3.7951315369897944,maxForce=1000000,transverse=256},
  {a=13,b=14,c=1.2053622857033144,dy=0,dz=256,freeLength=192,k=4.127551817602041,maxForce=1000000,transverse=256},
  {a=14,b=15,c=1.4262335725412856,dy=0,dz=256,freeLength=192,k=4.473919802295919,maxForce=1000000,transverse=256},
  {a=15,b=16,c=1.660556510362458,dy=0,dz=256,freeLength=192,k=4.834235491071429,maxForce=1000000,transverse=256},
  {a=17,b=18,c=0.5035643046608561,dy=0,dz=256,freeLength=192,k=0.7203892299107142,maxForce=1000000,transverse=256},
  {a=18,b=19,c=0.6004714048177704,dy=0,dz=256,freeLength=192,k=0.7930335220025511,maxForce=1000000,transverse=256},
  {a=19,b=20,c=0.7041104797980781,dy=0,dz=256,freeLength=192,k=0.8691647401147958,maxForce=1000000,transverse=256},
  {a=20,b=21,c=0.6472885922706142,dy=0,dz=256,freeLength=192,k=0.9487828842474486,maxForce=1000000,transverse=256},
  {a=21,b=22,c=0.6026811428516572,dy=0,dz=256,freeLength=192,k=1.0318879544005102,maxForce=1000000,transverse=256},
  {a=22,b=23,c=0.7131167862706428,dy=0,dz=256,freeLength=192,k=1.1184799505739798,maxForce=1000000,transverse=256},
  {a=23,b=24,c=0.830278255181229,dy=0,dz=256,freeLength=192,k=1.2085588727678573,maxForce=1000000,transverse=256},
  {a=1,b=9,c=1.2982480502585014,dy=-256,dz=0,freeLength=192,k=5.486484375,maxForce=1000000,transverse=256},
  {a=2,b=10,c=1.562579717354201,dy=-256,dz=0,freeLength=192,k=6.05369100765306,maxForce=1000000,transverse=256},
  {a=3,b=11,c=1.846003267541938,dy=-256,dz=0,freeLength=192,k=6.648793048469389,maxForce=1000000,transverse=256},
  {a=4,b=12,c=2.1485187008217106,dy=-256,dz=0,freeLength=192,k=7.271790497448977,maxForce=1000000,transverse=256},
  {a=5,b=13,c=1.5600795898064344,dy=-256,dz=0,freeLength=192,k=7.922683354591835,maxForce=1000000,transverse=256},
  {a=6,b=14,c=1.862595023086208,dy=-256,dz=0,freeLength=192,k=8.601471619897957,maxForce=1000000,transverse=256},
  {a=7,b=15,c=2.1842023394580186,dy=-256,dz=0,freeLength=192,k=9.30815529336735,maxForce=1000000,transverse=256},
  {a=8,b=16,c=2.5249015389218643,dy=-256,dz=0,freeLength=192,k=10.042734375,maxForce=1000000,transverse=256},
  {a=9,b=17,c=0.6491240251292507,dy=-256,dz=0,freeLength=192,k=1.37162109375,maxForce=1000000,transverse=256},
  {a=10,b=18,c=0.7812898586771005,dy=-256,dz=0,freeLength=192,k=1.513422751913265,maxForce=1000000,transverse=256},
  {a=11,b=19,c=0.923001633770969,dy=-256,dz=0,freeLength=192,k=1.6621982621173472,maxForce=1000000,transverse=256},
  {a=12,b=20,c=1.0742593504108553,dy=-256,dz=0,freeLength=192,k=1.8179476243622443,maxForce=1000000,transverse=256},
  {a=13,b=21,c=0.7800397949032172,dy=-256,dz=0,freeLength=192,k=1.9806708386479588,maxForce=1000000,transverse=256},
  {a=14,b=22,c=0.931297511543104,dy=-256,dz=0,freeLength=192,k=2.1503679049744893,maxForce=1000000,transverse=256},
  {a=15,b=23,c=1.0921011697290093,dy=-256,dz=0,freeLength=192,k=2.3270388233418373,maxForce=1000000,transverse=256},
  {a=16,b=24,c=1.2624507694609322,dy=-256,dz=0,freeLength=192,k=2.51068359375,maxForce=1000000,transverse=256}
 },
 integrator="RK4, 4 substeps per 1/60 native interval",
 massSource="coupled native Part.AssemblyMass, checked identical to independent rig",
 maxForce=1000000,
 nativeProtocol={lossFrames=3,postBarQuietFrames=2,recovery="reject corrupted capture; explicit reset and replay required",schema="verified-stepper-v2-2"},
 nodeSize=1.5,
 nodes={
  {bank=1,c=22.950000000000003,column=1,index=1,k=60.9609375,mass=3.375,name="Fast01",omega=4.25,projection={0,0.72,0.12,0,-0.08,0,0.08,0},y=512,z=0,zeta=0.8},
  {bank=1,c=27.622767857142858,column=2,index=2,k=67.26323341836734,mass=3.375,name="Fast02",omega=4.4642857142857135,projection={0,0,0.72,-0.12,0,0.08,0,0.08},y=512,z=256,zeta=0.9166666666666667},
  {bank=1,c=32.63303571428572,column=3,index=3,k=73.87547831632655,mass=3.375,name="Fast03",omega=4.678571428571429,projection={-0.08,0,0,0.72,0.12,0,0.08,0},y=512,z=512,zeta=1.0333333333333334},
  {bank=1,c=37.98080357142857,column=4,index=4,k=80.79767219387753,mass=3.375,name="Fast04",omega=4.892857142857142,projection={0,0.72,0.12,0,-0.08,0,0.08,0},y=512,z=768,zeta=1.15},
  {bank=1,c=27.57857142857143,column=5,index=5,k=88.02981505102039,mass=3.375,name="Fast05",omega=5.107142857142857,projection={0,0,0.72,-0.12,0,0.08,0,0.08},y=512,z=1024,zeta=0.8},
  {bank=1,c=32.92633928571429,column=6,index=6,k=95.57190688775509,mass=3.375,name="Fast06",omega=5.321428571428571,projection={-0.08,0,0,0.72,0.12,0,0.08,0},y=512,z=1280,zeta=0.9166666666666667},
  {bank=1,c=38.61160714285715,column=7,index=7,k=103.42394770408167,mass=3.375,name="Fast07",omega=5.5357142857142865,projection={0,0.72,0.12,0,-0.08,0,0.08,0},y=512,z=1536,zeta=1.0333333333333334},
  {bank=1,c=44.634375,column=8,index=8,k=111.5859375,mass=3.375,name="Fast08",omega=5.75,projection={0,0,0.72,-0.12,0,0.08,0,0.08},y=512,z=1792,zeta=1.15},
  {bank=2,c=11.475000000000001,column=1,index=9,k=15.240234375,mass=3.375,name="Medium01",omega=2.125,projection={0.72,0.12,0,-0.08,0,0.08,0,0},y=256,z=0,zeta=0.8},
  {bank=2,c=13.811383928571429,column=2,index=10,k=16.815808354591834,mass=3.375,name="Medium02",omega=2.2321428571428568,projection={0,0.08,0,0,0.72,-0.12,0,0.08},y=256,z=256,zeta=0.9166666666666667},
  {bank=2,c=16.31651785714286,column=3,index=11,k=18.468869579081638,mass=3.375,name="Medium03",omega=2.3392857142857144,projection={0.08,0,-0.08,0,0,0.72,0.12,0},y=256,z=512,zeta=1.0333333333333334},
  {bank=2,c=18.990401785714283,column=4,index=12,k=20.199418048469383,mass=3.375,name="Medium04",omega=2.446428571428571,projection={0.72,0.12,0,-0.08,0,0.08,0,0},y=256,z=768,zeta=1.15},
  {bank=2,c=13.789285714285715,column=5,index=13,k=22.007453762755098,mass=3.375,name="Medium05",omega=2.5535714285714284,projection={0,0.08,0,0,0.72,-0.12,0,0.08},y=256,z=1024,zeta=0.8},
  {bank=2,c=16.463169642857146,column=6,index=14,k=23.892976721938773,mass=3.375,name="Medium06",omega=2.6607142857142856,projection={0.08,0,-0.08,0,0,0.72,0.12,0},y=256,z=1280,zeta=0.9166666666666667},
  {bank=2,c=19.305803571428577,column=7,index=15,k=25.855986926020417,mass=3.375,name="Medium07",omega=2.7678571428571432,projection={0.72,0.12,0,-0.08,0,0.08,0,0},y=256,z=1536,zeta=1.0333333333333334},
  {bank=2,c=22.3171875,column=8,index=16,k=27.896484375,mass=3.375,name="Medium08",omega=2.875,projection={0,0.08,0,0,0.72,-0.12,0,0.08},y=256,z=1792,zeta=1.15},
  {bank=3,c=5.737500000000001,column=1,index=17,k=3.81005859375,mass=3.375,name="Slow01",omega=1.0625,projection={0,-0.08,0,0.08,0,0,0.72,0.12},y=0,z=0,zeta=0.8},
  {bank=3,c=6.905691964285714,column=2,index=18,k=4.203952088647958,mass=3.375,name="Slow02",omega=1.1160714285714284,projection={-0.12,0,0.08,0,0.08,0,0,0.72},y=0,z=256,zeta=0.9166666666666667},
  {bank=3,c=8.15825892857143,column=3,index=19,k=4.617217394770409,mass=3.375,name="Slow03",omega=1.1696428571428572,projection={0.72,0.12,0,0.08,0,-0.08,0,0},y=0,z=512,zeta=1.0333333333333334},
  {bank=3,c=9.495200892857142,column=4,index=20,k=5.049854512117346,mass=3.375,name="Slow04",omega=1.2232142857142856,projection={0,-0.08,0,0.08,0,0,0.72,0.12},y=0,z=768,zeta=1.15},
  {bank=3,c=6.894642857142857,column=5,index=21,k=5.5018634406887745,mass=3.375,name="Slow05",omega=1.2767857142857142,projection={-0.12,0,0.08,0,0.08,0,0,0.72},y=0,z=1024,zeta=0.8},
  {bank=3,c=8.231584821428573,column=6,index=22,k=5.973244180484693,mass=3.375,name="Slow06",omega=1.3303571428571428,projection={0.72,0.12,0,0.08,0,-0.08,0,0},y=0,z=1280,zeta=0.9166666666666667},
  {bank=3,c=9.652901785714288,column=7,index=23,k=6.463996731505104,mass=3.375,name="Slow07",omega=1.3839285714285716,projection={0,-0.08,0,0.08,0,0,0.72,0.12},y=0,z=1536,zeta=1.0333333333333334},
  {bank=3,c=11.15859375,column=8,index=24,k=6.97412109375,mass=3.375,name="Slow08",omega=1.4375,projection={-0.12,0,0.08,0,0.08,0,0,0.72},y=0,z=1792,zeta=1.15}
 },
 numericSubsteps=4,
 projectionRule="L1=1; matching bank channel weight .72, adjacent channels .12/.08/.08 with fixed signs",
 railLimit=224,
 schema="roalgo-mechanics-v2-1",
 spacing=256,
 stepsPerBar=12
}
local function deepFreeze(value)
	for _, child in value do if type(child) == "table" then deepFreeze(child) end end
	if not table.isfrozen(value) then table.freeze(value) end
	return value
end
deepFreeze(SAVED_V2_CONFIG)

local DRIVE_NAMES = table.freeze({ "trend", "immediateReturn", "rangeActivity", "volume", "peerRelative", "hourlyContext", "dailyTrend", "regimeStress" })

-- Fresh mutable copies so negative tests can corrupt them without touching other tests.
function Fixtures.nativeConfig() return deepCopy(SAVED_V2_CONFIG) end
function Fixtures.driveNames() return deepCopy(DRIVE_NAMES) end
function Fixtures.stateNames(config) return SpringState.expectedStateNames(config or SAVED_V2_CONFIG) end
function Fixtures.protocol() return SpringPolicy.protocol("spring-consensus-v1") end
function Fixtures.descriptor()
	return SpringState.describe(Fixtures.nativeConfig(), Fixtures.stateNames(), Fixtures.driveNames(), Fixtures.protocol())
end

-- A v3-shaped configuration mirroring the layout of the newer v3 Mechanics (schema roalgo-mechanics-v3-1, 12 drive
-- channels, four groups per bank, 24 or 48 nodes, 2n+11 state names). Synthetic; used only to prove rejection.
function Fixtures.v3Config(count)
	count = count or 48
	local driveNames = { "trend", "immediateReturn", "rangeActivity", "volume", "qqqMinusSpy", "iwmMinusSpy", "tltReturn",
		"xlkMinusSpy", "xlfMinusSpy", "xleMinusSpy", "targetDailyReturn", "regimeStress" }
	local groups = { "Tape", "EquityRelative", "SectorBond", "ParticipationRegime" }
	local c = { schema = "roalgo-mechanics-v3-1", nodeCount = count, columns = count / 3, D = 64, spacing = 256,
		bankNames = { "Fast", "Medium", "Slow" }, groupNames = groups, driveNames = driveNames, nodes = {}, edges = {} }
	local replicas = count / 12
	for bank = 1, 3 do
		for group = 1, 4 do
			for replica = 1, replicas do
				local col = (group - 1) * replicas + replica
				local projection = table.create(12, 0)
				projection[(group - 1) * 3 % 12 + 1] = 0.72
				projection[(group * 3) % 12 + 1] = 0.12
				projection[(group * 3 + 1) % 12 + 1] = 0.08
				projection[(group * 3 + 2) % 12 + 1] = 0.08
				table.insert(c.nodes, { index = (bank - 1) * c.columns + col, bank = bank, column = col, group = group, replica = replica,
					name = c.bankNames[bank] .. "." .. groups[group] .. string.format("%02d", replica),
					y = (3 - bank) * 256, z = (col - 1) * 256, omega = 1 + bank, projection = projection })
			end
		end
	end
	for bank = 1, 3 do
		for col = 1, c.columns - 1 do
			local a = (bank - 1) * c.columns + col
			table.insert(c.edges, { a = a, b = a + 1 })
		end
	end
	return c
end

function Fixtures.v3StateNames(config)
	local names = {}
	for i, n in config.nodes do names[i] = n.name .. ".x"; names[#config.nodes + i] = n.name .. ".v" end
	for _, bank in config.bankNames do table.insert(names, bank .. ".energy") end
	for _, group in config.groupNames do table.insert(names, group .. ".xMean"); table.insert(names, group .. ".vMean") end
	return names
end

-- Timeline: sessions of Fixtures.SESSION contiguous 5-minute bars; days are synthetic labels.
-- options.gapBefore[k] = true inserts a missing intraday interval before observation k (same day, +600 s).
-- options.resetAt[k] = true marks a recorded reset at k (observation 1 is always a reset unless firstReset == false).
-- options.overnightBefore[k] = true starts a new synthetic session at k.
function Fixtures.timeline(count, options)
	options = options or {}
	local session = options.session or Fixtures.SESSION
	local out = table.create(count)
	local t, day, inSession = Fixtures.T0, 1, 0
	for k = 1, count do
		if k > 1 then
			if inSession >= session or (options.overnightBefore and options.overnightBefore[k]) then
				day += 1
				inSession = 0
				t += 17 * 3600 + 300
			elseif options.gapBefore and options.gapBefore[k] then
				t += 600
			else
				t += 300
			end
		end
		inSession += 1
		local reset = (k == 1 and options.firstReset ~= false) or (options.resetAt ~= nil and options.resetAt[k] == true)
		out[k] = { t = t, availableT = t + 300, day = string.format("fixture-day-%02d", day), reset = reset }
	end
	return out
end

-- Default calibration motion: a shared slow factor plus node-specific oscillation, so every coordinate moves and the
-- directional nodes broadly agree. Deterministic.
function Fixtures.motion(k, x, v)
	local common = math.sin(2 * math.pi * k / 23) + 0.6 * math.sin(2 * math.pi * k / 9 + 0.4)
	for i = 1, 24 do
		local amplitude = 0.08 + 0.004 * i
		x[i] = amplitude * (common + 0.35 * math.sin(2 * math.pi * k / (5 + i % 4) + i))
		v[i] = amplitude * (0.7 * math.cos(2 * math.pi * k / 11 + 0.3 * i) + 0.2 * math.sin(2 * math.pi * k / 4 + i))
	end
end

-- Builds narrow samples via SpringState.synthetic. generator(k, x, v) fills zeroed x/v; options as Fixtures.timeline plus
-- options.invalidAt[k] = true to make observation k non-finite, and options.prefix for sample ids.
function Fixtures.stream(descriptor, count, generator, options)
	options = options or {}
	local times = Fixtures.timeline(count, options)
	local prefix = options.prefix or "fixture"
	local samples = table.create(count)
	for k = 1, count do
		local x, v = table.create(24, 0), table.create(24, 0)
		local fill = generator or Fixtures.motion
		fill(k, x, v)
		if options.invalidAt and options.invalidAt[k] then x[1] = NAN end
		local o = times[k]
		samples[k] = SpringState.synthetic(descriptor, prefix .. ":" .. k, o.t, o.availableT, o.day, o.reset, x, v)
	end
	return samples
end

function Fixtures.calibration(descriptor, count)
	descriptor = descriptor or Fixtures.descriptor()
	local SpringSignals = if script then require(script.Parent.Parent.src.SpringSignals) else require("../src/SpringSignals")
	return SpringSignals.calibrate(Fixtures.stream(descriptor, count or 180), descriptor, Fixtures.protocol())
end

-- x/v that put every eligible directional node of bank b at standardized displacement zBanks[b] (and velocity zV).
-- Non-voting nodes get `other` (default 0) so tests can show they never vote.
function Fixtures.bankState(calibration, zBanks, zV, other)
	local x, v = table.create(24, other or 0), table.create(24, other or 0)
	for b = 1, 3 do
		for _, i in calibration.eligible[b] do
			x[i] = zBanks[b] * calibration.coordinates[i].std
			local cv = calibration.coordinates[24 + i]
			v[i] = if cv.active then (zV or 0) * cv.std else 0
		end
	end
	return x, v
end

-- Named fixtures (handover Task 2): each returns x, v for a calibration.
function Fixtures.positiveAgreement(calibration) return Fixtures.bankState(calibration, { 3, 3, 3 }) end
function Fixtures.negativeAgreement(calibration) return Fixtures.bankState(calibration, { -3, -3, -3 }) end
function Fixtures.disagreement(calibration) return Fixtures.bankState(calibration, { 3, -3, 0 }) end
function Fixtures.weak(calibration) return Fixtures.bankState(calibration, { 0.1, 0.1, 0.1 }) end
function Fixtures.longReversal(calibration) return Fixtures.bankState(calibration, { 5, -1, -1 }) end
function Fixtures.shortReversal(calibration) return Fixtures.bankState(calibration, { -5, 1, 1 }) end
function Fixtures.equilibrium() return table.create(24, 0), table.create(24, 0) end
function Fixtures.nonFinite()
	local x, v = table.create(24, 0), table.create(24, 0)
	x[1], v[2] = NAN, math.huge
	return x, v
end

-- Narrow sample at timeline position k (default contiguous timeline).
function Fixtures.sample(descriptor, k, x, v, options)
	local times = Fixtures.timeline(k, options)
	local o = times[k]
	return SpringState.synthetic(descriptor, ((options and options.prefix) or "fixture") .. ":" .. k, o.t, o.availableT, o.day, o.reset, x, v)
end

function Fixtures.context(position, options)
	options = options or {}
	return { position = position or 0, pending = options.pending == true, exitedThisBar = options.exitedThisBar == true, barsSinceExit = options.barsSinceExit }
end

-- A full v2-shaped synthetic record: bar (OHLCV, label, contexts), feature (raw, drive, volatility, regime...),
-- and states.coupled/independent/numeric with vector/names/nodes(drive, force)/banks/energy. `market` scales every
-- non-x/v field so two records can share x/v but differ radically everywhere else.
function Fixtures.record(options)
	local o = options or {}
	local market = o.market or 1
	local t = o.t or Fixtures.T0
	local x, v = o.x or table.create(24, 0), o.v or table.create(24, 0)
	local price = 100 * market
	local bar = {
		t = t, availableT = if o.availableT ~= nil then o.availableT else t + 300,
		o = price, h = price * 1.01, l = price * 0.99, c = price * (1 + 0.002 * market), v = 1e6 * market, n = 5000 * market,
		vwap = price * 1.001, label = o.label or ("synthetic fixture bar " .. market), day = o.day or "fixture-day-01", minute = 570,
		contexts = { peerFive = { t = t, o = 50 * market, c = 51 * market }, spyHour = { t = t - 3600, c = 99 * market } },
	}
	local raw, names = table.create(33), table.create(33)
	for i = 1, 33 do raw[i] = market * (i - 17) * 0.37; names[i] = "raw" .. i end
	local drive = table.create(8)
	for i = 1, 8 do drive[i] = math.clamp(market * (i - 4.5) * 0.4, -2, 2) end
	local feature = {
		t = t, raw = raw, names = names, drive = drive, volatility = 0.001 * market, ready = market > 0,
		reset = if o.reset ~= nil then o.reset else false, regime = { 0.2 * market, 0.3, 0.5 }, contextMissing = { peerFive = market < 0 },
	}
	local stateNames = Fixtures.stateNames()
	local function state(sx, sv)
		local vector = table.create(51)
		for i = 1, 24 do vector[i] = sx[i]; vector[24 + i] = sv[i] end
		for b = 1, 3 do vector[48 + b] = 0.01 * b * market end
		local nodes = table.create(24)
		for i = 1, 24 do nodes[i] = { x = sx[i], v = sv[i], bank = math.ceil(i / 8), drive = market * 0.9 * (i % 3 - 1), force = market * 1000 * i } end
		local banks = {}
		for b = 1, 3 do banks[b] = { name = SAVED_V2_CONFIG.bankNames[b], displacement = market, velocity = -market, energy = vector[48 + b] } end
		return { vector = vector, names = table.clone(o.names or stateNames), nodes = nodes, banks = banks, energy = 0.02 * market }
	end
	local states = {}
	for _, variant in SpringState.VARIANTS do
		if not (o.omit and o.omit[variant]) then
			local override = o.variants and o.variants[variant]
			states[variant] = state(override and override.x or x, override and override.v or v)
		end
	end
	return { bar = bar, feature = feature, states = states }
end

-- Every table reachable from t (identity set), for reachability assertions.
function Fixtures.tables(t, seen)
	seen = seen or {}
	if type(t) ~= "table" or seen[t] then return seen end
	seen[t] = true
	for k, v in t do Fixtures.tables(k, seen); Fixtures.tables(v, seen) end
	return seen
end

function Fixtures.assertDeepFrozen(t, path)
	path = path or "root"
	assert(table.isfrozen(t), "not frozen: " .. path)
	for k, v in t do if type(v) == "table" then Fixtures.assertDeepFrozen(v, path .. "." .. tostring(k)) end end
end

function Fixtures.deepEqual(a, b, path)
	path = path or "root"
	if type(a) ~= "table" or type(b) ~= "table" then
		local same = a == b or (a ~= a and b ~= b)
		assert(same, "differs at " .. path .. ": " .. tostring(a) .. " vs " .. tostring(b))
		return true
	end
	for k, v in a do Fixtures.deepEqual(v, b[k], path .. "." .. tostring(k)) end
	for k in b do assert(a[k] ~= nil, "differs at " .. path .. "." .. tostring(k) .. ": missing") end
	return true
end

return Fixtures
