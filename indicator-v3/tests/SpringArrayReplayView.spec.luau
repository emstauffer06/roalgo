local loaded, View = pcall(require, "../src/SpringArrayReplayView")
assert(loaded and type(View.mount) == "function", "array replay renderer must load: " .. tostring(View))
print("SpringArrayReplayView module loaded")

local Frozen = require("../src/SpringFrozenV1")
local function signal()
	local s = { entries = {} }
	function s:Connect(fn)
		local c = { Connected = true }
		function c:Disconnect() self.Connected = false end
		table.insert(self.entries, { fn = fn, connection = c })
		return c
	end
	function s:Fire(...)
		for _, entry in table.clone(self.entries) do if entry.connection.Connected then entry.fn(...) end end
	end
	return s
end
local VM = {}
VM.__index = VM
local function vector(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, VM) end
VM.__add = function(a, b) return vector(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
VM.__mul = function(a, b) return vector(a.X * b, a.Y * b, a.Z * b) end
VM.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
local methods, OM = {}, {}
OM.__index = function(self, key)
	if methods[key] then return methods[key] end
	if key == "Position" and self._props.CFrame then return self._props.CFrame.Position end
	return self._props[key]
end
OM.__newindex = function(self, key, value)
	if key == "Parent" then
		local old = self._props.Parent
		if old then for i, child in old._children do if child == self then table.remove(old._children, i); break end end end
		if value then table.insert(value._children, self) end
	end
	self._props[key] = value
end
function methods:SetAttribute(key, value) self._attrs[key] = value end
function methods:GetAttribute(key) return self._attrs[key] end
function methods:IsA(class) return self.ClassName == class or (class == "BasePart" and self.ClassName == "Part") end
function methods:FindFirstChild(name)
	for _, child in self._children do if child.Name == name then return child end end
	return nil
end
function methods:GetDescendants()
	local out = {}
	local function walk(object) for _, child in object._children do table.insert(out, child); walk(child) end end
	walk(self)
	return out
end
function methods:Destroy()
	if self._dead then return end
	rawset(self, "_dead", true)
	self.Destroying:Fire()
	for _, child in table.clone(self._children) do child:Destroy() end
	self.Parent = nil
end
local made = {}
local function instance(class)
	local object = setmetatable({ _props = { ClassName = class, Name = class, Destroying = signal() }, _children = {}, _attrs = {} }, OM)
	table.insert(made, object)
	return object
end
local beat = signal()
local E = {
	Instance = { new = instance }, Vector3 = { new = vector },
	CFrame = { new = function(x, y, z) return { Position = if type(x) == "table" then x else vector(x, y, z) } end },
	Color3 = { fromRGB = function(r, g, b) return { r, g, b } end },
	ColorSequence = { new = function(value) return { value } end }, NumberSequence = { new = function(value) return { value } end },
	UDim2 = { fromOffset = function(x, y) return { x, y } end, fromScale = function(x, y) return { x, y } end },
	Enum = { Font = { RobotoMono = "mono" }, Material = { Neon = "neon" }, PartType = { Ball = "ball" } },
	RunService = { Heartbeat = beat },
}
local world = instance("Workspace")
local protected = instance("Model")
protected.Name, protected.Parent = "RoAlgoResearchPhysics", world
local view = View.mount(world, Frozen.descriptor, Frozen.nativeConfig2024, { laneCount = 8, layerSpacing = 800, env = E })
local parts, beams = 0, 0
for _, object in view.model:GetDescendants() do
	if object:IsA("Part") then
		parts += 1
		assert(object.Anchored and not object.CanCollide and not object.CanTouch and not object.CanQuery, "all display parts must be inert")
	elseif object:IsA("Beam") then beams += 1 end
	assert(not object:IsA("SpringConstraint") and not object:IsA("PrismaticConstraint") and not object:IsA("VectorForce"), "no simulated mechanics")
end
assert(parts == 392 and beams == 680 and view:stats().nodeCount == 384, "complete eight-lane pool")
assert(view.model:GetAttribute("ViewPosition") == vector(-6500, 2500, -1000)
	and view.model:GetAttribute("FocusPosition") == vector(0, 1280, 3328) and view.model:GetAttribute("ViewFieldOfView") == 70, "known full-array camera framing")
print("PASS complete inert array and one-time camera metadata")

local sample = { phase = "recorded", lane = 1, blockId = 1, rowIndex = 12, t = 1731949200, label = "2024-11-18 09:30",
	coupled = table.create(51, 0), independent = table.create(51, 0) }
sample.coupled[1], sample.independent[1] = 0.5, -0.25
local allocated = #made
view:updateLane(sample)
assert(view.lanes[1].nodes.coupled[1].part.Position == vector(-2768, 1536, 1024), "coupled saved x times D at exact layer")
assert(view.lanes[1].nodes.independent[1].part.Position == vector(-2816, 1536, 3840), "independent pair uses same layer and 11-spacing Z offset")
assert(view.lanes[8].nodes.coupled[1].part.Position == vector(2800, 1536, 1024), "other layers remain at rest")
assert(view.lanes[1].nodes.coupled[1].label.Text == "x +32.000", "numeric readout uses studs")
assert(#made == allocated, "updates reuse instance pools")
print("PASS exact normalized-state placement, independent pairing, and pooled updates")

sample.coupled[1] = 0.75
view:updateLane(sample)
assert(view.lanes[1].nodes.coupled[1].part.Position.X == -2752, "geometry updates immediately")
beat:Fire(0.1)
assert(view.lanes[1].nodes.coupled[1].label.Text == "x +48.000", "throttled numeric label reaches newest pose")
local before = view.lanes[1].nodes.coupled[1].part.Position
sample.coupled[1], sample.independent[51] = 1, 0 / 0
assert(not pcall(view.updateLane, view, sample), "corrupt saved vector is refused")
assert(view.lanes[1].nodes.coupled[1].part.Position == before, "both variants validate before any geometry mutation")
print("PASS numeric refresh and atomic refusal of corrupt records")

view:updateLane({ phase = "warmup", lane = 1, blockId = 9, rowIndex = 123 })
assert(view.lanes[1].nodes.coupled[1].part.Position.X == -2800 and view.lanes[1].nodes.coupled[1].part.Transparency > 0.5, "missing warm-up shown at dim rest")
assert(view.lanes[1].nodes.coupled[1].label.Text == "x --" and string.find(view.lanes[1].caption.Text, "settling", 1, true), "missing states never presented as recorded numbers")
view:updateLane({ phase = "idle", lane = 1 })
assert(string.find(view.lanes[1].caption.Text, "finished", 1, true), "finished lane explicitly labeled")
print("PASS truthful warm-up and finished-lane display")

assert(view:destroy() and not view:destroy(), "idempotent cleanup")
assert(view.model.Parent == nil and protected.Parent == world and #protected:GetDescendants() == 0, "only the owned replay model is removed")
for _, connection in beat.entries do assert(not connection.connection.Connected, "readout callback disconnected") end
assert(not pcall(view.updateLane, view, sample), "updates after cleanup are refused")
print("PASS cleanup preserves unrelated models and disconnects readouts")
print("SpringArrayReplayView: 5 behavior checks passed")
