--!strict
-- SpringLaneLayout: where the N copies ("lanes") of the capture-time v2 rig go, and the proof that they cannot touch.
-- Contract: spring-live-contract.md section 1b (L16 lanes, L21 visual layering). PURE Luau: no Roblox globals, no I/O.
-- Vector-like values are plain {x, y, z} tables; boxes are {min = {x,y,z}, max = {x,y,z}}. Nothing here builds a part,
-- steps physics or touches Studio; Studio code asks this module where to build and then checks the built rigs against it.
--
-- WHAT A LANE IS. One lane is the capture-time SpringV2Engine built at a lane origin: the coupled rig at the origin and
-- the independent rig at origin + (0, 0, 11 * spacing) (SpringV2Engine.luau:115). Lane origins differ in Z only, so the
-- motion axis X and the vertical layout keep the capture's coordinates. Lane offsets are centred on the capture origin:
-- offsetZ_k = (k - (N + 1) / 2) * S for k = 1..N, so they are mirror images that sum to 0 (contract L16 writes this loosely
-- as +-k*S). For ODD N the middle lane has offset 0 and IS the capture lane (origin exactly (0, 1024, 1024)); for EVEN N the
-- lanes straddle the capture origin at +-S/2, +-3S/2, ... and no lane sits at the capture position.
--
-- GEOMETRY DERIVED FROM THE CAPTURE ENGINE (SpringV2Engine.luau buildRig, lines 27-34), for each node i with rest
-- position rest_i = rigOrigin + (0, y_i, z_i), config = 2024 native.config:
--   Guide  : anchored, centre rest_i,                   size (2 * railLimit, 0.18, 0.18)         line 29
--   Anchor : anchored, centre rest_i - (anchorOffset,0,0), size (1, 1, 1)                        line 31
--   Node   : the ONLY moving body, centre rest_i, cube of nodeSize, PrismaticConstraint on X with
--            limits +-railLimit (lines 38-41): it can only move along X, within +-railLimit of rest.
-- Springs, rails, attachments and the VectorForce are constraints on those parts and add no extent of their own.
-- Closed-form footprint of one rig (hNode = nodeSize/2 = 0.75, hAnchor = 0.5, hGuideYZ = 0.09):
--   x : [ox + min(-(anchorOffset + hAnchor), -(railLimit + hNode), -railLimit), ox + max(-(anchorOffset - hAnchor), railLimit + hNode, railLimit)]
--       = [ox - 512.5, ox + 224.75]                 (anchor tail on -X, node at full +railLimit travel on +X)
--   y : [oy + min(y_i) - 0.75, oy + max(y_i) + 0.75] = [oy - 0.75, oy + 512.75]   (y_i = (3 - bank) * 256)
--   z : [oz + min(z_i) - 0.75, oz + max(z_i) + 0.75] = [oz - 0.75, oz + 1792.75]   (z_i = (col - 1) * 256)
-- A lane box is the union of both rigs; the independent rig is shifted by 11 * spacing = 2816 in Z, so
--   lane box at the capture origin (0, 1024, 1024):  x [-512.5, 224.75]  y [1023.25, 1536.75]  z [1023.25, 5632.75]
--   lane depth along Z = 4609.5 studs.
-- Because the moving bodies travel along X only, rail travel changes the X extent and NEVER the Z extent that decides
-- how far apart lanes are. Lane spacing S = ceil((depth + gap) / quantum) * quantum, so the clear space between two
-- neighbouring lane boxes is S - depth, which is at least `gap` by construction and is re-checked by verify().
--
-- API (all errors are raised with a message starting "SpringLaneLayout.<function>:"):
--   SpringLaneLayout.footprint(config, origin?) -> Box        closed form above, one lane, both rigs, full rail travel
--   SpringLaneLayout.footprintFromParts(parts, railLimit, opts?) -> Box
--       parts = { {pos = {x,y,z}, size = {x,y,z}, moving = boolean, name? ...}, ... }. A moving part's box is swept
--       +-railLimit along X from pos (pos is the REST position, i.e. as built / after reset). opts.offAxis (default 0)
--       also lets moving parts wander that far in Y and Z (the 2024 capture measured maxOffAxis 0).
--   SpringLaneLayout.parts(config, origin?) -> { Part }       the 144 part boxes of one lane, same shape as above
--   SpringLaneLayout.plan(config, opts) -> plan               opts = {count, gap = 512, origin = capture origin,
--       excluded = reserved zones (default: the stepper's two metronomes), zoneClearance = 0, quantum = 2,
--       spacing = override (verified, errors if too small)}
--       `excluded` REPLACES the default metronome zones; to keep them pass metronomeZones() plus your own boxes. `gap` is
--       the caller's request and plan() honours any positive value (tests pack lanes tighter); plan.gap reports it, and the
--       live controller must assert plan.gap >= SpringLaneLayout.DEFAULT_GAP (the L16 floor) before building anything.
--       plan = {schema, count, gap, spacing, depth, quantum, origin, railLimit, footprint, bounds, excluded, zoneClearance,
--               lanes = { {index, origin = {x,y,z}, offsetZ, box} }, maxAbsCoordinate, worstFloat32Ulp,
--               worstFloat32UlpByAxis = {x,y,z}, worstCoordinate = {lane, part, axis, value, ulp}, checks}
--       The plan is deep-frozen. plan() calls verify() and raises if any rule fails.
--   SpringLaneLayout.verify(plan, config?) -> checks          re-derives and re-checks every rule from the plan alone
--       (structure, offsets, stored boxes, every lane pair, zones, depth, bounds = union of the lane boxes, railLimit is a
--       real length); with a config it also re-derives the footprint and compares plan.railLimit with config.railLimit.
--       Use it with the config on any plan that crossed a boundary: only the config can say the rail length is the real one.
--   SpringLaneLayout.verifyBuilt(plan, built, opts?) -> report   built[k] = measured part boxes of lane k (Studio). Each
--       lane's measured footprint must lie inside its planned box (containment in a verified plan implies the lanes are
--       >= gap apart and clear of every zone). report = {lanes = {{index, box, looseness}}, minLaneSeparation,
--       minZoneSeparation, maxLooseness}: the measured numbers, and how much of each planned box the build left unused.
--       WHAT built[k] MUST BE: exactly the rig parts of lane k, the 144 that parts() lists (guides, anchors, nodes), each as
--         {pos = Part.Position AS BUILT, before any stepping (the REST position: a moving body is swept +-railLimit from it,
--          so one that already slid is refused), size = Part.Size, moving = not Part.Anchored}.
--       It must NOT include the stepper's MetronomeA / MetronomeB: SpringV2Engine parents two unanchored 8-stud cubes into
--       every lane Model at (+-400, 5000, -500). They are not rig parts and metronomeZones() reserves their space; handed
--       over as lane parts they widen the measured box to y 5004 and the lane is (correctly) rejected.
--       The plan's own railLimit is trusted here: run verify(plan, config) first on a plan that crossed a boundary.
--   SpringLaneLayout.metronomeZones(opts?) -> { Box }         reserved boxes of VerifiedStepper's two metronomes
--   SpringLaneLayout.float32Ulp(v) / float32Round(v)          float32 spacing near |v| / nearest float32
--   SpringLaneLayout.separation(a, b) / intersects(a, b) / contains(outer, inner) / translate(box, dx, dy, dz) / size(box)
-- Everything is deterministic: the same inputs give the same plan, bit for bit.
local SpringLaneLayout = {}

