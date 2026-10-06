-- Run from Studio's Command Bar in the already-open RoAlgo place; no publishing.
assert(game.PlaceId == 0, "Open RoAlgo before installing")
local Http = game:GetService("HttpService")
local storage = game:GetService("ServerStorage")
local control = game:GetService("CoreGui"):FindFirstChild("RoAlgoIndicatorControl")
if control then
    assert(not control:Invoke("status").busy, "Stop the current run before installing")
    control:Invoke("destroy")
end
local tree = Http:JSONDecode(Http:GetAsync("http://127.0.0.1:47622/tree"))
local root = Instance.new("Folder")
root.Name = "RoAlgoIndicator"
for _,f in tree.files do
    local bits = string.split(f.path,"/")
    assert(#bits == 2 and (bits[1] == "src" or bits[1] == "tests"), "Unexpected module path")
    local parent = root:FindFirstChild(bits[1]) or Instance.new("Folder")
    parent.Name = bits[1] parent.Parent = root
    local module = Instance.new("ModuleScript")
    module.Name = bits[2] module.Source = f.source module:SetAttribute("sha256",f.sha256) module.Parent = parent
end
local old = storage:FindFirstChild(root.Name)
if old then old:Destroy() end
root.Parent = storage
return require(root.src.App).start()
