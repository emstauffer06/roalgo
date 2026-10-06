-- Optional presentation sidecar, installed separately from the sealed live implementation. Only UI instances are
-- created. Native positions are READ at 10 Hz; existing translated display attachments supply label positions.
local Readouts = {}
Readouts.__index = Readouts
Readouts.SCHEMA = "roalgo-spring-lane-readouts-1"
Readouts.ROOT_NAME = "RoAlgoSpringLaneReadouts"

local function check(ok, why) assert(ok, "SpringLaneReadouts: " .. why) end
local function finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
local function formatX(value)
	if not finite(value) then return "x ---" end
	local rounded = math.round(value * 1000) / 1000
	if rounded == 0 then rounded = 0 end -- suppress negative zero
	return string.format("x %+.3f", rounded)
end

function Readouts:describe()
	return { schema = Readouts.SCHEMA, rootName = Readouts.ROOT_NAME, labels = #self.entries,
		quantity = "native X displacement from rest", units = "studs", restX = self.restX, interval = self.interval,
		textUpdates = self.textUpdates, samples = self.samples, destroyed = self.destroyed,
		reusesDisplayAttachments = true, writesNativeProperties = false }
end

function Readouts:destroy()
	if self.destroyed then return false end
	self.destroyed = true
	for _, connection in self.connections do connection:Disconnect() end
	table.clear(self.connections)
	if self.root then self.root:Destroy() end
	return true
end

function Readouts.mount(displayRoot, opts)
	opts = opts or {}
	check(displayRoot and displayRoot.Name == "RoAlgoSpringLaneDisplay" and displayRoot:GetAttribute("TranslationOnly") == true,
		"the translated live display root is required")
	check(displayRoot:FindFirstChild(Readouts.ROOT_NAME) == nil, "readouts already mounted")
	local restX = if opts.restX == nil then 0 else opts.restX
	local interval = if opts.interval == nil then 0.1 else opts.interval
	check(finite(restX), "restX must be finite")
	check(finite(interval) and interval > 0, "interval must be positive and finite")
	local entries, seen = {}, {}
	for _, marker in displayRoot:GetDescendants() do
		if marker:IsA("SphereHandleAdornment") then
			local part = marker.Adornee
			check(part and part:IsA("BasePart") and not seen[part], "each marker must identify one unique native body")
			local attachment = part:FindFirstChild("SpringDisplay_Center")
			check(attachment and attachment:IsA("Attachment") and attachment:GetAttribute("VisualOnly") == true
				and attachment:GetAttribute("TranslationOnly") == true and attachment.CFrame.Position == marker.CFrame.Position,
				"the existing translated center attachment must match the marker: " .. part:GetFullName())
			seen[part] = true
			table.insert(entries, { part = part, attachment = attachment, marker = marker })
		end
	end
	check(#entries > 0, "no displayed native nodes found")
	local self = setmetatable({ entries = entries, restX = restX, interval = interval, connections = {},
		textUpdates = 0, samples = 0, destroyed = false }, Readouts)
	local function sample()
		if self.destroyed then return end
		if displayRoot.Parent == nil or self.root.Parent ~= displayRoot then self:destroy(); return end
		self.samples += 1
		for _, entry in entries do
			if entry.part.Parent == nil or entry.attachment.Parent ~= entry.part then self:destroy(); return end
			local text = formatX(entry.part.Position.X - restX)
			if text ~= entry.lastText then
				entry.label.Text, entry.lastText = text, text
				self.textUpdates += 1
			end
		end
	end
	local ok, err = pcall(function()
		self.root = Instance.new("Folder")
		self.root.Name = Readouts.ROOT_NAME
		self.root:SetAttribute("Schema", Readouts.SCHEMA)
		self.root:SetAttribute("VisualOnly", true)
		self.root:SetAttribute("SourcePaths", displayRoot:GetFullName())
		self.root:SetAttribute("Quantity", "native X displacement from rest")
		self.root:SetAttribute("Units", "studs")
		self.root:SetAttribute("RestX", restX)
		self.root:SetAttribute("UpdateInterval", interval)
		self.root.Parent = displayRoot
		for i, entry in entries do
			local gui = Instance.new("BillboardGui")
			gui.Name, gui.Parent = string.format("NodeReadout_%03d", i), self.root
			gui.Adornee = entry.attachment
			gui.Size = UDim2.fromOffset(76, 16)
			gui.StudsOffsetWorldSpace = Vector3.new(0, entry.marker.Radius + 24, 0)
			gui.AlwaysOnTop, gui.MaxDistance, gui.LightInfluence = false, 0, 0
			gui:SetAttribute("VisualOnly", true)
			gui:SetAttribute("Units", "studs")
			gui:SetAttribute("SourcePaths", entry.part:GetFullName())
			local label = Instance.new("TextLabel")
			label.Name, label.Parent = "Displacement", gui
			label.Size = UDim2.fromScale(1, 1)
			label.BackgroundColor3 = Color3.fromRGB(12, 15, 20)
			label.BackgroundTransparency, label.BorderSizePixel = 0.5, 0
			label.TextColor3 = Color3.fromRGB(240, 240, 240)
			label.Font, label.TextSize = Enum.Font.RobotoMono, 11
			label.TextScaled, label.TextWrapped, label.RichText = false, false, false
			entry.label = label
		end
		sample()
		table.insert(self.connections, displayRoot.Destroying:Connect(function() self:destroy() end))
		table.insert(self.connections, self.root.Destroying:Connect(function() self:destroy() end))
		local elapsed = 0
		table.insert(self.connections, game:GetService("RunService").Heartbeat:Connect(function(dt)
			elapsed += dt
			if elapsed >= interval then elapsed %= interval; sample() end
		end))
	end)
	if not ok then self:destroy(); error("SpringLaneReadouts.mount: " .. tostring(err), 0) end
	return self
end

return Readouts