export type Vec3 = { read x: number, read y: number, read z: number }
export type Box = { read min: Vec3, read max: Vec3 }
export type Part = { name: string?, kind: string?, rig: string?, node: number?, pos: Vec3, size: Vec3, moving: boolean }

SpringLaneLayout.SCHEMA = "roalgo-spring-lane-layout-1"
-- The 2024 capture origin: SpringV2Engine.luau:100 `opts.origin or Vector3.new(0,1024,1024)`.
SpringLaneLayout.CAPTURE_ORIGIN = table.freeze({ x = 0, y = 1024, z = 1024 })
SpringLaneLayout.DEFAULT_GAP = 512 -- L16: spacing >= footprint + a 512-stud gap
-- Spacing is rounded UP to a multiple of this, so with an even quantum every lane origin is an integer for any count.
SpringLaneLayout.SPACING_QUANTUM = 2
SpringLaneLayout.MAX_LANES = 64 -- sanity bound against typos (count = 800), not a Roblox limit
SpringLaneLayout.FLOAT32_MAX = 3.4028234663852886e38
-- Constants hard-coded in SpringV2Engine.luau (not in config): anchor cube size (line 31), guide thickness (line 29),
-- the independent rig offset in config.spacing units (line 115).
SpringLaneLayout.RIG = table.freeze({ anchorSize = 1, guideThickness = 0.18, independentSpacings = 11 })
-- VerifiedStepper.luau newMetronome / _resetMetronomes: two 8-stud cubes at (+-400, 5000, -500), re-launched every
-- METRONOME_SPAN = 12 confirmed steps, falling under workspace.Gravity (default 196.2) in between.
SpringLaneLayout.METRONOME = table.freeze({
	size = 8, y = 5000, z = -500, xs = table.freeze({ -400, 400 }), span = 12, dt = 1 / 60, gravity = 196.2,
})

local RIG = SpringLaneLayout.RIG
local FLOAT32_MAX = SpringLaneLayout.FLOAT32_MAX

------------------------------------------------------------------------------------------------------------------------
-- small helpers

local function isFinite(x: any): boolean
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function fail(fn: string, message: string)
	error("SpringLaneLayout." .. fn .. ": " .. message, 0)
end

