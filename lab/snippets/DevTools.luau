-- Integration helpers for driving the MarketReservoirLab plugin from Studio MCP (development only).
-- Installed as ServerStorage.MarketReservoirLabTools by the bootstrap one-liner; require a Clone() of it.
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local CoreGui = game:GetService("CoreGui")
local BRIDGE = "http://127.0.0.1:47621"
local T = {}

function T.sync()
	local res = HttpService:RequestAsync({ Url = BRIDGE .. "/tree", Method = "GET" })
	assert(res.Success, "bridge unreachable")
	local tree = HttpService:JSONDecode(res.Body)
	local old = ServerStorage:FindFirstChild("MarketReservoirLabDev")
	local devRoot = Instance.new("Folder")
	devRoot.Name = "MarketReservoirLabDev"
	for _, f in tree.files do
		local parent = devRoot
		local segments = string.split(f.path, "/")
		for i = 1, #segments - 1 do
			local child = parent:FindFirstChild(segments[i])
			if not child then
				child = Instance.new("Folder")
				child.Name = segments[i]
				child.Parent = parent
			end
			parent = child
		end
		local s = Instance.new(f.className == "Script" and "Script" or "ModuleScript")
		s.Name = segments[#segments]
		if s:IsA("Script") then
			s.Disabled = true
		end
		s.Source = f.source
		s:SetAttribute("sha256", f.sha256)
		s.Parent = parent
	end
	if old then
		old:Destroy()
	end
	devRoot.Parent = ServerStorage
	return #tree.files
end

function T.call(command, args, timeout)
	local req, resp = CoreGui.MarketReservoirLabRequest, CoreGui.MarketReservoirLabResponse
	local id = HttpService:GenerateGUID(false)
	local result
	local conn = resp.Event:Connect(function(r)
		if type(r) == "table" and r.id == id then
			result = r
		end
	end)
	req:Fire({ id = id, command = command, args = args })
	local t0 = os.clock()
	while not result and os.clock() - t0 < (timeout or 100) do
		task.wait()
	end
	conn:Disconnect()
	if not result then
		error("plugin request timed out")
	end
	if not result.ok then
		error("plugin request failed: " .. tostring(result.result))
	end
	return result.result
end

function T.dev(module, fn, args, timeout)
	return T.call("runDev", { module = module, fn = fn, args = args }, timeout)
end

-- Fire-and-forget: the result is stored in CoreGui.MarketReservoirLabResult_<tag> (JSON) when it arrives.
function T.devAsync(tag, module, fn, args)
	local sv = CoreGui:FindFirstChild("MarketReservoirLabResult_" .. tag) or Instance.new("StringValue")
	sv.Name = "MarketReservoirLabResult_" .. tag
	sv.Value = "pending"
	sv.Parent = CoreGui
	task.spawn(function()
		local ok, res = pcall(T.dev, module, fn, args, 7200)
		sv.Value = HttpService:JSONEncode({ ok = ok, result = res })
	end)
	return sv.Name
end

function T.result(tag)
	local sv = CoreGui:FindFirstChild("MarketReservoirLabResult_" .. tag)
	return sv and sv.Value or "missing"
end

function T.json(v)
	return HttpService:JSONEncode(v)
end

return T
