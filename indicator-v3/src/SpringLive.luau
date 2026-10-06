-- Spring live forward test: Studio controller (Edit mode, plugin context). spring-live-contract.md W4; decisions
-- L3 (pre-flight), L4 (abort, never recover in place), L8 (run to the last bar), L10 (write-once chunks), L11 (follow /
-- play / scrub, Exit closes the UI only), L13 (live rig isolation), L14 (exclusivity). Written 2026-10-05.
--
-- start(opts):
--   1. exits RoAlgoSpringControl (2024 showcase) and any idle old RoAlgoSpringLiveControl and removes the showcase's
--      reopen button (CoreGui.RoAlgoSpringLauncher, also swept between bars); refuses while another live run is
--      stepping, while Play is running, or while a v3 control reports busy;
--   2. GETs the manifest from the loopback live server (:47627, L9; opts.baseUrl overrides), checks it against the L1 universe and checks that the
--      runId has no plan yet; a failure before the plan seal is recorded as a write-once "attempt_<ms>" record (L4);
--   3. pre-flight (L3a): SpringLiveCapture.replayCheck on capture-check records 1..78; stops with a clear status when it
--      fails, unless opts.allowPreflightFail (then the run is labelled "re-captured physics differs ...");
--   4. seals the plan (POST chunk "plan") BEFORE bar 1: plan and addendum SHA-256s, SpringFrozenV1 pins, module Source
--      receipts (SHA-256 computed here from each ModuleScript's Source), bar universe, pre-flight result;
--   5. builds SpringLiveCapture and SpringLiveSession (the lead-in saved2024 comparison is fed from capture-check pages);
--   6. mounts SpringReplayView, SpringPanel and SpringChart and frames the camera ONCE (never again, never per frame);
--   7. task.spawns the loop: for each bar guard -> cap:step -> session:step -> render when following (pcall: a UI error
--      never aborts); every 5 sessions drainChunk + verifyIsolation + POST; pages are fetched one ahead (the network
--      request runs early, the JSONDecode runs in the loop between bars); after the last lead-in row the session's
--      lead-in reproducibility (L3b) is read and shown live when it differs.
--   8. POSTs the manifest last. Any data, capture, decision, POST, isolation or exclusivity failure ends the run with an
--      "aborted" manifest (L4); lastSavedIndex says how many decided rows are on disk. The control's "stop" ends the run
--      between bars; Exit closes the UI only and "show" brings it back while the run continues.
-- replay({runId}): later playback from the saved, sha256-verified chunks; never builds a capture and never steps.
--
-- POST bodies use the exact encoder below: every number is written with %.17g (17 significant digits identify a double
-- exactly); the session's hex-packed states pass through as strings. Strings are ASCII-only JSON (D18).
-- Every Roblox service, the scheduler and every module dependency is injectable through opts.deps, so
-- tests/SpringLive.spec.luau runs the orchestration in luau.exe with doubles. This module never calls StepPhysics,
-- never touches Workspace.RoAlgoResearchPhysics and never locks the camera.
local SpringLive = {}

-- Default live server (contract L9: port 47627; 47625 belongs to another project's bridge since 2026-10-05 11:56). It must
-- equal spring-live-server.mjs DEFAULT_PORT (tests/spring-live-data.test.mjs checks this line). opts.baseUrl overrides it.
local BASE_URL = "http://127.0.0.1:47627"
local CONTROL_NAME = "RoAlgoSpringLiveControl"
local SHOWCASE_CONTROL = "RoAlgoSpringControl"
local SHOWCASE_LAUNCHER = "RoAlgoSpringLauncher" -- SpringShowcase's reopen button; one click restarts the 2024 showcase
local BUSY_CONTROLS = { "RoAlgoMarketControl", "RoAlgoResearchControl", "RoAlgoIndicatorControl" }
local RIG_NAME = "RoAlgoSpringLiveRig"
local REPLAY_MODEL = "RoAlgoSpringReplay"
local PLAN_SCHEMA = "roalgo-spring-live-plan-1"
local CHUNK_SCHEMA = "roalgo-spring-live-chunk-envelope-1"
local MANIFEST_SCHEMA = "roalgo-spring-live-manifest-1"
local ATTEMPT_SCHEMA = "roalgo-spring-live-attempt-1"
local CHUNK_SESSIONS = 5 -- L10: one chunk per 5 sessions
local PREFLIGHT_ROWS = 78 -- L3a: 2024 records 1..78 (session 1)
local NATIVE_TOLERANCE = 0.002 -- L3a probe tolerance for coupled and independent; numeric must match exactly
local ISOLATION_LIMIT = 1e-6 -- L13
local STEPS_PER_BAR = 12 -- W4 step 8: totalSteps must equal 12 x bars
local CAPTURE_CHECK_BLOCK = 512 -- the server serves at most 512 capture-check records per call
local MAX_BODY_BYTES = 48 * 1024 * 1024
local NAME_PATTERN = "^[%w_%-]+$"
local PHYSICS_DIFFERS = "re-captured physics differs from the 2024 calibration capture" -- L3

-- L1 universe, pinned (spring-live-data.mjs EXPECT, measured 2026-10-05). The run refuses any other universe.
local EXPECT = table.freeze({
	schema = "roalgo-spring-live-data-v1",
	datasetId = "b8a3ce225720691e172ab8216b85bcdff634fb1172ced5325db6d5d4fbb41a26",
	bars = 36402,
	sessions = 469,
	captureRows = 2268,
	liveStartIndex = 2269,
	liveStartT = 1735828200,
	pageSize = 512,
	pageCount = 72,
})

local SHORT_LABELS = table.freeze({ coupled = "Coupled", zero = "Zero", frozen = "Frozen", independent = "Independent",
	numeric = "Numeric", ema_baseline = "EMA base", no_trade = "No trade" })

-- Modules whose Source is hashed into the plan seal (every module the live run executes or displays with).
local SOURCE_MODULES = table.freeze({ "SpringLive", "SpringLiveCapture", "SpringLiveSession", "SpringFrozenV1",
	"SpringV2Engine", "SpringV2Mechanics", "SpringV2Features", "Regime", "VerifiedStepper", "SpringState", "SpringSignals",
	"SpringPolicy", "Execution", "SpringStudy", "SpringReplayView", "SpringPanel", "SpringChart" })
local DEPENDENCIES = table.freeze({ "SpringLiveCapture", "SpringLiveSession", "SpringFrozenV1", "SpringReplayView",
	"SpringPanel", "SpringChart" })

local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function isInteger(x) return finite(x) and x % 1 == 0 end
local function isSha(x) return type(x) == "string" and #x == 64 and string.match(x, "^[0-9a-f]+$") ~= nil end

-- Failures carry the stage that decides how the run ends (L4).
local Fault = {}
Fault.__index = Fault
Fault.__tostring = function(f) return f.stage .. ": " .. f.reason end
local function fault(stage, reason) return setmetatable({ stage = stage, reason = tostring(reason) }, Fault) end
local function raise(stage, reason) error(fault(stage, reason), 0) end
local function asFault(err, stage)
	if getmetatable(err) == Fault then return err end
	return fault(stage, if type(err) == "table" and err.reason then err.reason else tostring(err))
end

---------------------------------------------------------------------------------------------------------------------
-- SHA-256 (FIPS 180-4) over a Lua string; used for the module Source receipts in the plan seal.
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
local WORDS16 = ">" .. string.rep("I4", 16)
local function sha256(message)
	assert(type(message) == "string", "sha256 needs a string")
	local band, bxor, bnot, rrotate, rshift = bit32.band, bit32.bxor, bit32.bnot, bit32.rrotate, bit32.rshift
	local M = 4294967296
	local length = #message
	local bits = length * 8
	message = message .. "\128" .. string.rep("\0", (55 - length) % 64)
		.. string.pack(">I4I4", math.floor(bits / M), bits % M)
	local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
	local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
	local w = table.create(64, 0)
	for offset = 1, #message, 64 do
		w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15], w[16] =
			string.unpack(WORDS16, message, offset)
		for i = 17, 64 do
			local x, y = w[i - 15], w[i - 2]
			local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
			local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
			w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % M
		end
		local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
		for i = 1, 64 do
			local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
			local ch = bxor(band(e, f), band(bnot(e), g))
			local t1 = (h + S1 + ch + K256[i] + w[i]) % M
			local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
			local maj = bxor(band(a, b), band(a, c), band(b, c))
			h, g, f, e, d, c, b, a = g, f, e, (d + t1) % M, c, b, a, (t1 + S0 + maj) % M
		end
		h0, h1, h2, h3 = (h0 + a) % M, (h1 + b) % M, (h2 + c) % M, (h3 + d) % M
		h4, h5, h6, h7 = (h4 + e) % M, (h5 + f) % M, (h6 + g) % M, (h7 + h) % M
	end
	return string.format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
end

---------------------------------------------------------------------------------------------------------------------
-- Exact JSON encoder. Numbers: %.17g (exact for every finite double; JSON.parse in the server reads back the same
-- double). NaN/Infinity, nil holes, mixed or cyclic tables, functions and userdata raise. Keys are sorted; output is
-- ASCII only (non-ASCII becomes \uXXXX, astral code points as surrogate pairs).
local ESCAPES = { [8] = "\\b", [9] = "\\t", [10] = "\\n", [12] = "\\f", [13] = "\\r", [34] = '\\"', [92] = "\\\\" }

local function pathText(path) return "$" .. table.concat(path) end
local function encodeString(s, path)
	if not string.find(s, '[%c"\\\128-\255]') then return '"' .. s .. '"' end
	if utf8.len(s) == nil then error("SpringLive.encode: invalid UTF-8 at " .. pathText(path), 0) end
	local out = { '"' }
	for _, cp in utf8.codes(s) do
		local short = ESCAPES[cp]
		if short then
			table.insert(out, short)
		elseif cp < 0x20 or cp >= 0x7F then
			if cp >= 0x10000 then
				local v = cp - 0x10000
				table.insert(out, string.format("\\u%04x\\u%04x", 0xD800 + bit32.rshift(v, 10), 0xDC00 + bit32.band(v, 0x3FF)))
			else
				table.insert(out, string.format("\\u%04x", cp))
			end
		else
			table.insert(out, string.char(cp))
		end
	end
	table.insert(out, '"')
	return table.concat(out)
end

local function encodeValue(value, path, visiting, out)
	local kind = type(value)
	if kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error("SpringLive.encode: non-finite number at " .. pathText(path), 0)
		end
		table.insert(out, string.format("%.17g", value))
	elseif kind == "string" then
		table.insert(out, encodeString(value, path))
	elseif kind == "boolean" then
		table.insert(out, if value then "true" else "false")
	elseif kind == "table" then
		if visiting[value] then error("SpringLive.encode: cycle at " .. pathText(path), 0) end
		if #path > 64 then error("SpringLive.encode: nesting too deep at " .. pathText(path), 0) end
		local keys, count, maxIndex = {}, 0, 0
		for k in value do
			if type(k) == "string" then
				table.insert(keys, k)
			elseif type(k) == "number" and k == math.floor(k) and k >= 1 then
				count += 1
				if k > maxIndex then maxIndex = k end
			else
				error("SpringLive.encode: unsupported key " .. tostring(k) .. " at " .. pathText(path), 0)
			end
		end
		if #keys > 0 and count > 0 then error("SpringLive.encode: mixed table at " .. pathText(path), 0) end
		visiting[value] = true
		if #keys == 0 then
			if count ~= maxIndex then error("SpringLive.encode: sparse array at " .. pathText(path), 0) end
			table.insert(out, "[")
			for i = 1, maxIndex do
				if i > 1 then table.insert(out, ",") end
				table.insert(path, "[" .. i .. "]")
				encodeValue(value[i], path, visiting, out)
				table.remove(path)
			end
			table.insert(out, "]")
		else
			table.sort(keys)
			table.insert(out, "{")
			for i, k in keys do
				if i > 1 then table.insert(out, ",") end
				table.insert(path, "." .. k)
				table.insert(out, encodeString(k, path))
				table.insert(out, ":")
				encodeValue(value[k], path, visiting, out)
				table.remove(path)
			end
			table.insert(out, "}")
		end
		visiting[value] = nil
	else
		error("SpringLive.encode: unsupported " .. kind .. " at " .. pathText(path), 0)
	end
end

local function encode(value)
	local out = {}
	encodeValue(value, {}, {}, out)
	return table.concat(out)
end

-- Disclosure copy for stats/summaries/receipts: keeps finite numbers exactly, turns non-finite numbers, userdata and
-- unusual keys into strings, so a status report can always be written. Never used for chunk data (those stay strict).
local function sanitize(value, depth, seen)
	depth = depth or 0
	seen = seen or {}
	local kind = type(value)
	if kind == "number" then
		if value ~= value then return "NaN" end
		if value == math.huge then return "Infinity" end
		if value == -math.huge then return "-Infinity" end
		return value
	elseif kind == "string" then
		if utf8.len(value) == nil then return (string.gsub(value, "[\128-\255]", "?")) end
		return value
	elseif kind == "boolean" then
		return value
	elseif kind == "table" then
		if seen[value] then return "<cycle>" end
		if depth > 40 then return "<too deep>" end
		seen[value] = true
		local n, count, hasString = 0, 0, false
		for k in value do
			if type(k) == "number" and k == math.floor(k) and k >= 1 then
				count += 1
				if k > n then n = k end
			else
				hasString = true
			end
		end
		local out = {}
		if not hasString and count == n then
			for i = 1, n do
				local v = sanitize(value[i], depth + 1, seen)
				out[i] = if v == nil then false else v
			end
		else
			for k, v in value do
				local s = sanitize(v, depth + 1, seen)
				if s ~= nil then out[tostring(k)] = s end
			end
		end
		seen[value] = nil
		return out
	elseif kind == "nil" or kind == "function" or kind == "thread" then
		return nil
	end
	local typeName = typeof(value)
	if typeName == "Vector3" then return { x = value.X, y = value.Y, z = value.Z } end
	return "<" .. typeName .. "> " .. tostring(value)
end

local function withoutKey(t, key)
	if type(t) ~= "table" then return t end
	local copy = {}
	for k, v in t do if k ~= key then copy[k] = v end end
	return copy
end

---------------------------------------------------------------------------------------------------------------------
-- Dependencies. Defaults are the Studio services and the sibling ModuleScripts; tests inject doubles.
local function studioSources()
	local out = {}
	for _, name in SOURCE_MODULES do
		local m = script.Parent:FindFirstChild(name)
		if m and m:IsA("ModuleScript") then
			local tag = m:FindFirstChild("SourceSHA256")
			table.insert(out, { name = name, source = m.Source, stamped = m:GetAttribute("sha256") or (tag and tag.Value) })
		else
			table.insert(out, { name = name, missing = true })
		end
	end
	return out
end

local function resolveDeps(injected)
	injected = injected or {}
	assert(type(injected) == "table", "SpringLive: opts.deps must be a table")
	local defaults = {
		Http = function() return game:GetService("HttpService") end,
		CoreGui = function() return game:GetService("CoreGui") end,
		RunService = function() return game:GetService("RunService") end,
		workspace = function() return workspace end,
		spawn = function() return task.spawn end,
		wait = function() return task.wait end,
		Instance = function() return Instance end,
		CFrame = function() return CFrame end,
		clock = function() return function() return DateTime.now().UnixTimestampMillis end end,
		warn = function() return warn end,
		moduleSources = function() return studioSources end,
	}
	local deps = {}
	for name, make in defaults do
		local value = injected[name]
		if value == nil then value = make() end
		deps[name] = value
	end
	deps.modules = injected.modules or {}
	deps.expect = injected.expect or EXPECT
	deps.uiEnv = injected.uiEnv
	deps.baseUrl = injected.baseUrl or BASE_URL
	return deps
end

-- The live server's base URL (L9: the port is a start option of the server, so the controller takes it as an option
-- too): opts.baseUrl, else deps.baseUrl (tests), else BASE_URL. Loopback http only, an explicit port 1..65535, no
-- trailing slash, so every request path is baseUrl .. "/spring-live/...".
local function resolveBaseUrl(opts, deps, who)
	local url = if opts.baseUrl ~= nil then opts.baseUrl else deps.baseUrl
	local port = type(url) == "string" and string.match(url, "^http://127%.0%.0%.1:([1-9]%d*)$") or nil
	assert(port ~= nil and tonumber(port) <= 65535,
		who .. ": baseUrl must be http://127.0.0.1:<port> (loopback only, port 1-65535, no trailing slash); got " .. tostring(url))
	return url
