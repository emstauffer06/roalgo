-- SpringFeaturesPass spec (spring-live-contract.md section 1b, L15). Self-running:
--   luau.exe tests/SpringFeaturesPass.spec.luau
-- Pure logic with a FAKE Features (one scripted output per step), so every rule of the pass is exercised without data:
-- one step per bar, order, page handling, yields every K bars, rejected bars, malformed drives, digest stability.
-- The real thing (the capture-time v2 Features over the 2024 bars, 2,268 records bit for bit) is proven by
-- tests/spring-features-pass.test.mjs. Known-answer digests below were computed by an independent Node oracle.
local loaded, SpringFeaturesPass = pcall(require, "../src/SpringFeaturesPass")
assert(loaded and type(SpringFeaturesPass) == "table" and type(SpringFeaturesPass.new) == "function",
	"SpringFeaturesPass must load: " .. tostring(SpringFeaturesPass))
local passed = 0
local function test(name, fn) fn(); passed += 1; print("PASS " .. name) end

local NEG_ZERO = -0
assert(1 / NEG_ZERO == -math.huge, "fixture sanity: -0 is negative zero in this Luau")
local NONE = {} -- a mutate hook returns NONE to make the fake Features return nil

local function raises(fn, needle, what)
	local ok, err = pcall(fn)
	assert(not ok, (what or needle or "call") .. ": expected an error")
	if needle then
		assert(string.find(tostring(err), needle, 1, true), (what or needle) .. ": error was " .. tostring(err))
	end
	return tostring(err)
end
-- bit-exact equality of two doubles (tells 0 from -0, 1 ulp from equal)
local function sameBits(a, b)
	return type(a) == "number" and type(b) == "number" and string.pack("<d", a) == string.pack("<d", b)
end
-- a double that is different from x in the last bit (or the smallest subnormal when x is zero)
local function bump(x)
	if x == 0 then return 5e-324 end
	local sign = if x < 0 then -1 else 1
	local low, high = string.unpack("<I4I4", string.pack("<d", math.abs(x)))
	if low == 4294967295 then low, high = 0, high + 1 else low += 1 end
	local y = sign * string.unpack("<d", string.pack("<I4I4", low, high))
	assert(not sameBits(x, y))
	return y
end

local T0 = 1731940200
local function bar(k, shift)
	return { t = T0 + (k - 1) * 300 + (shift or 0), o = 100 + k, h = 101 + k, l = 99 + k, c = 100.5 + k, day = "2024-11-18" }
