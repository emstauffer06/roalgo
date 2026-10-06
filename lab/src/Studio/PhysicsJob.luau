--!strict
-- Physics state generation job (plan Tasks 3/5/6). ENGINE CODE, executed on the plugin's own thread.
--
-- A job owns L lanes. Each lane holds one reservoir per spec (profile x preset x drive) and processes whole
-- segments: reset to equilibrium, 60 zero-input settle steps, then 12 verified steps per observation with
-- the drive held constant, reading the 48-value state after each observation. Every segment starts from the
-- same reset, so different segments are independent and lanes run different segments side by side; all
-- lanes advance together in each verified StepPhysics call (one request covers every moving part).
-- The job receives only numeric input vectors; it never sees prices, datasets or targets.

local Reservoir = require("../Physics/Reservoir")
local ExplicitRunner = require("../Physics/ExplicitRunner")
local Config = require("../Config")

local PhysicsJob = {}

export type ReservoirSpec = {
	key: string, -- e.g. "O14:P2" or "O14:P2:d0.30"
	profileId: string,
	presetId: string,
	drive: number,
}

local MAX_SEGMENT_ATTEMPTS = 4

-- args = {jobId, reservoirs = {ReservoirSpec}, projections = {[profileId] = 24xD}, lanes?: number,
--         spacing?: number, visual?: boolean, startIndex?: number}
function PhysicsJob.start(ctx: any, args: any)
	local registry = ctx.registry
	assert(type(args.jobId) == "string", "PhysicsJob: jobId required")
	assert(registry[args.jobId] == nil, "PhysicsJob: job already exists: " .. args.jobId)
	local physics = Config.values.physics
	-- A container with this name that the registry does not own is an orphan (plugin reload, failed start).
	local orphan = workspace:FindFirstChild("MarketReservoirLab_" .. args.jobId)
	while orphan do
		orphan:Destroy()
		orphan = workspace:FindFirstChild("MarketReservoirLab_" .. args.jobId)
	end
	local container = Instance.new("Model")
	container.Name = "MarketReservoirLab_" .. args.jobId
	container.Parent = workspace
	local laneCount = args.lanes or 1
	-- Default layout: every lane and every reservoir occupies the same world location. Parts never collide
	-- (CanCollide/CanTouch off) and share no constraints, so they do not interact; identical coordinates
	-- make every lane's float32 arithmetic identical to a single sequential lane (measured: offsets along
	-- the rail axis changed states by ~1e-5). Spacing is for visual layouts only.
	local spacing = args.spacing or 0
	local lanes = {}
	local all = {}
	local runner
	local okBuild, buildErr = pcall(function()
	for l = 1, laneCount do
		local laneFolder = Instance.new("Folder")
		laneFolder.Name = string.format("Lane%02d", l)
		laneFolder.Parent = container
		local reservoirs = {}
		for k, spec in args.reservoirs do
			local projection = args.projections[spec.profileId]
			assert(projection, "PhysicsJob: missing projection for " .. spec.profileId)
			local r = Reservoir.build(laneFolder, {
				physics = physics,
				presetId = spec.presetId,
				projection = projection,
				driveDisplacement = spec.drive,
				name = (string.gsub(spec.key, ":", "_")),
				origin = Vector3.new(0, (l - 1) * spacing, (k - 1) * spacing),
				visual = args.visual == true,
			})
			reservoirs[k] = r
			table.insert(all, r)
		end
		lanes[l] = { index = l, reservoirs = reservoirs, phase = "idle", count = 0, segment = nil, row = 0, out = nil }
	end
	runner = ExplicitRunner.new(all, {
		dt = physics.dt,
		stepsPerBar = physics.stepsPerBar,
		settleSteps = physics.settleSteps,
		parent = container,
	})
	end)
	if not okBuild then
		container:Destroy()
		error(buildErr, 0)
	end
	registry[args.jobId] = {
		container = container,
		lanes = lanes,
		specs = args.reservoirs,
		runner = runner,
		lastIndex = (args.startIndex or 1) - 1,
		replays = 0,
		replayLog = {},
		segments = 0,
		args = args,
	}
	local params = {}
	for k, r in lanes[1].reservoirs do
		params[args.reservoirs[k].key] = r:parameters()
	end
	return { ok = true, lanes = laneCount, reservoirsPerLane = #args.reservoirs, parameters = params, counts = lanes[1].reservoirs[1]:counts() }
end

local function driveRow(job: any, lane: any)
	local row = lane.segment[lane.row]
	for k, spec in job.specs do
		local v = row.x[spec.profileId]
		assert(v, "PhysicsJob: row lacks input for " .. spec.profileId)
		lane.reservoirs[k]:drive(v)
	end
end

local function beginSegment(lane: any, segment: { any })
	for _, r in lane.reservoirs do
		r:reset()
	end
	lane.segment = segment
	lane.phase = "settle"
	lane.count = 0
	lane.row = 0
	lane.out = table.create(#segment)
end

-- Runs a set of whole segments across the lanes. Returns records keyed by segment order.
local function runSegments(job: any, segments: { { any } })
	local physics = Config.values.physics
	local nextSeg = 1
	local done = {}
	local active = 0
	for _, lane in job.lanes do
		lane.phase = "idle"
		if nextSeg <= #segments then
			beginSegment(lane, segments[nextSeg])
			lane.segIndex = nextSeg
			nextSeg += 1
			active += 1
		end
	end
	while active > 0 do
		job.runner:stepOnce()
		for _, lane in job.lanes do
			if lane.phase == "idle" then
				continue
			end
			lane.count += 1
			if lane.phase == "settle" and lane.count == physics.settleSteps then
				lane.phase = "bar"
				lane.count = 0
				lane.row = 1
				driveRow(job, lane)
			elseif lane.phase == "bar" and lane.count == physics.stepsPerBar then
				local row = lane.segment[lane.row]
				local rec = { i = row.i, t = row.t, seg = row.seg, off = row.off, s = {} }
				for k, spec in job.specs do
					rec.s[spec.key] = lane.reservoirs[k]:read()
				end
				lane.out[lane.row] = rec
				if lane.row < #lane.segment then
					lane.row += 1
					lane.count = 0
					driveRow(job, lane)
				else
					done[lane.segIndex] = lane.out
					job.segments += 1
					if nextSeg <= #segments then
						beginSegment(lane, segments[nextSeg])
						lane.segIndex = nextSeg
						nextSeg += 1
					else
						for _, r in lane.reservoirs do
							r:reset()
						end
						lane.phase = "idle"
						active -= 1
					end
				end
			end
		end
	end
	return done
end

-- args = {jobId, rows = {{i, t, seg, off, x = {[profileId] = vector}}}}
-- Rows arrive in strictly increasing index order and each call holds whole segments only. If a verified
-- step fails (CORRUPT_STEP), every segment of the call is replayed from its reset; no state from a call is
-- returned until all of its segments completed cleanly.
function PhysicsJob.stepRows(ctx: any, args: any)
	local job = ctx.registry[args.jobId]
	assert(job, "PhysicsJob: unknown job " .. tostring(args.jobId))
	local rows = args.rows
	assert(#rows > 0 and rows[1].off == 1, "PhysicsJob: a batch must start at a segment start")
	local segments = {}
	for n, row in rows do
		assert(row.i == job.lastIndex + n, string.format("PhysicsJob: expected row %d, got %s", job.lastIndex + n, tostring(row.i)))
		if row.off == 1 then
			table.insert(segments, { row })
		else
			local cur = segments[#segments]
			assert(row.off == #cur + 1 and row.seg == cur[1].seg, "PhysicsJob: segment offsets must be consecutive")
			table.insert(cur, row)
		end
	end
	local t0 = os.clock()
	local before = job.runner:stats()
	local done
	local replays = 0
	for attempt = 1, MAX_SEGMENT_ATTEMPTS do
		local ok, res = pcall(runSegments, job, segments)
		if ok then
			done = res
			break
		end
		if not string.find(tostring(res), "CORRUPT_STEP", 1, true) or attempt == MAX_SEGMENT_ATTEMPTS then
			error(res, 0)
		end
		replays += 1
		job.replays += 1
		job.runner:recover()
		table.insert(job.replayLog, { firstIndex = rows[1].i, reason = tostring(res) })
	end
	local out = table.create(#rows)
	local maxAbsX, saturated = 0, 0
	local threshold = Config.values.physics.saturationThreshold / 3
	for s = 1, #segments do
		for _, rec in done[s] do
			for _, st in rec.s do
				for j = 1, 24 do
					local a = math.abs(st[j])
					if a > maxAbsX then
						maxAbsX = a
					end
					if a >= threshold then
						saturated += 1
					end
				end
			end
			table.insert(out, rec)
		end
	end
	assert(#out == #rows, "PhysicsJob: lost rows")
	job.lastIndex = rows[#rows].i
	local after = job.runner:stats()
	return {
		rows = out,
		seconds = os.clock() - t0,
		maxAbsXOver3 = maxAbsX,
		saturatedNodeStates = saturated,
		segmentReplays = replays,
		steps = after.totalSteps - before.totalSteps,
		stats = after,
	}
end

function PhysicsJob.status(ctx: any, args: any)
	local job = ctx.registry[args.jobId]
	if not job then
		return { exists = false }
	end
	return { exists = true, lastIndex = job.lastIndex, replays = job.replays, replayLog = job.replayLog, segments = job.segments, stats = job.runner:stats() }
end

function PhysicsJob.stop(ctx: any, args: any)
	local job = ctx.registry[args.jobId]
	if not job then
		return { ok = true, existed = false }
	end
	local stats = job.runner:stats()
	job.runner:destroy()
	for _, lane in job.lanes do
		for _, r in lane.reservoirs do
			r:destroy()
		end
	end
	job.container:Destroy()
	ctx.registry[args.jobId] = nil
	return { ok = true, existed = true, stats = stats, replays = job.replays, replayLog = job.replayLog, segments = job.segments }
end

-- Generates (in Studio, with Roblox Random) the saved projection matrix for a profile dimension.
function PhysicsJob.projection(_ctx: any, args: any)
	local Projection = require("../Physics/Projection")
	local seed = args.seed or Config.values.physics.seed
	return {
		seed = seed,
		rows = 24,
		dimension = args.dimension,
		prng = Projection.PRNG_IDENTITY,
		studioVersion = version(),
		matrix = Projection.generate(seed, 24, args.dimension),
	}
end

return PhysicsJob
