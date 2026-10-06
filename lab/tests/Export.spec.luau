-- Export: bounded, immutable ResultStore pages and the cross-language fixtures read by tools/validate-results.mjs.
local Test = require("./Test")
local Json = require("../src/Util/Json")
local ResultStore = require("../src/Experiment/ResultStore")

local suite = Test.suite("Export")

local function decodePages(store: any, kind: string): ({ any }, { string })
	local m = store:manifest(kind)
	local records, pages = {}, {}
	for i = 1, m.pageCount do
		local text = store:page(kind, i)
		table.insert(pages, text)
		local page = Json.decode(text)
		for _, r in page.records do
			table.insert(records, r)
		end
	end
	return records, pages
end

local function varied(i: number): any
	-- record sizes vary; some strings are multi-byte so bytes ~= characters
	local note = string.rep(if i % 3 == 0 then "\u{e9}" else "a", (i * 37) % 120)
	return { i = i, note = note, x = i / 7, flag = i % 2 == 0 }
end

Test.case(suite, "pages never exceed maxPageBytes in UTF-8 bytes and pack adaptively", function()
	local store = ResultStore.new({ runId = "run-1", maxPageBytes = 600 })
	local input = {}
	for i = 1, 200 do
		table.insert(input, varied(i))
	end
	store:put("rows", input)
	local records, pages = decodePages(store, "rows")
	Test.truthy(#pages > 5, "several pages")
	local counts: { [number]: boolean } = {}
	local multibyteSeen = false
	for pi, text in pages do
		Test.truthy(#text <= 600, "page " .. pi .. " is " .. #text .. " bytes")
		local page = Json.decode(text)
		counts[#page.records] = true
		Test.eq(page.kind, "rows")
		Test.eq(page.runId, "run-1")
		Test.eq(page.pageIndex, pi)
		Test.eq(page.rowCount, #page.records)
		if (utf8.len(text) :: number) < #text then
			multibyteSeen = true
		end
		-- greedy: the next record would not have fitted on this page
		if pi < #pages then
			local nextRecord = Json.decode(pages[pi + 1]).records[1]
			local extraDigits = #tostring(#page.records + 1) - #tostring(#page.records)
			Test.truthy(#text + 1 + #Json.encode(nextRecord) + extraDigits > 600, "page " .. pi .. " packed greedily")
		end
	end
	Test.truthy(multibyteSeen, "fixture exercises multi-byte text")
	local distinct = 0
	for _ in counts do
		distinct += 1
	end
	Test.truthy(distinct > 1, "record counts per page adapt to record sizes")
	Test.eq(#records, 200)
	for i, r in records do
		Test.eq(Json.encode(r), Json.encode(input[i]), "record " .. i .. " order and content")
	end
	local m = store:manifest("rows")
	local bytes = 0
	for _, text in pages do
		bytes += #text
	end
	Test.eq(m.byteCount, bytes)
	Test.eq(m.rowCount, 200)
	Test.eq(m.pageCount, #pages)
	Test.eq(m.kind, "rows")
	Test.eq(m.runId, "run-1")
	Test.eq(m.maxPageBytes, 600)
	for i, b in m.pageBytes do
		Test.eq(b, #pages[i])
	end
	-- each page is canonical: decode then encode reproduces the bytes
	for _, text in pages do
		Test.eq(Json.encode(Json.decode(text)), text)
	end
end)

Test.case(suite, "default cap is 48 KiB; larger caps are refused", function()
	local store = ResultStore.new({ runId = "run-1" })
	Test.eq(store:maxPageBytes(), 49152)
	Test.throws(function() ResultStore.new({ runId = "run-1", maxPageBytes = 49153 }) end, "maxPageBytes")
	Test.throws(function() ResultStore.new({ runId = "run-1", maxPageBytes = 0 }) end, "maxPageBytes")
	Test.throws(function() ResultStore.new({ runId = "bad id" }) end, "runId")
	-- a realistic forecast export spans several 48 KiB pages
	local records = {}
	for i = 1, 1500 do
		table.insert(records, {
			id = "run-1:R50-RAW_PHYSICS:SPY:" .. tostring(1600000000 + i * 3600),
			runId = "run-1", modelId = "R50-RAW_PHYSICS", symbol = "SPY", t = 1600000000 + i * 3600,
			decisionTime = 1600003600 + i * 3600, outcomeTime = 1600032400 + i * 3600, prediction = math.sin(i) / 300,
			modelHash = string.rep("a", 64), dataHash = string.rep("b", 64),
		})
	end
	store:put("forecasts", records)
	local m = store:manifest("forecasts")
	Test.truthy(m.pageCount >= 3, "multiple pages")
	for i = 1, m.pageCount do
		Test.truthy(#store:page("forecasts", i) <= 49152)
	end
	Test.eq(m.rowCount, 1500)
end)

Test.case(suite, "pages are immutable once produced", function()
	local store = ResultStore.new({ runId = "run-1", maxPageBytes = 400 })
	local first = {}
	for i = 1, 30 do
		table.insert(first, varied(i))
	end
	store:put("rows", first)
	local n = store:pageCount("rows")
	local page1 = store:page("rows", 1)
	local lastText = store:page("rows", n) -- reading the open trailing page seals it
	store:put("rows", { varied(31), varied(32) })
	Test.eq(store:page("rows", 1), page1)
	Test.eq(store:page("rows", n), lastText, "the trailing page did not grow after it was read")
	Test.truthy(store:pageCount("rows") > n, "later records start a new page")
	local p = Json.decode(store:page("rows", n + 1))
	Test.eq(p.records[1].i, 31)
	Test.eq(p.firstRow, 31)
	Test.throws(function() store:page("rows", 0) end, "page")
	Test.throws(function() store:page("rows", store:pageCount("rows") + 1) end, "page")
	Test.throws(function() store:page("nope", 1) end, "kind")
end)

Test.case(suite, "an oversized record is an explicit error and changes nothing", function()
	local store = ResultStore.new({ runId = "run-1", maxPageBytes = 300 })
	store:put("rows", { { a = 1 } })
	Test.throws(function() store:put("rows", { { a = 2 }, { big = string.rep("x", 400) } }) end, "larger than maxPageBytes")
	Test.throws(function() store:put("rows", { { a = 2 }, { bad = 0 / 0 } }) end, "non-finite")
	Test.throws(function() store:put("rows", { { a = 2 }, { 1, b = 2 } }) end, "mixed")
	local m = store:manifest("rows")
	Test.eq(m.rowCount, 1, "failed batches are atomic")
	Test.eq(Json.decode(store:page("rows", 1)).records[1].a, 1)
end)

Test.case(suite, "manifest seals a kind; records are snapshotted at put time", function()
	local store = ResultStore.new({ runId = "run-1", maxPageBytes = 1000 })
	local rec = { v = 1 }
	store:put("rows", { rec })
	rec.v = 2 -- caller mutation after put
	local m = store:manifest("rows")
	Test.eq(Json.decode(store:page("rows", 1)).records[1].v, 1)
	Test.throws(function() store:put("rows", { { v = 3 } }) end, "sealed")
	Test.eq(store:manifest("rows").byteCount, m.byteCount, "manifest stable")
	local mj = Json.decode(store:manifestJson("rows"))
	Test.eq(mj.kind, "rows")
	Test.eq(mj.pageCount, 1)
	Test.eq(mj.rowCount, 1)
	Test.eq(mj.byteCount, #store:page("rows", 1))
	Test.eq(mj.format, ResultStore.FORMAT)
	Test.throws(function() store:put("bad kind", { {} }) end, "kind")
	Test.throws(function() store:put("rows2", { a = 1 } :: any) end, "array")
	Test.throws(function() store:manifest("unknown") end, "kind")
	store:put("empty", {})
	Test.eq(store:manifest("empty").pageCount, 0)
	Test.eq(store:manifest("empty").byteCount, 0)
	Test.deepEq(store:kinds(), { "empty", "rows" })
end)

Test.case(suite, "host acknowledgements must match run and artifact kind", function()
	local sha = string.rep("0123456789abcdef", 4)
	local ack = '{"artifactKind":"model","runId":"run-1","sha256":"' .. sha .. '"}'
	local parsed = ResultStore.parseAcknowledgement(ack, { runId = "run-1", artifactKind = "model" })
	Test.eq(parsed.sha256, sha)
	Test.throws(function() ResultStore.parseAcknowledgement(ack, { runId = "run-2", artifactKind = "model" }) end, "run")
	Test.throws(function() ResultStore.parseAcknowledgement(ack, { runId = "run-1", artifactKind = "forecasts" }) end, "kind")
	Test.throws(function()
		ResultStore.parseAcknowledgement('{"artifactKind":"model","runId":"run-1","sha256":"ABC"}', { runId = "run-1", artifactKind = "model" })
	end, "sha256")
	Test.throws(function()
		ResultStore.parseAcknowledgement('{"artifactKind":"model","extra":1,"runId":"run-1","sha256":"' .. sha .. '"}',
			{ runId = "run-1", artifactKind = "model" })
	end, "field")
	Test.throws(function()
		ResultStore.parseAcknowledgement(ack, { runId = "run-1", artifactKind = "model", sha256 = string.rep("f", 64) })
	end, "stale")
end)

Test.case(suite, "PRNG vector fixture matches this implementation", function()
	local PrngVectorsBuilder = require("./fixtures/PrngVectorsBuilder")
	local stored = require("./fixtures/PrngVectors")
	Test.eq(PrngVectorsBuilder.build(), stored, "regenerate with: node tools/gen-result-fixtures.mjs")
end)

Test.case(suite, "export sample fixture matches this implementation", function()
	local ExportSampleBuilder = require("./fixtures/ExportSampleBuilder")
	local stored = require("./fixtures/ExportSample")
	Test.eq(ExportSampleBuilder.build(), stored, "regenerate with: node tools/gen-result-fixtures.mjs")
	-- every page in the sample respects its cap
	local sample = Json.decode(stored)
	for kind, entry in sample.kinds do
		for i, text in entry.pages do
			Test.truthy(#text <= sample.maxPageBytes, kind .. " page " .. i)
		end
	end
end)

return suite
