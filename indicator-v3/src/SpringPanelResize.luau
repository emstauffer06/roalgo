-- Presentation-only panel sizing. No playback clock, data changes, or camera writes.
local Resize = {}
local Handle = {}
Handle.__index = Handle
local CONTROL = "RoAlgoSpringLayoutControl"
local PREFERENCES = "SpringPanelSizePreferences"
local OWNER = "spring-panel-resize-v1"
local KEYS = { panelWidth = "PanelWidth", panelHeight = "PanelHeight", chartWidth = "ChartWidth", chartHeight = "ChartHeight",
	panelX = "PanelX", panelY = "PanelY", chartX = "ChartX", chartY = "ChartY" }
local MOVE_BAR = 24

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

function Handle:_write(object, key, value)
	local properties = self.saved[object]
	if not properties then properties = {}; self.saved[object] = properties end
	if not properties[key] then properties[key] = { value = object[key] } end
	object[key] = value
end

function Handle:_apply()
	if self.destroyed then return end
	local camera = self.world.CurrentCamera
	local viewport = camera and camera.ViewportSize
	if not viewport or not finite(viewport.X) or not finite(viewport.Y) or viewport.X <= 0 or viewport.Y <= 0 then return end
	local vw, vh, E, p = viewport.X, viewport.Y, self.env, self.preferences
	local margin = math.min(12, vw / 8, vh / 8)
	local bar = math.min(MOVE_BAR, vh / 4)
	local maxHeight = math.max(1, vh - bar)
	-- Each panel gets its own viewport bounds. Overlap is intentional and allowed.
	-- On small windows, viewport limits take priority over nominal minimum sizes.
	local panelMax = math.min(720, vw)
	local pw = math.clamp(p.panelWidth or self.defaultPanelWidth, math.min(300, panelMax), panelMax)
	local ph = math.clamp(p.panelHeight or maxHeight, math.min(300, maxHeight), maxHeight)
	local defaultCW = math.max(1, vw - self.defaultPanelWidth - 2 * margin)
	local cw = math.clamp(p.chartWidth or defaultCW, math.min(400, vw), vw)
	local ch = math.clamp(p.chartHeight or self.defaultChartHeight, math.min(200, maxHeight), maxHeight)
	local px = math.clamp(p.panelX or (vw - pw), 0, vw - pw)
	local py = math.clamp(p.panelY or bar, bar, math.max(bar, vh - ph))
	local cx = math.clamp(p.chartX or margin, 0, vw - cw)
	local cy = math.clamp(p.chartY or (vh - margin - ch), bar, math.max(bar, vh - ch))
	local scale = pw / 440
	self.scale.Scale = scale
	self:_write(self.dock, "AnchorPoint", E.Vector2.new(0, 0))
	self:_write(self.dock, "Position", E.UDim2.fromOffset(px, py))
	self:_write(self.dock, "Size", E.UDim2.fromOffset(pw, ph))
	-- UIScale scales the ScrollingFrame itself as well as its descendants. Give it
	-- one logical width and an inverse-scaled height; do not also scale the Dock.
	self:_write(self.content, "Position", E.UDim2.fromOffset(0, 0))
	self:_write(self.content, "Size", E.UDim2.fromOffset(440, ph / scale))
	self:_write(self.chart, "AnchorPoint", E.Vector2.new(0, 0))
	self:_write(self.chart, "Position", E.UDim2.fromOffset(cx, cy))
	self:_write(self.chart, "Size", E.UDim2.fromOffset(cw, ch))
	for _, grip in self.moveBars do grip.Size = E.UDim2.new(1, -84, 0, bar) end
	for _, reset in self.resetButtons do reset.Position = E.UDim2.new(1, 0, 0, -bar); reset.Size = E.UDim2.fromOffset(84, bar) end
	-- Speed is hidden by the presentation adapter. Reclaim its former 364px header
	-- reservation while keeping the price/P&L readout between title and window buttons.
	if self.readout then
		self:_write(self.readout, "Position", E.UDim2.new(1, -150, 0, 4))
		self:_write(self.readout, "Size", E.UDim2.fromOffset(math.max(0, cw - 360), 18))
		self:_write(self.readout, "TextTruncate", E.Enum.TextTruncate.AtEnd)
	end
	self.dimensions = { panelWidth = pw, panelHeight = ph, chartWidth = cw, chartHeight = ch,
		panelX = px, panelY = py, chartX = cx, chartY = cy, moveBarHeight = bar,
		viewportWidth = vw, viewportHeight = vh, panelScale = scale, chartAutoWidth = p.chartWidth == nil,
		panelAutoHeight = p.panelHeight == nil, panelDocked = p.panelX == nil and p.panelY == nil,
		chartDocked = p.chartX == nil and p.chartY == nil, gap = margin }
