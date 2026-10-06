-- Cached presentation-only signed node colors. Reads displayed poses; never moves
-- parts or changes beams, transparency, physics, or saved state.
local Colors = {}
local Handle = {}
Handle.__index = Handle

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local COLOR_TOLERANCE = 1 / 255 + 1e-6
local function sameColor(a, b)
	return math.abs(a.R - b.R) <= COLOR_TOLERANCE and math.abs(a.G - b.G) <= COLOR_TOLERANCE
		and math.abs(a.B - b.B) <= COLOR_TOLERANCE
end

local function palette()
	local colors = {}
	-- Darker neutral and purer endpoints keep Neon nodes from washing toward white.
	local neutral, negative, positive = { 52, 58, 66 }, { 200, 12, 24 }, { 8, 178, 38 }
	for index = -255, 255 do
		local target = if index < 0 then negative else positive
		local amount = math.sqrt(math.abs(index) / 255)
		colors[index] = Color3.fromRGB(math.round(neutral[1] + (target[1] - neutral[1]) * amount),
			math.round(neutral[2] + (target[2] - neutral[2]) * amount),
			math.round(neutral[3] + (target[3] - neutral[3]) * amount))
	end
	return colors
end

local function body(part, label)
	assert(part and part:IsA("BasePart") and part.Anchored and finite(part.Position.X),
		"SpringNodeColors: anchored finite " .. label .. " required")
	return part
end

function Handle:update()
	if self.destroyed then return false end
	local started = os.clock()
	local red, green, neutral, skipped, writes = 0, 0, 0, 0, 0
	for _, group in self.groups do
		if not group.model.Parent or not group.model:IsDescendantOf(workspace) then
			skipped += #group.nodes
			continue
		end
		for _, entry in group.nodes do
			local part, rest = entry.part, entry.rest
			if not part.Parent or not rest.Parent or not part.Anchored or not rest.Anchored
				or not part:IsDescendantOf(group.model) or not rest:IsDescendantOf(group.model) then
				skipped += 1
				continue
			end
			local x, restX = part.Position.X, rest.Position.X
			if not finite(x) or not finite(restX) then skipped += 1; continue end
			local lean = (x - restX) / entry.studsPerUnit
			if not finite(lean) then skipped += 1; continue end
			local color = self.palette[math.round(math.clamp(lean, -1, 1) * 255)]
			if lean < 0 then red += 1 elseif lean > 0 then green += 1 else neutral += 1 end
			-- Retained renderers may repaint a stationary node. Compare the actual
			-- current color on every update instead of caching the last lean.
			if not sameColor(part.Color, color) then part.Color = color; writes += 1 end
			for _, marker in entry.markers do
				if marker.Parent and marker.Adornee == part and marker:IsDescendantOf(group.model) and not sameColor(marker.Color3, color) then
					marker.Color3 = color
					writes += 1
				end
			end
		end
	end
	self.updates += 1
	self.red, self.green, self.neutralCount, self.skipped = red, green, neutral, skipped
	self.colorWrites += writes
	local elapsed = os.clock() - started
	self.totalSeconds += elapsed
	self.maxSeconds = math.max(self.maxSeconds, elapsed)
	return true
end

function Handle:stats()
	return { destroyed = self.destroyed, nodeCount = self.nodeCount, modelCount = #self.groups,
		arrayNodes = self.counts.RoAlgoSpringArrayReplay, companionNodes = self.counts.RoAlgoSpringArrayCompanion,
		smallNodes = self.counts.RoAlgoSpringReplay, adornmentCount = self.adornmentCount,
		updates = self.updates, red = self.red, green = self.green, neutral = self.neutralCount,
		skipped = self.skipped, colorWrites = self.colorWrites, autoUpdate = self.autoUpdate,
		meanUpdateMs = if self.updates > 0 then 1000 * self.totalSeconds / self.updates else 0,
		maxUpdateMs = 1000 * self.maxSeconds }
end

function Handle:destroy()
	if self.destroyed then return end
	self.destroyed = true
	for _, connection in self.connections do connection:Disconnect() end
	table.clear(self.connections)
	for _, saved in self.originals do
		local object = saved.object
		if object.Parent and (saved.property ~= "Color" or object.Anchored) then
			pcall(function() object[saved.property] = saved.color end)
		end
	end
end

