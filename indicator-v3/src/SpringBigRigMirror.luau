-- Big-rig replay mirror (owner request, 2026-10-05: "can you at least play a replay on the bigger springs again along with a
-- visual of them trading"). Moves the 48 bodies of the restored v2 rig Workspace.RoAlgoResearchPhysics to the RECORDED
-- 2024 x of each replay row (Coupled rig <- coupled states, Independent rig <- independent states) and recolours its
-- springs by stretch. Kinematic display only: no physics is stepped, no force or constraint is changed, and the rig's
-- captions say it is a replay. attach() saves every touched property and restore() puts them back exactly.
-- Edit mode only. Overrides the handover's "do not move live native bodies" for replay, at the owner's request.
local Mirror = {}
Mirror.__index = Mirror

local BANKS = { "Fast", "Medium", "Slow" }
local AMBER, YELLOW = Color3.fromRGB(251, 139, 30), Color3.fromRGB(255, 214, 0)
local BLUE, CYAN = Color3.fromRGB(32, 104, 255), Color3.fromRGB(0, 220, 255)
local AXIAL_FULL, COUPLING_FULL = 48, 6 -- studs of stretch for full colour (as the playtest stretch script)

-- Crash safety (added after the 2026-10-05 Team Create disconnect left the rig mid-replay): while a mirror is attached,
-- every touched original is ALSO stored as an attribute in the place itself, so recover() can restore it from any later
-- session even if the attaching session died. restore() clears the attributes.
local ACTIVE_ATTR = "SpringMirrorActive"
local SAVED_CFRAME, SAVED_COLOR, SAVED_T, SAVED_E, SAVED_TEXT = "SpringMirrorSavedCFrame", "SpringMirrorSavedColor",
	"SpringMirrorSavedTransparency", "SpringMirrorSavedEmission", "SpringMirrorSavedText"

local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end

-- Restores a rig left mid-replay by a session that died, from the attributes stored in the place. Returns the number of
-- instances restored (0 when the rig was not left active).
function Mirror.recover(rigName)
	local rig = workspace:FindFirstChild(rigName or "RoAlgoResearchPhysics")
	if not rig or rig:GetAttribute(ACTIVE_ATTR) ~= true then return 0 end
	local n = 0
	for _, d in rig:GetDescendants() do
		local cf = d:GetAttribute(SAVED_CFRAME)
		if cf ~= nil and d:IsA("BasePart") then d.CFrame = cf; d:SetAttribute(SAVED_CFRAME, nil); n += 1 end
		local color = d:GetAttribute(SAVED_COLOR)
		if color ~= nil and d:IsA("Beam") then
			d.Color = color; d.Transparency = d:GetAttribute(SAVED_T); d.LightEmission = d:GetAttribute(SAVED_E)
			d:SetAttribute(SAVED_COLOR, nil); d:SetAttribute(SAVED_T, nil); d:SetAttribute(SAVED_E, nil); n += 1
		end
		local text = d:GetAttribute(SAVED_TEXT)
		if text ~= nil and d:IsA("TextLabel") then d.Text = text; d:SetAttribute(SAVED_TEXT, nil); n += 1 end
	end
	rig:SetAttribute(ACTIVE_ATTR, nil)
	return n
end
local function nodeName(i) return BANKS[math.floor((i - 1) / 8) + 1] .. string.format("%02d", (i - 1) % 8 + 1) end
local function ramp(base, t)
	local a = math.abs(t)
	local mid, far = if t >= 0 then AMBER else BLUE, if t >= 0 then YELLOW else CYAN
	if a <= 0.5 then return base:Lerp(mid, a * 2) end
	return mid:Lerp(far, (a - 0.5) * 2)
end

-- opts = {rigName?, D?, finalX = {coupled = {24}, independent = {24}}} where finalX is the recorded x of the row the
-- rig was restored to (the last 2024 row). Rest X per body = current X - D * finalX; all 48 must agree.
function Mirror.attach(opts)
	assert(not game:GetService("RunService"):IsRunning(), "SpringBigRigMirror: Edit mode only")
	local rig = workspace:FindFirstChild(opts.rigName or "RoAlgoResearchPhysics")
	assert(rig, "SpringBigRigMirror: big rig not found")
	-- A previous session may have died mid-replay: put its saved originals back before measuring anything.
	Mirror.recover(opts.rigName)
	local D = opts.D or 64
	local self = setmetatable({ rig = rig, D = D, bodies = { coupled = {}, independent = {} }, rest = { coupled = {}, independent = {} },
		saved = {}, beams = {}, captions = {}, restored = false }, Mirror)
	local restValues = {}
	for variant, modelName in { coupled = "Coupled", independent = "Independent" } do
		local model = assert(rig:FindFirstChild(modelName), "SpringBigRigMirror: missing " .. modelName)
		for i = 1, 24 do
			local body = model:FindFirstChild(nodeName(i), true)
			assert(body and body:IsA("BasePart") and not body.Anchored, "SpringBigRigMirror: missing body " .. modelName .. "." .. nodeName(i))
			local fx = opts.finalX[variant][i]
			assert(finite(fx), "SpringBigRigMirror: finalX missing for " .. variant .. " " .. i)
			self.bodies[variant][i] = body
			self.rest[variant][i] = body.Position.X - D * fx
			table.insert(restValues, self.rest[variant][i])
			table.insert(self.saved, { part = body, cframe = body.CFrame, linear = body.AssemblyLinearVelocity, angular = body.AssemblyAngularVelocity })
		end
	end
	table.sort(restValues)
	local spread = restValues[#restValues] - restValues[1]
	assert(spread < 0.05, string.format("SpringBigRigMirror: the rig is not at the recorded final pose (rest X spread %.4f studs)", spread))
	self.restSpread = spread
	-- Pair every visual Beam with its native SpringConstraint (shared attachments), as the playtest stretch script does.
	local springByPair = {}
	for _, s in rig:GetDescendants() do
		if s:IsA("SpringConstraint") and s.Attachment0 and s.Attachment1 then
			springByPair[s.Attachment0] = springByPair[s.Attachment0] or {}
			springByPair[s.Attachment0][s.Attachment1] = s
			springByPair[s.Attachment1] = springByPair[s.Attachment1] or {}
			springByPair[s.Attachment1][s.Attachment0] = s
		end
	end
	for _, b in rig:GetDescendants() do
		if b:IsA("Beam") and b.Attachment0 and b.Attachment1 then
			local s = springByPair[b.Attachment0] and springByPair[b.Attachment0][b.Attachment1]
			if s then
				local axial = s.Name == "NativeAxialSpring"
				-- Rest length: anchor springs at FreeLength; couplings at the transverse gap (both nodes share rest X).
				local d = b.Attachment0.WorldPosition - b.Attachment1.WorldPosition
				table.insert(self.beams, { beam = b, axial = axial, restLen = if axial then s.FreeLength else Vector3.new(0, d.Y, d.Z).Magnitude,
					color = b.Color, transparency = b.Transparency, emission = b.LightEmission,
					base = b.Color.Keypoints[1].Value, baseT = b.Transparency.Keypoints[1].Value, baseE = b.LightEmission })
			end
		end
	end
	for _, g in rig:GetDescendants() do
		if g:IsA("TextLabel") and g.Name == "TruthfulMechanicsCaption" then table.insert(self.captions, { label = g, text = g.Text }) end
	end
	-- Persist the originals in the place before the first pose (crash safety).
	for _, s in self.saved do s.part:SetAttribute(SAVED_CFRAME, s.cframe) end
	for _, it in self.beams do
		it.beam:SetAttribute(SAVED_COLOR, it.color); it.beam:SetAttribute(SAVED_T, it.transparency); it.beam:SetAttribute(SAVED_E, it.emission)
	end
	for _, cap in self.captions do cap.label:SetAttribute(SAVED_TEXT, cap.text) end
	rig:SetAttribute(ACTIVE_ATTR, true)
	return self
end

local function place(body, x)
	local p = body.Position
	if math.abs(p.X - x) > 1e-9 then body.CFrame = body.CFrame + Vector3.new(x - p.X, 0, 0) end
end

-- xCoupled / xIndependent: 24 recorded x each (normalized by D); note: text appended to the rig captions.
function Mirror:pose(xCoupled, xIndependent, note)
	assert(not self.restored, "SpringBigRigMirror: pose after restore")
	for variant, xs in { coupled = xCoupled, independent = xIndependent } do
		if type(xs) == "table" then
			for i = 1, 24 do
				if finite(xs[i]) then place(self.bodies[variant][i], self.rest[variant][i] + self.D * xs[i]) end
			end
		end
	end
	for _, it in self.beams do
		local b = it.beam
		local len = (b.Attachment0.WorldPosition - b.Attachment1.WorldPosition).Magnitude
		local t = if it.axial then math.clamp((len - it.restLen) / AXIAL_FULL, -1, 1) else math.clamp((len - it.restLen) / COUPLING_FULL, 0, 1)
		local c, a = ramp(it.base, t), math.abs(t)
		if it.axial then
			b.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, it.base:Lerp(c, 0.35)), ColorSequenceKeypoint.new(0.6, c), ColorSequenceKeypoint.new(1, c) })
			b.Transparency = NumberSequence.new(it.baseT - (it.baseT - 0.12) * a)
		else
			b.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, it.base:Lerp(c, 0.5)), ColorSequenceKeypoint.new(0.5, c), ColorSequenceKeypoint.new(1, it.base:Lerp(c, 0.5)) })
		end
		b.LightEmission = it.baseE + (1 - it.baseE) * a
	end
	for _, cap in self.captions do
		cap.label.Text = cap.text .. "  ·  REPLAY of recorded 2024 states" .. (if note then " · " .. note else "") .. " · not live physics"
	end
end

-- Puts every touched property back exactly; returns the largest remaining |dX| over the 48 bodies.
function Mirror:restore()
	if self.restored then return 0 end
	self.restored = true
	for _, s in self.saved do
		s.part.CFrame = s.cframe
		s.part.AssemblyLinearVelocity = s.linear
		s.part.AssemblyAngularVelocity = s.angular
	end
	for _, it in self.beams do
		it.beam.Color, it.beam.Transparency, it.beam.LightEmission = it.color, it.transparency, it.emission
	end
	for _, cap in self.captions do cap.label.Text = cap.text end
	-- Clear the crash-safety copies now that the originals are back.
	for _, s in self.saved do s.part:SetAttribute(SAVED_CFRAME, nil) end
	for _, it in self.beams do it.beam:SetAttribute(SAVED_COLOR, nil); it.beam:SetAttribute(SAVED_T, nil); it.beam:SetAttribute(SAVED_E, nil) end
	for _, cap in self.captions do cap.label:SetAttribute(SAVED_TEXT, nil) end
	self.rig:SetAttribute(ACTIVE_ATTR, nil)
	local worst = 0
	for _, s in self.saved do worst = math.max(worst, (s.part.Position - s.cframe.Position).Magnitude) end
	return worst
end

return Mirror
