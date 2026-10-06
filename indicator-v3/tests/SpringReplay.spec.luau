-- SpringReplayView spec (contract D14, D17, D20, D23, D25 and the SpringReplayView section).
-- Self-running: luau.exe tests/SpringReplay.spec.luau
-- Roblox is replaced by a scoped mock (instances, Vector3, Color3, sequences, ...) injected through options.env.
-- These checks cover properties, data mapping and a pinhole projection of the default framing; they do not prove
-- the rendered Studio scene.
local loaded,SpringReplayView=pcall(require,"../src/SpringReplayView")
assert(loaded and type(SpringReplayView)=="table" and type(SpringReplayView.mount)=="function",
	"SpringReplayView must load and export mount: "..tostring(SpringReplayView))
local passed=0
local function test(name,fn) fn();passed+=1;print("PASS "..name) end
local function near(a,b,e) assert(type(a)=="number" and math.abs(a-b)<=(e or 1e-9),tostring(a).." != "..tostring(b)) end

---------------------------------------------------------------------------------------------------
-- Mock Roblox environment. Assignments are checked against a per-class property allowlist with value types and
-- enum values against an enum allowlist, so a misspelt or wrongly typed property fails here, not only in Studio.
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
	local function c3(r,g,b)
		assert(type(r)=="number" and type(g)=="number" and type(b)=="number","Color3.new needs three numbers")
		return {R=r,G=g,B=b,kind="Color3"}
	end
	R.Color3={new=c3,fromRGB=function(r,g,b) return c3(r/255,g/255,b/255) end}
	R.CFrame={new=function(a,b,c)
		local p=if type(a)=="table" then a else v3(a,b,c)
		return {Position=p,X=p.X,Y=p.Y,Z=p.Z,kind="CFrame"}
	end}
	R.UDim={new=function(s,o) return {Scale=s or 0,Offset=o or 0,kind="UDim"} end}
	R.UDim2={new=function(xs,xo,ys,yo) return {X=R.UDim.new(xs,xo),Y=R.UDim.new(ys,yo),kind="UDim2"} end}
	R.UDim2.fromOffset=function(x,y) return R.UDim2.new(0,x,0,y) end
	R.UDim2.fromScale=function(x,y) return R.UDim2.new(x,0,y,0) end
	local ENUMS={Font={Gotham=true,GothamBold=true,GothamMedium=true,Code=true},Material={SmoothPlastic=true,Neon=true},
		PartType={Ball=true,Cylinder=true,Block=true},TextXAlignment={Left=true,Right=true,Center=true},
		TextYAlignment={Center=true,Top=true,Bottom=true},TextTruncate={AtEnd=true,None=true},ZIndexBehavior={Sibling=true,Global=true},
		ScrollingDirection={Y=true,X=true,XY=true}}
	R.Enum=setmetatable({},{__index=function(_,group)
		assert(ENUMS[group],"Enum."..tostring(group).." is not a known enum")
		return setmetatable({},{__index=function(_,item)
			assert(ENUMS[group][item],"Enum."..group.."."..tostring(item).." is not a valid enum item")
			return "Enum."..group.."."..item
		end})
	end})
	-- Sequences follow the Roblox rules: two or more keypoints, times increasing from exactly 0 to exactly 1.
	local function checkKeypoints(list,kind)
		assert(type(list)=="table" and #list>=2,kind..".new needs at least two keypoints")
		assert(list[1].Time==0 and list[#list].Time==1,kind.." keypoints must start at time 0 and end at time 1")
		for i=2,#list do assert(list[i].Time>list[i-1].Time,kind.." keypoint times must increase") end
	end
	R.ColorSequenceKeypoint={new=function(t,c)
		assert(type(t)=="number" and type(c)=="table" and c.kind=="Color3","ColorSequenceKeypoint.new(time, Color3)")
		return {Time=t,Value=c,kind="ColorSequenceKeypoint"}
	end}
	R.NumberSequenceKeypoint={new=function(t,v)
		assert(type(t)=="number" and type(v)=="number","NumberSequenceKeypoint.new(time, value)")
		return {Time=t,Value=v,Envelope=0,kind="NumberSequenceKeypoint"}
	end}
	R.ColorSequence={new=function(a,b)
		local list
		if type(a)=="table" and a.kind=="Color3" then
			list={R.ColorSequenceKeypoint.new(0,a),R.ColorSequenceKeypoint.new(1,b or a)}
		else
			list=a
		end
		checkKeypoints(list,"ColorSequence")
		for _,k in list do assert(k.kind=="ColorSequenceKeypoint","ColorSequence needs ColorSequenceKeypoints") end
		return {Keypoints=list,kind="ColorSequence"}
	end}
	R.NumberSequence={new=function(a,b)
		local list
		if type(a)=="number" then
			list={R.NumberSequenceKeypoint.new(0,a),R.NumberSequenceKeypoint.new(1,b or a)}
		else
			list=a
		end
		checkKeypoints(list,"NumberSequence")
		for _,k in list do assert(k.kind=="NumberSequenceKeypoint","NumberSequence needs NumberSequenceKeypoints") end
		return {Keypoints=list,kind="NumberSequence"}
	end}

	local PARENT_CLASS={Part="BasePart",BasePart="PVInstance",Model="PVInstance",PVInstance="Instance",Folder="Instance",
		Attachment="Instance",Beam="Instance",UICorner="Instance",UIStroke="Instance",UITextSizeConstraint="Instance",
		TextLabel="GuiObject",TextButton="GuiButton",GuiButton="GuiObject",TextBox="GuiObject",Frame="GuiObject",ScrollingFrame="GuiObject",
		GuiObject="GuiBase2d",ScreenGui="LayerCollector",BillboardGui="LayerCollector",LayerCollector="GuiBase2d",GuiBase2d="GuiBase",GuiBase="Instance",
		SpringConstraint="Constraint",PrismaticConstraint="Constraint",RopeConstraint="Constraint",VectorForce="Constraint",LineForce="Constraint",
		AlignPosition="Constraint",LinearVelocity="Constraint",Constraint="Instance"}
	-- Writable properties used by the modules, with their Roblox value types (subset of the real API).
	local TEXT={Text="string",TextColor3="Color3",TextTransparency="number",Font="Enum.Font",TextSize="number",TextWrapped="boolean",
		TextScaled="boolean",TextXAlignment="Enum.TextXAlignment",TextYAlignment="Enum.TextYAlignment",TextTruncate="Enum.TextTruncate",RichText="boolean"}
	local PROPS={
		Instance={Name="string"},
		BasePart={Anchored="boolean",CanCollide="boolean",CanTouch="boolean",CanQuery="boolean",CastShadow="boolean",Locked="boolean",
			Material="Enum.Material",Size="Vector3",CFrame="CFrame",Color="Color3",Transparency="number"},
		Part={Shape="Enum.PartType"},
		Attachment={Position="Vector3"},
		Beam={Attachment0="Instance",Attachment1="Instance",Width0="number",Width1="number",FaceCamera="boolean",Segments="number",
			LightInfluence="number",LightEmission="number",Enabled="boolean",Color="ColorSequence",Transparency="NumberSequence"},
		LayerCollector={Enabled="boolean",ResetOnSpawn="boolean",ZIndexBehavior="Enum.ZIndexBehavior"},
		BillboardGui={Adornee="Instance",AlwaysOnTop="boolean",MaxDistance="number",LightInfluence="number",Size="UDim2",SizeOffset="Vector2",
			StudsOffsetWorldSpace="Vector3",ClipsDescendants="boolean"},
		ScreenGui={IgnoreGuiInset="boolean",DisplayOrder="number"},
		GuiObject={Position="UDim2",Size="UDim2",AnchorPoint="Vector2",BackgroundColor3="Color3",BackgroundTransparency="number",
			BorderSizePixel="number",Visible="boolean",ZIndex="number",ClipsDescendants="boolean"},
		GuiButton={AutoButtonColor="boolean"},
		TextLabel=TEXT,TextButton=TEXT,
		TextBox=setmetatable({PlaceholderText="string",ClearTextOnFocus="boolean"},{__index=TEXT}),
		ScrollingFrame={CanvasSize="UDim2",ScrollBarThickness="number",ScrollingDirection="Enum.ScrollingDirection",ScrollBarImageColor3="Color3"},
		UICorner={CornerRadius="UDim"},
		UIStroke={Color="Color3",Thickness="number",Transparency="number"},
		UITextSizeConstraint={MaxTextSize="number",MinTextSize="number"},
	}
	local function propertyType(className,key)
		local c=className
		while c do
			local list=PROPS[c]
			if list and list[key] then return list[key] end
			c=PARENT_CLASS[c]
		end
		return nil
	end
	local function typeOf(value)
		local kind=type(value)
		if kind=="table" then
			if getmetatable(value)==V3 then return "Vector3" end
			if rawget(value,"_id") then return "Instance" end
			if value.kind then return value.kind end
		end
		if kind=="string" and string.sub(value,1,5)=="Enum." then return string.match(value,"^(Enum%.[^.]+)") end
		return kind
	end
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
		rawset(inst,"_writes",0);rawset(inst,"_tracked",tracked)
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
		if rawget(self,"_tracked") then
			local expected=propertyType(self.ClassName,k)
			assert(expected,tostring(k).." is not a valid member of "..self.ClassName)
			assert(v==nil or typeOf(v)==expected,string.format("%s.%s expects %s, got %s",self.ClassName,k,expected,typeOf(v)))
		end
		rawget(self,"_props")[k]=v
	end
	Inst.__tostring=function(self) return self.ClassName..":"..tostring(self.Name) end
	function methods:SetAttribute(k,v)
		assert(type(k)=="string","attribute name must be a string")
		local kind=typeOf(v)
		assert(v==nil or kind=="number" or kind=="string" or kind=="boolean" or kind=="Vector3" or kind=="Color3" or kind=="Vector2",
			"attribute "..k.." has an unsupported type "..kind)
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
		Enum=R.Enum,ColorSequence=R.ColorSequence,ColorSequenceKeypoint=R.ColorSequenceKeypoint,NumberSequence=R.NumberSequence,
		NumberSequenceKeypoint=R.NumberSequenceKeypoint} end
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

-- Estimated fit of a label's text. Gotham averages about 0.5 em per character (bold 0.55) and a line takes about
-- 1.15 em. Plain labels must fit their TextSize; TextScaled labels must fit at a size >= MinTextSize.
-- An estimate, not a Studio measurement.
local function textFits(label)
	local text=tostring(label.Text or "")
	if text=="" then return true,0 end
	local bold=label.Font=="Enum.Font.GothamBold"
	local factor=if bold then 0.55 else 0.5
	local width,height=label.Size.X.Offset,label.Size.Y.Offset
	if label.Size.X.Scale~=0 or label.Size.Y.Scale~=0 then
		local parentSize=label.Parent and label.Parent.Size
		assert(parentSize and parentSize.X.Scale==1 and parentSize.Y.Scale==1,"textFits: scale sizes only inside a full-size card")
		local gui=label.Parent.Parent
		width+=label.Size.X.Scale*gui.Size.X.Offset;height+=label.Size.Y.Scale*gui.Size.Y.Offset
	end
	local function lines(size)
		local perLine=math.max(1,math.floor(width/(size*factor)))
		local count,current=1,0
		for word in string.gmatch(text,"%S+") do
			local n=utf8.len(word) or #word
			if current==0 then
				current=n
				while current>perLine do count+=1;current-=perLine end
			elseif current+1+n<=perLine then
				current+=1+n
			else
				count+=1;current=n
				while current>perLine do count+=1;current-=perLine end
			end
		end
		return count
	end
	local function fitsAt(size)
		local n=lines(size)
		if not label.TextWrapped and n>1 then return false end
		return n*size*1.15<=height+0.5
	end
	if label.TextScaled then
		local limit=label:FindFirstChild("SizeLimit")
		local maxSize=if limit then limit.MaxTextSize else 100
		local minSize=if limit then limit.MinTextSize else 1
		for size=maxSize,minSize,-0.5 do if fitsAt(size) then return true,size end end
		return false,minSize
	end
	return fitsAt(label.TextSize),label.TextSize
end

---------------------------------------------------------------------------------------------------
-- Fixture descriptor: the saved v2 geometry (node names, banks, y/z, omega, dominant channels and the
-- 37 coupling edges measured from RoAlgoV2_SPY_1791205420530 native.config), shaped like SpringState.describe.
-- Projections are simplified to the single +0.72 dominant term; this fixture is synthetic.
---------------------------------------------------------------------------------------------------
local GEOMETRY=mockRoblox()
local function Vector3new(x,y,z) return GEOMETRY.Vector3.new(x,y,z) end
local DRIVE_NAMES={"trend","immediateReturn","rangeActivity","volume","peerRelative","hourlyContext","dailyTrend","regimeStress"}
local BANK_CHANNELS={{2,3,4},{1,5,6},{7,8,1}}
local DIRECTIONAL={[1]=true,[4]=true,[7]=true,[9]=true,[11]=true,[12]=true,[14]=true,[15]=true,[17]=true,[19]=true,[20]=true,[22]=true,[23]=true}
local OMEGA={4.25,4.4642857142857135,4.678571428571429,4.892857142857142,5.107142857142857,5.321428571428571,5.5357142857142865,5.75,
	2.125,2.2321428571428568,2.3392857142857144,2.446428571428571,2.5535714285714284,2.6607142857142856,2.7678571428571432,2.875,
	1.0625,1.1160714285714284,1.1696428571428572,1.2232142857142856,1.2767857142857142,1.3303571428571428,1.3839285714285716,1.4375}
local function deepFreeze(t) for _,v in t do if type(v)=="table" then deepFreeze(v) end end;if not table.isfrozen(t) then table.freeze(t) end;return t end
local function fixtureDescriptor(mutate)
	local bankNames={"Fast","Medium","Slow"}
	local nodes={}
	for i=1,24 do
		local bank=math.ceil(i/8);local column=(i-1)%8+1
		local channel=BANK_CHANNELS[bank][(column-1)%3+1]
		local projection={0,0,0,0,0,0,0,0};projection[channel]=0.72
		nodes[i]={index=i,name=bankNames[bank]..string.format("%02d",column),bank=bank,bankName=bankNames[bank],omega=OMEGA[i],
			y=(3-bank)*256,z=(column-1)*256,projection=projection,dominantChannel=channel,dominantName=DRIVE_NAMES[channel],
			dominantCoefficient=0.72,directional=DIRECTIONAL[i]==true}
	end
	local edges={}
	for bank=1,3 do for column=1,7 do local a=(bank-1)*8+column;table.insert(edges,{a=a,b=a+1}) end end
	for i=1,16 do table.insert(edges,{a=i,b=i+8}) end
	local directional={}
	for i=1,24 do if DIRECTIONAL[i] then table.insert(directional,i) end end
	local d={schema="spring-v2-descriptor-1",nodeCount=24,D=64,spacing=256,nodes=nodes,edges=edges,directional=directional,
		driveNames=table.clone(DRIVE_NAMES)}
	if mutate then mutate(d) end
	return deepFreeze(d)
end
local DESCRIPTOR=fixtureDescriptor()

local HEADERS={
	recorded_native="Recorded native physics · 5-minute observations · no live simulation.",
	artificial_intervention="Artificial state intervention · not a recording",
	numerical="Numerical comparator · not native physics",
	market_baseline="Market-only baseline · no physical input",
	no_trade="No-trade baseline · no physical input",
	synthetic_fixture="Synthetic fixture · not historical evidence",
}
local function apply(r,over)
	-- false in an override means "remove this field" (a nil in a table constructor overrides nothing).
	if over then for k,val in over do if val==false then r[k]=nil else r[k]=val end end end
	return r
end
local function row(over)
	local x,v,c={}, {}, {}
	for i=1,24 do
		x[i]=(i-12.5)/10 -- distinct per node so an index mix-up moves the wrong marker
		v[i]=(13-i)/50
		c[i]=if DIRECTIONAL[i] then (if i%2==0 then 1 else -1)*i/1000 else 0
	end
	return apply({index=412,t=1733153700,availableT=1733154000,label="2024-12-02 10:35 ET",day="2024-12-02",partition="training_retrospective",
		runId="coupled",runKind="recorded_native",runLabel="Coupled · recorded native",header=HEADERS.recorded_native,sampleId="coupled:412",
		x=x,v=v,diagnostics={valid=true,score=0.0123,bankScores={0.05,-0.02,0.01},nodeContributions=c},
		thresholds={entry=0.1129,exit=0.0508,bankDeadband=0.0282},
		policy={setup="none",warmup=40,posConfirm=0,negConfirm=0,longExit=0,shortExit=0},
		intent={action="HOLD",source="physics",reason="no_setup"},final={action="HOLD",source="physics",reason="no_setup",overridden=false,riskConditions={}},
		position=0,holdBars=0,equity=1,executions={},
		evidence={implementationStatus="history_verified",physicsDependence="demonstrated",marketEvidence="development_only_no_fresh_holdout"}},over)
end
local function baselineRow(kind,over)
	local r=row({runId=if kind=="market_baseline" then "ema_baseline" else "no_trade",runKind=kind,header=HEADERS[kind],
		runLabel=if kind=="market_baseline" then "EMA trend baseline" else "No trade",sampleId=false,x=false,v=false,
		diagnostics={valid=true,score=if kind=="market_baseline" then 0.2 else nil,bankScores=if kind=="market_baseline" then {0.3,0.2,0.1} else nil}})
	return apply(r,over)
end
local function filled(value) local out={} for i=1,24 do out[i]=value end return out end
local function zeros() return filled(0) end

local function mount(options)
	local R=mockRoblox()
	local workspace=R.root("Workspace")
	options=options or {}
	options.env=options.env or R.env()
	local view=SpringReplayView.mount(workspace,DESCRIPTOR,options)
	return R,workspace,view
end
local function model(workspace) return workspace:FindFirstChild("RoAlgoSpringReplay") end
local function partsOf(m)
	local out={}
	for _,x in m:GetDescendants() do if x:IsA("BasePart") then table.insert(out,x) end end
	return out
end
local function markers(m)
	local out={}
	for i=1,24 do out[i]=m:FindFirstChild("Nodes"):FindFirstChild(string.format("Node%02d",i)) end
	return out
end
local function tails(m)
	local out={}
	for i=1,24 do out[i]=m:FindFirstChild("Tails"):FindFirstChild(string.format("Tail%02d",i)) end
	return out
end
local function couplingBeams(m)
	local out={}
	for _,x in m:FindFirstChild("Coupling"):GetChildren() do if x.ClassName=="Beam" then table.insert(out,x) end end
	return out
end
local function card(m,i) return m:FindFirstChild("Labels"):FindFirstChild(string.format("Label%02d",i)):FindFirstChild("Card") end
local function enabledCount(list) local n=0 for _,b in list do if b.Enabled then n+=1 end end return n end
local function textOf(instance)
	local parts={}
	for _,x in instance:GetDescendants() do if x.ClassName=="TextLabel" then table.insert(parts,tostring(x.Text)) end end
	return table.concat(parts,"\n")
end
local function headerLine(m,name) return m:FindFirstChild("Header"):FindFirstChild("Card"):FindFirstChild(name) end
local function rgbOf(c) return {c.R,c.G,c.B} end
local function sameColor(a,b,e)
	e=e or 1e-9
	return math.abs(a[1]-b[1])<=e and math.abs(a[2]-b[2])<=e and math.abs(a[3]-b[3])<=e
end
local function colorDistance(a,b) return math.sqrt((a[1]-b[1])^2+(a[2]-b[2])^2+(a[3]-b[3])^2) end
local function keyColor(seq,k) return rgbOf(seq.Keypoints[k].Value) end
local function keyNumber(seq,k) return seq.Keypoints[k].Value end
local PALETTE=SpringReplayView.PALETTE
local STYLE=SpringReplayView.STYLE

local ALLOWED_CLASSES={Model=true,Folder=true,Part=true,Attachment=true,Beam=true,BillboardGui=true,Frame=true,TextLabel=true,
	UICorner=true,UIStroke=true,UITextSizeConstraint=true}
local FORBIDDEN_PATTERNS={"Constraint","Force","Torque","Weld","Motor","Body","Align","Velocity","Snap","Glue","Joint"}

-- Pinhole projection through the model's own framing attributes (vertical FOV, 16:9 viewport).
local function cross(a,b) return Vector3new(a.Y*b.Z-a.Z*b.Y,a.Z*b.X-a.X*b.Z,a.X*b.Y-a.Y*b.X) end
local function dot(a,b) return a.X*b.X+a.Y*b.Y+a.Z*b.Z end
local function cameraOf(m)
	local focus,eye,fov=m:GetAttribute("FocusPosition"),m:GetAttribute("ViewPosition"),m:GetAttribute("ViewFieldOfView")
	local f=(focus-eye).Unit
	local r=cross(f,Vector3new(0,1,0)).Unit
	return {eye=eye,f=f,r=r,u=cross(r,f),tanHalf=math.tan(math.rad(fov)/2)}
end
local function project(cam,p,W,H)
	local rel=p-cam.eye
	local z=dot(rel,cam.f)
	assert(z>1,"point behind or at the camera")
	local x=dot(rel,cam.r)/(z*cam.tanHalf*(W/H))
	local y=dot(rel,cam.u)/(z*cam.tanHalf)
	return (x+1)/2*W,(1-y)/2*H
end

---------------------------------------------------------------------------------------------------
test("mount builds one RoAlgoSpringReplay model under the given parent and nothing else",function()
	local R,workspace,view=mount()
	local children=workspace:GetChildren()
	assert(#children==1 and children[1].Name=="RoAlgoSpringReplay" and children[1].ClassName=="Model")
	assert(view.model==children[1])
	assert(R.writes(workspace)==0,"the parent's own properties must not be written")
	for _,inst in R.created do
		assert(inst==view.model or inst:IsDescendantOf(view.model),"created instance outside the model: "..tostring(inst))
	end
	assert(view.model:GetAttribute("SpringReplayView")==true and view.model:GetAttribute("VisualOnly")==true)
end)

test("every part is anchored, non-colliding, non-query, non-touch and locked, before and after updates",function()
	local _,workspace,view=mount()
	local function check()
		local parts=partsOf(model(workspace))
		assert(#parts==24*2+2,"24 markers, 24 rest ticks, the focus and the header anchor expected, got "..#parts)
		for _,p in parts do
			assert(p.ClassName=="Part","only plain Parts: "..p.ClassName)
			assert(p.Anchored==true and p.CanCollide==false and p.CanQuery==false and p.CanTouch==false and p.CastShadow==false,
				"decoration flags missing on "..p.Name)
			assert(p.Locked==true,"decoration is locked against accidental selection: "..p.Name)
			assert(p:GetAttribute("VisualOnly")==true)
		end
	end
	check()
	view:update(row())
	view:update(row({runId="independent",sampleId="independent:412"}))
	view:update(baselineRow("market_baseline"))
	check()
end)

test("no constraint, force or joint class is ever created",function()
	local R,_,view=mount()
	view:update(row());view:update(baselineRow("no_trade"));view:destroy()
	for className,count in R.classes do
		assert(ALLOWED_CLASSES[className],"class outside the decoration allowlist: "..className.." x"..count)
		-- UI layout constraints (UITextSizeConstraint) are GUI sizing rules, not physics; everything else is checked.
		local physicsName=if string.sub(className,1,2)=="UI" then "" else className
		for _,pattern in FORBIDDEN_PATTERNS do assert(not string.find(physicsName,pattern,1,true),"forbidden class "..className) end
	end
	assert(R.classes.Part==50 and R.classes.Beam==24+37 and R.classes.BillboardGui==25 and R.classes.Attachment==48)
end)

test("24 node markers carry saved identities and rest offsets from the descriptor (D14)",function()
	local _,workspace,view=mount()
	local m=model(workspace)
	local list=markers(m)
	local origin=m:GetAttribute("DisplayOrigin")
	local ls=m:GetAttribute("LayoutScale")
	assert(ls==0.125 and m:GetAttribute("VisualScale")==0.25 and m:GetAttribute("DisplacementStudsPerUnit")==16)
	assert(m:GetAttribute("RestGeometry")=="rest offsets derived from saved config; capture origin not saved")
	for i=1,24 do
		local node=DESCRIPTOR.nodes[i]
		local marker=list[i]
		assert(marker and marker:GetAttribute("NodeIndex")==i and marker:GetAttribute("NodeName")==node.name and marker:GetAttribute("Bank")==node.bank)
		assert(marker:GetAttribute("DirectVote")==node.directional)
		local p=marker.CFrame.Position
		near(p.X,origin.X);near(p.Y,origin.Y+node.y*ls);near(p.Z,origin.Z+node.z*ls)
		local restTick=m:FindFirstChild("Nodes"):FindFirstChild(string.format("Rest%02d",i))
		near(restTick.CFrame.Position.X,origin.X);near(restTick.CFrame.Position.Y,p.Y);near(restTick.CFrame.Position.Z,p.Z)
	end
	assert(view.counts.nodes==24 and m:GetAttribute("Nodes")==24)
end)

test("37 coupling beams join exactly the descriptor's edges between node Center attachments",function()
	local _,workspace=mount()
	local m=model(workspace)
	local beams=couplingBeams(m)
	assert(#beams==37,"37 coupling beams expected, got "..#beams)
	local wanted={}
	for _,e in DESCRIPTOR.edges do wanted[string.format("%02d_%02d",e.a,e.b)]=e end
	local seen={}
	for _,beam in beams do
		local a,b=beam.Attachment0,beam.Attachment1
		assert(a and b and a.ClassName=="Attachment" and b.ClassName=="Attachment" and a.Name=="Center" and b.Name=="Center")
		local key=string.format("%02d_%02d",a.Parent:GetAttribute("NodeIndex"),b.Parent:GetAttribute("NodeIndex"))
		assert(wanted[key] and not seen[key],"unexpected or duplicate connector "..key)
		assert(beam.Name=="Couple"..key and beam:GetAttribute("RestGap")==256)
		seen[key]=true
	end
end)

test("24 tails run from each node's axial anchor, 512 capture studs on -X scaled by the layout, to the node",function()
	local _,workspace,view=mount()
	local m=model(workspace)
	local list,tailList=markers(m),tails(m)
	assert(m:GetAttribute("AnchorOffset")==512 and m:GetAttribute("AnchorDisplayStuds")==64 and view.anchorDisplay==64)
	for i=1,24 do
		local tail=tailList[i]
		assert(tail and tail.ClassName=="Beam" and tail:GetAttribute("NodeIndex")==i)
		local anchor,center=tail.Attachment0,tail.Attachment1
		assert(anchor.Name=="Anchor" and anchor.Parent.Name==string.format("Rest%02d",i),"tail starts at the node's own anchor")
		assert(center.Name=="Center" and center.Parent==list[i],"tail ends at the node's own marker")
		local restPosition=anchor.Parent.CFrame.Position
		local world=restPosition+anchor.Position
		near(world.X,restPosition.X-64);near(world.Y,restPosition.Y);near(world.Z,restPosition.Z)
		assert(tail.Enabled==false,"no tail before a row is shown")
	end
	-- descriptor.anchorOffset and options.anchorOffset override the contract default.
	local R=mockRoblox()
	local ws=R.root("Workspace")
	local other=SpringReplayView.mount(ws,fixtureDescriptor(function(d) d.anchorOffset=256 end),{env=R.env()})
	assert(other.anchorDisplay==32 and model(ws):GetAttribute("AnchorOffset")==256)
	other:destroy()
	other=SpringReplayView.mount(ws,DESCRIPTOR,{env=R.env(),anchorOffset=400,layoutScale=0.25})
	assert(other.anchorDisplay==100)
	other:destroy()
end)

test("update moves each marker to rest + visualScale*D*x along X only",function()
	local R=mockRoblox()
	local workspace=R.root("Workspace")
	local view=SpringReplayView.mount(workspace,DESCRIPTOR,{env=R.env(),origin=R.Vector3.new(100,20,-50),visualScale=0.5,layoutScale=0.2})
	local m=model(workspace)
	local r=row()
	view:update(r)
	local list=markers(m)
	for i=1,24 do
		local p=list[i].CFrame.Position
		near(p.X,100+0.5*64*r.x[i]);near(p.Y,20+DESCRIPTOR.nodes[i].y*0.2);near(p.Z,-50+DESCRIPTOR.nodes[i].z*0.2)
		near(list[i]:GetAttribute("X"),r.x[i]);near(list[i]:GetAttribute("V"),r.v[i])
	end
	-- A second row moves every marker again; nothing keeps the previous row's pose.
	local r2=row({index=413,sampleId="coupled:413"})
	for i=1,24 do r2.x[i]=-r.x[i]*2 end
	view:update(r2)
	for i=1,24 do near(list[i].CFrame.Position.X,100+0.5*64*r2.x[i]) end
	assert(m:GetAttribute("RowIndex")==413 and m:GetAttribute("SampleId")=="coupled:413")
end)

test("the model's identity attributes follow the shown row exactly",function()
	local _,workspace,view=mount()
	local m=model(workspace)
	view:update(row({index=900,t=1734000000,availableT=1734000300,sampleId="coupled:900",partition="validation",
		diagnostics={valid=true,score=-0.0421,bankScores={0,0,0},nodeContributions=zeros()}}))
	assert(m:GetAttribute("RowIndex")==900 and m:GetAttribute("ObservationT")==1734000000,"ObservationT is the bar time t")
	assert(m:GetAttribute("RunId")=="coupled" and m:GetAttribute("RunKind")=="recorded_native")
	assert(m:GetAttribute("Partition")=="validation" and m:GetAttribute("SampleId")=="coupled:900")
	assert(m:GetAttribute("Score")==-0.0421)
	view:update(baselineRow("no_trade",{index=901,t=1734000300,availableT=1734000600}))
	assert(m:GetAttribute("RowIndex")==901 and m:GetAttribute("ObservationT")==1734000300 and m:GetAttribute("RunId")=="no_trade")
	assert(m:GetAttribute("RunKind")=="no_trade" and m:GetAttribute("SampleId")=="" and m:GetAttribute("Score")==nil)
	assert(m:GetAttribute("Partition")=="training_retrospective")
end)

test("coupled runs show all 37 connectors; the independent run and rows without a state show none (D20)",function()
	local _,workspace,view=mount()
	local m=model(workspace)
	local beams=couplingBeams(m)
	view:update(row())
	assert(enabledCount(beams)==37 and m:GetAttribute("CouplingVisible")==true)
	assert(enabledCount(tails(m))==24)
	view:update(row({runId="independent",runLabel="Independent · recorded native",sampleId="independent:412"}))
	assert(enabledCount(beams)==0,"independent run must draw 0 coupling connectors")
	assert(enabledCount(tails(m))==24,"the independent rig still has its anchor springs")
	assert(m:GetAttribute("CouplingVisible")==false)
	assert(string.find(headerLine(m,"Notice").Text,"coupling removed",1,true))
	for _,kind in {"artificial_intervention","numerical","synthetic_fixture"} do
		view:update(row({runId=kind.."_run",runKind=kind,header=HEADERS[kind],partition=if kind=="synthetic_fixture" then "synthetic" else "validation"}))
		assert(enabledCount(beams)==37,kind.." keeps the coupled topology")
	end
	-- An invalid sample without x draws no connectors and no tails: nothing implies a state at rest.
	view:update(row({x=false,v=false,diagnostics={valid=false,reason="names_mismatch"}}))
	assert(enabledCount(beams)==0 and enabledCount(tails(m))==0 and m:GetAttribute("CouplingVisible")==false)
	local notice=headerLine(m,"Notice")
	assert(string.find(notice.Text,"Invalid physics sample",1,true) and string.find(notice.Text,"names_mismatch",1,true))
	assert(sameColor(rgbOf(notice.TextColor3),PALETTE.negative),"invalid notice is shown in the warning colour")
	for i,marker in markers(m) do
		assert(sameColor(rgbOf(marker.Color),PALETTE.invalid),"invalid sample markers use the invalid colour: "..i)
		near(marker.CFrame.Position.X,m:GetAttribute("DisplayOrigin").X)
	end
end)

test("header billboard shows the run kind's provenance header, notice and the stretch legend",function()
	local _,workspace,view=mount()
	local m=model(workspace)
	local header=m:FindFirstChild("Header")
	assert(header.ClassName=="BillboardGui" and header.AlwaysOnTop==true and header.MaxDistance==0)
	assert(header.Enabled==false,"the header card is hidden by default (owner request, 2026-10-05)")
	do
		local _,ws2=mount({showHeader=true})
		assert(model(ws2):FindFirstChild("Header").Enabled==true,"options.showHeader brings the header card back")
	end
	assert(string.sub(headerLine(m,"Legend").Text,1,23)=="spring colour = stretch","the legend states that colour encodes stretch")
	assert(m:GetAttribute("Legend")==headerLine(m,"Legend").Text)
	for kind,text in HEADERS do
		local r=if kind=="market_baseline" or kind=="no_trade" then baselineRow(kind)
			else row({runId=kind,runKind=kind,header=text,partition="evaluation"})
		view:update(r)
		assert(headerLine(m,"Title").Text==text,"header for "..kind)
		assert(m:GetAttribute("RunKind")==kind)
	end
	view:update(row({partition="training_retrospective"}))
	local detail=headerLine(m,"Detail").Text
	assert(string.find(detail,"retrospective in-sample",1,true))
	assert(string.find(detail,"2024-12-02 10:35 ET",1,true) and string.find(detail,"coupled:412",1,true) and string.find(detail,"obs 412",1,true))
	assert(headerLine(m,"Notice").Text=="Endpoint state at this observation · stepped, no visual interpolation")
	local scope=headerLine(m,"Scope").Text
	assert(string.find(scope,"rest offsets derived from saved config; capture origin not saved",1,true))
	assert(string.find(scope,"16 studs per unit (2x layout scale)",1,true),"the extra visual scale is stated")
	assert(view.scaleNote and string.find(view.scaleNote,"16 studs per unit",1,true))
end)

test("baseline and no-trade rows grey the rig at rest and say no physical input",function()
	local _,workspace,view=mount()
	local m=model(workspace)
	local list=markers(m)
	local beams=couplingBeams(m)
	local origin=m:GetAttribute("DisplayOrigin")
	view:update(row())
	for _,kind in {"market_baseline","no_trade"} do
		view:update(baselineRow(kind))
		local first=list[1].Color
		for i=1,24 do
			local marker=list[i]
			near(marker.CFrame.Position.X,origin.X)
			assert(marker.Color.R==first.R and marker.Color.G==first.G and marker.Color.B==first.B,"every marker the same grey")
			assert(math.abs(marker.Color.R-marker.Color.G)<0.05 and math.abs(marker.Color.G-marker.Color.B)<0.05,"grey, not a sign colour")
			assert(marker:GetAttribute("TopContributor")==0 and marker.Material=="Enum.Material.SmoothPlastic")
			assert(marker:GetAttribute("X")==nil,"no state value under a baseline")
			local vote=card(m,i):FindFirstChild("Vote").Text
			if DIRECTIONAL[i] then assert(vote=="no physical input","voting node "..i.." says no physical input") else
				assert(vote=="visible, not a direct vote","non-voting node "..i.." keeps its D23 mark") end
		end
		assert(enabledCount(beams)==0,"no unlabelled coupled rig under a baseline")
		assert(enabledCount(tails(m))==0,"no spring stretch is drawn under a baseline")
		assert(m:GetAttribute("PhysicalInput")==false)
		local notice=headerLine(m,"Notice")
		assert(notice.Text=="Rig greyed at rest · no physical input feeds this run")
		assert(sameColor(rgbOf(notice.TextColor3),PALETTE.amber))
	end
	view:update(row())
	assert(m:GetAttribute("PhysicalInput")==true and enabledCount(beams)==37)
	assert(list[22].Color.G>list[22].Color.R,"a positive voting contribution is green again after leaving the baseline")
end)

test("contributions colour and scale voting markers; the top three are highlighted",function()
	local _,workspace,view=mount()
	local m=model(workspace)
	local list=markers(m)
	local r=row()
	view:update(r)
	local c=r.diagnostics.nodeContributions
	local size22,size20=list[22].Size.X,list[20].Size.X
	assert(c[22]>0 and list[22].Color.G>list[22].Color.R,"positive contribution is green")
	assert(c[23]<0 and list[23].Color.R>list[23].Color.G,"negative contribution is red")
	assert(math.abs(c[22])>math.abs(c[20]) and size22>size20,"larger |contribution| draws a larger marker")
	assert(list[23]:GetAttribute("TopContributor")==1 and list[22]:GetAttribute("TopContributor")==2 and list[20]:GetAttribute("TopContributor")==3)
	assert(list[19]:GetAttribute("TopContributor")==0,"the fourth-ranked node is not highlighted")
	assert(list[1]:GetAttribute("TopContributor")==0)
	for i=1,24 do
		local top=list[i]:GetAttribute("TopContributor")>0
		assert(list[i].Material==(if top then "Enum.Material.Neon" else "Enum.Material.SmoothPlastic"),"Neon marks exactly the top three: "..i)
		local stroke=card(m,i):FindFirstChild("Stroke")
		assert(stroke.Thickness==(if top then 2.5 else 1),"label outline thickens for the top three: "..i)
	end
	near(list[22]:GetAttribute("Contribution"),c[22])
	-- Non-voting nodes keep a fixed small size and a bank tint, never a sign colour.
	assert(list[2].Size.X<size20 and list[2]:GetAttribute("Contribution")==0)
	for i=1,24 do
		if not DIRECTIONAL[i] then
			local bank=DESCRIPTOR.nodes[i].bank
			local tint=rgbOf(list[i].Color)
			assert(colorDistance(tint,PALETTE.positive)>0.15 and colorDistance(tint,PALETTE.negative)>0.15,"non-voting node "..i.." takes no sign colour")
			for j=1,24 do
				if not DIRECTIONAL[j] then
					local same=DESCRIPTOR.nodes[j].bank==bank
					assert(sameColor(tint,rgbOf(list[j].Color))==same,"non-voting tint follows the bank: "..i.." vs "..j)
				end
			end
		end
	end
	assert(card(m,2):FindFirstChild("Vote").Text=="visible, not a direct vote")
	assert(card(m,22):FindFirstChild("Vote").Text==string.format("contribution %+.4f",c[22]))
end)

test("ranking edge cases: all-zero rows highlight nothing, ties go to the lower index, tiny rows stay small",function()
	local _,workspace,view=mount()
	local m=model(workspace)
	local list=markers(m)
	view:update(row({runId="zero",runKind="artificial_intervention",header=HEADERS.artificial_intervention,sampleId="zero:412",
		x=zeros(),v=zeros(),diagnostics={valid=true,score=0,bankScores={0,0,0},nodeContributions=zeros()}}))
	for i=1,24 do assert(list[i]:GetAttribute("TopContributor")==0 and list[i].Material=="Enum.Material.SmoothPlastic","zero row highlights nothing: "..i) end
	local tie=zeros()
	tie[4]=0.01;tie[1]=-0.01;tie[7]=0.01;tie[9]=0.01;tie[23]=-0.002
	view:update(row({diagnostics={valid=true,score=0.0,bankScores={0,0,0},nodeContributions=tie}}))
	assert(list[1]:GetAttribute("TopContributor")==1 and list[4]:GetAttribute("TopContributor")==2 and list[7]:GetAttribute("TopContributor")==3)
	assert(list[9]:GetAttribute("TopContributor")==0,"a tie beyond the top three stays unhighlighted")
	-- Contributions far below the entry threshold draw markers near the minimum size.
	local tiny=zeros()
	tiny[4]=0.0001;tiny[12]=-0.0002
	view:update(row({diagnostics={valid=true,score=0,bankScores={0,0,0},nodeContributions=tiny}}))
	assert(list[12].Size.X<view.markerDiameter*0.8,"a contribution far below entry is not drawn full-size")
end)

test("persistent node labels: compact translucent contract cards with D23 text and non-voting marks",function()
	local _,workspace=mount()
	local m=model(workspace)
	local labels=m:FindFirstChild("Labels"):GetChildren()
	assert(#labels==24)
	local voting,nonVoting=0,0
	for i=1,24 do
		local node=DESCRIPTOR.nodes[i]
		local gui=m:FindFirstChild("Labels"):FindFirstChild(string.format("Label%02d",i))
		assert(gui.ClassName=="BillboardGui" and gui.MaxDistance==0 and gui.AlwaysOnTop==true and gui.Adornee)
		-- Contract label style: about 84x29 px (75% of the v2 112x38 card), card ~35%, text ~15%, outline ~40% transparent.
		assert(gui.Size.X.Scale==0 and gui.Size.Y.Scale==0 and math.abs(gui.Size.X.Offset-84)<=8 and math.abs(gui.Size.Y.Offset-29)<=3,
			"compact card about 84x29 px")
		local c=gui:FindFirstChild("Card")
		near(c.BackgroundTransparency,0.35,0.05)
		near(c:FindFirstChild("Stroke").Transparency,0.4,0.05)
		local texts=0
		for _,x in c:GetChildren() do
			if x.ClassName=="TextLabel" then
				texts+=1
				near(x.TextTransparency,0.15,0.05)
				local fits,size=textFits(x)
				assert(fits and size>=6,string.format("label %d %s text does not fit the card (%s)",i,x.Name,x.Text))
			end
		end
		assert(texts==2,"identity and vote lines only")
		assert(c:FindFirstChild("Identity").Text==node.name.." · dominant input: "..DRIVE_NAMES[node.dominantChannel])
		local vote=c:FindFirstChild("Vote").Text
		if node.directional then voting+=1;assert(vote~="visible, not a direct vote") else nonVoting+=1;assert(vote=="visible, not a direct vote") end
	end
	assert(voting==13 and nonVoting==11)
	assert(card(m,1):FindFirstChild("Identity").Text=="Fast01 · dominant input: immediateReturn")
	assert(card(m,11):FindFirstChild("Identity").Text=="Medium03 · dominant input: hourlyContext")
	assert(card(m,18):FindFirstChild("Identity").Text=="Slow02 · dominant input: regimeStress")
	for _,name in {"Title","Detail","Notice","Legend","Scope"} do
		local fits=textFits(headerLine(m,name))
		assert(fits,"header line "..name.." overflows: "..headerLine(m,name).Text)
	end
end)

test("tails, couplings and markers are clearly visible on a physical row (contract tail rule)",function()
	local _,workspace,view=mount()
	local m=model(workspace)
	view:update(row())
	local ls=m:GetAttribute("LayoutScale")
	for i,tail in tails(m) do
		assert(tail.Enabled==true,"tail "..i.." shown")
		assert(tail.Width0/ls>=2.5 and tail.Width1/ls>=2.5,"tail "..i.." at least 2.5 studs wide at v2 scale")
		for k=1,#tail.Transparency.Keypoints do assert(keyNumber(tail.Transparency,k)<=0.45,"tail "..i.." transparency <= 0.45") end
		assert(tail.LightInfluence==0 and tail.FaceCamera==true)
	end
	for _,beam in couplingBeams(m) do
		assert(beam.Enabled==true and beam.Width0>0 and beam.Width1>0 and beam.Width0/ls>=2.5)
		for k=1,#beam.Transparency.Keypoints do assert(keyNumber(beam.Transparency,k)<=0.45,beam.Name.." transparency <= 0.45") end
	end
	for i,marker in markers(m) do
		assert(marker.Transparency<0.5 and marker.Size.X>0.5,"marker "..i.." visible")
	end
	for i=1,24 do
		local restTick=m:FindFirstChild("Nodes"):FindFirstChild(string.format("Rest%02d",i))
		assert(restTick.Transparency<1 and restTick.Size.Y>1,"rest tick "..i.." visible")
	end
end)

-- Terminal palette (owner request, 2026-10-05): springs are grey at rest (PALETTE.springRest); lengthened ramps through the
-- amber key to the coral key (yellow), compressed through the cyan key (blue) to the violet key (bright cyan).
test("tail colour encodes signed anchor-spring stretch D*x: grey at rest, warm ramp lengthened, cool ramp compressed",function()
	local _,workspace,view=mount()
	local m=model(workspace)
	local x=zeros()
	-- Fast04 +0.75 (full stretch), Fast05 -0.75 (full compression), Fast06 +0.375 (amber), Fast07 -0.375 (cyan),
	-- Medium01 +3 (clamped full), Slow01 at rest.
	x[4]=0.75;x[5]=-0.75;x[6]=0.375;x[7]=-0.375;x[9]=3
	view:update(row({x=x,v=zeros(),diagnostics={valid=true,score=0,bankScores={0,0,0},nodeContributions=zeros()}}))
	local list=tails(m)
	local function nodeEnd(i) return keyColor(list[i].Color,2) end
	local function anchorEnd(i) return keyColor(list[i].Color,1) end
	local bank=PALETTE.bank
	for _,i in {1,2,3,8,17,24} do
		assert(sameColor(nodeEnd(i),PALETTE.springRest) and sameColor(anchorEnd(i),PALETTE.springRest),"rest tail "..i.." is spring-rest grey")
		near(keyNumber(list[i].Transparency,2),STYLE.tailRestTransparency);near(list[i].LightEmission,0.25)
		near(list[i]:GetAttribute("Stretch"),0)
	end
	assert(sameColor(nodeEnd(4),PALETTE.coral),"full lengthening is coral at the node end")
	assert(sameColor(nodeEnd(5),PALETTE.violet),"full compression is violet at the node end")
	assert(sameColor(nodeEnd(6),PALETTE.amber),"half lengthening is amber")
	assert(sameColor(nodeEnd(7),PALETTE.cyan),"half compression is cyan")
	assert(sameColor(nodeEnd(9),PALETTE.coral),"stretch beyond 0.75 D stays at full colour")
	near(list[4]:GetAttribute("Stretch"),64*0.75);near(list[5]:GetAttribute("Stretch"),-64*0.75)
	-- The colours really are warm and cool, so a swapped palette fails too.
	assert(PALETTE.coral[1]>0.9 and PALETTE.coral[3]<0.5 and PALETTE.amber[1]>0.9 and PALETTE.amber[3]<0.5)
	assert(PALETTE.violet[3]>0.9 and PALETTE.violet[1]<0.4 and PALETTE.cyan[3]>0.9 and PALETTE.cyan[1]<0.4)
	-- Rest grey is neutral (no hue), so stretch is the only thing the spring colour shows.
	assert(math.abs(PALETTE.springRest[1]-PALETTE.springRest[3])<0.02 and PALETTE.springRest[1]<0.4)
	for _,i in {4,5,6,7} do
		local base=PALETTE.springRest
		assert(colorDistance(anchorEnd(i),base)<colorDistance(nodeEnd(i),base),"the node end is the strongest: "..i)
	end
	near(keyNumber(list[4].Transparency,2),STYLE.tailFullTransparency);near(list[4].LightEmission,1)
	near(keyNumber(list[5].Transparency,2),STYLE.tailFullTransparency);near(list[5].LightEmission,1)
	assert(keyNumber(list[6].Transparency,2)<keyNumber(list[1].Transparency,2) and keyNumber(list[6].Transparency,2)>keyNumber(list[4].Transparency,2))
	assert(list[6].LightEmission>0.25 and list[6].LightEmission<1)
	-- Deterministic: the same row draws the same scene.
	local first=snapshot(m)
	view:update(row({x=x,v=zeros(),diagnostics={valid=true,score=0,bankScores={0,0,0},nodeContributions=zeros()}}))
	assert(snapshot(m)==first,"the same row draws an identical scene")
end)

test("coupling colour encodes extra length sqrt(T^2+(D*dx)^2)-T, hottest mid-span, full at 6 studs",function()
	local _,workspace,view=mount()
	local m=model(workspace)
	local x=zeros()
	-- Edge 1-2: dx such that the extra length is exactly 6 studs; edge 3-4: 3 studs; edge 9-10: equal x (no stretch).
	local dxFull=math.sqrt(262^2-256^2)/64
	local dxHalf=math.sqrt(259^2-256^2)/64
	x[2]=dxFull;x[4]=dxHalf;x[9]=0.4;x[10]=0.4
	view:update(row({x=x,v=zeros(),diagnostics={valid=true,score=0,bankScores={0,0,0},nodeContributions=zeros()}}))
	local function beam(a,b) return m:FindFirstChild("Coupling"):FindFirstChild(string.format("Couple%02d_%02d",a,b)) end
	local full,half,still=beam(1,2),beam(3,4),beam(9,10)
	near(full:GetAttribute("ExtraLength"),6,1e-9);near(half:GetAttribute("ExtraLength"),3,1e-9);near(still:GetAttribute("ExtraLength"),0)
	assert(#full.Color.Keypoints==3 and full.Color.Keypoints[2].Time==0.5)
	assert(sameColor(keyColor(full.Color,2),PALETTE.coral),"full extra length is coral mid-span")
	assert(sameColor(keyColor(half.Color,2),PALETTE.amber),"half of full is amber mid-span")
	local base=PALETTE.springRest
	assert(colorDistance(keyColor(full.Color,1),base)<colorDistance(keyColor(full.Color,2),base),"hottest mid-span, cooler ends")
	assert(sameColor(keyColor(still.Color,1),PALETTE.springRest) and sameColor(keyColor(still.Color,3),PALETTE.springRest),"no stretch: spring-rest grey")
	assert(keyNumber(full.Transparency,2)<keyNumber(still.Transparency,2) and full.LightEmission>still.LightEmission)
	near(full.LightEmission,1);near(keyNumber(full.Transparency,2),0.12)
	-- A vertical (bank-to-bank) edge between stretched nodes: x[1]=0 vs x[9]=0.4 -> 64*0.4 = 25.6 studs transverse.
	local vertical=beam(1,9)
	near(vertical:GetAttribute("ExtraLength"),math.sqrt(256^2+25.6^2)-256,1e-9)
end)

test("the default framing shows the whole rig, its tails and labels left of the 440 px panel (D21, D25)",function()
	local _,workspace,view=mount()
	local m=model(workspace)
	local focus,eye=m:GetAttribute("FocusPosition"),m:GetAttribute("ViewPosition")
	local d=focus-eye
	local angle=math.deg(math.acos(math.abs(d.X)/d.Magnitude))
	assert(angle>=45,"view direction only "..angle.." degrees from the displacement axis")
	assert(eye.Y>focus.Y,"camera looks down onto the banks")
	local cam=cameraOf(m)
	local origin=m:GetAttribute("DisplayOrigin")
	local spu=m:GetAttribute("DisplacementStudsPerUnit")
	local ls=m:GetAttribute("LayoutScale")
	for _,size in {{1280,720},{1920,1080}} do
		local W,H=size[1],size[2]
		local freeRight=W-440
		local minX,maxX=math.huge,-math.huge
		local function inside(px,py,what)
			assert(px>=4 and px<=freeRight-4 and py>=4 and py<=H-4,string.format("%s at (%.0f,%.0f) is outside the free %dx%d area",what,px,py,freeRight,H))
		end
		for i,node in DESCRIPTOR.nodes do
			local y,z=origin.Y+node.y*ls,origin.Z+node.z*ls
			for _,units in {-2,0,2} do
				local px,py=project(cam,Vector3new(origin.X+spu*units,y,z),W,H)
				inside(px,py,string.format("node %d at x=%+d",i,units))
				minX=math.min(minX,px);maxX=math.max(maxX,px)
			end
			local ax,ay=project(cam,Vector3new(origin.X-view.anchorDisplay,y,z),W,H)
			inside(ax,ay,"anchor "..i)
			minX=math.min(minX,ax)
			-- The label card (84x29 px) sits above or below its rest point.
			local gui=m:FindFirstChild("Labels"):FindFirstChild(string.format("Label%02d",i))
			local lx,ly=project(cam,Vector3new(origin.X,y+gui.StudsOffsetWorldSpace.Y,z),W,H)
			local w,h=gui.Size.X.Offset,gui.Size.Y.Offset
			local top=ly-h/2-gui.SizeOffset.Y*h
			inside(lx-w/2,top,"label "..i.." top-left");inside(lx+w/2,top+h,"label "..i.." bottom-right")
		end
		local header=m:FindFirstChild("Header")
		local hx,hy=project(cam,header.Adornee.CFrame.Position,W,H)
		local hw,hh=header.Size.X.Offset,header.Size.Y.Offset
		local htop=hy-hh/2-header.SizeOffset.Y*hh
		inside(hx-hw/2,htop,"header top-left");inside(hx+hw/2,htop+hh,"header bottom-right")
		assert(maxX-minX>=0.4*freeRight,string.format("the rig fills too little of the free area at %dx%d (%.0f of %d px)",W,H,maxX-minX,freeRight))
	end
	-- A CameraSubject for free orbit in a playtest: an anchored part at the focus.
	assert(m:GetAttribute("CameraSubject")=="Focus")
	local subject=m:FindFirstChild("Focus")
	assert(subject and subject.Anchored==true and subject==view.focusPart and subject.CFrame.Position==focus)
	assert(m:GetAttribute("SuggestedMaxZoomDistance")>=d.Magnitude*2)
end)

test("default placement is near spawn and clear of the v2 rigs and spawn pad (D20)",function()
	local _,workspace,view=mount()
	local m=model(workspace)
	view:update(row())
	local points={}
	for _,p in partsOf(m) do table.insert(points,{p.Name,p.CFrame.Position}) end
	for i,tail in tails(m) do table.insert(points,{"anchor "..i,tail.Attachment0.Parent.CFrame.Position+tail.Attachment0.Position}) end
	for _,item in points do
		local q=item[2]
		local insideV2=q.X>=-2048-40 and q.X<=-1312+40 and q.Y>=80-40 and q.Y<=1360+40 and q.Z>=-896-40 and q.Z<=896+40
		assert(not insideV2,"replay part inside the v2 rig volume: "..item[1])
		assert(not (math.abs(q.X)<12 and math.abs(q.Z)<12 and q.Y<12),"replay part on the spawn pad")
		assert(q.Y>5,"replay part below the baseplate level")
		assert(math.abs(q.X)<600 and math.abs(q.Z)<600,"replay is near spawn")
	end
	local eye=m:GetAttribute("ViewPosition")
	assert(eye.Y>5 and math.abs(eye.X)<1000 and math.abs(eye.Z)<1000)
end)

test("update rejects malformed rows without changing anything",function()
	local _,workspace,view=mount()
	local m=model(workspace)
	view:update(row())
	local before=snapshot(m)
	local function shorter(list) local out=table.clone(list);out[#out]=nil;return out end
	local function longer(list) local out=table.clone(list);out[#out+1]=0;return out end
	local base=row()
	local nonVoting=zeros();nonVoting[2]=0.5
	local cases={
		{"x length 23",row({x=shorter(base.x)})},
		{"x length 25",row({x=longer(base.x)})},
		{"v length 23",row({v=shorter(base.v)})},
		{"x non-finite",(function() local r=row();r.x[5]=0/0;return r end)()},
		{"x infinite",(function() local r=row();r.x[24]=math.huge;return r end)()},
		{"contributions length 25",row({diagnostics={valid=true,score=0,nodeContributions=longer(base.diagnostics.nodeContributions)}})},
		{"non-voting node with a contribution",row({diagnostics={valid=true,score=0.5,nodeContributions=nonVoting}})},
		{"bank scores length 2",row({diagnostics={valid=true,score=0,bankScores={1,2}}})},
		{"missing diagnostics",row({diagnostics=false})},
		{"missing runKind",row({runKind=false})},
		{"unknown runKind",row({runKind="live_physics"})},
		{"missing index",row({index=false})},
		{"index 0",row({index=0})},
		{"fractional index",row({index=1.5})},
		{"missing t",row({t=false})},
		{"missing availableT",row({availableT=false})},
		{"missing runId",row({runId=false})},
		{"header from another kind",row({header=HEADERS.artificial_intervention})},
		{"missing header",row({header=false})},
		{"unknown partition",row({partition="holdout"})},
		{"valid physical row without x",row({x=false})},
		{"physical row without sample id",row({sampleId=false})},
		{"physical row with an empty sample id",row({sampleId=""})},
		{"missing final",row({final=false})},
		{"intent without action",row({intent={source="physics"}})},
		{"pending without action",row({pending={source="physics"}})},
		{"position 0.5",row({position=0.5})},
		{"non-finite equity",row({equity=0/0})},
		{"executions not a list",row({executions=false})},
		{"missing evidence",row({evidence=false})},
		{"non-finite entry threshold",row({thresholds={entry=0/0,exit=0.05,bankDeadband=0.02}})},
		{"baseline carrying x",baselineRow("market_baseline",{x=base.x,v=base.v})},
		{"baseline carrying contributions",baselineRow("no_trade",{diagnostics={valid=true,nodeContributions=base.diagnostics.nodeContributions}})},
		{"baseline with a physical header",baselineRow("market_baseline",{header=HEADERS.recorded_native})},
		{"not a table","row"},
	}
	for _,case in cases do
		local r=case[2]
		assert(SpringReplayView.validateRow(r,DESCRIPTOR)~=nil,"validateRow accepted: "..case[1])
		local ok,err=pcall(function() view:update(r) end)
		assert(not ok,"accepted malformed row: "..case[1])
		assert(string.find(tostring(err),"SpringReplayView",1,true),"error names the module for "..case[1])
		assert(snapshot(m)==before,"partial update on rejected row: "..case[1])
	end
	assert(SpringReplayView.validateRow(row(),DESCRIPTOR)==nil and SpringReplayView.validateRow(baselineRow("no_trade"),DESCRIPTOR)==nil)
	-- Without a descriptor the non-voting rule cannot be checked; the view always passes its own.
	assert(SpringReplayView.validateRow(row({diagnostics={valid=true,score=0.5,nodeContributions=nonVoting}}))==nil)
	-- An invalid physics sample without x is drawn as invalid, not rejected.
	view:update(row({x=false,v=false,diagnostics={valid=false,reason="names_mismatch"}}))
	assert(string.find(headerLine(m,"Notice").Text,"Invalid physics sample",1,true))
end)

test("destroy removes everything it created; update after destroy fails; destroy is idempotent",function()
	local R,workspace,view=mount()
	view:update(row())
	view:destroy()
	assert(R.live()==0,"live instances after destroy: "..R.live())
	assert(#workspace:GetChildren()==0)
	view:destroy()
	assert(not pcall(function() view:update(row()) end))
end)

test("an update after the model was removed outside the view fails and changes nothing",function()
	local R,workspace,view=mount()
	view:update(row())
	local m=model(workspace)
	m.Parent=nil
	local before=snapshot(m)
	local ok,err=pcall(function() view:update(row({index=413,sampleId="coupled:413"})) end)
	assert(not ok and string.find(tostring(err),"removed outside",1,true))
	assert(snapshot(m)==before)
	view:destroy()
	assert(R.live()==0)
end)

test("repeated mount/update/destroy cycles leave no instances",function()
	local R=mockRoblox()
	local workspace=R.root("Workspace")
	local other=R.root("Model");other.Name="RoAlgoResearchPhysics";other.Parent=workspace
	local writesBefore=R.writes(other)
	for cycle=1,5 do
		local view=SpringReplayView.mount(workspace,DESCRIPTOR,{env=R.env()})
		view:update(row({index=cycle,sampleId="coupled:"..cycle}))
		view:update(baselineRow("no_trade",{index=cycle}))
		view:destroy()
		assert(R.live()==0,"cycle "..cycle.." leaked "..R.live().." instances")
	end
	assert(#workspace:GetChildren()==1 and workspace:GetChildren()[1]==other and R.writes(other)==writesBefore,
		"the v2 presentation must be untouched")
end)

test("a stale replay model is replaced; a foreign model of that name is refused and untouched",function()
	local R=mockRoblox()
	local workspace=R.root("Workspace")
	local first=SpringReplayView.mount(workspace,DESCRIPTOR,{env=R.env()})
	local second=SpringReplayView.mount(workspace,DESCRIPTOR,{env=R.env()})
	assert(R.isDestroyed(first.model) and #workspace:GetChildren()==1 and workspace:GetChildren()[1]==second.model)
	second:destroy()
	assert(R.live()==0)
	local foreign=R.root("Model");foreign.Name="RoAlgoSpringReplay";foreign.Parent=workspace
	local writes=R.writes(foreign)
	local ok,err=pcall(function() SpringReplayView.mount(workspace,DESCRIPTOR,{env=R.env()}) end)
	assert(not ok and string.find(tostring(err),"refusing",1,true))
	assert(not R.isDestroyed(foreign) and R.writes(foreign)==writes and #workspace:GetChildren()==1)
	assert(R.live()==0,"a refused mount leaves nothing behind")
end)

test("mount rejects malformed descriptors and options without leaving instances",function()
	local R=mockRoblox()
	local workspace=R.root("Workspace")
	local bad={
		{"23 nodes",fixtureDescriptor(function(d) d.nodes[24]=nil;d.nodeCount=23 end)},
		{"edge to node 25",fixtureDescriptor(function(d) d.edges[37]={a=24,b=25} end)},
		{"edge from node 25",fixtureDescriptor(function(d) d.edges[37]={a=25,b=24} end)},
		{"self-loop",fixtureDescriptor(function(d) d.edges[37]={a=3,b=3} end)},
		{"36 edges",fixtureDescriptor(function(d) table.remove(d.edges) end)},
		{"38 edges",fixtureDescriptor(function(d) table.insert(d.edges,{a=1,b=10}) end)},
		{"duplicate edge",fixtureDescriptor(function(d) d.edges[37]={a=1,b=2} end)},
		{"reversed duplicate edge",fixtureDescriptor(function(d) d.edges[37]={a=2,b=1} end)},
		{"7 drive names",fixtureDescriptor(function(d) d.driveNames[3]=nil end)},
		{"wrong schema",fixtureDescriptor(function(d) d.schema="v3" end)},
		{"vote flag missing",fixtureDescriptor(function(d) d.nodes[5].directional=nil end)},
		{"non-finite rest",fixtureDescriptor(function(d) d.nodes[5].y=0/0 end)},
		{"anchorOffset 0",fixtureDescriptor(function(d) d.anchorOffset=0 end)},
	}
	for _,case in bad do
		assert(not pcall(function() SpringReplayView.mount(workspace,case[2],{env=R.env()}) end),"accepted bad descriptor: "..case[1])
	end
	assert(not pcall(function() SpringReplayView.mount(workspace,DESCRIPTOR,{env=R.env(),visualScale=0}) end))
	assert(not pcall(function() SpringReplayView.mount(workspace,DESCRIPTOR,{env=R.env(),anchorOffset=-1}) end))
	assert(not pcall(function() SpringReplayView.mount(workspace,DESCRIPTOR,{env=R.env(),origin={X=0,Y=0/0,Z=0}}) end))
	assert(not pcall(function() SpringReplayView.mount(workspace,DESCRIPTOR,{}) end),"no Roblox globals in the CLI without injection")
	assert(R.live()==0 and #workspace:GetChildren()==0)
	-- The deep-frozen descriptor is only read: a mount and updates succeed against it.
	local view=SpringReplayView.mount(workspace,DESCRIPTOR,{env=R.env()})
	view:update(row())
	view:destroy()
end)

test("the view keeps no reference to the row: later mutation of the row changes nothing",function()
	local _,workspace,view=mount()
	local m=model(workspace)
	local r=row()
	view:update(r)
	local before=snapshot(m)
	r.x[1]=99;r.diagnostics.nodeContributions[1]=5;r.header="changed"
	assert(snapshot(m)==before)
end)

---------------------------------------------------------------------------------------------------
-- Live forward test labels (spring-live-contract.md L12), appended 2026-10-05. The 2024 cases above are unchanged.
local LIVE_HEADER="Live-captured native physics · 5-minute observations · 2025-2026 forward test."
local function liveRow(over)
	return apply(row({runKind="live_native",header=LIVE_HEADER,runLabel="Coupled live native",partition="forward_test",
		evidence={implementationStatus="pass",physicsDependence="history_verified",marketEvidence="forward_test_predeclared"}}),over)
end

test("live_native rows with the lead-in and forward-test partitions are shown with their L12 texts (L12)",function()
	local _,workspace,view=mount()
	local m=model(workspace)
	assert(SpringReplayView.HEADERS.live_native==LIVE_HEADER,"exported live_native header")
	assert(SpringReplayView.validateRow(liveRow(),DESCRIPTOR)==nil)
	view:update(liveRow())
	assert(headerLine(m,"Title").Text==LIVE_HEADER and m:GetAttribute("RunKind")=="live_native")
	assert(m:GetAttribute("Partition")=="forward_test")
	assert(string.find(headerLine(m,"Detail").Text,"forward test · 2025-2026 · frozen 2024 protocol, never tuned here",1,true))
	view:update(liveRow({partition="calibration_lead_in",
		final={action="HOLD",source="lead_in",reason="lead_in_not_traded",overridden=true,riskConditions={"lead_in_not_traded"}}}))
	assert(m:GetAttribute("Partition")=="calibration_lead_in")
	assert(string.find(headerLine(m,"Detail").Text,"2024 lead-in · calibration period · not traded",1,true))
	-- Coupled live rows draw the 37 couplings; the live independent rig draws none (UNCOUPLED_RUNS is keyed by run id).
	local beams=couplingBeams(m)
	assert(enabledCount(beams)==37)
	view:update(liveRow({runId="independent",header=LIVE_HEADER.." Independent rig: 0 coupling springs.",sampleId="independent:412"}))
	assert(enabledCount(beams)==0 and m:GetAttribute("CouplingVisible")==false)
end)

test("the live additions keep the 2024 refusals: unknown kinds, unknown partitions, mismatched headers (L12)",function()
	local cases={
		{"runKind live",liveRow({runKind="live"})},
		{"runKind live_physics",liveRow({runKind="live_physics"})},
		{"partition holdout",liveRow({partition="holdout"})},
		{"partition forward",liveRow({partition="forward"})},
		{"live kind with the recorded header",liveRow({header=HEADERS.recorded_native})},
		{"recorded kind with the live header",row({header=LIVE_HEADER})},
		{"valid live row without x",liveRow({x=false})},
	}
	for _,case in cases do assert(SpringReplayView.validateRow(case[2],DESCRIPTOR)~=nil,"accepted: "..case[1]) end
	assert(SpringReplayView.HEADERS.recorded_native==HEADERS.recorded_native,"the 2024 recorded header is unchanged")
	local _,workspace,view=mount()
	view:update(liveRow())
	local before=snapshot(model(workspace))
	assert(not pcall(function() view:update(liveRow({partition="holdout"})) end))
	assert(snapshot(model(workspace))==before,"a refused live row changes nothing")
end)
print("SpringReplay: "..passed.." tests passed")