end

local function loadModules(deps)
	local m = {}
	for _, name in DEPENDENCIES do
		local value = deps.modules[name]
		if value == nil then
			if script then
				local instance = script.Parent:FindFirstChild(name)
				assert(instance, "SpringLive: module " .. name .. " is not installed next to SpringLive")
				value = require(instance)
			else
				value = require("./" .. name)
			end
		end
		m[name] = value
	end
	return m
end

---------------------------------------------------------------------------------------------------------------------
-- Loopback live server.
-- The network part (yields) and the JSONDecode (CPU) are separate so a prefetch can fetch early and decode between bars.
local function httpText(deps, path, stage)
	local ok, body = pcall(function() return deps.Http:GetAsync(deps.baseUrl .. path) end)
	if not ok then raise(stage or "data", "GET " .. path .. " failed: " .. tostring(body)) end
	return body
end
local function decodeText(deps, path, body, stage)
	local decoded, value = pcall(function() return deps.Http:JSONDecode(body) end)
	if not decoded or type(value) ~= "table" then raise(stage or "data", "GET " .. path .. " returned invalid JSON") end
	return value
end
local function httpGet(deps, path, stage)
	return decodeText(deps, path, httpText(deps, path, stage), stage)
end

-- L4 needs every attempt reported, so a runId that already holds a plan is refused before the pre-flight: a failed
-- attempt is then recorded only in a directory no other run owns. RequestAsync gives the status code without parsing
-- an error message; 404 means the runId is free.
local function checkRunIdFree(deps, runId)
	local path = "/spring-live/chunk?runId=" .. runId .. "&name=plan"
	local ok, response = pcall(function() return deps.Http:RequestAsync({ Url = deps.baseUrl .. path, Method = "GET" }) end)
	if not ok or type(response) ~= "table" then raise("data", "GET " .. path .. " failed: " .. tostring(response)) end
	if response.StatusCode == 404 then return end
	if response.StatusCode == 200 then raise("runid", "runId " .. runId .. " already has a sealed plan; choose a new runId") end
	raise("data", "GET " .. path .. " -> HTTP " .. tostring(response.StatusCode))
end