end
local function bars(from, to)
	local out = {}
	for k = from, to do out[#out + 1] = bar(k) end
	return out
end

-- A fake Features: step k returns values that depend only on k, so changing a bar's t changes nothing else.
--   opts.regime = true         adds a 3-entry regime
--   opts.mutate(out, k)        edit (or replace, or NONE) the k-th result before it is returned
--   opts.raiseAt = k           the k-th step raises
local function makeFake(opts)
	opts = opts or {}
	local fake = { steps = 0, seen = {}, outputs = {} }
	function fake:step(b)
		self.steps += 1
		local k = self.steps
		table.insert(self.seen, b)
		if opts.raiseAt == k then error("fake features exploded at " .. k) end
		local drive = table.create(8)
		for j = 1, 8 do drive[j] = math.sin(k * 0.37 + j) * 1.5 end
		local out = { t = b.t, drive = drive, volatility = 0.001 + k * 1e-5, ready = k >= 12, reset = k == 1 }
		if opts.regime then out.regime = { 0.2 + k * 1e-3, 0.3, 0.5 - k * 1e-3 } end
		if opts.mutate then
			local replaced = opts.mutate(out, k)
			if replaced == NONE then out = nil elseif replaced ~= nil then out = replaced end
		end
		self.outputs[k] = out
		return out
	end
	return fake
end
-- A Features that replays scripted rows (for the known-answer digests).
local function scripted(rows)
	local fake = { steps = 0 }
	function fake:step(b)
		self.steps += 1
		local r = rows[self.steps]
		assert(r and r.t == b.t, "scripted features: bar does not match the script")
		return {
			t = if r.withT == false then nil else r.t,
			drive = table.clone(r.drive), volatility = r.volatility, ready = r.ready, reset = r.reset,
			regime = if r.regime then table.clone(r.regime) else nil,
		}
	end
	return fake
end

local function newPass(fake, extra)
	local options = { features = fake, yield = false }
	for k, v in extra or {} do options[k] = v end
	return SpringFeaturesPass.new(options)
end
local function fill(pass, from, to)
	for k = from, to do pass:push(bar(k)) end
	return pass
end
-- a pass over bars 1..n of a fresh fake
local function built(n, opts, extra)
	local fake = makeFake(opts)
	return fill(newPass(fake, extra), 1, n), fake
end

test("new validates its options and defaults to 512 / hex", function()
	raises(function() SpringFeaturesPass.new() end, "options table required")
	raises(function() SpringFeaturesPass.new({}) end, "options.features")
	raises(function() SpringFeaturesPass.new({ features = {} }) end, "options.features")
	raises(function() SpringFeaturesPass.new({ features = { step = 5 } }) end, "options.features")
	local f = makeFake()
	for _, bad in { 0, -3, 1.5, "5", math.huge, 0 / 0 } do
		raises(function() SpringFeaturesPass.new({ features = f, yieldEvery = bad }) end, "yieldEvery", "yieldEvery " .. tostring(bad))
	end
	raises(function() SpringFeaturesPass.new({ features = f, yield = "x" }) end, "yield must be")
	raises(function() SpringFeaturesPass.new({ features = f, onProgress = 5 }) end, "onProgress must be")
	raises(function() SpringFeaturesPass.new({ features = f, encoding = "base64" }) end, "encoding must be")
	local pass = SpringFeaturesPass.new({ features = f })
	local s = pass:stats()
	assert(s.yieldEvery == 512 and s.encoding == "hex" and s.count == 0 and s.regimeSize == 0 and s.failure == nil)
	assert(pass:count() == 0 and pass:failure() == nil and f.steps == 0, "constructing a pass steps nothing")
	assert(SpringFeaturesPass.DRIVE_SIZE == 8 and SpringFeaturesPass.DEFAULT_YIELD_EVERY == 512)
end)

test("exactly one features:step per bar, in order, with the caller's own bar", function()
	local fake = makeFake()
	local pass = newPass(fake)
	local list = bars(1, 6)
	for k, b in list do
		assert(pass:push(b) == k, "push returns the 1-based index of the bar")
		assert(fake.steps == k, "one step per push, not " .. fake.steps .. " after " .. k)
		assert(pass:count() == k)
	end
	for k, b in list do assert(fake.seen[k] == b, "Features saw the caller's bar object " .. k .. " in order") end
end)

test("stored values equal what Features returned, bit for bit", function()
	local fake = makeFake({ mutate = function(out, k)
		if k == 2 then out.drive[3] = NEG_ZERO end                 -- the sign of zero
		if k == 3 then out.drive[4] = 5e-324 end                   -- smallest subnormal
		if k == 4 then out.drive[5] = 1.7976931348623157e308 end   -- largest double
		if k == 5 then out.drive[1] = bump(out.drive[1]); out.volatility = bump(out.volatility) end -- 1 ulp
		out.ready, out.reset = k % 2 == 0, k % 4 < 2                -- all four ready/reset combinations
		return out
	end })
	local pass = fill(newPass(fake), 1, 8)
	local seenCombos = {}
	for i = 1, 8 do
		local row, want = pass:get(i), fake.outputs[i]
		assert(row.t == bar(i).t and sameBits(row.t, want.t), "t " .. i)
		for j = 1, 8 do assert(sameBits(row.drive[j], want.drive[j]), "drive " .. i .. "/" .. j) end
		assert(#row.drive == 8 and sameBits(row.volatility, want.volatility), "volatility " .. i)
		assert(row.ready == want.ready and row.reset == want.reset, "flags " .. i)
		assert(row.regime == nil, "no regime unless Features returns one")
		seenCombos[(if row.ready then "R" else "r") .. (if row.reset then "S" else "s")] = true
	end
	assert(seenCombos.RS and seenCombos.Rs and seenCombos.rS and seenCombos.rs, "all four flag combinations exercised")
	assert(1 / pass:get(2).drive[3] == -math.huge, "-0 survives as -0")
	assert(pass:push({ t = bar(8).t + 0.25 }) == 9 and sameBits(pass:get(9).t, bar(8).t + 0.25), "a fractional t is stored exactly")
end)

test("get returns fresh copies, the pass copies at push time, and get checks its index", function()
	local fake = makeFake({ regime = true })
	local pass = fill(newPass(fake), 1, 4)
	local a, b = pass:get(2), pass:get(2)
	assert(a ~= b and a.drive ~= b.drive and a.regime ~= b.regime, "every get builds new tables")
	a.drive[1], a.regime[1], a.volatility, a.ready = 999, 999, 999, not a.ready
	local c = pass:get(2)
	assert(sameBits(c.drive[1], fake.outputs[2].drive[1]) and sameBits(c.regime[1], fake.outputs[2].regime[1]), "mutating a result changes nothing stored")
	assert(sameBits(c.volatility, fake.outputs[2].volatility) and c.ready == fake.outputs[2].ready)
	local before = pass:digest()
	fake.outputs[3].drive[1], fake.outputs[3].regime[2] = 777, 777 -- Features reusing its own table later
	assert(pass:digest() == before and sameBits(pass:get(3).drive[1], math.sin(3 * 0.37 + 1) * 1.5), "values were copied, not referenced")
	for _, bad in { 0, 5, -1, 1.5, 0 / 0, math.huge, -math.huge, "2", false } do
		raises(function() pass:get(bad) end, "index must be an integer in 1..4", "get(" .. tostring(bad) .. ")")
	end
	raises(function() pass:get() end, "index must be an integer in 1..4", "get()")
	assert(pass:get(1).t == bar(1).t and pass:get(4).t == bar(4).t, "both ends readable")
end)

test("pushPage stores a page exactly like pushing its bars one by one", function()
	local one = fill(newPass(makeFake({ regime = true }), nil), 1, 40)
	local fake = makeFake({ regime = true })
	local paged = newPass(fake)
	assert(paged:pushPage(bars(1, 7)) == 7, "returns the last index")
	assert(paged:pushPage(bars(8, 8)) == 8)
	assert(paged:pushPage({}) == 8 and fake.steps == 8, "an empty page changes nothing")
	assert(paged:pushPage(bars(9, 40)) == 40 and paged:count() == 40 and fake.steps == 40)
	assert(paged:digest() == one:digest(), "pages and single pushes give one digest")
	for i = 1, 40 do
		local x, y = paged:get(i), one:get(i)
		assert(x.t == y.t and x.ready == y.ready and x.reset == y.reset and sameBits(x.volatility, y.volatility))
		for j = 1, 8 do assert(sameBits(x.drive[j], y.drive[j])) end
		for j = 1, 3 do assert(sameBits(x.regime[j], y.regime[j])) end
	end
	for k, b in bars(1, 40) do assert(fake.seen[k].t == b.t, "pages are stepped in order") end
end)

test("a bad page is rejected before the first bar is stepped", function()
	local pass, fake = built(3)
	local digest = pass:digest()
	local function untouched(what)
		assert(fake.steps == 3 and pass:count() == 3 and pass:failure() == nil and pass:digest() == digest, what .. ": pass untouched")
	end
	local dup = bars(4, 6)
	dup[3] = bar(5) -- same t as bars[2]
	raises(function() pass:pushPage(dup) end, "bars[3]", "duplicate inside the page"); untouched("duplicate")
	local unordered = { bar(4), bar(6), bar(5) }
	raises(function() pass:pushPage(unordered) end, "bars[3]", "out of order inside the page"); untouched("unordered")
	raises(function() pass:pushPage(bars(3, 5)) end, "bars[1]", "first bar not after the stored t"); untouched("overlap")
	raises(function() pass:pushPage({ bar(4), "nope", bar(6) }) end, "bars[2]", "non-table bar"); untouched("non-table bar")
	local nan = bars(4, 6)
	nan[2].t = 0 / 0
	raises(function() pass:pushPage(nan) end, "bars[2]", "NaN t"); untouched("NaN t")
	raises(function() pass:pushPage("page") end, "array of bars"); untouched("not a table")
	assert(pass:pushPage(bars(4, 6)) == 6 and fake.steps == 6, "a good page is still accepted afterwards")
end)

test("push rejects invalid and non-increasing bars before Features sees them, and stays usable", function()
	local pass, fake = built(3)
	local digest = pass:digest()
	local cases = {
		{ "duplicate t", bar(3), "not after" },
		{ "earlier t", bar(2), "not after" },
		{ "t one second earlier", { t = bar(3).t - 1 }, "not after" },
		{ "missing t", { c = 1 }, "bar.t must be a finite number" },
		{ "NaN t", { t = 0 / 0 }, "bar.t must be a finite number" },
		{ "inf t", { t = math.huge }, "bar.t must be a finite number" },
		{ "-inf t", { t = -math.huge }, "bar.t must be a finite number" },
		{ "string t", { t = "1731941100" }, "bar.t must be a finite number" },
		{ "bar is nil", nil, "bar must be a table" },
		{ "bar is a string", "bar", "bar must be a table" },
	}
	for _, c in cases do
		raises(function() pass:push(c[2]) end, c[3], c[1])
		assert(fake.steps == 3, c[1] .. ": Features was stepped")
		assert(pass:count() == 3 and pass:failure() == nil and pass:digest() == digest, c[1] .. ": pass changed")
	end
	assert(pass:push(bar(4)) == 4 and fake.steps == 4, "the next valid bar is accepted")
	assert(pass:push({ t = bar(4).t + 1 }) == 5, "any strictly later t is fine (the pass does not insist on 300 s)")
end)

local MALFORMED = {
	{ "feature nil", "must return a table", function() return NONE end },
	{ "feature a number", "must return a table", function() return 5 end },
	{ "drive missing", "drive must be a table", function(o) o.drive = nil end },
	{ "drive a string", "drive must be a table", function(o) o.drive = "1,2,3" end },
	{ "7 values", "exactly 8 values, found 7", function(o) o.drive[8] = nil end },
	{ "9 values", "exactly 8 values, found 9", function(o) o.drive[9] = 0 end },
	{ "12 values (the v3 Features schema)", "exactly 8 values, found 12", function(o) for j = 9, 12 do o.drive[j] = 0 end end },
	{ "a hole and a ninth key", "drive[3] must be a finite number", function(o) o.drive[3] = nil; o.drive[9] = 1 end },
	{ "a named extra key", "exactly 8 values, found 9", function(o) o.drive.extra = 1 end },
	{ "NaN in drive[3]", "drive[3] must be a finite number", function(o) o.drive[3] = 0 / 0 end },
	{ "+inf in drive[1]", "drive[1] must be a finite number", function(o) o.drive[1] = math.huge end },
	{ "-inf in drive[8]", "drive[8] must be a finite number", function(o) o.drive[8] = -math.huge end },
	{ "numeric string in drive[2]", "drive[2] must be a finite number", function(o) o.drive[2] = "1" end },
	{ "NaN volatility", "volatility must be a finite number", function(o) o.volatility = 0 / 0 end },
	{ "nil volatility", "volatility must be a finite number", function(o) o.volatility = nil end },
	{ "string volatility", "volatility must be a finite number", function(o) o.volatility = "0.1" end },
	{ "nil ready", "ready must be a boolean", function(o) o.ready = nil end },
	{ "numeric ready", "ready must be a boolean", function(o) o.ready = 1 end },
	{ "nil reset", "reset must be a boolean", function(o) o.reset = nil end },
	{ "string reset", "reset must be a boolean", function(o) o.reset = "true" end },
	{ "feature.t is not the bar's t", "is not the bar's t", function(o) o.t += 1 end },
}
test("a malformed Features result is rejected, poisons the pass and is never half stored", function()
	local clean = built(2)
	local cleanDigest = clean:digest()
	for _, case in MALFORMED do
		local name, needle, edit = case[1], case[2], case[3]
		local fake = makeFake({ mutate = function(out, k) if k == 3 then return edit(out) end end })
		local pass = fill(newPass(fake), 1, 2)
		local message = raises(function() pass:push(bar(3)) end, needle, name)
		assert(string.find(message, "bar #3", 1, true), name .. ": message names the bar: " .. message)
		assert(pass:count() == 2, name .. ": count " .. pass:count())
		assert(pass:digest() == cleanDigest, name .. ": nothing of the rejected bar was stored")
		local reason = pass:failure()
		assert(reason and string.find(reason, needle, 1, true) and pass:stats().failure == reason, name .. ": failure() " .. tostring(reason))
		raises(function() pass:push(bar(4)) end, "has failed", name .. " then push")
		raises(function() pass:pushPage(bars(4, 5)) end, "has failed", name .. " then pushPage")
		raises(function() pass:pushPage({}) end, "has failed", name .. " then an empty page")
		assert(fake.steps == 3, name .. ": a failed pass never calls Features again")
		assert(pass:count() == 2 and pass:get(2).t == bar(2).t, name .. ": stored bars stay readable")
	end
end)

test("an error raised inside Features poisons the pass and keeps its message", function()
	local fake = makeFake({ raiseAt = 3 })
	local pass = fill(newPass(fake), 1, 2)
	local message = raises(function() pass:push(bar(3)) end, "fake features exploded at 3")
	assert(string.find(message, "Features:step raised", 1, true) and string.find(message, "bar #3", 1, true), message)
	assert(pass:count() == 2 and pass:failure() ~= nil)
	raises(function() pass:push(bar(4)) end, "has failed")
	assert(fake.steps == 3)
end)

test("a push from inside features:step is refused and nothing is double stored", function()
	local pass
	local fake = { steps = 0 }
	function fake:step(b)
		self.steps += 1
		if self.steps == 2 then pass:push(bar(9)) end -- re-entrant
		return { t = b.t, drive = { 1, 2, 3, 4, 5, 6, 7, 8 }, volatility = 0.1, ready = true, reset = false }
	end
	pass = newPass(fake)
	pass:push(bar(1))
	local message = raises(function() pass:push(bar(2)) end, "re-entered")
	assert(string.find(message, "Features:step raised", 1, true), message)
	assert(pass:count() == 1 and pass:failure() ~= nil)
end)

test("regime is optional, stored when present, and its size is fixed by the first bar", function()
	local pass, fake = built(5, { regime = true })
	assert(pass:stats().regimeSize == 3)
	for i = 1, 5 do
		local r, want = pass:get(i).regime, fake.outputs[i].regime
		assert(#r == 3 and sameBits(r[1], want[1]) and sameBits(r[2], want[2]) and sameBits(r[3], want[3]), "regime " .. i)
	end
	local without = built(3)
	assert(without:stats().regimeSize == 0 and without:get(2).regime == nil)
	local function breakAt(withRegime, edit)
		local fake2 = makeFake({ regime = withRegime, mutate = function(out, k) if k == 3 then edit(out) end end })
		local p = fill(newPass(fake2), 1, 2)
		local message = raises(function() p:push(bar(3)) end, nil)
		assert(p:count() == 2 and p:failure() ~= nil)
		return message
	end
	assert(string.find(breakAt(true, function(o) o.regime = nil end), "differs from the 3", 1, true), "regime vanishes")
	assert(string.find(breakAt(false, function(o) o.regime = { 0.5, 0.5 } end), "differs from the 0", 1, true), "regime appears")
	assert(string.find(breakAt(true, function(o) o.regime = { 0.5, 0.5 } end), "differs from the 3", 1, true), "regime shrinks")
	assert(string.find(breakAt(true, function(o) o.regime[4] = 0.1 end), "differs from the 3", 1, true), "regime grows")
	assert(string.find(breakAt(true, function(o) o.regime[2] = 0 / 0 end), "regime[2] must be a finite number", 1, true), "regime NaN")
	assert(string.find(breakAt(true, function(o) o.regime = {} end), "must not be an empty table", 1, true), "regime empty")
	assert(string.find(breakAt(true, function(o) o.regime = "low" end), "regime must be a table", 1, true), "regime string")
end)

test("yields every K bars after the bar is stored, and reports progress first", function()
	local events = {}
	local pass
	pass = SpringFeaturesPass.new({
		features = makeFake(), yieldEvery = 3,
		onProgress = function(count, t) table.insert(events, "p" .. count .. ":" .. t) assert(pass:count() == count, "progress sees the stored bar") end,
		yield = function(count) table.insert(events, "y" .. count) assert(pass:count() == count, "yield sees the stored bar") end,
	})
	fill(pass, 1, 10)
	local want = { "p3:" .. bar(3).t, "y3", "p6:" .. bar(6).t, "y6", "p9:" .. bar(9).t, "y9" }
	assert(table.concat(events, ",") == table.concat(want, ","), "events " .. table.concat(events, ","))
	local s = pass:stats()
	assert(s.yields == 3 and s.progressCalls == 3 and s.callbackErrors == 0 and s.count == 10)
	-- K = 1 yields after every bar; a page of 1000 with K = 300 yields at 300, 600, 900 and not at the end
	local every, counts = 0, {}
	local one = SpringFeaturesPass.new({ features = makeFake(), yieldEvery = 1, yield = function() every += 1 end })
	fill(one, 1, 7)
	assert(every == 7)
	local big = SpringFeaturesPass.new({ features = makeFake(), yieldEvery = 300, yield = function(c) table.insert(counts, c) end })
	assert(big:pushPage(bars(1, 1000)) == 1000)
	assert(table.concat(counts, ",") == "300,600,900", table.concat(counts, ","))
end)

test("the default yield is the scheduler's wait; yield=false turns it off; an explicit yield wins", function()
	local waits = 0
	local scheduler = { wait = function() waits += 1 end }
	local pass = SpringFeaturesPass.new({ features = makeFake(), yieldEvery = 2, scheduler = scheduler })
	fill(pass, 1, 5)
	assert(waits == 2 and pass:stats().yields == 2, "scheduler.wait at 2 and 4, got " .. waits)
	waits = 0
	local quiet = SpringFeaturesPass.new({ features = makeFake(), yieldEvery = 2, scheduler = scheduler, yield = false })
	fill(quiet, 1, 5)
	assert(waits == 0 and quiet:stats().yields == 0, "yield=false never waits and never counts a yield")
	local own = 0
	fill(SpringFeaturesPass.new({ features = makeFake(), yieldEvery = 2, scheduler = scheduler, yield = function() own += 1 end }), 1, 5)
	assert(own == 2 and waits == 0, "an explicit yield replaces the scheduler")
	local noScheduler = SpringFeaturesPass.new({ features = makeFake(), yieldEvery = 2, scheduler = {} })
	fill(noScheduler, 1, 5)
	assert(noScheduler:stats().yields == 0, "a scheduler without wait yields nothing")
	local hasTask = pcall(function() return task.wait end)
	if not hasTask then
		local bare = SpringFeaturesPass.new({ features = makeFake(), yieldEvery = 2 })
		fill(bare, 1, 5)
		assert(bare:stats().yields == 0, "no task library (luau.exe): no yield and no error")
	end
end)

test("callback errors are counted and never abort or corrupt the pass", function()
	local clean = built(9)
	local pass = SpringFeaturesPass.new({
		features = makeFake(), yieldEvery = 3,
		onProgress = function() error("ui exploded") end,
		yield = function() error("scheduler exploded") end,
	})
	fill(pass, 1, 9)
	local s = pass:stats()
	assert(s.count == 9 and s.failure == nil and pass:failure() == nil)
	assert(s.callbackErrors == 6 and s.yields == 3 and s.progressCalls == 3, "6 errors from 3 boundaries, got " .. s.callbackErrors)
	assert(string.find(s.lastCallbackError, "scheduler exploded", 1, true), tostring(s.lastCallbackError))
	assert(pass:digest() == clean:digest(), "stored values are the same as a quiet pass")
end)

test("digest: stable, canonical, and independent of how the bars were fed", function()
	local base = built(30, { regime = true })
	local digest = base:digest()
	local count, hex = string.match(digest, "^sfp1%-hex:(%d+):(%x+)$")
	assert(count == "30" and hex and #hex == 64, "format " .. digest)
	assert(base:digest() == digest and base:digest() == digest, "digest does not change the pass")
	assert(built(30, { regime = true }):digest() == digest, "a second pass over the same inputs")
	assert(built(30, { regime = true }, { yieldEvery = 7 }):digest() == digest, "yieldEvery does not matter")
	local paged = newPass(makeFake({ regime = true }))
	paged:pushPage(bars(1, 1)); paged:pushPage(bars(2, 13)); paged:pushPage(bars(14, 30))
	assert(paged:digest() == digest, "page boundaries do not matter")
	assert(built(29, { regime = true }):digest() ~= digest and built(31, { regime = true }):digest() ~= digest, "count matters")
	assert(built(30):digest() ~= digest, "regime matters")
	assert(string.match(newPass(makeFake()):digest(), "^sfp1%-hex:0:%x+$"), "an empty pass has a digest too")
end)

local function scriptedPass(rows, extra)
	local list = {}
	for i, r in rows do list[i] = { t = r.t } end
	local pass = newPass(scripted(rows), extra)
	pass:pushPage(list)
	return pass
end
local ROWS_A = {
	{ t = 1731940200, drive = { 0.5, -0.25, 1 / 3, -1, 2, -2, 0, NEG_ZERO }, volatility = 0.001, ready = false, reset = true, withT = false },
	{ t = 1731940500, drive = { 1e-300, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 2 }, volatility = 0.002, ready = true, reset = false },
}
local ROWS_B = {
	{ t = ROWS_A[1].t, drive = ROWS_A[1].drive, volatility = 0.001, ready = false, reset = true, regime = { 0.2, 0.3, 0.5 } },
	{ t = ROWS_A[2].t, drive = ROWS_A[2].drive, volatility = 0.002, ready = true, reset = false, regime = { 0.25, 0.25, 0.5 } },
}
local ROWS_G = {
	{ t = 100, drive = { 0.5, -0.25, 1, -1, 2, -2, 0, 0.125 }, volatility = 0.5, ready = false, reset = true },
	{ t = 400, drive = { 0.75, 1.5, 3, 0, 0.0625, -0.5, 1024, 2 }, volatility = 0.25, ready = true, reset = false },
}
local ROWS_G2 = {
	{ t = 100, drive = ROWS_G[1].drive, volatility = 0.5, ready = false, reset = true, regime = { 0.5, 0.25, 0.25 } },
	{ t = 400, drive = ROWS_G[2].drive, volatility = 0.25, ready = true, reset = false, regime = { 0.125, 0.375, 0.5 } },
}
test("digest known answers (computed independently in Node from the documented byte stream)", function()
	assert(scriptedPass(ROWS_A):digest() == "sfp1-hex:2:e7cbbaf884bef3ba23bea7ca4afb119feebcc49933556673cd2d823b2d987d42", "fixture A: " .. scriptedPass(ROWS_A):digest())
	assert(scriptedPass(ROWS_B):digest() == "sfp1-hex:2:facdbc923ede8cd521a15085f6b142ba17493913e458a5b3059dc77377e43836", "fixture B: " .. scriptedPass(ROWS_B):digest())
	assert(newPass(makeFake()):digest() == "sfp1-hex:0:e50b22a7b1e6c7134932220154f9313028dbb9de374cf1effbe94e8bdf24c38e", "empty pass")
	assert(scriptedPass(ROWS_G, { encoding = "g17" }):digest() == "sfp1-g17:2:b8271a59e602c9565adb5b77997770dcfaf181ae7e7576d4b8e3359d768988ef", "g17 fixture")
	assert(scriptedPass(ROWS_G2, { encoding = "g17" }):digest() == "sfp1-g17:2:e458b3915684d50f49945fe859416c6e88ba702aa44c9995b3c16e6bf3564076", "g17 fixture with regime")
end)

test("digest is sensitive to every stored field, to order, and to the sign of zero", function()
	local function digestWith(mutate, shiftFrom)
		local fake = makeFake({ regime = true, mutate = mutate })
		local pass = newPass(fake)
		for k = 1, 20 do pass:push(bar(k, if shiftFrom and k >= shiftFrom then 1 else 0)) end
		return pass:digest()
	end
	local base = digestWith(nil)
	assert(digestWith(nil) == base, "the baseline is reproducible")
	local seen, total = { [base] = true }, 1
	local function variant(name, mutate, shiftFrom)
		local d = digestWith(mutate, shiftFrom)
		assert(d ~= base, name .. ": digest did not change")
		assert(not seen[d], name .. ": digest equals another variant")
		seen[d] = true
		total += 1
	end
	for _, row in { 1, 10, 20 } do
		local function at(fn) return function(out, k) if k == row then fn(out) end end end
		for j = 1, 8 do variant("drive " .. j .. " row " .. row, at(function(o) o.drive[j] = bump(o.drive[j]) end)) end
		variant("volatility row " .. row, at(function(o) o.volatility = bump(o.volatility) end))
		for j = 1, 3 do variant("regime " .. j .. " row " .. row, at(function(o) o.regime[j] = bump(o.regime[j]) end)) end
		variant("ready row " .. row, at(function(o) o.ready = not o.ready end))
		variant("reset row " .. row, at(function(o) o.reset = not o.reset end))
		variant("swapped drive values row " .. row, at(function(o) o.drive[1], o.drive[2] = o.drive[2], o.drive[1] end))
		variant("t row " .. row, nil, row)
	end
	local zero = digestWith(function(o, k) if k == 7 then o.drive[3] = 0 end end)
	local negZero = digestWith(function(o, k) if k == 7 then o.drive[3] = NEG_ZERO end end)
	assert(zero ~= negZero and zero ~= base and negZero ~= base, "0 and -0 are different values")
	assert(total == 1 + 3 * (8 + 1 + 3 + 2 + 1 + 1), "variant count " .. total)
end)

test("g17 fallback: its own label, deterministic, sensitive to 1 ulp, to flags and to the sign of zero", function()
	local function g17(mutate, n)
		local pass = newPass(makeFake({ regime = true, mutate = mutate }), { encoding = "g17" })
		return fill(pass, 1, n or 12):digest()
	end
	local base = g17(nil)
	assert(string.match(base, "^sfp1%-g17:12:%x+$") and #base == #"sfp1-g17:12:" + 64, base)
	assert(g17(nil) == base and g17(nil, 11) ~= base)
	assert(base ~= built(12, { regime = true }):digest(), "hex and g17 digests are different strings")
	assert(g17(function(o, k) if k == 5 then o.drive[2] = bump(o.drive[2]) end end) ~= base, "1 ulp in drive")
	assert(g17(function(o, k) if k == 12 then o.volatility = bump(o.volatility) end end) ~= base, "1 ulp in volatility")
	assert(g17(function(o, k) if k == 3 then o.regime[3] = bump(o.regime[3]) end end) ~= base, "1 ulp in regime")
	assert(g17(function(o, k) if k == 4 then o.reset = not o.reset end end) ~= base, "reset flag")
	assert(g17(function(o, k) if k == 4 then o.ready = not o.ready end end) ~= base, "ready flag")
	local zero = g17(function(o, k) if k == 7 then o.drive[3] = 0 end end)
	local negZero = g17(function(o, k) if k == 7 then o.drive[3] = NEG_ZERO end end)
	assert(zero ~= negZero, "0 and -0 differ in the fallback text too")
	assert(newPass(makeFake(), { encoding = "g17" }):stats().encoding == "g17")
end)

test("digest covers the bars stored when it was called, even if bars arrive while it yields", function()
	local pass
	local armed = false
	pass = SpringFeaturesPass.new({
		features = makeFake(), yieldEvery = 2,
		yield = function()
			if armed then armed = false; pass:push(bar(8)) end
		end,
	})
	armed = false
	for k = 1, 7 do pass:push(bar(k)) end
	local expected7, expected8 = built(7):digest(), built(8):digest()
	armed = true
	local during = pass:digest()
	assert(pass:count() == 8, "a bar really arrived while digest yielded")
	assert(during == expected7, "digest covered the 7 bars present at the call: " .. during)
	assert(pass:digest() == expected8, "the next digest covers all 8")
	assert(pass:stats().callbackErrors == 0)
end)

test("sha256: NIST vectors, million a, all byte values, block-boundary lengths", function()
	local sha = SpringFeaturesPass.sha256
	assert(sha("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
	assert(sha("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	assert(sha("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
	assert(sha("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")
		== "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
	assert(sha(string.rep("a", 1000000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
	local all = {}
	for b = 0, 255 do all[b + 1] = string.char(b) end
	assert(sha(table.concat(all)) == "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880")
	assert(sha(string.rep("x", 55)) == "d5e285683cd4efc02d021a5c62014694958901005d6f71e89e0989fac77e4072", "55 bytes: padding fits one block")
	assert(sha(string.rep("x", 56)) == "04c26261370ee7541549d16dee320c723e3fd14671e66a099afe0a377c16888e", "56 bytes: padding needs a second block")
	assert(sha(string.rep("x", 64)) == "7ce100971f64e7001e8fe5a51973ecdfe1ced42befe7ee8d5fd6219506b5393c", "64 bytes")
	assert(sha(string.rep("x", 119)) == "000b48d4edf0fa7bee3c6236ecd2785baa5db4eeb8bb54341b029e0d9fa5fb0c", "119 bytes")
	raises(function() sha(5) end, "string required")
end)

test("sha256 streaming equals one shot for every split, and a finished hasher refuses more", function()
	local message = string.rep("0123456789abcdef", 18) .. "tail" -- 292 bytes: crosses several block boundaries
	local whole = SpringFeaturesPass.sha256(message)
	for cut = 0, #message do
		local h = SpringFeaturesPass._newHasher()
		h.update(string.sub(message, 1, cut)); h.update(string.sub(message, cut + 1))
		assert(h.final() == whole, "split at " .. cut)
	end
	for _, cuts in { { 63, 64 }, { 64, 65 }, { 1, 2, 3, 127, 128 }, { 100, 100, 100 } } do
		local h, from = SpringFeaturesPass._newHasher(), 1
		for _, c in cuts do h.update(string.sub(message, from, from + c - 1)); from += c end
		h.update(string.sub(message, from))
		assert(h.final() == whole, "cuts " .. table.concat(cuts, ","))
	end
	local h = SpringFeaturesPass._newHasher()
	h.update("abc")
	assert(h.final() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	raises(function() h.update("more") end, "already finalised")
	raises(function() h.final() end, "already finalised")
	raises(function() SpringFeaturesPass._newHasher().update(nil) end, "string required")
end)

test("a long pass: 5000 bars in irregular pages, 9 yields at the 512 cadence, spot values exact", function()
	local counts, progress = {}, {}
	local fake = makeFake({ regime = true })
	local pass = SpringFeaturesPass.new({
		features = fake, yield = function(c) table.insert(counts, c) end,
		onProgress = function(c) table.insert(progress, c) end,
	})
	local from = 1
	for _, size in { 1, 511, 512, 513, 1000, 1, 999 } do
		assert(pass:pushPage(bars(from, from + size - 1)) == from + size - 1)
		from += size
	end
	assert(pass:pushPage(bars(from, 5000)) == 5000 and from == 3538)
	assert(pass:count() == 5000 and fake.steps == 5000)
	assert(table.concat(counts, ",") == "512,1024,1536,2048,2560,3072,3584,4096,4608", table.concat(counts, ","))
	assert(table.concat(progress, ",") == table.concat(counts, ","))
	for _, i in { 1, 2500, 5000 } do
		local row, want = pass:get(i), fake.outputs[i]
		assert(row.t == bar(i).t and sameBits(row.volatility, want.volatility) and row.ready == want.ready and row.reset == want.reset)
		for j = 1, 8 do assert(sameBits(row.drive[j], want.drive[j]), "drive " .. i .. "/" .. j) end
		for j = 1, 3 do assert(sameBits(row.regime[j], want.regime[j]), "regime " .. i .. "/" .. j) end
	end
	assert(pass:get(1).reset == true and pass:get(2).reset == false and pass:get(11).ready == false and pass:get(12).ready == true)
	assert(#counts == 9 and pass:stats().yields == 9 and pass:stats().progressCalls == 9)
	local oneByOne = fill(newPass(makeFake({ regime = true })), 1, 5000)
	assert(pass:digest() == oneByOne:digest(), "irregular pages give the digest of single pushes")
	assert(pass:stats().yields == 18 and pass:stats().progressCalls == 9, "digest yields at the same cadence, without progress")
end)

print("SpringFeaturesPass: " .. passed .. " tests passed")