local function readVec(fn: string, v: any, what: string): Vec3
	if type(v) ~= "table" then fail(fn, what .. " must be a table {x, y, z}") end
	local x, y, z = v.x, v.y, v.z
	if not (isFinite(x) and isFinite(y) and isFinite(z)) then fail(fn, what .. " needs finite numeric x, y and z") end
	return { x = x, y = y, z = z }
end

local function readBox(fn: string, b: any, what: string): Box
	if type(b) ~= "table" then fail(fn, what .. " must be a box {min = {x,y,z}, max = {x,y,z}}") end
	local lo, hi = readVec(fn, b.min, what .. ".min"), readVec(fn, b.max, what .. ".max")
	if lo.x > hi.x or lo.y > hi.y or lo.z > hi.z then fail(fn, what .. " has min above max") end
	return { min = lo, max = hi }
end

local function readConfig(fn: string, config: any): any
	if type(config) ~= "table" then fail(fn, "config must be the rig config (native.config), got " .. typeof(config)) end
	for _, key in { "railLimit", "anchorOffset", "nodeSize", "spacing" } do
		local v = config[key]
		if not isFinite(v) or v <= 0 then fail(fn, "config." .. key .. " must be a positive finite number, got " .. tostring(v)) end
	end
	local nodes = config.nodes
	if type(nodes) ~= "table" or #nodes < 1 then fail(fn, "config.nodes must list the rig nodes with y and z") end
	for i = 1, #nodes do
		local n = nodes[i]
		if type(n) ~= "table" or not isFinite(n.y) or not isFinite(n.z) then fail(fn, "config.nodes[" .. i .. "] needs finite y and z") end
	end
	return config
end

local function copyVec(v: Vec3): Vec3
	return { x = v.x, y = v.y, z = v.z }
end

local function deepFreeze(t: any): any
	if type(t) == "table" and not table.isfrozen(t) then
		for _, v in t do deepFreeze(v) end
		table.freeze(t)
	end
	return t
end

local function gap1(aLo: number, aHi: number, bLo: number, bHi: number): number
	return math.max(aLo - bHi, bLo - aHi)
end

------------------------------------------------------------------------------------------------------------------------
-- boxes

-- Signed clear distance along the best separating axis: > 0 means the closed boxes are that far apart (every point pair
-- is at least this far apart); 0 means they touch; < 0 means they overlap (by this much along the shallowest axis).
function SpringLaneLayout.separation(a: Box, b: Box): number
	local sx = gap1(a.min.x, a.max.x, b.min.x, b.max.x)
	local sy = gap1(a.min.y, a.max.y, b.min.y, b.max.y)
	local sz = gap1(a.min.z, a.max.z, b.min.z, b.max.z)
	return math.max(sx, sy, sz)
end

-- True when the two closed boxes share at least one point (touching counts).
function SpringLaneLayout.intersects(a: Box, b: Box): boolean
	return SpringLaneLayout.separation(a, b) <= 0
end

function SpringLaneLayout.contains(outer: Box, inner: Box): boolean
	return outer.min.x <= inner.min.x and outer.min.y <= inner.min.y and outer.min.z <= inner.min.z
		and outer.max.x >= inner.max.x and outer.max.y >= inner.max.y and outer.max.z >= inner.max.z
end

function SpringLaneLayout.translate(box: Box, dx: number, dy: number, dz: number): Box
	return {
		min = { x = box.min.x + dx, y = box.min.y + dy, z = box.min.z + dz },
		max = { x = box.max.x + dx, y = box.max.y + dy, z = box.max.z + dz },
	}
end

function SpringLaneLayout.size(box: Box): Vec3
	return { x = box.max.x - box.min.x, y = box.max.y - box.min.y, z = box.max.z - box.min.z }
end

------------------------------------------------------------------------------------------------------------------------
-- float32

-- Spacing between adjacent float32 values at |v|: the distance from |v| to the next float32 above it, which is
-- 2^(E - 23) for |v| in [2^E, 2^(E+1)), and 2^-149 (the smallest denormal) below 2^-126 and at 0.
function SpringLaneLayout.float32Ulp(v: number): number
	if not isFinite(v) then fail("float32Ulp", "finite number required, got " .. tostring(v)) end
	local a = math.abs(v)
	if a > FLOAT32_MAX then fail("float32Ulp", tostring(v) .. " is outside the float32 range") end
	if a < 2 ^ -126 then return 2 ^ -149 end
	local _, e = math.frexp(a) -- a = m * 2^e with m in [0.5, 1), so a is in [2^(e-1), 2^e)
	return math.ldexp(1, e - 1 - 23)
end

-- The float32 nearest to v (round to nearest even), as a double. Errors outside the float32 range.
function SpringLaneLayout.float32Round(v: number): number
	if not isFinite(v) then fail("float32Round", "finite number required, got " .. tostring(v)) end
	if math.abs(v) > FLOAT32_MAX then fail("float32Round", tostring(v) .. " is outside the float32 range") end
	local packed = string.pack("<f", v)
	local rounded = string.unpack("<f", packed)
	return rounded :: number
