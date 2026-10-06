-- Physics pump (ENGINE CODE, runs in the Studio MCP/command context, which may use HttpService to reach the
-- local bridge on 127.0.0.1:47621). It pulls a job's aligned input pages from the bridge, asks the
-- MarketReservoirLab plugin to step them on the plugin's own thread (mailbox events in CoreGui), and posts the
-- measured states back to the bridge, which writes, hashes and acknowledges each immutable page.
-- Progress: CoreGui.MarketReservoirLabPumpStatus (JSON). Cancel: set its attribute Cancel = true; the pump
-- stops at the next page boundary.
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")

local Pump = {}
local BRIDGE = "http://127.0.0.1:47621"

local function call(command: string, args: any, timeout: number?)
	local requestEvent = CoreGui:FindFirstChild("MarketReservoirLabRequest") :: BindableEvent
	local responseEvent = CoreGui:FindFirstChild("MarketReservoirLabResponse") :: BindableEvent
	assert(requestEvent and responseEvent, "MarketReservoirLab plugin is not loaded in this Studio")
	local id = HttpService:GenerateGUID(false)
	local result
	local conn = responseEvent.Event:Connect(function(r)
		if type(r) == "table" and r.id == id then
			result = r
		end
	end)
	requestEvent:Fire({ id = id, command = command, args = args })
	local t0 = os.clock()
	while not result do
		task.wait()
		if os.clock() - t0 > (timeout or 3600) then
			conn:Disconnect()
			error("plugin request timed out: " .. command)
		end
	end
	conn:Disconnect()
	if not result.ok then
		error("plugin request failed: " .. tostring(result.result))
	end
	return result.result
end
Pump.call = call

local function get(path: string)
	local r = HttpService:RequestAsync({ Url = BRIDGE .. path, Method = "GET" })
	if not r.Success then
		error("bridge GET " .. path .. " -> " .. r.StatusCode .. " " .. r.Body)
	end
	return HttpService:JSONDecode(r.Body)
end

local function post(path: string, value: any)
	local r = HttpService:RequestAsync({
		Url = BRIDGE .. path,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = HttpService:JSONEncode(value),
	})
	local ok, body = pcall(HttpService.JSONDecode, HttpService, r.Body)
	if not r.Success or not ok or not body.ok then
		error("bridge POST " .. path .. " -> " .. r.StatusCode .. " " .. r.Body)
	end
	return body
end

local function statusValue(): StringValue
	local status = CoreGui:FindFirstChild("MarketReservoirLabPumpStatus") :: StringValue
	if not status then
		status = Instance.new("StringValue")
		status.Name = "MarketReservoirLabPumpStatus"
		status.Parent = CoreGui
	end
	return status
end

function Pump.status(): string
	return statusValue().Value
end

function Pump.cancel()
	statusValue():SetAttribute("Cancel", true)
end

-- Identity of the engine code the plugin runs for this job: the sha256 attributes that the dev-tree sync
-- stamped on each module, plus the Studio version. Recorded in every state page; a change mid-job aborts it.
local CODE_MODULES = { "src/Studio/PhysicsJob", "src/Physics/ExplicitRunner", "src/Physics/Reservoir", "src/Config", "generated/ConfigData" }
local function codeSignature()
	local dev = game:GetService("ServerStorage"):FindFirstChild("MarketReservoirLabDev")
	assert(dev, "ServerStorage.MarketReservoirLabDev is missing")
	local out = { studioVersion = version(), runner = "verified-deferred-stepping" }
	local parts = {}
	for _, path in CODE_MODULES do
		local node: Instance? = dev
		for seg in string.gmatch(path, "[^/]+") do
			node = node and node:FindFirstChild(seg)
		end
		assert(node, "dev module missing: " .. path)
		local sha = (node :: Instance):GetAttribute("sha256")
		assert(type(sha) == "string", "dev module has no sha256 attribute: " .. path)
		out[path] = sha
		table.insert(parts, path .. "=" .. sha)
	end
	out.signature = table.concat(parts, ";") .. ";" .. out.studioVersion
	return out
