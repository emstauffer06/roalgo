--!strict
-- Bounded, immutable JSON export pages for the Studio-to-host bridge (plan Task 5, "Concrete export path").
--
-- * put(kind, records) encodes every record immediately with Util/Json (a snapshot: later caller mutation has no
--   effect) and appends it to the kind's open page. A batch is atomic: an encoding error or an oversized record
--   leaves the store unchanged.
-- * Pages are packed greedily with adaptive record counts. Each page is one JSON object
--     {"firstRow":F,"kind":K,"pageIndex":I,"records":[...],"rowCount":N,"runId":R}
--   (keys in sorted order, so decode->encode reproduces the bytes) whose UTF-8 byte length (#text) is at most
--   maxPageBytes. A record that cannot fit on an empty page is an explicit error.
-- * A page is immutable once produced: full pages are sealed as they fill, and reading the open trailing page
--   with page() seals it, so later records start a new page.
-- * manifest(kind) seals the kind (no further puts) and returns {format, kind, runId, pageCount, rowCount,
--   byteCount, maxPageBytes, pageBytes}. Hashing is the host's job (tools/validate-results.mjs, SHA-256).
-- * parseAcknowledgement validates the host's {runId, artifactKind, sha256} acknowledgement record.
local Json = require("../Util/Json")
local Config = require("../Config")
local Ledger = require("./Ledger")

local ResultStore = {}
ResultStore.FORMAT = "mrl-resultstore-1"
ResultStore.MAX_PAGE_BYTES = Config.values.resultStore.maxPageBytes :: number

export type Manifest = {
	format: string,
	kind: string,
	runId: string,
	pageCount: number,
	rowCount: number,
	byteCount: number,
	maxPageBytes: number,
	pageBytes: { number },
}

export type ResultStore = {
	put: (self: ResultStore, kind: string, records: { any }) -> (),
	page: (self: ResultStore, kind: string, pageIndex: number) -> string,
	pageCount: (self: ResultStore, kind: string) -> number,
	manifest: (self: ResultStore, kind: string) -> Manifest,
	manifestJson: (self: ResultStore, kind: string) -> string,
	kinds: (self: ResultStore) -> { string },
	maxPageBytes: (self: ResultStore) -> number,
	runId: (self: ResultStore) -> string,
}

type KindState = {
	sealed: { string },
	open: { string },
	openBytes: number,
	firstRow: number, -- row number of the first record on the open page
	rowCount: number,
	closed: boolean,
}

local function isArray(t: any): boolean
	if type(t) ~= "table" or getmetatable(t) ~= nil then
		return false
	end
	local count = 0
	for k in t do
		if type(k) ~= "number" then
			return false
		end
		count += 1
	end
	return count == #t
end

function ResultStore.new(opts: { runId: string, maxPageBytes: number? }): ResultStore
	if type(opts) ~= "table" then
		error("ResultStore: options table required", 2)
	end
	if not Ledger.isName(opts.runId) then
		error("ResultStore: invalid runId " .. tostring(opts.runId) .. " (letters, digits, underscores, hyphens only)", 2)
	end
	local cap = opts.maxPageBytes or ResultStore.MAX_PAGE_BYTES
	if type(cap) ~= "number" or cap ~= math.floor(cap) or cap < 1 or cap > ResultStore.MAX_PAGE_BYTES then
		error("ResultStore: maxPageBytes must be an integer in [1, " .. ResultStore.MAX_PAGE_BYTES .. "]", 2)
	end
	local runId = opts.runId
	local runJson = Json.encodeString(runId)
	local states: { [string]: KindState } = {}
	local kindJson: { [string]: string } = {}

	local function pageSize(kind: string, firstRow: number, pageIndex: number, count: number, recordBytes: number): number
		return 12 + #Json.encodeNumber(firstRow) -- {"firstRow":
			+ 8 + #kindJson[kind] -- ,"kind":
			+ 13 + #Json.encodeNumber(pageIndex) -- ,"pageIndex":
			+ 12 + recordBytes + math.max(count - 1, 0) -- ,"records":[ ... ]
			+ 13 + #Json.encodeNumber(count) -- ],"rowCount":
			+ 9 + #runJson -- ,"runId":
			+ 1 -- }
	end

	local function pageText(kind: string, firstRow: number, pageIndex: number, records: { string }): string
		local text = '{"firstRow":' .. Json.encodeNumber(firstRow)
			.. ',"kind":' .. kindJson[kind]
			.. ',"pageIndex":' .. Json.encodeNumber(pageIndex)
			.. ',"records":[' .. table.concat(records, ",")
			.. '],"rowCount":' .. Json.encodeNumber(#records)
			.. ',"runId":' .. runJson .. "}"
		return text
	end

	local function seal(kind: string, st: KindState)
		if #st.open == 0 then
			return
		end
		local text = pageText(kind, st.firstRow, #st.sealed + 1, st.open)
		local expected = pageSize(kind, st.firstRow, #st.sealed + 1, #st.open, st.openBytes)
		if #text ~= expected or #text > cap then
			error(string.format("ResultStore: internal page size mismatch (%d vs %d, cap %d)", #text, expected, cap), 0)
		end
		table.insert(st.sealed, text)
		st.firstRow += #st.open
		st.open = {}
		st.openBytes = 0
	end

	local function stateOf(kind: string): KindState
		local st = states[kind]
		if not st then
			error("ResultStore: unknown kind " .. tostring(kind), 3)
		end
		return st
	end

	local self = {}

	function self.put(_: any, kind: string, records: { any })
		if not Ledger.isName(kind) then
			error("ResultStore: invalid kind " .. tostring(kind) .. " (letters, digits, underscores, hyphens only)", 2)
		end
		if not isArray(records) then
			error("ResultStore: records must be an array", 2)
		end
		local existing = states[kind]
		if existing and existing.closed then
			error("ResultStore: kind " .. kind .. " is sealed by its manifest", 2)
		end
		if not kindJson[kind] then
			kindJson[kind] = Json.encodeString(kind)
		end
		-- encode everything first (snapshot + atomic failure)
		local encoded: { string } = {}
		for i, r in records do
			local ok, res = pcall(Json.encode, r)
			if not ok then
				error(string.format("ResultStore: record %d of %s cannot be encoded: %s", i, kind, tostring(res)), 2)
			end
			encoded[i] = res
		end
		-- pack on a working copy, then commit
		local base = existing or { sealed = {}, open = {}, openBytes = 0, firstRow = 1, rowCount = 0, closed = false }
		local work: KindState = {
			sealed = table.clone(base.sealed),
			open = table.clone(base.open),
			openBytes = base.openBytes,
			firstRow = base.firstRow,
			rowCount = base.rowCount,
			closed = false,
		}
		for i, text in encoded do
			local pageIndex = #work.sealed + 1
			if pageSize(kind, work.firstRow, pageIndex, #work.open + 1, work.openBytes + #text) > cap then
				if #work.open > 0 then
					seal(kind, work)
				end
				if pageSize(kind, work.firstRow, #work.sealed + 1, 1, #text) > cap then
					error(string.format("ResultStore: record %d of %s (%d bytes encoded) is larger than maxPageBytes %d",
						i, kind, #text, cap), 2)
				end
			end
			table.insert(work.open, text)
			work.openBytes += #text
			work.rowCount += 1
		end
		states[kind] = work
	end

	function self.pageCount(_: any, kind: string): number
		local st = stateOf(kind)
		return #st.sealed + (if #st.open > 0 then 1 else 0)
	end

	function self.page(_: any, kind: string, pageIndex: number): string
		local st = stateOf(kind)
		local total = #st.sealed + (if #st.open > 0 then 1 else 0)
		if type(pageIndex) ~= "number" or pageIndex ~= math.floor(pageIndex) or pageIndex < 1 or pageIndex > total then
			error(string.format("ResultStore: page index %s out of range 1..%d for %s", tostring(pageIndex), total, kind), 2)
		end
		if pageIndex > #st.sealed then
			seal(kind, st)
		end
		return st.sealed[pageIndex]
	end

	function self.manifest(_: any, kind: string): Manifest
		local st = stateOf(kind)
		seal(kind, st)
		st.closed = true
		local bytes, sizes: { number } = 0, {}
		for i, text in st.sealed do
			sizes[i] = #text
			bytes += #text
		end
		return table.freeze({
			format = ResultStore.FORMAT,
			kind = kind,
			runId = runId,
			pageCount = #st.sealed,
			rowCount = st.rowCount,
			byteCount = bytes,
			maxPageBytes = cap,
			pageBytes = table.freeze(sizes),
		}) :: any
	end

	function self.manifestJson(_: any, kind: string): string
		local m = (self :: any).manifest(self, kind)
		local plain = table.clone(m) :: any
		plain.pageBytes = table.clone(m.pageBytes)
		return Json.encode(plain)
	end

	function self.kinds(_: any): { string }
		local out = {}
		for k in states do
			table.insert(out, k)
		end
		table.sort(out)
		return out
	end

	function self.maxPageBytes(_: any): number
		return cap
	end

	function self.runId(_: any): string
		return runId
	end

	return table.freeze(self) :: any
end

local ACK_FIELDS = { runId = true, artifactKind = true, sha256 = true }

-- Validates a host acknowledgement {runId, artifactKind, sha256}. expected.runId and expected.artifactKind must
-- match; when expected.sha256 is given (a previously acknowledged hash), a different hash is a stale record.
function ResultStore.parseAcknowledgement(text: string, expected: { runId: string, artifactKind: string, sha256: string? })
	local ok, value = pcall(Json.decode, text)
	if not ok then
		error("ResultStore: acknowledgement is not valid JSON: " .. tostring(value), 2)
	end
	if type(value) ~= "table" or isArray(value) and next(value) ~= nil then
		error("ResultStore: acknowledgement must be a JSON object", 2)
	end
	for k in value do
		if not ACK_FIELDS[k] then
			error("ResultStore: unknown field " .. tostring(k) .. " in acknowledgement", 2)
		end
	end
	for k in ACK_FIELDS do
		if type(value[k]) ~= "string" then
			error("ResultStore: acknowledgement field " .. k .. " must be a string", 2)
		end
	end
	if not string.match(value.sha256, "^" .. string.rep("[0-9a-f]", 64) .. "$") then
		error("ResultStore: acknowledgement sha256 must be 64 lowercase hex digits", 2)
	end
	if value.runId ~= expected.runId then
		error(string.format("ResultStore: acknowledgement is for run %s, expected run %s", value.runId, tostring(expected.runId)), 2)
	end
	if value.artifactKind ~= expected.artifactKind then
		error(string.format("ResultStore: acknowledgement is for kind %s, expected kind %s", value.artifactKind,
			tostring(expected.artifactKind)), 2)
	end
	if expected.sha256 ~= nil and value.sha256 ~= expected.sha256 then
		error("ResultStore: stale acknowledgement (sha256 differs from the expected artifact hash)", 2)
	end
	return table.freeze({ runId = value.runId, artifactKind = value.artifactKind, sha256 = value.sha256 })
end

return table.freeze(ResultStore)