end

------------------------------------------------------------------------------------------------------------------------
-- footprints

-- Boxes of every part of ONE lane (both rigs). `moving` marks the bodies that slide along X within +-railLimit.
function SpringLaneLayout.parts(config: any, origin: Vec3?): { Part }
	local c = readConfig("parts", config)
	local o = if origin == nil then copyVec(SpringLaneLayout.CAPTURE_ORIGIN) else readVec("parts", origin, "origin")
	local out: { Part } = {}
	local rigs = {
		{ name = "coupled", dz = 0 },
		{ name = "independent", dz = RIG.independentSpacings * c.spacing },
	}
	for _, rig in rigs do
		for i = 1, #c.nodes do
			local n = c.nodes[i]
			local rx, ry, rz = o.x, o.y + n.y, o.z + rig.dz + n.z
			table.insert(out, { name = "Guide" .. i, kind = "guide", rig = rig.name, node = i,
				pos = { x = rx, y = ry, z = rz },
				size = { x = 2 * c.railLimit, y = RIG.guideThickness, z = RIG.guideThickness }, moving = false })
			table.insert(out, { name = "Anchor" .. i, kind = "anchor", rig = rig.name, node = i,
				pos = { x = rx - c.anchorOffset, y = ry, z = rz },
				size = { x = RIG.anchorSize, y = RIG.anchorSize, z = RIG.anchorSize }, moving = false })
			table.insert(out, { name = if type(n.name) == "string" then n.name else "Node" .. i, kind = "node", rig = rig.name, node = i,
				pos = { x = rx, y = ry, z = rz },
				size = { x = c.nodeSize, y = c.nodeSize, z = c.nodeSize }, moving = true })
		end
	end
	return out
end

-- Union box of measured/derived part boxes, with moving parts swept +-railLimit along X (and +-offAxis in Y and Z).
function SpringLaneLayout.footprintFromParts(parts: any, railLimit: number, opts: any?): Box
	local fn = "footprintFromParts"
	if type(parts) ~= "table" or #parts < 1 then fail(fn, "parts must be a non-empty list of {pos, size, moving}") end
	if not isFinite(railLimit) or railLimit < 0 then fail(fn, "railLimit must be a finite number >= 0, got " .. tostring(railLimit)) end
	local offAxis = 0
	if opts ~= nil then
		if type(opts) ~= "table" then fail(fn, "opts must be a table") end
		if opts.offAxis ~= nil then
			if not isFinite(opts.offAxis) or opts.offAxis < 0 then fail(fn, "opts.offAxis must be a finite number >= 0") end
			offAxis = opts.offAxis
		end
	end
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for i = 1, #parts do
		local p = parts[i]
		if type(p) ~= "table" then fail(fn, "parts[" .. i .. "] must be a table") end
		local pos, sz = readVec(fn, p.pos, "parts[" .. i .. "].pos"), readVec(fn, p.size, "parts[" .. i .. "].size")
		if sz.x <= 0 or sz.y <= 0 or sz.z <= 0 then fail(fn, "parts[" .. i .. "].size must be positive") end
		if type(p.moving) ~= "boolean" then fail(fn, "parts[" .. i .. "].moving must be true or false (a missing flag would silently drop the rail travel)") end
		local travelX = if p.moving then railLimit else 0
		local wander = if p.moving then offAxis else 0
		minX = math.min(minX, pos.x - sz.x / 2 - travelX)
		maxX = math.max(maxX, pos.x + sz.x / 2 + travelX)
		minY = math.min(minY, pos.y - sz.y / 2 - wander)
		maxY = math.max(maxY, pos.y + sz.y / 2 + wander)
		minZ = math.min(minZ, pos.z - sz.z / 2 - wander)
		maxZ = math.max(maxZ, pos.z + sz.z / 2 + wander)
	end
	return { min = { x = minX, y = minY, z = minZ }, max = { x = maxX, y = maxY, z = maxZ } }
end

