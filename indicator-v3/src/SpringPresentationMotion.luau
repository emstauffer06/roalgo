-- Presentation-only easing for an existing pool of anchored display parts.
-- The host owns timing and chooses zero duration for seeks and discontinuities.
local Motion = {}
Motion.__index = Motion

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function owned(entry)
	return entry.part.Parent ~= nil and entry.part:IsDescendantOf(entry.model)
end

local function visible(self, entry)
	return owned(entry) and entry.model:IsDescendantOf(self.world)
end

local function validateAnchored(self)
	-- Validate the whole pool before any write, so a changed anchor flag cannot
	-- produce a partial update or inadvertently start driving native physics.
	for _, entry in self.parts do
		if owned(entry) then
			assert(entry.part.Anchored, "SpringPresentationMotion: every display part must remain anchored")
		end
	end
end

local function finishTargets(self)
	for _, item in self.active do
		if visible(self, item.entry) then item.entry.part.CFrame = item.target end
	end
	table.clear(self.active)
	self.elapsed, self.duration = 0, 0
end

-- workspaceOverride supports the standalone fixture; Roblox callers omit it.
function Motion.new(models, workspaceOverride)
	assert(type(models) == "table" and #models > 0, "SpringPresentationMotion: display model list required")
	local world = workspaceOverride or workspace
	assert(world and world:IsA("Workspace"), "SpringPresentationMotion: Workspace required")
	local self = setmetatable({ world = world, parts = {}, active = {}, captured = nil,
		elapsed = 0, duration = 0, movedParts = 0, captures = 0, transitions = 0,
		modelCount = 0, destroyed = false }, Motion)
	local seenModels, seenParts = {}, {}
	for _, model in models do
		assert(model and (model:IsA("Model") or model:IsA("Folder")), "SpringPresentationMotion: Model or Folder required")
		if not seenModels[model] then
			seenModels[model] = true
			self.modelCount += 1
			for _, part in model:GetDescendants() do
				if part:IsA("BasePart") and not seenParts[part] then
					seenParts[part] = true
					table.insert(self.parts, { part = part, model = model })
				end
			end
		end
	end
	validateAnchored(self)
	return self
end

function Motion:capture()
	assert(not self.destroyed, "SpringPresentationMotion: capture after destroy")
	validateAnchored(self)
	local captured = {}
	for _, entry in self.parts do
		if visible(self, entry) then table.insert(captured, { entry = entry, start = entry.part.CFrame }) end
	end
	-- Preserve the displayed starting pose above, then restore old endpoints.
	-- Renderers that cache their last target may omit writes for unchanged nodes.
	finishTargets(self)
	self.captured = captured
	self.captures += 1
	return #captured
end

function Motion:transition(seconds)
	assert(not self.destroyed, "SpringPresentationMotion: transition after destroy")
	assert(finite(seconds) and seconds >= 0, "SpringPresentationMotion: nonnegative finite duration required")
	assert(self.captured ~= nil, "SpringPresentationMotion: capture must precede transition")
	validateAnchored(self)
	local active = {}
	for _, item in self.captured do
		if visible(self, item.entry) then
			local target = item.entry.part.CFrame
			if target ~= item.start then table.insert(active, { entry = item.entry, start = item.start, target = target }) end
		end
	end
	self.captured = nil
	self.movedParts = #active
	self.transitions += 1
	self.elapsed, self.duration = 0, seconds
	self.active = if seconds > 0 then active else {}
	-- Targets remain exact when duration is zero; only a running ease rewinds.
	for _, item in self.active do item.entry.part.CFrame = item.start end
	return self.movedParts
end

function Motion:advance(dt)
	assert(not self.destroyed, "SpringPresentationMotion: advance after destroy")
	assert(finite(dt) and dt >= 0, "SpringPresentationMotion: nonnegative finite elapsed time required")
	if #self.active == 0 then return 0 end
	validateAnchored(self)
	self.elapsed = math.min(self.duration, self.elapsed + dt)
	local alpha = self.elapsed / self.duration
	local eased = alpha * alpha * (3 - 2 * alpha)
	local continuing, written = {}, 0
	for _, item in self.active do
		if visible(self, item.entry) then
			local pose = if alpha >= 1 then item.target else item.start:Lerp(item.target, eased)
			if item.entry.part.CFrame ~= pose then item.entry.part.CFrame = pose; written += 1 end
			if alpha < 1 then table.insert(continuing, item) end
		end
	end
	self.active = continuing
	return written
end

function Motion:snap()
	assert(not self.destroyed, "SpringPresentationMotion: snap after destroy")
	validateAnchored(self)
	local count = #self.active
	finishTargets(self)
	self.captured = nil
	return count
end

function Motion:stats()
	return { modelCount = self.modelCount, cachedParts = #self.parts, activeParts = #self.active,
		capturedParts = if self.captured then #self.captured else 0, movedParts = self.movedParts,
		captures = self.captures, transitions = self.transitions, elapsed = self.elapsed,
		duration = self.duration, destroyed = self.destroyed }
end

function Motion:destroy()
	if self.destroyed then return false end
	self:snap()
	self.destroyed = true
	return true
end

return Motion
