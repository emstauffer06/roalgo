-- Spring Indicator docked panel (spring-indicator-contract.md D21; handover section 10, Task 5).
-- Pure presentation: it formats the precomputed displayRow it is given and forwards button presses
-- to callbacks. It never computes signals, scores, positions or ledgers. Every Roblox global it uses
-- can be injected through options.env so the CLI spec can run it against mocks.
local SpringPanel={}

local GUI_NAME="RoAlgoSpringPanel"
local WIDTH=440
local PAD=12
local INNER=WIDTH-2*PAD
local CONTENT_HEIGHT=732
local MAX_RUNS=8
local TOP_CONTRIBUTIONS=4
local FILL_LINES=3
local NOT_APPROVED="experimental - not approved for trading"

local RUN_KINDS={recorded_native=true,artificial_intervention=true,numerical=true,market_baseline=true,no_trade=true,synthetic_fixture=true}
local NO_PHYSICAL_INPUT={market_baseline=true,no_trade=true}
local PARTITION_TEXT={
	training_retrospective="TRAINING · retrospective in-sample",
	validation="VALIDATION · development, sessions already inspected",
	evaluation="EVALUATION · development only, not a fresh holdout",
}
-- Live forward test (spring-live-contract.md L12; append-only additions, 2026-10-05): run kind live_native and the
-- calibration_lead_in / forward_test partitions (L12 texts, lead segment upper-cased like the panel's other partitions).
RUN_KINDS.live_native=true
PARTITION_TEXT.calibration_lead_in="2024 LEAD-IN · calibration period · not traded"
PARTITION_TEXT.forward_test="FORWARD TEST · 2025-2026 · frozen 2024 protocol, never tuned here"
local BANK_LABELS={"FAST","MEDIUM","SLOW"}
local ROBLOX_GLOBALS={"Instance","UDim2","UDim","Color3","Enum","Vector2"}

local Panel={}
Panel.__index=Panel

local function finite(x) return type(x)=="number" and x==x and math.abs(x)<math.huge end
local function isInteger(x) return finite(x) and x%1==0 end
local function fail(message) error("SpringPanel: "..message,3) end
local function text(x) return if x==nil or x=="" then "—" else tostring(x) end
local function signed(x,digits) return if finite(x) then string.format("%+."..(digits or 4).."f",x) else "—" end
local function plain(x,digits) return if finite(x) then string.format("%."..(digits or 4).."f",x) else "—" end
local function whole(x) return if finite(x) then string.format("%.0f",x) else "—" end
local function band(x,digits) return if finite(x) then "±"..string.format("%."..(digits or 4).."f",math.abs(x)) else "—" end

local function resolveEnv(options)
	local injected=options.env
	if injected~=nil and type(injected)~="table" then fail("options.env must be a table") end
	local defaults={Instance=Instance,UDim2=UDim2,UDim=UDim,Color3=Color3,Enum=Enum,Vector2=Vector2}
	local env={}
	for _,name in ROBLOX_GLOBALS do
		local value=injected and injected[name]
		if value==nil then value=defaults[name] end
		if value==nil then fail("Roblox global "..name.." is unavailable; inject it through options.env") end
		env[name]=value
	end
	return env
end

-- Pure: the reason a row cannot be displayed, or nil.
local function rowProblem(row,label)
	if type(row)~="table" then return label.." must be a table" end
	if not isInteger(row.index) or row.index<1 then return label..".index must be a positive integer" end
	if not finite(row.t) then return label..".t must be finite" end
	if type(row.runId)~="string" or row.runId=="" then return label..".runId must be a non-empty string" end
	if not RUN_KINDS[row.runKind] then return label..".runKind is unknown: "..tostring(row.runKind) end
	if type(row.header)~="string" or row.header=="" then return label..".header is required" end
	if type(row.partition)~="string" then return label..".partition is required" end
	if type(row.diagnostics)~="table" then return label..".diagnostics is required" end
	if type(row.final)~="table" or type(row.final.action)~="string" then return label..".final.action is required" end
	if type(row.intent)~="table" or type(row.intent.action)~="string" then return label..".intent.action is required" end
	if row.policy~=nil and type(row.policy)~="table" then return label..".policy must be a table" end
	if row.position~=-1 and row.position~=0 and row.position~=1 then return label..".position must be -1, 0 or 1" end
	if not finite(row.equity) then return label..".equity must be finite" end
	if type(row.executions)~="table" then return label..".executions must be a list" end
	if row.pending~=nil and (type(row.pending)~="table" or type(row.pending.action)~="string") then return label..".pending must carry an action" end
	if type(row.evidence)~="table" then return label..".evidence is required" end
	if row.thresholds~=nil and type(row.thresholds)~="table" then return label..".thresholds must be a table" end
	local contributions=row.diagnostics.nodeContributions
	if contributions~=nil then
		if type(contributions)~="table" or #contributions~=24 then return label..".diagnostics.nodeContributions must hold 24 values" end
		for i=1,24 do if not finite(contributions[i]) then return label..".diagnostics.nodeContributions["..i.."] must be finite" end end
	end
	local banks=row.diagnostics.bankScores
	if banks~=nil then
		if type(banks)~="table" or #banks~=3 then return label..".diagnostics.bankScores must hold 3 values" end
		for i=1,3 do if not finite(banks[i]) then return label..".diagnostics.bankScores["..i.."] must be finite" end end
	end
	return nil
end

local function flatten(value,limit)
	if value==nil then return "—" end
	if type(value)~="table" then return tostring(value) end
	local keys={}
	for key in value do table.insert(keys,tostring(key)) end
	table.sort(keys)
	local parts={}
	for _,key in keys do
		local item=value[key]
		if item==nil then item=value[tonumber(key)] end
		local shown
		if type(item)=="table" then
			local inner={}
			local innerKeys={}
			for k in item do table.insert(innerKeys,tostring(k)) end
			table.sort(innerKeys)
			for _,k in innerKeys do
				local v=item[k]
				if v==nil then v=item[tonumber(k)] end
				if type(v)~="table" then table.insert(inner,k.."="..tostring(v)) end
			end
			shown=key.."{"..table.concat(inner,", ").."}"
		else
			shown=key.."="..tostring(item)
		end
		table.insert(parts,shown)
		if #parts>=(limit or 12) then table.insert(parts,"…");break end
	end
	return table.concat(parts," · ")
end

local function positionName(position)
	if position==1 then return "LONG" elseif position==-1 then return "SHORT" end
	return "FLAT"
end

-- Pure: every string, colour key and bar geometry the panel shows for one row.
function Panel:_describe(row,compareRow,context)
	local d={}
	local diagnostics=row.diagnostics
	local thresholds=row.thresholds or {}
	local policy=row.policy or {}
	local noInput=NO_PHYSICAL_INPUT[row.runKind]==true
	d.header=row.header
	local provenance=context.provenance
	if type(provenance)=="table" then provenance=flatten(provenance,6) end
	d.provenance=string.format("run %s · %s · sample %s%s",row.runId,row.runKind,text(row.sampleId),
		if type(provenance)=="string" and provenance~="" then " · "..provenance else "")
	d.timestamp=string.format("%s · t %s · available %s",text(row.label),whole(row.t),whole(row.availableT))
	d.partition=PARTITION_TEXT[row.partition] or string.upper(row.partition)
	local rowCount=context.rowCount
	d.counter=string.format("row %d / %s",row.index,if isInteger(rowCount) then tostring(rowCount) else "?")
	d.fraction=if isInteger(rowCount) and rowCount>1 then math.clamp((row.index-1)/(rowCount-1),0,1) else 0
	d.score=string.format("SCORE %s",signed(diagnostics.score))
	d.setup=string.format("setup %s%s",text(policy.setup),if diagnostics.valid==false then " · invalid: "..text(diagnostics.reason) else "")
	d.thresholds=string.format("entry %s · exit %s · bank deadband %s",band(thresholds.entry),band(thresholds.exit),band(thresholds.bankDeadband))
	d.scoreValue=diagnostics.score
	d.entry=thresholds.entry;d.exit=thresholds.exit;d.deadband=thresholds.bankDeadband
	d.banks={}
	for b=1,3 do
		local value=diagnostics.bankScores and diagnostics.bankScores[b]
		d.banks[b]={value=value,text=signed(value)}
	end
	d.contributions={}
	local contributions=diagnostics.nodeContributions
	if noInput then
		d.contributions[1]="no physical input · this run's decisions use no spring state"
	elseif contributions then
		local order={}
		for i=1,24 do if contributions[i]~=0 then table.insert(order,i) end end
		table.sort(order,function(a,b)
			local da,db=math.abs(contributions[a]),math.abs(contributions[b])
			if da==db then return a<b end
			return da>db
		end)
		for rank=1,math.min(TOP_CONTRIBUTIONS,#order) do
			local i=order[rank]
			local node=self._nodes[i]
			d.contributions[rank]=string.format("%d. %s · %s  %s",rank,node.name,node.input,signed(contributions[i]))
		end
		if #order==0 then d.contributions[1]="all node contributions are exactly 0" end
	else
		d.contributions[1]="no node contributions recorded for this row"
	end
	d.policyCounters=string.format("warm-up %s · confirm +%s / −%s · exit long %s / short %s",
		whole(policy.warmup),whole(policy.posConfirm),whole(policy.negConfirm),whole(policy.longExit),whole(policy.shortExit))
	d.policyState=string.format("blocked: %s",text(policy.blocked))
	local intent,final=row.intent,row.final
	d.intent=string.format("INTENT  %s · %s · %s",intent.action,text(intent.source),text(intent.reason))
	d.final=string.format("FINAL  %s · %s · %s%s",final.action,text(final.source),text(final.reason),if final.overridden then " · OVERRIDDEN" else "")
	d.overridden=final.overridden==true
	local conditions=final.riskConditions
	d.conditions="override conditions: "..(if type(conditions)=="table" and #conditions>0 then table.concat(conditions,", ") else "none")
	local pending=row.pending
	d.pending=if pending then string.format("PENDING  %s · %s · %s · signalT %s · fills at next open",pending.action,text(pending.source),text(pending.reason),whole(pending.signalT))
		else "PENDING  none"
	d.position=string.format("POSITION %s (%+d) · hold %s bars · equity %s",positionName(row.position),row.position,whole(row.holdBars),plain(row.equity,5))
	d.levels=string.format("stop %s · target %s",plain(row.stop,4),plain(row.target,4))
	d.fills={}
	local executions=row.executions
	if #executions==0 then
		d.fills[1]="FILLS  none this bar"
	else
		for k=1,math.min(FILL_LINES,#executions) do
			local fill=executions[k]
			d.fills[k]=string.format("FILL %s · side %s @ %s · %s · %s%s",text(fill.action),text(fill.side),plain(fill.price,4),
				text(fill.source),text(fill.reason),if finite(fill.signalT) then " · signalT "..whole(fill.signalT) else "")
		end
		if #executions>FILL_LINES then d.fills[FILL_LINES]=d.fills[FILL_LINES]..string.format("  (+%d more)",#executions-FILL_LINES) end
	end
	local evidence=row.evidence
	d.evidenceImplementation="implementation: "..text(evidence.implementationStatus)
	d.evidenceDependence="physics dependence: "..text(evidence.physicsDependence)
	d.evidenceMarket="market evidence: "..text(evidence.marketEvidence)
	local resultEvidence=context.evidence
	local counts=type(resultEvidence)=="table" and resultEvidence.physicsDependenceCounts or nil
	d.evidenceCounts=if counts~=nil then "dependence counts: "..flatten(counts,8)
		elseif resultEvidence~=nil then "result evidence: "..flatten(resultEvidence,8) else "dependence counts: —"
	d.comparisons=if context.comparisons~=nil then "comparisons: "..flatten(context.comparisons,10) else "comparisons: —"
	if compareRow then
		d.compareHeader=string.format("COMPARE  %s · %s",text(compareRow.runLabel or compareRow.runId),compareRow.header)
		local aligned=compareRow.index==row.index and compareRow.t==row.t
		d.compareAligned=aligned
		d.compareAlignment=if aligned then string.format("aligned · same observation #%d · %s",row.index,text(row.label))
			else string.format("MISALIGNED · compare #%d t %s vs selected #%d t %s",compareRow.index,whole(compareRow.t),row.index,whole(row.t))
		d.compareSummary=string.format("score %s · final %s · %s · position %s · equity %s",signed(compareRow.diagnostics.score),
			compareRow.final.action,text(compareRow.final.reason),positionName(compareRow.position),plain(compareRow.equity,5))
	else
		d.compareHeader="COMPARE  no comparison row selected"
		d.compareAligned=nil
		d.compareAlignment="—"
		d.compareSummary="—"
	end
	d.noInput=noInput
	d.runId=row.runId
	return d
end

function SpringPanel.mount(parent,options)
	options=options or {}
	if type(options)~="table" then fail("options must be a table") end
	local env=resolveEnv(options)
	if parent==nil or (type(parent)~="table" and type(parent)~="userdata") then fail("parent instance required") end
	local callbacks=options.callbacks or {}
	if type(callbacks)~="table" then fail("options.callbacks must be a table") end
	local nodes={}
	local descriptor=options.descriptor
	for i=1,24 do
		local node=descriptor and descriptor.nodes and descriptor.nodes[i]
		local input=node and (node.dominantName or (descriptor.driveNames and descriptor.driveNames[node.dominantChannel]))
		nodes[i]={name=if node and type(node.name)=="string" then node.name else string.format("node %02d",i),input=if type(input)=="string" then input else "dominant input —"}
	end
	local UD2,C3,E=env.UDim2,env.Color3,env.Enum
	-- Terminal palette (owner request, 2026-10-05): black, amber accent ("cyan" key = the primary accent), white values,
	-- green up / red down, yellow warnings ("amber" key = the warning colour).
	local C={bg=C3.fromRGB(0,0,0),panel=C3.fromRGB(14,14,14),raised=C3.fromRGB(28,28,28),line=C3.fromRGB(60,60,60),
		text=C3.fromRGB(240,240,240),muted=C3.fromRGB(150,150,150),cyan=C3.fromRGB(251,139,30),green=C3.fromRGB(74,232,90),
		red=C3.fromRGB(255,67,61),amber=C3.fromRGB(255,214,0),grey=C3.fromRGB(100,100,100)}
	local panel=setmetatable({_destroyed=false,_connections={},_handlers={},_callbacks=callbacks,_nodes=nodes,_playing=false,
		_rowCount=nil,_index=nil,_runButtons={},_runs={},_colors=C,env=env},Panel)
	local created={}
	local function make(className,parentInstance,props)
		local instance=env.Instance.new(className)
		table.insert(created,instance)
		for key,value in props do instance[key]=value end
		if parentInstance then instance.Parent=parentInstance end
		return instance
	end
	panel._make=make
	local function round(instance,radius) make("UICorner",instance,{CornerRadius=env.UDim.new(0,radius or 6)}) end
	local function label(parentInstance,name,y,height,size,color,font,x,width)
		return make("TextLabel",parentInstance,{Name=name,Text="",Position=UD2.fromOffset(x or PAD,y),Size=UD2.fromOffset(width or INNER,height),
			BackgroundTransparency=1,TextColor3=color or C.text,Font=font or E.Font.Gotham,TextSize=size or 11,TextWrapped=true,
			TextXAlignment=E.TextXAlignment.Left,TextYAlignment=E.TextYAlignment.Center,TextTruncate=E.TextTruncate.AtEnd})
	end
	local function caption(parentInstance,name,value,y)
		local item=label(parentInstance,name,y,12,9,C.cyan,E.Font.GothamBold) -- section captions in the amber accent
		item.Text=value
		return item
	end
	local ok,err=pcall(function()
		local gui=make("ScreenGui",nil,{Name=GUI_NAME,ResetOnSpawn=false,IgnoreGuiInset=true,DisplayOrder=61,ZIndexBehavior=E.ZIndexBehavior.Sibling,Enabled=true})
		gui:SetAttribute("SpringPanel",true);gui:SetAttribute("Experimental",true);gui:SetAttribute("NotApprovedForTrading",true)
		panel.screenGui=gui
		local dock=make("Frame",gui,{Name="Dock",AnchorPoint=env.Vector2.new(1,0),Position=UD2.new(1,0,0,0),Size=UD2.new(0,WIDTH,1,0),
			BackgroundColor3=C.bg,BackgroundTransparency=0,BorderSizePixel=0})
		make("UIStroke",dock,{Color=C.line,Thickness=1,Transparency=0.2})
		local content=make("ScrollingFrame",dock,{Name="Content",Position=UD2.fromOffset(0,0),Size=UD2.new(1,0,1,0),CanvasSize=UD2.fromOffset(0,CONTENT_HEIGHT),
			ScrollBarThickness=6,ScrollingDirection=E.ScrollingDirection.Y,BackgroundTransparency=1,BorderSizePixel=0,ScrollBarImageColor3=C.line})
		panel._content=content
		local L={}
		local function button(id,value,x,y,width,height,handler,primary)
			local b=make("TextButton",content,{Name=id,Text=value,Position=UD2.fromOffset(x,y),Size=UD2.fromOffset(width,height),
				BackgroundColor3=if primary then C.cyan else C.raised,TextColor3=if primary then C.bg else C.text,TextSize=11,Font=E.Font.GothamMedium,
				BorderSizePixel=0,AutoButtonColor=true,TextTruncate=E.TextTruncate.AtEnd})
			round(b,5)
			panel._handlers[id]=handler
			table.insert(panel._connections,b.MouseButton1Click:Connect(function() if not panel._destroyed then handler() end end))
			return b
		end
		-- Header and provenance.
		L.brand=label(content,"Brand",6,18,13,C.cyan,E.Font.GothamBold,PAD,280);L.brand.Text="ROALGO · SPRING INDICATOR"
		button("Exit","Exit spring mode",WIDTH-PAD-118,5,118,20,function() panel:_invoke("onExit") end)
		L.header=label(content,"Header",26,28,11,C.text,E.Font.GothamMedium);L.header.Text="No spring row loaded"
		L.provenance=label(content,"Provenance",55,13,9,C.muted);L.provenance.Text="—"
		L.timestamp=label(content,"Timestamp",70,16,12,C.text,E.Font.GothamBold);L.timestamp.Text="—"
		L.partition=label(content,"Partition",87,14,11,C.amber,E.Font.GothamMedium);L.partition.Text="—"
		-- Run selector (rows of four, filled by setRuns).
		caption(content,"RunCaption","RUN",104)
		panel._runTop=118
		-- Transport.
		local transportY=166
		button("Previous","◀ Prev",PAD,transportY,62,24,function() panel:_invoke("onStep",-1) end)
		panel._playButton=button("PlayPause","Play",PAD+68,transportY,72,24,function() panel:_togglePlay() end,true)
		button("Next","Next ▶",PAD+146,transportY,62,24,function() panel:_invoke("onStep",1) end)
		local goTo=make("TextBox",content,{Name="GoTo",Text="",PlaceholderText="row #",ClearTextOnFocus=true,Position=UD2.fromOffset(PAD+214,transportY),
			Size=UD2.fromOffset(62,24),BackgroundColor3=C.panel,TextColor3=C.text,TextSize=11,Font=E.Font.Code,BorderSizePixel=0})
		round(goTo,5)
		panel._goTo=goTo
		panel._handlers.GoTo=function(value) panel:_goToRow(value) end
		table.insert(panel._connections,goTo.FocusLost:Connect(function(enterPressed)
			if not panel._destroyed and enterPressed then panel:_goToRow(goTo.Text) end
		end))
		L.counter=label(content,"RowCounter",transportY,24,11,C.muted,E.Font.GothamMedium,PAD+282,INNER-282);L.counter.Text="row — / —"
		L.counter.TextXAlignment=E.TextXAlignment.Right
		local track=make("TextButton",content,{Name="ScrubTrack",Text="",TextSize=10,AutoButtonColor=false,Position=UD2.fromOffset(PAD,transportY+30),Size=UD2.fromOffset(INNER,12),
			BackgroundColor3=C.panel,BorderSizePixel=0})
		round(track,4)
		local fill=make("Frame",track,{Name="Fill",Position=UD2.fromOffset(0,0),Size=UD2.new(0,0,1,0),BackgroundColor3=C.cyan,BackgroundTransparency=0.35,BorderSizePixel=0})
		round(fill,4)
		local handle=make("Frame",track,{Name="Handle",AnchorPoint=env.Vector2.new(0.5,0.5),Position=UD2.new(0,0,0.5,0),Size=UD2.fromOffset(6,16),BackgroundColor3=C.text,BorderSizePixel=0})
		panel._track,panel._fill,panel._handle=track,fill,handle
		local dragging=false
		local function scrubAt(x) if not panel._destroyed then panel:_scrubAtScreenX(x) end end
		panel._handlers.Scrub=function(index) panel:_scrubTo(index) end
		table.insert(panel._connections,track.MouseButton1Down:Connect(function(x) dragging=true;scrubAt(x) end))
		table.insert(panel._connections,track.MouseMoved:Connect(function(x) if dragging then scrubAt(x) end end))
		table.insert(panel._connections,track.MouseButton1Up:Connect(function() dragging=false end))
		table.insert(panel._connections,track.MouseLeave:Connect(function() dragging=false end))
		-- Score, thresholds and bank bars.
		local scoreY=214
		L.score=label(content,"Score",scoreY,20,16,C.text,E.Font.GothamBold,PAD,190);L.score.Text="SCORE —"
		L.setup=label(content,"Setup",scoreY,20,11,C.muted,E.Font.GothamMedium,PAD+196,INNER-196);L.setup.Text="setup —"
		L.thresholds=label(content,"Thresholds",scoreY+21,13,10,C.muted);L.thresholds.Text="entry — · exit — · bank deadband —"
		local function bar(name,y,x,width)
			local back=make("Frame",content,{Name=name,Position=UD2.fromOffset(x,y),Size=UD2.fromOffset(width,10),BackgroundColor3=C.panel,BorderSizePixel=0})
			make("Frame",back,{Name="Zero",AnchorPoint=env.Vector2.new(0.5,0),Position=UD2.new(0.5,0,0,0),Size=UD2.new(0,1,1,0),BackgroundColor3=C.muted,BorderSizePixel=0})
			local value=make("Frame",back,{Name="Value",Position=UD2.new(0.5,0,0,1),Size=UD2.new(0,0,1,-2),BackgroundColor3=C.muted,BorderSizePixel=0})
			local ticks={}
			for k,tickName in {"TickPlus","TickMinus","TickPlusExit","TickMinusExit"} do
				ticks[k]=make("Frame",back,{Name=tickName,AnchorPoint=env.Vector2.new(0.5,0),Position=UD2.new(0.5,0,0,0),Size=UD2.new(0,2,1,0),
					BackgroundColor3=if k<=2 then C.amber else C.muted,BorderSizePixel=0,Visible=false})
			end
			return {back=back,value=value,ticks=ticks}
		end
		panel._scoreBar=bar("ScoreBar",scoreY+36,PAD,INNER)
		panel._bankBars={}
		L.banks={}
		for b=1,3 do
			local y=scoreY+50+(b-1)*15
			local name=label(content,"BankName"..b,y,13,9,C.muted,E.Font.GothamBold,PAD,52);name.Text=BANK_LABELS[b]
			panel._bankBars[b]=bar("BankBar"..b,y+2,PAD+56,INNER-56-72)
			L.banks[b]=label(content,"BankValue"..b,y,13,10,C.text,E.Font.GothamMedium,WIDTH-PAD-68,68);L.banks[b].Text="—"
			L.banks[b].TextXAlignment=E.TextXAlignment.Right
		end
		-- Node contributions.
		local contributionY=312
		caption(content,"ContributionCaption","TOP NODE CONTRIBUTIONS",contributionY)
		L.contributions={}
		for rank=1,TOP_CONTRIBUTIONS do
			L.contributions[rank]=label(content,"Contribution"..rank,contributionY+12+(rank-1)*13,13,10,C.text,E.Font.GothamMedium)
		end
		-- Policy counters.
		local policyY=378
		caption(content,"PolicyCaption","POLICY",policyY)
		L.policyCounters=label(content,"PolicyCounters",policyY+12,13,10,C.text);L.policyCounters.Text="—"
		L.policyState=label(content,"PolicyState",policyY+25,13,10,C.muted);L.policyState.Text="blocked: —"
		-- Actions.
		local actionY=420
		caption(content,"ActionCaption","ACTION · INTENT VS FINAL",actionY)
		L.intent=label(content,"Intent",actionY+12,13,10,C.text,E.Font.GothamMedium);L.intent.Text="INTENT  —"
		L.final=label(content,"Final",actionY+25,13,10,C.text,E.Font.GothamBold);L.final.Text="FINAL  —"
		L.conditions=label(content,"Conditions",actionY+38,13,10,C.muted);L.conditions.Text="override conditions: —"
		L.pending=label(content,"Pending",actionY+51,13,10,C.text);L.pending.Text="PENDING  —"
		-- Ledger.
		local ledgerY=488
		caption(content,"LedgerCaption","LEDGER · SIMULATED HISTORICAL EXECUTION",ledgerY)
		L.position=label(content,"Position",ledgerY+12,13,10,C.text,E.Font.GothamMedium);L.position.Text="POSITION —"
		L.levels=label(content,"Levels",ledgerY+25,13,10,C.muted);L.levels.Text="stop — · target —"
		L.fills={}
		for k=1,FILL_LINES do L.fills[k]=label(content,"Fill"..k,ledgerY+38+(k-1)*13,13,10,C.text) end
		-- Evidence.
		local evidenceY=571
		caption(content,"EvidenceCaption","EVIDENCE",evidenceY)
		L.evidenceImplementation=label(content,"EvidenceImplementation",evidenceY+12,13,10,C.text)
		L.evidenceDependence=label(content,"EvidenceDependence",evidenceY+25,13,10,C.text)
		L.evidenceMarket=label(content,"EvidenceMarket",evidenceY+38,13,10,C.text)
		L.evidenceCounts=label(content,"EvidenceCounts",evidenceY+51,13,9,C.muted)
		L.notApproved=label(content,"NotApproved",evidenceY+64,13,10,C.amber,E.Font.GothamBold);L.notApproved.Text=NOT_APPROVED
		-- Comparison strip (a second displayRow at the same index).
		local compareY=650
		caption(content,"CompareCaption","COMPARISON · SAME OBSERVATION",compareY)
		L.compareHeader=label(content,"CompareHeader",compareY+12,13,10,C.text,E.Font.GothamMedium);L.compareHeader.Text="COMPARE  —"
		L.compareAlignment=label(content,"CompareAlignment",compareY+25,13,10,C.muted);L.compareAlignment.Text="—"
		L.compareSummary=label(content,"CompareSummary",compareY+38,13,10,C.text);L.compareSummary.Text="—"
		L.comparisons=label(content,"Comparisons",compareY+51,13,9,C.muted);L.comparisons.Text="comparisons: —"
		L.status=label(content,"Status",compareY+64,12,9,C.muted);L.status.Text="Ready · presentation only; values come from the loaded spring result"
		panel._labels=L
		gui:SetAttribute("RowIndex",0)
	end)
	if not ok then
		for _,instance in created do pcall(function() instance:Destroy() end) end
		error(tostring(err),2)
	end
	panel._created=created
	panel.screenGui.Parent=parent
	return panel
end

function Panel:_invoke(name,...)
	if self._destroyed then return false end
	local callback=self._callbacks[name]
	if type(callback)~="function" then return false end
	local ok,err=pcall(callback,...)
	if not ok then self:setStatus("Error: "..tostring(err)) end
	return ok
end

function Panel:setStatus(value)
	if self._destroyed then return end
	self._labels.status.Text=tostring(value)
	self.screenGui:SetAttribute("Status",tostring(value))
end

function Panel:setPlaying(playing)
	if self._destroyed then return end
	self._playing=playing==true
	self._playButton.Text=if self._playing then "Pause" else "Play"
	self.screenGui:SetAttribute("Playing",self._playing)
end

function Panel:_togglePlay()
	if self._playing then
		self:setPlaying(false);self:_invoke("onPause")
	else
		self:setPlaying(true);self:_invoke("onPlay")
	end
end

function Panel:_scrubTo(index)
	local count=self._rowCount
	if not isInteger(count) or not isInteger(index) then return false end
	index=math.clamp(index,1,count)
	-- Skip a repeat of the last requested row (drag jitter) and, before any request, the row already shown.
	if index==self._lastScrub or (self._lastScrub==nil and index==self._index) then return false end
	self._lastScrub=index
	return self:_invoke("onScrub",index)
end

function Panel:_scrubAtScreenX(x)
	local count=self._rowCount
	if not isInteger(count) or not finite(x) then return false end
	local position,size=self._track.AbsolutePosition,self._track.AbsoluteSize
	if not position or not size or not finite(size.X) or size.X<=0 then return false end
	local fraction=math.clamp((x-position.X)/size.X,0,1)
	return self:_scrubTo(math.floor(fraction*(count-1)+0.5)+1)
end

function Panel:_goToRow(value)
	local index=tonumber(value)
	local count=self._rowCount
	if not isInteger(index) or not isInteger(count) or index<1 or index>count then
		self:setStatus(string.format("Row must be a whole number from 1 to %s",if isInteger(count) then tostring(count) else "?"))
		return false
	end
	self._lastScrub=nil
	return self:_scrubTo(index)
end

function Panel:testActivate(id,...)
	assert(not self._destroyed,"SpringPanel: panel destroyed")
	local handler=self._handlers[id]
	assert(handler,"SpringPanel: unknown control "..tostring(id))
	handler(...)
	return true
end

function Panel:setRuns(runs)
	if self._destroyed then error("SpringPanel: setRuns after destroy",2) end
	if type(runs)~="table" or #runs<1 or #runs>MAX_RUNS then error("SpringPanel: setRuns needs 1 to 8 runs",2) end
	local seen={}
	for i,run in runs do
		if type(run)~="table" or type(run.id)~="string" or run.id=="" or seen[run.id] then error("SpringPanel: run "..i.." needs a unique id",2) end
		if not RUN_KINDS[run.kind] then error("SpringPanel: run "..run.id.." has unknown kind "..tostring(run.kind),2) end
		seen[run.id]=true
	end
	for _,old in self._runButtons do
		self._handlers[old.Name]=nil
		old:Destroy()
	end
	local env,C=self.env,self._colors
	local buttons={}
	local width=(INNER-3*6)/4
	for i,run in runs do
		local id=run.id
		local column,row=(i-1)%4,math.floor((i-1)/4)
		local b=self._make("TextButton",self._content,{Name="Run_"..id,Text=if type(run.label)=="string" and run.label~="" then run.label else id,
			Position=env.UDim2.fromOffset(PAD+column*(width+6),self._runTop+row*22),Size=env.UDim2.fromOffset(width,20),
			BackgroundColor3=C.raised,TextColor3=C.text,TextSize=10,Font=env.Enum.Font.GothamMedium,BorderSizePixel=0,AutoButtonColor=true,
			TextTruncate=env.Enum.TextTruncate.AtEnd})
		b:SetAttribute("RunId",id);b:SetAttribute("RunKind",run.kind)
		if isInteger(run.rowCount) then b:SetAttribute("RowCount",run.rowCount) end
		local handler=function() self:_invoke("onRun",id) end
		self._handlers[b.Name]=handler
		table.insert(self._connections,b.MouseButton1Click:Connect(function() if not self._destroyed then handler() end end))
		table.insert(buttons,b)
	end
	self._runButtons=buttons
	self._runs=runs
	self:_highlightRun(self._selectedRun)
end

function Panel:_highlightRun(runId)
	local C=self._colors
	for _,b in self._runButtons do
		local selected=b:GetAttribute("RunId")==runId
		b.BackgroundColor3=if selected then C.cyan else C.raised
		b.TextColor3=if selected then C.bg else C.text
	end
end

local function placeBar(env,C,bar,value,scale,ticks)
	local UD2=env.UDim2
	local range=math.max(1,if finite(value) then math.abs(value) else 0)
	for _,tick in ticks do range=math.max(range,if finite(tick) then math.abs(tick) else 0) end
	if finite(value) and value~=0 then
		local w=math.abs(value)/range*0.5
		bar.value.Position=if value>0 then UD2.new(0.5,0,0,1) else UD2.new(0.5-w,0,0,1)
		bar.value.Size=UD2.new(w,0,1,-2)
		bar.value.BackgroundColor3=if scale then (if value>0 then C.green else C.red) else C.muted
	else
		bar.value.Position=UD2.new(0.5,0,0,1);bar.value.Size=UD2.new(0,0,1,-2);bar.value.BackgroundColor3=C.muted
	end
	local marks={ticks[1],if finite(ticks[1]) then -ticks[1] else nil,ticks[2],if finite(ticks[2]) then -ticks[2] else nil}
	for k,tick in bar.ticks do
		local at=marks[k]
		tick.Visible=finite(at)
		if finite(at) then tick.Position=UD2.new(0.5+at/range*0.5,0,0,0) end
	end
end

-- Validates both rows before any property changes, then sets every field from the same row.
function Panel:update(row,compareRow,context)
	if self._destroyed then error("SpringPanel: update after destroy",2) end
	local problem=rowProblem(row,"displayRow")
	if not problem and compareRow~=nil then problem=rowProblem(compareRow,"compareRow") end
	if not problem and context~=nil and type(context)~="table" then problem="context must be a table" end
	if not problem and context and context.rowCount~=nil and (not isInteger(context.rowCount) or context.rowCount<row.index) then
		problem="context.rowCount must be a whole number >= displayRow.index"
	end
	if problem then error("SpringPanel: rejected row: "..problem,2) end
	context=context or {}
	local d=self:_describe(row,compareRow,context)
	local env,C,L=self.env,self._colors,self._labels
	L.header.Text=d.header;L.provenance.Text=d.provenance;L.timestamp.Text=d.timestamp;L.partition.Text=d.partition
	L.counter.Text=d.counter
	self._fill.Size=env.UDim2.new(d.fraction,0,1,0);self._handle.Position=env.UDim2.new(d.fraction,0,0.5,0)
	L.score.Text=d.score;L.score.TextColor3=if d.noInput then C.grey elseif finite(d.scoreValue) and d.scoreValue>0 then C.green elseif finite(d.scoreValue) and d.scoreValue<0 then C.red else C.text
	L.setup.Text=d.setup;L.thresholds.Text=d.thresholds
	placeBar(env,C,self._scoreBar,d.scoreValue,true,{d.entry,d.exit})
	for b=1,3 do
		L.banks[b].Text=d.banks[b].text
		local value=d.banks[b].value
		placeBar(env,C,self._bankBars[b],value,finite(value) and finite(d.deadband) and math.abs(value)>=math.abs(d.deadband),{d.deadband,nil})
	end
	for rank=1,TOP_CONTRIBUTIONS do
		L.contributions[rank].Text=d.contributions[rank] or ""
		L.contributions[rank].TextColor3=if d.noInput then C.grey else C.text
	end
	L.policyCounters.Text=d.policyCounters;L.policyState.Text=d.policyState
	L.intent.Text=d.intent;L.final.Text=d.final;L.final.TextColor3=if d.overridden then C.amber else C.text
	L.conditions.Text=d.conditions;L.pending.Text=d.pending
	L.position.Text=d.position;L.levels.Text=d.levels
	for k=1,FILL_LINES do L.fills[k].Text=d.fills[k] or "" end
	L.evidenceImplementation.Text=d.evidenceImplementation;L.evidenceDependence.Text=d.evidenceDependence
	L.evidenceMarket.Text=d.evidenceMarket;L.evidenceCounts.Text=d.evidenceCounts;L.notApproved.Text=NOT_APPROVED
	L.compareHeader.Text=d.compareHeader;L.compareAlignment.Text=d.compareAlignment;L.compareSummary.Text=d.compareSummary
	L.compareAlignment.TextColor3=if d.compareAligned==false then C.red else C.muted
	L.comparisons.Text=d.comparisons
	self._index=row.index
	self._rowCount=if isInteger(context.rowCount) then context.rowCount else self._rowCount
	self._lastScrub=nil
	self._selectedRun=row.runId
	self:_highlightRun(row.runId)
	if type(context.playing)=="boolean" then self:setPlaying(context.playing) end
	local gui=self.screenGui
	gui:SetAttribute("RowIndex",row.index);gui:SetAttribute("RunId",row.runId);gui:SetAttribute("RunKind",row.runKind)
	gui:SetAttribute("SampleId",row.sampleId or "");gui:SetAttribute("ObservationT",row.t)
	gui:SetAttribute("CompareRunId",if compareRow then compareRow.runId else "")
	gui:SetAttribute("CompareAligned",d.compareAligned)
	return d
end

function Panel:destroy()
	if self._destroyed then return end
	self._destroyed=true
	for _,connection in self._connections do connection:Disconnect() end
	self._connections={}
	self._handlers={}
	self._callbacks={}
	local gui=self.screenGui
	self._labels=nil;self._runButtons={}
	if gui then gui:Destroy() end
end

SpringPanel.GUI_NAME=GUI_NAME
SpringPanel.WIDTH=WIDTH
SpringPanel.NOT_APPROVED=NOT_APPROVED
SpringPanel.validateRow=function(row) return rowProblem(row,"displayRow") end
return SpringPanel