-- Closed-form footprint of one lane (derivation in the header). Independent of parts() and footprintFromParts().
function SpringLaneLayout.footprint(config: any, origin: Vec3?): Box
	local c = readConfig("footprint", config)
	local o = if origin == nil then copyVec(SpringLaneLayout.CAPTURE_ORIGIN) else readVec("footprint", origin, "origin")
	local hNode = c.nodeSize / 2
	local hAnchor = RIG.anchorSize / 2
	local hGuideYZ = RIG.guideThickness / 2
	-- X: anchor tail, guide (half length railLimit) and the node at full +-railLimit travel.
	local xLow = -math.max(c.anchorOffset + hAnchor, c.railLimit + hNode, c.railLimit)
	local xHigh = math.max(-c.anchorOffset + hAnchor, c.railLimit + hNode, c.railLimit)
	-- Y and Z: guide, anchor and node of a node all sit at that node's rest y and z; the widest of them is the cube.
	local halfT = math.max(hNode, hAnchor, hGuideYZ)
	local minY = math.huge
	local maxY = -math.huge
	local minZ = math.huge
	local maxZ = -math.huge
	for i = 1, #c.nodes do
		local n = c.nodes[i]
		minY = math.min(minY, n.y)
		maxY = math.max(maxY, n.y)
		minZ = math.min(minZ, n.z)
		maxZ = math.max(maxZ, n.z)
	end
	local independentDz = RIG.independentSpacings * c.spacing -- positive, so the coupled rig is lowest in Z, independent highest
	return {
		min = { x = o.x + xLow, y = o.y + minY - halfT, z = o.z + minZ - halfT },
		max = { x = o.x + xHigh, y = o.y + maxY + halfT, z = o.z + independentDz + maxZ + halfT },
	}
end

------------------------------------------------------------------------------------------------------------------------
-- reserved zones

-- The stepper's two metronomes. A metronome falls for at most `span` steps before it is re-launched; with velocity
-- gained before position (the larger of the usual integrators) the drop after n steps is g * dt^2 * n(n+1)/2, which
-- is an upper bound of the exact 0.5 * g * (n dt)^2 too.
function SpringLaneLayout.metronomeZones(opts: any?): { Box }
	local M = SpringLaneLayout.METRONOME
	local gravity, margin = M.gravity, 0
	if opts ~= nil then
		if type(opts) ~= "table" then fail("metronomeZones", "opts must be a table") end
		if opts.gravity ~= nil then
			if not isFinite(opts.gravity) or opts.gravity < 0 then fail("metronomeZones", "opts.gravity must be a finite number >= 0") end
			gravity = opts.gravity
		end
		if opts.margin ~= nil then
			if not isFinite(opts.margin) or opts.margin < 0 then fail("metronomeZones", "opts.margin must be a finite number >= 0") end
			margin = opts.margin
		end
	end
	local half = M.size / 2
	local fall = gravity * M.dt * M.dt * M.span * (M.span + 1) / 2
	local zones: { Box } = {}
	for _, x in M.xs do
		table.insert(zones, {
			min = { x = x - half - margin, y = M.y - half - fall - margin, z = M.z - half - margin },
			max = { x = x + half + margin, y = M.y + half + margin, z = M.z + half + margin },
		})
	end
	return zones
end

------------------------------------------------------------------------------------------------------------------------
-- verification

local function boxesEqual(a: Box, b: Box): boolean
	return a.min.x == b.min.x and a.min.y == b.min.y and a.min.z == b.min.z
		and a.max.x == b.max.x and a.max.y == b.max.y and a.max.z == b.max.z
end

local function describeBox(b: Box): string
	return string.format("x[%.4f, %.4f] y[%.4f, %.4f] z[%.4f, %.4f]", b.min.x, b.max.x, b.min.y, b.max.y, b.min.z, b.max.z)
end

