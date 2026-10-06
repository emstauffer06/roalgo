-- SpringPanel spec (contract D17, D21; handover section 10). Self-running: luau.exe tests/SpringPanel.spec.luau
-- Roblox is replaced by a scoped mock injected through options.env. These checks cover the presentation
-- data and wiring only; they do not prove how the panel renders in Studio.
local loaded,SpringPanel=pcall(require,"../src/SpringPanel")
assert(loaded and type(SpringPanel)=="table" and type(SpringPanel.mount)=="function","SpringPanel must load and export mount: "..tostring(SpringPanel))
local passed=0
local function test(name,fn) fn();passed+=1;print("PASS "..name) end

---------------------------------------------------------------------------------------------------
-- Mock Roblox environment.
---------------------------------------------------------------------------------------------------
local function mockRoblox()
	local R={created={},classes={},connections={}}
	local V3={}
	local function v3(x,y,z) return setmetatable({X=x or 0,Y=y or 0,Z=z or 0},V3) end
	V3.__index=function(v,k)
		if k=="Magnitude" then return math.sqrt(v.X^2+v.Y^2+v.Z^2) end
		if k=="Unit" then local m=math.sqrt(v.X^2+v.Y^2+v.Z^2);return v3(v.X/m,v.Y/m,v.Z/m) end
		return nil
	end
	V3.__add=function(a,b) return v3(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
	V3.__sub=function(a,b) return v3(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
	V3.__mul=function(a,b)
		if type(a)=="number" then return v3(a*b.X,a*b.Y,a*b.Z) end
		if type(b)=="number" then return v3(a.X*b,a.Y*b,a.Z*b) end
		return v3(a.X*b.X,a.Y*b.Y,a.Z*b.Z)
	end
	V3.__div=function(a,b) return v3(a.X/b,a.Y/b,a.Z/b) end
	V3.__unm=function(a) return v3(-a.X,-a.Y,-a.Z) end
	V3.__eq=function(a,b) return a.X==b.X and a.Y==b.Y and a.Z==b.Z end
	V3.__tostring=function(a) return string.format("Vector3(%.17g,%.17g,%.17g)",a.X,a.Y,a.Z) end
	R.Vector3={new=v3,zero=v3(0,0,0),one=v3(1,1,1)}
	R.Vector2={new=function(x,y) return {X=x or 0,Y=y or 0,kind="Vector2"} end}
	local function c3(r,g,b) return {R=r,G=g,B=b,kind="Color3"} end
	R.Color3={new=c3,fromRGB=function(r,g,b) return c3(r/255,g/255,b/255) end}
	R.CFrame={new=function(a,b,c)
		local p=if type(a)=="table" then a else v3(a,b,c)
		return {Position=p,X=p.X,Y=p.Y,Z=p.Z,kind="CFrame"}
	end}
	R.UDim={new=function(s,o) return {Scale=s or 0,Offset=o or 0,kind="UDim"} end}
	R.UDim2={new=function(xs,xo,ys,yo) return {X=R.UDim.new(xs,xo),Y=R.UDim.new(ys,yo),kind="UDim2"} end}
	R.UDim2.fromOffset=function(x,y) return R.UDim2.new(0,x,0,y) end
	R.UDim2.fromScale=function(x,y) return R.UDim2.new(x,0,y,0) end
	R.Enum=setmetatable({},{__index=function(_,group)
		return setmetatable({},{__index=function(_,item) return "Enum."..group.."."..item end})
	end})
	R.ColorSequence={new=function(a,b) return {Keypoints={a,b or a},kind="ColorSequence"} end}
	R.NumberSequence={new=function(a,b) return {First=a,Last=b or a,kind="NumberSequence"} end}

	local PARENT_CLASS={Part="BasePart",BasePart="PVInstance",Model="PVInstance",PVInstance="Instance",
		TextLabel="GuiObject",TextButton="GuiButton",GuiButton="GuiObject",TextBox="GuiObject",Frame="GuiObject",ScrollingFrame="GuiObject",
		GuiObject="GuiBase2d",ScreenGui="LayerCollector",BillboardGui="LayerCollector",LayerCollector="GuiBase2d",GuiBase2d="GuiBase",GuiBase="Instance",
		SpringConstraint="Constraint",PrismaticConstraint="Constraint",RopeConstraint="Constraint",VectorForce="Constraint",LineForce="Constraint",
		AlignPosition="Constraint",LinearVelocity="Constraint",Constraint="Instance"}
	local EVENTS={MouseButton1Click=true,MouseButton1Down=true,MouseButton1Up=true,MouseMoved=true,MouseLeave=true,FocusLost=true,
		InputBegan=true,InputChanged=true,InputEnded=true,Activated=true}
	local nextId=0
	local Inst={}
	local methods={}
	local function signal()
		local s={handlers={}}
		function s:Connect(fn)
			local connection={Connected=true}
			local entry={fn=fn,connection=connection}
			table.insert(self.handlers,entry);table.insert(R.connections,connection)
			function connection:Disconnect()
				self.Connected=false
				for i,e in s.handlers do if e==entry then table.remove(s.handlers,i);break end end
			end
			return connection
		end
		function s:Fire(...)
			for _,e in table.clone(self.handlers) do if e.connection.Connected then e.fn(...) end end
		end
		return s
	end
	local function newInstance(className,tracked)
		nextId+=1
		local inst=setmetatable({},Inst)
		rawset(inst,"ClassName",className);rawset(inst,"_id",nextId);rawset(inst,"_props",{Name=className})
		rawset(inst,"_attrs",{});rawset(inst,"_children",{});rawset(inst,"_signals",{});rawset(inst,"_destroyed",false)
		rawset(inst,"_writes",0)
		if tracked then table.insert(R.created,inst);R.classes[className]=(R.classes[className] or 0)+1 end
		return inst
	end
	Inst.__index=function(self,k)
		local m=methods[k]
		if m then return m end
		if k=="Parent" then return rawget(self,"_parent") end
		if EVENTS[k] then
			local signals=rawget(self,"_signals")
			signals[k]=signals[k] or signal()
			return signals[k]
		end
		return rawget(self,"_props")[k]
	end
	Inst.__newindex=function(self,k,v)
		rawset(self,"_writes",rawget(self,"_writes")+1)
		if k=="Parent" then
			assert(not rawget(self,"_destroyed"),"The Parent property of "..tostring(self.Name).." is locked")
			local old=rawget(self,"_parent")
			if old then
				for i,c in rawget(old,"_children") do if c==self then table.remove(rawget(old,"_children"),i);break end end
			end
			rawset(self,"_parent",v)
			if v then table.insert(rawget(v,"_children"),self) end
			return
		end
		assert(methods[k]==nil and not EVENTS[k],"cannot assign "..k)
		rawget(self,"_props")[k]=v
	end
	Inst.__tostring=function(self) return self.ClassName..":"..tostring(self.Name) end
	function methods:SetAttribute(k,v)
		assert(type(k)=="string","attribute name must be a string")
		rawset(self,"_writes",rawget(self,"_writes")+1)
		rawget(self,"_attrs")[k]=v
	end
	function methods:GetAttribute(k) return rawget(self,"_attrs")[k] end
	function methods:GetChildren() return table.clone(rawget(self,"_children")) end
	function methods:GetDescendants()
		local out={}
		local function walk(x) for _,c in rawget(x,"_children") do table.insert(out,c);walk(c) end end
		walk(self)
		return out
	end
	function methods:FindFirstChild(name)
		for _,c in rawget(self,"_children") do if c.Name==name then return c end end
		return nil
	end
	function methods:IsA(className)
		local c=self.ClassName
		while c do if c==className then return true end;c=PARENT_CLASS[c] end
		return className=="Instance"
	end
	function methods:IsDescendantOf(ancestor)
		local p=rawget(self,"_parent")
		while p do if p==ancestor then return true end;p=rawget(p,"_parent") end
		return false
	end
	function methods:Destroy()
		if rawget(self,"_destroyed") then return end
		for _,c in table.clone(rawget(self,"_children")) do c:Destroy() end
		local p=rawget(self,"_parent")
		if p then for i,c in rawget(p,"_children") do if c==self then table.remove(rawget(p,"_children"),i);break end end end
		rawset(self,"_parent",nil);rawset(self,"_destroyed",true)
		for _,s in rawget(self,"_signals") do
			for _,e in table.clone(s.handlers) do e.connection:Disconnect() end
		end
	end
	R.Instance={new=function(className)
		assert(type(className)=="string","Instance.new needs a class name")
		return newInstance(className,true)
	end}
	function R.root(className) return newInstance(className or "Workspace",false) end
	function R.env() return {Instance=R.Instance,Vector3=R.Vector3,Vector2=R.Vector2,Color3=R.Color3,CFrame=R.CFrame,UDim2=R.UDim2,UDim=R.UDim,
		Enum=R.Enum,ColorSequence=R.ColorSequence,NumberSequence=R.NumberSequence} end
	function R.live()
		local n=0
		for _,inst in R.created do if not rawget(inst,"_destroyed") then n+=1 end end
		return n
	end
	function R.props(inst) return rawget(inst,"_props") end
	function R.writes(inst) return rawget(inst,"_writes") end
	function R.isDestroyed(inst) return rawget(inst,"_destroyed") end
	return R
end

-- Canonical text of every property and attribute under root, for no-partial-update checks.
local function serialize(value,seen)
	local kind=type(value)
	if kind=="number" then return string.format("%.17g",value) end
	if kind~="table" then return tostring(value) end
	if rawget(value,"_id") then return "inst#"..rawget(value,"_id") end
	seen=seen or {}
	if seen[value] then return "<cycle>" end
	seen[value]=true
	local keys={}
	for k in value do table.insert(keys,tostring(k)) end
	table.sort(keys)
	local parts={}
	for _,k in keys do
		local v=value[k]
		if v==nil then v=value[tonumber(k)] end
		table.insert(parts,k.."="..serialize(v,seen))
	end
	seen[value]=nil
	return "{"..table.concat(parts,",").."}"
end
local function snapshot(root)
	local parts={}
	local all=root:GetDescendants()
	table.insert(all,1,root)
	for _,inst in all do
		table.insert(parts,string.format("%d|%s|%s|%s|%s",rawget(inst,"_id"),inst.ClassName,serialize(rawget(inst,"_props")),
			serialize(rawget(inst,"_attrs")),tostring(rawget(inst,"_parent") and rawget(rawget(inst,"_parent"),"_id"))))
	end
	return table.concat(parts,"\n")
end

---------------------------------------------------------------------------------------------------
-- Fixtures (synthetic values; shaped like contract displayRows).
---------------------------------------------------------------------------------------------------
local DRIVE_NAMES={"trend","immediateReturn","rangeActivity","volume","peerRelative","hourlyContext","dailyTrend","regimeStress"}
local BANK_CHANNELS={{2,3,4},{1,5,6},{7,8,1}}
local DIRECTIONAL={[1]=true,[4]=true,[7]=true,[9]=true,[11]=true,[12]=true,[14]=true,[15]=true,[17]=true,[19]=true,[20]=true,[22]=true,[23]=true}
local function deepFreeze(t) for _,v in t do if type(v)=="table" then deepFreeze(v) end end;if not table.isfrozen(t) then table.freeze(t) end;return t end
local function fixtureDescriptor()
	local bankNames={"Fast","Medium","Slow"}
	local nodes={}
	for i=1,24 do
		local bank=math.ceil(i/8);local column=(i-1)%8+1
		local channel=BANK_CHANNELS[bank][(column-1)%3+1]
		nodes[i]={index=i,name=bankNames[bank]..string.format("%02d",column),bank=bank,bankName=bankNames[bank],y=(3-bank)*256,z=(column-1)*256,
			dominantChannel=channel,dominantName=DRIVE_NAMES[channel],dominantCoefficient=0.72,directional=DIRECTIONAL[i]==true}
	end
	return deepFreeze({schema="spring-v2-descriptor-1",nodeCount=24,D=64,spacing=256,nodes=nodes,driveNames=table.clone(DRIVE_NAMES)})
end
local DESCRIPTOR=fixtureDescriptor()
local HEADERS={
	recorded_native="Recorded native physics · 5-minute observations · no live simulation.",
	artificial_intervention="Artificial state intervention · not a recording",
	market_baseline="Market-only baseline · no physical input",
	no_trade="No-trade baseline · no physical input",
}
local RUNS={
	{id="coupled",kind="recorded_native",label="Coupled",rowCount=2268},
	{id="zero",kind="artificial_intervention",label="Zero state",rowCount=2268},
	{id="frozen",kind="artificial_intervention",label="Frozen state",rowCount=2268},
	{id="independent",kind="recorded_native",label="Independent",rowCount=2268},
	{id="numeric",kind="numerical",label="Numeric",rowCount=2268},
	{id="ema_baseline",kind="market_baseline",label="EMA baseline",rowCount=2268},
	{id="no_trade",kind="no_trade",label="No trade",rowCount=2268},
}
local function apply(r,over)
	-- false in an override removes the field (a nil in a table constructor overrides nothing).
	if over then for k,val in over do if val==false then r[k]=nil else r[k]=val end end end
	return r
end
local function row(over)
	local c={}
	for i=1,24 do c[i]=0 end
	c[4]=0.0410;c[12]=-0.0333;c[20]=0.0275;c[9]=0.0111;c[1]=-0.0042
	return apply({index=412,t=1733153700,availableT=1733154000,label="2024-12-02 10:35 ET",day="2024-12-02",partition="training_retrospective",
		runId="coupled",runKind="recorded_native",runLabel="Coupled · recorded native",header=HEADERS.recorded_native,sampleId="coupled:412",
		x={},v={},
		diagnostics={valid=true,score=0.1534,bankScores={0.2101,-0.0412,0.0907},nodeContributions=c},
		thresholds={entry=0.1129,exit=0.0508,bankDeadband=0.0282},
		policy={setup="positive",warmup=37,posConfirm=1,negConfirm=0,longExit=1,shortExit=0,blocked="cooldown"},
		intent={action="CLOSE",source="physics",reason="physics_loss_of_conviction"},
		final={action="CLOSE",source="physics",reason="physics_loss_of_conviction",overridden=false,riskConditions={}},
		pending={action="CLOSE",source="physics",reason="physics_loss_of_conviction",signalT=1733154000},
		position=1,holdBars=3,equity=1.00234,stop=598.12,target=603.4,
		executions={{t=1733153700,action="BUY",side="BUY",price=601.23,reason="confirmed_positive_setup",source="physics",signalT=1733153400},
			{t=1733153700,action="CLOSE",side="SELL",price=600.5,reason="stop",source="risk"}},
		evidence={implementationStatus="history_verified",physicsDependence="demonstrated_on_history",marketEvidence="development_only_no_fresh_holdout"}},over)
end
local function baselineRow(kind,over)
	return apply(row({runId=if kind=="market_baseline" then "ema_baseline" else "no_trade",runKind=kind,header=HEADERS[kind],
		runLabel=if kind=="market_baseline" then "EMA trend baseline" else "No trade",sampleId=false,x=false,v=false,pending=false,executions={},
		diagnostics={valid=true,score=if kind=="market_baseline" then -0.0721 else nil,bankScores=if kind=="market_baseline" then {-0.1,-0.05,0.02} else nil},
		intent={action="HOLD",source="baseline",reason="no_setup"},final={action="HOLD",source="baseline",reason="no_setup",overridden=false,riskConditions={}},
		position=0,holdBars=0,equity=0.99871}),over)
end
local CONTEXT={rowCount=2268,evidence={physicsDependenceCounts={coupledVsZero=14,coupledVsFrozen=9}},comparisons={actionDifferences=23,longShort="15/8"}}

local function mount(callbacks,options)
	local R=mockRoblox()
	local core=R.root("CoreGui")
	options=options or {}
	options.env=options.env or R.env()
	options.callbacks=callbacks or {}
	options.descriptor=options.descriptor or DESCRIPTOR
	local panel=SpringPanel.mount(core,options)
	return R,core,panel
end
local function find(root,name)
	for _,x in root:GetDescendants() do if x.Name==name then return x end end
	error("no descendant named "..name)
end
local function textOf(root,name) return tostring(find(root,name).Text) end
local function has(haystack,needle,what) assert(string.find(haystack,needle,1,true),(what or "text").." missing '"..needle.."' in '"..haystack.."'") end
local function recorder()
	local calls={}
	local callbacks={}
	for _,name in {"onRun","onPlay","onPause","onStep","onScrub","onExit"} do
		callbacks[name]=function(...) table.insert(calls,{name,...}) end
	end
	return calls,callbacks
end

---------------------------------------------------------------------------------------------------
test("mount builds one docked RoAlgoSpringPanel ScreenGui under the parent and nothing else",function()
	local R,core,panel=mount()
	local children=core:GetChildren()
	assert(#children==1 and children[1].Name=="RoAlgoSpringPanel" and children[1].ClassName=="ScreenGui" and panel.screenGui==children[1])
	local gui=children[1]
	assert(gui.ResetOnSpawn==false and gui.IgnoreGuiInset==true and gui.Enabled==true and gui.DisplayOrder>60,"above the main dashboard")
	assert(R.writes(core)==0)
	for _,inst in R.created do assert(inst==gui or inst:IsDescendantOf(gui),"created outside the panel: "..tostring(inst)) end
	local dock=gui:FindFirstChild("Dock")
	assert(dock.AnchorPoint.X==1 and dock.Position.X.Scale==1 and dock.Position.X.Offset==0,"docked to the right edge")
	assert(dock.Size.X.Scale==0 and dock.Size.X.Offset==440 and dock.Size.Y.Scale==1 and dock.Size.Y.Offset==0,"440 px wide, full height")
	assert(dock.BackgroundTransparency==0)
end)

test("layout fits 440 px, keeps text readable and does not overlap rows",function()
	local _,_,panel=mount()
	panel:setRuns(RUNS)
	panel:update(row(),baselineRow("no_trade"),CONTEXT)
	local content=find(panel.screenGui,"Content")
	assert(content.ClassName=="ScrollingFrame","content scrolls when the viewport is shorter than the panel")
	local canvas=content.CanvasSize.Y.Offset
	assert(canvas>=600 and canvas<=760,"content height suits a 720 px viewport (scrolls if Studio is shorter): "..canvas)
	local bands={}
	for _,x in content:GetChildren() do
		if x.Position and x.Size and x.ClassName~="UICorner" then
			local left,width=x.Position.X.Offset,x.Size.X.Offset
			local top,height=x.Position.Y.Offset,x.Size.Y.Offset
			assert(x.Position.X.Scale==0 and x.Size.X.Scale==0,"fixed-pixel layout inside the dock: "..x.Name)
			assert(left>=0 and left+width<=440,"horizontal overflow: "..x.Name)
			assert(top>=0 and top+height<=canvas,"vertical overflow: "..x.Name)
			if x.ClassName=="TextLabel" or x.ClassName=="TextButton" or x.ClassName=="TextBox" then
				assert(x.TextSize>=9,"text too small: "..x.Name)
			end
			table.insert(bands,{name=x.Name,left=left,right=left+width,top=top,bottom=top+height})
		end
	end
	for i=1,#bands do for j=i+1,#bands do
		local a,b=bands[i],bands[j]
		local overlapX=a.left<b.right and b.left<a.right
		local overlapY=a.top<b.bottom and b.top<a.bottom
		assert(not (overlapX and overlapY),"overlap: "..a.name.." and "..b.name)
	end end
	for _,x in panel.screenGui:GetDescendants() do
		if (x.ClassName=="TextLabel" or x.ClassName=="TextButton") then assert(x.TextSize>=9,"text too small: "..x.Name) end
	end
end)

test("setRuns builds a selector button per run; clicks report the run id; the shown run is highlighted",function()
	local calls,callbacks=recorder()
	local _,_,panel=mount(callbacks)
	panel:setRuns(RUNS)
	for _,run in RUNS do
		local b=find(panel.screenGui,"Run_"..run.id)
		assert(b.ClassName=="TextButton" and b.Text==run.label and b:GetAttribute("RunId")==run.id and b:GetAttribute("RunKind")==run.kind)
		b.MouseButton1Click:Fire()
	end
	assert(#calls==#RUNS)
	for i,run in RUNS do assert(calls[i][1]=="onRun" and calls[i][2]==run.id) end
	panel:update(row({runId="zero",runKind="artificial_intervention",header=HEADERS.artificial_intervention,sampleId="zero:412"}),nil,CONTEXT)
	local zero,coupled=find(panel.screenGui,"Run_zero"),find(panel.screenGui,"Run_coupled")
	assert(zero.BackgroundColor3.R>0.9 and zero.BackgroundColor3.B<0.2,"selected run uses the amber accent (terminal palette)")
	assert(coupled.BackgroundColor3.B<0.3,"unselected runs stay dark")
	-- Replacing the run list removes the old buttons and their handlers.
	panel:setRuns({RUNS[1],RUNS[7]})
	assert(not pcall(function() find(panel.screenGui,"Run_zero") end))
	assert(not pcall(function() panel:setRuns({RUNS[1],RUNS[1]}) end),"duplicate run ids")
	assert(not pcall(function() panel:setRuns({{id="x",kind="live"}}) end),"unknown run kind")
	local nine={}
	for i=1,9 do nine[i]={id="r"..i,kind="no_trade"} end
	assert(not pcall(function() panel:setRuns(nine) end),"more runs than the selector holds")
end)

test("update shows every displayRow field from the same row",function()
	local _,_,panel=mount()
	local r=row()
	panel:update(r,nil,CONTEXT)
	local g=panel.screenGui
	assert(textOf(g,"Header")==HEADERS.recorded_native)
	has(textOf(g,"Provenance"),"run coupled");has(textOf(g,"Provenance"),"recorded_native");has(textOf(g,"Provenance"),"coupled:412")
	has(textOf(g,"Timestamp"),"2024-12-02 10:35 ET");has(textOf(g,"Timestamp"),"1733153700");has(textOf(g,"Timestamp"),"1733154000")
	assert(textOf(g,"Partition")=="TRAINING · retrospective in-sample")
	assert(textOf(g,"RowCounter")=="row 412 / 2268")
	assert(textOf(g,"Score")=="SCORE +0.1534")
	has(textOf(g,"Setup"),"setup positive")
	assert(textOf(g,"Thresholds")=="entry ±0.1129 · exit ±0.0508 · bank deadband ±0.0282")
	assert(textOf(g,"BankValue1")=="+0.2101" and textOf(g,"BankValue2")=="-0.0412" and textOf(g,"BankValue3")=="+0.0907")
	assert(textOf(g,"Contribution1")=="1. Fast04 · immediateReturn  +0.0410")
	assert(textOf(g,"Contribution2")=="2. Medium04 · trend  -0.0333")
	assert(textOf(g,"Contribution3")=="3. Slow04 · dailyTrend  +0.0275")
	assert(textOf(g,"Contribution4")=="4. Medium01 · trend  +0.0111")
	assert(textOf(g,"PolicyCounters")=="warm-up 37 · confirm +1 / −0 · exit long 1 / short 0")
	assert(textOf(g,"PolicyState")=="blocked: cooldown")
	assert(textOf(g,"Intent")=="INTENT  CLOSE · physics · physics_loss_of_conviction")
	assert(textOf(g,"Final")=="FINAL  CLOSE · physics · physics_loss_of_conviction")
	assert(textOf(g,"Conditions")=="override conditions: none")
	assert(textOf(g,"Pending")=="PENDING  CLOSE · physics · physics_loss_of_conviction · signalT 1733154000 · fills at next open")
	assert(textOf(g,"Position")=="POSITION LONG (+1) · hold 3 bars · equity 1.00234")
	assert(textOf(g,"Levels")=="stop 598.1200 · target 603.4000")
	assert(textOf(g,"Fill1")=="FILL BUY · side BUY @ 601.2300 · physics · confirmed_positive_setup · signalT 1733153400")
	assert(textOf(g,"Fill2")=="FILL CLOSE · side SELL @ 600.5000 · risk · stop")
	assert(textOf(g,"Fill3")=="")
	assert(textOf(g,"EvidenceImplementation")=="implementation: history_verified")
	assert(textOf(g,"EvidenceDependence")=="physics dependence: demonstrated_on_history")
	assert(textOf(g,"EvidenceMarket")=="market evidence: development_only_no_fresh_holdout")
	assert(textOf(g,"NotApproved")=="experimental - not approved for trading")
	has(textOf(g,"EvidenceCounts"),"coupledVsZero=14");has(textOf(g,"EvidenceCounts"),"coupledVsFrozen=9")
	has(textOf(g,"Comparisons"),"actionDifferences=23")
	assert(g:GetAttribute("RowIndex")==412 and g:GetAttribute("SampleId")=="coupled:412" and g:GetAttribute("ObservationT")==1733153700)
	assert(g:GetAttribute("RunId")=="coupled" and g:GetAttribute("RunKind")=="recorded_native")
end)

test("overrides, risk conditions, flat positions and empty fills are spelled out",function()
	local _,_,panel=mount()
	panel:update(row({intent={action="BUY",source="physics",reason="confirmed_positive_setup"},
		final={action="HOLD",source="risk",reason="risk_not_ready",overridden=true,riskConditions={"risk_not_ready","invalid_risk_volatility"}},
		pending=false,position=-1,holdBars=7,stop=false,target=false,executions={},partition="evaluation"}),nil,CONTEXT)
	local g=panel.screenGui
	assert(textOf(g,"Intent")=="INTENT  BUY · physics · confirmed_positive_setup")
	assert(textOf(g,"Final")=="FINAL  HOLD · risk · risk_not_ready · OVERRIDDEN")
	assert(textOf(g,"Conditions")=="override conditions: risk_not_ready, invalid_risk_volatility")
	assert(textOf(g,"Pending")=="PENDING  none")
	assert(textOf(g,"Position")=="POSITION SHORT (-1) · hold 7 bars · equity 1.00234")
	assert(textOf(g,"Levels")=="stop — · target —")
	assert(textOf(g,"Fill1")=="FILLS  none this bar")
	assert(textOf(g,"Partition")=="EVALUATION · development only, not a fresh holdout")
	panel:update(row({partition="validation"}),nil,CONTEXT)
	assert(textOf(g,"Partition")=="VALIDATION · development, sessions already inspected")
	-- More fills than lines: the last line says how many are hidden.
	local many={}
	for k=1,5 do many[k]={t=1,action="BUY",side="BUY",price=1,reason="r"..k,source="physics"} end
	panel:update(row({executions=many}),nil,CONTEXT)
	has(textOf(g,"Fill3"),"(+2 more)")
end)

test("the panel displays the row's own decision; it never recomputes one",function()
	local _,_,panel=mount()
	-- Score far above entry with two strong banks, but the stored final action is HOLD: HOLD is shown.
	panel:update(row({diagnostics={valid=true,score=0.9,bankScores={0.9,0.9,0.9}},final={action="HOLD",source="physics",reason="warmup",overridden=false},
		intent={action="HOLD",source="physics",reason="warmup"},policy={setup="positive",warmup=3,posConfirm=0,negConfirm=0,longExit=0,shortExit=0,blocked="warmup"}}),nil,CONTEXT)
	assert(textOf(panel.screenGui,"Final")=="FINAL  HOLD · physics · warmup")
	assert(textOf(panel.screenGui,"Score")=="SCORE +0.9000")
	assert(textOf(panel.screenGui,"Contribution1")=="no node contributions recorded for this row")
end)

test("a baseline row says no physical input; the comparison strip is aligned to the same observation",function()
	local _,_,panel=mount()
	local g=panel.screenGui
	panel:update(baselineRow("market_baseline"),nil,CONTEXT)
	assert(textOf(g,"Header")==HEADERS.market_baseline)
	has(textOf(g,"Contribution1"),"no physical input")
	assert(textOf(g,"Contribution2")=="")
	assert(textOf(g,"CompareHeader")=="COMPARE  no comparison row selected")
	panel:update(row(),baselineRow("no_trade"),CONTEXT)
	assert(textOf(g,"CompareHeader")=="COMPARE  No trade · "..HEADERS.no_trade)
	assert(textOf(g,"CompareAlignment")=="aligned · same observation #412 · 2024-12-02 10:35 ET")
	assert(textOf(g,"CompareSummary")=="score — · final HOLD · no_setup · position FLAT · equity 0.99871")
	assert(g:GetAttribute("CompareAligned")==true and g:GetAttribute("CompareRunId")=="no_trade")
	panel:update(row(),baselineRow("market_baseline",{index=411,t=1733153400}),CONTEXT)
	has(textOf(g,"CompareAlignment"),"MISALIGNED")
	assert(g:GetAttribute("CompareAligned")==false)
	local alignment=find(g,"CompareAlignment")
	assert(alignment.TextColor3.R>alignment.TextColor3.G,"misalignment is shown in red")
end)

test("transport controls call onStep, onPlay/onPause, onScrub and onExit",function()
	local calls,callbacks=recorder()
	local R,_,panel=mount(callbacks)
	local g=panel.screenGui
	panel:update(row(),nil,CONTEXT)
	find(g,"Previous").MouseButton1Click:Fire()
	find(g,"Next").MouseButton1Click:Fire()
	local play=find(g,"PlayPause")
	assert(play.Text=="Play")
	play.MouseButton1Click:Fire();assert(play.Text=="Pause")
	play.MouseButton1Click:Fire();assert(play.Text=="Play")
	find(g,"Exit").MouseButton1Click:Fire()
	local track=find(g,"ScrubTrack")
	R.props(track).AbsolutePosition=R.Vector2.new(1492,200);R.props(track).AbsoluteSize=R.Vector2.new(416,12)
	track.MouseButton1Down:Fire(1492+416*0.25,206)
	track.MouseMoved:Fire(1492+416*0.25,206) -- same row: no duplicate scrub
	track.MouseMoved:Fire(1492+416*0.5,206)
	track.MouseButton1Up:Fire(1492+416*0.5,206)
	track.MouseMoved:Fire(1492+416,206) -- not dragging any more
	track.MouseButton1Down:Fire(1492-50,206) -- left of the track clamps to the first row
	local goTo=find(g,"GoTo")
	goTo.Text="100";goTo.FocusLost:Fire(true)
	goTo.Text="100";goTo.FocusLost:Fire(false) -- focus lost without Enter does nothing
	goTo.Text="abc";goTo.FocusLost:Fire(true)
	goTo.Text="9999";goTo.FocusLost:Fire(true)
	goTo.Text="12.5";goTo.FocusLost:Fire(true)
	local expected={{"onStep",-1},{"onStep",1},{"onPlay"},{"onPause"},{"onExit"},{"onScrub",568},{"onScrub",1135},{"onScrub",1},{"onScrub",100}}
	assert(#calls==#expected,"expected "..#expected.." callback calls, got "..#calls)
	for i,want in expected do
		assert(calls[i][1]==want[1] and calls[i][2]==want[2],string.format("call %d is %s(%s), expected %s(%s)",i,calls[i][1],tostring(calls[i][2]),want[1],tostring(want[2])))
	end
	has(textOf(g,"Status"),"Row must be a whole number from 1 to 2268")
	-- The controller can report playback state; the row context can too.
	panel:setPlaying(true);assert(play.Text=="Pause")
	panel:update(row(),nil,{rowCount=2268,playing=false});assert(play.Text=="Play")
	assert(panel:testActivate("Next") and calls[#calls][1]=="onStep" and calls[#calls][2]==1)
end)

test("callback errors are contained and reported; missing callbacks are ignored",function()
	local _,_,panel=mount({onExit=function() error("exit refused") end})
	local g=panel.screenGui
	find(g,"Exit").MouseButton1Click:Fire()
	has(textOf(g,"Status"),"Error:");has(textOf(g,"Status"),"exit refused")
	find(g,"Next").MouseButton1Click:Fire() -- no onStep: nothing happens, nothing throws
end)

test("update rejects malformed rows and leaves every field unchanged",function()
	local _,_,panel=mount()
	panel:setRuns(RUNS)
	panel:update(row(),baselineRow("no_trade"),CONTEXT)
	local before=snapshot(panel.screenGui)
	local function contributions(n) local c={} for i=1,n do c[i]=0.001 end return c end
	local cases={
		{"missing runId",row({runId=false})},
		{"unknown runKind",row({runKind="live"})},
		{"missing header",row({header=false})},
		{"missing index",row({index=false})},
		{"fractional index",row({index=2.5})},
		{"position 2",row({position=2})},
		{"non-finite equity",row({equity=0/0})},
		{"missing final",row({final=false})},
		{"final without action",row({final={source="risk"}})},
		{"missing intent",row({intent=false})},
		{"policy not a table",row({policy="positive"})},
		{"missing evidence",row({evidence=false})},
		{"executions not a list",row({executions=false})},
		{"pending without action",row({pending={source="physics"}})},
		{"23 contributions",row({diagnostics={valid=true,score=0,nodeContributions=contributions(23)}})},
		{"2 bank scores",row({diagnostics={valid=true,score=0,bankScores={0,0}}})},
		{"missing diagnostics",row({diagnostics=false})},
		-- Rows whose displayable fields differ from the shown row, so a write-before-validate would be visible.
		{"new header, bad position",row({header="Some other header",label="2024-12-03 09:30 ET",index=413,position=2})},
		{"new score, bad equity",row({diagnostics={valid=true,score=-0.5,bankScores={-1,-1,-1}},equity=math.huge})},
	}
	for _,case in cases do
		local ok,err=pcall(function() panel:update(case[2],nil,CONTEXT) end)
		assert(not ok,"accepted malformed row: "..case[1])
		assert(string.find(tostring(err),"SpringPanel",1,true))
		assert(snapshot(panel.screenGui)==before,"partial update on rejected row: "..case[1])
	end
	assert(not pcall(function() panel:update(row(),row({runId=false}),CONTEXT) end),"malformed compare row")
	assert(not pcall(function() panel:update(row(),nil,{rowCount=100}) end),"rowCount below the row index")
	assert(not pcall(function() panel:update(row(),nil,"context") end),"context must be a table")
	assert(snapshot(panel.screenGui)==before)
end)

test("destroy disconnects controls, removes the ScreenGui and leaves no instances",function()
	local calls,callbacks=recorder()
	local R,core,panel=mount(callbacks)
	panel:setRuns(RUNS)
	panel:update(row(),nil,CONTEXT)
	local next=find(panel.screenGui,"Next")
	local signal=next.MouseButton1Click
	panel:destroy()
	assert(R.live()==0 and #core:GetChildren()==0)
	for _,connection in R.connections do assert(connection.Connected==false,"a connection survived destroy") end
	signal:Fire()
	assert(#calls==0,"a destroyed panel must not call back")
	assert(not pcall(function() panel:update(row(),nil,CONTEXT) end))
	panel:destroy()
	for cycle=1,4 do
		local p=SpringPanel.mount(core,{env=R.env(),callbacks=callbacks,descriptor=DESCRIPTOR})
		p:setRuns(RUNS);p:update(row({index=cycle}),baselineRow("no_trade",{index=cycle}),CONTEXT);p:destroy()
		assert(R.live()==0,"cycle "..cycle.." leaked")
	end
	assert(not pcall(function() SpringPanel.mount(core,{callbacks={}}) end),"no Roblox globals in the CLI without injection")
	assert(R.live()==0 and #core:GetChildren()==0)
end)

test("without a descriptor, contributions use node numbers; rows without policy show dashes",function()
	local R=mockRoblox()
	local core=R.root("CoreGui")
	local panel=SpringPanel.mount(core,{env=R.env()})
	panel:update(row(),nil,{rowCount=2268})
	assert(textOf(panel.screenGui,"Contribution1")=="1. node 04 · dominant input —  +0.0410")
	-- A comparator row without policy counters is shown with dashes, not rejected.
	panel:update(baselineRow("no_trade",{policy=false,thresholds=false}),nil,{rowCount=2268})
	assert(textOf(panel.screenGui,"PolicyCounters")=="warm-up — · confirm +— / −— · exit long — / short —")
	assert(textOf(panel.screenGui,"Thresholds")=="entry — · exit — · bank deadband —")
	panel:destroy()
end)

---------------------------------------------------------------------------------------------------
-- Live forward test labels (spring-live-contract.md L12), appended 2026-10-05. The 2024 cases above are unchanged.
local LIVE_HEADER="Live-captured native physics · 5-minute observations · 2025-2026 forward test."
local LIVE_RUNS={
	{id="coupled",kind="live_native",label="Coupled",rowCount=2269},
	{id="zero",kind="artificial_intervention",label="Zero",rowCount=2269},
	{id="frozen",kind="artificial_intervention",label="Frozen",rowCount=2269},
	{id="independent",kind="live_native",label="Independent",rowCount=2269},
	{id="numeric",kind="numerical",label="Numeric",rowCount=2269},
	{id="ema_baseline",kind="market_baseline",label="EMA base",rowCount=2269},
	{id="no_trade",kind="no_trade",label="No trade",rowCount=2269},
}
local function liveRow(over)
	return apply(row({runKind="live_native",header=LIVE_HEADER,runLabel="Coupled live native",partition="forward_test",
		evidence={implementationStatus="pass",physicsDependence="history_verified",marketEvidence="forward_test_predeclared"}}),over)
end

test("live_native runs and the lead-in and forward-test partitions are shown with their L12 texts (L12)",function()
	local _,_,panel=mount()
	panel:setRuns(LIVE_RUNS)
	assert(find(panel.screenGui,"Run_coupled"):GetAttribute("RunKind")=="live_native")
	assert(find(panel.screenGui,"Run_independent"):GetAttribute("RunKind")=="live_native")
	local g=panel.screenGui
	panel:update(liveRow(),nil,CONTEXT)
	assert(textOf(g,"Header")==LIVE_HEADER)
	has(textOf(g,"Provenance"),"live_native")
	assert(textOf(g,"Partition")=="FORWARD TEST · 2025-2026 · frozen 2024 protocol, never tuned here")
	assert(textOf(g,"EvidenceMarket")=="market evidence: forward_test_predeclared")
	panel:update(liveRow({partition="calibration_lead_in",pending=false,position=0,holdBars=0,equity=1,executions={},stop=false,target=false,
		intent={action="BUY",source="physics",reason="confirmed_positive_setup"},
		final={action="HOLD",source="lead_in",reason="lead_in_not_traded",overridden=true,riskConditions={"lead_in_not_traded"}}}),nil,CONTEXT)
	assert(textOf(g,"Partition")=="2024 LEAD-IN · calibration period · not traded")
	assert(textOf(g,"Intent")=="INTENT  BUY · physics · confirmed_positive_setup")
	assert(textOf(g,"Final")=="FINAL  HOLD · lead_in · lead_in_not_traded · OVERRIDDEN")
	assert(textOf(g,"Conditions")=="override conditions: lead_in_not_traded")
	assert(textOf(g,"Position")=="POSITION FLAT (+0) · hold 0 bars · equity 1.00000")
end)

test("the live additions keep the 2024 refusals for unknown run kinds (L12)",function()
	local _,_,panel=mount()
	panel:setRuns(LIVE_RUNS)
	panel:update(liveRow(),nil,CONTEXT)
	local before=snapshot(panel.screenGui)
	for _,kind in {"live","live_physics","recorded"} do
		assert(not pcall(function() panel:update(liveRow({runKind=kind}),nil,CONTEXT) end),"update accepted runKind "..kind)
	end
	assert(snapshot(panel.screenGui)==before,"a refused live row changes nothing")
	for _,kind in {"live","live_physics"} do
		assert(not pcall(function() panel:setRuns({{id="x",kind=kind}}) end),"setRuns accepted kind "..kind)
	end
end)
print("SpringPanel: "..passed.." tests passed")
