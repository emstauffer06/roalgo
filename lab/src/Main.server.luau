-- MarketReservoirLab local plugin entry (plan Task 1/8). ENGINE CODE.
-- Inert unless the open place is the dedicated experiment place: RoAlgo (placeId 0), or any place
-- whose ServerStorage contains a Folder named MarketReservoirLabPlace. Never runs in Play mode.
local RunService = game:GetService("RunService")
if RunService:IsRunning() then
	return
end
local ServerStorage = game:GetService("ServerStorage")
local CoreGui = game:GetService("CoreGui")
local HttpService = game:GetService("HttpService")

local LAB_PLACE_IDS = { [0] = true }
local function isLabPlace(): boolean
	return LAB_PLACE_IDS[game.PlaceId] == true or ServerStorage:FindFirstChild("MarketReservoirLabPlace") ~= nil
end
if not isLabPlace() then
	return
end

local root = script.Parent.Parent
local buildInfoValue = root:FindFirstChild("BuildInfo")
local buildInfo = buildInfoValue and buildInfoValue.Value or "{}"
local SteppingProbe = require("./Studio/SteppingProbe")
local Panel = require("./UI/Panel")

local state = {
	buildInfo = buildInfo,
	loadProbe = nil :: any,
	busy = false,
	registry = {}, -- objects that dev functions keep alive between requests (reservoirs, runners, jobs)
}

-- Runs a function from the dev source tree (ServerStorage.MarketReservoirLabDev, mirroring lab/) on this
-- plugin's thread. The tree is cloned first so each call sees the current sources (require caches per
-- instance). Only modules inside that folder can be run.
local function runDev(modulePath: string, fnName: string, args: any)
	local devRoot = ServerStorage:FindFirstChild("MarketReservoirLabDev")
	assert(devRoot, "MarketReservoirLab: ServerStorage.MarketReservoirLabDev is missing")
	local clone = devRoot:Clone()
	local target: Instance? = clone
	for part in string.gmatch(modulePath, "[^/]+") do
		target = target and target:FindFirstChild(part)
	end
	assert(target and target:IsA("ModuleScript"), "MarketReservoirLab: dev module not found: " .. modulePath)
	local mod = require(target :: ModuleScript)
	local fn = mod[fnName]
	assert(type(fn) == "function", "MarketReservoirLab: dev function not found: " .. fnName)
	return fn({ plugin = plugin, context = "plugin", buildInfo = buildInfo, registry = state.registry, state = state }, args)
end

local handlers = {}
function handlers.info()
	return HttpService:JSONEncode({
		buildInfo = buildInfo,
		placeId = game.PlaceId,
		studioVersion = version(),
		loadProbe = state.loadProbe,
		busy = state.busy,
	})
end
function handlers.probe(args)
	local label = (type(args) == "table" and args.label) or "plugin-request"
	return HttpService:JSONEncode(SteppingProbe.run(label, args))
end
function handlers.runDev(args)
	assert(type(args) == "table", "runDev expects {module, fn, args}")
	return runDev(args.module, args.fn, args.args)
end

local rpcName = "MarketReservoirLabRPC"
local old = CoreGui:FindFirstChild(rpcName)
if old then
	old:Destroy()
end
local rpc = Instance.new("BindableFunction")
rpc.Name = rpcName
rpc.OnInvoke = function(command: string, args: any)
	-- Only the read-only status call runs on the caller's thread. Anything that can step physics goes through
	-- the single mailbox worker, so two StepPhysics streams can never be outstanding at once.
	if command ~= "info" then
		return HttpService:JSONEncode({ error = "use the MarketReservoirLabRequest mailbox for " .. tostring(command) })
	end
	local handler = handlers[command]
	local ok, result = pcall(handler, args)
	if not ok then
		return HttpService:JSONEncode({ error = tostring(result) })
	end
	return result
end
rpc.Parent = CoreGui

-- Mailbox: requests are queued by an event handler and executed by a worker thread that this plugin
-- spawned at load, so the work always runs on a plugin-owned thread. Callers fire
-- MarketReservoirLabRequest with {id, command, args} and wait for MarketReservoirLabResponse {id, ok, result}.
local function freshEvent(name: string): BindableEvent
	local prev = CoreGui:FindFirstChild(name)
	if prev then
		prev:Destroy()
	end
	local ev = Instance.new("BindableEvent")
	ev.Name = name
	ev.Parent = CoreGui
	return ev
end
local requestEvent = freshEvent("MarketReservoirLabRequest")
local responseEvent = freshEvent("MarketReservoirLabResponse")
local queue = {}
requestEvent.Event:Connect(function(req)
	if type(req) == "table" and type(req.id) == "string" then
		table.insert(queue, req)
	end
end)
task.spawn(function()
	while requestEvent.Parent do
		if state.probing then
			RunService.Heartbeat:Wait() -- the load-time probe is stepping; queued requests wait for it
			continue
		end
		local req = table.remove(queue, 1)
		if req then
			state.busy = true
			local handler = handlers[req.command]
			local ok, result
			if handler then
				ok, result = pcall(handler, req.args)
			else
				ok, result = false, "unknown command " .. tostring(req.command)
			end
			state.busy = false
			responseEvent:Fire({ id = req.id, ok = ok, result = if ok then result else tostring(result) })
		else
			RunService.Heartbeat:Wait()
		end
	end
end)

local toolbar = plugin:CreateToolbar("Market Reservoir Lab")
local button = toolbar:CreateButton("MarketReservoirLabPanel", "Open the market reservoir lab panel", "", "Lab Panel")
button.ClickableWhenViewportHidden = true
local panel = Panel.new(plugin, state)
button.Click:Connect(function()
	panel:toggle()
end)

-- Containers left in Workspace by a previous plugin session belong to no job of this session: remove them.
for _, child in workspace:GetChildren() do
	if child:IsA("Model") and string.sub(child.Name, 1, 19) == "MarketReservoirLab_" then
		child:Destroy()
	end
end

-- One automatic capability probe on the plugin's own main thread, recorded for inspection. The mailbox
-- worker does not start any request while it runs.
state.probing = true
task.defer(function()
	task.wait(2)
	local ok, report = pcall(SteppingProbe.run, "plugin-load", { bars = 200 })
	state.probing = false
	state.loadProbe = ok and report or { error = tostring(report) }
	local sv = CoreGui:FindFirstChild("MarketReservoirLabLoadProbe") or Instance.new("StringValue")
	sv.Name = "MarketReservoirLabLoadProbe"
	sv.Value = HttpService:JSONEncode(state.loadProbe)
	sv.Parent = CoreGui
	panel:refresh()
end)
