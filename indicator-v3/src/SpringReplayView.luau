-- Spring Indicator replay view (spring-indicator-contract.md D14, D20, D23, D25 and the SpringReplayView section;
-- handover section 10). Decorative only. It draws one precomputed displayRow at a time with anchored,
-- non-colliding, non-query, non-touch markers and Beam connectors. It never creates constraints or forces, never
-- steps physics, never reads market data, never moves native bodies, and never touches an instance outside the
-- model it creates (never Workspace.RoAlgoResearchPhysics). Every Roblox global it uses can be injected through
-- options.env so the CLI spec can run it against mocks; in Studio the real globals are used.
local SpringReplayView={}

local MODEL_NAME="RoAlgoSpringReplay"
local MARKER_ATTRIBUTE="SpringReplayView"
local DESCRIPTOR_SCHEMA="spring-v2-descriptor-1"
local NODE_COUNT=24
local EDGE_COUNT=37
local BANK_COUNT=3
local DEFAULT_LAYOUT_SCALE=0.125 -- 256-stud saved spacing -> 32 display studs
local DEFAULT_VISUAL_SCALE=0.25 -- x displacement drawn at 2x the layout scale (stated on the model and in the header)
-- The capture's axial anchors sit 512 studs on the -X side of each node's rest (native.config.anchorOffset).
-- The descriptor does not carry it, so the contract value is the default; descriptor.anchorOffset or
-- options.anchorOffset override it.
local CAPTURE_ANCHOR_OFFSET=512
local DEFAULT_CENTER={256,72,0} -- clear of the v2 rigs (x -2048..-1312) and of the spawn pad
local VIEW_FIELD_OF_VIEW=50
-- D25: the view direction must be at least 45 degrees from the displacement axis X. With yaw 50 (measured from X
-- in the XZ plane) and pitch 22 it is about 53 degrees, +x reads to screen-right, the eight columns spread left
-- to right and the three banks stack vertically.
local VIEW_YAW=math.rad(50)
local VIEW_PITCH=math.rad(22)
local VIEW_DISTANCE_FACTOR=0.9 -- camera distance per stud of the framed rig width
local VIEW_SHIFT_FACTOR=0.4 -- focus shift to screen-right (per stud of distance), so the rig sits left of the docked panel
local REST_NOTE="rest offsets derived from saved config; capture origin not saved"
local LEGEND="spring colour = stretch · grey at rest · amber→yellow lengthened · blue→cyan compressed · couplings warmer = longer"

