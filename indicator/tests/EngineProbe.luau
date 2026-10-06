--!strict
-- Studio Edit-mode behavioral probe. A CLI compile is not a native-physics pass.
-- Parent must be Workspace or an ordinary Folder/Model beneath Workspace.
-- This test owns, and always destroys, its complete fixture.
local EngineProbe = {}

local FIELDS = { "fast", "medium", "slow", "velocity", "energy", "agreement" }
local REPEAT_TOLERANCE = 2e-4
local ZERO_TOLERANCE = 1e-4
local RELEASE_TOLERANCE = 0.005 -- normalized drive units, unchanged by physical scale
local TOTAL_BARS = 126

local function finite(n: any): boolean
	return type(n) == "number" and n == n and math.abs(n) < math.huge
end

function EngineProbe.run(parent: Instance, options: any?): any
	local report: any = {
		ok = false,
		kind = "Roblox native StepPhysics, Edit mode",
		repeatTolerance = REPEAT_TOLERANCE,
		zeroTolerance = ZERO_TOLERANCE,
		releaseTolerance = RELEASE_TOLERANCE,
		checks = {},
	}
	local fixture: Folder? = nil
	local engine: any = nil
	local function check(name: string, passed: boolean, detail: any?)
		table.insert(report.checks, { name = name, passed = passed, detail = detail })
		assert(passed, "EngineProbe: " .. name)
	end
	local ok, err = pcall(function()
		local engineModule = script.Parent.Parent:FindFirstChild("src")
		engineModule = if engineModule then engineModule:FindFirstChild("Engine") else nil
		check("Engine module is installed", engineModule ~= nil)
		local Engine = require(engineModule :: ModuleScript)
		fixture = Instance.new("Folder")
		fixture.Name = "RoAlgoIndicatorProbe"
		fixture.Parent = parent
		engine = Engine.new(fixture, { name = "ProbeRig", origin = Vector3.new(0, 72, 300) })
		local sentinel = Instance.new("Part")
		sentinel.Name = "UnsteppedSentinel"
		sentinel.Anchored = false
		sentinel.CanCollide = false
		sentinel.CanTouch = false
		sentinel.CanQuery = false
		sentinel.Transparency = 1
		sentinel.CFrame = CFrame.new(50, 80, 300)
		sentinel.Parent = fixture
		local sentinelPosition = sentinel.Position
		local completed = 0
		local function step(drive: number): any
			local state = engine:step(drive)
			completed += 1
			for _, field in FIELDS do
				assert(finite(state[field]), "EngineProbe: non-finite " .. field)
			end
			assert(math.abs(state.fast) < 3.51 and math.abs(state.medium) < 3.51 and math.abs(state.slow) < 3.51,
				"EngineProbe: rail limit exceeded")
			assert(state.energy >= 0 and state.energy < 25, "EngineProbe: energy outside declared bounds")
			if options and options.onProgress then options.onProgress(completed, TOTAL_BARS) end
			return state
		end

		engine:reset()
		local zero = step(0)
		check("zero input remains at equilibrium", math.abs(zero.fast) <= ZERO_TOLERANCE
			and math.abs(zero.medium) <= ZERO_TOLERANCE and math.abs(zero.slow) <= ZERO_TOLERANCE, zero)
		local first = step(1)
		check("positive input moves every channel", first.fast > 1e-3 and first.medium > 1e-3 and first.slow > 1e-3, first)
		check("response speeds have fast / medium / slow order", first.fast > first.medium and first.medium > first.slow, first)
		local heldPositive = first
		for _ = 2, 16 do
			heldPositive = step(1)
			assert(heldPositive.fast > 0 and heldPositive.medium > 0 and heldPositive.slow > 0,
				"EngineProbe: held-positive sign reversal")
		end
		check("held input approaches unit normalized displacement", heldPositive.fast > 0.9
			and heldPositive.medium > 0.8 and heldPositive.slow > 0.7
			and heldPositive.fast < 1.08 and heldPositive.medium < 1.08 and heldPositive.slow < 1.08, heldPositive)
		check("positive agreement", heldPositive.agreement == 1, heldPositive.agreement)
		-- Regression: a small physical signal can deactivate far from equilibrium.
		-- Holding longer did not remove that native floor at D=1; release must be measured.
		local released: any = heldPositive
		for _ = 1, 40 do released = step(0) end
		check("held input releases without retaining stale signal", math.abs(released.fast) < RELEASE_TOLERANCE
			and math.abs(released.medium) < RELEASE_TOLERANCE and math.abs(released.slow) < RELEASE_TOLERANCE, released)
		check("released held input loses energy", released.energy < heldPositive.energy * 1e-3,
			{ initial = heldPositive.energy, final = released.energy })
		check("released held input has neutral agreement", released.agreement == 0, released.agreement)

		engine:reset()
		local heldNegative: any = nil
		for _ = 1, 16 do
			heldNegative = step(-1)
			assert(heldNegative.fast < 0 and heldNegative.medium < 0 and heldNegative.slow < 0,
				"EngineProbe: held-negative sign reversal")
		end
		check("negative agreement", heldNegative.agreement == -1, heldNegative.agreement)
		check("signed input has symmetric response", math.abs(heldPositive.fast + heldNegative.fast) < 0.02
			and math.abs(heldPositive.medium + heldNegative.medium) < 0.02
			and math.abs(heldPositive.slow + heldNegative.slow) < 0.02, heldNegative)

		engine:reset()
		local impulse = step(1)
		local tail: any = impulse
		for _ = 1, 40 do tail = step(0) end
		check("native impulse loses energy", impulse.energy > 1e-5 and tail.energy < impulse.energy * 1e-3,
			{ initial = impulse.energy, final = tail.energy })
		check("native impulse returns toward equilibrium", math.abs(tail.fast) < RELEASE_TOLERANCE
			and math.abs(tail.medium) < RELEASE_TOLERANCE and math.abs(tail.slow) < RELEASE_TOLERANCE, tail)
		check("decayed native impulse has neutral agreement", tail.agreement == 0, tail.agreement)

		local sequence = { 1, 0.5, -0.75, 0, 0.25, 0 }
		local repeats = {}
		for repeatIndex = 1, 2 do
			engine:reset()
			local states = {}
			for _, drive in sequence do table.insert(states, step(drive)) end
			repeats[repeatIndex] = states
		end
		local maxDifference = 0
		for i = 1, #sequence do
			for _, field in FIELDS do
				maxDifference = math.max(maxDifference, math.abs(repeats[1][i][field] - repeats[2][i][field]))
			end
		end
		check("reset sequence repeats within tolerance", maxDifference <= REPEAT_TOLERANCE, maxDifference)
		check("parts outside engine are not stepped", (sentinel.Position - sentinelPosition).Magnitude <= 1e-6
			and sentinel.AssemblyLinearVelocity.Magnitude <= 1e-6)
		local stats = engine:stats()
		check("native rig contains three springs, rails, and forces", stats.counts.nodes == 3
			and stats.counts.springs == 3 and stats.counts.rails == 3 and stats.counts.forces == 3
			and stats.counts.metronomes == 2, stats.counts)
		check("every bar has twelve verified native steps", completed == TOTAL_BARS and stats.totalBars == completed
			and stats.totalSteps == completed * 12 and stats.parts == 5 and stats.corruptSteps == 0, stats)
		check("native rail motion is restrained", stats.maxOffAxis <= 1e-3 and stats.saturatedNodes == 0
			and stats.saturationObservations == 0, stats)
		report.completedBars = completed
		report.firstPositive = first
		report.heldPositive = heldPositive
		report.heldRelease = released
		report.heldNegative = heldNegative
		report.impulse = { initial = impulse, tail = tail }
		report.maxRepeatDifference = maxDifference
		report.stats = stats
	end)
	if engine then
		if not report.stats then report.stats = engine:stats() end
		engine:destroy()
	end
	if fixture then fixture:Destroy() end
	report.ok = ok
	if not ok then report.error = tostring(err) end
	return report
end

return EngineProbe
