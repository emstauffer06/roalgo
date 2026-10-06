local Motion = require("../src/SpringPresentationMotion")
assert(type(Motion.new) == "function", "motion module must load")

local CF = {}
CF.__index = CF
CF.__eq = function(a, b) return a.x == b.x end
local function frame(x) return setmetatable({ x = x }, CF) end
function CF:Lerp(other, alpha) return frame(self.x + (other.x - self.x) * alpha) end

local Object = {}
Object.__index = function(self, key)
	if key == "CFrame" then return self.cf end
	return Object[key]
end
Object.__newindex = function(self, key, value)
	if key == "CFrame" then rawset(self, "cf", value); self.writes += 1 else rawset(self, key, value) end
end
function Object:IsA(class) return self.ClassName == class or (class == "BasePart" and self.ClassName == "Part") end
function Object:IsDescendantOf(root)
	local parent = self.Parent
	while parent do if parent == root then return true end; parent = parent.Parent end
	return false
end
function Object:GetDescendants()
	local out = {}
	local function visit(parent)
		for _, child in parent.children do
			if child.Parent == parent then table.insert(out, child); visit(child) end
		end
	end
	visit(self)
	return out
end
local function object(class, parent, x)
	local obj = setmetatable({ ClassName = class, children = {}, writes = 0, cf = frame(x or 0), Anchored = true }, Object)
	obj.Parent = parent
	if parent then table.insert(parent.children, obj) end
	return obj
end
local function fixture()
	local world = object("Workspace")
	local model = object("Model", world)
	local part = object("Part", model)
	local still = object("Part", model, 42)
	return world, model, part, still
end
local function near(actual, expected) assert(math.abs(actual - expected) < 1e-9, tostring(actual) .. " ~= " .. expected) end

do
	local world, model, part, still = fixture()
	local motion = Motion.new({ model }, world)
	motion:capture(); part.CFrame = frame(10); motion:transition(1)
	near(part.CFrame.x, 0)
	motion:advance(0); near(part.CFrame.x, 0)
	motion:advance(.25); near(part.CFrame.x, 1.5625)
	motion:advance(.25); near(part.CFrame.x, 5)
	motion:advance(.5); near(part.CFrame.x, 10)
	assert(still.writes == 0, "unchanged nodes must receive no smoothing writes")
	assert(motion:stats().activeParts == 0 and motion:stats().movedParts == 1)
	print("PASS smoothstep zero, quarter, midpoint, exact endpoint and unchanged parts")
end
do
	local world, model, part = fixture()
	local motion = Motion.new({ model }, world)
	motion:capture(); part.CFrame = frame(10); motion:transition(1); motion:advance(.5)
	motion:capture(); part.CFrame = frame(20); motion:transition(1)
	near(part.CFrame.x, 5)
	motion:advance(.5); near(part.CFrame.x, 12.5)
	motion:snap(); near(part.CFrame.x, 20)
	motion:capture(); part.CFrame = frame(31); motion:transition(0)
	near(part.CFrame.x, 31)
	assert(motion:stats().activeParts == 0)
	print("PASS interrupted transitions start at displayed pose; snap and zero duration finish targets")
end
do
	local world, model, part = fixture()
	local motion = Motion.new({ model }, world)
	motion:capture(); part.CFrame = frame(10); motion:transition(1); motion:advance(.5)
	motion:capture()
	near(part.CFrame.x, 10) -- An optimized renderer may skip writing an unchanged target.
	motion:transition(1); near(part.CFrame.x, 5)
	motion:advance(.5); near(part.CFrame.x, 7.5)
	motion:advance(.5); near(part.CFrame.x, 10)
	print("PASS capture restores previous endpoint before an unchanged-target renderer runs")
end
do
	local world, model, part = fixture()
	local storage = object("ServerStorage")
	local motion = Motion.new({ model }, world)
	motion:capture(); part.CFrame = frame(10); model.Parent = storage; motion:transition(1)
	near(part.CFrame.x, 10)
	model.Parent = world; motion:capture(); part.CFrame = frame(20); motion:transition(1)
	model.Parent = storage; local writes = part.writes; motion:advance(1)
	assert(part.writes == writes, "parked parts receive no interpolation writes")
	motion:capture(); part.CFrame = frame(30); model.Parent = world; motion:transition(1)
	near(part.CFrame.x, 30)
	assert(motion:stats().activeParts == 0)
	print("PASS parked before/after capture and parking during transition skip interpolation")
end
do
	local world, model, part = fixture()
	part.Anchored = false
	assert(not pcall(Motion.new, { model }, world), "unanchored source must be rejected")
	part.Anchored = true
	local motion = Motion.new({ model }, world)
	motion:capture(); part.CFrame = frame(10); part.Anchored = false
	local writes = part.writes
	assert(not pcall(motion.transition, motion, 1) and part.writes == writes)
	part.Anchored = true; motion:transition(1); part.Anchored = false
	writes = part.writes
	assert(not pcall(motion.advance, motion, .5) and part.writes == writes)
	print("PASS unanchored construction and runtime changes refuse all motion writes")
end
do
	local world, model, part = fixture()
	local motion = Motion.new({ model, model }, world)
	assert(motion:stats().cachedParts == 2, "duplicate model references must be deduplicated")
	motion:capture(); part.CFrame = frame(10); motion:transition(1); motion:advance(.25)
	part.Parent = nil; local writes = part.writes; motion:advance(.25)
	assert(part.writes == writes)
	assert(motion:destroy() and not motion:destroy())
	assert(not pcall(motion.capture, motion), "destroyed instance rejects new transitions")
	local world2, model2, part2 = fixture()
	local motion2 = Motion.new({ model2 }, world2)
	motion2:capture(); part2.CFrame = frame(20); motion2:transition(1); motion2:destroy()
	near(part2.CFrame.x, 20)
	print("PASS deduplication, removed parts, destroy finishes targets and idempotent cleanup")
end
do
	local world, model, part = fixture()
	local motion = Motion.new({ model }, world)
	motion:capture(); part.CFrame = frame(10)
	local writes = part.writes
	for _, bad in { -1, math.huge, 0 / 0 } do
		assert(not pcall(motion.transition, motion, bad) and part.writes == writes)
	end
	motion:transition(1)
	writes = part.writes
	assert(not pcall(motion.advance, motion, -1) and part.writes == writes)
	assert(not pcall(motion.advance, motion, 0 / 0) and part.writes == writes)
	print("PASS invalid durations and elapsed times leave presentation untouched")
end
