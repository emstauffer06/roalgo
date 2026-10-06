-- SpringStretchColors (LocalScript, StarterPlayer.StarterPlayerScripts)
-- the owner 2026-10-05: colour every v2 rig spring by how stretched it is, "for more showcase-y ness".
-- Pure presentation on the client: reads each native SpringConstraint's current length and recolours the
-- matching visual Beam. It never moves parts, never touches forces or constraints, and never touches the camera.
-- Installed into the configured place (PlaceId 0 by default); this file is the reviewable source copy.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local RIG_NAME = "RoAlgoResearchPhysics"
local AMBER, CORAL = Color3.fromRGB(255, 176, 48), Color3.fromRGB(255, 72, 72)
local CYAN, VIOLET = Color3.fromRGB(64, 196, 255), Color3.fromRGB(150, 100, 255)
local AXIAL_FULL = 48 -- studs of anchor stretch or compression for full colour (about 0.75 D, D = 64)
local COUPLING_FULL = 6 -- studs of extra coupling length for full colour

local rig = workspace:WaitForChild(RIG_NAME, 60)
if not rig then return end

local items, known = {}, {}

local function scan()
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
		if b:IsA("Beam") and not known[b] and b.Attachment0 and b.Attachment1 then
			local s = springByPair[b.Attachment0] and springByPair[b.Attachment0][b.Attachment1]
			if s then
				known[b] = true
				local axial = s.Name == "NativeAxialSpring"
				local d = b.Attachment0.WorldPosition - b.Attachment1.WorldPosition
				table.insert(items, {
					beam = b,
					axial = axial,
					-- anchor springs rest at FreeLength; couplings rest at the transverse gap (both nodes share rest X)
					restLen = if axial then s.FreeLength else Vector3.new(0, d.Y, d.Z).Magnitude,
					base = b.Color.Keypoints[1].Value,
					baseT = b.Transparency.Keypoints[1].Value,
					baseE = b.LightEmission,
				})
			end
		end
	end
end

local function ramp(base, t)
	local a = math.abs(t)
	local mid = if t >= 0 then AMBER else CYAN
	local far = if t >= 0 then CORAL else VIOLET
	if a <= 0.5 then return base:Lerp(mid, a * 2) end
	return mid:Lerp(far, (a - 0.5) * 2)
end

local function update()
	for _, it in items do
		local b = it.beam
		if not b.Parent or not b.Attachment0 or not b.Attachment1 then continue end
		local len = (b.Attachment0.WorldPosition - b.Attachment1.WorldPosition).Magnitude
		local t = if it.axial
			then math.clamp((len - it.restLen) / AXIAL_FULL, -1, 1)
			else math.clamp((len - it.restLen) / COUPLING_FULL, 0, 1)
		local c = ramp(it.base, t)
		local a = math.abs(t)
		if it.axial then -- Attachment0 is the anchor end: softer; node end: full colour
			b.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, it.base:Lerp(c, 0.35)),
				ColorSequenceKeypoint.new(0.6, c),
				ColorSequenceKeypoint.new(1, c),
			})
			b.Transparency = NumberSequence.new(it.baseT - (it.baseT - 0.12) * a)
		else -- coupling: hottest mid-span
			b.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, it.base:Lerp(c, 0.5)),
				ColorSequenceKeypoint.new(0.5, c),
				ColorSequenceKeypoint.new(1, it.base:Lerp(c, 0.5)),
			})
		end
		b.LightEmission = it.baseE + (1 - it.baseE) * a
	end
end

local function legend()
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	if pg:FindFirstChild("SpringStretchLegend") then return end
	local sg = Instance.new("ScreenGui")
	sg.Name = "SpringStretchLegend"
	sg.ResetOnSpawn = false
	local fr = Instance.new("Frame")
	fr.Size = UDim2.fromOffset(340, 58)
	fr.Position = UDim2.new(0, 24, 1, -74)
	fr.BackgroundColor3 = Color3.fromRGB(10, 14, 22)
	fr.BackgroundTransparency = 0.3
	fr.Parent = sg
	Instance.new("UICorner", fr).CornerRadius = UDim.new(0, 8)
	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(1, -24, 0, 10)
	bar.Position = UDim2.fromOffset(12, 10)
	bar.BorderSizePixel = 0
	bar.BackgroundColor3 = Color3.new(1, 1, 1)
	bar.Parent = fr
	Instance.new("UICorner", bar).CornerRadius = UDim.new(0, 5)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, VIOLET),
		ColorSequenceKeypoint.new(0.25, CYAN),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(200, 205, 215)),
		ColorSequenceKeypoint.new(0.75, AMBER),
		ColorSequenceKeypoint.new(1, CORAL),
	})
	g.Parent = bar
	local function caption(text, align, x, y, size, color)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1
		l.Size = UDim2.new(1, -24, 0, 16)
		l.Position = UDim2.fromOffset(12, y)
		l.Font = Enum.Font.GothamMedium
		l.TextSize = size
		l.TextColor3 = color
		l.TextTransparency = 0.1
		l.TextXAlignment = align
		l.Text = text
		l.Parent = fr
		return l
	end
	caption("compressed", Enum.TextXAlignment.Left, 0, 23, 12, Color3.fromRGB(220, 225, 235))
	caption("stretched", Enum.TextXAlignment.Right, 0, 23, 12, Color3.fromRGB(220, 225, 235))
	caption("spring colour = live stretch of each native SpringConstraint", Enum.TextXAlignment.Center, 0, 39, 11, Color3.fromRGB(170, 176, 190))
	sg.Parent = pg
end

scan()
legend()
RunService:BindToRenderStep("SpringStretchColors", Enum.RenderPriority.Last.Value - 1, update)
-- parts can stream in after join; keep pairing until all 85 springs are coloured
task.spawn(function()
	for _ = 1, 30 do
		if #items >= 85 then break end
		task.wait(2)
		scan()
	end
end)