-- Label style (contract, the owner 2026-10-05; supersedes the handover's "opaque"): compact cards at about 75% of the
-- v2 112x38 px card, background about 35% transparent, text about 15%, outline about 40%.
local LABEL_WIDTH,LABEL_HEIGHT=84,29
local LABEL_CARD_TRANSPARENCY=0.35
local LABEL_TEXT_TRANSPARENCY=0.15
local LABEL_OUTLINE_TRANSPARENCY=0.4
-- Node-to-anchor tails: transparency at most 0.45 and at least 2.5 studs wide at v2 scale (contract). Width is a
-- fraction of the display spacing: 0.04 * 32 = 1.28 studs at layout 0.125, i.e. 10.24 studs at v2 scale.
local TAIL_WIDTH_FRACTION=0.04
local TAIL_REST_TRANSPARENCY=0.42
local TAIL_FULL_TRANSPARENCY=0.12
local TAIL_FULL_STRETCH=0.75 -- full stretch colour at |stretch| = 0.75 D
local COUPLING_WIDTH_FRACTION=0.05
local COUPLING_REST_TRANSPARENCY=0.3
local COUPLING_FULL_TRANSPARENCY=0.12
local COUPLING_FULL_STUDS=6 -- full colour at 6 studs of extra coupling length
local REST_EMISSION,FULL_EMISSION=0.25,1

-- Contract headers, keyed by displayRow.runKind. A row's header must begin with its kind's header.
local HEADERS={
	recorded_native="Recorded native physics · 5-minute observations · no live simulation.",
	artificial_intervention="Artificial state intervention · not a recording",
	numerical="Numerical comparator · not native physics",
	market_baseline="Market-only baseline · no physical input",
	no_trade="No-trade baseline · no physical input",
	synthetic_fixture="Synthetic fixture · not historical evidence",
}
local NO_PHYSICAL_INPUT={market_baseline=true,no_trade=true}
-- The recorded independent rig had 0 coupling springs (D20), so its run never draws connectors.
local UNCOUPLED_RUNS={independent=true}
local PARTITION_TEXT={
	training_retrospective="training · retrospective in-sample",
	validation="validation · development, sessions already inspected",
	evaluation="evaluation · development only, not a fresh holdout",
}
-- Live forward test (spring-live-contract.md L12; append-only additions, 2026-10-05): run kind live_native and the
-- calibration_lead_in / forward_test partitions. The 2024 kinds, partitions and texts above are unchanged.
HEADERS.live_native="Live-captured native physics · 5-minute observations · 2025-2026 forward test."
PARTITION_TEXT.calibration_lead_in="2024 lead-in · calibration period · not traded"
PARTITION_TEXT.forward_test="forward test · 2025-2026 · frozen 2024 protocol, never tuned here"
local BANK_NAMES={"Fast","Medium","Slow"}

local ROBLOX_GLOBALS={"Instance","Vector3","Vector2","Color3","CFrame","UDim2","UDim","Enum","ColorSequence","ColorSequenceKeypoint",
	"NumberSequence","NumberSequenceKeypoint"}

local View={}
View.__index=View

local function finite(x) return type(x)=="number" and x==x and math.abs(x)<math.huge end
local function isInteger(x) return finite(x) and x%1==0 end
local function fail(message) error("SpringReplayView: "..message,3) end

local function resolveEnv(options)
	local injected=options.env
	if injected~=nil and type(injected)~="table" then fail("options.env must be a table") end
	local defaults={Instance=Instance,Vector3=Vector3,Vector2=Vector2,Color3=Color3,CFrame=CFrame,UDim2=UDim2,UDim=UDim,
		Enum=Enum,ColorSequence=ColorSequence,ColorSequenceKeypoint=ColorSequenceKeypoint,NumberSequence=NumberSequence,
		NumberSequenceKeypoint=NumberSequenceKeypoint}
	local env={}
	for _,name in ROBLOX_GLOBALS do
		local value=injected and injected[name]
		if value==nil then value=defaults[name] end
		if name=="Instance" and options.Instance~=nil then value=options.Instance end
		if value==nil then fail("Roblox global "..name.." is unavailable; inject it through options.env") end
		env[name]=value
	end
	return env
end

local function validateDescriptor(d)
	if type(d)~="table" then fail("descriptor required") end
	if d.schema~=DESCRIPTOR_SCHEMA then fail("descriptor schema must be "..DESCRIPTOR_SCHEMA) end
	if d.nodeCount~=NODE_COUNT or type(d.nodes)~="table" or #d.nodes~=NODE_COUNT then fail("descriptor must hold exactly 24 nodes") end
	if not finite(d.D) or d.D<=0 then fail("descriptor D must be a positive finite number") end
	if not finite(d.spacing) or d.spacing<=0 then fail("descriptor spacing must be a positive finite number") end
	if d.anchorOffset~=nil and (not finite(d.anchorOffset) or d.anchorOffset<=0) then fail("descriptor anchorOffset must be a positive finite number") end
	if type(d.driveNames)~="table" or #d.driveNames~=8 then fail("descriptor must name 8 drive channels") end
	for channel=1,8 do
		if type(d.driveNames[channel])~="string" or d.driveNames[channel]=="" then fail("drive channel "..channel.." has no name") end
	end
	for i=1,NODE_COUNT do
		local node=d.nodes[i]
		if type(node)~="table" or node.index~=i then fail("node "..i.." is missing or out of order") end
		if type(node.name)~="string" or node.name=="" then fail("node "..i.." has no name") end
		if not isInteger(node.bank) or node.bank<1 or node.bank>BANK_COUNT then fail("node "..i.." has an invalid bank") end
		if not finite(node.y) or not finite(node.z) then fail("node "..i.." has no finite rest offset") end
		if not isInteger(node.dominantChannel) or node.dominantChannel<1 or node.dominantChannel>8 then fail("node "..i.." has an invalid dominant channel") end
		if type(node.directional)~="boolean" then fail("node "..i.." must declare whether it votes") end
	end
	if type(d.edges)~="table" or #d.edges~=EDGE_COUNT then fail("descriptor must hold exactly 37 coupling edges") end
	local seen={}
	for e=1,EDGE_COUNT do
		local edge=d.edges[e]
		if type(edge)~="table" or not isInteger(edge.a) or not isInteger(edge.b) then fail("edge "..e.." is malformed") end
		if edge.a<1 or edge.a>NODE_COUNT or edge.b<1 or edge.b>NODE_COUNT or edge.a==edge.b then fail("edge "..e.." does not join two distinct nodes") end
		local key=math.min(edge.a,edge.b)*100+math.max(edge.a,edge.b)
		if seen[key] then fail("edge "..e.." duplicates another edge") end
		seen[key]=true
	end
end

local function readVector(value,label)
	local ok,x,y,z=pcall(function() return value.X,value.Y,value.Z end)
	if not ok or not finite(x) or not finite(y) or not finite(z) then fail(label.." must be a Vector3 with finite components") end
	return x,y,z
end

local function rgb(r,g,b) return table.freeze({r/255,g/255,b/255}) end
-- Terminal palette (owner request, 2026-10-05: "change the UI and node color and spring gradient ... to something like" a
-- Bloomberg terminal): black, amber titles, white values, green up / red down, blue accents.
local PALETTE={
	bank=table.freeze({rgb(251,139,30),rgb(235,235,235),rgb(52,128,255)}), -- Fast amber, Medium white, Slow blue
	positive=rgb(74,232,90),negative=rgb(255,67,61),neutral=rgb(90,90,90),
	noInput=rgb(85,85,85),invalid=rgb(255,214,0),rest=rgb(120,120,120),
	card=rgb(0,0,0),text=rgb(251,139,30),muted=rgb(150,150,150),
	-- Springs are grey at rest so the gradient alone carries tension:
	-- lengthened grey -> amber -> yellow; compressed grey -> blue -> cyan.
	springRest=rgb(70,70,70),
	amber=rgb(251,139,30),coral=rgb(255,214,0),cyan=rgb(32,104,255),violet=rgb(0,220,255),
}
table.freeze(PALETTE)
local function mix(a,b,t) return {a[1]+(b[1]-a[1])*t,a[2]+(b[2]-a[2])*t,a[3]+(b[3]-a[3])*t} end
local function ramp(base,u,first,second)
	u=math.clamp(u,0,1)
	if u<=0.5 then return mix(base,first,u/0.5) end
	return mix(first,second,(u-0.5)/0.5)
end

-- Pure: tail (node-to-anchor spring) style for a signed capture-stud stretch (+D*x_i lengthens the anchor spring).
local function tailStyle(bankColor,stretch,D)
	bankColor=PALETTE.springRest -- terminal palette: springs start grey; the node keeps its bank colour
	local u=math.min(1,math.abs(stretch)/(TAIL_FULL_STRETCH*D))
	local first,second=PALETTE.amber,PALETTE.coral
	if stretch<0 then first,second=PALETTE.cyan,PALETTE.violet end
	local nodeTransparency=TAIL_REST_TRANSPARENCY-(TAIL_REST_TRANSPARENCY-TAIL_FULL_TRANSPARENCY)*u
	return {
		stretch=stretch,intensity=u,
		anchorColor=ramp(bankColor,0.35*u,first,second), -- the node end is the strongest
		nodeColor=ramp(bankColor,u,first,second),
		anchorTransparency=math.min(TAIL_REST_TRANSPARENCY,nodeTransparency+0.1),
		nodeTransparency=nodeTransparency,
		lightEmission=REST_EMISSION+(FULL_EMISSION-REST_EMISSION)*u,
	}
end

-- Pure: coupling style for extra length (capture studs) beyond the rest gap; hottest mid-span.
local function couplingStyle(colorA,colorB,extra)
	colorA,colorB=PALETTE.springRest,PALETTE.springRest -- terminal palette: couplings start grey
	local u=math.min(1,math.max(0,extra)/COUPLING_FULL_STUDS)
	local span=COUPLING_REST_TRANSPARENCY-COUPLING_FULL_TRANSPARENCY
	return {
		extra=extra,intensity=u,
		colorA=ramp(colorA,0.5*u,PALETTE.amber,PALETTE.coral),
		colorMid=ramp(mix(colorA,colorB,0.5),u,PALETTE.amber,PALETTE.coral),
		colorB=ramp(colorB,0.5*u,PALETTE.amber,PALETTE.coral),
		endTransparency=COUPLING_REST_TRANSPARENCY-span*0.5*u,
		midTransparency=COUPLING_REST_TRANSPARENCY-span*u,
		lightEmission=REST_EMISSION+(FULL_EMISSION-REST_EMISSION)*u,
	}
end

local function checkArray(value,count,label)
	if type(value)~="table" then return label.." must be an array" end
	if #value~=count then return string.format("%s must hold %d values (got %d)",label,count,#value) end
	for i=1,count do
		if not finite(value[i]) then return string.format("%s[%d] must be finite",label,i) end
	end
	return nil
end
local function optionalFinite(value,label)
	if value~=nil and not finite(value) then return label.." must be finite when present" end
	return nil
end
local function actionProblem(value,label)
	if type(value)~="table" or type(value.action)~="string" or value.action=="" then return label..".action is required" end
	if value.source~=nil and type(value.source)~="string" then return label..".source must be a string" end
	if value.reason~=nil and type(value.reason)~="string" then return label..".reason must be a string" end
	return nil
end

-- Pure validation of one displayRow (contract section 3). The replay view and the docked panel use this same
-- function, so a row is either shown by both or by neither. With a descriptor it also rejects a non-zero
-- contribution on a non-voting node (non-voting nodes contribute 0). Returns nil or the reason.
local function rowProblem(row,descriptor)
	if type(row)~="table" then return "displayRow must be a table" end
	if not isInteger(row.index) or row.index<1 then return "index must be a positive integer" end
	if not finite(row.t) then return "t must be finite" end
	if not finite(row.availableT) then return "availableT must be finite" end
	if type(row.runId)~="string" or row.runId=="" then return "runId must be a non-empty string" end
	local canonical=HEADERS[row.runKind]
	if canonical==nil then return "unknown runKind "..tostring(row.runKind) end
	if type(row.header)~="string" or string.sub(row.header,1,#canonical)~=canonical then
		return "header does not match runKind "..row.runKind
	end
	if type(row.partition)~="string" or row.partition=="" or (PARTITION_TEXT[row.partition]==nil and row.runKind~="synthetic_fixture") then
		return "unknown partition "..tostring(row.partition)
	end
	if row.runLabel~=nil and type(row.runLabel)~="string" then return "runLabel must be a string" end
	if row.label~=nil and type(row.label)~="string" then return "label must be a string" end
	local diagnostics=row.diagnostics
	if type(diagnostics)~="table" or type(diagnostics.valid)~="boolean" then return "diagnostics.valid is required" end
	if diagnostics.reason~=nil and type(diagnostics.reason)~="string" then return "diagnostics.reason must be a string" end
	local problem=optionalFinite(diagnostics.score,"diagnostics.score")
	if problem then return problem end
	if diagnostics.bankScores~=nil then
		problem=checkArray(diagnostics.bankScores,BANK_COUNT,"diagnostics.bankScores")
		if problem then return problem end
	end
	local contributions=diagnostics.nodeContributions
	if contributions~=nil then
		problem=checkArray(contributions,NODE_COUNT,"diagnostics.nodeContributions")
		if problem then return problem end
		if descriptor then
			for i=1,NODE_COUNT do
				if not descriptor.nodes[i].directional and contributions[i]~=0 then
					return string.format("non-voting node %d carries contribution %.6g (non-voting nodes contribute 0)",i,contributions[i])
				end
			end
		end
	end
	if row.thresholds~=nil then
		if type(row.thresholds)~="table" then return "thresholds must be a table" end
		for _,key in {"entry","exit","bankDeadband"} do
			problem=optionalFinite(row.thresholds[key],"thresholds."..key)
			if problem then return problem end
		end
	end
	if row.policy~=nil and type(row.policy)~="table" then return "policy must be a table" end
	problem=actionProblem(row.intent,"intent") or actionProblem(row.final,"final")
	if problem then return problem end
	if row.final.riskConditions~=nil and type(row.final.riskConditions)~="table" then return "final.riskConditions must be a list" end
	if row.pending~=nil then
		problem=actionProblem(row.pending,"pending")
		if problem then return problem end
	end
	if row.position~=-1 and row.position~=0 and row.position~=1 then return "position must be -1, 0 or 1" end
	if not finite(row.equity) then return "equity must be finite" end
	problem=optionalFinite(row.holdBars,"holdBars") or optionalFinite(row.stop,"stop") or optionalFinite(row.target,"target")
	if problem then return problem end
	if type(row.executions)~="table" then return "executions must be a list" end
	for k,fill in row.executions do
		if type(fill)~="table" then return "executions["..tostring(k).."] must be a table" end
	end
	if type(row.evidence)~="table" then return "evidence is required" end
	if NO_PHYSICAL_INPUT[row.runKind] then
		-- A baseline never displays a spring state as its input.
		if row.x~=nil or row.v~=nil then return row.runKind.." rows must not carry x/v" end
		if contributions~=nil then return row.runKind.." rows must not carry node contributions" end
		if row.sampleId~=nil and type(row.sampleId)~="string" then return "sampleId must be a string" end
		return nil
	end
	if type(row.sampleId)~="string" or row.sampleId=="" then return "sampleId is required for a physical run" end
	if diagnostics.valid and (row.x==nil or row.v==nil) then return "a valid physical row needs x and v" end
	if row.x~=nil then
		problem=checkArray(row.x,NODE_COUNT,"x")
		if problem then return problem end
	end
	if row.v~=nil then
		problem=checkArray(row.v,NODE_COUNT,"v")
		if problem then return problem end
	end
	return nil
end

local function labelCard(env,make,parent,index,node,driveName,adornee,below,bankColor)
	local C3=env.Color3
	local gui=make("BillboardGui",parent,{Name=string.format("Label%02d",index)})
	gui.Adornee=adornee
	gui.AlwaysOnTop=true;gui.MaxDistance=0;gui.LightInfluence=0;gui.ResetOnSpawn=false;gui.ClipsDescendants=false
	gui.Size=env.UDim2.fromOffset(LABEL_WIDTH,LABEL_HEIGHT)
	gui.SizeOffset=env.Vector2.new(0,if below then -0.5 else 0.5)
	gui:SetAttribute("VisualOnly",true);gui:SetAttribute("NodeIndex",index);gui:SetAttribute("DirectVote",node.directional)
	gui:SetAttribute("DominantDriveChannel",node.dominantChannel);gui:SetAttribute("DominantInput",driveName)
	local card=make("Frame",gui,{Name="Card"})
	card.Size=env.UDim2.fromScale(1,1);card.BackgroundColor3=C3.new(table.unpack(PALETTE.card))
	card.BackgroundTransparency=LABEL_CARD_TRANSPARENCY;card.BorderSizePixel=0
	make("UICorner",card,{CornerRadius=env.UDim.new(0,4)})
	local stroke=make("UIStroke",card,{Name="Stroke"})
	stroke.Color=C3.new(table.unpack(bankColor));stroke.Thickness=1;stroke.Transparency=LABEL_OUTLINE_TRANSPARENCY
	local function line(name,y,h,maxSize,color,font)
		local text=make("TextLabel",card,{Name=name})
		text.Position=env.UDim2.fromOffset(3,y);text.Size=env.UDim2.new(1,-6,0,h)
		text.BackgroundTransparency=1;text.TextTransparency=LABEL_TEXT_TRANSPARENCY;text.TextColor3=C3.new(table.unpack(color))
		text.Font=font;text.TextScaled=true;text.TextWrapped=true
		text.TextXAlignment=env.Enum.TextXAlignment.Left;text.TextYAlignment=env.Enum.TextYAlignment.Center
		make("UITextSizeConstraint",text,{Name="SizeLimit",MaxTextSize=maxSize,MinTextSize=6})
		return text
	end
	-- D23 identity text, verbatim (wraps to two lines inside the compact card).
	local identity=line("Identity",1,17,10,bankColor,env.Enum.Font.GothamBold)
	identity.Text=string.format("%s · dominant input: %s",node.name,driveName)
	local vote=line("Vote",18,10,9,PALETTE.text,env.Enum.Font.GothamMedium)
	vote.Text=if node.directional then "contribution —" else "visible, not a direct vote"
	return {gui=gui,stroke=stroke,vote=vote}
end

local function colorSequence(env,stops)
	local keypoints={}
	for k,stop in stops do keypoints[k]=env.ColorSequenceKeypoint.new(stop[1],env.Color3.new(stop[2][1],stop[2][2],stop[2][3])) end
	return env.ColorSequence.new(keypoints)
end
local function numberSequence(env,stops)
	local keypoints={}
	for k,stop in stops do keypoints[k]=env.NumberSequenceKeypoint.new(stop[1],stop[2]) end
	return env.NumberSequence.new(keypoints)
end

function SpringReplayView.mount(parent,descriptor,options)
	options=options or {}
	if type(options)~="table" then fail("options must be a table") end
	local env=resolveEnv(options)
	if parent==nil or (type(parent)~="table" and type(parent)~="userdata") then fail("parent instance required") end
	validateDescriptor(descriptor)
	local layoutScale=if options.layoutScale==nil then DEFAULT_LAYOUT_SCALE else options.layoutScale
	local visualScale=if options.visualScale==nil then DEFAULT_VISUAL_SCALE else options.visualScale
	local anchorOffset=options.anchorOffset or descriptor.anchorOffset or CAPTURE_ANCHOR_OFFSET
	if not finite(layoutScale) or layoutScale<=0 then fail("layoutScale must be a positive finite number") end
	if not finite(visualScale) or visualScale<=0 then fail("visualScale must be a positive finite number") end
	if not finite(anchorOffset) or anchorOffset<=0 then fail("anchorOffset must be a positive finite number") end

	local nodes=descriptor.nodes
	local yMin,yMax,zMin,zMax=math.huge,-math.huge,math.huge,-math.huge
	for _,node in nodes do
		yMin=math.min(yMin,node.y);yMax=math.max(yMax,node.y);zMin=math.min(zMin,node.z);zMax=math.max(zMax,node.z)
	end
	local ox,oy,oz
	if options.origin~=nil then
		ox,oy,oz=readVector(options.origin,"options.origin")
	else
		ox=DEFAULT_CENTER[1];oy=DEFAULT_CENTER[2]-(yMin+yMax)/2*layoutScale;oz=DEFAULT_CENTER[3]-(zMin+zMax)/2*layoutScale
	end
	local spacing=descriptor.spacing*layoutScale
	local studsPerUnit=visualScale*descriptor.D
	local anchorDisplay=anchorOffset*layoutScale
	local markerDiameter=0.17*spacing
	local labelLift=0.16*spacing
	local scaleNote=string.format("x drawn at %.4g studs per unit (%.3gx layout scale) · anchors %.4g studs on -X · %s",
		studsPerUnit,visualScale/layoutScale,anchorDisplay,REST_NOTE)

	-- Default framing (an initial view only, D25): oblique so x displacement reads sideways; the rig, its tails and
	-- labels sit left of the 440 px docked panel. The framed width covers the columns plus the anchor tails.
	local cx,cy,cz=ox-anchorDisplay/2,oy+(yMin+yMax)/2*layoutScale,oz+(zMin+zMax)/2*layoutScale
	local width=math.max((zMax-zMin)*layoutScale+anchorDisplay,(yMax-yMin)*layoutScale,spacing)
	local distance=VIEW_DISTANCE_FACTOR*width+spacing
	-- Look direction d (camera -> focus) and its screen-right vector d x up = (sin yaw, 0, cos yaw).
	local dx,dy,dz=math.cos(VIEW_PITCH)*math.cos(VIEW_YAW),-math.sin(VIEW_PITCH),-math.cos(VIEW_PITCH)*math.sin(VIEW_YAW)
	local rx,rz=math.sin(VIEW_YAW),math.cos(VIEW_YAW)
	local shift=VIEW_SHIFT_FACTOR*distance
	local fx,fy,fz=cx+shift*rx,cy,cz+shift*rz
	local vx,vy,vz=fx-distance*dx,fy-distance*dy,fz-distance*dz

	local created={}
	local function make(className,parentInstance,props)
		local instance=env.Instance.new(className)
		table.insert(created,instance)
		if props then
			for key,value in props do instance[key]=value end
		end
		if parentInstance then instance.Parent=parentInstance end
		return instance
	end
	local V3,CF,C3=env.Vector3,env.CFrame,env.Color3
	local function decoratePart(part)
		-- Fixed order: CanQuery may only be cleared once CanCollide is false.
		part.Anchored=true;part.CanCollide=false;part.CanTouch=false;part.CanQuery=false
		part.CastShadow=false;part.Locked=true;part.Material=env.Enum.Material.SmoothPlastic
		part:SetAttribute("VisualOnly",true)
	end

	local model=make("Model",nil,{Name=MODEL_NAME})
	local view=setmetatable({},View)
	local ok,err=pcall(function()
		model:SetAttribute(MARKER_ATTRIBUTE,true);model:SetAttribute("VisualOnly",true)
		model:SetAttribute("Schema","roalgo-spring-replay-2")
		model:SetAttribute("Scope","Anchored replay markers of precomputed rows; decoration never participates in dynamics; no live simulation")
		model:SetAttribute("RestGeometry",REST_NOTE)
		model:SetAttribute("DisplayOrigin",V3.new(ox,oy,oz))
		model:SetAttribute("LayoutScale",layoutScale);model:SetAttribute("VisualScale",visualScale)
		model:SetAttribute("DisplacementStudsPerUnit",studsPerUnit)
		model:SetAttribute("AnchorOffset",anchorOffset);model:SetAttribute("AnchorDisplayStuds",anchorDisplay)
		model:SetAttribute("ScaleNote",scaleNote);model:SetAttribute("Legend",LEGEND)
		model:SetAttribute("FocusPosition",V3.new(fx,fy,fz));model:SetAttribute("ViewPosition",V3.new(vx,vy,vz))
		model:SetAttribute("ViewFieldOfView",VIEW_FIELD_OF_VIEW)
		local nodesFolder=make("Folder",model,{Name="Nodes"})
		local tailsFolder=make("Folder",model,{Name="Tails"})
		local couplingFolder=make("Folder",model,{Name="Coupling"})
		local labelsFolder=make("Folder",model,{Name="Labels"})
		local rest,markers,centers,tails,labels,bankColors={}, {}, {}, {}, {}, {}
		for i,node in nodes do
			local bankColor=PALETTE.bank[node.bank]
			bankColors[i]=bankColor
			local driveName=descriptor.driveNames[node.dominantChannel]
			local px,py,pz=ox,oy+node.y*layoutScale,oz+node.z*layoutScale
			rest[i]={px,py,pz}
			local restPart=make("Part",nil,{Name=string.format("Rest%02d",i)})
			decoratePart(restPart)
			restPart.Shape=env.Enum.PartType.Cylinder -- disk normal to the displacement axis X
			restPart.Size=V3.new(0.25,0.32*spacing,0.32*spacing);restPart.CFrame=CF.new(V3.new(px,py,pz))
			restPart.Color=C3.new(table.unpack(PALETTE.rest));restPart.Transparency=0.35
			restPart:SetAttribute("NodeIndex",i);restPart:SetAttribute("RestTick",true)
			restPart.Parent=nodesFolder
			-- The node's axial anchor, anchorDisplay studs on the -X side of its rest (local offset; no rotation).
			local anchorAttachment=make("Attachment",restPart,{Name="Anchor"})
			anchorAttachment.Position=V3.new(-anchorDisplay,0,0)
			local marker=make("Part",nil,{Name=string.format("Node%02d",i)})
			decoratePart(marker)
			marker.Shape=env.Enum.PartType.Ball
			marker.Size=V3.new(markerDiameter,markerDiameter,markerDiameter);marker.CFrame=CF.new(V3.new(px,py,pz))
			marker.Color=C3.new(table.unpack(PALETTE.neutral));marker.Transparency=0.2
			marker:SetAttribute("NodeIndex",i);marker:SetAttribute("Bank",node.bank)
			marker:SetAttribute("BankName",if type(node.bankName)=="string" then node.bankName else BANK_NAMES[node.bank])
			marker:SetAttribute("NodeName",node.name);marker:SetAttribute("DirectVote",node.directional)
			marker:SetAttribute("DominantInput",driveName)
			marker.Parent=nodesFolder
			local center=make("Attachment",marker,{Name="Center"})
			local tail=make("Beam",tailsFolder,{Name=string.format("Tail%02d",i)})
			tail.Attachment0=anchorAttachment;tail.Attachment1=center
			tail.Width0=TAIL_WIDTH_FRACTION*spacing;tail.Width1=TAIL_WIDTH_FRACTION*spacing;tail.FaceCamera=true;tail.Segments=1
			tail.LightInfluence=0;tail.LightEmission=REST_EMISSION;tail.Enabled=false
			tail.Color=colorSequence(env,{{0,bankColor},{1,bankColor}})
			tail.Transparency=numberSequence(env,{{0,TAIL_REST_TRANSPARENCY},{1,TAIL_REST_TRANSPARENCY}})
			tail:SetAttribute("VisualOnly",true);tail:SetAttribute("NodeIndex",i);tail:SetAttribute("Tail",true)
			local column=math.floor(node.z/descriptor.spacing+0.5)
			local below=column%2==1
			local label=labelCard(env,make,labelsFolder,i,node,driveName,restPart,below,bankColor)
			label.gui.StudsOffsetWorldSpace=V3.new(0,if below then -labelLift else labelLift,0)
			markers[i]=marker;centers[i]=center;tails[i]=tail;labels[i]=label
		end
		local beams,gaps={}, {}
		for e,edge in descriptor.edges do
			local a,b=nodes[edge.a],nodes[edge.b]
			gaps[e]=math.sqrt((a.y-b.y)^2+(a.z-b.z)^2) -- rest gap T in capture studs (256 for every v2 edge)
			local beam=make("Beam",couplingFolder,{Name=string.format("Couple%02d_%02d",edge.a,edge.b)})
			beam.Attachment0=centers[edge.a];beam.Attachment1=centers[edge.b]
			beam.Width0=COUPLING_WIDTH_FRACTION*spacing;beam.Width1=COUPLING_WIDTH_FRACTION*spacing;beam.FaceCamera=true;beam.Segments=1
			beam.LightInfluence=0;beam.LightEmission=REST_EMISSION
			beam.Color=colorSequence(env,{{0,bankColors[edge.a]},{0.5,mix(bankColors[edge.a],bankColors[edge.b],0.5)},{1,bankColors[edge.b]}})
			beam.Transparency=numberSequence(env,{{0,COUPLING_REST_TRANSPARENCY},{0.5,COUPLING_REST_TRANSPARENCY},{1,COUPLING_REST_TRANSPARENCY}})
			beam.Enabled=false
			beam:SetAttribute("VisualOnly",true);beam:SetAttribute("Coupling",true);beam:SetAttribute("RestGap",gaps[e])
			beams[e]=beam
		end
		-- An anchored, invisible part at the framing focus: a CameraSubject for free orbit in a playtest (D25).
		local focus=make("Part",nil,{Name="Focus"})
		decoratePart(focus)
		focus.Shape=env.Enum.PartType.Block;focus.Size=V3.new(0.2,0.2,0.2);focus.Transparency=1
		focus.CFrame=CF.new(V3.new(fx,fy,fz))
		focus.Parent=model
		model:SetAttribute("CameraSubject","Focus");model:SetAttribute("SuggestedMaxZoomDistance",math.ceil(3*distance))
		local anchor=make("Part",nil,{Name="HeaderAnchor"})
		decoratePart(anchor)
		anchor.Shape=env.Enum.PartType.Block;anchor.Size=V3.new(0.2,0.2,0.2);anchor.Transparency=1
		anchor.CFrame=CF.new(V3.new(ox,oy+yMax*layoutScale+1.1*spacing,cz))
		anchor.Parent=model
		local header=make("BillboardGui",model,{Name="Header"})
		header.Adornee=anchor;header.AlwaysOnTop=true;header.MaxDistance=0;header.LightInfluence=0
		header.ResetOnSpawn=false;header.Size=env.UDim2.fromOffset(560,112);header.SizeOffset=env.Vector2.new(0,0.5)
		-- Hidden unless options.showHeader (owner request, 2026-10-05: "take this off"). Its lines are still kept current, and the
		-- same provenance header and interpolation note are shown in SpringPanel.
		header.Enabled=options.showHeader==true
		header:SetAttribute("VisualOnly",true)
		local card=make("Frame",header,{Name="Card"})
		card.Size=env.UDim2.fromScale(1,1);card.BackgroundColor3=C3.new(table.unpack(PALETTE.card))
		card.BackgroundTransparency=0.1;card.BorderSizePixel=0
		make("UICorner",card,{CornerRadius=env.UDim.new(0,6)})
		local function headerLine(name,y,h,size,color,font)
			local text=make("TextLabel",card,{Name=name})
			text.Position=env.UDim2.fromOffset(10,y);text.Size=env.UDim2.new(1,-20,0,h)
			text.BackgroundTransparency=1;text.TextTransparency=0;text.TextColor3=C3.new(table.unpack(color))
			text.Font=font;text.TextSize=size;text.TextWrapped=true
			text.TextXAlignment=env.Enum.TextXAlignment.Left;text.TextYAlignment=env.Enum.TextYAlignment.Center
			return text
		end
		local title=headerLine("Title",4,16,12,PALETTE.cyan,env.Enum.Font.GothamBold)
		title.Text="Spring replay · awaiting a displayRow · no state shown"
		local detail=headerLine("Detail",20,25,10,PALETTE.text,env.Enum.Font.GothamMedium);detail.Text=""
		local notice=headerLine("Notice",45,13,10,PALETTE.muted,env.Enum.Font.GothamBold);notice.Text=""
		local legend=headerLine("Legend",58,25,10,PALETTE.amber,env.Enum.Font.GothamMedium);legend.Text=LEGEND
		local scope=headerLine("Scope",83,25,9,PALETTE.muted,env.Enum.Font.Gotham)
		scope.Text="Anchored replay markers · "..scaleNote
		model:SetAttribute("Nodes",#markers);model:SetAttribute("Tails",#tails);model:SetAttribute("CouplingBeams",#beams)
		model:SetAttribute("NodeLabels",#labels)
		model:SetAttribute("RowIndex",0);model:SetAttribute("PhysicalInput",false);model:SetAttribute("CouplingVisible",false)
		view.model=model;view.descriptor=descriptor;view.env=env
		view.rest=rest;view.markers=markers;view.tails=tails;view.labels=labels;view.beams=beams;view.gaps=gaps
		view.bankColors=bankColors;view.focusPart=focus
		view.header={title=title,detail=detail,notice=notice,legend=legend,scope=scope}
		view.studsPerUnit=studsPerUnit;view.markerDiameter=markerDiameter;view.visualScale=visualScale;view.layoutScale=layoutScale
		view.anchorOffset=anchorOffset;view.anchorDisplay=anchorDisplay;view.scaleNote=scaleNote
		view.origin={ox,oy,oz};view.focusPosition={fx,fy,fz};view.viewPosition={vx,vy,vz};view.fieldOfView=VIEW_FIELD_OF_VIEW
		view.counts={nodes=#markers,tails=#tails,couplingBeams=#beams,nodeLabels=#labels,instances=#created}
		view.destroyed=false
	end)
	if not ok then
		model:Destroy()
		for _,instance in created do pcall(function() instance:Destroy() end) end
		error(tostring(err),2)
	end
	-- Replace only a stale replay model made by this module; refuse to touch anything else.
	for _,child in parent:GetChildren() do
		if child.Name==MODEL_NAME then
			if child:GetAttribute(MARKER_ATTRIBUTE)~=true then
				model:Destroy()
				fail("parent already holds a "..MODEL_NAME.." that this module did not create; refusing to touch it")
			end
		end
	end
	for _,child in parent:GetChildren() do
		if child.Name==MODEL_NAME and child:GetAttribute(MARKER_ATTRIBUTE)==true then child:Destroy() end
	end
	model.Parent=parent
	return view
end

-- Pure: turns a validated row into every property value the scene will show.
function View:_plan(row)
	local diagnostics=row.diagnostics
	local descriptor=self.descriptor
	local noInput=NO_PHYSICAL_INPUT[row.runKind]==true
	local hasState=not noInput and row.x~=nil
	local coupled=hasState and not UNCOUPLED_RUNS[row.runId]
	local contributions=if not noInput then diagnostics.nodeContributions else nil
	local entry=row.thresholds and row.thresholds.entry
	local maxAbs=0
	if contributions then
		for i=1,NODE_COUNT do maxAbs=math.max(maxAbs,math.abs(contributions[i])) end
	end
	-- Marker size is relative to the largest contribution, but never to less than a quarter of the entry
	-- threshold, so a row of tiny contributions does not draw full-size markers.
	local reference=math.max(maxAbs,if finite(entry) and entry>0 then entry*0.25 else 0)
	if reference<=0 then reference=1 end
	local rank={}
	if contributions then
		local order={}
		for i=1,NODE_COUNT do
			if descriptor.nodes[i].directional and contributions[i]~=0 then table.insert(order,i) end
		end
		table.sort(order,function(a,b)
			local da,db=math.abs(contributions[a]),math.abs(contributions[b])
			if da==db then return a<b end
			return da>db
		end)
		for position=1,math.min(3,#order) do rank[order[position]]=position end
	end
	local plan={nodes={},edges={},coupled=coupled,noInput=noInput,hasState=hasState}
	for i,node in descriptor.nodes do
		local rest=self.rest[i]
		local displacement=if hasState then self.studsPerUnit*row.x[i] else 0
		local entryPlan={x=rest[1]+displacement,y=rest[2],z=rest[3],rank=rank[i] or 0}
		local c=contributions and contributions[i]
		if noInput then
			entryPlan.color=PALETTE.noInput;entryPlan.transparency=0.55;entryPlan.diameter=self.markerDiameter*0.6
			entryPlan.vote=if node.directional then "no physical input" else "visible, not a direct vote"
		else
			local intensity=if c then math.min(1,math.abs(c)/reference) else 0
			if not diagnostics.valid then
				entryPlan.color=PALETTE.invalid
			elseif not node.directional then
				entryPlan.color=mix(PALETTE.neutral,PALETTE.bank[node.bank],0.55)
			elseif c and c>0 then
				entryPlan.color=mix(PALETTE.neutral,PALETTE.positive,0.25+0.75*intensity)
			elseif c and c<0 then
				entryPlan.color=mix(PALETTE.neutral,PALETTE.negative,0.25+0.75*intensity)
			else
				entryPlan.color=PALETTE.neutral
			end
			entryPlan.transparency=if node.directional then 0.05 else 0.45
			entryPlan.diameter=if node.directional then self.markerDiameter*(0.75+0.65*intensity) else self.markerDiameter*0.6
			if not node.directional then
				entryPlan.vote="visible, not a direct vote"
			elseif c then
				entryPlan.vote=string.format("contribution %+.4f",c)
			else
				entryPlan.vote="contribution —"
			end
		end
		entryPlan.tail=if hasState then tailStyle(self.bankColors[i],descriptor.D*row.x[i],descriptor.D) else nil
		entryPlan.contribution=c
		entryPlan.xValue=if hasState then row.x[i] else nil
		entryPlan.vValue=if hasState and row.v then row.v[i] else nil
		plan.nodes[i]=entryPlan
	end
	for e,edge in descriptor.edges do
		local extra=0
		if hasState then
			local T=self.gaps[e]
			local dxCapture=descriptor.D*(row.x[edge.b]-row.x[edge.a])
			extra=math.sqrt(T*T+dxCapture*dxCapture)-T
		end
		plan.edges[e]=couplingStyle(self.bankColors[edge.a],self.bankColors[edge.b],extra)
	end
	local partitionText=PARTITION_TEXT[row.partition] or row.partition
	plan.title=row.header
	plan.detail=string.format("%s · %s · obs %d · %s · %s",row.runLabel or row.runId,partitionText,row.index,
		row.sampleId or "no spring sample",row.label or string.format("t %.0f",row.t))
	if noInput then
		plan.notice="Rig greyed at rest · no physical input feeds this run"
		plan.noticeColor=PALETTE.amber
	elseif not hasState then
		plan.notice="Invalid physics sample · "..(diagnostics.reason or "no reason recorded").." · no state drawn"
		plan.noticeColor=PALETTE.negative
	elseif not coupled then
		plan.notice="Independent rig · coupling removed (0 coupling springs recorded)"
		plan.noticeColor=PALETTE.muted
	elseif not diagnostics.valid then
		plan.notice="Invalid physics sample · "..(diagnostics.reason or "no reason recorded")
		plan.noticeColor=PALETTE.negative
	else
		plan.notice="Endpoint state at this observation · stepped, no visual interpolation"
		plan.noticeColor=PALETTE.muted
	end
	return plan
end

function View:_apply(row,plan)
	local env=self.env
	local V3,CF,C3=env.Vector3,env.CFrame,env.Color3
	for i,entry in plan.nodes do
		local marker=self.markers[i]
		marker.CFrame=CF.new(V3.new(entry.x,entry.y,entry.z))
		marker.Size=V3.new(entry.diameter,entry.diameter,entry.diameter)
		marker.Color=C3.new(table.unpack(entry.color));marker.Transparency=entry.transparency
		marker.Material=if entry.rank>0 then env.Enum.Material.Neon else env.Enum.Material.SmoothPlastic
		marker:SetAttribute("Contribution",entry.contribution)
		marker:SetAttribute("TopContributor",entry.rank)
		marker:SetAttribute("X",entry.xValue);marker:SetAttribute("V",entry.vValue)
		local tail=self.tails[i]
		local style=entry.tail
		tail.Enabled=style~=nil
		if style then
			tail.Color=colorSequence(env,{{0,style.anchorColor},{1,style.nodeColor}})
			tail.Transparency=numberSequence(env,{{0,style.anchorTransparency},{1,style.nodeTransparency}})
			tail.LightEmission=style.lightEmission
		end
		tail:SetAttribute("Stretch",if style then style.stretch else nil)
		local label=self.labels[i]
		label.vote.Text=entry.vote
		label.stroke.Thickness=if entry.rank>0 then 2.5 else 1
		label.stroke.Color=C3.new(table.unpack(if entry.rank>0 then entry.color else PALETTE.bank[self.descriptor.nodes[i].bank]))
	end
	for e,beam in self.beams do
		local style=plan.edges[e]
		beam.Enabled=plan.coupled
		beam.Color=colorSequence(env,{{0,style.colorA},{0.5,style.colorMid},{1,style.colorB}})
		beam.Transparency=numberSequence(env,{{0,style.endTransparency},{0.5,style.midTransparency},{1,style.endTransparency}})
		beam.LightEmission=style.lightEmission
		beam:SetAttribute("ExtraLength",if plan.hasState then style.extra else nil)
	end
	local header=self.header
	header.title.Text=plan.title;header.detail.Text=plan.detail
	header.notice.Text=plan.notice;header.notice.TextColor3=C3.new(table.unpack(plan.noticeColor))
	local model=self.model
	model:SetAttribute("RunId",row.runId);model:SetAttribute("RunKind",row.runKind)
	model:SetAttribute("RowIndex",row.index);model:SetAttribute("ObservationT",row.t)
	model:SetAttribute("SampleId",row.sampleId or "");model:SetAttribute("Partition",row.partition)
	model:SetAttribute("PhysicalInput",not plan.noInput);model:SetAttribute("CouplingVisible",plan.coupled)
	model:SetAttribute("Score",if finite(row.diagnostics.score) then row.diagnostics.score else nil)
end

-- Validates the whole row first, then applies every property in one pass (no yields), so the scene never shows a
-- mix of two observations and a rejected row changes nothing.
function View:update(row)
	if self.destroyed then error("SpringReplayView: update after destroy",2) end
	if self.model.Parent==nil then error("SpringReplayView: replay model was removed outside this view",2) end
	local problem=rowProblem(row,self.descriptor)
	if problem then error("SpringReplayView: rejected displayRow: "..problem,2) end
	local plan=self:_plan(row)
	self:_apply(row,plan)
	return plan
end

function View:destroy()
	if self.destroyed then return end
	self.destroyed=true
	local model=self.model
	self.markers=nil;self.tails=nil;self.labels=nil;self.beams=nil;self.header=nil;self.focusPart=nil
	if model then model:Destroy() end
end

SpringReplayView.MODEL_NAME=MODEL_NAME
SpringReplayView.HEADERS=table.freeze(table.clone(HEADERS))
SpringReplayView.REST_NOTE=REST_NOTE
SpringReplayView.LEGEND=LEGEND
SpringReplayView.PALETTE=PALETTE
SpringReplayView.STYLE=table.freeze({
	labelWidth=LABEL_WIDTH,labelHeight=LABEL_HEIGHT,labelCardTransparency=LABEL_CARD_TRANSPARENCY,
	labelTextTransparency=LABEL_TEXT_TRANSPARENCY,labelOutlineTransparency=LABEL_OUTLINE_TRANSPARENCY,
	tailWidthFraction=TAIL_WIDTH_FRACTION,tailRestTransparency=TAIL_REST_TRANSPARENCY,tailFullTransparency=TAIL_FULL_TRANSPARENCY,
	tailFullStretch=TAIL_FULL_STRETCH,couplingFullStuds=COUPLING_FULL_STUDS,captureAnchorOffset=CAPTURE_ANCHOR_OFFSET,
})
SpringReplayView.tailStyle=tailStyle
SpringReplayView.couplingStyle=couplingStyle
-- Shared displayRow validation (also used by SpringPanel): nil when the row may be shown, else the reason.
SpringReplayView.validateRow=function(row,descriptor) return rowProblem(row,descriptor) end
return SpringReplayView