end

-- Starts a job in the background and returns at once (or runs it to completion when blocking is true).
function Pump.start(experimentId: string, jobId: string, blocking: boolean?)
	local status = statusValue()
	status:SetAttribute("Cancel", false)
	local JOB = get("/artifact/" .. experimentId .. "/" .. jobId .. "-job.json")
	local s = { job = jobId, phase = "starting", page = 0, processed = 0, total = JOB.rows, replays = 0, startedClock = os.clock() }
	local function setStatus()
		s.updatedClock = os.clock()
		status.Value = HttpService:JSONEncode(s)
	end
	setStatus()
	local code
	local function body()
		local ok, err = pcall(function()
			local projections = {}
			for profileId, name in JOB.projectionArtifacts do
				projections[profileId] = get("/artifact/" .. experimentId .. "/" .. name).matrix
			end
			-- Resume: continue after the last saved page (pages always end at a segment boundary). A job left
			-- in the plugin by an interrupted pump is discarded and a fresh one starts at the next segment.
			local saved
			for _, stream in JOB.streams do
				local p = get("/progress/" .. experimentId .. "/" .. stream)
				assert(saved == nil or (p.pages == saved.pages and p.rows == saved.rows), "saved progress differs across streams")
				saved = p
			end
			local page = saved.pages
			local from = saved.rows + 1
			s.resumedFrom = from
			code = codeSignature()
			s.code = code
			call("runDev", { module = "src/Studio/PhysicsJob", fn = "stop", args = { jobId = jobId } })
			local started = call("runDev", {
				module = "src/Studio/PhysicsJob",
				fn = "start",
				args = { jobId = jobId, reservoirs = JOB.reservoirs, projections = projections, lanes = JOB.lanes, startIndex = from },
			})
			if page == 0 then
				post("/artifact/" .. experimentId .. "/" .. jobId .. "-reservoirs.json", { job = JOB, started = started, studioVersion = version() })
			else
				post("/artifact/" .. experimentId .. "/" .. jobId .. "-resume-" .. from .. ".json", { resumedFrom = from, page = page, started = started })
			end
			local t0 = os.clock()
			local steps = 0
			while true do
				if status:GetAttribute("Cancel") then
					s.phase = "cancelled"
					break
				end
				local batches = {}
				local first
				for _, stream in JOB.streams do
					local b = get("/inputs/" .. experimentId .. "/" .. stream .. "?from=" .. from .. "&count=" .. JOB.pageRows)
					batches[stream] = b
					first = first or b
					assert(b.total == first.total and #b.rows == #first.rows, "job streams are not aligned")
				end
				if #first.rows == 0 then
					break
				end
				-- whole segments only: unless the batch reaches the end of the stream, leave the trailing
				-- (possibly incomplete) segment for the next batch
				local keep = #first.rows
				if from - 1 + #first.rows < first.total then
					keep = 0
					for n = #first.rows, 2, -1 do
						if first.rows[n].off == 1 then
							keep = n - 1
							break
						end
					end
					assert(keep > 0, "a segment is longer than the page size")
				end
				local rows = table.create(keep)
				for n = 1, keep do
					local r0 = first.rows[n]
					local x = {}
					for _, stream in JOB.streams do
						local r = batches[stream].rows[n]
						assert(r.i == r0.i and r.t == r0.t and r.seg == r0.seg and r.off == r0.off, "stream rows differ")
						x[JOB.streamProfiles[stream]] = r.x
					end
					rows[n] = { i = r0.i, t = r0.t, seg = r0.seg, off = r0.off, x = x }
				end
				local nowCode = codeSignature()
				if nowCode.signature ~= code.signature then
					error("the dev source tree changed during the job; refusing to mix code versions in one job")
				end
				local res = call("runDev", { module = "src/Studio/PhysicsJob", fn = "stepRows", args = { jobId = jobId, rows = rows } })
				page += 1
				steps += res.steps
				local batchPages = {}
				for _, stream in JOB.streams do
					local profileId = JOB.streamProfiles[stream]
					local keys = {}
					for _, spec in JOB.reservoirs do
						if spec.profileId == profileId then
							table.insert(keys, spec.key)
						end
					end
					local outRows = table.create(#res.rows)
					for n, rec in res.rows do
						local st = {}
						for _, key in keys do
							st[key] = rec.s[key]
						end
						outRows[n] = { i = rec.i, t = rec.t, seg = rec.seg, off = rec.off, s = st }
					end
					table.insert(batchPages, {
						page = page,
						fromIndex = from,
						stream = stream,
						profileId = profileId,
						keys = keys,
						jobId = jobId,
						rows = outRows,
						code = code,
						diag = {
							maxAbsXOver3 = res.maxAbsXOver3,
							saturatedNodeStates = res.saturatedNodeStates,
							segmentReplays = res.segmentReplays,
							steps = res.steps,
							stats = res.stats,
							seconds = res.seconds,
						},
					})
				end
				-- all stream pages of this batch are committed together by the bridge
				post("/states-batch/" .. experimentId, { pages = batchPages })
				from += keep
				s.phase = "running"
				s.page = page
				s.processed = from - 1
				s.replays += res.segmentReplays
				s.elapsed = os.clock() - t0
				s.barsPerSecond = (from - s.resumedFrom) / math.max(1e-6, s.elapsed)
				s.stepsPerSecond = steps / math.max(1e-6, s.elapsed)
				s.stats = res.stats
				setStatus()
				task.wait()
			end
			if s.phase ~= "cancelled" then
				s.phase = "complete"
			end
			s.stopped = call("runDev", { module = "src/Studio/PhysicsJob", fn = "stop", args = { jobId = jobId } })
			-- status artifact named per attempt; a failed status post never turns a finished job into a failure
			local okPost, postErr = pcall(post, "/artifact/" .. experimentId .. "/" .. jobId .. "-pump-final-" .. s.resumedFrom .. ".json", s)
			if not okPost then
				s.statusPostError = tostring(postErr)
			end
		end)
		if not ok then
			s.phase = "failed"
			s.error = tostring(err)
			pcall(call, "runDev", { module = "src/Studio/PhysicsJob", fn = "stop", args = { jobId = jobId } })
		end
		setStatus()
		return s
	end
	if blocking then
		return body()
	end
	task.spawn(body)
	return "pump started for " .. jobId
end

-- Runs several jobs one after another in the background; stops at the first job that does not complete.
-- The pump-final artifact of a finished job makes a re-queued job a no-op only through resume (0 new rows).
function Pump.queue(experimentId: string, jobIds: { string })
	local queueStatus = CoreGui:FindFirstChild("MarketReservoirLabQueueStatus") :: StringValue
	if not queueStatus then
		queueStatus = Instance.new("StringValue")
		queueStatus.Name = "MarketReservoirLabQueueStatus"
		queueStatus.Parent = CoreGui
	end
	local results = {}
	local function save(phase)
		queueStatus.Value = HttpService:JSONEncode({ phase = phase, jobs = jobIds, results = results, clock = os.clock() })
	end
	save("running")
	task.spawn(function()
		for _, jobId in jobIds do
			local ok, s = pcall(Pump.start, experimentId, jobId, true)
			table.insert(results, { job = jobId, phase = if ok and type(s) == "table" then s.phase else "failed", error = if ok then (type(s) == "table" and s.error or nil) else tostring(s) })
			save("running")
			if not ok or type(s) ~= "table" or s.phase ~= "complete" then
				save("stopped")
				return
			end
		end
		save("complete")
	end)
	return "queue started: " .. table.concat(jobIds, ",")
end

function Pump.queueStatus(): string
	local q = CoreGui:FindFirstChild("MarketReservoirLabQueueStatus") :: StringValue
	return if q then q.Value else "none"
end

return Pump