-- Re-derives every geometric rule from the plan's own numbers. Raises on the first violation.
local function checkGeometry(fn: string, plan: any, config: any?): any
	if type(plan) ~= "table" or plan.schema ~= SpringLaneLayout.SCHEMA then fail(fn, "not a " .. SpringLaneLayout.SCHEMA .. " plan") end
	local count, gap, spacing = plan.count, plan.gap, plan.spacing
	if type(count) ~= "number" or count % 1 ~= 0 or count < 1 then fail(fn, "plan.count must be a positive integer") end
	if not isFinite(gap) or gap <= 0 then fail(fn, "plan.gap must be a positive finite number") end
	if not isFinite(spacing) or spacing <= 0 then fail(fn, "plan.spacing must be a positive finite number") end
	local origin = readVec(fn, plan.origin, "plan.origin")
	local footprint = readBox(fn, plan.footprint, "plan.footprint")
	-- verifyBuilt sweeps every measured moving body by this much along X, so it has to be a real rail length
	local railLimit = plan.railLimit
	if not isFinite(railLimit) or railLimit < 0 then fail(fn, "plan.railLimit must be a finite number >= 0, got " .. tostring(railLimit)) end
	local depth = footprint.max.z - footprint.min.z
	if plan.depth ~= depth then fail(fn, "plan.depth " .. tostring(plan.depth) .. " is not the footprint's extent along Z, " .. tostring(depth)) end
	local lanes = plan.lanes
	if type(lanes) ~= "table" or #lanes ~= count then fail(fn, "plan.lanes must list exactly plan.count lanes") end
	if config ~= nil then
		local derived = SpringLaneLayout.footprint(config, origin)
		if not boxesEqual(derived, footprint) then
			fail(fn, "plan.footprint " .. describeBox(footprint) .. " differs from the footprint derived from the config " .. describeBox(derived))
		end
		if railLimit ~= config.railLimit then
			fail(fn, "plan.railLimit " .. tostring(railLimit) .. " differs from config.railLimit " .. tostring(config.railLimit))
		end
	end
	local boxes: { Box } = {}
	for k = 1, count do
		local lane = lanes[k]
		if type(lane) ~= "table" or lane.index ~= k then fail(fn, "lane " .. k .. " is missing or has the wrong index") end
		local lo = readVec(fn, lane.origin, "lane " .. k .. " origin")
		if not isFinite(lane.offsetZ) then fail(fn, "lane " .. k .. " needs a finite offsetZ") end
		-- the lane differs from the plan origin (the capture origin by default) in Z only
		if lo.x ~= origin.x or lo.y ~= origin.y then
			fail(fn, string.format("lane %d origin (%s, %s) differs from the plan origin (%s, %s) in X or Y; lanes may differ in Z only", k, tostring(lo.x), tostring(lo.y), tostring(origin.x), tostring(origin.y)))
		end
		if lo.z ~= origin.z + lane.offsetZ then
			fail(fn, string.format("lane %d origin z %s is not origin z %s + offsetZ %s", k, tostring(lo.z), tostring(origin.z), tostring(lane.offsetZ)))
		end
		-- the stored box must be the footprint moved by the lane's own offset (a stale box would hide a moved lane)
		local box = readBox(fn, lane.box, "lane " .. k .. " box")
		local expected = SpringLaneLayout.translate(footprint, 0, 0, lane.offsetZ)
		if not boxesEqual(expected, box) then
			fail(fn, "lane " .. k .. " box " .. describeBox(box) .. " is not the footprint at its offset " .. describeBox(expected))
		end
		boxes[k] = box
	end
	-- every pair of lanes, not only neighbours
	local pairs_, minSeparation = 0, nil :: number?
	for i = 1, count - 1 do
		for j = i + 1, count do
			local s = SpringLaneLayout.separation(boxes[i], boxes[j])
			pairs_ += 1
			if s < gap or s <= 0 then
				fail(fn, string.format("lanes %d and %d are only %s studs apart (closest axis), below the required gap %s", i, j, tostring(s), tostring(gap)))
			end
			if minSeparation == nil or s < minSeparation then minSeparation = s end
		end
	end
	-- reserved zones: strictly clear (touching counts as intersecting)
	local zones = plan.excluded
	if type(zones) ~= "table" then fail(fn, "plan.excluded must be a list of boxes") end
	local clearance = plan.zoneClearance
	if not isFinite(clearance) or clearance < 0 then fail(fn, "plan.zoneClearance must be a finite number >= 0") end
	local minZoneSeparation = nil :: number?
	for z = 1, #zones do
		local zone = readBox(fn, zones[z], "excluded zone " .. z)
		for k = 1, count do
			local s = SpringLaneLayout.separation(boxes[k], zone)
			if s <= clearance then
				fail(fn, string.format("lane %d box %s intersects or is within %s studs of excluded zone %d %s (separation %s)",
					k, describeBox(boxes[k]), tostring(clearance), z, describeBox(zone), tostring(s)))
			end
			if minZoneSeparation == nil or s < minZoneSeparation then minZoneSeparation = s end
		end
	end
	-- centred on the capture origin: offset_k = (k - (count + 1) / 2) * spacing, hence antisymmetric and summing to 0
	local offsetSum = 0
	for k = 1, count do
		local offset = lanes[k].offsetZ
		if offset ~= (k - (count + 1) / 2) * spacing then
			fail(fn, string.format("lane %d offsetZ %s is not (k - (count + 1)/2) * spacing = %s", k, tostring(offset), tostring((k - (count + 1) / 2) * spacing)))
		end
		if offset ~= -lanes[count + 1 - k].offsetZ then fail(fn, "offsets are not symmetric around the capture origin at lane " .. k) end
		offsetSum += offset
	end
	if offsetSum ~= 0 then fail(fn, "lane offsets do not sum to zero (" .. tostring(offsetSum) .. ")") end
	-- plan.bounds is the union of the lane boxes (the extent the draw-distance check reads), every face of it. Last, so a
	-- tampered lane is reported as what it is (too close, off-centre) before its stale bounds are.
	local loX, loY, loZ = boxes[1].min.x, boxes[1].min.y, boxes[1].min.z
	local hiX, hiY, hiZ = boxes[1].max.x, boxes[1].max.y, boxes[1].max.z
	for k = 2, count do
		local bk = boxes[k]
		loX = math.min(loX, bk.min.x)
		loY = math.min(loY, bk.min.y)
		loZ = math.min(loZ, bk.min.z)
		hiX = math.max(hiX, bk.max.x)
		hiY = math.max(hiY, bk.max.y)
		hiZ = math.max(hiZ, bk.max.z)
	end
	local union: Box = { min = { x = loX, y = loY, z = loZ }, max = { x = hiX, y = hiY, z = hiZ } }
	local bounds = readBox(fn, plan.bounds, "plan.bounds")
	if not boxesEqual(bounds, union) then
		fail(fn, "plan.bounds " .. describeBox(bounds) .. " is not the union of the lane boxes " .. describeBox(union))
	end
	return {
		count = count, pairs = pairs_, requiredGap = gap, minLaneSeparation = minSeparation,
		zones = #zones, zoneClearance = clearance, minZoneSeparation = minZoneSeparation,
		symmetric = true, sameXY = true,
	}
