--!strict
-- Append-only forecast ledger, separate failure records, and a separate outcome store.
--
-- * Forecast id = runId..":"..modelId..":"..symbol..":"..tostring(t). runId, modelId and symbol may contain only
--   ASCII letters, digits, underscores and hyphens, so the id parses back unambiguously. t must be an integer
--   whose tostring is plain digits (identical text in Luau and JavaScript).
-- * decisionTime must equal t + barSeconds and outcomeTime must equal decisionTime + horizonHours*barSeconds
--   (defaults from Config: 3600 and 8).
-- * Stored records are copies, frozen; duplicate ids are rejected, never overwritten. Pages are fresh arrays.
--   Records must be plain tables (no metatable), so the fields validated are exactly the fields stored.
-- * A model failure is a failure record (no prediction field), never a numeric zero forecast. A forecast and a
--   failure can never share an id.
-- * Outcomes live in a separate store keyed by forecast id; adding one never touches a forecast.
local Types = require("../Types")
local Config = require("../Config")

type Forecast = Types.Forecast
type Outcome = Types.Outcome

export type Failure = {
	id: string,
	runId: string,
	modelId: string,
	symbol: string,
	t: number,
	decisionTime: number,
	reason: string,
	detail: string?,
	phase: string?,
}

export type Ledger = {
	append: (self: Ledger, record: Forecast) -> (),
	appendFailure: (self: Ledger, record: { [string]: any }) -> Failure,
	page: (self: Ledger, startIndex: number, limit: number) -> { Forecast },
	count: (self: Ledger) -> number,
	get: (self: Ledger, id: string) -> Forecast?,
	failurePage: (self: Ledger, startIndex: number, limit: number) -> { Failure },
	failureCount: (self: Ledger) -> number,
	getFailure: (self: Ledger, id: string) -> Failure?,
	metadata: (self: Ledger) -> { runId: string, barSeconds: number, horizonHours: number },
}

export type OutcomeStore = {
	add: (self: OutcomeStore, record: Outcome) -> (),
	get: (self: OutcomeStore, forecastId: string) -> Outcome?,
	page: (self: OutcomeStore, startIndex: number, limit: number) -> { Outcome },
	count: (self: OutcomeStore) -> number,
}

export type ParsedId = { runId: string, modelId: string, symbol: string, t: number }

local Ledger = {}

local NAME_PATTERN = "^[A-Za-z0-9_%-]+$"

local FORECAST_FIELDS = {
	id = true, runId = true, modelId = true, symbol = true, t = true, decisionTime = true,
	outcomeTime = true, prediction = true, modelHash = true, dataHash = true,
}
local FAILURE_FIELDS = {
	id = true, runId = true, modelId = true, symbol = true, t = true, decisionTime = true,
	reason = true, detail = true, phase = true,
}
local OUTCOME_FIELDS = { forecastId = true, eligible = true, actual = true, exclusionReason = true }

local REASONS: { [string]: boolean } = {}
for _, r in Types.EXCLUSION_REASONS do
	REASONS[r] = true
end

local function isFinite(x: any): boolean
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function isName(s: any): boolean
	return type(s) == "string" and string.find(s, NAME_PATTERN) ~= nil
end

local function checkName(field: string, s: any)
	if not isName(s) then
		error(string.format("Ledger: invalid %s %s (letters, digits, underscores, hyphens only)", field, tostring(s)), 3)
	end
end

-- Integer seconds whose tostring is plain digits, so ids read the same in Luau and JavaScript.
local function isCanonicalTime(t: any): boolean
	return isFinite(t) and t == math.floor(t) and t >= 0 and tostring(t) == string.format("%.0f", t)
end

local function checkTime(field: string, t: any)
	if not isCanonicalTime(t) then
		error(string.format("Ledger: %s must be a non-negative integer number of seconds, got %s", field, tostring(t)), 3)
	end
end

local function checkFields(record: any, allowed: { [string]: boolean }, what: string)
	if type(record) ~= "table" then
		error("Ledger: " .. what .. " must be a table", 3)
	end
	-- Fields are validated by indexing but stored by raw copy; a metatable (__index/__iter proxy) would let the
	-- two disagree, so only plain tables (frozen or not) are accepted.
	if getmetatable(record) ~= nil then
		error("Ledger: " .. what .. " must be a plain table without a metatable", 3)
	end
	for k in record do
		if type(k) ~= "string" or not allowed[k] then
			error("Ledger: unknown field " .. tostring(k) .. " in " .. what, 3)
		end
	end
end

local function frozenCopy(record: { [string]: any }): any
	local copy = {}
	for k, v in record do
		if type(v) == "table" then
			error("Ledger: nested tables are not allowed in records (field " .. tostring(k) .. ")", 3)
		end
		copy[k] = v
	end
	return table.freeze(copy)
end

