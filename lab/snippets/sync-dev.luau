-- Paste into execute_luau (Edit DataModel) to mirror the lab source tree into ServerStorage.MarketReservoirLabDev
-- from the local bridge (tools/bridge-server.mjs on 127.0.0.1:47621). Development convenience only; the
-- packaged plugin (tools/build-plugin.mjs) is the deliverable.
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local res = HttpService:RequestAsync({ Url = "http://127.0.0.1:47621/tree", Method = "GET" })
assert(res.Success, "bridge unreachable: " .. tostring(res.StatusCode))
local tree = HttpService:JSONDecode(res.Body)
local old = ServerStorage:FindFirstChild("MarketReservoirLabDev")
local devRoot = Instance.new("Folder")
devRoot.Name = "MarketReservoirLabDev"
local count = 0
for _, f in tree.files do
	local parent: Instance = devRoot
	local segments = string.split(f.path, "/")
	for i = 1, #segments - 1 do
		local seg = segments[i]
		local child = parent:FindFirstChild(seg)
		if not child then
			child = Instance.new("Folder")
			child.Name = seg
			child.Parent = parent
		end
		parent = child
	end
	local s = Instance.new(f.className == "Script" and "Script" or "ModuleScript")
	s.Name = segments[#segments]
	if s:IsA("Script") then
		(s :: Script).Disabled = true -- the dev mirror never runs Main as a game script
	end
	(s :: any).Source = f.source
	s:SetAttribute("sha256", f.sha256)
	s.Parent = parent
	count += 1
end
if old then
	old:Destroy()
end
devRoot.Parent = ServerStorage
return "synced " .. count .. " files"
