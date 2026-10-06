-- Engine-only physics specs (Studio). Registered by RunAll.luau, never by the CLI.
-- Scheduling cases use a recording stepper (no physics). Native cases require real synchronous
-- StepPhysics and fail when that capability is missing: a CLI pass is never engine verification.
local Test = require("./Test")
local Config = require("../src/Config")
local Reservoir = require("../src/Physics/Reservoir")
local ExplicitRunner = require("../src/Physics/ExplicitRunner")
local SteppingProbe = require("../src/Studio/SteppingProbe")

local suite = Test.suite("Physics")
local physics = Config.values.physics

local function projection(d: number)
	local m = {}
	for i = 1, 24 do
		local row = table.create(d, 0)
		row[((i - 1) % d) + 1] = 1
		m[i] = row
	end
	return m
end

local function withReservoir(fn)
	local folder = Instance.new("Folder")
	folder.Name = "MarketReservoirSpec"
	folder.Parent = workspace
	local ok, err = pcall(function()
		local r = Reservoir.build(folder, { physics = physics, presetId = "P2", projection = projection(14), driveDisplacement = 0.3, name = "SpecReservoir" })
		fn(r, folder)
	end)
	folder:Destroy()
	if not ok then
		error(err, 0)
	end
end

Test.case(suite, "geometry counts: 24 nodes, 24 rails, 24 axial springs, 38 couplings, 24 drives", function()
	withReservoir(function(r)
		Test.deepEq(r:counts(), { nodes = 24, rails = 24, axial = 24, couplings = 38, forces = 24 })
		local p = r:parameters()
		Test.near(p[1].mass, 1, 1e-6, "density-1 unit cube mass")
		Test.near(p[1].k, p[1].mass * 4, 1e-9, "k = m omega^2 for column 1 (omega 2)")
		Test.near(p[24].c, 2 * 0.5 * p[24].mass * 12, 1e-9, "c = 2 zeta m omega for node 24")
	end)
end)

Test.case(suite, "scheduler: one bar = exactly 12 StepPhysics calls of dt=1/60 over every moving part", function()
	withReservoir(function(r)
		local calls = {}
		local runner = ExplicitRunner.new({ r }, {
			dt = physics.dt, stepsPerBar = 12, settleSteps = 60, metronome = false,
			stepper = function(dt, parts) table.insert(calls, { dt = dt, n = #parts }) end,
		})
		runner:resetSegment()
		Test.eq(#calls, 60, "settle steps")
		table.clear(calls)
		runner:stepBar({ table.create(14, 0.5) })
		Test.eq(#calls, 12, "steps per bar")
		for _, c in calls do
			Test.eq(c.dt, 1 / 60)
			Test.eq(c.n, 24, "all 24 moving parts in every call")
		end
		runner:destroy()
	end)
end)

Test.case(suite, "drive force = k * drive * dot(row, x)/sqrt(D); reset clears forces", function()
	withReservoir(function(r)
		local x = table.create(14, 0)
		x[1] = 2
		r:drive(x)
		local n1 = r.nodes[1]
		Test.near(n1.force.Force.X, n1.k * 0.3 * 2 / math.sqrt(14), 1e-5)
		r:reset()
		Test.eq(n1.force.Force.X, 0)
	end)
end)

Test.case(suite, "native: verified StepPhysics drives the mechanics probes", function()
	local report = SteppingProbe.run("spec", { bars = 50 })
	Test.falsy(report.error, "probe error: " .. tostring(report.error))
	Test.truthy(report.oneNode.moved and report.oneNode.constrained and report.oneNode.decays, "one-node: moves on X, stays on rail, decays")
	Test.near(report.oneNode.drivenX, 0.6, 0.6, "one-node displacement toward the static k*0.6/k equilibrium")
	Test.eq(report.oneNode.stepStats.totalSteps, 660, "60 driven + 600 free steps, each metronome-verified")
	Test.truthy(report.twoNode.secondResponds, "two-node: coupled node responds")
	Test.deepEq(report.reservoir.counts, { nodes = 24, rails = 24, axial = 24, couplings = 38, forces = 24 })
	Test.eq(report.reservoir.runnerStats.stepFailures, 0, "metronome-verified steps")
end)

return suite