local function httpPost(deps, runId, name, payload)
	local encodedOk, body = pcall(encode, { runId = runId, name = name, payload = payload })
	if not encodedOk then raise("post", "encoding " .. name .. ": " .. tostring(body)) end
	if #body > MAX_BODY_BYTES then raise("post", name .. " body is " .. #body .. " bytes, over the 48 MB limit") end
	local ok, response = pcall(function()
		return deps.Http:RequestAsync({ Url = deps.baseUrl .. "/spring-live/chunk", Method = "POST",
			Headers = { ["Content-Type"] = "application/json" }, Body = body })
	end)
	if not ok then raise("post", "POST " .. name .. " failed: " .. tostring(response)) end
	if type(response) ~= "table" or response.Success ~= true or (response.StatusCode ~= 200 and response.StatusCode ~= 201) then
		local code = if type(response) == "table" then tostring(response.StatusCode) else "?"
		local text = if type(response) == "table" then string.sub(tostring(response.Body), 1, 200) else ""
		local f = fault("post", "POST " .. name .. " -> HTTP " .. code .. " " .. text)
		f.httpStatus = if type(response) == "table" then response.StatusCode else nil
		error(f, 0)
	end
	local decoded, receipt = pcall(function() return deps.Http:JSONDecode(response.Body) end)
	if not decoded or type(receipt) ~= "table" or receipt.ok ~= true or not isSha(receipt.sha256) or not isInteger(receipt.bytes) then
		raise("post", "POST " .. name .. " returned an invalid receipt")
	end
	return { name = name, sha256 = receipt.sha256, bytes = receipt.bytes, path = receipt.path, bodyBytes = #body }
end

local function getChunk(deps, runId, name, sha)
	local path = "/spring-live/chunk?runId=" .. runId .. "&name=" .. name .. (if sha then "&sha256=" .. sha else "")
	return httpGet(deps, path, "replay")
end

---------------------------------------------------------------------------------------------------------------------
-- L14 exclusivity. Returns ok, reason. `own` is this controller's BindableFunction (skipped).
local function makeGuard(deps, getOwn)
	return function()
		local CoreGui = deps.CoreGui
		for _, name in BUSY_CONTROLS do
			local control = CoreGui:FindFirstChild(name)
			if control then
				local ok, status = pcall(function() return control:Invoke("status") end)
				if not ok then return false, name .. " status could not be read: " .. tostring(status) end
				if type(status) == "table" and status.busy then return false, name .. " reports busy" end
			end
		end
		if CoreGui:FindFirstChild(SHOWCASE_CONTROL) then return false, SHOWCASE_CONTROL .. " (2024 showcase) is active" end
		local own = getOwn()
		for _, child in CoreGui:GetChildren() do
			if child.Name == CONTROL_NAME and child ~= own then return false, "another " .. CONTROL_NAME .. " is present" end
		end
		return true
	end
end

-- The 2024 showcase leaves a reopen button after a user Exit. One click on it would restart the showcase over the live
-- UI and end the live run through the guard, so the live controller removes it (SpringShowcase's own programmatic
-- takeover does the same). Returns how many were removed.
local function removeLaunchers(CoreGui)
	local removed = 0
	for _, child in CoreGui:GetChildren() do
		if child.Name == SHOWCASE_LAUNCHER then
			if pcall(function() child:Destroy() end) then removed += 1 end
		end
	end
	return removed
end

-- Step 1: exit the 2024 showcase and idle old live controls; refuse while an old live run is still stepping.
local function exitOthers(deps)
	local CoreGui = deps.CoreGui
	local showcase = CoreGui:FindFirstChild(SHOWCASE_CONTROL)
	if showcase then
		pcall(function() showcase:Invoke("exit") end)
		assert(showcase.Parent == nil and CoreGui:FindFirstChild(SHOWCASE_CONTROL) == nil,
			"SpringLive: " .. SHOWCASE_CONTROL .. " did not exit; close the 2024 showcase first")
	end
	local launchers = removeLaunchers(CoreGui)
	assert(CoreGui:FindFirstChild(SHOWCASE_LAUNCHER) == nil, "SpringLive: the 2024 showcase reopen button could not be removed")
	for _, child in CoreGui:GetChildren() do
		if child.Name == CONTROL_NAME then
			local ok, status = pcall(function() return child:Invoke("status") end)
			assert(ok and type(status) == "table", "SpringLive: an old " .. CONTROL_NAME .. " does not answer status; remove it first")
			assert(not status.running and not status.busy, string.format("SpringLive: live run %s is still stepping (bar %s); invoke stop on %s first",
				tostring(status.runId), tostring(status.decided), CONTROL_NAME))
			assert(not status.captureRetained, "SpringLive: the previous capture is retained for inspection; invoke release on " .. CONTROL_NAME .. " first")
			pcall(function() child:Invoke("exit") end)
			if child.Parent ~= nil then child:Destroy() end
		end
	end
	return launchers
end

---------------------------------------------------------------------------------------------------------------------
-- Viewer: the UI, the shared cursor (follow / play / scrub) and the control. Shared by start() and replay().
local function newViewer(deps, modules, options)
	local Frozen = modules.SpringFrozenV1
	local V = {
		state = { viewRun = options.viewRun or "coupled", compareRun = options.compareRun or "zero", index = 0,
			following = true, playing = false, rate = math.clamp(tonumber(options.rate) or 6, 0.5, 60) },
		ui = { mounted = false, errors = 0, lastError = nil },
		labels = {},
		decided = 0,
		session = nil,
		framed = false,
		cameraWrites = 0,
	}
	local state, ui = V.state, V.ui

	local function uiError(where, err)
		ui.errors += 1
		ui.lastError = where .. ": " .. tostring(err)
	end
	local function guarded(where, fn, ...)
		local ok, err = pcall(fn, ...)
		if not ok then uiError(where, err) end
		return ok
	end

	function V.render()
		local session, i = V.session, state.index
		if not ui.mounted or not session or i < 1 or i > V.decided then return false end
		local rowOk, row = pcall(function() return session:displayRow(state.viewRun, i) end)
		if not rowOk then uiError("displayRow", row); return false end
		local compareOk, compareRow = pcall(function() return session:displayRow(state.compareRun, i) end)
		if not compareOk then uiError("displayRow compare", compareRow); compareRow = nil end
		if ui.view then guarded("view", function() ui.view:update(row) end) end
		if ui.panel then
			guarded("panel", function() ui.panel:update(row, compareRow, session:context(state.viewRun, state.compareRun)) end)
		end
		if ui.chart then
			guarded("chart", function()
				ui.chart:update(i, session:bars(), session:rows(state.viewRun),
					{ runLabel = SHORT_LABELS[state.viewRun] or state.viewRun, label = V.labels[i], labels = V.labels })
			end)
		end
		return true
	end

	-- The last status text is kept so a UI brought back with "show" starts with it.
	function V.setStatusLine(text)
		V.statusText = text
		if ui.mounted and ui.panel then guarded("status", function() ui.panel:setStatus(text) end) end
	end

	local function syncPlaying()
		if ui.mounted and ui.panel then guarded("panel playing", function() ui.panel:setPlaying(state.playing) end) end
	end

	-- Moves the cursor over decided rows only; any explicit move leaves follow mode (L11).
	function V.seek(index)
		if V.decided < 1 then return 0 end
		state.following = false
		state.index = math.clamp(math.floor(tonumber(index) or state.index), 1, V.decided)
		V.render()
		return state.index
	end
	function V.setPlaying(playing)
		state.playing = playing == true
		state.following = false
		if state.index < 1 then state.index = math.min(1, V.decided) end
		syncPlaying()
		return state.playing
	end
	function V.follow()
		state.following, state.playing = true, false
		syncPlaying()
		state.index = V.decided
		V.render()
		return true
	end
	-- Called by the capture loop after every decided row.
	function V.onDecided(index, label)
		V.decided = index
		V.labels[index] = label
		if state.following then
			state.index = index
			V.render()
		end
	end
	local function knownRun(id)
		local session = V.session
		if type(id) ~= "string" or not session then return false end
		local ok, runs = pcall(function() return session:runs() end)
		if not ok or type(runs) ~= "table" then return false end
		for _, run in runs do if run.id == id then return true end end
		return false
	end
	function V.selectRun(id)
		if not knownRun(id) then return false end
		state.viewRun = id
		V.render()
		return true
	end
	function V.selectCompare(id)
		if not knownRun(id) then return false end
		state.compareRun = id
		V.render()
		return true
	end
	function V.find(runId, action, from)
		local session = V.session
		if not session or V.decided < 1 then return nil end
		local rows = session:rows(runId or state.viewRun)
		if type(rows) ~= "table" then return nil end
		for i = math.max(1, math.floor(tonumber(from) or 1)), V.decided do
			local r = rows[i]
			if r and r.fa == action then return i end
		end
		return nil
	end

	-- The camera is framed once, from the replay model's view attributes, and never written again (D25, L11).
	local function frameOnce()
		if V.framed or options.frame == false then return end
		V.framed = true
		local model = (ui.view and ui.view.model) or deps.workspace:FindFirstChild(REPLAY_MODEL)
		if not model then return end
		local focus, at = model:GetAttribute("FocusPosition"), model:GetAttribute("ViewPosition")
		if focus == nil or at == nil then return end
		local camera = deps.workspace.CurrentCamera
		if not camera then return end
		camera.CFrame = deps.CFrame.lookAt(at, focus)
		camera.Focus = deps.CFrame.new(focus)
		local fov = model:GetAttribute("ViewFieldOfView")
		if type(fov) == "number" then camera.FieldOfView = fov end
		V.cameraWrites += 1
	end

	function V.mount(session)
		V.session = session
		local descriptor = Frozen.descriptor
		local env = deps.uiEnv
		guarded("view mount", function() ui.view = modules.SpringReplayView.mount(deps.workspace, descriptor, { env = env }) end)
		guarded("panel mount", function()
			ui.panel = modules.SpringPanel.mount(deps.CoreGui, {
				descriptor = descriptor,
				env = env,
				callbacks = {
					onRun = function(id) V.selectRun(id) end,
					onPlay = function() V.setPlaying(true) end,
					onPause = function() V.setPlaying(false) end,
					onStep = function(delta) V.setPlaying(false); V.seek(state.index + (tonumber(delta) or 1)) end,
					onScrub = function(index) V.seek(index) end,
					onExit = function() V.exitUI() end,
				},
			})
			local runs = session:runs()
			local shown = {}
			for k, run in runs do
				local copy = table.clone(run)
				copy.label = SHORT_LABELS[run.id] or run.label
				shown[k] = copy
			end
			ui.panel:setRuns(shown)
		end)
		guarded("chart mount", function()
			local inset = if type(modules.SpringPanel.WIDTH) == "number" then modules.SpringPanel.WIDTH + 12 else 452
			ui.chart = modules.SpringChart.mount(deps.CoreGui, { rightInset = inset, env = env })
		end)
		ui.mounted = true
		guarded("camera", frameOnce)
		local accumulated = 0
		local okBeat, connection = pcall(function()
			return deps.RunService.Heartbeat:Connect(function(dt)
				if not state.playing or not ui.mounted then accumulated = 0; return end
				accumulated += (tonumber(dt) or 0) * state.rate
				if accumulated < 1 then return end
				local steps = math.floor(accumulated)
				accumulated -= steps
				if state.index + steps >= V.decided then
					-- Reaching the newest decided row switches back to following the capture (L11).
					V.follow()
				else
					state.index += steps
					V.render()
				end
			end)
		end)
		if okBeat then ui.heartbeat = connection else uiError("heartbeat", connection) end
		if V.statusText then V.setStatusLine(V.statusText) end
	end

	-- Brings the UI back after Exit (the run never stopped). The camera was framed once and is never framed again. While
	-- hidden, onDecided kept the cursor on the newest row when following, so the view comes back where it should be.
	function V.show()
		if ui.mounted then return true end
		if not V.session then return false end
		V.mount(V.session)
		syncPlaying()
		V.render()
		return true
	end

	-- Closes the UI only (L11): the capture loop, if any, keeps running; status and stop keep working.
	function V.exitUI()
		if not ui.mounted then return true end
		ui.mounted = false
		state.playing = false
		if ui.heartbeat then pcall(function() ui.heartbeat:Disconnect() end) end
		for _, key in { "panel", "chart", "view" } do
			local item = ui[key]
			ui[key] = nil
			if item then pcall(function() item:destroy() end) end
		end
		if options.onExitUI then options.onExitUI() end
		return true
	end

	return V
end

local function reproducibilityOf(session)
	if not session then return nil end
	local ok, value = pcall(function() return session:reproducibility() end)
	if not ok then return { status = "error", error = tostring(value) } end
	return sanitize(value)
end

local function makeControl(deps, viewer, handlers)
	local control = deps.Instance.new("BindableFunction")
	control.Name = CONTROL_NAME
	control.OnInvoke = function(command, ...)
		local args = { ... }
		if command == "status" then return handlers.status() end
		-- On demand (never per bar): the session's L3b/L20 lead-in comparison so far, so the lead can check exact drives
		-- and states after a few bars instead of waiting for row captureRows. nil before the session exists.
		if command == "reproducibility" then return handlers.reproducibility() end
		if command == "stop" then return handlers.stop() end
		if command == "release" then return if handlers.release then handlers.release() else false end
		if command == "exit" then return handlers.exit() end
		if command == "show" then return viewer.show() end
		if not viewer.ui.mounted then
			if command == "run" or command == "compare" or command == "seek" or command == "play" or command == "pause"
				or command == "follow" or command == "rate" or command == "find" then
				return false
			end
		end
		if command == "run" then return viewer.selectRun(args[1])
		elseif command == "compare" then return viewer.selectCompare(args[1])
		elseif command == "seek" then return viewer.seek(args[1])
		elseif command == "play" then return viewer.setPlaying(true)
		elseif command == "pause" then viewer.setPlaying(false); return true
		elseif command == "follow" then return viewer.follow()
		elseif command == "rate" then
			viewer.state.rate = math.clamp(tonumber(args[1]) or 6, 0.5, 60)
			return viewer.state.rate
		elseif command == "find" then return viewer.find(args[1], args[2], args[3])
		end
		error(CONTROL_NAME .. ": unknown command " .. tostring(command))
	end
	control.Parent = deps.CoreGui
	return control
end

---------------------------------------------------------------------------------------------------------------------
local function checkManifest(manifest, expect)
	local problems = {}
	local function need(ok, what) if not ok then table.insert(problems, what) end end
	need(manifest.schema == expect.schema, "schema " .. tostring(manifest.schema))
	need(manifest.datasetId == expect.datasetId, "datasetId " .. tostring(manifest.datasetId))
	need(manifest.bars == expect.bars, "bars " .. tostring(manifest.bars))
	need(manifest.captureRows == expect.captureRows, "captureRows " .. tostring(manifest.captureRows))
	need(manifest.liveStartIndex == expect.liveStartIndex, "liveStartIndex " .. tostring(manifest.liveStartIndex))
	need(manifest.liveStartT == expect.liveStartT, "liveStartT " .. tostring(manifest.liveStartT))
	need(manifest.pageSize == expect.pageSize, "pageSize " .. tostring(manifest.pageSize))
	need(manifest.pageCount == expect.pageCount, "pageCount " .. tostring(manifest.pageCount))
	need(type(manifest.prehistory) == "table", "prehistory missing")
	need(type(manifest.split) == "table", "split missing")
	if #problems > 0 then raise("data", "live manifest differs from the L1 universe: " .. table.concat(problems, "; ")) end
end

local function moduleReceipts(deps)
	local ok, sources = pcall(deps.moduleSources)
	if not ok or type(sources) ~= "table" then raise("seal", "module Sources could not be read: " .. tostring(sources)) end
	local receipts, problems = {}, {}
	for _, item in sources do
		if item.missing or type(item.source) ~= "string" then
			table.insert(problems, tostring(item.name) .. " is not installed")
		else
			local digest = sha256(item.source)
			local stamped = if type(item.stamped) == "string" then string.lower(item.stamped) else nil
			if stamped and stamped ~= digest then
				table.insert(problems, string.format("%s Source sha256 %s differs from its stamped %s", item.name, digest, stamped))
			end
			table.insert(receipts, { name = item.name, bytes = #item.source, sha256 = digest, stamped = stamped or false })
		end
	end
	if #problems > 0 then raise("seal", "module receipts failed: " .. table.concat(problems, "; ")) end
	return receipts
end

local function captureIdentity(cap)
	local config = cap.engineConfig
	if config == nil and type(cap.engine) == "table" then config = cap.engine.config end
	if config == nil then
		local stats = cap:stats()
		config = type(stats) == "table" and stats.config or nil
	end
	local names = cap.driveNames
	if names == nil and type(cap.features) == "table" and type(cap.features.info) == "function" then
		names = cap.features:info().driveNames
	end
	if type(config) ~= "table" then raise("build", "the capture exposes no engine config") end
	if type(names) ~= "table" or #names ~= 8 then raise("build", "the capture exposes no 8 drive names") end
	return config, names
end

local function findTotalSteps(stats)
	if type(stats) ~= "table" then return nil end
	if isInteger(stats.totalSteps) then return stats.totalSteps end
	for _, key in { "native", "engine", "runner" } do
		local inner = stats[key]
		if type(inner) == "table" and isInteger(inner.totalSteps) then return inner.totalSteps end
	end
	return nil
end

-- Capture-check records carry the saved 2024 values twice: JSON numbers and exact little-endian hex (string.pack "<d").
-- The controller always hands the exact hex values onward, so no comparison depends on JSONDecode precision.
local VARIANT_NAMES = { "coupled", "independent", "numeric" }
local function unhexDoubles(text, n)
	if type(text) ~= "string" or #text ~= 16 * n or string.find(text, "[^0-9a-fA-F]") then return nil end
	local bytes = string.gsub(text, "%x%x", function(h) return string.char(tonumber(h, 16)) end)
	local out = table.create(n)
	for i = 1, n do out[i] = (string.unpack("<d", bytes, (i - 1) * 8 + 1)) end
	return out
end
local function exactRecord(record)
	local hex = record.hex
	if type(hex) ~= "table" then return record end
	local out = { index = record.index, t = record.t, reset = record.reset, drive = unhexDoubles(hex.drive, 8) or record.drive }
	for _, variant in VARIANT_NAMES do out[variant] = unhexDoubles(hex[variant], 51) or record[variant] end
	return out
end
-- Pre-flight rows for SpringLiveCapture.replayCheck: hex strings where present (it decodes them exactly).
local function replayRow(record)
	local hex = type(record.hex) == "table" and record.hex or {}
	local out = { index = record.index, t = record.t, reset = record.reset, drive = hex.drive or record.drive }
	for _, variant in VARIANT_NAMES do out[variant] = hex[variant] or record[variant] end
	return out
end
-- Measures Roblox JSONDecode precision on the pre-flight records: decoded numbers that differ from their exact hex.
local function decodeCheck(records)
	local values, mismatches = 0, 0
	for _, record in records do
		local exact = exactRecord(record)
		if exact ~= record then
			for _, key in { "drive", "coupled", "independent", "numeric" } do
				local a, b = record[key], exact[key]
				if type(a) == "table" and type(b) == "table" then
					for k = 1, #b do
						values += 1
						if a[k] ~= b[k] then mismatches += 1 end
					end
				end
			end
		end
	end
	return { values = values, mismatches = mismatches }
end

local function slimBar(bar)
	return { t = bar.t, o = bar.o, h = bar.h, l = bar.l, c = bar.c, availableT = bar.availableT, day = bar.day, label = bar.label }
end

local function checkBar(bar, index, prevT)
	if type(bar) ~= "table" then raise("data", "bar " .. index .. " is not a table") end
	if not isInteger(bar.t) or (prevT and bar.t <= prevT) then raise("data", "bar " .. index .. " t is not strictly increasing") end
	if bar.availableT ~= bar.t + 300 then raise("data", "bar " .. index .. " availableT ~= t + 300") end
	if type(bar.day) ~= "string" or type(bar.label) ~= "string" then raise("data", "bar " .. index .. " lacks day/label") end
	for _, key in { "o", "h", "l", "c" } do
		if not finite(bar[key]) then raise("data", "bar " .. index .. " " .. key .. " is not finite") end
	end
end

local function validRunId(runId)
	return type(runId) == "string" and #runId >= 1 and #runId <= 100 and string.match(runId, NAME_PATTERN) ~= nil
		and not string.match(string.upper(runId), "^CON$") and not string.match(string.upper(runId), "^PRN$")
		and not string.match(string.upper(runId), "^AUX$") and not string.match(string.upper(runId), "^NUL$")
		and not string.match(string.upper(runId), "^COM%d$") and not string.match(string.upper(runId), "^LPT%d$")
end

---------------------------------------------------------------------------------------------------------------------
function SpringLive.start(opts)
	opts = opts or {}
	assert(type(opts) == "table", "SpringLive.start: options table required")
	local deps = resolveDeps(opts.deps)
	deps.baseUrl = resolveBaseUrl(opts, deps, "SpringLive.start")
	local expect = deps.expect
	local planSha = if type(opts.planSha256) == "string" then string.lower(opts.planSha256) else nil
	local addendumSha = if type(opts.addendumSha256) == "string" then string.lower(opts.addendumSha256) else nil
	assert(isSha(planSha), "SpringLive.start: opts.planSha256 (SHA-256 of forward-test-2025-2026-plan.md) is required")
	assert(isSha(addendumSha), "SpringLive.start: opts.addendumSha256 (SHA-256 of spring-live-contract.md) is required")
	local runId = opts.runId or ("live_" .. string.format("%.0f", deps.clock()))
	assert(validRunId(runId), "SpringLive.start: runId must match ^[A-Za-z0-9_-]{1,100}$ and not be a device name")
	assert(not (deps.RunService.IsRunning and deps.RunService:IsRunning()), "SpringLive.start: Studio Edit mode only (stop Play/Run first)")
	local modules = loadModules(deps)
	local Frozen, Capture, Session = modules.SpringFrozenV1, modules.SpringLiveCapture, modules.SpringLiveSession

	local launchersAtStart = exitOthers(deps)
	local control
	local guard = makeGuard(deps, function() return control end)
	local okIdle, idleWhy = guard()
	assert(okIdle, "SpringLive.start: refused (L14): " .. tostring(idleWhy))

	local status = { runId = runId, phase = "starting", busy = true, running = false, decided = 0, total = expect.bars,
		chunks = 0, startedAtMs = deps.clock(), launchersRemoved = launchersAtStart }
	local run = { stopRequested = false, receipts = {}, lastChunkIndex = 0, seq = 0, plan = nil, cap = nil,
		session = nil, manifest = nil, preflight = nil, physicsLabel = nil, leadIn = nil, leadInPending = false,
		physicsWarning = nil, attempt = nil, planConflict = false }
	local function captureRetained()
		return run.cap ~= nil and not run.captureReleased
			and (type(run.cap.release) == "function" or type(run.cap.destroy) == "function")
	end
	local viewer
	viewer = newViewer(deps, modules, { viewRun = opts.viewRun, compareRun = opts.compareRun, rate = opts.rate,
		frame = opts.frame, onExitUI = function()
			if not status.running and not status.busy and not captureRetained() and control and control.Parent ~= nil then control:Destroy() end
		end })

	local function log(message)
		if deps.warn then pcall(deps.warn, "[SpringLive " .. runId .. "] " .. message) end
	end
	local function setPhase(phase) status.phase = phase end

	local function statusSnapshot()
		local s = table.clone(status)
		s.decided = viewer.decided
		s.index = viewer.state.index
		s.following = viewer.state.following
		s.playing = viewer.state.playing
		s.rate = viewer.state.rate
		s.viewRun = viewer.state.viewRun
		s.compareRun = viewer.state.compareRun
		s.uiMounted = viewer.ui.mounted
		s.uiErrors = viewer.ui.errors
		s.lastUiError = viewer.ui.lastError
		s.cameraFramings = viewer.cameraWrites
		s.chunks = #run.receipts
		s.lastChunk = run.receipts[#run.receipts]
		s.lastSavedIndex = run.lastChunkIndex
		s.planSha256 = run.plan and run.plan.sha256 or nil
		s.preflight = run.preflight
		s.physicsLabel = run.physicsLabel
		s.leadIn = run.leadIn
		s.physicsWarning = run.physicsWarning
		s.attempt = run.attempt
		s.manifest = run.manifest
		s.stopRequested = run.stopRequested
		s.captureRetained = captureRetained()
		return s
	end

	-- Native stats for disclosure (the engine config is recorded once in the plan's module receipts, not per chunk).
	local function nativeStats()
		if not run.cap then return nil end
		local ok, stats = pcall(function() return run.cap:stats() end)
		if not ok then return { error = tostring(stats) } end
		return sanitize(withoutKey(stats, "config"))
	end

	local function receiptList()
		local list = {}
		for k, r in run.receipts do
			list[k] = { name = r.name, sha256 = r.sha256, bytes = r.bytes, seq = r.seq, firstIndex = r.firstIndex,
				lastIndex = r.lastIndex }
		end
		return list
	end

	local function sessionPart(method)
		if not run.session then return nil end
		local ok, value = pcall(function() return run.session[method](run.session) end)
		if not ok then return { error = tostring(value) } end
		return sanitize(value)
	end

	local function writeManifest(manifestStatus, failure, checks)
		local payload = {
			schema = MANIFEST_SCHEMA,
			runId = runId,
			status = manifestStatus,
			planSha256 = run.plan.sha256,
			chunks = receiptList(),
			lastChunkSha256 = if #run.receipts > 0 then run.receipts[#run.receipts].sha256 else run.plan.sha256,
			-- lastIndex: rows decided; lastSavedIndex: rows on disk in the chunks (a POST or decision failure can leave
			-- decided rows unsaved: their pending chunk was lost or the session state is no longer trusted).
			lastIndex = viewer.decided,
			lastSavedIndex = run.lastChunkIndex,
			unsavedRows = viewer.decided - run.lastChunkIndex,
			bars = expect.bars,
			startedAtMs = status.startedAtMs,
			endedAtMs = deps.clock(),
			preflight = run.preflight,
			physicsLabel = run.physicsLabel,
			physicsWarning = run.physicsWarning,
			native = nativeStats(),
			summaries = sessionPart("summary"),
			evidence = sessionPart("evidence"),
			reproducibility = sessionPart("reproducibility"),
			identity = sessionPart("identity"),
			checks = checks,
		}
		if failure then
			payload.reason = failure.reason
			payload.stage = failure.stage
			payload.trace = failure.trace
		end
		local receipt = httpPost(deps, runId, "manifest", sanitize(payload))
		run.manifest = receipt
		return receipt
	end

	-- L4 "every attempt is reported": a failure before the plan seal (data, runId, pre-flight, module receipts, a refused
	-- plan POST) leaves a write-once attempt record, best effort. It is never written into a run directory owned by
	-- another run (runId already sealed, or the plan POST answered 409). replay() reads only plan, chunk and manifest.
	local function recordAttempt(failure, phase)
		if run.plan then return end
		if failure.stage == "runid" or run.planConflict then
			run.attempt = { skipped = "the run directory belongs to an earlier run with this runId" }
			return
		end
		local m = run.liveManifest
		local payload = {
			schema = ATTEMPT_SCHEMA,
			runId = runId,
			status = "not_started",
			phase = phase,
			stage = failure.stage,
			reason = failure.reason,
			trace = failure.trace,
			startedAtMs = status.startedAtMs,
			endedAtMs = deps.clock(),
			planSha256 = planSha,
			addendumSha256 = addendumSha,
			preflight = run.preflight,
			physicsLabel = run.physicsLabel,
			barUniverse = if type(m) == "table" then { datasetId = m.datasetId, bars = m.bars, captureRows = m.captureRows,
				liveStartIndex = m.liveStartIndex, liveStartT = m.liveStartT } else nil,
			controller = { preflightRows = PREFLIGHT_ROWS, nativeTolerance = NATIVE_TOLERANCE, rigName = RIG_NAME, server = deps.baseUrl },
		}
		local name = "attempt_" .. string.format("%.0f", deps.clock())
		local ok, receipt = pcall(httpPost, deps, runId, name, sanitize(payload))
		if ok then
			run.attempt = { name = name, sha256 = receipt.sha256, bytes = receipt.bytes }
		else
			run.attempt = { name = name, error = tostring(asFault(receipt, "post")) }
			log("attempt record could not be saved: " .. run.attempt.error)
		end
	end

	-- A lane producer may already be inside the next bar while the decision front finishes or fails. Keep the capture
	-- busy until that verified bar has returned; all terminal isolation/stats/manifest reads happen after this join.
	local function quiesce()
		if run.joined then return true end
		status.running, status.busy = false, true
		setPhase("stopping")
		if run.cap and type(run.cap.shutdown) == "function" then
			local ok, err = pcall(run.cap.shutdown, run.cap, "controller finishing")
			if not ok then
				status.stage, status.reason = "shutdown", tostring(err)
				setPhase("shutdown_failed")
				log("capture shutdown failed; terminal manifest withheld: " .. tostring(err))
				return false
			end
		end
		run.joined = true
		return true
	end

	local function verifyIsolation(where)
		local ok, delta = pcall(function() return run.cap:verifyIsolation() end)
		local result = { at = where, ok = ok and finite(delta) and delta < ISOLATION_LIMIT, maxDelta = if ok and finite(delta) then delta else nil }
		if not ok then result.error = tostring(delta) elseif not finite(delta) then result.error = "maxDelta " .. tostring(delta) end
		return result
	end

	-- Ends the run after joining; only a controller that owns the plan may write the terminal manifest.
	local function finish(manifestStatus, failure, checks)
		if not quiesce() then return end
		checks = checks or {}
		if run.cap and checks.isolationEnd == nil then
			local isolation = verifyIsolation("end")
			checks.isolationEnd = sanitize(isolation)
			if not isolation.ok then
				local reason = "isolation breach at the end: " .. tostring(isolation.error or isolation.maxDelta)
				if failure then failure.reason ..= " (" .. reason .. ")" else failure = fault("isolation", reason) end
				manifestStatus = "aborted"
			end
		end
		status.running = false
		status.busy = false
		status.endedAtMs = deps.clock()
		if failure then
			status.stage, status.reason = failure.stage, failure.reason
		end
		setPhase(manifestStatus)
		if run.plan then
			local ok, err = pcall(writeManifest, manifestStatus, failure, checks)
			if not ok then
				status.manifestError = tostring(asFault(err, "post"))
				log("manifest could not be saved: " .. status.manifestError)
			end
		end
		if failure then log(manifestStatus .. " (" .. failure.stage .. "): " .. failure.reason) end
		viewer.setStatusLine(string.format("LIVE RUN %s · %s%s%s", string.upper(manifestStatus), runId,
			if failure then " · " .. failure.stage .. ": " .. failure.reason else "",
			if run.physicsWarning then " · WARNING: " .. run.physicsWarning else ""))
		-- The control keeps the retained rig reachable until explicit "release"; Exit only hides that inspection UI.
	end

	-- Drains everything decided since the last chunk, records isolation, POSTs it (write-once) and chains the hashes.
	local sessionsInChunk, chunkFirstDay, chunkLastDay = 0, nil, nil
	local function flushChunk(final)
		if viewer.decided <= run.lastChunkIndex then return nil end
		local drained, chunk = pcall(function() return run.session:drainChunk() end)
		if not drained then raise("decision", "drainChunk: " .. tostring(chunk)) end
		if type(chunk) ~= "table" then raise("decision", "drainChunk returned no chunk for rows " .. (run.lastChunkIndex + 1) .. ".." .. viewer.decided) end
		local isolation = verifyIsolation("chunk")
		run.seq += 1
		local name = string.format("chunk_%04d", run.seq)
		local previous = if #run.receipts > 0 then run.receipts[#run.receipts].sha256 else run.plan.sha256
		local envelope = {
			schema = CHUNK_SCHEMA, runId = runId, seq = run.seq, name = name, planSha256 = run.plan.sha256,
			prevSha256 = previous, firstIndex = run.lastChunkIndex + 1, lastIndex = viewer.decided,
			sessions = { count = sessionsInChunk, firstDay = chunkFirstDay, lastDay = chunkLastDay }, final = final == true,
			isolation = sanitize(isolation), native = nativeStats(), chunk = chunk,
			-- The chunk that closes the lead-in carries the L3b result, so it is on disk long before the manifest.
			leadInReproducibility = if run.leadInPending then run.leadIn else nil,
		}
		local receipt = httpPost(deps, runId, name, envelope)
		receipt.seq, receipt.firstIndex, receipt.lastIndex = run.seq, envelope.firstIndex, envelope.lastIndex
		table.insert(run.receipts, receipt)
		run.lastChunkIndex = viewer.decided
		if envelope.leadInReproducibility ~= nil then run.leadInPending = false end
		if not isolation.ok then
			raise("isolation", "isolation breach at chunk " .. run.seq .. ": " .. tostring(isolation.error or isolation.maxDelta))
		end
		return receipt
	end

	-- Page fetches run one page ahead in their own thread; the loop waits only when the next page is late. Only the
	-- network request runs ahead (it yields and costs no Lua time); the JSONDecode of the body runs in await(), in the
	-- loop's own thread between bars, so a large decode never lands inside a bar's physics frames (as in the 2024 App,
	-- whose HTTP ran between bars).
	local function fetchAsync(path)
		local slot = { done = false, path = path }
		deps.spawn(function()
			local ok, value = pcall(httpText, deps, path, "data")
			slot.ok, slot.value, slot.done = ok, value, true
		end)
		return slot
	end
	local function await(slot)
		while not slot.done do deps.wait() end
		if not slot.ok then error(asFault(slot.value, "data"), 0) end
		if slot.decoded == nil then
			slot.decoded = decodeText(deps, slot.path, slot.value, "data")
			slot.value = nil
		end
		return slot.decoded
	end

	-- Lead-in comparison (L3b): capture-check blocks of 512 records, the next block prefetched.
	local savedBlocks = {}
	local function blockSlot(b)
		local first = (b - 1) * CAPTURE_CHECK_BLOCK + 1
		local last = math.min(b * CAPTURE_CHECK_BLOCK, expect.captureRows)
		if first > expect.captureRows then return nil end
		return { first = first, last = last, slot = fetchAsync("/spring-live/capture-check?first=" .. first .. "&last=" .. last) }
	end
	local function ensureSaved(index, bar)
		local b = math.ceil(index / CAPTURE_CHECK_BLOCK)
		local block = savedBlocks[b]
		if not block then
			block = blockSlot(b)
			savedBlocks[b] = block
		end
		if not block.records then
			local response = await(block.slot)
			local records = response.records
			if response.first ~= block.first or response.last ~= block.last or type(records) ~= "table"
				or #records ~= block.last - block.first + 1 then
				raise("data", "capture-check " .. block.first .. ".." .. block.last .. " returned another range")
			end
			for j, record in records do
				if type(record) ~= "table" or record.index ~= block.first + j - 1 then
					raise("data", "capture-check record " .. (block.first + j - 1) .. " is out of order")
				end
			end
			block.records = records
			if savedBlocks[b + 1] == nil then savedBlocks[b + 1] = blockSlot(b + 1) or false end
			savedBlocks[b - 2] = nil
		end
		local record = block.records[index - block.first + 1]
		if record.t ~= bar.t then raise("data", "lead-in bar " .. index .. " t differs from the saved 2024 record") end
	end
	local function saved2024(index)
		if not isInteger(index) or index < 1 or index > expect.captureRows then return nil end
		local block = savedBlocks[math.ceil(index / CAPTURE_CHECK_BLOCK)]
		if not block or not block.records then return nil end
		local record = block.records[index - block.first + 1]
		return if record then exactRecord(record) else nil
	end

	local function statusLine(bar)
		local where = if viewer.state.following then "following"
			elseif viewer.state.playing then "playing row " .. viewer.state.index
			else "viewing row " .. viewer.state.index
		local part = if viewer.decided <= expect.captureRows then "2024 lead-in, not traded" else "forward test"
		local text = string.format("LIVE · bar %d/%d · %s · %s · %s", viewer.decided, expect.bars, tostring(bar.label), part, where)
		-- L3: the "physics differs" disclosure is shown live, never only in the files.
		if run.physicsWarning then text ..= " · WARNING: " .. run.physicsWarning end
		return text
	end

	-- L3b, read once when the last lead-in row is decided: shown live (status line, status) when it does not pass, and
	-- written into the next chunk envelope. The session also reports whether the lead-in decision rows equal the offline
	-- 2024 result (reproducibility().decisionRows); a "differs" there is shown the same way.
	local function readLeadIn()
		local ok, repro = pcall(function() return run.session:reproducibility() end)
		local warnings = {}
		if run.physicsWarning then table.insert(warnings, run.physicsWarning) end
		local earlier = #warnings
		if not ok or type(repro) ~= "table" then
			run.leadIn = { status = "error", error = tostring(repro) }
			table.insert(warnings, "lead-in reproducibility could not be read: " .. tostring(repro))
		else
			run.leadIn = sanitize(repro)
			if repro.status ~= "pass" then
				local label = if type(repro.label) == "string" then repro.label else PHYSICS_DIFFERS
				if label ~= run.physicsWarning then table.insert(warnings, label) end
			end
			local rows = repro.decisionRows
			if type(rows) == "table" and rows.status == "differs" then
				table.insert(warnings, if type(rows.label) == "string" then rows.label else "lead-in decision rows differ from the offline 2024 result")
			end
		end
		run.leadInPending = true
		if #warnings > earlier then
			run.physicsWarning = table.concat(warnings, " · ")
			log("lead-in reproducibility (L3b): " .. tostring(run.leadIn.status) .. " · " .. run.physicsWarning)
		end
	end

	local function loop()
		local outcome
		local ok, err = xpcall(function()
			local manifestData = run.liveManifest
			local expectedIndex = 1
			local prevT, prevDay = nil, nil
			local sessionsSeen = 0
			local slot = fetchAsync("/spring-live/page?index=1")
			for k = 1, manifestData.pageCount do
				local page = await(slot)
				if page.datasetId ~= manifestData.datasetId then raise("data", "page " .. k .. " belongs to dataset " .. tostring(page.datasetId)) end
				if page.page ~= k or page.pageCount ~= manifestData.pageCount then raise("data", "page " .. k .. " numbering differs") end
				local bars = page.bars
				if type(bars) ~= "table" or page.firstIndex ~= expectedIndex or page.lastIndex ~= expectedIndex + #bars - 1 or #bars < 1
					or #bars > manifestData.pageSize or (k < manifestData.pageCount and #bars ~= manifestData.pageSize) then
					raise("data", "page " .. k .. " is not contiguous at index " .. expectedIndex)
				end
				slot = if k < manifestData.pageCount then fetchAsync("/spring-live/page?index=" .. (k + 1)) else nil
				for _, bar in bars do
					if run.stopRequested then
						outcome = "stopped"
						return
					end
					status.launchersRemoved += removeLaunchers(deps.CoreGui)
					local guardOk, why = guard()
					if not guardOk then raise("exclusivity", why) end
					checkBar(bar, expectedIndex, prevT)
					if expectedIndex == expect.liveStartIndex and bar.t ~= expect.liveStartT then
						raise("data", "forward test does not start at t " .. expect.liveStartT)
					end
					if bar.day ~= prevDay then
						if sessionsInChunk == CHUNK_SESSIONS then
							flushChunk(false)
							sessionsInChunk, chunkFirstDay = 0, nil
						end
						sessionsInChunk += 1
						sessionsSeen += 1
						chunkFirstDay = chunkFirstDay or bar.day
						chunkLastDay = bar.day
						prevDay = bar.day
					end
					if expectedIndex <= expect.captureRows then ensureSaved(expectedIndex, bar) end
					local stepped, record = pcall(function() return run.cap:step(bar) end)
					if not stepped then raise("capture", "bar " .. expectedIndex .. ": " .. tostring(record)) end
					if type(record) ~= "table" or type(record.bar) ~= "table" or record.bar.t ~= bar.t or type(record.feature) ~= "table"
						or type(record.states) ~= "table" then
						raise("capture", "bar " .. expectedIndex .. " returned an invalid record")
					end
					local f = record.feature
					local drive = if type(f.drive) == "table" then table.clone(f.drive) else f.drive
					local input = { bar = slimBar(bar), feature = { reset = f.reset, ready = f.ready, volatility = f.volatility, drive = drive },
						states = record.states }
					local decidedOk, index = pcall(function() return run.session:step(input) end)
					if not decidedOk then raise("decision", "bar " .. expectedIndex .. ": " .. tostring(index)) end
					if index ~= expectedIndex then raise("decision", "session returned index " .. tostring(index) .. " for bar " .. expectedIndex) end
					prevT = bar.t
					expectedIndex += 1
					status.decided = index
					if index == expect.captureRows then readLeadIn() end
					viewer.onDecided(index, bar.label)
					viewer.setStatusLine(statusLine(bar))
				end
			end
			if expectedIndex - 1 ~= expect.bars then raise("data", "stepped " .. (expectedIndex - 1) .. " bars, expected " .. expect.bars) end
			if sessionsSeen ~= expect.sessions then raise("data", "saw " .. sessionsSeen .. " sessions, expected " .. expect.sessions) end
			flushChunk(true)
			outcome = "complete"
		end, function(e)
			local f = asFault(e, "internal")
			if getmetatable(e) ~= Fault then f.trace = debug.traceback(tostring(e), 2) end
			return f
		end)
		if not quiesce() then return end
		if ok and outcome == "complete" then
			local isolation = verifyIsolation("end")
			if not isolation.ok then
				finish("aborted", fault("isolation", "isolation breach at the end: " .. tostring(isolation.error or isolation.maxDelta)))
				return
			end
			local statsOk, stats = pcall(function() return run.cap:stats() end)
			local totalSteps = if statsOk then findTotalSteps(stats) else nil
			local checks = {
				totalSteps = { expected = STEPS_PER_BAR * viewer.decided, actual = totalSteps or false,
					pass = totalSteps == STEPS_PER_BAR * viewer.decided },
				isolationEnd = sanitize(isolation),
				bars = { expected = expect.bars, actual = viewer.decided, pass = viewer.decided == expect.bars },
			}
			finish(if checks.totalSteps.pass then "complete" else "complete_checks_failed", nil, checks)
			return
		end
		local failure = if ok then fault("stop", "stopped_by_user") else err
		-- Clean between-bar endings keep every decided row: flush what is pending before the manifest.
		if failure.stage == "stop" or failure.stage == "exclusivity" or failure.stage == "data" or failure.stage == "capture" then
			local flushed, flushErr = pcall(flushChunk, true)
			if not flushed then
				local extra = asFault(flushErr, "post")
				failure.reason ..= " (final chunk not saved: " .. tostring(extra) .. ")"
			end
		end
		finish("aborted", failure)
	end

	local function stop()
		if not status.running then return false end
		run.stopRequested = true
		viewer.state.playing = false
		setPhase("stopping")
		return true
	end
	local function exit()
		viewer.exitUI()
		if not status.running and not status.busy and not captureRetained() and control.Parent ~= nil then control:Destroy() end
		return true
	end
	local function release()
		assert(not status.running and not status.busy, "SpringLive: cannot release a running or stopping capture")
		if not captureRetained() then return false end
		local dispose = run.cap.release or run.cap.destroy
		dispose(run.cap)
		run.captureReleased = true
		return true
	end
	control = makeControl(deps, viewer, { status = statusSnapshot, stop = stop, exit = exit, release = release,
		reproducibility = function() return reproducibilityOf(run.session) end })

	-- Steps 2-6 (synchronous unless opts.background), then step 7 in its own thread.
	local function setup()
		local ok, err = xpcall(function()
			setPhase("data")
			local manifestData = httpGet(deps, "/spring-live/manifest", "data")
			checkManifest(manifestData, expect)
			run.liveManifest = manifestData
			checkRunIdFree(deps, runId)

			-- Step 3: pre-flight (L3a).
			if opts.preflight == false then
				run.preflight = { skipped = true }
				run.physicsLabel = "pre-flight not run"
			else
				setPhase("preflight")
				local okGuard, why = guard()
				if not okGuard then raise("exclusivity", why) end
				local check = httpGet(deps, "/spring-live/capture-check?first=1&last=" .. PREFLIGHT_ROWS, "data")
				local rows = check.records
				if check.first ~= 1 or check.last ~= PREFLIGHT_ROWS or type(rows) ~= "table" or #rows ~= PREFLIGHT_ROWS then
					raise("data", "capture-check 1.." .. PREFLIGHT_ROWS .. " returned another range")
				end
				for i, row in rows do
					if type(row) ~= "table" or row.index ~= i then raise("data", "capture-check record " .. i .. " is out of order") end
				end
				local replayRows = table.create(#rows)
				for i, row in rows do replayRows[i] = replayRow(row) end
				local checked, result = pcall(function()
					return Capture.replayCheck(replayRows, { guard = guard, nativeConfig2024 = Frozen.nativeConfig2024, tolerance = NATIVE_TOLERANCE })
				end)
				if not checked then raise("preflight", "replayCheck failed: " .. tostring(result)) end
				local valid = type(result) == "table"
				local maxAbs = valid and type(result.maxAbs) == "table" and result.maxAbs or {}
				local within = valid and result.count == PREFLIGHT_ROWS and maxAbs.numeric == 0
					and finite(maxAbs.coupled) and maxAbs.coupled <= NATIVE_TOLERANCE
					and finite(maxAbs.independent) and maxAbs.independent <= NATIVE_TOLERANCE
				local pass = within and result.pass == true
				run.preflight = sanitize({ rows = "1.." .. PREFLIGHT_ROWS, count = valid and result.count or false,
					maxAbs = maxAbs, worst = valid and result.worst or nil, isolation = valid and result.isolation or nil,
					verdict = valid and result.verdict or nil, modulePass = valid and result.pass == true, controllerPass = within,
					pass = pass, nativeTolerance = NATIVE_TOLERANCE, numericTolerance = 0, allowedToFail = opts.allowPreflightFail == true,
					jsonDecode = decodeCheck(rows) })
				if not pass then
					local text = string.format("pre-flight failed: max |diff| coupled %s, independent %s, numeric %s (count %s)",
						tostring(maxAbs.coupled), tostring(maxAbs.independent), tostring(maxAbs.numeric), tostring(result and result.count))
					if not opts.allowPreflightFail then raise("preflight", text) end
					run.physicsLabel = PHYSICS_DIFFERS
					run.physicsWarning = PHYSICS_DIFFERS
					log(text .. "; continuing because allowPreflightFail is set; the run is labelled: " .. PHYSICS_DIFFERS)
				else
					run.physicsLabel = "pre-flight matched the 2024 capture on records 1.." .. PREFLIGHT_ROWS
				end
			end

			-- Step 4: seal the plan before bar 1.
			setPhase("sealing")
			assert(type(Frozen) == "table" and type(Frozen.pins) == "table" and isSha(Frozen.resultSha256),
				"SpringFrozenV1 must carry pins and resultSha256")
			local plan = {
				schema = PLAN_SCHEMA,
				runId = runId,
				startedAtMs = status.startedAtMs,
				planSha256 = planSha,
				addendumSha256 = addendumSha,
				frozen = sanitize({ schema = Frozen.schema, resultSha256 = Frozen.resultSha256, resultName = Frozen.resultName,
					protocolId = Frozen.protocolId, pins = Frozen.pins, canonicalSha256 = Frozen.canonicalSha256, sources = Frozen.sources,
					frozenSampleId = type(Frozen.frozenState) == "table" and Frozen.frozenState.sampleId or nil }),
				modules = moduleReceipts(deps),
				barUniverse = sanitize({ datasetId = manifestData.datasetId, captureDataHash = manifestData.captureDataHash,
					query = manifestData.query, split = manifestData.split, bars = manifestData.bars, sessions = expect.sessions,
					pageSize = manifestData.pageSize, pageCount = manifestData.pageCount, captureRows = manifestData.captureRows,
					liveStartIndex = manifestData.liveStartIndex, liveStartT = manifestData.liveStartT }),
				preflight = run.preflight,
				physicsLabel = run.physicsLabel,
				controller = { chunkSessions = CHUNK_SESSIONS, preflightRows = PREFLIGHT_ROWS, nativeTolerance = NATIVE_TOLERANCE,
					isolationLimit = ISOLATION_LIMIT, stepsPerBar = STEPS_PER_BAR, rigName = RIG_NAME, server = deps.baseUrl },
			}
			local okSeal, sealOrErr = pcall(httpPost, deps, runId, "plan", plan)
			if not okSeal then
				local f = asFault(sealOrErr, "post")
				run.planConflict = f.httpStatus == 409
				raise("seal", "plan seal failed: " .. tostring(f))
			end
			run.plan = sealOrErr

			-- Step 5: capture and session.
			setPhase("building")
			local okGuard, why = guard()
			if not okGuard then raise("exclusivity", why) end
			local built, capOrErr = pcall(function()
				return Capture.new({ prehistory = manifestData.prehistory, symbol = "SPY", name = RIG_NAME, guard = guard,
					nativeConfig2024 = Frozen.nativeConfig2024 })
			end)
			if not built then raise("capture", "SpringLiveCapture.new: " .. tostring(capOrErr)) end
			run.cap = capOrErr
			local isolation = verifyIsolation("start")
			if not isolation.ok then raise("isolation", "isolation breach at start: " .. tostring(isolation.error or isolation.maxDelta)) end
			local engineConfig, driveNames = captureIdentity(run.cap)
			local madeSession, sessionOrErr = pcall(function()
				return Session.new({ frozen = Frozen, engineConfig = engineConfig, driveNames = driveNames,
					planSha256 = run.plan.sha256, leadInRows = expect.captureRows, saved2024 = saved2024, runId = runId })
			end)
			if not madeSession then raise("decision", "SpringLiveSession.new: " .. tostring(sessionOrErr)) end
			run.session = sessionOrErr

			-- Step 6: UI and the one camera framing.
			viewer.mount(run.session)
			viewer.setStatusLine("LIVE · " .. runId .. " · plan sealed " .. string.sub(run.plan.sha256, 1, 12)
				.. " · waiting for bar 1 · Exit hides this view only (the run continues; control: show / stop)"
				.. (if run.physicsWarning then " · WARNING: " .. run.physicsWarning else ""))
		end, function(e)
			local f = asFault(e, "internal")
			if getmetatable(e) ~= Fault then f.trace = debug.traceback(tostring(e), 2) end
			return f
		end)
		if ok then return true end
		if err.stage == "preflight" then
			status.running, status.busy = false, false
			status.stage, status.reason = err.stage, err.reason
			setPhase("preflight_failed")
			log(err.reason)
			recordAttempt(err, "preflight_failed")
			return false
		end
		finish("aborted", err)
		recordAttempt(err, "aborted")
		return false
	end

	local function begin()
		if run.stopRequested then
			finish("aborted", fault("stop", "stopped_by_user before bar 1"))
			return
		end
		setPhase("running")
		local ok, err = pcall(loop)
		if not ok then
			-- Even a failure in the loop's own handler must join before terminal accounting.
			finish("aborted", fault("internal", "controller failure: " .. tostring(err)))
		end
	end

	status.running = true
	if opts.background then
		deps.spawn(function()
			if setup() then begin() end
		end)
	elseif setup() then
		deps.spawn(begin)
	end
	return control
end

---------------------------------------------------------------------------------------------------------------------
-- Later playback from the saved chunks: no capture, no stepping. Every chunk is fetched with its sha256 (the server
-- answers 409 on a mismatch) and must continue the hash chain that starts at the plan.
function SpringLive.replay(opts)
	opts = opts or {}
	assert(type(opts) == "table", "SpringLive.replay: options table required")
	local deps = resolveDeps(opts.deps)
	deps.baseUrl = resolveBaseUrl(opts, deps, "SpringLive.replay")
	local runId = opts.runId
	assert(validRunId(runId), "SpringLive.replay: runId required")
	local modules = loadModules(deps)
	local Session, Frozen = modules.SpringLiveSession, modules.SpringFrozenV1
	assert(type(Session.regenerate) == "function", "SpringLive.replay: SpringLiveSession.regenerate is required for playback")
	exitOthers(deps)

	local manifest = getChunk(deps, runId, "manifest")
	assert(manifest.schema == MANIFEST_SCHEMA and manifest.runId == runId, "SpringLive.replay: not a live manifest for " .. runId)
	assert(isSha(manifest.planSha256) and type(manifest.chunks) == "table", "SpringLive.replay: manifest lacks plan hash or chunks")
	local plan = getChunk(deps, runId, "plan", manifest.planSha256)
	assert(plan.schema == PLAN_SCHEMA and plan.runId == runId, "SpringLive.replay: plan does not belong to " .. runId)
	local chunks, previous, nextIndex = {}, manifest.planSha256, 1
	for seq, receipt in manifest.chunks do
		assert(type(receipt) == "table" and isSha(receipt.sha256) and type(receipt.name) == "string"
			and string.match(receipt.name, NAME_PATTERN) ~= nil, "SpringLive.replay: chunk receipt " .. seq .. " is invalid")
		local envelope = getChunk(deps, runId, receipt.name, receipt.sha256)
		assert(envelope.schema == CHUNK_SCHEMA and envelope.runId == runId and envelope.seq == seq,
			"SpringLive.replay: chunk " .. tostring(receipt.name) .. " is not chunk " .. seq .. " of " .. runId)
		assert(envelope.prevSha256 == previous, "SpringLive.replay: chunk " .. seq .. " breaks the hash chain")
		assert(envelope.firstIndex == nextIndex, "SpringLive.replay: chunk " .. seq .. " does not continue at row " .. nextIndex)
		previous, nextIndex = receipt.sha256, envelope.lastIndex + 1
		table.insert(chunks, envelope.chunk)
	end
	assert(manifest.lastChunkSha256 == previous, "SpringLive.replay: manifest does not close the hash chain")
	-- The chunks must cover exactly the saved rows. Rows decided after the last saved chunk (a POST or decision failure)
	-- are disclosed by the manifest (lastIndex > lastSavedIndex) and cannot be shown.
	local saved = manifest.lastSavedIndex
	assert(isInteger(saved) and isInteger(manifest.lastIndex) and saved >= 0 and saved <= manifest.lastIndex,
		"SpringLive.replay: manifest lacks a valid lastSavedIndex")
	assert(nextIndex - 1 == saved, "SpringLive.replay: chunks cover " .. (nextIndex - 1) .. " rows, manifest says " .. tostring(saved) .. " saved")
	assert(#chunks > 0, string.format("SpringLive.replay: run %s saved no rows (manifest %s, %d decided)", runId,
		tostring(manifest.status), manifest.lastIndex))
	-- Every run is re-decided from the saved exact inputs (no physics). The rig identity was checked when the run was
	-- captured, so the frozen 2024 config and drive names stand in for the engine here.
	local session, report = Session.regenerate({ frozen = Frozen, engineConfig = Frozen.nativeConfig2024,
		driveNames = Frozen.descriptor.driveNames, planSha256 = manifest.planSha256, runId = runId,
		leadInRows = type(plan.barUniverse) == "table" and plan.barUniverse.captureRows or EXPECT.captureRows }, chunks)
	assert(type(report) == "table" and report.pass == true, string.format(
		"SpringLive.replay: the saved chunks do not regenerate exactly (row differences %s, chunk field mismatches %s, problems %s)",
		tostring(report and report.totalRowDifferences), tostring(report and report.chunkFieldMismatches and #report.chunkFieldMismatches),
		tostring(report and report.problems and table.concat(report.problems, "; "))))

	local control
	local viewer = newViewer(deps, modules, { viewRun = opts.viewRun, compareRun = opts.compareRun, rate = opts.rate,
		frame = opts.frame, onExitUI = function() if control and control.Parent ~= nil then control:Destroy() end end })
	local rows = saved
	local coupledRows = session:rows("coupled")
	assert(type(coupledRows) == "table" and #coupledRows == rows,
		"SpringLive.replay: the regenerated session holds " .. tostring(coupledRows and #coupledRows) .. " rows, manifest says " .. rows .. " saved")
	-- Time labels for the chart come from the display rows (bars() carries only t/o/h/l/c).
	viewer.labels = setmetatable({}, { __index = function(_, i)
		local ok, row = pcall(function() return session:displayRow("coupled", i) end)
		return if ok and type(row) == "table" then row.label else nil
	end })
	viewer.mount(session)
	viewer.decided = rows
	viewer.state.following = false
	viewer.seek(math.clamp(math.floor(tonumber(opts.index) or 1), 1, math.max(rows, 1)))
	local unsaved = manifest.lastIndex - rows
	viewer.setStatusLine(string.format("REPLAY · %s · %s · %d rows%s · no stepping%s", runId, tostring(manifest.status), rows,
		if unsaved > 0 then string.format(" saved (%d decided, %d not saved)", manifest.lastIndex, unsaved) else "",
		if type(manifest.physicsWarning) == "string" then " · WARNING: " .. manifest.physicsWarning else ""))
	local status = { runId = runId, phase = "replay", replay = true, busy = false, running = false, total = rows,
		lastIndex = manifest.lastIndex, lastSavedIndex = rows, unsavedRows = unsaved, physicsWarning = manifest.physicsWarning,
		manifestStatus = manifest.status, planSha256 = manifest.planSha256,
		regenerated = { pass = report.pass, rows = report.rows, chunks = report.chunks, rowDifferences = report.totalRowDifferences } }
	control = makeControl(deps, viewer, {
		status = function()
			local s = table.clone(status)
			s.decided, s.index, s.playing, s.following = viewer.decided, viewer.state.index, viewer.state.playing, viewer.state.following
			s.viewRun, s.compareRun, s.uiMounted, s.uiErrors = viewer.state.viewRun, viewer.state.compareRun, viewer.ui.mounted, viewer.ui.errors
			return s
		end,
		stop = function() return false end,
		exit = function() viewer.exitUI(); if control.Parent ~= nil then control:Destroy() end; return true end,
		reproducibility = function() return reproducibilityOf(session) end,
	})
	return control
end

SpringLive.CONTROL_NAME = CONTROL_NAME
SpringLive.RIG_NAME = RIG_NAME
SpringLive.EXPECT = EXPECT
SpringLive.CHUNK_SESSIONS = CHUNK_SESSIONS
SpringLive.PREFLIGHT_ROWS = PREFLIGHT_ROWS
SpringLive.NATIVE_TOLERANCE = NATIVE_TOLERANCE
SpringLive.ISOLATION_LIMIT = ISOLATION_LIMIT
SpringLive.SOURCE_MODULES = SOURCE_MODULES
SpringLive.encode = encode
SpringLive.sanitize = sanitize
SpringLive.sha256 = sha256
return SpringLive