end

-- Public: raises unless every rule holds. With a config the footprint is re-derived too.
function SpringLaneLayout.verify(plan: any, config: any?): any
	if config ~= nil then readConfig("verify", config) end
	return deepFreeze(checkGeometry("verify", plan, config))
end

-- Checks what Studio actually built. built[k] = measured part boxes of lane k, as footprintFromParts takes them.
-- The rule is containment: each lane's measured footprint must lie inside its planned box. The plan itself is verified
-- first, so containment already implies that measured lanes are >= gap apart and clear of every reserved zone (a box
-- inside a box cannot be closer to anything outside it than the outer box is). The measured separations are reported
-- anyway, because they are what Studio shows next to the planned numbers.
function SpringLaneLayout.verifyBuilt(plan: any, built: any, opts: any?): any
	local fn = "verifyBuilt"
	checkGeometry(fn, plan, nil)
	if type(built) ~= "table" or #built ~= plan.count then fail(fn, "built must list the measured parts of exactly " .. tostring(plan.count) .. " lanes") end
	local measured: { Box } = {}
	local maxLooseness = 0
	local lanes = {}
	for k = 1, plan.count do
		local m = SpringLaneLayout.footprintFromParts(built[k], plan.railLimit, opts)
		local planned = plan.lanes[k].box
		if not SpringLaneLayout.contains(planned, m) then
			fail(fn, "lane " .. k .. " measured footprint " .. describeBox(m) .. " leaves its planned box " .. describeBox(planned))
		end
		-- how much of the planned box the built lane leaves unused (0 = the plan is exactly tight)
		local looseness = math.max(m.min.x - planned.min.x, m.min.y - planned.min.y, m.min.z - planned.min.z,
			planned.max.x - m.max.x, planned.max.y - m.max.y, planned.max.z - m.max.z)
		maxLooseness = math.max(maxLooseness, looseness)
		measured[k] = m
		table.insert(lanes, { index = k, box = m, looseness = looseness })
	end
	local minSeparation = nil :: number?
	for i = 1, plan.count - 1 do
		for j = i + 1, plan.count do
			local s = SpringLaneLayout.separation(measured[i], measured[j])
			if minSeparation == nil or s < minSeparation then minSeparation = s end
		end
	end
	local minZoneSeparation = nil :: number?
	for z = 1, #plan.excluded do
		for k = 1, plan.count do
			local s = SpringLaneLayout.separation(measured[k], plan.excluded[z])
			if minZoneSeparation == nil or s < minZoneSeparation then minZoneSeparation = s end
		end
	end
	return deepFreeze({ lanes = lanes, minLaneSeparation = minSeparation, minZoneSeparation = minZoneSeparation, maxLooseness = maxLooseness })
end

------------------------------------------------------------------------------------------------------------------------
-- plan