end

function Handle:set(values)
	assert(not self.destroyed, "SpringPanelResize: destroyed")
	assert(type(values) == "table", "SpringPanelResize: size table required")
	for key, value in values do
		assert(KEYS[key] and finite(value), "SpringPanelResize: expected finite panel/chart Width, Height, X or Y")
	end
	local changed = table.clone(values)
	-- The first move/resize leaves docking without a position or size jump. Freeze
	-- only this panel; its neighbor remains completely independent.
	for _, prefix in { "panel", "chart" } do
		if values[prefix .. "X"] ~= nil or values[prefix .. "Y"] ~= nil
			or values[prefix .. "Width"] ~= nil or values[prefix .. "Height"] ~= nil then
			for _, suffix in { "X", "Y", "Width", "Height" } do
				local key = prefix .. suffix
				if changed[key] == nil and self.preferences[key] == nil then changed[key] = self.dimensions[key] end
			end
		end
	end
	for key, value in changed do self.preferences[key] = value end
	self:_apply()
	for key in changed do
		-- Persist the accepted size, not an arbitrarily large drag request. Viewport
		-- changes only clamp the display, preserving the user's larger-window preference.
		self.preferences[key] = self.dimensions[key]
		self.storage:SetAttribute(KEYS[key], self.preferences[key])
	end
	return self:stats()
end

function Handle:reset()
	assert(not self.destroyed, "SpringPanelResize: destroyed")
	self.drag = nil
	table.clear(self.preferences)
	for _, key in KEYS do self.storage:SetAttribute(key, nil) end
	self:_apply()
	return self:stats()
end

function Handle:stats()
	local out = table.clone(self.dimensions or {})
	out.destroyed, out.dragging, out.cameraWrites = self.destroyed, self.drag ~= nil, 0
	out.preferences = table.clone(self.preferences)
	return out
end

function Handle:destroy()
	if self.destroyed then return end
	self.destroyed, self.drag = true, nil
	for _, connection in self.connections do connection:Disconnect() end
	if self.cameraConnection then self.cameraConnection:Disconnect() end
	for _, object in self.owned do object:Destroy() end
	for object, properties in self.saved do
		for key, entry in properties do pcall(function() object[key] = entry.value end) end
	end
	table.clear(self.connections)
	table.clear(self.saved)
	-- The owned preference folder intentionally survives the UI lifecycle.
end