function Colors.mount(models, options)
	options = options or {}
	local D = options.D or 64
	assert(type(models) == "table" and finite(D) and D > 0, "SpringNodeColors: models and positive D required")
	local self = setmetatable({ groups = {}, counts = {}, originals = {}, connections = {},
		nodeCount = 0, adornmentCount = 0, updates = 0, red = 0, green = 0, neutralCount = 0, skipped = 0,
		colorWrites = 0, totalSeconds = 0, maxSeconds = 0, destroyed = false, autoUpdate = options.autoUpdate ~= false,
		palette = palette() }, Handle)
	local byBody = {}
	local function add(group, part, rest, scale)
		body(part, "node"); body(rest, "rest reference")
		assert(not byBody[part], "SpringNodeColors: duplicate node")
		local entry = { part = part, rest = rest, studsPerUnit = scale, markers = {} }
		byBody[part] = entry
		table.insert(group.nodes, entry)
		table.insert(self.originals, { object = part, property = "Color", color = part.Color })
		self.nodeCount += 1
	end
	-- Discover and validate all sources before performing any color writes.
	for _, model in models do
		assert(model and model:IsA("Model") and model.Parent, "SpringNodeColors: parented display model required")
		assert(not self.counts[model.Name], "SpringNodeColors: duplicate display model")
		local group = { model = model, nodes = {} }
		if model.Name == "RoAlgoSpringArrayReplay" then
			assert(model:GetAttribute("LaneCount") == 8, "SpringNodeColors: expected eight array lanes")
			for laneIndex = 1, 8 do
				local lane = assert(model:FindFirstChild(string.format("Lane%02d", laneIndex)), "SpringNodeColors: missing lane")
				local rest = body(lane:FindFirstChild("VisualAnchors"), "array rest reference")
				for _, variant in { "coupled", "independent" } do
					local folder = assert(lane:FindFirstChild(variant), "SpringNodeColors: missing array variant")
					for _, bank in { "Fast", "Medium", "Slow" } do
						for column = 1, 8 do add(group, folder:FindFirstChild(bank .. string.format("%02d", column)), rest, D) end
					end
				end
			end
		elseif model.Name == "RoAlgoSpringArrayCompanion" then
			for _, variant in { "Coupled", "Independent" } do
				local rig = assert(model:FindFirstChild(variant), "SpringNodeColors: missing companion variant")
				local nodes, guides = {}, {}
				for _, part in rig:GetDescendants() do
					if part:IsA("BasePart") then
						local index = part:GetAttribute("NodeIndex")
						if index ~= nil then
							assert(finite(index) and index % 1 == 0 and index >= 1 and index <= 24 and not nodes[index],
								"SpringNodeColors: invalid or duplicate companion node index")
							nodes[index] = part
						end
						local guide = tonumber(string.match(part.Name, "^Guide(%d+)$"))
						if guide then
							assert(not guides[guide], "SpringNodeColors: duplicate companion guide")
							guides[guide] = part
						end
					end
				end
				for i = 1, 24 do add(group, nodes[i], guides[i], D) end
			end
		elseif model.Name == "RoAlgoSpringReplay" then
			local scale = model:GetAttribute("DisplacementStudsPerUnit")
			assert(finite(scale) and scale > 0, "SpringNodeColors: small display displacement scale required")
			local folder = assert(model:FindFirstChild("Nodes"), "SpringNodeColors: missing small display nodes")
			for i = 1, 24 do
				add(group, folder:FindFirstChild(string.format("Node%02d", i)), folder:FindFirstChild(string.format("Rest%02d", i)), scale)
			end
		else error("SpringNodeColors: unsupported model " .. model.Name) end
		self.counts[model.Name] = #group.nodes
		table.insert(self.groups, group)
	end
	assert(#self.groups == 3 and self.nodeCount == 456, "SpringNodeColors: all three displays / 456 nodes required")
	for _, group in self.groups do
		for _, object in group.model:GetDescendants() do
			if object:IsA("SphereHandleAdornment") then
				local entry = byBody[object.Adornee]
				if entry and object.Adornee:IsDescendantOf(group.model) then
					table.insert(entry.markers, object)
					table.insert(self.originals, { object = object, property = "Color3", color = object.Color3 })
					self.adornmentCount += 1
				end
			end
		end
	end
	local ok, failure = pcall(function()
		if options.lifecycle then table.insert(self.connections, options.lifecycle.Destroying:Connect(function() self:destroy() end)) end
		if self.autoUpdate then
			table.insert(self.connections, game:GetService("RunService").Heartbeat:Connect(function() self:update() end))
		end
		self:update()
	end)
	if not ok then self:destroy(); error(failure, 2) end
	return self
end

return Colors
