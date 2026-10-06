-- SpringLaneLayout spec (contract 1b L16/L21). Self-running: luau.exe tests/SpringLaneLayout.spec.luau
-- Pure Luau: no Roblox, no Studio. What this proves and what it cannot:
--   PROVES: the footprint derivation (closed form AND from per-part boxes) against the measured spans; lane counts 1..12
--     are centred, share the capture X and Y, and are at least 512 studs apart for EVERY pair and for every PART pair
--     (brute force, rails swept); reserved zones and tampered plans are rejected; float32 spacing is exact at powers of
--     two (checked against real float32 bit patterns) and every lane coordinate is exactly representable.
--   CANNOT PROVE: that the real built engine has these part boxes. SpringLaneLayout.verifyBuilt() is what Studio calls
--     on measured part boxes of the built lanes; here it is exercised with the derived boxes and deliberate errors.
-- Inputs: the rig config is the REAL 2024 native.config, taken three ways that must agree:
--   (1) REAL below: read with node from indicator-v2/results/RoAlgoV2_SPY_1791205420530.json native.config
--       (file sha256 bd4ef4f0b8e80c31f79495f99264d23ffc6d477413f00d47b770197293b38828);
--   (2) SpringFrozenV1.nativeConfig2024, the same config as frozen into Luau by make-spring-frozen.mjs;
--   (3) SpringV2Mechanics.config(), the capture-time module (sha d4680345...).
local okLayout, Layout = pcall(require, "../src/SpringLaneLayout")
assert(okLayout and type(Layout) == "table", "SpringLaneLayout must load without Roblox globals: " .. tostring(Layout))
local okMech, Mechanics = pcall(require, "../src/SpringV2Mechanics")
assert(okMech and type(Mechanics) == "table", "SpringV2Mechanics must load: " .. tostring(Mechanics))
local okFrozen, Frozen = pcall(require, "../src/SpringFrozenV1")
assert(okFrozen and type(Frozen) == "table" and type(Frozen.nativeConfig2024) == "table", "SpringFrozenV1.nativeConfig2024 must load: " .. tostring(Frozen))

local passed = 0
local function test(name, fn)
	fn()
	passed += 1
	print("PASS " .. name)
end
local function rejects(fn, fragment)
	local ok, err = pcall(fn)
	assert(not ok, "expected a rejection containing '" .. fragment .. "'")
	assert(string.find(tostring(err), fragment, 1, true), "wrong rejection: " .. tostring(err) .. " (expected '" .. fragment .. "')")
	return tostring(err)
end
local function near(a, b, e, what)
	assert(math.abs(a - b) <= (e or 1e-9), (what or "value") .. ": " .. tostring(a) .. " != " .. tostring(b))
end
local function same(a, b, what)
	assert(a == b, (what or "value") .. ": " .. tostring(a) .. " ~= " .. tostring(b))
end
local function deepCopy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in t do out[k] = deepCopy(v) end
	return out
