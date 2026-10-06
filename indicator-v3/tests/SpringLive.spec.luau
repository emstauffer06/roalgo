-- SpringLive spec (contract D17 style). Self-running: luau.exe tests/SpringLive.spec.luau
-- Every Roblox service, the scheduler and the module dependencies (SpringLiveCapture, SpringLiveSession, SpringFrozenV1,
-- SpringReplayView, SpringPanel, SpringChart) are doubles injected through opts.deps. A frame-stepped scheduler stands in
-- for task.spawn/task.wait and Heartbeat; the capture double yields once per bar, so commands can arrive between bars as
-- they do in Studio. These checks cover the controller's orchestration only; native stepping, the real session and the
-- real UI are verified in Studio by the lead.
local loaded, SpringLive = pcall(require, "../src/SpringLive")
assert(loaded and type(SpringLive) == "table" and type(SpringLive.start) == "function", "SpringLive must load: " .. tostring(SpringLive))
local passed = 0
local function test(name, fn) fn(); passed += 1; print("PASS " .. name) end

local CONTROL = SpringLive.CONTROL_NAME
local PLAN_SHA = "11c7f75de45ae7eafd889d2be1d1277a88b57599459d46f634b88100ec2333bc"
local ADDENDUM_SHA = string.rep("fd", 32)
local RUN_IDS = { "coupled", "zero", "frozen", "independent", "numeric", "ema_baseline", "no_trade" }

local function find(list, value, from)
	for i = from or 1, #list do if list[i] == value then return i end end
	return nil