local function checkPageArgs(startIndex: any, limit: any)
	if type(startIndex) ~= "number" or startIndex ~= math.floor(startIndex) or startIndex < 1 then
		error("Ledger: page start must be an integer >= 1", 3)
	end
	if type(limit) ~= "number" or limit ~= math.floor(limit) or limit < 0 then
		error("Ledger: page limit must be an integer >= 0", 3)
	end
end

local function slice(list: { any }, startIndex: number, limit: number): { any }
	local out = {}
	local last = math.min(#list, startIndex + limit - 1)
	for i = startIndex, last do
		table.insert(out, list[i])
	end
	return out
end

function Ledger.isName(s: any): boolean
	return isName(s)
end

function Ledger.forecastId(runId: string, modelId: string, symbol: string, t: number): string
	checkName("runId", runId)
	checkName("modelId", modelId)
	checkName("symbol", symbol)
	checkTime("t", t)
	return runId .. ":" .. modelId .. ":" .. symbol .. ":" .. tostring(t)
end

function Ledger.parseId(id: string): ParsedId
	if type(id) ~= "string" then
		error("Ledger: id must be a string", 2)
	end
	local runId, modelId, symbol, tText = string.match(id, "^([^:]+):([^:]+):([^:]+):([^:]+)$")
	if not runId or not isName(runId) or not isName(modelId) or not isName(symbol) then
		error("Ledger: malformed forecast id " .. id, 2)
	end
	local t = tonumber(tText)
	if not isCanonicalTime(t) or tostring(t) ~= tText then
		error("Ledger: malformed timestamp in forecast id " .. id, 2)
	end
	return table.freeze({ runId = runId :: string, modelId = modelId :: string, symbol = symbol :: string, t = t :: number }) :: any
end

local function resolveTiming(metadata: { [string]: any }): (number, number)
	local bar = metadata.barSeconds or Config.values.barSeconds
	local horizon = metadata.horizonHours or Config.values.horizonHours
	if not isFinite(bar) or bar <= 0 or bar ~= math.floor(bar) then
		error("Ledger: barSeconds must be a positive integer", 3)
	end
	if not isFinite(horizon) or horizon <= 0 or horizon ~= math.floor(horizon) then
		error("Ledger: horizonHours must be a positive integer", 3)
	end
	return bar, horizon
end

function Ledger.new(metadata: { runId: string, barSeconds: number?, horizonHours: number? }): Ledger
	if type(metadata) ~= "table" then
		error("Ledger: metadata table required", 2)
	end
	if not isName(metadata.runId) then
		error("Ledger: invalid runId " .. tostring(metadata.runId) .. " (letters, digits, underscores, hyphens only)", 2)
	end
	local runId = metadata.runId
	local bar, horizon = resolveTiming(metadata :: any)
	local meta = table.freeze({ runId = runId, barSeconds = bar, horizonHours = horizon })

	local records: { Forecast } = {}
	local byId: { [string]: Forecast } = {}
	local failures: { Failure } = {}
	local failureById: { [string]: Failure } = {}

	local self = {}

	function self.append(_: any, record: Forecast)
		checkFields(record, FORECAST_FIELDS, "forecast")
		local r = record :: any
		if r.runId ~= runId then
			error(string.format("Ledger: forecast runId %s does not match ledger run %s", tostring(r.runId), runId), 2)
		end
		checkName("modelId", r.modelId)
		checkName("symbol", r.symbol)
		checkTime("t", r.t)
		if r.decisionTime ~= r.t + bar then
			error("Ledger: decisionTime must equal t + " .. bar, 2)
		end
		if r.outcomeTime ~= r.decisionTime + horizon * bar then
			error("Ledger: outcomeTime must equal decisionTime + " .. horizon * bar, 2)
		end
		if not isFinite(r.prediction) then
			error("Ledger: prediction must be a finite number, got " .. tostring(r.prediction), 2)
		end
		if type(r.modelHash) ~= "string" or r.modelHash == "" then
			error("Ledger: modelHash must be a non-empty string", 2)
		end
		if type(r.dataHash) ~= "string" or r.dataHash == "" then
			error("Ledger: dataHash must be a non-empty string", 2)
		end
		local expected = Ledger.forecastId(runId, r.modelId, r.symbol, r.t)
		if r.id ~= expected then
			error(string.format("Ledger: forecast id %s does not match expected id %s", tostring(r.id), expected), 2)
		end
		if byId[expected] then
			error("Ledger: duplicate forecast id " .. expected, 2)
		end
		if failureById[expected] then
			error("Ledger: a failure record already exists for id " .. expected, 2)
		end
		local stored = frozenCopy(r)
		table.insert(records, stored)
		byId[expected] = stored
	end

	function self.appendFailure(_: any, record: { [string]: any }): Failure
		if type(record) == "table" and record.prediction ~= nil then
			error("Ledger: a failure record must not carry a prediction", 2)
		end
		checkFields(record, FAILURE_FIELDS, "failure")
		if record.runId ~= runId then
			error(string.format("Ledger: failure runId %s does not match ledger run %s", tostring(record.runId), runId), 2)
		end
		checkName("modelId", record.modelId)
		checkName("symbol", record.symbol)
		checkTime("t", record.t)
		if type(record.reason) ~= "string" or record.reason == "" or utf8.len(record.reason) == nil then
			error("Ledger: failure reason must be a non-empty UTF-8 string", 2)
		end
		for _, opt in { "detail", "phase" } do
			local v = record[opt]
			if v ~= nil and (type(v) ~= "string" or utf8.len(v) == nil) then
				error("Ledger: failure " .. opt .. " must be a UTF-8 string", 2)
			end
		end
		if record.decisionTime ~= nil and record.decisionTime ~= record.t + bar then
			error("Ledger: failure decisionTime must equal t + " .. bar, 2)
		end
		local id = Ledger.forecastId(runId, record.modelId, record.symbol, record.t)
		if record.id ~= nil and record.id ~= id then
			error(string.format("Ledger: failure id %s does not match expected id %s", tostring(record.id), id), 2)
		end
		if byId[id] then
			error("Ledger: a forecast already exists for id " .. id, 2)
		end
		if failureById[id] then
			error("Ledger: duplicate failure id " .. id, 2)
		end
		local copy = {
			id = id,
			runId = runId,
			modelId = record.modelId,
			symbol = record.symbol,
			t = record.t,
			decisionTime = record.t + bar,
			reason = record.reason,
			detail = record.detail,
			phase = record.phase,
		}
		local stored = table.freeze(copy) :: any
		table.insert(failures, stored)
		failureById[id] = stored
		return stored
	end

	function self.page(_: any, startIndex: number, limit: number): { Forecast }
		checkPageArgs(startIndex, limit)
		return slice(records, startIndex, limit)
	end

	function self.count(_: any): number
		return #records
	end

	function self.get(_: any, id: string): Forecast?
		return byId[id]
	end

	function self.failurePage(_: any, startIndex: number, limit: number): { Failure }
		checkPageArgs(startIndex, limit)
		return slice(failures, startIndex, limit)
	end

	function self.failureCount(_: any): number
		return #failures
	end

	function self.getFailure(_: any, id: string): Failure?
		return failureById[id]
	end

	function self.metadata(_: any)
		return meta
	end

	return table.freeze(self) :: any
end

-- Validates one outcome record against the Types.Outcome contract; returns the parsed forecast id.
function Ledger.validateOutcome(record: any, runId: string?): ParsedId
	checkFields(record, OUTCOME_FIELDS, "outcome")
	local ok, parsed = pcall(Ledger.parseId, record.forecastId)
	if not ok then
		error("Ledger: outcome forecastId invalid: " .. tostring(parsed), 2)
	end
	if runId ~= nil and parsed.runId ~= runId then
		error(string.format("Ledger: outcome run %s does not match store run %s", parsed.runId, runId), 2)
	end
	if type(record.eligible) ~= "boolean" then
		error("Ledger: outcome eligible must be a boolean", 2)
	end
	if record.eligible then
		if not isFinite(record.actual) then
			error("Ledger: eligible outcome needs a finite actual", 2)
		end
		if record.exclusionReason ~= nil then
			error("Ledger: eligible outcome must not have an exclusionReason", 2)
		end
	else
		if record.actual ~= nil then
			error("Ledger: excluded outcome must not carry an actual", 2)
		end
		if not REASONS[record.exclusionReason] then
			error("Ledger: unknown exclusionReason " .. tostring(record.exclusionReason), 2)
		end
	end
	return parsed
end

function Ledger.newOutcomes(metadata: { runId: string? }?): OutcomeStore
	local runId: string? = nil
	if metadata ~= nil then
		if type(metadata) ~= "table" then
			error("Ledger: outcome metadata must be a table", 2)
		end
		if metadata.runId ~= nil then
			if not isName(metadata.runId) then
				error("Ledger: invalid runId " .. tostring(metadata.runId), 2)
			end
			runId = metadata.runId
		end
	end
	local records: { Outcome } = {}
	local byId: { [string]: Outcome } = {}
	local self = {}

	function self.add(_: any, record: Outcome)
		local ok, err = pcall(Ledger.validateOutcome, record, runId)
		if not ok then
			error(err, 2)
		end
		local id = (record :: any).forecastId
		if byId[id] then
			error("Ledger: duplicate outcome for forecast id " .. id, 2)
		end
		local stored = frozenCopy(record :: any)
		table.insert(records, stored)
		byId[id] = stored
	end

	function self.get(_: any, forecastId: string): Outcome?
		return byId[forecastId]
	end

	function self.page(_: any, startIndex: number, limit: number): { Outcome }
		checkPageArgs(startIndex, limit)
		return slice(records, startIndex, limit)
	end

	function self.count(_: any): number
		return #records
	end

	return table.freeze(self) :: any
end

return table.freeze(Ledger)