end
local function deepEqual(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in a do if not deepEqual(v, b[k]) then return false end end
	for k in b do if a[k] == nil then return false end end
	return true
end

------------------------------------------------------------------------------------------------------------------------
-- Inputs and independent references (derived by hand, not by the module)

-- Read with node from the 2024 capture manifest; geometry keys only (y = (3 - bank) * 256, z = (col - 1) * 256).
local REAL = {
	D = 64, spacing = 256, anchorOffset = 512, railLimit = 224, nodeSize = 1.5, nodeCount = 24,
	y = { 512, 512, 512, 512, 512, 512, 512, 512, 256, 256, 256, 256, 256, 256, 256, 256, 0, 0, 0, 0, 0, 0, 0, 0 },
	z = { 0, 256, 512, 768, 1024, 1280, 1536, 1792, 0, 256, 512, 768, 1024, 1280, 1536, 1792, 0, 256, 512, 768, 1024, 1280, 1536, 1792 },
}
local CONFIG = Frozen.nativeConfig2024
local ORIGIN = { x = 0, y = 1024, z = 1024 } -- SpringV2Engine.luau:100, the capture origin

-- Hand derivation at the capture origin. Part centres span (scout measurement): x -512..224, y 1024..1536, z 1024..2816
-- (coupled) and 3840..5632 (independent). Half sizes: node 1.5/2 = 0.75, anchor 1/2 = 0.5, guide 0.18/2 = 0.09.
-- x: anchor centre at -512 with half 0.5 -> -512.5; node at +224 (full travel) with half 0.75 -> 224.75.
-- y: 1024 - 0.75 .. 1536 + 0.75.  z: 1024 - 0.75 .. 5632 + 0.75.
local EXPECT = {
	minX = -512.5, maxX = 224.75, minY = 1023.25, maxY = 1536.75, minZ = 1023.25, maxZ = 5632.75,
	depth = 4609.5, -- 5632.75 - 1023.25
	spacing = 5122, -- ceil((4609.5 + 512) / 2) * 2 = ceil(2560.75) * 2
	gapBetweenNeighbours = 512.5, -- 5122 - 4609.5
}

-- Real float32 neighbour distance, from bit patterns (valid for float32-exact, non-negative v below the max finite value).
local function f32bits(v) return (string.unpack("<I4", string.pack("<f", v))) end
local function f32value(bits) return (string.unpack("<f", string.pack("<I4", bits))) end
local function measuredUlp(v) return f32value(f32bits(v) + 1) - v end

-- Brute-force part-level separation helpers (do not use the module's own box code).
local function partNumbers(p, rail)
	local travel = if p.moving then rail else 0
	return { p.pos.x - p.size.x / 2 - travel, p.pos.x + p.size.x / 2 + travel, p.pos.y - p.size.y / 2, p.pos.y + p.size.y / 2,
		p.pos.z - p.size.z / 2, p.pos.z + p.size.z / 2 }
end
local function numberGap(a, b)
	local gx = math.max(a[1] - b[2], b[1] - a[2])
	local gy = math.max(a[3] - b[4], b[3] - a[4])
	local gz = math.max(a[5] - b[6], b[5] - a[6])
	return math.max(gx, gy, gz)
end

local function box(lx, ly, lz, hx, hy, hz) return { min = { x = lx, y = ly, z = lz }, max = { x = hx, y = hy, z = hz } } end
local function planWith(count, extra)
	local opts = { count = count }
	for k, v in extra or {} do opts[k] = v end
	return Layout.plan(CONFIG, opts)
end
local function moveLane(p, k, dz)
	local lane = p.lanes[k]
	lane.origin.z += dz
	lane.offsetZ += dz
	lane.box = Layout.translate(lane.box, 0, 0, dz)
end

------------------------------------------------------------------------------------------------------------------------
-- float32

test("float32Ulp is exact at every power of two and equals the real float32 spacing", function()
	for e = -126, 127 do
		local v = 2 ^ e
		same(Layout.float32Ulp(v), 2 ^ (e - 23), "ulp(2^" .. e .. ")")
		same(Layout.float32Ulp(-v), 2 ^ (e - 23), "ulp(-2^" .. e .. ")")
		-- the same number measured from the float32 bit pattern: distance to the next float32 up
		same(measuredUlp(v), 2 ^ (e - 23), "measured float32 spacing at 2^" .. e)
	end
	same(Layout.float32Ulp(1), 2 ^ -23, "ulp(1)")
	same(Layout.float32Ulp(1), 1.1920928955078125e-07, "ulp(1) literal")
	same(Layout.float32Ulp(2), 2 ^ -22)
	same(Layout.float32Ulp(1024), 2 ^ -13)
	same(Layout.float32Ulp(2 ^ 23), 1)
	same(Layout.float32Ulp(2 ^ 24), 2)
end)

test("float32Ulp stays in the lower binade just below a power of two and matches measured spacing off the powers", function()
	same(Layout.float32Ulp(1 - 2 ^ -53), 2 ^ -24, "double just below 1")
	same(Layout.float32Ulp(2 ^ 24 - 1), 1, "2^24 - 1")
	same(Layout.float32Ulp(1023.999), 2 ^ -14)
	same(Layout.float32Ulp(1024), 2 ^ -13)
	for _, v in { 1.5, 1.75, 3, 1023.25, 1536.75, 5632.75, 18950.25, 23559.75, 65535.5, 300000.25, 16777215, 1e10, 1073741824, 6.5e30 } do
		local exact = Layout.float32Round(v)
		same(Layout.float32Ulp(exact), measuredUlp(exact), "ulp at " .. tostring(exact))
	end
end)

test("float32Ulp: zero and denormals, and loud rejection of everything that is not a float32 number", function()
	same(Layout.float32Ulp(0), 2 ^ -149)
	same(Layout.float32Ulp(-0), 2 ^ -149)
	same(measuredUlp(0), 2 ^ -149)
	same(Layout.float32Ulp(2 ^ -149), 2 ^ -149)
	same(Layout.float32Ulp(1e-40), 2 ^ -149)
	same(Layout.float32Ulp(2 ^ -127), 2 ^ -149)
	same(Layout.float32Ulp(2 ^ -126), 2 ^ -149, "smallest normal binade has spacing 2^-149")
	same(Layout.float32Ulp(2 ^ -125), 2 ^ -148)
	rejects(function() Layout.float32Ulp(0 / 0) end, "finite number required")
	rejects(function() Layout.float32Ulp(math.huge) end, "finite number required")
	rejects(function() Layout.float32Ulp("1") end, "finite number required")
	rejects(function() Layout.float32Ulp(nil) end, "finite number required")
	rejects(function() Layout.float32Ulp(1e39) end, "outside the float32 range")
	rejects(function() Layout.float32Ulp(-1e39) end, "outside the float32 range")
	assert(Layout.float32Ulp(Layout.FLOAT32_MAX) == 2 ^ 104, "ulp at the largest float32")
end)

test("float32Round: nearest float32; dyadic layout coordinates are exact, decimals are not", function()
	same(Layout.float32Round(0.1), 0.10000000149011612)
	assert(Layout.float32Round(0.1) ~= 0.1)
	same(Layout.float32Round(1023.25), 1023.25)
	same(Layout.float32Round(-16903.75), -16903.75)
	same(Layout.float32Round(16777216), 16777216)
	same(Layout.float32Round(16777217), 16777216, "2^24 + 1 is the first integer float32 cannot hold")
	rejects(function() Layout.float32Round(1e39) end, "outside the float32 range")
	rejects(function() Layout.float32Round(0 / 0) end, "finite number required")
end)

------------------------------------------------------------------------------------------------------------------------
-- inputs

test("the real native.config agrees three ways: node-read literal, frozen Luau copy, capture Mechanics.config()", function()
	local capture = Mechanics.config()
	for _, key in { "D", "spacing", "anchorOffset", "railLimit", "nodeSize" } do
		same(CONFIG[key], REAL[key], "frozen " .. key)
		same(capture[key], REAL[key], "capture Mechanics " .. key)
	end
	same(#CONFIG.nodes, REAL.nodeCount)
	same(#capture.nodes, REAL.nodeCount)
	for i = 1, REAL.nodeCount do
		same(CONFIG.nodes[i].y, REAL.y[i], "frozen node " .. i .. ".y")
		same(CONFIG.nodes[i].z, REAL.z[i], "frozen node " .. i .. ".z")
		same(capture.nodes[i].y, REAL.y[i], "capture node " .. i .. ".y")
		same(capture.nodes[i].z, REAL.z[i], "capture node " .. i .. ".z")
	end
	same(Layout.CAPTURE_ORIGIN.x, 0)
	same(Layout.CAPTURE_ORIGIN.y, 1024)
	same(Layout.CAPTURE_ORIGIN.z, 1024)
	assert(table.isfrozen(Layout.CAPTURE_ORIGIN), "the capture origin constant cannot be mutated")
	same(Layout.DEFAULT_GAP, 512)
	same(Layout.RIG.independentSpacings * REAL.spacing, 2816, "independent offset 11 * spacing")
	same(Layout.RIG.anchorSize, 1)
	same(Layout.RIG.guideThickness, 0.18)
end)

------------------------------------------------------------------------------------------------------------------------
-- part list and footprint derivation

test("parts(): the 144 part boxes of one lane at the capture origin", function()
	local parts = Layout.parts(CONFIG)
	same(#parts, 144, "parts per lane")
	local count = { guide = 0, anchor = 0, node = 0, moving = 0, coupled = 0, independent = 0 }
	for _, p in parts do
		count[p.kind] += 1
		count[p.rig] += 1
		if p.moving then count.moving += 1 end
		assert((p.kind == "node") == p.moving, "only nodes move")
		local i = p.node
		local dz = if p.rig == "independent" then 11 * 256 else 0
		if p.kind == "node" then
			same(p.pos.x, 0)
			same(p.size.x, 1.5); same(p.size.y, 1.5); same(p.size.z, 1.5)
			assert(string.find(p.name, if i <= 8 then "Fast" elseif i <= 16 then "Medium" else "Slow", 1, true), "node name " .. p.name)
		elseif p.kind == "anchor" then
			same(p.pos.x, -512, "anchors sit anchorOffset on the -X side")
			same(p.size.x, 1); same(p.size.y, 1); same(p.size.z, 1)
		else
			same(p.pos.x, 0)
			same(p.size.x, 448, "guide length 2 * railLimit"); same(p.size.y, 0.18); same(p.size.z, 0.18)
		end
		same(p.pos.y, 1024 + REAL.y[i], p.name .. ".y")
		same(p.pos.z, 1024 + dz + REAL.z[i], p.name .. ".z")
	end
	same(count.guide, 48); same(count.anchor, 48); same(count.node, 48); same(count.moving, 48)
	same(count.coupled, 72); same(count.independent, 72)
	-- a lane at another origin is the same rig moved rigidly
	local moved = Layout.parts(CONFIG, { x = 7, y = -33, z = -4096 })
	for k, p in parts do
		same(moved[k].pos.x - p.pos.x, 7); same(moved[k].pos.y - p.pos.y, -1057); same(moved[k].pos.z - p.pos.z, -5120)
		same(moved[k].size.x, p.size.x)
	end
end)

test("the part centres span exactly the measured capture extents (x -512..224, y 1024..1536, z 1024..2816 and 3840..5632)", function()
	local span = {
		coupled = { x = { math.huge, -math.huge }, y = { math.huge, -math.huge }, z = { math.huge, -math.huge } },
		independent = { x = { math.huge, -math.huge }, y = { math.huge, -math.huge }, z = { math.huge, -math.huge } },
	}
	for _, p in Layout.parts(CONFIG) do
		local s = span[p.rig]
		local lo, hi = p.pos.x, p.pos.x
		if p.moving then lo, hi = lo - 224, hi + 224 end
		s.x[1], s.x[2] = math.min(s.x[1], lo), math.max(s.x[2], hi)
		s.y[1], s.y[2] = math.min(s.y[1], p.pos.y), math.max(s.y[2], p.pos.y)
		s.z[1], s.z[2] = math.min(s.z[1], p.pos.z), math.max(s.z[2], p.pos.z)
	end
	for _, rig in { "coupled", "independent" } do
		same(span[rig].x[1], -512, rig .. " x min"); same(span[rig].x[2], 224, rig .. " x max")
		same(span[rig].y[1], 1024, rig .. " y min"); same(span[rig].y[2], 1536, rig .. " y max")
	end
	same(span.coupled.z[1], 1024); same(span.coupled.z[2], 2816)
	same(span.independent.z[1], 3840); same(span.independent.z[2], 5632)
end)

test("footprint(): closed form at the capture origin equals the hand derivation", function()
	local fp = Layout.footprint(CONFIG)
	same(fp.min.x, EXPECT.minX, "min x"); same(fp.max.x, EXPECT.maxX, "max x")
	same(fp.min.y, EXPECT.minY, "min y"); same(fp.max.y, EXPECT.maxY, "max y")
	same(fp.min.z, EXPECT.minZ, "min z"); same(fp.max.z, EXPECT.maxZ, "max z")
	local size = Layout.size(fp)
	same(size.z, EXPECT.depth, "depth along Z")
	same(size.x, 737.25, "width along X")
	same(size.y, 513.5, "height along Y")
	local explicit = Layout.footprint(CONFIG, ORIGIN)
	assert(deepEqual(fp, explicit), "explicit capture origin = default")
end)

test("footprint() equals the union of every part box (rails swept), for the real config, other origins and other configs", function()
	local function compare(config, origin, label)
		local closed = Layout.footprint(config, origin)
		local fromParts = Layout.footprintFromParts(Layout.parts(config, origin), config.railLimit)
		for _, corner in { "min", "max" } do
			for _, axis in { "x", "y", "z" } do
				near(closed[corner][axis], fromParts[corner][axis], 1e-9, label .. " " .. corner .. "." .. axis)
			end
		end
	end
	compare(CONFIG, nil, "real/capture")
	compare(CONFIG, { x = 7, y = -33.5, z = -4096 }, "real/shifted")
	-- anchorOffset smaller than railLimit: the node, not the anchor, sets the -X side
	local small = { railLimit = 100, anchorOffset = 50, nodeSize = 3, spacing = 10, nodes = { { y = 0, z = 0 }, { y = 5, z = 20 }, { y = -8, z = 7 } } }
	compare(small, nil, "synthetic anchor inside rail")
	local fp = Layout.footprint(small)
	near(fp.min.x, -101.5, 1e-12, "node half-size at -railLimit"); near(fp.max.x, 101.5, 1e-12)
	same(fp.min.z, 1024 - 1.5); same(fp.max.z, 1024 + 110 + 20 + 1.5, "independent rig offset 11 * spacing = 110")
	same(fp.min.y, 1024 - 8 - 1.5); same(fp.max.y, 1024 + 5 + 1.5)
	-- a thin node: the 1-stud anchor is wider than the node in Y and Z
	local thin = { railLimit = 224, anchorOffset = 512, nodeSize = 0.2, spacing = 256, nodes = { { y = 0, z = 0 }, { y = 256, z = 256 } } }
	compare(thin, nil, "synthetic thin node")
	near(Layout.footprint(thin).min.y, 1024 - 0.5, 1e-12, "anchor half-size when it is the widest")
end)

test("footprintFromParts(): static boxes, rail sweep along X only, off-axis allowance, union and input validation", function()
	local static = Layout.footprintFromParts({ { pos = { x = 10, y = 20, z = 30 }, size = { x = 2, y = 4, z = 6 }, moving = false } }, 50)
	assert(deepEqual(static, box(9, 18, 27, 11, 22, 33)), "static part has no travel")
	local moving = Layout.footprintFromParts({ { pos = { x = 10, y = 20, z = 30 }, size = { x = 2, y = 4, z = 6 }, moving = true } }, 50)
	assert(deepEqual(moving, box(-41, 18, 27, 61, 22, 33)), "moving part sweeps +-railLimit along X only")
	local wander = Layout.footprintFromParts({
		{ pos = { x = 10, y = 20, z = 30 }, size = { x = 2, y = 4, z = 6 }, moving = true },
		{ pos = { x = 0, y = 0, z = 0 }, size = { x = 1, y = 1, z = 1 }, moving = false },
	}, 50, { offAxis = 3 })
	assert(deepEqual(wander, box(-41, -0.5, -0.5, 61, 25, 36)), "off-axis allowance only for the moving part; union with the static one")
	assert(deepEqual(Layout.footprintFromParts({ { pos = { x = 0, y = 0, z = 0 }, size = { x = 2, y = 2, z = 2 }, moving = true } }, 0),
		box(-1, -1, -1, 1, 1, 1)), "railLimit 0 is allowed")
	local goodPos, goodSize = { x = 0, y = 0, z = 0 }, { x = 1, y = 1, z = 1 }
	rejects(function() Layout.footprintFromParts({}, 1) end, "non-empty list")
	rejects(function() Layout.footprintFromParts(nil, 1) end, "non-empty list")
	rejects(function() Layout.footprintFromParts({ { pos = goodPos, size = goodSize } }, 1) end, "moving must be true or false")
	rejects(function() Layout.footprintFromParts({ { pos = goodPos, size = goodSize, moving = 1 } }, 1) end, "moving must be true or false")
	rejects(function() Layout.footprintFromParts({ { pos = goodPos, size = { x = 0, y = 1, z = 1 }, moving = false } }, 1) end, "size must be positive")
	rejects(function() Layout.footprintFromParts({ { pos = { x = 0, y = 0 }, size = goodSize, moving = false } }, 1) end, "pos needs finite numeric")
	rejects(function() Layout.footprintFromParts({ { pos = { x = 0 / 0, y = 0, z = 0 }, size = goodSize, moving = false } }, 1) end, "pos needs finite numeric")
	rejects(function() Layout.footprintFromParts({ { pos = goodPos, size = goodSize, moving = false } }, -1) end, "railLimit")
	rejects(function() Layout.footprintFromParts({ { pos = goodPos, size = goodSize, moving = false } }, 0 / 0) end, "railLimit")
	rejects(function() Layout.footprintFromParts({ { pos = goodPos, size = goodSize, moving = false } }, 1, { offAxis = -1 }) end, "offAxis")
	rejects(function() Layout.footprintFromParts({ goodPos }, 1) end, "pos must be a table")
end)

test("rail travel is along X only: it changes the X extent and never the Y or Z extent that decides lane spacing", function()
	local base = Layout.footprint(CONFIG)
	local long = deepCopy(CONFIG)
	long.railLimit = 5000
	local wide = Layout.footprint(long)
	same(wide.min.z, base.min.z); same(wide.max.z, base.max.z)
	same(wide.min.y, base.min.y); same(wide.max.y, base.max.y)
	assert(wide.max.x > base.max.x + 4000, "X extent follows the rail")
	assert(wide.min.x < base.min.x - 4000, "X extent follows the rail")
	local a, b = planWith(5), Layout.plan(long, { count = 5 })
	same(a.spacing, b.spacing, "spacing is independent of the rail length")
	for k = 1, 5 do
		same(a.lanes[k].box.min.z, b.lanes[k].box.min.z); same(a.lanes[k].box.max.z, b.lanes[k].box.max.z)
	end
	-- the same through the parts-based route
	local parts = Layout.parts(CONFIG)
	local short = Layout.footprintFromParts(parts, 0)
	local full = Layout.footprintFromParts(parts, 224)
	same(short.min.z, full.min.z); same(short.max.z, full.max.z)
	same(short.min.y, full.min.y); same(short.max.y, full.max.y)
	same(full.max.x, 224.75, "full travel: node centre +224 plus its half size")
	local nodes = {}
	for _, p in parts do if p.kind == "node" then table.insert(nodes, p) end end
	same(Layout.footprintFromParts(nodes, 0).max.x, 0.75, "no travel: a node alone reaches only its own half size")
	same(Layout.footprintFromParts(nodes, 224).max.x, 224.75)
end)

------------------------------------------------------------------------------------------------------------------------
-- box helpers

test("separation / intersects / contains / translate / size", function()
	local a = box(0, 0, 0, 10, 10, 10)
	same(Layout.separation(a, box(15, 0, 0, 20, 10, 10)), 5, "gap along X")
	same(Layout.separation(box(15, 0, 0, 20, 10, 10), a), 5, "symmetric")
	same(Layout.separation(a, box(0, -30, 0, 10, -12, 10)), 12, "gap along Y")
	same(Layout.separation(a, box(0, 0, 40, 10, 10, 50)), 30, "gap along Z")
	same(Layout.separation(a, box(15, 0, 40, 20, 10, 50)), 30, "best separating axis, not the sum")
	same(Layout.separation(a, box(10, 0, 0, 20, 10, 10)), 0, "touching faces")
	same(Layout.separation(a, box(10, 10, 10, 20, 20, 20)), 0, "touching corners")
	assert(Layout.separation(a, box(5, 5, 5, 20, 20, 20)) < 0, "overlap is negative")
	same(Layout.separation(a, box(5, 5, 5, 20, 20, 20)), -5, "shallowest overlap depth")
	assert(Layout.intersects(a, box(10, 0, 0, 20, 10, 10)), "touching counts as intersecting")
	assert(Layout.intersects(a, box(5, 5, 5, 6, 6, 6)), "contained")
	assert(not Layout.intersects(a, box(10.001, 0, 0, 20, 10, 10)), "a sliver apart")
	assert(Layout.contains(a, box(1, 1, 1, 9, 9, 9)))
	assert(Layout.contains(a, a), "a box contains itself")
	assert(not Layout.contains(a, box(1, 1, 1, 9, 9, 10.5)))
	assert(not Layout.contains(a, box(-0.5, 1, 1, 9, 9, 9)))
	assert(not Layout.contains(box(1, 1, 1, 9, 9, 9), a))
	assert(deepEqual(Layout.translate(a, 1, 2, 3), box(1, 2, 3, 11, 12, 13)))
	assert(deepEqual(Layout.size(box(1, 2, 3, 11, 12, 13)), { x = 10, y = 10, z = 10 }))
end)

------------------------------------------------------------------------------------------------------------------------
-- plans

test("plan counts 1..12: centred offsets, capture X and Y, spacing, order", function()
	for n = 1, 12 do
		local plan = planWith(n)
		same(#plan.lanes, n, "lane count"); same(plan.count, n)
		same(plan.spacing, EXPECT.spacing, "spacing N=" .. n)
		same(plan.depth, EXPECT.depth)
		same(plan.gap, 512)
		local sum = 0
		for k = 1, n do
			local lane = plan.lanes[k]
			local offset = (k - (n + 1) / 2) * 5122
			same(lane.index, k)
			same(lane.offsetZ, offset, "N=" .. n .. " lane " .. k .. " offset")
			same(lane.origin.x, 0, "lane origin X is the capture X"); same(lane.origin.y, 1024, "lane origin Y is the capture Y")
			same(lane.origin.z, 1024 + offset, "lane origin Z")
			same(lane.box.min.x, EXPECT.minX); same(lane.box.max.x, EXPECT.maxX)
			same(lane.box.min.y, EXPECT.minY); same(lane.box.max.y, EXPECT.maxY)
			same(lane.box.min.z, EXPECT.minZ + offset); same(lane.box.max.z, EXPECT.maxZ + offset)
			same(lane.offsetZ, -plan.lanes[n + 1 - k].offsetZ, "mirror lane offset")
			sum += offset
			if k > 1 then assert(lane.origin.z > plan.lanes[k - 1].origin.z, "lanes are ordered in +Z") end
		end
		same(sum, 0, "offsets sum to zero (centred on the capture origin)")
		if n % 2 == 1 then
			local mid = plan.lanes[(n + 1) / 2]
			same(mid.offsetZ, 0, "odd count: the middle lane IS the capture lane")
			assert(deepEqual(mid.origin, ORIGIN), "middle lane origin equals the capture origin")
		else
			assert(plan.lanes[n / 2].offsetZ < 0 and plan.lanes[n / 2 + 1].offsetZ > 0, "even count straddles the capture origin")
			same(plan.lanes[n / 2 + 1].offsetZ, 2561, "half a spacing either side")
		end
	end
	local one = planWith(1)
	assert(deepEqual(one.lanes[1].box, Layout.footprint(CONFIG)), "one lane is exactly the capture footprint")
	same(one.checks.pairs, 0); same(one.checks.minLaneSeparation, nil)
end)

test("every lane pair is at least 512 apart (hand arithmetic on the hand-derived footprint, all pairs, N=1..12)", function()
	for n = 2, 12 do
		local plan = planWith(n)
		local least = math.huge
		for i = 1, n - 1 do
			for j = i + 1, n do
				local between = plan.lanes[j].box.min.z - plan.lanes[i].box.max.z
				same(between, (j - i) * 5122 - EXPECT.depth, "z clearance between lanes " .. i .. " and " .. j)
				assert(between >= 512, "lanes " .. i .. "," .. j .. " only " .. between .. " apart")
				least = math.min(least, between)
			end
		end
		same(least, EXPECT.gapBetweenNeighbours, "tight: the closest pair is the neighbours")
		same(plan.checks.minLaneSeparation, 512.5)
		same(plan.checks.pairs, n * (n - 1) / 2)
		same(plan.checks.requiredGap, 512)
	end
end)

test("brute force: no two PART boxes of different lanes (rails swept) are closer than 512, N=8", function()
	local plan = planWith(8)
	local boxes = {}
	for k = 1, 8 do
		boxes[k] = {}
		for i, p in Layout.parts(CONFIG, plan.lanes[k].origin) do boxes[k][i] = partNumbers(p, 224) end
	end
	local least, comparisons = math.huge, 0
	for i = 1, 7 do
		for j = i + 1, 8 do
			for _, a in boxes[i] do
				for _, b in boxes[j] do
					local g = numberGap(a, b)
					comparisons += 1
					if g < least then least = g end
				end
			end
		end
	end
	same(comparisons, 28 * 144 * 144, "every part pair of every lane pair was compared")
	assert(least >= 512, "closest pair of parts across lanes is " .. least)
	same(least, 512.5, "the closest parts are the independent rig's far nodes and the next lane's near nodes")
	-- and each lane's parts stay inside its own planned box
	for k = 1, 8 do
		for _, a in boxes[k] do
			local b = plan.lanes[k].box
			assert(a[1] >= b.min.x and a[2] <= b.max.x and a[3] >= b.min.y and a[4] <= b.max.y and a[5] >= b.min.z and a[6] <= b.max.z, "part outside lane box " .. k)
		end
	end
end)

test("gap and quantum: spacing is the smallest multiple of the quantum that leaves the gap", function()
	for _, case in {
		{ gap = 512, quantum = 2, spacing = 5122 },
		{ gap = 512, quantum = 1, spacing = 5122 },
		{ gap = 512, quantum = 0.5, spacing = 5121.5 },
		{ gap = 512, quantum = 256, spacing = 5376 },
		{ gap = 512, quantum = 7, spacing = 5124 },
		{ gap = 1000, quantum = 2, spacing = 5610 },
		{ gap = 100, quantum = 2, spacing = 4710 },
		{ gap = 0.5, quantum = 2, spacing = 4610 },
	} do
		local plan = planWith(3, { gap = case.gap, quantum = case.quantum })
		same(plan.spacing, case.spacing, "gap " .. case.gap .. " quantum " .. case.quantum)
		assert(plan.spacing >= EXPECT.depth + case.gap, "spacing keeps the gap")
		assert(plan.spacing - case.quantum < EXPECT.depth + case.gap, "and is the smallest such multiple")
		same(plan.spacing % case.quantum, 0, "multiple of the quantum")
		assert(plan.checks.minLaneSeparation >= case.gap, "measured separation keeps the gap")
	end
	same(planWith(2, { gap = 512 }).spacing, planWith(2).spacing, "512 is the default gap")
	-- rounding guard: with gap = 512 + 2^-43 (one ulp above 512) depth + gap rounds DOWN to 5121.5, an exact multiple of
	-- 0.5, which would leave the closest pair one ulp short of the requested gap; the plan must step to the next multiple
	local ulpGap = 512 + 2 ^ -43
	assert(ulpGap > 512 and 4609.5 + ulpGap == 5121.5, "premise: the sum rounds onto the multiple")
	local edge = planWith(2, { gap = ulpGap, quantum = 0.5 })
	same(edge.spacing, 5122, "next multiple, not 5121.5")
	assert(edge.checks.minLaneSeparation >= ulpGap, "closest pair keeps even a one-ulp gap")
end)

test("float32: N=8 maximum coordinate, worst spacing, and every part coordinate exactly representable", function()
	local plan = planWith(8)
	same(plan.maxAbsCoordinate, 23559.75, "max |coordinate| = last lane's far z corner 5632.75 + 3.5 * 5122")
	same(plan.worstFloat32Ulp, 2 ^ -9, "worst ulp, where |coordinate| is in [16384, 32768)")
	same(plan.worstFloat32Ulp, 0.001953125)
	same(plan.worstFloat32Ulp, measuredUlp(23559.75), "worst ulp equals the real float32 spacing at the largest coordinate")
	same(plan.worstFloat32UlpByAxis.x, measuredUlp(512.5), "X (the motion axis) keeps capture-scale precision")
	same(plan.worstFloat32UlpByAxis.x, 2 ^ -14)
	same(plan.worstFloat32UlpByAxis.y, measuredUlp(1536.75))
	same(plan.worstFloat32UlpByAxis.y, 2 ^ -13)
	same(plan.worstFloat32UlpByAxis.z, 2 ^ -9)
	same(plan.checks.maxFloat32RoundTrip, 0, "no coordinate changes when stored as float32")
	assert(plan.checks.exactFloat32 == true)
	local worst = plan.worstCoordinate
	same(worst.ulp, plan.worstFloat32Ulp)
	same(Layout.float32Ulp(worst.value), worst.ulp, "the reported worst coordinate really has that ulp")
	assert(worst.axis == "z" and worst.lane >= 1 and worst.lane <= 8)
	-- independent recomputation: every part centre of every lane, rail extremes included, round-trips through float32
	local worstSeen, maxAbsSeen = 0, 0
	for k = 1, 8 do
		for _, p in Layout.parts(CONFIG, plan.lanes[k].origin) do
			for _, v in { p.pos.x, p.pos.y, p.pos.z, p.pos.x - 224, p.pos.x + 224 } do
				same(f32value(f32bits(math.abs(v))), math.abs(v), "float32 holds " .. v .. " exactly")
				same(v % 1, 0, "integer coordinate " .. v)
				worstSeen = math.max(worstSeen, measuredUlp(math.abs(v)))
				maxAbsSeen = math.max(maxAbsSeen, math.abs(v))
			end
		end
	end
	same(maxAbsSeen, 23559, "largest part-centre coordinate")
	same(worstSeen, plan.worstFloat32Ulp, "worst ulp over all part centres equals the plan's")
	print(string.format("MEASURE N=8 spacing=%s depth=%s maxAbsCoordinate=%s worstFloat32Ulp=%s (2^-9) ulpX=%s ulpY=%s ulpZ=%s minLaneSeparation=%s minZoneSeparation=%s bounds.z=[%s, %s]",
		tostring(plan.spacing), tostring(plan.depth), tostring(plan.maxAbsCoordinate), tostring(plan.worstFloat32Ulp),
		tostring(plan.worstFloat32UlpByAxis.x), tostring(plan.worstFloat32UlpByAxis.y), tostring(plan.worstFloat32UlpByAxis.z),
		tostring(plan.checks.minLaneSeparation), tostring(plan.checks.minZoneSeparation), tostring(plan.bounds.min.z), tostring(plan.bounds.max.z)))
end)

test("float32 across N=1..12: max coordinate closed form, worst ulp is the real spacing there, exactness at every count", function()
	local lastUlp = 0
	for n = 1, 12 do
		local plan = planWith(n)
		local expectedMax = 5632.75 + (n - 1) * 2561
		same(plan.maxAbsCoordinate, expectedMax, "N=" .. n .. " max coordinate")
		same(plan.worstFloat32Ulp, measuredUlp(expectedMax), "N=" .. n .. " worst ulp")
		assert(plan.worstFloat32Ulp >= lastUlp, "worst ulp never shrinks as lanes are added")
		lastUlp = plan.worstFloat32Ulp
		same(plan.checks.maxFloat32RoundTrip, 0)
		same(plan.bounds.max.z, expectedMax)
		same(plan.bounds.min.z, EXPECT.minZ - (n - 1) * 2561)
		same(plan.bounds.min.x, EXPECT.minX); same(plan.bounds.max.y, EXPECT.maxY)
	end
	print(string.format("MEASURE N=12 maxAbsCoordinate=%s worstFloat32Ulp=%s", tostring(planWith(12).maxAbsCoordinate), tostring(planWith(12).worstFloat32Ulp)))
end)

test("a lane origin Roblox cannot hold exactly is refused, not silently rounded", function()
	rejects(function() planWith(2, { origin = { x = 0.1, y = 1024, z = 1024 } }) end, "not exactly representable in float32")
	rejects(function() planWith(1, { origin = { x = 0, y = 1024, z = 16777217 } }) end, "not exactly representable in float32") -- 2^24 + 1
	planWith(1, { origin = { x = 0, y = 1024, z = 16777216 } }) -- 2^24 itself is fine
	rejects(function() planWith(2, { origin = { x = 0, y = 1024, z = 1e38 } }) end, "not exactly representable in float32")
	rejects(function() planWith(2, { origin = { x = 0, y = 1024, z = 1e39 } }) end, "outside the float32 range")
	local ok = planWith(2, { origin = { x = 0.5, y = 1024.25, z = 1024 } })
	same(ok.lanes[1].origin.x, 0.5); same(ok.lanes[1].origin.y, 1024.25)
end)

test("another origin: lanes keep that origin's X and Y and are centred on its Z", function()
	local plan = planWith(3, { origin = { x = 10, y = 20, z = 30 } })
	for k = 1, 3 do
		same(plan.lanes[k].origin.x, 10); same(plan.lanes[k].origin.y, 20)
		same(plan.lanes[k].origin.z, 30 + (k - 2) * 5122)
		same(plan.lanes[k].box.min.x, 10 + EXPECT.minX); same(plan.lanes[k].box.max.x, 10 + EXPECT.maxX)
		same(plan.lanes[k].box.min.y, 20 + (EXPECT.minY - 1024)); same(plan.lanes[k].box.max.y, 20 + (EXPECT.maxY - 1024))
		same(plan.lanes[k].box.min.z, 30 + (k - 2) * 5122 + (EXPECT.minZ - 1024))
	end
	assert(deepEqual(plan.lanes[2].origin, { x = 10, y = 20, z = 30 }))
	assert(deepEqual(plan.origin, { x = 10, y = 20, z = 30 }))
end)

test("plan is deterministic, leaves its inputs alone and is deep-frozen", function()
	local before = deepCopy(CONFIG)
	local opts = { count = 6, gap = 600, excluded = { box(1, 2, 3, 4, 5, 6) } }
	local optsBefore = deepCopy(opts)
	local a, b = Layout.plan(CONFIG, opts), Layout.plan(CONFIG, opts)
	assert(deepEqual(a, b), "identical plans from identical inputs")
	assert(deepEqual(CONFIG, before), "config untouched")
	assert(deepEqual(opts, optsBefore), "options untouched")
	assert(table.isfrozen(a) and table.isfrozen(a.lanes) and table.isfrozen(a.lanes[1]) and table.isfrozen(a.lanes[1].box.min)
		and table.isfrozen(a.footprint) and table.isfrozen(a.checks) and table.isfrozen(a.excluded), "plan is frozen all the way down")
	rejects(function() a.spacing = 1 end, "readonly")
	rejects(function() a.lanes[1].origin.z = 0 end, "readonly")
	rejects(function() a.lanes[2].box.max.z = 0 end, "readonly")
	-- the plan owns its zone boxes: later edits to the caller's table cannot reach it
	opts.excluded[1].min.x = 999
	same(a.excluded[1].min.x, 1)
	assert(a.schema == "roalgo-spring-lane-layout-1" and Layout.SCHEMA == a.schema)
end)

test("plan() rejects impossible or malformed requests with a clear message", function()
	for _, bad in { 0, -1, 1.5, 65, 800, 0 / 0, math.huge, "8" } do
		rejects(function() planWith(bad) end, "count must be an integer from 1 to 64")
	end
	rejects(function() Layout.plan(CONFIG, {}) end, "count must be an integer from 1 to 64")
	rejects(function() Layout.plan(CONFIG) end, "options table required")
	same(planWith(64).count, 64, "64 lanes is the sanity bound")
	same(planWith(8.0).count, 8, "8.0 is an integer")
	for _, bad in { 0, -512, 0 / 0, math.huge, "512" } do
		rejects(function() planWith(2, { gap = bad }) end, "gap must be a positive finite number")
	end
	for _, bad in { 0, -2, 0 / 0, math.huge, "2" } do
		rejects(function() planWith(2, { quantum = bad }) end, "quantum must be a positive finite number")
	end
	for _, bad in { -1, 0 / 0, math.huge } do
		rejects(function() planWith(2, { zoneClearance = bad }) end, "zoneClearance must be a finite number >= 0")
	end
	rejects(function() planWith(2, { origin = { x = 0, y = 1024 } }) end, "origin needs finite numeric x, y and z")
	rejects(function() planWith(2, { origin = { x = 0, y = 0 / 0, z = 0 } }) end, "origin needs finite numeric x, y and z")
	rejects(function() planWith(2, { origin = 5 }) end, "origin must be a table")
	for _, key in { "railLimit", "anchorOffset", "nodeSize", "spacing" } do
		local broken = deepCopy(CONFIG)
		broken[key] = -1
		rejects(function() Layout.plan(broken, { count = 2 }) end, "config." .. key .. " must be a positive finite number")
		broken[key] = nil
		rejects(function() Layout.footprint(broken) end, "config." .. key .. " must be a positive finite number")
	end
	local noNodes = deepCopy(CONFIG)
	noNodes.nodes = {}
	rejects(function() Layout.plan(noNodes, { count = 2 }) end, "config.nodes")
	local badNode = deepCopy(CONFIG)
	badNode.nodes[3].z = "x"
	rejects(function() Layout.plan(badNode, { count = 2 }) end, "config.nodes[3] needs finite y and z")
	rejects(function() Layout.plan(nil, { count = 2 }) end, "config must be the rig config")
	rejects(function() Layout.parts(CONFIG, { x = 1 }) end, "origin needs finite numeric")
end)

test("a spacing override is verified: too small is an error that names the gap, exact is accepted", function()
	local depthPlusGap = EXPECT.depth + 512 -- 5121.5
	local err = rejects(function() planWith(3, { spacing = depthPlusGap - 0.25 }) end, "apart") -- 0.25 short of the gap, a value float32 holds exactly
	assert(string.find(err, "required gap 512", 1, true), "message names the required gap: " .. err)
	rejects(function() planWith(3, { spacing = 4609.5 + 100 }) end, "lanes 1 and 2 are only 100")
	rejects(function() planWith(3, { spacing = depthPlusGap - 0.001 }) end, "not exactly representable in float32") -- an off-grid spacing is refused too
	rejects(function() planWith(3, { spacing = EXPECT.depth }) end, "only 0 studs apart")
	rejects(function() planWith(3, { spacing = 100 }) end, "apart")
	rejects(function() planWith(3, { spacing = -5122 }) end, "spacing must be a positive finite number")
	rejects(function() planWith(3, { spacing = 0 / 0 }) end, "spacing must be a positive finite number")
	local exact = planWith(3, { spacing = depthPlusGap })
	same(exact.spacing, 5121.5)
	same(exact.checks.minLaneSeparation, 512, "exactly the gap")
	local roomy = planWith(3, { spacing = 20000 })
	same(roomy.lanes[3].offsetZ, 20000)
	same(roomy.checks.minLaneSeparation, 20000 - EXPECT.depth)
	-- shrinking the gap request is not an error by itself: it just packs the lanes closer, still at least the gap
	local packed = planWith(3, { gap = 64 })
	assert(packed.spacing < EXPECT.spacing and packed.checks.minLaneSeparation >= 64)
end)

------------------------------------------------------------------------------------------------------------------------
-- reserved zones

test("metronomeZones(): the stepper's two 8-stud cubes plus their fall, checked against simulated free fall", function()
	local zones = Layout.metronomeZones()
	same(#zones, 2)
	same(zones[1].min.x, -404); same(zones[1].max.x, -396)
	same(zones[2].min.x, 396); same(zones[2].max.x, 404)
	for _, z in zones do
		same(z.min.z, -504); same(z.max.z, -496)
		same(z.max.y, 5004, "top: the cube at its 5000 launch height")
	end
	-- simulate the 12 fall steps with both integration orders; the zone must hold the cube at every step
	local g, dt = 196.2, 1 / 60
	local lowestSemi, lowestExact = 0, 0
	local v, y = 0, 0
	for n = 1, 12 do
		v -= g * dt
		y += v * dt
		lowestSemi = y
		lowestExact = -0.5 * g * (n * dt) ^ 2
		assert(zones[1].min.y <= 5000 - 4 + y + 1e-9, "semi-implicit step " .. n .. " is inside the zone")
		assert(zones[1].min.y <= 5000 - 4 + lowestExact + 1e-9, "exact fall step " .. n .. " is inside the zone")
	end
	near(zones[1].min.y, 5000 - 4 + lowestSemi, 1e-9, "the zone reaches exactly the larger (semi-implicit) drop")
	near(-lowestSemi, 4.251, 1e-9, "12-step drop")
	near(-lowestExact, 3.924, 1e-9, "exact 12-step drop")
	-- options
	local lowGravity = Layout.metronomeZones({ gravity = 0 })
	same(lowGravity[1].min.y, 4996, "no gravity, no fall")
	local padded = Layout.metronomeZones({ margin = 10 })
	same(padded[1].min.x, -414); same(padded[1].max.y, 5014); same(padded[2].max.z, -486)
	rejects(function() Layout.metronomeZones({ gravity = -1 }) end, "gravity")
	rejects(function() Layout.metronomeZones({ margin = 0 / 0 }) end, "margin")
	rejects(function() Layout.metronomeZones(5) end, "opts must be a table")
end)

test("default plan reserves the metronomes and proves the lanes miss them; excluded = {} removes the zones", function()
	local plan = planWith(8)
	same(#plan.excluded, 2); same(plan.checks.zones, 2)
	local fall = 196.2 * (1 / 60) ^ 2 * 78
	near(plan.checks.minZoneSeparation, (5000 - 4 - fall) - EXPECT.maxY, 1e-9, "the metronomes are above the lanes")
	assert(plan.checks.minZoneSeparation > 3000)
	for k = 1, 8 do
		for z = 1, 2 do assert(Layout.separation(plan.lanes[k].box, plan.excluded[z]) > 0, "lane " .. k .. " clear of metronome " .. z) end
	end
	local none = planWith(8, { excluded = {} })
	same(#none.excluded, 0); same(none.checks.zones, 0); same(none.checks.minZoneSeparation, nil)
end)

test("a zone inside a lane (or straddling lanes, or covering all of them) is an error that names the lane and the zone", function()
	local plan = planWith(5)
	local lane3 = plan.lanes[3].box
	-- a small zone in the gap between the coupled and independent rigs: no part is there, but it is inside the lane box
	local midZ = (lane3.min.z + lane3.max.z) / 2
	local err = rejects(function() planWith(5, { excluded = { box(-10, 1200, midZ - 5, 10, 1300, midZ + 5) } }) end, "lane 3")
	assert(string.find(err, "excluded zone 1", 1, true), "names the zone: " .. err)
	-- straddling lane 2 and its gap
	rejects(function() planWith(5, { excluded = { box(-10, 1200, plan.lanes[2].box.max.z - 10, 10, 1300, plan.lanes[2].box.max.z + 100) } }) end, "lane 2")
	-- second zone offending: its index is reported
	local err2 = rejects(function()
		planWith(5, { excluded = { box(5000, 0, 0, 5001, 1, 1), box(-10, 1200, midZ, 10, 1300, midZ + 5) } })
	end, "excluded zone 2")
	assert(string.find(err2, "lane 3", 1, true), err2)
	rejects(function() planWith(5, { excluded = { box(-1e5, -1e5, -1e5, 1e5, 1e5, 1e5) } }) end, "lane 1")
	-- a zone around one part of a lane
	local node = Layout.parts(CONFIG, plan.lanes[4].origin)[3]
	rejects(function()
		planWith(5, { excluded = { box(node.pos.x - 1, node.pos.y - 1, node.pos.z - 1, node.pos.x + 1, node.pos.y + 1, node.pos.z + 1) } })
	end, "lane 4")
end)

test("zones: touching counts as intersecting, a gap-region zone is fine, zoneClearance widens the margin", function()
	local plan = planWith(3)
	local lane1, lane2 = plan.lanes[1].box, plan.lanes[2].box
	local function zoneAt(z0, z1) return box(-10, 1100, z0, 10, 1200, z1) end
	-- hugging the far face of lane 1: separation exactly 0
	rejects(function() planWith(3, { excluded = { zoneAt(lane1.max.z, lane1.max.z + 10) } }) end, "intersects or is within")
	-- a sliver past the face is clear with clearance 0 ...
	local sliver = planWith(3, { excluded = { zoneAt(lane1.max.z + 0.25, lane1.max.z + 0.5) } })
	same(sliver.checks.minZoneSeparation, 0.25)
	-- ... and refused once a clearance of 1 stud is demanded
	rejects(function() planWith(3, { excluded = { zoneAt(lane1.max.z + 0.25, lane1.max.z + 0.5) }, zoneClearance = 1 }) end, "within 1 studs")
	-- a zone in the middle of the 512.5 gap: 200 from lane 1, 312.5 from lane 2
	local inGap = planWith(3, { excluded = { zoneAt(lane1.max.z + 200, lane1.max.z + 200.5) } })
	same(inGap.checks.minZoneSeparation, 200)
	assert(lane1.max.z + 200.5 < lane2.min.z)
	planWith(3, { excluded = { zoneAt(lane1.max.z + 200, lane1.max.z + 200.5) }, zoneClearance = 199 })
	rejects(function() planWith(3, { excluded = { zoneAt(lane1.max.z + 200, lane1.max.z + 200.5) }, zoneClearance = 200 }) end, "excluded zone 1")
	-- a zone separated from every lane in X only: the same for all lanes, distance from the lane's -X face
	local west = planWith(12, { excluded = { box(-2048, 80, -896, -1312, 1360, 896) } }) -- the v2 presentation rig, contract D20 numbers
	same(west.checks.minZoneSeparation, 799.5, "799.5 studs (-1312 to -512.5) of clearance to the v2 presentation rig, on the X axis")
	-- malformed zones
	rejects(function() planWith(2, { excluded = { box(5, 0, 0, 1, 1, 1) } }) end, "min above max")
	rejects(function() planWith(2, { excluded = { { min = { x = 0, y = 0, z = 0 } } } }) end, "excluded[1].max must be a table")
	rejects(function() planWith(2, { excluded = { 5 } }) end, "excluded[1] must be a box")
	rejects(function() planWith(2, { excluded = "zones" }) end, "excluded must be a list of boxes")
end)

------------------------------------------------------------------------------------------------------------------------
-- verify

test("verify() re-derives every rule: a good plan passes, tampering is caught", function()
	local plan = planWith(4)
	local checks = Layout.verify(plan)
	same(checks.pairs, 6); same(checks.minLaneSeparation, 512.5); same(checks.zones, 2); same(checks.symmetric, true); same(checks.sameXY, true)
	Layout.verify(plan, CONFIG)
	assert(table.isfrozen(checks))

	local function tamper(mutate)
		local p = deepCopy(plan)
		mutate(p)
		return p
	end
	-- lane 2 pulled towards lane 1 by 4000 studs, box kept consistent: neighbours too close
	rejects(function() Layout.verify(tamper(function(p) moveLane(p, 2, -4000) end)) end, "lanes 1 and 2 are only")
	-- the same move but the stored box left stale
	rejects(function()
		Layout.verify(tamper(function(p) p.lanes[2].origin.z -= 4000; p.lanes[2].offsetZ -= 4000 end))
	end, "is not the footprint at its offset")
	-- lane 3 moved onto lane 1: only the non-adjacent pair overlaps (neighbour distances stay 5122)
	rejects(function() Layout.verify(tamper(function(p) moveLane(p, 3, -(2561 + 7683)) end)) end, "lanes 1 and 3 are only")
	-- a lane stepped sideways (X) or up (Y): lanes may differ in Z only
	rejects(function() Layout.verify(tamper(function(p) p.lanes[2].origin.x = 5 end)) end, "differs from the plan origin")
	rejects(function() Layout.verify(tamper(function(p) p.lanes[4].origin.y = 1100 end)) end, "differs from the plan origin")
	-- an origin z that does not equal origin + offset
	rejects(function() Layout.verify(tamper(function(p) p.lanes[2].origin.z += 1 end)) end, "is not origin z")
	-- everything shifted together: pairs fine, but no longer centred on the capture origin
	rejects(function() Layout.verify(tamper(function(p) for k = 1, 4 do moveLane(p, k, 100) end end)) end, "is not (k - (count + 1)/2) * spacing")
	-- offsets that are not mirror images although each is on the grid: spacing changed under the lanes
	rejects(function() Layout.verify(tamper(function(p) p.spacing += 2 end)) end, "is not (k - (count + 1)/2) * spacing")
	-- required gap raised above what the layout leaves
	rejects(function() Layout.verify(tamper(function(p) p.gap = 6000 end)) end, "below the required gap 6000")
	-- a reserved zone dropped into a lane after the fact
	rejects(function() Layout.verify(tamper(function(p) p.excluded[3] = box(-5, 1200, 3000, 5, 1300, 3010) end)) end, "excluded zone 3")
	-- structural damage
	rejects(function() Layout.verify(tamper(function(p) p.count = 5 end)) end, "exactly plan.count lanes")
	rejects(function() Layout.verify(tamper(function(p) p.lanes[2].index = 7 end)) end, "lane 2 is missing or has the wrong index")
	rejects(function() Layout.verify(tamper(function(p) p.schema = "other" end)) end, "not a roalgo-spring-lane-layout-1 plan")
	rejects(function() Layout.verify(nil) end, "not a roalgo-spring-lane-layout-1 plan")
	rejects(function() Layout.verify(tamper(function(p) p.gap = -1 end)) end, "plan.gap must be a positive finite number")
	rejects(function() Layout.verify(tamper(function(p) p.lanes[1].box.max.z = 0 / 0 end)) end, "lane 1 box")
	-- a shrunken footprint (every lane box, the depth and the bounds consistently smaller) passes alone but not against the config
	local small = tamper(function(p)
		p.footprint.max.z -= 1000
		p.depth -= 1000
		p.bounds.max.z -= 1000
		for k = 1, 4 do p.lanes[k].box.max.z -= 1000 end
	end)
	Layout.verify(small)
	local err = rejects(function() Layout.verify(small, CONFIG) end, "differs from the footprint derived from the config")
	assert(string.find(err, "5632.75", 1, true) or string.find(err, "4632.75", 1, true), "message shows the numbers: " .. err)
	local otherConfig = deepCopy(CONFIG)
	otherConfig.railLimit = 300
	rejects(function() Layout.verify(plan, otherConfig) end, "differs from the footprint derived from the config")
end)

test("verify() names the broken field of a structurally damaged plan", function()
	local plan = planWith(3)
	local function broken(mutate, fragment)
		local p = deepCopy(plan)
		mutate(p)
		rejects(function() Layout.verify(p) end, fragment)
	end
	broken(function(p) p.count = 2.5 end, "plan.count must be a positive integer")
	broken(function(p) p.count = 0 end, "plan.count must be a positive integer")
	broken(function(p) p.count = "3" end, "plan.count must be a positive integer")
	broken(function(p) p.spacing = 0 end, "plan.spacing must be a positive finite number")
	broken(function(p) p.spacing = 0 / 0 end, "plan.spacing must be a positive finite number")
	broken(function(p) p.origin = nil end, "plan.origin must be a table")
	broken(function(p) p.origin.y = math.huge end, "plan.origin needs finite numeric")
	broken(function(p) p.footprint = nil end, "plan.footprint must be a box")
	broken(function(p) p.footprint.min.x = 9999 end, "plan.footprint has min above max")
	broken(function(p) p.lanes = nil end, "exactly plan.count lanes")
	broken(function(p) p.lanes[3] = nil end, "exactly plan.count lanes")
	broken(function(p) p.lanes[2] = 5 end, "lane 2 is missing or has the wrong index")
	broken(function(p) p.lanes[2].origin = nil end, "lane 2 origin must be a table")
	broken(function(p) p.lanes[2].offsetZ = 0 / 0 end, "lane 2 needs a finite offsetZ")
	broken(function(p) p.lanes[3].box = nil end, "lane 3 box must be a box")
	broken(function(p) p.excluded = nil end, "plan.excluded must be a list of boxes")
	broken(function(p) p.excluded[1] = { min = { x = 0, y = 0, z = 0 } } end, "excluded zone 1.max must be a table")
	broken(function(p) p.zoneClearance = -1 end, "plan.zoneClearance must be a finite number >= 0")
	broken(function(p) p.zoneClearance = nil end, "plan.zoneClearance must be a finite number >= 0")
	-- a config that is not a config
	rejects(function() Layout.verify(plan, 5) end, "config must be the rig config")
	rejects(function() Layout.footprintFromParts({ { pos = { x = 0, y = 0, z = 0 }, size = { x = 1, y = 1, z = 1 }, moving = false } }, 1, 5) end, "opts must be a table")
end)

test("verifyBuilt(): measured part boxes of the built lanes must sit inside the planned lane boxes", function()
	local plan = planWith(3)
	local function built()
		local out = {}
		for k = 1, 3 do out[k] = Layout.parts(CONFIG, plan.lanes[k].origin) end
		return out
	end
	local report = Layout.verifyBuilt(plan, built())
	same(#report.lanes, 3)
	same(report.maxLooseness, 0, "the derived part boxes ARE the planned boxes")
	same(report.minLaneSeparation, 512.5)
	assert(report.minZoneSeparation > 3000)
	assert(deepEqual(report.lanes[2].box, plan.lanes[2].box))
	-- looseness: a built lane that does not use all of its box, reported not rejected
	local trimmed = built()
	for _, p in trimmed[2] do if p.kind == "node" then p.size = { x = 1, y = 1, z = 1 } end end
	local loose = Layout.verifyBuilt(plan, trimmed)
	same(loose.lanes[2].looseness, 0.25, "smaller nodes leave 0.25 stud of slack on the nearest face")
	same(loose.maxLooseness, 0.25)
	-- a built lane that exceeds its box (nodes of 3 studs instead of 1.5)
	local fat = built()
	for _, p in fat[2] do if p.kind == "node" then p.size = { x = 3, y = 3, z = 3 } end end
	rejects(function() Layout.verifyBuilt(plan, fat) end, "lane 2 measured footprint")
	-- a lane built at the wrong Z (300 studs off)
	local shifted = built()
	for _, p in shifted[3] do p.pos = { x = p.pos.x, y = p.pos.y, z = p.pos.z + 300 } end
	rejects(function() Layout.verifyBuilt(plan, shifted) end, "lane 3 measured footprint")
	-- built at the wrong X (rails sweep further than planned)
	local sideways = built()
	for _, p in sideways[1] do p.pos = { x = p.pos.x + 1, y = p.pos.y, z = p.pos.z } end
	rejects(function() Layout.verifyBuilt(plan, sideways) end, "lane 1 measured footprint")
	-- an extra part far outside
	local stray = built()
	table.insert(stray[1], { name = "Stray", pos = { x = 0, y = 1100, z = plan.lanes[1].box.max.z + 100 }, size = { x = 1, y = 1, z = 1 }, moving = false })
	rejects(function() Layout.verifyBuilt(plan, stray) end, "lane 1 measured footprint")
	-- wrong lane count, a lane with no parts, a part without the moving flag, off-axis allowance
	local twoOnly = built()
	twoOnly[3] = nil
	rejects(function() Layout.verifyBuilt(plan, twoOnly) end, "exactly 3 lanes")
	local empty = built()
	empty[2] = {}
	rejects(function() Layout.verifyBuilt(plan, empty) end, "non-empty list")
	local noFlag = built()
	noFlag[1][3] = { name = "NoFlag", pos = noFlag[1][3].pos, size = noFlag[1][3].size }
	rejects(function() Layout.verifyBuilt(plan, noFlag) end, "moving must be true or false")
	Layout.verifyBuilt(plan, built(), { offAxis = 0.0 })
	rejects(function() Layout.verifyBuilt(plan, built(), { offAxis = 1 }) end, "lane 1 measured footprint") -- 1 stud of wander leaves the exact boxes
	-- a tampered plan is refused before anything is compared
	local bad = deepCopy(plan)
	moveLane(bad, 2, -4000)
	rejects(function() Layout.verifyBuilt(bad, built()) end, "lanes 1 and 2 are only")
end)

------------------------------------------------------------------------------------------------------------------------
-- verifyBuilt, the Studio-time proof (contract L16: "no two lanes' parts can touch, asserted at build time").
-- Added after review: the cases above only pushed lanes towards +Z and +X or inflated every axis at once, so dropping the
-- min-Y, max-Y or min-Z test of contains(), or tolerating a ninth built lane, still passed. Every rule below is pinned by a
-- case that is red when that one rule is dropped, on any one face, for any one lane.

local function derivedBuilt(plan)
	local out = {}
	for k = 1, plan.count do out[k] = Layout.parts(CONFIG, plan.lanes[k].origin) end
	return out
end
local function shiftParts(parts, dx, dy, dz)
	for _, p in parts do p.pos = { x = p.pos.x + dx, y = p.pos.y + dy, z = p.pos.z + dz } end
end
local function dropParts(parts, predicate)
	local kept = {}
	for _, p in parts do
		if not predicate(p) then table.insert(kept, p) end
	end
	return kept
end
local function strayPart(centre)
	return { name = "Stray", pos = centre, size = { x = 1, y = 1, z = 1 }, moving = false }
end

test("verifyBuilt enforces all six faces of every lane: a part reaching 0.75 out of any one face is rejected, one resting exactly on it is accepted", function()
	local plan = planWith(3)
	local checked = 0
	for k = 1, 3 do
		local b = plan.lanes[k].box
		local mid = { x = (b.min.x + b.max.x) / 2, y = (b.min.y + b.max.y) / 2, z = (b.min.z + b.max.z) / 2 }
		for _, face in { { "min", "x" }, { "max", "x" }, { "min", "y" }, { "max", "y" }, { "min", "z" }, { "max", "z" } } do
			local corner, axis = face[1], face[2]
			local outward = if corner == "min" then -1 else 1
			local f = b[corner][axis]
			-- centre of a 1-stud static part that sits `beyond` studs past the face (negative: inside the lane)
			local function centre(beyond)
				local c = { x = mid.x, y = mid.y, z = mid.z }
				c[axis] = f + outward * beyond
				return c
			end
			local out = derivedBuilt(plan)
			table.insert(out[k], strayPart(centre(0.25))) -- spans 0.25 inside .. 0.75 outside the face
			rejects(function() Layout.verifyBuilt(plan, out) end, "lane " .. k .. " measured footprint")
			local on = derivedBuilt(plan)
			table.insert(on[k], strayPart(centre(-0.5))) -- spans 1 stud inside .. exactly the face
			local report = Layout.verifyBuilt(plan, on)
			same(report.maxLooseness, 0, "lane " .. k .. " " .. corner .. " " .. axis .. ": a part exactly on the face leaves the box tight")
			checked += 1
		end
	end
	same(checked, 18, "3 lanes x 6 faces")
end)

test("verifyBuilt rejects a whole lane built in the wrong place: every lane, every axis, both directions, 0.25 stud up to a lane spacing", function()
	local plan = planWith(3)
	same(Layout.verifyBuilt(plan, derivedBuilt(plan)).maxLooseness, 0, "control: built exactly as planned is accepted")
	local cases = 0
	for k = 1, 3 do
		for _, axis in { "x", "y", "z" } do
			for _, dist in { 0.25, 1, 300, 5122 } do
				for _, sign in { -1, 1 } do
					local built = derivedBuilt(plan)
					local d = { x = 0, y = 0, z = 0 }
					d[axis] = sign * dist
					shiftParts(built[k], d.x, d.y, d.z)
					rejects(function() Layout.verifyBuilt(plan, built) end, "lane " .. k .. " measured footprint")
					cases += 1
				end
			end
		end
	end
	same(cases, 72, "3 lanes x 3 axes x 4 distances x 2 directions")
	-- two lanes handed over in each other's place
	local swapped = derivedBuilt(plan)
	swapped[1], swapped[2] = swapped[2], swapped[1]
	rejects(function() Layout.verifyBuilt(plan, swapped) end, "lane 1 measured footprint")
	-- pos is the REST position: one node already displaced 1 stud along its rail is swept from the wrong place and refused
	local displaced = derivedBuilt(plan)
	for _, p in displaced[2] do
		if p.rig == "coupled" and p.kind == "node" and p.node == 1 then p.pos = { x = p.pos.x + 1, y = p.pos.y, z = p.pos.z } end
	end
	rejects(function() Layout.verifyBuilt(plan, displaced) end, "lane 2 measured footprint")
end)

test("verifyBuilt demands exactly one measured part list per planned lane, and refuses a lane that carries the stepper's metronome", function()
	local plan = planWith(3)
	local four = derivedBuilt(plan)
	four[4] = Layout.parts(CONFIG, { x = 0, y = 1024, z = 1024 + 4 * 5122 })
	rejects(function() Layout.verifyBuilt(plan, four) end, "exactly 3 lanes") -- one list too many is as wrong as one too few
	local two = derivedBuilt(plan)
	two[3] = nil
	rejects(function() Layout.verifyBuilt(plan, two) end, "exactly 3 lanes")
	for _, bad in { {}, "lanes", 5, true } do
		rejects(function() Layout.verifyBuilt(plan, bad) end, "exactly 3 lanes")
	end
	rejects(function() Layout.verifyBuilt(plan, nil) end, "exactly 3 lanes")
	local plan8 = planWith(8)
	local nine = derivedBuilt(plan8)
	nine[9] = Layout.parts(CONFIG, { x = 0, y = 1024, z = 1024 + 9 * 5122 })
	rejects(function() Layout.verifyBuilt(plan8, nine) end, "exactly 8 lanes")
	same(Layout.verifyBuilt(plan8, derivedBuilt(plan8)).maxLooseness, 0, "control: eight lists for eight lanes")
	-- documented hazard: SpringV2Engine parents two UNANCHORED 8-stud cubes (MetronomeA/B) into every lane Model. They are
	-- not rig parts (metronomeZones() reserves them), so a caller that hands them over is told, with the numbers.
	local withMetronome = derivedBuilt(plan)
	table.insert(withMetronome[1], { name = "MetronomeA", pos = { x = -400, y = 5000, z = -500 }, size = { x = 8, y = 8, z = 8 }, moving = true })
	local err = rejects(function() Layout.verifyBuilt(plan, withMetronome) end, "lane 1 measured footprint")
	assert(string.find(err, "5004.0000", 1, true), "the message shows the cube's top, 5004: " .. err)
end)

test("verifyBuilt reports MEASURED numbers: frozen report, looseness on each of the six faces, minima over all lane pairs and all zones", function()
	local plan = planWith(3)
	local report = Layout.verifyBuilt(plan, derivedBuilt(plan))
	assert(table.isfrozen(report) and table.isfrozen(report.lanes) and table.isfrozen(report.lanes[1])
		and table.isfrozen(report.lanes[1].box) and table.isfrozen(report.lanes[1].box.min), "the report is frozen all the way down")
	-- Looseness is how much of a planned box the build leaves unused, on the face where it is largest. One lane loses the
	-- parts that define exactly one face; the expected slack is hand-derived from the config (nodes 1..8 are the y = 512
	-- bank, z = (col - 1) * 256, col = node % 8 or 8; anchors reach -512.5, nodes +-224.75 at full travel, guides +-224).
	local faceCases = {
		{ "max z", 256, function(p) return p.rig == "independent" and p.node % 8 == 0 end },
		{ "min z", 256, function(p) return p.rig == "coupled" and p.node % 8 == 1 end },
		{ "max y", 256, function(p) return p.node <= 8 end },
		{ "min y", 256, function(p) return p.node >= 17 end },
		{ "min x", 287.75, function(p) return p.kind == "anchor" end }, -- 512.5 - 224.75: the node at -railLimit is next
		{ "max x", 0.75, function(p) return p.kind == "node" end }, -- 224.75 - 224: the guide end is next (y and z slack is only 0.25)
	}
	for _, c in faceCases do
		for k = 1, 3 do
			local built = derivedBuilt(plan)
			built[k] = dropParts(built[k], c[3])
			local r = Layout.verifyBuilt(plan, built)
			same(r.lanes[k].looseness, c[2], "lane " .. k .. " looseness on the " .. c[1] .. " face")
			same(r.maxLooseness, c[2], "max looseness, " .. c[1] .. " face")
			for j = 1, 3 do
				if j ~= k then same(r.lanes[j].looseness, 0, "untouched lane " .. j) end
			end
		end
	end
	-- the closest PAIR is found among all pairs of the measured boxes, wherever it is
	local function without(built, k, predicate)
		built[k] = dropParts(built[k], predicate)
		return built
	end
	local lane1FarZ = function(p) return p.rig == "independent" and p.node % 8 == 0 end
	local lane3NearZ = function(p) return p.rig == "coupled" and p.node % 8 == 1 end
	same(Layout.verifyBuilt(plan, without(derivedBuilt(plan), 1, lane1FarZ)).minLaneSeparation, 512.5, "only pair (1,2) loosened: pair (2,3) is the closest")
	same(Layout.verifyBuilt(plan, without(derivedBuilt(plan), 3, lane3NearZ)).minLaneSeparation, 512.5, "only pair (2,3) loosened: pair (1,2) is the closest")
	local both = without(without(derivedBuilt(plan), 1, lane1FarZ), 3, lane3NearZ)
	same(Layout.verifyBuilt(plan, both).minLaneSeparation, 768.5, "measured 512.5 + 256 on both neighbour pairs, not the planned 512.5")
	-- zones: the nearest zone-lane pair over all zones and all lanes (the near sliver is zone 2, beside the LAST lane)
	local lastFarZ = plan.lanes[3].box.max.z
	local zonePlan = planWith(3, { excluded = {
		box(5000, 1100, 0, 5001, 1200, 1),
		box(-10, 1100, lastFarZ + 0.25, 10, 1200, lastFarZ + 0.5),
	} })
	same(Layout.verifyBuilt(zonePlan, derivedBuilt(zonePlan)).minZoneSeparation, 0.25, "the sliver 0.25 beyond lane 3 is the closest zone")
	same(Layout.verifyBuilt(zonePlan, without(derivedBuilt(zonePlan), 3, lane1FarZ)).minZoneSeparation, 256.25, "measured: lane 3 lost its far columns, so 0.25 + 256")
	same(Layout.verifyBuilt(planWith(3, { excluded = {} }), derivedBuilt(plan)).minZoneSeparation, nil, "no zones, no zone separation")
end)

test("a box with min above max is refused on every axis: as a zone, as the plan footprint, as a lane box and as a stored zone", function()
	for _, bad in { box(5, 0, 0, 1, 1, 1), box(0, 5, 0, 1, 1, 1), box(0, 0, 5, 1, 1, 1) } do
		rejects(function() planWith(2, { excluded = { bad } }) end, "min above max")
	end
	local plan = planWith(3)
	for _, axis in { "x", "y", "z" } do
		local p = deepCopy(plan)
		p.footprint.min[axis] = 99999
		rejects(function() Layout.verify(p) end, "plan.footprint has min above max")
		local q = deepCopy(plan)
		q.lanes[2].box.min[axis] = 1e9
		rejects(function() Layout.verify(q) end, "lane 2 box has min above max")
		local r = deepCopy(plan)
		r.excluded[1].min[axis] = 1e9
		rejects(function() Layout.verify(r) end, "excluded zone 1 has min above max")
	end
end)

test("footprintFromParts: the off-axis allowance widens a lone moving part on both sides in Y and Z, and never a static part", function()
	local lone = Layout.footprintFromParts({ { pos = { x = 10, y = 20, z = 30 }, size = { x = 2, y = 4, z = 6 }, moving = true } }, 50, { offAxis = 3 })
	assert(deepEqual(lone, box(-41, 15, 24, 61, 25, 36)), "x +-50, y 18..22 -> 15..25, z 27..33 -> 24..36")
	local still = Layout.footprintFromParts({ { pos = { x = 10, y = 20, z = 30 }, size = { x = 2, y = 4, z = 6 }, moving = false } }, 50, { offAxis = 3 })
	assert(deepEqual(still, box(9, 18, 27, 11, 22, 33)), "a static part neither travels nor wanders")
end)

test("metronomeZones margin grows every one of the six faces of both zones by exactly the margin", function()
	local base, padded = Layout.metronomeZones(), Layout.metronomeZones({ margin = 10 })
	same(#padded, 2)
	for i = 1, 2 do
		for _, axis in { "x", "y", "z" } do
			same(padded[i].min[axis], base[i].min[axis] - 10, "zone " .. i .. " min " .. axis)
			same(padded[i].max[axis], base[i].max[axis] + 10, "zone " .. i .. " max " .. axis)
		end
	end
end)

test("a rail limit whose extreme positions Roblox cannot hold exactly is refused, and the message names the rail coordinate", function()
	local c = deepCopy(CONFIG)
	c.railLimit = 224.1 -- not a multiple of a power of two: the node centres at +-railLimit would be rounded
	local err = rejects(function() Layout.plan(c, { count = 1 }) end, "not exactly representable in float32")
	assert(string.find(err, "@+rail", 1, true), "it is the rail-extreme coordinate that is inexact: " .. err)
	same(Layout.plan(CONFIG, { count = 1 }).checks.maxFloat32RoundTrip, 0, "the real railLimit 224 is exact at both extremes")
end)

test("the default quantum keeps every lane origin an integer for any count, whatever the gap", function()
	for _, gap in { 512, 513, 700.3, 1023.9 } do
		for _, n in { 1, 2, 3, 7, 8, 11, 12, 63, 64 } do
			local plan = planWith(n, { gap = gap })
			same(plan.spacing % 2, 0, "gap " .. gap .. ": spacing is a multiple of the default quantum 2")
			for k = 1, n do
				same(plan.lanes[k].offsetZ % 1, 0, "gap " .. gap .. " N=" .. n .. " lane " .. k .. " offset is an integer")
				same(plan.lanes[k].origin.z % 1, 0, "gap " .. gap .. " N=" .. n .. " lane " .. k .. " origin z is an integer")
			end
			if n > 1 then assert(plan.checks.minLaneSeparation >= gap, "and the gap still holds") end
		end
	end
	same(planWith(2, { gap = 513 }).spacing, 5124, "4609.5 + 513 = 5122.5 rounds up to the next even number")
end)

test("verify(plan, config) re-derives the rail limit; verify(plan) re-derives depth and bounds from the lane boxes", function()
	for n = 1, 12 do
		local plan = planWith(n)
		Layout.verify(plan, CONFIG) -- no false alarm on a genuine plan, odd or even count
		same(plan.railLimit, 224); same(plan.depth, 4609.5)
		same(plan.bounds.min.z, plan.lanes[1].box.min.z); same(plan.bounds.max.z, plan.lanes[n].box.max.z)
	end
	local small = { railLimit = 100, anchorOffset = 50, nodeSize = 3, spacing = 10, nodes = { { y = 0, z = 0 }, { y = 5, z = 20 }, { y = -8, z = 7 } } }
	Layout.verify(Layout.plan(small, { count = 3, excluded = {} }), small)
	local plan = planWith(4)
	-- a plan whose rail limit was rewritten would sweep the measured rails by the wrong amount: only the config can say so
	for _, wrong in { 0, 223.5, 224.5, 1000 } do
		local p = deepCopy(plan)
		p.railLimit = wrong
		rejects(function() Layout.verify(p, CONFIG) end, "plan.railLimit")
	end
	-- a rail limit that is not a number is refused even without a config
	for _, bad in { -1, 0 / 0, math.huge, "224" } do
		local p = deepCopy(plan)
		p.railLimit = bad
		rejects(function() Layout.verify(p) end, "plan.railLimit must be a finite number >= 0")
	end
	local noRail = deepCopy(plan)
	noRail.railLimit = nil
	rejects(function() Layout.verify(noRail) end, "plan.railLimit must be a finite number >= 0")
	-- depth is the footprint's own extent along Z
	for _, wrong in { 1, 4609, 4610, 0 } do
		local p = deepCopy(plan)
		p.depth = wrong
		rejects(function() Layout.verify(p) end, "plan.depth")
	end
	-- bounds is the union of the lane boxes: every one of the six faces, and a missing box
	for _, face in { { "min", "x" }, { "max", "x" }, { "min", "y" }, { "max", "y" }, { "min", "z" }, { "max", "z" } } do
		local p = deepCopy(plan)
		p.bounds[face[1]][face[2]] += 1
		rejects(function() Layout.verify(p) end, "plan.bounds")
	end
	local lastOnly = deepCopy(plan) -- bounds that cover only the first lane
	lastOnly.bounds = deepCopy(plan.lanes[1].box)
	rejects(function() Layout.verify(lastOnly) end, "plan.bounds")
	local noBounds = deepCopy(plan)
	noBounds.bounds = nil
	rejects(function() Layout.verify(noBounds) end, "plan.bounds must be a box")
end)

test("custom excluded zones REPLACE the stepper's metronome zones (add metronomeZones() back to keep them); plan.gap reports the request", function()
	local one = planWith(2, { excluded = { box(5000, 0, 0, 5001, 1, 1) } })
	same(#one.excluded, 1, "the metronome zones are gone")
	same(one.checks.zones, 1)
	local zones = Layout.metronomeZones()
	local inLane2 = planWith(2).lanes[2].box
	local midZ = (inLane2.min.z + inLane2.max.z) / 2
	local bad = box(-10, 1200, midZ, 10, 1300, midZ + 5) -- in the empty middle of lane 2's box: still a lane zone
	local kept = planWith(2, { excluded = { zones[1], zones[2], box(5000, 0, 0, 5001, 1, 1) } })
	same(#kept.excluded, 3); same(kept.checks.zones, 3)
	rejects(function() planWith(2, { excluded = { zones[1], zones[2], bad } }) end, "excluded zone 3")
	-- L16's 512-stud gap is the default; a smaller request is honoured and visible, so the controller can assert plan.gap >= DEFAULT_GAP
	same(planWith(2).gap, Layout.DEFAULT_GAP)
	same(planWith(2, { gap = 64 }).gap, 64)
	assert(planWith(2, { gap = 64 }).gap < Layout.DEFAULT_GAP)
end)

print(string.format("SpringLaneLayout: %d tests passed", passed))
