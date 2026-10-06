-- Run in the RoAlgo Studio Edit-mode Command Bar. Local installation only.
assert(game.PlaceId == 0, 'Open RoAlgo before installing Market Lab v3')
assert(not game:GetService('RunService'):IsRunning(), 'Install in Studio Edit mode')
local Http=game:GetService('HttpService')
local storage=game:GetService('ServerStorage')
local CoreGui=game:GetService('CoreGui')
local function requireIdle()
    for _,name in {'RoAlgoIndicatorControl','RoAlgoResearchControl','RoAlgoMarketControl'} do
        local control=CoreGui:FindFirstChild(name)
        if control then assert(not control:Invoke('status').busy, 'Wait for '..name..' to finish before installing') end
    end
end
requireIdle()
local health=Http:JSONDecode(Http:GetAsync('http://127.0.0.1:47624/health'))
assert(type(health)=='table' and health.ok==true and health.app=='RoAlgo Market Lab' and health.schemaVersion==3, 'Expected RoAlgo Market Lab schema3 bridge')
requireIdle()
local tree=Http:JSONDecode(Http:GetAsync('http://127.0.0.1:47624/tree'))
assert(type(tree)=='table' and type(tree.files)=='table', 'Invalid source tree')
-- Both HTTP calls can yield. Recheck before allocating or changing any instances.
requireIdle()
local root=Instance.new('Folder')
root.Name='RoAlgoMarketLab'
local seen={}
local ok,err=pcall(function()
    for _,f in tree.files do
        assert(type(f.path)=='string' and f.path:match('^[a-z]+/[A-Za-z0-9_]+$') and not seen[f.path], 'Invalid or duplicate module path')
        local bits=string.split(f.path,'/')
        assert(#bits==2 and (bits[1]=='src' or bits[1]=='tests'), 'Unexpected source directory')
        assert(type(f.source)=='string' and type(f.sha256)=='string' and #f.sha256==64 and f.sha256:match('^[a-f0-9]+$'), 'Invalid source/hash')
        seen[f.path]=true
        local parent=root:FindFirstChild(bits[1])
        if not parent then parent=Instance.new('Folder');parent.Name=bits[1];parent.Parent=root end
        local module=Instance.new('ModuleScript')
        module.Name=bits[2];module.Source=f.source;module:SetAttribute('sha256',f.sha256)
        local provenance=Instance.new('StringValue');provenance.Name='SourceSHA256';provenance.Value=f.sha256;provenance.Parent=module
        module.Parent=parent
    end
    for _,name in {'App','Dashboard','PhysicsView','Features','Regime','Engine','Mechanics','Learning','Execution','Study','VerifiedStepper'} do assert(seen['src/'..name], 'Missing '..name) end
end)
if not ok then root:Destroy();error(err) end
-- Recheck all versions before replacing any live v3 objects.
local idleOk,idleErr=pcall(requireIdle)
if not idleOk then root:Destroy();error(idleErr) end
local existing=CoreGui:FindFirstChild('RoAlgoMarketControl')
if existing then existing:Invoke('destroy') end
local old=storage:FindFirstChild(root.Name)
if old then
    local base='RoAlgoMarketLab_backup_'..tostring(DateTime.now().UnixTimestampMillis)
    local backupName=base
    local suffix=2
    while storage:FindFirstChild(backupName) do backupName=base..'_'..suffix;suffix+=1 end
    old.Name=backupName
end
root.Parent=storage
return require(root.src.App).start()