end
local function count(list, prefix)
	local n = 0
	for _, s in list do if string.sub(s, 1, #prefix) == prefix then n += 1 end end
	return n
end
local function lastIndexOf(list, prefix)
	for i = #list, 1, -1 do if string.sub(list[i], 1, #prefix) == prefix then return i end end
	return nil
end
local function expectError(fn, needle)
	local ok, err = pcall(fn)
	assert(not ok, "expected an error containing " .. tostring(needle))
	if needle then assert(string.find(tostring(err), needle, 1, true), "error '" .. tostring(err) .. "' lacks '" .. needle .. "'") end
	return err
end

-- Minimal strict JSON reader for the POST bodies; it also asserts the D18 ASCII-only rule on every string byte.
local function decodeJson(s)
	local pos = 1
	local function ws() pos = string.find(s, "[^ \t\r\n]", pos) or #s + 1 end
	local ESC = { b = "\b", t = "\t", n = "\n", f = "\f", r = "\r", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
	local function str()
		assert(string.sub(s, pos, pos) == '"', "string expected at " .. pos)
		pos += 1
		local out = {}
		while true do
			local c = string.sub(s, pos, pos)
			if c == '"' then pos += 1; break end
			if c == "\\" then
				local e = string.sub(s, pos + 1, pos + 1)
				if e == "u" then
					local cp = tonumber(string.sub(s, pos + 2, pos + 5), 16)
					pos += 6
					if cp >= 0xD800 and cp <= 0xDBFF then
						assert(string.sub(s, pos, pos + 1) == "\\u", "lone surrogate")
						local lo = tonumber(string.sub(s, pos + 2, pos + 5), 16)
						pos += 6
						cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
					end
					table.insert(out, utf8.char(cp))
				else
					assert(ESC[e], "bad escape")
					table.insert(out, ESC[e])
					pos += 2
				end
			else
				local b = string.byte(c)
				assert(b and b >= 0x20 and b < 0x7F, "non-ASCII or control byte in JSON string at " .. pos)
				table.insert(out, c)
				pos += 1
			end
		end
		return table.concat(out)
	end
	local value
	value = function()
		ws()
		local c = string.sub(s, pos, pos)
		if c == "{" then
			pos += 1
			local t = {}
			ws()
			if string.sub(s, pos, pos) == "}" then pos += 1; return t end
			while true do
				ws()
				local k = str()
				ws()
				assert(string.sub(s, pos, pos) == ":", "colon expected")
				pos += 1
				t[k] = value()
				ws()
				local d = string.sub(s, pos, pos)
				pos += 1
				if d == "}" then return t end
				assert(d == ",", "comma expected")
			end
		elseif c == "[" then
			pos += 1
			local t = {}
			ws()
			if string.sub(s, pos, pos) == "]" then pos += 1; return t end
			while true do
				table.insert(t, value())
				ws()
				local d = string.sub(s, pos, pos)
				pos += 1
				if d == "]" then return t end
				assert(d == ",", "comma expected in array")
			end
		elseif c == '"' then
			return str()
		elseif string.sub(s, pos, pos + 3) == "true" then
			pos += 4
			return true
		elseif string.sub(s, pos, pos + 4) == "false" then
			pos += 5
			return false
		end
		local num = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
		assert(num and #num > 0, "value expected at " .. pos)
		pos += #num
		return tonumber(num)
	end
	local v = value()
	ws()
	assert(pos == #s + 1, "trailing bytes")
	return v
end

-- Exact little-endian hex of doubles, as the live server sends them (capture-check `hex`, L10).
local function hexOf(values)
	local packed = string.pack("<" .. string.rep("d", #values), table.unpack(values))
	return (string.gsub(packed, ".", function(c) return string.format("%02x", string.byte(c)) end))
end
local function savedValue(i, k) return i / 7 + k * 1e-3 end
local function savedDrive(i, k) return i * 0.001 + k / 3 end

-- Roblox-like instance double: Parent assignment maintains children; writes can be observed.
local Node = {}
Node.__index = function(self, k)
	local method = rawget(Node, k)
	if method ~= nil then return method end
	return rawget(self, "_props")[k]
end
Node.__newindex = function(self, k, v)
	local props = rawget(self, "_props")
	if k == "Parent" then
		local old = props.Parent
		if old then
			local kids = rawget(old, "_children")
			local at = find(kids, self)
			if at then table.remove(kids, at) end
		end
		props.Parent = v
		if v then table.insert(rawget(v, "_children"), self) end
		return
	end
	props[k] = v
	local hook = rawget(self, "_onWrite")
	if hook then hook(k, v) end
end
function Node.new(class, name)
	return setmetatable({ _props = { Name = name or class, ClassName = class }, _children = {}, _attrs = {} }, Node)
end
function Node:FindFirstChild(name)
	for _, c in rawget(self, "_children") do if c.Name == name then return c end end
	return nil
end
function Node:GetChildren() return table.clone(rawget(self, "_children")) end
function Node:Destroy() self.Parent = nil; rawset(self, "_destroyed", true) end
function Node:Invoke(...) return self.OnInvoke(...) end
function Node:GetAttribute(k) return rawget(self, "_attrs")[k] end
function Node:SetAttribute(k, v) rawget(self, "_attrs")[k] = v end

-- Frame-stepped scheduler: spawn runs a thread until it yields (task.spawn semantics); frame() resumes every suspended
-- thread once and fires Heartbeat.
local function scheduler()
	local S = { threads = {}, handlers = {}, frames = 0 }
	local function resume(co, ...)
		local ok, err = coroutine.resume(co, ...)
		if not ok then error("thread failed: " .. tostring(err), 0) end
		if coroutine.status(co) ~= "dead" then table.insert(S.threads, co) end
	end
	function S.spawn(fn, ...) resume(coroutine.create(fn), ...) end
	function S.wait() coroutine.yield(); return 0 end
	S.heartbeat = {
		Connect = function(_, fn)
			local connection = { Connected = true }
			function connection:Disconnect() self.Connected = false end
			table.insert(S.handlers, { fn = fn, c = connection })
			return connection
		end,
	}
	function S.frame(dt)
		S.frames += 1
		local list = S.threads
		S.threads = {}
		for _, co in list do resume(co) end
		for _, h in table.clone(S.handlers) do if h.c.Connected then h.fn(dt or 1 / 60) end end
	end
	function S.busy() return #S.threads > 0 end
	return S
end

local function makeWorld(cfg)
	cfg = cfg or {}
	local S = scheduler()
	local W = { cfg = cfg, S = S, log = {}, posts = {}, store = {}, warnings = {}, clock = 0, camera = {}, urls = {},
		baseUrl = cfg.baseUrl or "http://127.0.0.1:47627",
		counts = { step = 0, decide = 0, drain = 0, isolation = 0, replayCheck = 0, saved = 0, captureNew = 0 } }
	local function log(s) if not (cfg.quietUi and (string.match(s, "^view ") or string.match(s, "^panel ") or string.match(s, "^chart "))) then table.insert(W.log, s) end end
	W.logf = log

	-- Universe: sessions of bars; the forward test starts after captureRows.
	local days = cfg.days or { 6, 6, 6, 3, 6, 6, 6, 6, 6, 6, 6, 6 }
	local T0 = cfg.T0 or 1700000000
	local bars = {}
	for d, n in days do
		for j = 1, n do
			local t = T0 + (d - 1) * 86400 + (j - 1) * 300
			table.insert(bars, { t = t, availableT = t + 300, day = string.format("D%04d", d), label = string.format("D%04d %02d", d, j),
				o = 100 + d, h = 101 + d, l = 99 + d, c = 100.5 + d, v = 1000, n = 10, vwap = 100, minute = j, contexts = { peerFive = {} } })
		end
	end
	W.bars = bars
	local N = #bars
	local captureRows = cfg.captureRows or 20
	local pageSize = cfg.pageSize or 16
	local pageCount = math.ceil(N / pageSize)
	W.expect = cfg.expect or { schema = "roalgo-spring-live-data-v1", datasetId = "test-dataset", bars = N, sessions = #days,
		captureRows = captureRows, liveStartIndex = captureRows + 1, liveStartT = bars[captureRows + 1].t, pageSize = pageSize,
		pageCount = pageCount }
	if cfg.useRealExpect then W.expect = nil end
	if cfg.mutateExpect then cfg.mutateExpect(W.expect) end
	local datasetId = if W.expect then W.expect.datasetId else SpringLive.EXPECT.datasetId
	W.manifest = { schema = "roalgo-spring-live-data-v1", format = "roalgo-v2-dataset-schema-2-paged", datasetId = datasetId,
		captureDataHash = "capture-hash", query = { symbol = "SPY", train = 20, validation = 5, test = 444, ["end"] = "2026-10-02" },
		split = { trainEndT = T0 + 86400, validationEndT = T0 + 2 * 86400, testStartT = T0 + 2 * 86400 },
		prehistory = { marker = "prehistory" }, pageSize = pageSize, pageCount = pageCount, bars = N, captureRows = captureRows,
		liveStartIndex = captureRows + 1, liveStartT = bars[captureRows + 1].t, metadata = {} }
	if cfg.mutateManifest then cfg.mutateManifest(W.manifest) end

	W.CoreGui = Node.new("CoreGui")
	W.workspace = Node.new("Workspace")
	local camera = Node.new("Camera")
	rawset(camera, "_onWrite", function(k) table.insert(W.camera, k); log("camera " .. k) end)
	W.workspace.CurrentCamera = camera

	-- Bodies are opaque tokens; JSONDecode resolves them. Labelled tokens log "decode <label>" so the specs can see in which
	-- thread, and between which bars, a page or capture-check block is decoded.
	local tokens, labels, nextToken = {}, {}, 0
	local function token(value, label)
		nextToken += 1
		local key = "@@" .. nextToken
		tokens[key] = value
		labels[key] = label
		return key
	end
	local function parseUrl(url)
		-- Every request must go to the configured server: the L9 default http://127.0.0.1:47627 unless cfg.baseUrl.
		assert(string.sub(url, 1, #W.baseUrl) == W.baseUrl, "request to another server: " .. url)
		table.insert(W.urls, url)
		local path, query = string.match(string.sub(url, #W.baseUrl + 1), "^(/[^?]*)%??(.*)$")
		assert(path, "unexpected URL " .. url)
		local q = {}
		for k, v in string.gmatch(query, "([^&=]+)=([^&]*)") do q[k] = v end
		return path, q
	end
	W.Http = {
		GetAsync = function(_, url)
			local path, q = parseUrl(url)
			if path == "/spring-live/manifest" then
				log("GET manifest")
				return token(W.manifest)
			elseif path == "/spring-live/page" then
				local k = tonumber(q.index)
				log("GET page " .. k)
				if cfg.pageLatency and coroutine.isyieldable() then coroutine.yield() end
				local first, last = (k - 1) * pageSize + 1, math.min(k * pageSize, N)
				local page = { datasetId = W.manifest.datasetId, page = k, pageCount = pageCount, firstIndex = first, lastIndex = last,
					bars = table.move(bars, first, last, 1, {}) }
				if cfg.mutatePage then cfg.mutatePage(page) end
				return token(page, "page " .. k)
			elseif path == "/spring-live/capture-check" then
				local a, b = tonumber(q.first), tonumber(q.last)
				log("GET capture-check " .. a .. "-" .. b)
				local records = {}
				for i = a, b do
					local drive, vector = {}, {}
					for k = 1, 8 do drive[k] = savedDrive(i, k) end
					for k = 1, 51 do vector[k] = savedValue(i, k) end
					local record = { index = i, t = if bars[i] then bars[i].t else i, reset = i == 1, drive = table.clone(drive),
						coupled = table.clone(vector), independent = table.clone(vector), numeric = table.clone(vector),
						hex = { drive = hexOf(drive), coupled = hexOf(vector), independent = hexOf(vector), numeric = hexOf(vector) } }
					-- Simulated JSONDecode imprecision: every JSON number drifts by at least one ulp; the hex stays exact.
					if cfg.decodeNoise then
						for _, key in { "drive", "coupled", "independent", "numeric" } do
							local list = record[key]
							for k = 1, #list do list[k] += list[k] * 2 ^ -52 end
						end
					end
					records[i - a + 1] = record
				end
				if cfg.mutateCheck then cfg.mutateCheck(records, a, b) end
				return token({ schema = "roalgo-spring-live-capture-check-1", first = a, last = b, count = b - a + 1, names = { "Fast01.x" }, records = records },
					"capture-check " .. a .. "-" .. b)
			elseif path == "/spring-live/chunk" then
				log("GET chunk " .. q.name .. (if q.sha256 then " sha" else ""))
				local item = W.store[q.runId .. "/" .. q.name]
				if not item then error("HTTP 404 (Not Found)") end
				if q.sha256 and q.sha256 ~= item.sha256 then error("HTTP 409 (Conflict)") end
				return token(item.payload)
			end
			error("unknown GET " .. url)
		end,
		JSONDecode = function(_, s)
			local v = tokens[s]
			assert(v ~= nil, "JSONDecode of an unknown body")
			if labels[s] then log("decode " .. labels[s]) end
			return v
		end,
		RequestAsync = function(_, req)
			if req.Method == "GET" then
				-- The runId check before the pre-flight: is there a plan for this runId already?
				local path, q = parseUrl(req.Url)
				assert(path == "/spring-live/chunk" and q.name == "plan" and q.runId, "only the runId check uses RequestAsync GET")
				log("CHECK runId " .. q.runId)
				if cfg.runIdCheck then
					local r = cfg.runIdCheck()
					if r == "throw" then error("HttpError: ConnectFail") end
					if r then return { Success = r == 200, StatusCode = r, Body = "{}" } end
				end
				local exists = W.store[q.runId .. "/plan"] ~= nil
				return { Success = exists, StatusCode = if exists then 200 else 404, Body = if exists then "{}" else "{\"error\":\"Chunk not found\"}" }
			end
			assert(req.Method == "POST" and req.Headers["Content-Type"] == "application/json", "POST with JSON content type expected")
			table.insert(W.urls, req.Url)
			assert(req.Url == W.baseUrl .. "/spring-live/chunk", "chunk route expected")
			-- The server's 48 MB body limit (spring-live-server.mjs MAX_BODY_BYTES): an oversize body is refused unread.
			if #req.Body > 48 * 1024 * 1024 then
				log("POST oversize")
				return { Success = false, StatusCode = 413, StatusMessage = "Payload Too Large", Body = "{\"error\":\"too large\"}" }
			end
			local body
			if #req.Body > 4 * 1024 * 1024 then
				-- Large bodies (the size-limit spec) are not parsed char by char; sorted keys put name first and runId last.
				body = { name = string.match(req.Body, '^{"name":"([%w_%-]+)"'), runId = string.match(req.Body, '"runId":"([%w_%-]+)"}$'),
					payload = { large = #req.Body } }
				assert(body.name and body.runId, "large body keys")
			else
				body = decodeJson(req.Body)
				local keys = {}
				for k in body do table.insert(keys, k) end
				table.sort(keys)
				assert(table.concat(keys, ",") == "name,payload,runId", "body keys must be exactly runId,name,payload")
			end
			log("POST " .. body.name)
			table.insert(W.posts, { name = body.name, runId = body.runId, payload = body.payload, raw = req.Body })
			if cfg.postFail then
				local r = cfg.postFail(body.name)
				if r == "throw" then error("HttpError: ConnectFail") end
				if r then return { Success = false, StatusCode = r, StatusMessage = "fail", Body = "{\"error\":\"injected\"}" } end
			end
			local key = body.runId .. "/" .. body.name
			if W.store[key] then return { Success = false, StatusCode = 409, StatusMessage = "Conflict", Body = "{\"error\":\"exists\"}" } end
			-- (A large body gets a cheaper stand-in digest; it only has to be a stable 64-hex value.)
			local sha = if #req.Body > 4 * 1024 * 1024 then SpringLive.sha256(string.sub(req.Body, 1, 65536) .. #req.Body) else SpringLive.sha256(req.Body)
			W.store[key] = { payload = body.payload, sha256 = sha }
			local receipt = { ok = true, path = "results/spring-live/" .. key .. ".json", sha256 = sha, bytes = #req.Body }
			if cfg.receipt then cfg.receipt(body.name, receipt) end
			return { Success = true, StatusCode = 201, Body = token(receipt) }
		end,
	}

	-- SpringLiveCapture double.
	local cap = { engineConfig = { nodes = "config" }, driveNames = { "trend", "immediateReturn", "rangeActivity", "volume",
		"peerRelative", "hourlyContext", "dailyTrend", "regimeStress" } }
	function cap:step(bar)
		W.counts.step += 1
		local i = W.counts.step
		log("step " .. i)
		if cfg.onStep then cfg.onStep(i, W) end
		if coroutine.isyieldable() then coroutine.yield() end
		if cfg.captureFail == i then error("CORRUPT_STEP at bar " .. i) end
		-- recordShift: the capture returns the record of another bar (t one second off).
		local recordBar = if cfg.recordShift == i then { t = bar.t + 1 } else bar
		return { bar = recordBar, feature = { reset = i == 1, ready = i > 11, volatility = 0.0012, drive = { 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8 },
			raw = { 1, 2 }, names = { "x" }, regime = { p = 1 } }, states = { coupled = { vector = { i } }, independent = { vector = { i } }, numeric = { vector = { i } } } }
	end
	function cap:stats()
		return { totalSteps = if cfg.totalSteps then cfg.totalSteps(W) else 12 * W.counts.step, corruptSteps = 0, config = { huge = true },
			maxAbsX = 0.5, notANumber = 0 / 0 }
	end
	function cap:verifyIsolation()
		W.counts.isolation += 1
		log("isolation " .. W.counts.isolation)
		if cfg.isolation then return cfg.isolation(W.counts.isolation) end
		return 0
	end
	W.cap = cap
	local Capture = {
		-- Real contract (src/SpringLiveCapture.luau): replayCheck(rows, {guard, nativeConfig2024, tolerance}) and
		-- new({prehistory, symbol, name, guard, nativeConfig2024}); both refuse without nativeConfig2024.
		replayCheck = function(rows, opts)
			W.counts.replayCheck += 1
			W.replayCheckRows, W.replayCheckOpts = rows, opts
			assert(opts.nativeConfig2024 == W.Frozen.nativeConfig2024, "replayCheck needs the frozen 2024 native config")
			log("replayCheck " .. #rows)
			if cfg.preflight then return cfg.preflight(rows) end
			return { count = #rows, maxAbs = { coupled = 1.5e-4, independent = 2.5e-4, numeric = 0 }, pass = true,
				worst = { coupled = { index = 3, component = 7 } }, isolation = { maxDelta = 0 }, verdict = "matches" }
		end,
		new = function(opts)
			W.counts.captureNew += 1
			W.capOpts = opts
			assert(opts.nativeConfig2024 == W.Frozen.nativeConfig2024, "SpringLiveCapture.new needs the frozen 2024 native config")
			log("capture.new")
			return cap
		end,
	}

	-- SpringLiveSession double.
	local SM = {}
	SM.__index = SM
	local function newSession(n)
		local s = setmetatable({ n = 0, pending = {}, rowsByRun = {}, barsArr = { t = {}, o = {}, h = {}, l = {}, c = {} } }, SM)
		for _, id in RUN_IDS do s.rowsByRun[id] = {} end
		for i = 1, n or 0 do
			s.n = i
			for _, id in RUN_IDS do table.insert(s.rowsByRun[id], { fa = "HOLD", po = 0, eq = 1 }) end
			for _, k in { "t", "o", "h", "l", "c" } do table.insert(s.barsArr[k], bars[i][k]) end
		end
		return s
	end
	function SM:step(input)
		W.counts.decide += 1
		local i = self.n + 1
		log("decide " .. i)
		if cfg.decisionFail == i then error("ledger assertion at " .. i) end
		W.lastInput = input
		if i <= W.sessionOpts.leadInRows then
			local saved = W.sessionOpts.saved2024(i)
			assert(saved and saved.index == i and saved.t == input.bar.t, "saved2024 mismatch at " .. i)
			-- The session compares numeric arrays exactly: they must be the exact hex values, never drifted JSON numbers.
			assert(type(saved.numeric) == "table" and #saved.numeric == 51 and saved.numeric[51] == savedValue(i, 51)
				and saved.coupled[1] == savedValue(i, 1) and saved.drive[8] == savedDrive(i, 8), "saved2024 must carry the exact values at " .. i)
			W.counts.saved += 1
		end
		self.n = i
		for _, id in RUN_IDS do
			table.insert(self.rowsByRun[id], { fa = if i % 7 == 0 then "BUY" elseif i % 7 == 3 then "CLOSE" else "HOLD", po = 0, eq = 1 })
		end
		for _, k in { "t", "o", "h", "l", "c" } do table.insert(self.barsArr[k], input.bar[k]) end
		table.insert(self.pending, i)
		return if cfg.badIndex == i then i + 1 else i
	end
	function SM:drainChunk()
		W.counts.drain += 1
		local first, last = self.pending[1], self.pending[#self.pending]
		log("drain " .. tostring(first) .. "-" .. tostring(last))
		self.pending = {}
		if first == nil then return nil end -- the real session returns nil when nothing was decided since the last drain
		return { firstIndex = first, lastIndex = last, score = if cfg.chunkNaN then 0 / 0 else 0.1 + 0.2,
			states = { coupled = { "000000000000f03f" } }, blob = if cfg.chunkBlob then string.rep("a", cfg.chunkBlob) else nil }
	end
	function SM:displayRow(runId, i)
		if cfg.displayFail then error("displayRow broke") end
		assert(i >= 1 and i <= self.n, "displayRow beyond decided rows")
		if not cfg.fullRows then return { index = i, runId = runId } end
		local zeros = table.create(24, 0)
		local bar = bars[i]
		return { index = i, t = bar.t, availableT = bar.availableT, label = bar.label, day = bar.day, partition = "evaluation",
			runId = runId, runKind = "recorded_native", runLabel = runId,
			header = "Recorded native physics · 5-minute observations · no live simulation.", sampleId = runId .. ":" .. i,
			x = zeros, v = zeros, diagnostics = { valid = true, score = 0.01, bankScores = { 0.01, 0, -0.01 }, nodeContributions = zeros },
			thresholds = { entry = 0.11277320613367355, exit = 0.0507479427601531, bankDeadband = 0.028193301533418386 },
			policy = { setup = "none", warmup = 12, posConfirm = 0, negConfirm = 0, longExit = 0, shortExit = 0 },
			intent = { action = "HOLD", source = "physics", reason = "no_setup" },
			final = { action = "HOLD", source = "physics", reason = "no_setup", overridden = false, riskConditions = {} },
			position = 0, holdBars = 0, equity = 1, executions = {},
			evidence = { implementationStatus = "verified", physicsDependence = "pending", marketEvidence = "forward_test_predeclared" } }
	end
	function SM:runs()
		local list = {}
		for _, id in RUN_IDS do
			table.insert(list, { id = id, kind = if cfg.fullRows then "recorded_native" else "live_native", label = id, header = "h", rowCount = self.n })
		end
		return list
	end
	function SM:context(runId, compareId) return { rowCount = self.n, runId = runId, compareId = compareId } end
	function SM:rows(runId) return self.rowsByRun[runId] end
	function SM:bars() return self.barsArr end
	function SM:summary() return { coupled = { netReturn = 0.012345678901234567 } } end
	function SM:evidence() return { marketEvidence = "forward_test_predeclared" } end
	-- Real contract (src/SpringLiveSession.luau): status in_progress | pass | differs | not_checked, plus label.
	function SM:reproducibility()
		if cfg.reproFail then error("reproducibility broke") end
		W.counts.repro = (W.counts.repro or 0) + 1
		W.reproAt = W.reproAt or {}
		table.insert(W.reproAt, self.n)
		local leadIn = W.sessionOpts.leadInRows
		if self.n < leadIn then return { status = "in_progress", label = "lead-in comparison in progress", maxAbs = { coupled = 0 } } end
		-- decisionRows: the session's L20-style comparison of the lead-in decision rows with the offline 2024 result.
		local decisionRows = if cfg.decisionDiffers
			then { status = "differs", rowDifferences = 3, label = "3 of 20 lead-in rows differ from the offline 2024 result" }
			else { status = "pass", rowDifferences = 0, label = "all 20 lead-in decision and ledger rows equal the offline 2024 result" }
		if cfg.reproDiffers then
			return { status = "differs", pass = false, label = "re-captured physics differs from the 2024 calibration capture",
				maxAbs = { coupled = 0.004, independent = 0, numeric = 0 }, decisionRows = decisionRows }
		end
		return { status = "pass", pass = true, label = "lead-in re-capture matches the 2024 calibration capture", maxAbs = { coupled = 0 },
			decisionRows = decisionRows }
	end
	local Session = {
		new = function(opts)
			W.sessionOpts = opts
			log("session.new")
			if cfg.sessionNewFail then error("descriptor mismatch") end
			W.session = newSession(0)
			return W.session
		end,
		-- Real contract: SpringLiveSession.regenerate(opts, chunks) --> session, report{pass, rows, chunks, totalRowDifferences}.
		regenerate = function(opts, chunks)
			log("regenerate " .. #chunks)
			W.regenerateArgs = { chunks = chunks, opts = opts }
			local rows = chunks[#chunks].lastIndex
			return newSession(rows), { pass = not cfg.regenerateFails, rows = rows, chunks = #chunks,
				totalRowDifferences = if cfg.regenerateFails then 3 else 0, chunkFieldMismatches = {}, problems = {} }
		end,
	}

	-- UI doubles with the real signatures (SpringReplayView.mount(parent, descriptor, options), SpringPanel.mount(parent,
	-- {descriptor, callbacks, env}), SpringChart.mount(parent, {rightInset, env}); update/destroy as in src/).
	W.Frozen = table.freeze({ schema = "spring-frozen-v1", resultSha256 = "3fdcd3b57e0b9224117169c24a23ee8724efbfc968b7811f06a682f2bd0a5d6d",
		pins = table.freeze({ entry = "c58d3570b4debc3f", exit = "98fffc64a2fba93f", bankDeadband = "c58d3570b4de9c3f" }),
		protocolId = "spring-consensus-v1", resultName = "RoAlgoV3_spring_v1_1791220038839.json",
		nativeConfig2024 = table.freeze({ schema = "roalgo-mechanics-v2-1" }),
		descriptor = table.freeze({ schema = "spring-v2-descriptor-1", driveNames = table.freeze({ "trend" }) }),
		frozenState = table.freeze({ sampleId = "coupled:12" }) })
	local View = {
		mount = function(parent, descriptor, options)
			assert(parent == W.workspace and descriptor == W.Frozen.descriptor and type(options) == "table", "view mount arguments")
			log("mount view")
			local model = Node.new("Model", "RoAlgoSpringReplay")
			model:SetAttribute("FocusPosition", { focus = true })
			model:SetAttribute("ViewPosition", { view = true })
			model:SetAttribute("ViewFieldOfView", 40)
			model.Parent = W.workspace
			local v = { model = model }
			function v:update(row)
				log("view " .. row.index)
				if cfg.viewFail then error("view rejected the row") end
			end
			function v:destroy() log("view.destroy"); model:Destroy() end
			return v
		end,
	}
	local Panel = {
		WIDTH = 440,
		mount = function(parent, options)
			assert(parent == W.CoreGui and options.descriptor == W.Frozen.descriptor, "panel mount arguments")
			log("mount panel")
			W.callbacks = options.callbacks
			local p = {}
			function p:setRuns(runs) W.panelRuns = runs end
			function p:update(row, compareRow, context)
				assert(type(context) == "table" and context.rowCount >= row.index, "panel context.rowCount must cover the row")
				W.panelRow, W.panelCompare = row, compareRow
				log("panel " .. row.index .. " " .. row.runId .. " vs " .. (if compareRow then compareRow.runId else "-"))
			end
			function p:setStatus(text) W.statusLine = text end
			function p:setPlaying(playing) W.panelPlaying = playing end
			function p:destroy() log("panel.destroy") end
			return p
		end,
	}
	local Chart = {
		mount = function(parent, options)
			assert(parent == W.CoreGui and options.rightInset == 452, "chart mount arguments")
			log("mount chart")
			local c = {}
			function c:update(i, barsTable, rows, info)
				assert(#rows == #barsTable.t and i >= 1 and i <= #rows, "chart rows/bars must cover the cursor")
				assert(type(info) == "table" and type(info.runLabel) == "string", "chart info")
				log("chart " .. i)
				if cfg.chartFail then error("chart broke") end
			end
			function c:destroy() log("chart.destroy") end
			return c
		end,
	}

	W.sources = {}
	for _, name in SpringLive.SOURCE_MODULES do
		local source = "-- " .. name .. " source\nreturn {}\n"
		W.sources[name] = source
	end
	W.deps = {
		Http = W.Http, CoreGui = W.CoreGui, workspace = W.workspace,
		RunService = { IsRunning = function() return cfg.playMode == true end, Heartbeat = S.heartbeat },
		spawn = S.spawn, wait = S.wait,
		Instance = { new = function(class) return Node.new(class) end },
		CFrame = { lookAt = function(at, focus) return { at = at, focus = focus } end, new = function(p) return { p = p } end },
		clock = function() W.clock += 1; return 1791300000000 + W.clock end,
		warn = function(message) table.insert(W.warnings, message) end,
		moduleSources = function()
			local out = {}
			for _, name in SpringLive.SOURCE_MODULES do
				local stamp = SpringLive.sha256(W.sources[name])
				if cfg.badStamp == name then stamp = string.rep("0", 64) end
				if cfg.missingModule == name then table.insert(out, { name = name, missing = true })
				else table.insert(out, { name = name, source = W.sources[name], stamped = stamp }) end
			end
			return out
		end,
		modules = { SpringLiveCapture = Capture, SpringLiveSession = Session, SpringFrozenV1 = W.Frozen, SpringReplayView = View,
			SpringPanel = Panel, SpringChart = Chart },
		expect = W.expect,
	}
	return W
end

local function start(W, extra)
	local opts = { planSha256 = string.upper(PLAN_SHA), addendumSha256 = ADDENDUM_SHA, runId = "test_run", deps = W.deps }
	for k, v in extra or {} do opts[k] = v end
	W.control = SpringLive.start(opts)
	return W.control
end
local function runOut(W, limit)
	local frames = 0
	while W.S.busy() and frames < (limit or 200000) do W.S.frame(); frames += 1 end
	assert(not W.S.busy(), "the run did not finish")
	return frames
end
local function framesUntil(W, predicate, limit)
	local frames = 0
	while not predicate() and frames < (limit or 100000) do W.S.frame(); frames += 1 end
	assert(predicate(), "condition not reached")
end
local function post(W, name)
	for _, p in W.posts do if p.name == name then return p end end
	return nil
end
local function status(W) return W.control:Invoke("status") end
local function chunkPosts(W)
	local list = {}
	for _, p in W.posts do if string.match(p.name, "^chunk_") then table.insert(list, p) end end
	return list
end

---------------------------------------------------------------------------------------------------------------------
test("encoder writes every double with %.17g, sorted keys and ASCII-only strings", function()
	local text = SpringLive.encode({ b = 0.1, a = -0.0, c = { 1, 2.5, 1735828200 }, d = "é·\n\"\\", e = true, f = false, g = "😀" })
	assert(text == '{"a":-0,"b":0.10000000000000001,"c":[1,2.5,1735828200],"d":"\\u00e9\\u00b7\\n\\"\\\\","e":true,"f":false,"g":"\\ud83d\\ude00"}',
		"unexpected encoding: " .. text)
	-- Round trip: values that need all 17 significant digits must come back bit-identical.
	local values = { 0.1 + 0.2, 1 / 3, 2 ^ -1074, 1.7976931348623157e308, -123.456e-7, 2 ^ 53 + 2, 0.11277320613367355,
		0.0507479427601531, 0.028193301533418386, -1.0262303352355957, 5e-324 * 3 }
	local back = decodeJson(SpringLive.encode({ v = values })).v
	for i, x in values do
		assert(string.pack("<d", back[i]) == string.pack("<d", x), "double " .. i .. " did not round-trip exactly")
	end
	expectError(function() SpringLive.encode({ x = 0 / 0 }) end, "non-finite")
	expectError(function() SpringLive.encode({ x = math.huge }) end, "non-finite")
	expectError(function() SpringLive.encode({ 1, nil, 3 }) end, "sparse")
	expectError(function() SpringLive.encode({ 1, x = 2 }) end, "mixed")
	expectError(function() SpringLive.encode({ x = function() end }) end, "unsupported")
	local cyclic = {}
	cyclic.self = cyclic
	expectError(function() SpringLive.encode(cyclic) end, "cycle")
	expectError(function() SpringLive.encode({ s = "\255\254" }) end, "UTF-8")
end)

test("sha256 matches FIPS 180-4 vectors and Node at every padding boundary", function()
	local vectors = {
		[""] = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
		abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
		["-- SpringPolicy source\nreturn {}\n"] = "1b67094a28961335e7705112750110070671fd3df7091a82ba7052b818e7c5ac",
		["spring · live — 😀"] = "ca27e7f386edac5de57dc42b296b75dd8264556b87a3c50d4015d707a6868c24",
	}
	for message, digest in vectors do assert(SpringLive.sha256(message) == digest, "sha256 mismatch for " .. message) end
	local repeated = {
		[55] = "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
		[56] = "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
		[63] = "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
		[64] = "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
		[65] = "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
		[119] = "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb",
		[120] = "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c",
		[1000000] = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
	}
	for n, digest in repeated do assert(SpringLive.sha256(string.rep("a", n)) == digest, "sha256 mismatch for a x " .. n) end
end)

test("happy path: manifest, pre-flight, plan sealed before bar 1, capture and session built from it, run complete", function()
	local W = makeWorld()
	local control = start(W)
	assert(control.Name == CONTROL and control.Parent == W.CoreGui, "control must be the CoreGui BindableFunction " .. CONTROL)
	local L = W.log
	assert(string.find(W.statusLine, "Exit hides this view only", 1, true), "the first status line says what Exit does")
	local order = { "GET manifest", "CHECK runId test_run", "GET capture-check 1-78", "replayCheck 78", "POST plan", "capture.new",
		"isolation 1", "session.new", "mount view", "mount panel", "mount chart", "camera CFrame" }
	local at = 0
	for _, item in order do
		local i = find(L, item)
		assert(i and i > at, "out of order or missing: " .. item)
		at = i
	end
	-- task.spawn runs the loop until its first yield: bar 1 is in flight (capturing), nothing is decided yet.
	assert(W.counts.step == 1 and W.counts.decide == 0 and find(L, "step 1") > find(L, "camera CFrame"), "only bar 1 in flight at return")
	assert(status(W).phase == "running" and status(W).busy == true and status(W).running == true, "status must say running")
	runOut(W)
	local plan = post(W, "plan")
	assert(find(W.log, "POST plan") < find(W.log, "step 1"), "the plan must be sealed before bar 1")
	assert(W.sessionOpts.planSha256 == W.store["test_run/plan"].sha256, "the session must carry the plan seal's sha256")
	assert(W.sessionOpts.leadInRows == 20 and W.sessionOpts.frozen == W.Frozen and type(W.sessionOpts.saved2024) == "function"
		and W.sessionOpts.runId == "test_run", "session options")
	assert(W.sessionOpts.engineConfig == W.cap.engineConfig and W.sessionOpts.driveNames == W.cap.driveNames, "session identity from the capture")
	assert(W.capOpts.name == "RoAlgoSpringLiveRig" and W.capOpts.symbol == "SPY" and W.capOpts.prehistory == W.manifest.prehistory
		and type(W.capOpts.guard) == "function", "capture options")
	assert(W.counts.step == #W.bars and W.counts.decide == #W.bars, "every bar stepped and decided exactly once")
	-- The session receives exactly the contract input: 8 bar fields, 4 feature fields, the engine states.
	local input = W.lastInput
	local barKeys, featureKeys = {}, {}
	for k in input.bar do table.insert(barKeys, k) end
	for k in input.feature do table.insert(featureKeys, k) end
	table.sort(barKeys); table.sort(featureKeys)
	assert(table.concat(barKeys, ",") == "availableT,c,day,h,l,label,o,t", "bar fields: " .. table.concat(barKeys, ","))
	assert(table.concat(featureKeys, ",") == "drive,ready,reset,volatility", "feature fields: " .. table.concat(featureKeys, ","))
	assert(input.states.coupled.vector[1] == #W.bars, "states pass through from the capture record")
	local s = status(W)
	assert(s.phase == "complete" and s.running == false and s.busy == false and s.decided == #W.bars, "final status")
	assert(W.posts[#W.posts].name == "manifest" and W.posts[#W.posts].payload.status == "complete", "the manifest goes last")
	assert(plan and plan.payload.runId == "test_run", "plan payload")
	assert(#W.warnings == 0, "no warnings on the happy path")
	assert(control.Parent == W.CoreGui, "the control stays after the run for a final status read")
	assert(control:Invoke("exit") == true and control.Parent == nil, "exit after the run removes the control")
end)

test("plan seal carries both plan hashes, SpringFrozenV1 pins, Source receipts, pre-flight and the bar universe", function()
	local W = makeWorld()
	start(W)
	runOut(W)
	local plan = post(W, "plan").payload
	assert(plan.schema == "roalgo-spring-live-plan-1" and plan.planSha256 == PLAN_SHA and plan.addendumSha256 == ADDENDUM_SHA, "plan hashes (lower-cased)")
	assert(plan.frozen.resultSha256 == W.Frozen.resultSha256 and plan.frozen.pins.entry == "c58d3570b4debc3f"
		and plan.frozen.pins.exit == "98fffc64a2fba93f" and plan.frozen.frozenSampleId == "coupled:12", "frozen pins")
	assert(#plan.modules == #SpringLive.SOURCE_MODULES, "one receipt per module")
	for k, receipt in plan.modules do
		local name = SpringLive.SOURCE_MODULES[k]
		assert(receipt.name == name and receipt.bytes == #W.sources[name] and receipt.sha256 == SpringLive.sha256(W.sources[name]), "receipt " .. name)
		if name == "SpringPolicy" then
			assert(receipt.sha256 == "1b67094a28961335e7705112750110070671fd3df7091a82ba7052b818e7c5ac", "SpringPolicy receipt equals Node's sha256")
		end
	end
	local u = plan.barUniverse
	assert(u.datasetId == "test-dataset" and u.bars == #W.bars and u.pageCount == W.manifest.pageCount and u.captureRows == 20
		and u.liveStartIndex == 21 and u.liveStartT == W.bars[21].t and u.sessions == 12, "bar universe")
	assert(plan.preflight.pass == true and plan.preflight.count == 78 and plan.preflight.maxAbs.coupled == 1.5e-4
		and plan.preflight.maxAbs.numeric == 0, "pre-flight result in the seal")
	assert(string.find(plan.physicsLabel, "matched", 1, true), "physics label")
	assert(plan.frozen.protocolId == "spring-consensus-v1" and plan.frozen.resultName == W.Frozen.resultName, "frozen identity")
	assert(plan.preflight.worst.coupled.index == 3 and plan.preflight.verdict == "matches", "replayCheck details disclosed")
	assert(W.replayCheckOpts.tolerance == 0.002 and type(W.replayCheckOpts.guard) == "function", "replayCheck options")
	assert(#W.replayCheckRows == 78 and W.replayCheckRows[78].index == 78 and W.replayCheckRows[1].reset == true, "pre-flight rows 1..78")
	local row = W.replayCheckRows[40]
	assert(row.numeric == hexOf((function() local v = {} for k = 1, 51 do v[k] = savedValue(40, k) end return v end)())
		and #row.drive == 128 and #row.coupled == 816, "pre-flight rows carry the exact hex, not the JSON numbers")
	assert(plan.preflight.jsonDecode.values == 78 * (8 + 3 * 51) and plan.preflight.jsonDecode.mismatches == 0, "JSONDecode precision measured")
end)

test("JSONDecode drift is measured and disclosed, never used: pre-flight and lead-in see the exact hex values", function()
	local W = makeWorld({ decodeNoise = true })
	start(W)
	runOut(W)
	assert(status(W).phase == "complete" and W.counts.saved == 20, "the session saw exact saved values on every lead-in row")
	local plan = post(W, "plan").payload
	assert(plan.preflight.jsonDecode.mismatches == 78 * (8 + 3 * 51) and plan.preflight.pass == true,
		"drift counted (" .. plan.preflight.jsonDecode.mismatches .. ")")
	local row = W.replayCheckRows[5]
	assert(type(row.numeric) == "string" and type(row.coupled) == "string" and type(row.independent) == "string"
		and type(row.drive) == "string", "replayCheck receives hex for the drive and all three variants")
	-- saved2024 hands the session exact values for the drive and every variant (the session double asserts drive[8],
	-- coupled[1] and numeric[51]; here every slot of row 7 is checked).
	local saved = W.sessionOpts.saved2024(7)
	for k = 1, 8 do assert(saved.drive[k] == savedDrive(7, k), "exact drive " .. k) end
	for _, variant in { "coupled", "independent", "numeric" } do
		for k = 1, 51 do assert(saved[variant][k] == savedValue(7, k), "exact " .. variant .. " " .. k) end
	end
end)

test("a module Source that differs from its stamped sha256, or a missing module, refuses before the seal", function()
	for _, case in { { badStamp = "SpringPolicy" }, { missingModule = "SpringFrozenV1" } } do
		local W = makeWorld(case)
		start(W)
		runOut(W)
		local s = status(W)
		assert(s.phase == "aborted" and s.stage == "seal", "phase " .. tostring(s.phase) .. " stage " .. tostring(s.stage))
		assert(string.find(s.reason, case.badStamp or case.missingModule, 1, true), "reason names the module: " .. s.reason)
		assert(post(W, "plan") == nil and post(W, "manifest") == nil and W.counts.captureNew == 0 and W.counts.step == 0,
			"nothing sealed, built or stepped")
		-- L4: the failed attempt is still on disk, as a write-once attempt record (never a manifest).
		assert(#W.posts == 1 and string.match(W.posts[1].name, "^attempt_%d+$"), "one attempt record")
		local a = W.posts[1].payload
		assert(a.schema == "roalgo-spring-live-attempt-1" and a.status == "not_started" and a.stage == "seal" and a.phase == "aborted"
			and string.find(a.reason, case.badStamp or case.missingModule, 1, true) and a.planSha256 == PLAN_SHA
			and a.preflight.pass == true and a.barUniverse.datasetId == "test-dataset", "attempt record contents")
		assert(s.attempt.name == W.posts[1].name and s.attempt.sha256 == W.store["test_run/" .. W.posts[1].name].sha256, "status names the record")
	end
end)

test("start refuses without both plan hashes, with a bad runId, or in Play mode", function()
	local W = makeWorld()
	expectError(function() SpringLive.start({ addendumSha256 = ADDENDUM_SHA, deps = W.deps }) end, "planSha256")
	expectError(function() SpringLive.start({ planSha256 = PLAN_SHA, deps = W.deps }) end, "addendumSha256")
	expectError(function() SpringLive.start({ planSha256 = "abc", addendumSha256 = ADDENDUM_SHA, deps = W.deps }) end, "planSha256")
	expectError(function() start(W, { runId = "../escape" }) end, "runId")
	expectError(function() start(W, { runId = "CON" }) end, "runId")
	local P = makeWorld({ playMode = true })
	expectError(function() start(P) end, "Edit mode")
	assert(#W.log == 0 and #P.log == 0, "a refused start touches nothing")
end)

test("pages are fetched one ahead: page k+1 is requested before page k is stepped and never earlier", function()
	for _, latency in { false, true } do
		local W = makeWorld({ pageLatency = latency })
		start(W)
		runOut(W)
		local L = W.log
		local pageSize, pages = W.manifest.pageSize, W.manifest.pageCount
		assert(count(L, "GET page ") == pages, "each page exactly once")
		for k = 1, pages - 1 do
			local firstOfK = (k - 1) * pageSize + 1
			local getNext = find(L, "GET page " .. (k + 1))
			assert(getNext < find(L, "step " .. firstOfK), "page " .. (k + 1) .. " must be requested before page " .. k .. " is stepped")
			assert(getNext > find(L, "GET page " .. k), "pages are requested in order")
			if k >= 2 then
				assert(getNext > find(L, "step " .. ((k - 1) * pageSize)), "page " .. (k + 1) .. " requested more than one page ahead")
			end
			-- Only the request runs ahead: page k+1 is decoded in the loop between its predecessor's last bar and its first.
			local decodeNext = find(L, "decode page " .. (k + 1))
			assert(count(L, "decode page " .. (k + 1)) == 1 and decodeNext > find(L, "decide " .. (k * pageSize))
				and decodeNext < find(L, "step " .. (k * pageSize + 1)), "page " .. (k + 1) .. " decoded between bars")
		end
		assert(find(L, "decode page 1") < find(L, "step 1"), "page 1 decoded before bar 1")
		assert(status(W).phase == "complete", "latency " .. tostring(latency) .. " run completes")
	end
end)

test("page contiguity, dataset id and bar checks abort the run with the decided rows saved", function()
	local cases = {
		{ cfg = { mutatePage = function(p) if p.page == 3 then p.firstIndex += 1; p.lastIndex += 1 end end }, needle = "contiguous", decided = 32 },
		{ cfg = { mutatePage = function(p) if p.page == 2 then p.datasetId = "other" end end }, needle = "dataset", decided = 16 },
		{ cfg = { mutatePage = function(p) if p.page == 2 then p.bars[3] = table.clone(p.bars[3]); p.bars[3].availableT += 1 end end },
			needle = "availableT", decided = 18 },
		-- Only firstIndex is wrong (lastIndex and the bars are right).
		{ cfg = { mutatePage = function(p) if p.page == 3 then p.firstIndex += 1 end end }, needle = "contiguous", decided = 32 },
		-- A repeated timestamp in the forward test (bar 34 is a copy of bar 33).
		{ cfg = { mutatePage = function(p) if p.page == 3 then p.bars[2] = table.clone(p.bars[1]) end end },
			needle = "strictly increasing", decided = 33 },
		-- The forward test must start at liveStartT (row 21 here; 2269 in L1): row 21 moved by one minute.
		{ cfg = { mutatePage = function(p)
			if p.page == 2 then p.bars[5] = table.clone(p.bars[5]); p.bars[5].t += 60; p.bars[5].availableT += 60 end
		end }, needle = "forward test does not start", decided = 20 },
		-- All bars arrive but the session count differs from the universe.
		{ cfg = { mutateExpect = function(e) e.sessions = 13 end }, needle = "saw 12 sessions, expected 13", decided = 69 },
	}
	for _, case in cases do
		local W = makeWorld(case.cfg)
		start(W)
		runOut(W)
		local s = status(W)
		assert(s.phase == "aborted" and s.stage == "data" and string.find(s.reason, case.needle, 1, true), "data abort: " .. tostring(s.reason))
		assert(W.counts.step == case.decided and s.decided == case.decided, "stopped after " .. case.decided .. " bars, got " .. W.counts.step)
		local m = post(W, "manifest").payload
		assert(m.status == "aborted" and m.stage == "data" and m.lastIndex == case.decided and m.lastSavedIndex == case.decided
			and m.unsavedRows == 0, "aborted manifest")
		local chunks = chunkPosts(W)
		assert(chunks[#chunks].payload.lastIndex == case.decided and chunks[#chunks].payload.final == true, "decided rows flushed before the manifest")
	end
	local M = makeWorld({ mutateManifest = function(m) m.bars += 1 end })
	start(M)
	assert(status(M).phase == "aborted" and status(M).stage == "data" and M.counts.replayCheck == 0 and post(M, "plan") == nil,
		"a manifest outside the universe refuses before the pre-flight and the seal")
	assert(#M.posts == 1 and M.posts[1].payload.stage == "data" and string.find(M.posts[1].payload.reason, "bars", 1, true),
		"the refused attempt is recorded")
end)

test("the runId check: a runId with a sealed plan is refused before the pre-flight, without writing into its directory", function()
	local W = makeWorld()
	start(W)
	runOut(W)
	W.control:Invoke("exit")
	local postsBefore = #W.posts
	local mark = #W.log
	local again = start(W)
	local s = again:Invoke("status")
	assert(s.phase == "aborted" and s.stage == "runid" and string.find(s.reason, "already has a sealed plan", 1, true), "refused: " .. tostring(s.reason))
	assert(#W.posts == postsBefore and s.attempt.skipped ~= nil, "nothing written into the earlier run's directory")
	local L = table.move(W.log, mark + 1, #W.log, 1, {})
	assert(find(L, "CHECK runId test_run") and find(L, "replayCheck 78") == nil and find(L, "GET capture-check 1-78") == nil, "no pre-flight")
	-- A runId check that cannot be answered stops the start (stage data) and is recorded.
	for _, answer in { 500, "throw" } do
		local F = makeWorld({ runIdCheck = function() return answer end })
		start(F)
		assert(status(F).stage == "data" and F.counts.replayCheck == 0 and post(F, "plan") == nil, "runId check failure " .. tostring(answer))
	end
	-- A plan POST answered 409 (raced by another writer) leaves no attempt record in that directory either.
	local P = makeWorld({ postFail = function(name) if name == "plan" then return 409 end return nil end })
	start(P)
	assert(status(P).stage == "seal" and #P.posts == 1 and status(P).attempt.skipped ~= nil, "plan 409: no attempt record")
	-- A plan POST that fails otherwise is recorded (the directory may be this attempt's own).
	local Q = makeWorld({ postFail = function(name) if name == "plan" then return 500 end return nil end })
	start(Q)
	assert(status(Q).stage == "seal" and #Q.posts == 2 and string.match(Q.posts[2].name, "^attempt_") and status(Q).attempt.sha256,
		"plan 500: attempt recorded")
end)

test("chunk cadence: one chunk per 5 sessions, drained between sessions, hash-chained from the plan", function()
	local W = makeWorld()
	start(W)
	runOut(W)
	local chunks = chunkPosts(W)
	-- 12 sessions: 1-5 (27 bars, session 4 is short), 6-10, 11-12.
	assert(#chunks == 3 and W.counts.drain == 3, "3 chunks expected, got " .. #chunks)
	local spans = { { 1, 27, 5 }, { 28, 57, 5 }, { 58, 69, 2 } }
	for k, span in spans do
		local e = chunks[k].payload
		assert(chunks[k].name == string.format("chunk_%04d", k) and e.seq == k and e.runId == "test_run", "chunk name/seq")
		assert(e.firstIndex == span[1] and e.lastIndex == span[2] and e.sessions.count == span[3], "chunk " .. k .. " span")
		assert(e.chunk.firstIndex == span[1] and e.chunk.lastIndex == span[2], "the session chunk is drained at the session boundary")
		assert(e.isolation.ok == true and e.isolation.maxDelta == 0, "isolation recorded per chunk")
		assert(e.native.totalSteps == 12 * span[2] and e.native.config == nil and e.native.notANumber == "NaN", "native stats (no config, sanitized)")
		assert(e.chunk.score == 0.1 + 0.2, "chunk doubles exact")
	end
	assert(chunks[1].payload.prevSha256 == W.store["test_run/plan"].sha256, "the chain starts at the plan seal")
	assert(chunks[2].payload.prevSha256 == W.store["test_run/chunk_0001"].sha256, "chunk 2 chains to chunk 1")
	assert(chunks[3].payload.prevSha256 == W.store["test_run/chunk_0002"].sha256 and chunks[3].payload.final == true, "chunk 3 chains to chunk 2")
	-- Drained after the last bar of session 5 and before the first bar of session 6.
	local L = W.log
	assert(find(L, "drain 1-27") > find(L, "decide 27") and find(L, "drain 1-27") < find(L, "step 28"), "drain between sessions")
	assert(find(L, "POST chunk_0001") < find(L, "step 28"), "chunk posted before the next session is stepped")
	assert(W.counts.isolation == 5, "isolation at start, at 3 chunks and at the end; got " .. W.counts.isolation)
	local m = post(W, "manifest").payload
	assert(#m.chunks == 3 and m.chunks[3].sha256 == W.store["test_run/chunk_0003"].sha256 and m.lastChunkSha256 == m.chunks[3].sha256, "receipts")
	assert(m.checks.totalSteps.expected == 12 * #W.bars and m.checks.totalSteps.pass == true, "totalSteps == 12 x bars")
	assert(m.summaries.coupled.netReturn == 0.012345678901234567 and m.evidence.marketEvidence == "forward_test_predeclared"
		and m.reproducibility.maxAbs.coupled == 0, "summaries, evidence and reproducibility in the manifest")
	assert(m.planSha256 == W.store["test_run/plan"].sha256 and m.native.config == nil, "manifest plan hash and native stats")
end)

test("a totalSteps mismatch completes the run but flags the manifest", function()
	local W = makeWorld({ totalSteps = function(world) return 12 * world.counts.step - 1 end })
	start(W)
	runOut(W)
	local m = post(W, "manifest").payload
	assert(m.status == "complete_checks_failed" and m.checks.totalSteps.pass == false and m.checks.totalSteps.actual == 12 * #W.bars - 1, "flagged")
	assert(status(W).phase == "complete_checks_failed", "status shows the failed check")
end)

test("a failed chunk POST (HTTP error, 409 or no connection) aborts with an aborted manifest and steps no further", function()
	for _, failure in { 500, 409, "throw" } do
		local W = makeWorld({ postFail = function(name) if name == "chunk_0002" then return failure end return nil end })
		start(W)
		runOut(W)
		local s = status(W)
		assert(s.phase == "aborted" and s.stage == "post", "post abort for " .. tostring(failure) .. ": " .. tostring(s.stage))
		assert(W.counts.step == 57 and W.counts.decide == 57, "no bar after the failed POST (session 11 starts at 58)")
		local m = post(W, "manifest").payload
		assert(m.status == "aborted" and m.stage == "post" and m.lastIndex == 57 and #m.chunks == 1, "aborted manifest")
		assert(m.lastSavedIndex == 27 and m.unsavedRows == 30 and status(W).lastSavedIndex == 27, "rows 28..57 decided but not saved")
		assert(count(W.log, "POST chunk_0002") == 1, "a failed chunk is never retried")
	end
	-- A failed plan seal aborts before anything is built, and no manifest is written into a directory we do not own.
	local P = makeWorld({ postFail = function(name) if name == "plan" then return 409 end return nil end })
	start(P)
	assert(status(P).phase == "aborted" and status(P).stage == "seal" and P.counts.captureNew == 0 and #P.posts == 1, "plan 409")
end)

test("POST receipts are checked: a 2xx reply without ok, with a bad sha256 or byte count aborts the run", function()
	local bad = {
		function(r) r.ok = false end,
		function(r) r.sha256 = "not-a-sha" end,
		function(r) r.sha256 = string.upper(r.sha256) end,
		function(r) r.bytes = 12.5 end,
		function(r) r.bytes = nil end,
	}
	for k, change in bad do
		local W = makeWorld({ receipt = function(name, r) if name == "chunk_0001" then change(r) end end })
		start(W)
		runOut(W)
		local s = status(W)
		assert(s.phase == "aborted" and s.stage == "post" and string.find(s.reason, "invalid receipt", 1, true), "receipt case " .. k .. ": " .. tostring(s.reason))
		assert(W.counts.step == 27 and #post(W, "manifest").payload.chunks == 0, "stopped at the first chunk; the chunk is not counted as saved")
	end
	local P = makeWorld({ receipt = function(name, r) if name == "plan" then r.ok = false end end })
	start(P)
	assert(status(P).stage == "seal" and P.counts.captureNew == 0, "a bad plan receipt refuses the seal")
end)

test("the 48 MB body limit is enforced before sending: an oversize chunk aborts and is never sent", function()
	local W = makeWorld({ chunkBlob = 48 * 1024 * 1024 })
	start(W)
	runOut(W)
	local s = status(W)
	assert(s.phase == "aborted" and s.stage == "post" and string.find(s.reason, "over the 48 MB limit", 1, true), "size abort: " .. tostring(s.reason))
	assert(find(W.log, "POST oversize") == nil and post(W, "chunk_0001") == nil, "the oversize body never reached the server")
	assert(W.counts.step == 27 and post(W, "manifest").payload.status == "aborted", "aborted manifest after the refused chunk")
	-- Just under the limit is sent (the limit is the server's 48 MiB, not less).
	local U = makeWorld({ chunkBlob = 48 * 1024 * 1024 - 4096 })
	start(U)
	framesUntil(U, function() return post(U, "chunk_0001") ~= nil or status(U).phase == "aborted" end)
	assert(post(U, "chunk_0001") ~= nil and find(U.log, "POST oversize") == nil, "a body under 48 MiB is posted: " .. tostring(status(U).reason))
	U.control:Invoke("stop")
	runOut(U)
end)

test("an isolation breach aborts the run: at start, at a chunk (after saving it) and when verifyIsolation throws", function()
	local W = makeWorld({ isolation = function(call) return if call == 3 then 1e-3 else 0 end })
	start(W)
	runOut(W)
	local s = status(W)
	assert(s.phase == "aborted" and s.stage == "isolation" and W.counts.step == 57, "breach at chunk 2 stops before session 11")
	local c2 = post(W, "chunk_0002").payload
	assert(c2.isolation.ok == false and c2.isolation.maxDelta == 1e-3, "the breaching chunk is saved with its isolation result")
	assert(post(W, "manifest").payload.status == "aborted" and post(W, "manifest").payload.stage == "isolation", "aborted manifest")
	local A = makeWorld({ isolation = function(call) return if call == 1 then 2e-6 else 0 end })
	start(A)
	runOut(A)
	assert(status(A).stage == "isolation" and A.counts.step == 0 and post(A, "manifest").payload.status == "aborted", "breach at start")
	local T = makeWorld({ isolation = function(call) if call == 2 then error("snapshot lost") end return 0 end })
	start(T)
	runOut(T)
	assert(status(T).stage == "isolation" and string.find(status(T).reason, "snapshot lost", 1, true), "a throwing check is a breach")
	local E = makeWorld({ isolation = function(call) return if call == 5 then 1e-6 else 0 end })
	start(E)
	runOut(E)
	assert(status(E).phase == "aborted" and status(E).stage == "isolation" and E.counts.step == #E.bars, "a breach at the end (delta 1e-6 is not below the limit)")
end)

test("a decision error aborts at once without flushing; a capture error flushes the decided rows", function()
	local D = makeWorld({ decisionFail = 25 })
	start(D)
	runOut(D)
	local s = status(D)
	assert(s.phase == "aborted" and s.stage == "decision" and D.counts.step == 25 and s.decided == 24, "decision abort at bar 25")
	local m = post(D, "manifest").payload
	assert(m.lastIndex == 24 and #m.chunks == 0 and #chunkPosts(D) == 0, "no flush after a decision error (session state is suspect)")
	assert(m.lastSavedIndex == 0 and m.unsavedRows == 24, "the manifest says no decided row is on disk")
	assert(string.find(m.reason, "ledger assertion at 25", 1, true), "reason carries the error")
	D.control:Invoke("exit")
	expectError(function() SpringLive.replay({ runId = "test_run", deps = D.deps }) end, "saved no rows")
	-- After a chunk was saved, a later decision error leaves rows decided but unsaved; replay shows the saved rows only.
	local D2 = makeWorld({ decisionFail = 40 })
	start(D2)
	runOut(D2)
	local m2 = post(D2, "manifest").payload
	assert(m2.lastIndex == 39 and m2.lastSavedIndex == 27 and m2.unsavedRows == 12 and #m2.chunks == 1, "39 decided, 27 saved")
	D2.control:Invoke("exit")
	local replay = SpringLive.replay({ runId = "test_run", deps = D2.deps })
	local rs = replay:Invoke("status")
	assert(rs.decided == 27 and rs.lastIndex == 39 and rs.unsavedRows == 12 and string.find(D2.statusLine, "12 not saved", 1, true),
		"replay of an aborted run: " .. tostring(D2.statusLine))
	replay:Invoke("exit")
	-- A capture error on the first bar after a flush: nothing new to save, so no empty chunk is drained or posted.
	local F = makeWorld({ captureFail = 28 })
	start(F)
	runOut(F)
	local mf = post(F, "manifest").payload
	assert(status(F).stage == "capture" and F.counts.drain == 1 and #chunkPosts(F) == 1 and mf.lastIndex == 27 and mf.lastSavedIndex == 27
		and not string.find(mf.reason, "not saved", 1, true), "no empty chunk after a flush")
	F.control:Invoke("exit")
	assert(SpringLive.replay({ runId = "test_run", deps = F.deps }):Invoke("status").decided == 27, "and the run replays")
	local I = makeWorld({ badIndex = 10 })
	start(I)
	runOut(I)
	assert(status(I).stage == "decision" and I.counts.step == 10, "a session index out of step is a decision error")
	local C = makeWorld({ captureFail = 40 })
	start(C)
	runOut(C)
	local c = status(C)
	assert(c.phase == "aborted" and c.stage == "capture" and C.counts.decide == 39, "capture abort at bar 40")
	local mc = post(C, "manifest").payload
	assert(mc.lastIndex == 39 and mc.chunks[#mc.chunks].lastIndex == 39, "rows 28..39 flushed before the aborted manifest")
	assert(string.find(mc.reason, "CORRUPT_STEP", 1, true) and mc.native.totalSteps ~= nil, "manifest carries reason and native stats")
	-- The capture must return the record of the bar it was given.
	local R = makeWorld({ recordShift = 9 })
	start(R)
	runOut(R)
	assert(status(R).stage == "capture" and string.find(status(R).reason, "invalid record", 1, true) and R.counts.decide == 8,
		"a record for another bar is a capture error")
end)

test("chunk data stay strict: a non-finite value in a session chunk aborts instead of being rewritten", function()
	local W = makeWorld({ chunkNaN = true })
	start(W)
	runOut(W)
	local s = status(W)
	assert(s.phase == "aborted" and s.stage == "post" and string.find(s.reason, "non-finite", 1, true), "strict chunk encoding: " .. tostring(s.reason))
	assert(post(W, "chunk_0001") == nil and W.counts.step == 27, "nothing written; stopped at the first chunk boundary")
	assert(post(W, "manifest").payload.status == "aborted", "aborted manifest still written (sanitized disclosure)")
end)

test("stop ends the run between bars: the bar in flight completes, nothing after it is stepped", function()
	local W = makeWorld()
	start(W)
	framesUntil(W, function() return status(W).decided == 17 end)
	assert(W.counts.step == 18, "bar 18 is in flight while commands arrive")
	W.control:Invoke("seek", 3)
	assert(W.control:Invoke("play") == true and status(W).playing == true, "playing before stop")
	assert(W.control:Invoke("stop") == true, "stop accepted while running")
	assert(status(W).playing == false and status(W).phase == "stopping", "stop also stops playback")
	runOut(W)
	local s = status(W)
	assert(W.counts.step == 18 and W.counts.decide == 18 and s.decided == 18, "the in-flight bar finishes; no later bar is stepped")
	assert(s.phase == "aborted" and s.stage == "stop" and s.reason == "stopped_by_user", "stopped status")
	local m = post(W, "manifest").payload
	assert(m.status == "aborted" and m.reason == "stopped_by_user" and m.lastIndex == 18, "aborted manifest with the reason")
	assert(m.chunks[#m.chunks].lastIndex == 18, "pending rows flushed before the manifest")
	assert(W.control:Invoke("stop") == false, "stop after the end does nothing")
end)

test("Exit closes the UI only: the run keeps stepping to its manifest and status keeps answering", function()
	for _, via in { "control", "panel" } do
		local W = makeWorld()
		start(W)
		framesUntil(W, function() return status(W).decided == 10 end)
		if via == "control" then assert(W.control:Invoke("exit") == true) else W.callbacks.onExit() end
		local closed = #W.log
		assert(find(W.log, "panel.destroy") and find(W.log, "chart.destroy") and find(W.log, "view.destroy"), "UI destroyed")
		assert(W.control.Parent == W.CoreGui and status(W).running == true and status(W).uiMounted == false, "control and run survive Exit")
		assert(W.control:Invoke("seek", 3) == false and W.control:Invoke("follow") == false, "UI commands answer false after Exit")
		runOut(W)
		for i = closed + 1, #W.log do
			local line = W.log[i]
			assert(not (string.match(line, "^view %d") or string.match(line, "^panel %d") or string.match(line, "^chart %d")), "rendered after Exit: " .. line)
		end
		assert(W.counts.step == #W.bars and status(W).phase == "complete" and post(W, "manifest").payload.status == "complete", "run completed")
		assert(W.control:Invoke("exit") == true and W.control.Parent == nil, "exit after the end removes the control")
	end
end)

test("show brings the UI back after Exit while the run continues, without framing the camera again", function()
	local W = makeWorld()
	start(W)
	framesUntil(W, function() return status(W).decided == 10 end)
	W.control:Invoke("exit")
	framesUntil(W, function() return status(W).decided == 20 end)
	assert(count(W.log, "mount panel") == 1 and status(W).uiMounted == false, "closed")
	assert(W.control:Invoke("show") == true, "show accepted while the run steps")
	local s = status(W)
	assert(s.uiMounted == true and count(W.log, "mount view") == 2 and count(W.log, "mount panel") == 2 and count(W.log, "mount chart") == 2,
		"view, panel and chart mounted again")
	assert(W.panelRow.index == 20 and s.following == true and string.find(W.statusLine, "bar 20/69", 1, true), "following the newest row again")
	assert(#W.camera == 3 and s.cameraFramings == 1, "the camera is not framed a second time")
	assert(#W.panelRuns == 7, "run buttons restored")
	assert(W.control:Invoke("show") == true and count(W.log, "mount panel") == 2, "show while shown mounts nothing")
	framesUntil(W, function() return status(W).decided == 25 end)
	assert(W.panelRow.index == 25 and W.control:Invoke("seek", 4) == 4, "renders and commands work again")
	runOut(W)
	assert(status(W).phase == "complete" and status(W).uiErrors == 0, "run completed")
end)

test("the 2024 showcase reopen button is removed at start and between bars; replay removes it too", function()
	local function launcher(parent)
		local l = Node.new("ScreenGui", "RoAlgoSpringLauncher")
		l.Parent = parent
		return l
	end
	local W = makeWorld({ onStep = function(i, world) if i == 30 then launcher(world.CoreGui) end end })
	local before = launcher(W.CoreGui)
	start(W)
	assert(before.Parent == nil and W.CoreGui:FindFirstChild("RoAlgoSpringLauncher") == nil, "removed at start")
	framesUntil(W, function() return W.counts.step == 30 end)
	assert(W.CoreGui:FindFirstChild("RoAlgoSpringLauncher") ~= nil and status(W).launchersRemoved == 1, "one appeared during bar 30")
	framesUntil(W, function() return W.counts.step == 31 end)
	assert(W.CoreGui:FindFirstChild("RoAlgoSpringLauncher") == nil and status(W).launchersRemoved == 2, "swept before bar 31")
	runOut(W)
	assert(status(W).phase == "complete" and W.counts.step == #W.bars, "the run is untouched")
	W.control:Invoke("exit")
	local again = launcher(W.CoreGui)
	SpringLive.replay({ runId = "test_run", deps = W.deps }):Invoke("exit")
	assert(again.Parent == nil, "replay removes it as well")
end)

test("render errors never abort the run (view, chart and displayRow failures)", function()
	for _, cfg in { { viewFail = true, chartFail = true }, { displayFail = true } } do
		local W = makeWorld(cfg)
		start(W)
		runOut(W)
		local s = status(W)
		assert(s.phase == "complete" and W.counts.step == #W.bars, "the run completes despite UI errors")
		assert(s.uiErrors >= #W.bars and type(s.lastUiError) == "string", "UI errors are counted and shown in status")
		if cfg.viewFail then assert(count(W.log, "panel ") == #W.bars, "a broken view does not stop the panel") end
	end
end)

test("follow shows the newest row; seek/scrub/step leave follow; play catches up and follows again", function()
	local W = makeWorld()
	start(W)
	framesUntil(W, function() return status(W).decided == 12 end)
	assert(W.panelRow.index == 12 and W.panelRow.runId == "coupled" and W.panelCompare.runId == "zero", "following the newest row, coupled vs zero")
	assert(status(W).following == true and string.find(W.statusLine, "following", 1, true), "status line says following")
	assert(W.control:Invoke("seek", 5) == 5 and status(W).following == false and W.panelRow.index == 5, "seek leaves follow")
	local before = count(W.log, "panel ")
	for _ = 1, 6 do W.S.frame(0) end
	assert(status(W).decided == 18 and W.panelRow.index == 5 and count(W.log, "panel ") == before, "no follow renders while viewing a row")
	assert(string.find(W.statusLine, "viewing row 5", 1, true) and string.find(W.statusLine, "bar 18/69", 1, true), "status shows capture and view")
	W.callbacks.onScrub(3)
	assert(status(W).index == 3, "panel scrub")
	W.callbacks.onStep(1)
	assert(status(W).index == 4 and status(W).playing == false, "panel step")
	assert(W.control:Invoke("seek", 999) == status(W).decided, "seek clamps to decided rows")
	W.control:Invoke("seek", 2)
	assert(W.control:Invoke("rate", 4) == 4 and W.control:Invoke("play") == true and W.panelPlaying == true, "play")
	W.S.frame(1) -- 4 rows per second for 1 s
	assert(status(W).index == 6 and status(W).playing == true and status(W).following == false, "play advances over decided rows")
	assert(W.control:Invoke("pause") == true and status(W).playing == false and W.panelPlaying == false, "pause")
	W.S.frame(1)
	assert(status(W).index == 6, "paused cursor stays")
	W.control:Invoke("play")
	W.S.frame(100)
	assert(status(W).following == true and status(W).playing == false and status(W).index == status(W).decided, "play reaching the newest row follows")
	W.control:Invoke("seek", 1)
	assert(W.control:Invoke("follow") == true and status(W).index == status(W).decided and W.panelRow.index == status(W).decided, "follow command")
	assert(W.control:Invoke("compare", "ema_baseline") == true and W.panelCompare.runId == "ema_baseline", "compare")
	assert(W.control:Invoke("run", "independent") == true and W.panelRow.runId == "independent", "run")
	assert(W.control:Invoke("run", "bogus") == false and W.control:Invoke("compare", "live") == false, "unknown runs refused")
	W.callbacks.onRun("numeric")
	assert(W.panelRow.runId == "numeric", "panel run button")
	assert(W.control:Invoke("find", "coupled", "BUY", 1) == 7 and W.control:Invoke("find", "coupled", "BUY", 8) == 14, "find over decided rows")
	assert(#W.panelRuns == 7 and W.panelRuns[1].label == "Coupled" and W.panelRuns[6].label == "EMA base", "short run labels")
	expectError(function() W.control:Invoke("teleport") end, "unknown command")
	-- Play rate is clamped to 0.5..60 rows per second (command and start option).
	assert(W.control:Invoke("rate", 1e9) == 60 and W.control:Invoke("rate", 0) == 0.5 and W.control:Invoke("rate", "fast") == 6, "rate command clamps")
	runOut(W)
	for _, case in { { 1000, 60 }, { 0.01, 0.5 }, { 12, 12 } } do
		local R = makeWorld()
		start(R, { rate = case[1] })
		assert(status(R).rate == case[2], "start rate " .. case[1] .. " -> " .. tostring(status(R).rate))
		runOut(R)
	end
end)

test("the camera is framed once, before the loop, and never written again", function()
	local W = makeWorld()
	start(W)
	local framing = table.clone(W.camera)
	assert(#framing == 3 and framing[1] == "CFrame" and framing[2] == "Focus" and framing[3] == "FieldOfView", "one framing: CFrame, Focus, FOV")
	framesUntil(W, function() return status(W).decided == 30 end)
	W.control:Invoke("seek", 4)
	W.control:Invoke("play")
	W.S.frame(2)
	W.control:Invoke("follow")
	W.control:Invoke("run", "zero")
	W.control:Invoke("exit")
	runOut(W)
	assert(#W.camera == 3 and count(W.log, "camera CFrame") == 1, "no camera write after the framing (" .. #W.camera .. " writes)")
	assert(status(W).cameraFramings == 1, "status reports one framing")
	assert(lastIndexOf(W.log, "camera ") < find(W.log, "step 1"), "framing happens before bar 1")
	local F = makeWorld()
	start(F, { frame = false })
	runOut(F)
	assert(#F.camera == 0, "frame=false never touches the camera")
end)

test("exclusivity (L14): refuses while a v3 control is busy, stops between bars when one turns busy", function()
	local W = makeWorld()
	local market = Node.new("BindableFunction", "RoAlgoMarketControl")
	market.OnInvoke = function(command) assert(command == "status"); return { busy = true } end
	market.Parent = W.CoreGui
	expectError(function() start(W) end, "RoAlgoMarketControl reports busy")
	assert(#W.log == 0 and W.CoreGui:FindFirstChild(CONTROL) == nil, "nothing fetched, no control left behind")

	local B = makeWorld({ onStep = function(i, world) if i == 30 then world.indicatorBusy = true end end })
	local indicator = Node.new("BindableFunction", "RoAlgoIndicatorControl")
	indicator.OnInvoke = function() return { busy = B.indicatorBusy == true } end
	indicator.Parent = B.CoreGui
	start(B)
	runOut(B)
	local s = status(B)
	assert(s.phase == "aborted" and s.stage == "exclusivity" and B.counts.step == 30 and s.decided == 30, "stopped before bar 31")
	assert(string.find(s.reason, "RoAlgoIndicatorControl", 1, true) and post(B, "manifest").payload.lastIndex == 30, "reason and manifest")
	assert(chunkPosts(B)[#chunkPosts(B)].payload.lastIndex == 30, "decided rows flushed")

	local G = makeWorld({ onStep = function(i, world)
		if i == 5 then
			local showcase = Node.new("BindableFunction", "RoAlgoSpringControl")
			showcase.OnInvoke = function() return true end
			showcase.Parent = world.CoreGui
		end
	end })
	start(G)
	runOut(G)
	assert(status(G).stage == "exclusivity" and G.counts.step == 5, "a 2024 showcase appearing mid-run stops the run")
	local P = makeWorld({ onStep = function(i, world)
		if i == 8 then
			local other = Node.new("BindableFunction", CONTROL)
			other.OnInvoke = function() return { running = false } end
			other.Parent = world.CoreGui
		end
	end })
	start(P)
	runOut(P)
	assert(status(P).stage == "exclusivity" and P.counts.step == 8, "a second live controller stops the run")
	local Q = makeWorld()
	local broken = Node.new("BindableFunction", "RoAlgoResearchControl")
	broken.OnInvoke = function() error("no status") end
	broken.Parent = Q.CoreGui
	expectError(function() start(Q) end, "could not be read")
end)

test("old controllers: the 2024 showcase is exited, a stepping live run refuses, an idle one is replaced", function()
	local W = makeWorld()
	local showcase = Node.new("BindableFunction", "RoAlgoSpringControl")
	local exited = false
	showcase.OnInvoke = function(command) if command == "exit" then exited = true; showcase:Destroy(); return true end end
	showcase.Parent = W.CoreGui
	start(W)
	assert(exited and W.CoreGui:FindFirstChild("RoAlgoSpringControl") == nil, "showcase exited first")
	runOut(W)

	local R = makeWorld()
	local running = Node.new("BindableFunction", CONTROL)
	running.OnInvoke = function(command) if command == "status" then return { running = true, runId = "live_1", decided = 99 } end return true end
	running.Parent = R.CoreGui
	expectError(function() start(R) end, "still stepping")
	assert(#R.log == 0, "a stepping live run blocks a second one before any request")

	local I = makeWorld()
	local idle = Node.new("BindableFunction", CONTROL)
	local idleExit = false
	idle.OnInvoke = function(command)
		if command == "status" then return { running = false } end
		if command == "exit" then idleExit = true end
		return true
	end
	idle.Parent = I.CoreGui
	start(I)
	assert(idleExit and idle.Parent == nil, "the idle old control is exited and removed")
	local controls = 0
	for _, child in I.CoreGui:GetChildren() do if child.Name == CONTROL then controls += 1 end end
	assert(controls == 1 and I.CoreGui:FindFirstChild(CONTROL) == I.control, "exactly one live control")
	runOut(I)

	local S = makeWorld()
	local stuck = Node.new("BindableFunction", "RoAlgoSpringControl")
	stuck.OnInvoke = function() return false end
	stuck.Parent = S.CoreGui
	expectError(function() start(S) end, "did not exit")
end)

test("pre-flight (L3a): a failure stops before the seal unless allowed; the controller re-checks the module's verdict", function()
	local failing = function(rows) return { count = #rows, maxAbs = { coupled = 0.01, independent = 1e-4, numeric = 0 }, pass = false } end
	local W = makeWorld({ preflight = failing })
	local control = start(W)
	local s = status(W)
	assert(s.phase == "preflight_failed" and s.stage == "preflight" and s.running == false and s.busy == false, "clear status")
	assert(string.find(s.reason, "coupled 0.01", 1, true), "reason shows the measured difference: " .. s.reason)
	assert(post(W, "plan") == nil and W.counts.captureNew == 0 and not W.S.busy(), "no seal, no capture, no loop")
	assert(#W.warnings == 1 and s.preflight.maxAbs.coupled == 0.01, "the failure is reported")
	-- L4: the failed pre-flight is on disk as a write-once attempt record carrying the measured differences.
	assert(#W.posts == 1 and string.match(W.posts[1].name, "^attempt_") and s.attempt.name == W.posts[1].name, "attempt record")
	local a = W.posts[1].payload
	assert(a.phase == "preflight_failed" and a.stage == "preflight" and a.preflight.maxAbs.coupled == 0.01 and a.preflight.pass == false
		and string.find(a.reason, "coupled 0.01", 1, true) and a.addendumSha256 == ADDENDUM_SHA, "attempt contents")
	assert(control:Invoke("exit") == true and control.Parent == nil, "exit removes the failed control")

	-- The module says pass, but numeric is not exactly 0: the controller still fails it.
	local N = makeWorld({ preflight = function(rows) return { count = #rows, maxAbs = { coupled = 0, independent = 0, numeric = 1e-15 }, pass = true } end })
	start(N)
	assert(status(N).phase == "preflight_failed", "numeric must match exactly")
	local C = makeWorld({ preflight = function(rows) return { count = 77, maxAbs = { coupled = 0, independent = 0, numeric = 0 }, pass = true } end })
	start(C)
	assert(status(C).phase == "preflight_failed", "the count must be 78")
	local T = makeWorld({ preflight = function() error("engine already exists") end })
	start(T)
	assert(status(T).phase == "preflight_failed" and string.find(status(T).reason, "engine already exists", 1, true), "a throwing check fails")

	local A = makeWorld({ preflight = failing })
	start(A, { allowPreflightFail = true })
	assert(string.find(A.statusLine, "WARNING: re-captured physics differs", 1, true) and status(A).physicsWarning ~= nil,
		"an allowed pre-flight failure is shown live from the start")
	runOut(A)
	assert(post(A, "manifest").payload.physicsWarning == "re-captured physics differs from the 2024 calibration capture", "and in the manifest")
	local plan = post(A, "plan").payload
	assert(plan.preflight.pass == false and plan.preflight.allowedToFail == true, "the failed pre-flight is sealed")
	assert(plan.physicsLabel == "re-captured physics differs from the 2024 calibration capture", "L3 label")
	assert(status(A).phase == "complete", "allowed runs continue")

	local K = makeWorld()
	start(K, { preflight = false })
	runOut(K)
	assert(K.counts.replayCheck == 0 and find(K.log, "GET capture-check 1-78") == nil, "pre-flight skipped")
	assert(post(K, "plan").payload.preflight.skipped == true and post(K, "plan").payload.physicsLabel == "pre-flight not run", "skip disclosed")
end)

test("lead-in comparison: saved2024 serves capture-check records for rows 1..captureRows only, checked against the bars", function()
	local W = makeWorld()
	start(W)
	runOut(W)
	assert(W.counts.saved == 20, "every lead-in row compared")
	assert(W.sessionOpts.saved2024(21) == nil and W.sessionOpts.saved2024(0) == nil, "nothing beyond the lead-in")
	assert(W.sessionOpts.saved2024(20).index == 20, "row 20 served")
	assert(count(W.log, "GET capture-check 1-20") == 1, "one block for 20 lead-in rows")
	local B = makeWorld({ mutateCheck = function(records, a, b) if a == 1 and b == 20 then records[12].t += 300 end end })
	start(B)
	runOut(B)
	assert(status(B).stage == "data" and string.find(status(B).reason, "lead-in bar 12", 1, true) and B.counts.step == 11, "t mismatch stops before bar 12")
end)

test("L3b: the lead-in reproducibility is read when the lead-in ends, shown live when it differs, saved in the next chunk", function()
	local W = makeWorld()
	start(W)
	runOut(W)
	assert(W.reproAt[1] == 20 and #W.reproAt == 2, "read once when row 20 (the last lead-in row) is decided, and for the manifest")
	local s = status(W)
	assert(s.leadIn.status == "pass" and s.physicsWarning == nil and #W.warnings == 0, "a passing lead-in shows no warning")
	assert(post(W, "chunk_0001").payload.leadInReproducibility.status == "pass", "the chunk closing the lead-in carries it")
	assert(post(W, "chunk_0002").payload.leadInReproducibility == nil, "only that chunk")
	assert(not string.find(W.statusLine, "WARNING", 1, true), "no warning on the status line")

	local D = makeWorld({ reproDiffers = true })
	start(D)
	framesUntil(D, function() return status(D).decided == 19 end)
	assert(status(D).physicsWarning == nil and not string.find(D.statusLine, "WARNING", 1, true), "nothing to show before the lead-in ends")
	framesUntil(D, function() return status(D).decided == 21 end)
	local label = "re-captured physics differs from the 2024 calibration capture"
	assert(status(D).physicsWarning == label and status(D).leadIn.status == "differs" and status(D).leadIn.maxAbs.coupled == 0.004, "status")
	assert(string.find(D.statusLine, "WARNING: " .. label, 1, true) and string.find(D.statusLine, "bar 21/69", 1, true), "shown live: " .. D.statusLine)
	assert(#D.warnings == 1 and string.find(D.warnings[1], label, 1, true), "logged once")
	runOut(D)
	assert(status(D).phase == "complete", "disclosed, not aborted (L3)")
	assert(post(D, "chunk_0001").payload.leadInReproducibility.status == "differs" and post(D, "manifest").payload.physicsWarning == label,
		"on disk in the chunk and the manifest")
	assert(string.find(D.statusLine, "LIVE RUN COMPLETE", 1, true) and string.find(D.statusLine, label, 1, true), "and on the final status line")

	-- Lead-in decision rows that differ from the offline 2024 result are shown the same way.
	local R = makeWorld({ decisionDiffers = true })
	start(R)
	framesUntil(R, function() return status(R).decided == 21 end)
	assert(status(R).physicsWarning == "3 of 20 lead-in rows differ from the offline 2024 result"
		and string.find(R.statusLine, "WARNING: 3 of 20 lead-in rows differ", 1, true) and #R.warnings == 1, "decision rows shown live")
	runOut(R)
	-- A pre-flight warning (allowed failure) is kept when the lead-in passes, and not logged a second time.
	local P = makeWorld({ preflight = function(rows) return { count = #rows, maxAbs = { coupled = 0.01, independent = 0, numeric = 0 }, pass = false } end })
	start(P, { allowPreflightFail = true })
	runOut(P)
	assert(status(P).physicsWarning == label and #P.warnings == 1 and status(P).leadIn.status == "pass", "pre-flight warning kept")
	-- Both: the warnings are joined.
	local B = makeWorld({ preflight = function(rows) return { count = #rows, maxAbs = { coupled = 0.01, independent = 0, numeric = 0 }, pass = false } end,
		decisionDiffers = true })
	start(B, { allowPreflightFail = true })
	runOut(B)
	assert(status(B).physicsWarning == label .. " · 3 of 20 lead-in rows differ from the offline 2024 result", "joined: " .. tostring(status(B).physicsWarning))
	-- The same label from the pre-flight and the lead-in is shown once.
	local T = makeWorld({ preflight = function(rows) return { count = #rows, maxAbs = { coupled = 0.01, independent = 0, numeric = 0 }, pass = false } end,
		reproDiffers = true })
	start(T, { allowPreflightFail = true })
	runOut(T)
	assert(status(T).physicsWarning == label, "not repeated: " .. tostring(status(T).physicsWarning))
end)

test("background start returns at once and runs setup and loop in its own thread", function()
	local W = makeWorld({ pageLatency = true })
	local control = start(W, { background = true })
	assert(control.Parent == W.CoreGui, "control exists immediately")
	runOut(W)
	assert(status(W).phase == "complete" and W.counts.step == #W.bars, "background run completes")
end)

test("full L1 universe with the pinned EXPECT: 36,402 bars, 469 sessions, 72 pages, 5 lead-in blocks, 94 chunks", function()
	local days = {}
	for d = 1, 469 do days[d] = if d == 9 or d == 26 or d == 150 or d == 250 or d == 400 then 42 else 78 end
	local W = makeWorld({ days = days, captureRows = 2268, pageSize = 512, useRealExpect = true, T0 = 1735828200 - 30 * 86400, quietUi = true })
	assert(#W.bars == 36402 and W.bars[2269].t == 1735828200, "synthetic universe matches L1")
	start(W)
	runOut(W)
	local s = status(W)
	assert(s.phase == "complete" and W.counts.step == 36402 and W.counts.decide == 36402, "complete: " .. tostring(s.reason))
	assert(count(W.log, "GET page ") == 72 and #chunkPosts(W) == 94 and W.counts.drain == 94, "pages and chunks")
	local blocks = { "1-512", "513-1024", "1025-1536", "1537-2048", "2049-2268" }
	for b, block in blocks do
		assert(count(W.log, "GET capture-check " .. block) == 1, "lead-in block " .. block)
		-- Prefetched one block ahead: block b+1 is requested while block b is stepped, never earlier; it is decoded in
		-- the loop between the last bar of block b and the first bar of block b+1.
		if b < #blocks then
			local getNext = find(W.log, "GET capture-check " .. blocks[b + 1])
			assert(getNext < find(W.log, "step " .. (b * 512)), "block " .. (b + 1) .. " requested during block " .. b)
			if b > 1 then assert(getNext > find(W.log, "step " .. ((b - 1) * 512)), "block " .. (b + 1) .. " requested more than one block ahead") end
			local decodeNext = find(W.log, "decode capture-check " .. blocks[b + 1])
			assert(decodeNext > find(W.log, "decide " .. (b * 512)) and decodeNext < find(W.log, "step " .. (b * 512 + 1)),
				"block " .. (b + 1) .. " decoded between bars")
		end
	end
	assert(W.counts.saved == 2268 and W.counts.isolation == 96, "lead-in compared; isolation at start, 94 chunks and end")
	local m = post(W, "manifest").payload
	assert(m.checks.totalSteps.expected == 436824 and m.checks.totalSteps.pass and #m.chunks == 94 and m.lastIndex == 36402, "manifest")
	assert(post(W, "chunk_0094").payload.sessions.count == 4, "the last chunk holds the final 4 sessions")
	local plan = post(W, "plan").payload
	assert(plan.barUniverse.datasetId == SpringLive.EXPECT.datasetId and plan.barUniverse.pageCount == 72, "pinned universe sealed")
	-- A different dataset id is refused by the pinned EXPECT.
	local X = makeWorld({ days = days, captureRows = 2268, pageSize = 512, useRealExpect = true, T0 = 1735828200 - 30 * 86400,
		mutateManifest = function(m2) m2.datasetId = string.rep("0", 64) end })
	start(X)
	assert(status(X).stage == "data" and string.find(status(X).reason, "datasetId", 1, true), "pinned datasetId")
end)

-- Mock Roblox UI environment for the real SpringPanel and SpringChart (adapted from tests/SpringChart.spec.luau).
local function uiMock()
	local R = { created = {} }
	local Inst, methods = {}, {}
	local function signal()
		local s = { handlers = {} }
		function s:Connect(fn)
			local c = { Connected = true }
			table.insert(self.handlers, { fn = fn, c = c })
			function c:Disconnect() self.Connected = false end
			return c
		end
		return s
	end
	local function new(className)
		local i = setmetatable({}, Inst)
		rawset(i, "ClassName", className); rawset(i, "_p", { Name = className }); rawset(i, "_a", {}); rawset(i, "_c", {})
		rawset(i, "_s", {}); rawset(i, "_dead", false)
		table.insert(R.created, i)
		return i
	end
	Inst.__index = function(self, k)
		if methods[k] then return methods[k] end
		if k == "Parent" then return rawget(self, "_parent") end
		if k == "FocusLost" or (type(k) == "string" and string.sub(k, 1, 5) == "Mouse") then
			local s = rawget(self, "_s"); s[k] = s[k] or signal(); return s[k]
		end
		return rawget(self, "_p")[k]
	end
	Inst.__newindex = function(self, k, v)
		if k == "Parent" then
			assert(not rawget(self, "_dead"), "parent locked")
			rawset(self, "_parent", v)
			if v then table.insert(rawget(v, "_c") or rawget(v, "_children"), self) end
			return
		end
		rawget(self, "_p")[k] = v
	end
	function methods:SetAttribute(k, v) rawget(self, "_a")[k] = v end
	function methods:GetAttribute(k) return rawget(self, "_a")[k] end
	function methods:FindFirstChild(name) for _, c in rawget(self, "_c") do if c.Name == name then return c end end return nil end
	function methods:Destroy()
		if rawget(self, "_dead") then return end
		for _, c in table.clone(rawget(self, "_c")) do c:Destroy() end
		rawset(self, "_dead", true); rawset(self, "_parent", nil)
	end
	local function udim(s, o) return { Scale = s or 0, Offset = o or 0 } end
	R.env = {
		Instance = { new = new },
		UDim = { new = udim },
		UDim2 = { new = function(xs, xo, ys, yo) return { X = udim(xs, xo), Y = udim(ys, yo) } end,
			fromOffset = function(x, y) return { X = udim(0, x), Y = udim(0, y) } end,
			fromScale = function(x, y) return { X = udim(x, 0), Y = udim(y, 0) } end },
		Color3 = { fromRGB = function(r, g, b) return { R = r, G = g, B = b } end, new = function(r, g, b) return { R = r, G = g, B = b } end },
		Vector2 = { new = function(x, y) return { X = x, Y = y } end },
		Enum = setmetatable({}, { __index = function(_, g) return setmetatable({}, { __index = function(_, i) return g .. "." .. i end }) end }),
	}
	return R
end

test("with the real SpringPanel and SpringChart: every render is accepted, Exit works, the run is untouched", function()
	local okPanel, RealPanel = pcall(require, "../src/SpringPanel")
	local okChart, RealChart = pcall(require, "../src/SpringChart")
	assert(okPanel and okChart, "real UI modules must load")
	local W = makeWorld({ fullRows = true })
	local R = uiMock()
	W.deps.modules.SpringPanel = RealPanel
	W.deps.modules.SpringChart = RealChart
	W.deps.uiEnv = R.env
	start(W)
	local panelGui, chartGui = W.CoreGui:FindFirstChild("RoAlgoSpringPanel"), W.CoreGui:FindFirstChild("RoAlgoSpringChart")
	assert(panelGui and chartGui, "the real panel and chart mount under CoreGui")
	framesUntil(W, function() return status(W).decided == 40 end)
	assert(status(W).uiErrors == 0, "no UI error with the real modules: " .. tostring(status(W).lastUiError))
	assert(panelGui:GetAttribute("RowIndex") == 40 and chartGui:GetAttribute("Index") == 40, "panel and chart follow the newest row")
	assert(panelGui:GetAttribute("CompareRunId") == "zero" and panelGui:GetAttribute("CompareAligned") == true, "coupled vs zero, aligned")
	assert(string.find(panelGui:GetAttribute("Status"), "LIVE · bar 40/69", 1, true), "live status line on the panel")
	W.control:Invoke("seek", 12)
	assert(panelGui:GetAttribute("RowIndex") == 12 and chartGui:GetAttribute("Index") == 12, "seek shows row 12 in both")
	W.control:Invoke("follow")
	-- Press the panel's own Exit button (its MouseButton1Click handlers).
	local exitHandled = false
	for _, item in R.created do
		if item.Name == "Exit" and item.ClassName == "TextButton" then
			for _, h in rawget(item, "_s").MouseButton1Click.handlers do h.fn(); exitHandled = true end
		end
	end
	assert(exitHandled and status(W).uiMounted == false and rawget(panelGui, "_dead") and rawget(chartGui, "_dead"), "Exit closed the real UI")
	-- "show" mounts the real panel and chart again, following the newest row.
	framesUntil(W, function() return status(W).decided == 50 end)
	assert(W.control:Invoke("show") == true, "show")
	-- (The UI mock's Destroy does not unlink from the Node parent, so look for the live instance.)
	local function liveChild(name)
		local found
		for _, c in W.CoreGui:GetChildren() do if c.Name == name and not rawget(c, "_dead") then found = c end end
		return found
	end
	local panel2, chart2 = liveChild("RoAlgoSpringPanel"), liveChild("RoAlgoSpringChart")
	assert(panel2 and chart2 and panel2 ~= panelGui and not rawget(panel2, "_dead"), "a fresh real panel and chart")
	assert(panel2:GetAttribute("RowIndex") == 50 and chart2:GetAttribute("Index") == 50 and status(W).uiErrors == 0,
		"the remounted UI shows row 50: " .. tostring(status(W).lastUiError))
	runOut(W)
	assert(status(W).phase == "complete" and W.counts.step == #W.bars and status(W).uiErrors == 0, "the run completed after Exit")
end)

test("replay: fetches manifest, plan and every chunk by sha256 along the hash chain; never builds a capture or steps", function()
	local W = makeWorld()
	start(W)
	runOut(W)
	W.control:Invoke("exit")
	local stepsBefore, capturesBefore = W.counts.step, W.counts.captureNew
	local mark = #W.log
	local control = SpringLive.replay({ runId = "test_run", deps = W.deps, index = 5 })
	local L = table.move(W.log, mark + 1, #W.log, 1, {})
	assert(L[1] == "GET chunk manifest" and L[2] == "GET chunk plan sha" and L[3] == "GET chunk chunk_0001 sha"
		and L[4] == "GET chunk chunk_0002 sha" and L[5] == "GET chunk chunk_0003 sha" and L[6] == "regenerate 3", "replay fetch order")
	assert(W.counts.step == stepsBefore and W.counts.captureNew == capturesBefore and W.counts.replayCheck == 1, "no stepping in replay")
	local args = W.regenerateArgs
	assert(args.opts.planSha256 == W.store["test_run/plan"].sha256 and args.opts.runId == "test_run" and args.opts.leadInRows == 20
		and args.opts.engineConfig == W.Frozen.nativeConfig2024 and args.opts.frozen == W.Frozen, "regenerate options")
	assert(#args.chunks == 3 and args.chunks[1].firstIndex == 1 and args.chunks[3].lastIndex == #W.bars, "the session chunks, in order")
	local s = control:Invoke("status")
	assert(s.replay == true and s.decided == #W.bars and s.index == 5 and W.panelRow.index == 5 and s.regenerated.pass == true, "replay viewer")
	assert(control:Invoke("seek", 40) == 40 and control:Invoke("stop") == false, "replay seeks; there is nothing to stop")
	control:Invoke("exit")
	-- A regeneration that differs from the saved rows is refused.
	W.cfg.regenerateFails = true
	expectError(function() SpringLive.replay({ runId = "test_run", deps = W.deps }) end, "do not regenerate exactly")
	W.cfg.regenerateFails = false
	-- A chunk whose envelope seq differs from its place in the manifest is refused.
	W.store["test_run/chunk_0002"].payload.seq = 5
	expectError(function() SpringLive.replay({ runId = "test_run", deps = W.deps }) end, "is not chunk 2")
	W.store["test_run/chunk_0002"].payload.seq = 2
	-- A manifest whose saved-row count does not match the chunks is refused.
	W.store["test_run/manifest"].payload.lastSavedIndex = 68
	expectError(function() SpringLive.replay({ runId = "test_run", deps = W.deps }) end, "chunks cover 69 rows")
	W.store["test_run/manifest"].payload.lastSavedIndex = 69
	-- A broken chain or a tampered chunk is refused.
	W.store["test_run/chunk_0002"].payload.prevSha256 = string.rep("e", 64)
	expectError(function() SpringLive.replay({ runId = "test_run", deps = W.deps }) end, "hash chain")
	W.store["test_run/chunk_0002"].sha256 = string.rep("d", 64)
	expectError(function() SpringLive.replay({ runId = "test_run", deps = W.deps }) end, "409")
end)

-- Integration (2026-10-05): contract L9 moved the live server to port 47627 (47625 is another project's bridge). The
-- controller default must match spring-live-server.mjs DEFAULT_PORT, and the address is a start/replay option.
test("L9 server address: default http://127.0.0.1:47627; opts.baseUrl routes every request; anything else is refused", function()
	local W = makeWorld()
	start(W)
	runOut(W)
	assert(status(W).phase == "complete" and #W.urls > 0, "the default run completes")
	for _, url in W.urls do assert(string.sub(url, 1, 23) == "http://127.0.0.1:47627/", "default server: " .. url) end
	assert(post(W, "plan").payload.controller.server == "http://127.0.0.1:47627", "the plan records the default server")

	local base = "http://127.0.0.1:50123"
	local B = makeWorld({ baseUrl = base })
	start(B, { baseUrl = base })
	runOut(B)
	assert(status(B).phase == "complete", "a run against another port completes")
	local kinds = {}
	for _, url in B.urls do
		assert(string.sub(url, 1, #base + 1) == base .. "/", "every request goes to opts.baseUrl: " .. url)
		local path = string.match(string.sub(url, #base + 1), "^(/[^?]*)")
		local key = if path == "/spring-live/chunk" and string.find(url, "?", 1, true) then "chunk-get" else path
		kinds[key] = (kinds[key] or 0) + 1
	end
	assert(kinds["/spring-live/manifest"] == 1 and kinds["/spring-live/page"] == 5 and kinds["/spring-live/capture-check"] >= 2
		and kinds["chunk-get"] == 1 and kinds["/spring-live/chunk"] == #B.posts, "manifest, pages, capture-check, runId check and POSTs")
	assert(post(B, "plan").payload.controller.server == base, "the plan records opts.baseUrl")
	B.urls = {}
	local r = SpringLive.replay({ runId = "test_run", deps = B.deps, baseUrl = base })
	assert(r:Invoke("status").regenerated.pass == true and #B.urls == 2 + #post(B, "manifest").payload.chunks, "replay reads opts.baseUrl")
	r:Invoke("exit")
	expectError(function() SpringLive.replay({ runId = "test_run", deps = B.deps }) end, "request to another server")

	for _, bad in { "http://localhost:47627", "http://127.0.0.1:47627/", "https://127.0.0.1:47627", "http://10.0.0.1:47627",
		"http://127.0.0.1:0", "http://127.0.0.1:65536", "http://127.0.0.1:047627", "http://127.0.0.1", "http://127.0.0.1:47627/spring-live",
		" http://127.0.0.1:47627", 47627 } do
		local X = makeWorld()
		expectError(function() start(X, { baseUrl = bad }) end, "baseUrl must be http://127.0.0.1:<port>")
		assert(#X.urls == 0 and #X.posts == 0 and X.CoreGui:FindFirstChild(CONTROL) == nil, "refused before any request or control")
		expectError(function() SpringLive.replay({ runId = "test_run", deps = X.deps, baseUrl = bad }) end, "baseUrl must be")
	end
	local M = makeWorld({ baseUrl = "http://127.0.0.1:65535" })
	start(M, { baseUrl = "http://127.0.0.1:65535" })
	runOut(M)
	assert(status(M).phase == "complete", "port 65535 is accepted")
end)

test("the reproducibility command reads the lead-in comparison on demand (UI shown or hidden, live or replay), never per bar", function()
	local F = makeWorld({ mutateManifest = function(m) m.bars = 1 end })
	local failed = start(F)
	assert(status(F).phase == "aborted" and failed:Invoke("reproducibility") == nil, "nil before a session exists")

	local W = makeWorld()
	local control = start(W)
	framesUntil(W, function() return status(W).decided == 5 end)
	assert((W.counts.repro or 0) == 0, "the loop does not read it per bar")
	local r = control:Invoke("reproducibility")
	assert(type(r) == "table" and r.status == "in_progress" and W.counts.repro == 1, "read once, on demand")
	control:Invoke("exit")
	assert(status(W).uiMounted == false and control:Invoke("reproducibility").status == "in_progress", "available while the UI is hidden")
	runOut(W)
	assert(control:Invoke("reproducibility").status == "pass", "after the lead-in: pass")
	W.cfg.reproFail = true
	local broken = control:Invoke("reproducibility")
	assert(broken.status == "error" and string.find(broken.error, "reproducibility broke", 1, true), "a failing read is reported, not raised")
	W.cfg.reproFail = false
	local R = SpringLive.replay({ runId = "test_run", deps = W.deps })
	assert(R:Invoke("reproducibility").status == "pass", "replay answers from the regenerated session")
	R:Invoke("exit")
end)

print("SpringLive: " .. passed .. " tests passed")

-- Lifecycle regression: a lane producer can be inside its next 12-interval bar while the decision front aborts.
test("terminal accounting joins a yielding producer before isolation and manifest on decision error or stop", function()
	for _, cause in { "decision", "stop" } do
		local W = makeWorld({ decisionFail = if cause == "decision" then 1 else nil })
		local nativeSteps, producing, haltRequested = 0, false, false
		local originalStats, originalIsolation = W.cap.stats, W.cap.verifyIsolation
		W.cfg.onStep = function(i)
			if i ~= 1 then return end
			producing = true
			W.S.spawn(function()
				repeat
					for _ = 1, 12 do W.S.wait(); nativeSteps += 1 end
				until haltRequested
				producing = false
			end)
		end
		function W.cap:shutdown()
			haltRequested = true
			while producing do W.S.wait() end
			W.logf("producer joined")
		end
		function W.cap:stats()
			local out = originalStats(self)
			out.globalSteps, out.producing = nativeSteps, producing
			return out
		end
		function W.cap:verifyIsolation()
			if haltRequested then assert(not producing, "terminal isolation must wait for the current native bar") end
			return originalIsolation(self)
		end
		start(W)
		if cause == "stop" then W.control:Invoke("stop") end
		for _ = 1, 3 do W.S.frame() end
		assert(post(W, "manifest") == nil, "manifest must not be sealed halfway through a native bar")
		assert(status(W).busy == true, "joining still owns the active capture")
		runOut(W, 30)
		local terminal = post(W, "manifest").payload
		assert(terminal.status == "aborted" and terminal.native.globalSteps == 12 and terminal.native.producing == false,
			"terminal native counters include the joined 12-interval bar")
		assert(find(W.log, "producer joined") < find(W.log, "POST manifest"), "join precedes the manifest")
		for _ = 1, 5 do W.S.frame() end
		assert(nativeSteps == terminal.native.globalSteps, "no native steps after terminal stats are saved")
	end
end)

test("terminal capture remains reachable after Exit until explicit release; release refuses a running capture", function()
	local W = makeWorld()
	local releases = 0
	function W.cap:release() releases += 1 end
	start(W)
	expectError(function() W.control:Invoke("release") end, "running")
	assert(releases == 0, "a running capture cannot be released")
	runOut(W)
	assert(status(W).captureRetained == true and releases == 0, "completion preserves inspection evidence")
	W.control:Invoke("exit")
	assert(W.control.Parent == W.CoreGui and status(W).uiMounted == false, "Exit retains the cleanup handle")
	expectError(function() start(W, { runId = "another_attempt" }) end, "release")
	assert(W.control:Invoke("release") == true and releases == 1, "explicit terminal release removes owned capture")
	assert(status(W).captureRetained == false and W.control:Invoke("release") == false, "release is idempotent")
	W.control:Invoke("exit")
	assert(W.control.Parent == nil, "released control can exit")
end)

print("SpringLive lifecycle: " .. passed .. " tests passed")

test("a failed shutdown keeps ownership and withholds a terminal manifest whose native counters cannot be trusted", function()
	local W = makeWorld({ decisionFail = 1 })
	function W.cap:shutdown() error("join unavailable") end
	function W.cap:release() error("must stay retained") end
	start(W)
	runOut(W)
	local s = status(W)
	assert(s.phase == "shutdown_failed" and s.busy == true and s.running == false, "shutdown failure remains busy")
	assert(post(W, "manifest") == nil and string.find(s.reason, "join unavailable", 1, true), "no premature terminal receipt")
	expectError(function() W.control:Invoke("release") end, "stopping")
	W.control:Invoke("exit")
	assert(W.control.Parent == W.CoreGui, "failed join keeps its control reachable")
end)

print("SpringLive shutdown fail-safe: " .. passed .. " tests passed")