function Resize.mount(core, options)
	options = options or {}
	assert(core and options.storage, "SpringPanelResize: CoreGui and options.storage required")
	assert(not core:FindFirstChild(CONTROL), "SpringPanelResize: layout controller already mounted")
	local E = options.env or { Instance = Instance, UDim2 = UDim2, UDim = UDim, Vector2 = Vector2, Color3 = Color3, Enum = Enum }
	local world = options.workspace or workspace
	local inputService = options.inputService or game:GetService("UserInputService")
	local panelGui, chartGui = core:FindFirstChild("RoAlgoSpringPanel"), core:FindFirstChild("RoAlgoSpringChart")
	local dock = panelGui and panelGui:FindFirstChild("Dock")
	local chart = chartGui and chartGui:FindFirstChild("Chart")
	local content = dock and dock:FindFirstChild("Content")
	assert(dock and chart and content, "SpringPanelResize: retained panels required")
	for _, child in content:GetChildren() do assert(not child:IsA("UIScale"), "SpringPanelResize: content already has a scale") end
	local camera = world.CurrentCamera
	assert(camera and camera.ViewportSize.X > 0 and camera.ViewportSize.Y > 0, "SpringPanelResize: ready viewport required")
	local storage = options.storage:FindFirstChild(PREFERENCES)
	if storage then
		assert(storage:IsA("Folder") and storage:GetAttribute("Owner") == OWNER, "SpringPanelResize: preference folder ownership mismatch")
	else
		storage = E.Instance.new("Folder")
		storage.Name = PREFERENCES
		storage:SetAttribute("Owner", OWNER)
		storage.Parent = options.storage
	end
	local self = setmetatable({ env = E, world = world, inputService = inputService, dock = dock, chart = chart,
		content = content, readout = chart:FindFirstChild("Readout"), storage = storage, saved = {}, owned = {}, connections = {},
		moveBars = {}, resetButtons = {},
		preferences = {}, destroyed = false, defaultPanelWidth = dock.Size.X.Offset,
		defaultChartHeight = chart.Size.Y.Scale * camera.ViewportSize.Y + chart.Size.Y.Offset }, Handle)
	for key, attribute in KEYS do
		local value = storage:GetAttribute(attribute)
		if finite(value) then self.preferences[key] = value end
	end
	local function make(class, parent, properties)
		local object = E.Instance.new(class)
		table.insert(self.owned, object)
		for key, value in properties do object[key] = value end
		object.Parent = parent
		return object
	end
	local function connect(signal, fn)
		table.insert(self.connections, signal:Connect(function(...)
			if not self.destroyed then fn(...) end
		end))
	end
	local ok, failure = pcall(function()
		self.scale = make("UIScale", content, { Name = "SpringPanelContentScale", Scale = 1 })
		self:_write(content, "VerticalScrollBarPosition", E.Enum.VerticalScrollBarPosition.Left)
		self:_write(dock, "ClipsDescendants", false)
		self:_write(chart, "ClipsDescendants", false)
		local oldHide = chart:FindFirstChild("Hide")
		if oldHide then self:_write(oldHide, "Visible", false) end -- Avoid the old cached _fullSize toggle.
		local foreground, background = E.Color3.fromRGB(223, 235, 245), E.Color3.fromRGB(37, 58, 73)
		local function button(parent, name, caption, position, size, anchor)
			return make("TextButton", parent, { Name = name, Text = caption, Position = position, Size = size,
				AnchorPoint = anchor or E.Vector2.new(0, 0), BackgroundColor3 = background, BackgroundTransparency = 0.1,
				TextColor3 = foreground, TextSize = 10, Font = E.Enum.Font.GothamMedium, BorderSizePixel = 0,
				Active = true, AutoButtonColor = true, ZIndex = 30 })
		end
		local function begin(kind, input)
			local inputType = input.UserInputType
			if inputType ~= E.Enum.UserInputType.MouseButton1 and inputType ~= E.Enum.UserInputType.Touch then return end
			self:_apply()
			self.drag = { kind = kind, x = input.Position.X, y = input.Position.Y, sizes = table.clone(self.dimensions),
				touch = if inputType == E.Enum.UserInputType.Touch then input else nil }
		end
		local frontOrder = math.max(panelGui.DisplayOrder, chartGui.DisplayOrder) + 1
		local function front(panel)
			self:_write(panelGui, "DisplayOrder", if panel then frontOrder else frontOrder - 1)
			self:_write(chartGui, "DisplayOrder", if panel then frontOrder - 1 else frontOrder)
		end
		local function grip(parent, name, text, position, size, anchor, kind)
			local object = button(parent, name, text, position, size, anchor)
			connect(object.InputBegan, function(input)
				if input.UserInputType == E.Enum.UserInputType.MouseButton1 or input.UserInputType == E.Enum.UserInputType.Touch then
					front(parent == dock); begin(kind, input)
				end
			end)
			return object
		end
		for _, entry in { { dock, "Panel", "panel", "Move telemetry" }, { chart, "Chart", "chart", "Move chart" } } do
			local parent, name, prefix = entry[1], entry[2], entry[3]
			table.insert(self.moveBars, grip(parent, "Move" .. name, "⠿  " .. entry[4], E.UDim2.fromOffset(0, 0),
				E.UDim2.new(1, -84, 0, MOVE_BAR), E.Vector2.new(0, 1), prefix .. "Move"))
			grip(parent, "Resize" .. name .. "RightEdge", "↔", E.UDim2.new(1, 0, 0, 24),
				E.UDim2.new(0, 8, 1, -46), E.Vector2.new(1, 0), prefix .. "Width")
			grip(parent, "Resize" .. name .. "BottomEdge", "↕", E.UDim2.new(0, 0, 1, 0),
				E.UDim2.new(1, -22, 0, 8), E.Vector2.new(0, 1), prefix .. "Height")
			grip(parent, "Resize" .. name .. "BottomRight", "↘", E.UDim2.new(1, 0, 1, 0),
				E.UDim2.fromOffset(22, 22), E.Vector2.new(1, 1), prefix .. "Corner")
			local reset = button(parent, "Reset" .. name .. "Size", "Reset layout", E.UDim2.new(1, 0, 0, -MOVE_BAR),
				E.UDim2.fromOffset(84, MOVE_BAR), E.Vector2.new(1, 0))
			table.insert(self.resetButtons, reset)
			connect(reset.MouseButton1Click, function() front(parent == dock); self:reset() end)
			connect(parent.InputBegan, function(input)
				if input.UserInputType == E.Enum.UserInputType.MouseButton1 or input.UserInputType == E.Enum.UserInputType.Touch then front(parent == dock) end
			end)
		end
		connect(inputService.InputChanged, function(input)
			local drag = self.drag
			if not drag then return end
			if drag.touch then if input ~= drag.touch then return end
			elseif input.UserInputType ~= E.Enum.UserInputType.MouseMovement then return end
			local dx, dy, sizes = input.Position.X - drag.x, input.Position.Y - drag.y, drag.sizes
			local prefix = if string.sub(drag.kind, 1, 5) == "panel" then "panel" else "chart"
			local action = string.sub(drag.kind, #prefix + 1)
			local values = { [prefix .. "X"] = sizes[prefix .. "X"], [prefix .. "Y"] = sizes[prefix .. "Y"] }
			if action == "Move" then
				values[prefix .. "X"] += dx; values[prefix .. "Y"] += dy
			else
				if action == "Width" or action == "Corner" then
					values[prefix .. "Width"] = math.min(sizes[prefix .. "Width"] + dx, sizes.viewportWidth - sizes[prefix .. "X"])
				end
				if action == "Height" or action == "Corner" then
					values[prefix .. "Height"] = math.min(sizes[prefix .. "Height"] + dy, sizes.viewportHeight - sizes[prefix .. "Y"])
				end
			end
			self:set(values)
		end)
		connect(inputService.InputEnded, function(input)
			local drag = self.drag
			if drag and ((drag.touch and input == drag.touch) or (not drag.touch and input.UserInputType == E.Enum.UserInputType.MouseButton1)) then self.drag = nil end
		end)
		local function bindCamera()
			if self.cameraConnection then self.cameraConnection:Disconnect(); self.cameraConnection = nil end
			self.drag = nil
			local current = world.CurrentCamera
			if current then self.cameraConnection = current:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				if not self.destroyed then self.drag = nil; self:_apply() end
			end) end
			self:_apply()
		end
		connect(world:GetPropertyChangedSignal("CurrentCamera"), bindCamera)
		if options.lifecycle then connect(options.lifecycle.Destroying, function() self:destroy() end) end
		connect(panelGui.Destroying, function() self:destroy() end)
		connect(chartGui.Destroying, function() self:destroy() end)
		self.control = make("BindableFunction", core, { Name = CONTROL })
		self.control.OnInvoke = function(command, value)
			if command == "status" then return self:stats()
			elseif command == "set" then return self:set(value)
			elseif command == "reset" then return self:reset() end
			error("SpringPanelResize: unsupported command " .. tostring(command))
		end
		connect(self.control.Destroying, function() self:destroy() end)
		bindCamera()
	end)
	if not ok then self:destroy(); error(failure, 2) end
	return self
end

return Resize