function SpringLaneLayout.plan(config: any, opts: any): any
	local fn = "plan"
	local c = readConfig(fn, config)
	if type(opts) ~= "table" then fail(fn, "options table required, e.g. {count = 8}") end
	local count = opts.count
	if type(count) ~= "number" or count ~= count or count % 1 ~= 0 or count < 1 or count > SpringLaneLayout.MAX_LANES then
		fail(fn, string.format("count must be an integer from 1 to %d, got %s", SpringLaneLayout.MAX_LANES, tostring(count)))
	end
	local gap = if opts.gap == nil then SpringLaneLayout.DEFAULT_GAP else opts.gap
	if not isFinite(gap) or gap <= 0 then fail(fn, "gap must be a positive finite number, got " .. tostring(gap)) end
	local quantum = if opts.quantum == nil then SpringLaneLayout.SPACING_QUANTUM else opts.quantum
	if not isFinite(quantum) or quantum <= 0 then fail(fn, "quantum must be a positive finite number, got " .. tostring(quantum)) end
	local clearance = if opts.zoneClearance == nil then 0 else opts.zoneClearance
	if not isFinite(clearance) or clearance < 0 then fail(fn, "zoneClearance must be a finite number >= 0, got " .. tostring(clearance)) end
	local origin = if opts.origin == nil then copyVec(SpringLaneLayout.CAPTURE_ORIGIN) else readVec(fn, opts.origin, "origin")
	local zones: { Box } = {}
	if opts.excluded == nil then
		zones = SpringLaneLayout.metronomeZones()
	else
		if type(opts.excluded) ~= "table" then fail(fn, "excluded must be a list of boxes") end
		for z = 1, #opts.excluded do table.insert(zones, readBox(fn, opts.excluded[z], "excluded[" .. z .. "]")) end
	end

	local footprint = SpringLaneLayout.footprint(c, origin)
	local depth = footprint.max.z - footprint.min.z
	local spacing: number
	if opts.spacing ~= nil then
		spacing = opts.spacing
		if not isFinite(spacing) or spacing <= 0 then fail(fn, "spacing must be a positive finite number, got " .. tostring(spacing)) end
	else
		spacing = math.ceil((depth + gap) / quantum) * quantum
		while spacing - depth < gap do spacing += quantum end -- guard against a rounding shortfall
	end

	local lanes = {}
	for k = 1, count do
		local offset = (k - (count + 1) / 2) * spacing
		table.insert(lanes, {
			index = k,
			origin = { x = origin.x, y = origin.y, z = origin.z + offset },
			offsetZ = offset,
			box = SpringLaneLayout.translate(footprint, 0, 0, offset),
		})
	end
	local plan: any = {
		schema = SpringLaneLayout.SCHEMA, count = count, gap = gap, spacing = spacing, depth = depth, quantum = quantum,
		origin = origin, railLimit = c.railLimit, footprint = footprint, excluded = zones, zoneClearance = clearance,
		lanes = lanes,
	}

	-- float32: every coordinate Roblox will hold for every lane (part centres incl. full rail travel, lane origins, box corners).
	-- This runs first so an origin that is too large or not exactly representable is reported as that, not as lanes that
	-- "touch" because the offset was absorbed by rounding.
	local maxAbs = 0
	local worstUlp = 0
	local byAxis: { [string]: number } = { x = 0, y = 0, z = 0 }
	local worst: any = nil
	local maxRoundTrip = 0
	local function visit(lane: number, part: string, axis: string, value: number, exact: boolean)
		local a = math.abs(value)
		if a > FLOAT32_MAX then fail(fn, string.format("lane %d %s %s = %s is outside the float32 range", lane, part, axis, tostring(value))) end
		maxAbs = math.max(maxAbs, a)
		local ulp = SpringLaneLayout.float32Ulp(value)
		byAxis[axis] = math.max(byAxis[axis], ulp)
		if ulp > worstUlp then
			worstUlp = ulp
			worst = { lane = lane, part = part, axis = axis, value = value, ulp = ulp }
		end
		if exact then
			local err = math.abs(SpringLaneLayout.float32Round(value) - value)
			maxRoundTrip = math.max(maxRoundTrip, err)
			if err > 0 then
				fail(fn, string.format("lane %d %s %s = %s is not exactly representable in float32 (nearest %s); the layout promises Roblox holds exactly the planned coordinates",
					lane, part, axis, tostring(value), tostring(SpringLaneLayout.float32Round(value))))
			end
		end
	end
	for k = 1, count do
		local lane = lanes[k]
		visit(k, "origin", "x", lane.origin.x, true)
		visit(k, "origin", "y", lane.origin.y, true)
		visit(k, "origin", "z", lane.origin.z, true)
		visit(k, "box.min", "x", lane.box.min.x, false)
		visit(k, "box.min", "y", lane.box.min.y, false)
		visit(k, "box.min", "z", lane.box.min.z, false)
		visit(k, "box.max", "x", lane.box.max.x, false)
		visit(k, "box.max", "y", lane.box.max.y, false)
		visit(k, "box.max", "z", lane.box.max.z, false)
		for _, p in SpringLaneLayout.parts(c, lane.origin) do
			local label = (p.rig :: string) .. "." .. (p.name :: string)
			visit(k, label, "x", p.pos.x, true)
			visit(k, label, "y", p.pos.y, true)
			visit(k, label, "z", p.pos.z, true)
			if p.moving then
				visit(k, label .. "@+rail", "x", p.pos.x + c.railLimit, true)
				visit(k, label .. "@-rail", "x", p.pos.x - c.railLimit, true)
			end
		end
	end
	local bounds: Box = {
		min = { x = lanes[1].box.min.x, y = lanes[1].box.min.y, z = lanes[1].box.min.z },
		max = { x = lanes[count].box.max.x, y = lanes[count].box.max.y, z = lanes[count].box.max.z },
	}
	plan.bounds = bounds
	local checks = checkGeometry(fn, plan, c)
	plan.maxAbsCoordinate = maxAbs
	plan.worstFloat32Ulp = worstUlp
	plan.worstFloat32UlpByAxis = byAxis
	plan.worstCoordinate = worst
	checks.exactFloat32 = true
	checks.maxFloat32RoundTrip = maxRoundTrip
	plan.checks = checks
	return deepFreeze(plan)
end

return SpringLaneLayout
