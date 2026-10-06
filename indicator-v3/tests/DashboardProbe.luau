-- Native UI construction/layout and callback-handler probe. No physical mouse/input claim.
local Probe={}
-- Pure data-binding checks run in the CLI; the native construction probe below
-- remains a separate Studio check and is never replaced by simulated UI results.
function Probe.runData(Dashboard)
 assert(type(Dashboard.describe)=='function','Dashboard must derive rolling selection from actual snapshot data')
 local nodes24,nodes48={},{}
 for i=1,24 do nodes24[i]={x=0,v=0} end
 for i=1,48 do nodes48[i]={x=0,v=0} end
 local snapshot={selectedVariant='memory',selectedFold=2,selectedConfiguration='grouped48',
  comparisons={{id='memory',report={selectedPolicyId='six_bar_timeout',policyCandidates={{},{},{},{}}},result={summary={netReturn=.01}}}},
  latestRecord={states={coupled={nodes=nodes48}}},study={foldDescriptors={{id='first'},{id='second'},{id='third'}},
  configurations={{id='grouped24',nodeCount=24},{id='grouped48',nodeCount=48}},aggregate={groups={
   {id='memory',configurationId='grouped24',meanNetReturn=.50,worstDrawdown=.4,totalTrades=999,folds=3,attemptedFolds=3},
   {id='memory',configurationId='grouped48',meanNetReturn=.02,worstDrawdown=.03,totalTrades=12,folds=2,attemptedFolds=3,failedFolds=1}}}}}
 local d=Dashboard.describe(snapshot,{node=48})
 assert(d.variant=='memory' and d.foldIndex==2 and d.foldCount==3 and d.configurationId=='grouped48','snapshot owns active model, fold and architecture selection')
 assert(d.nodeCount==48 and d.nodeIndex==48 and d.diagnosticOnly,'memory readout uses native inspector only as an explicitly unused diagnostic')
 assert(d.policyId=='six_bar_timeout' and d.policyBudget==4,'show actual frozen policy identity and recorded candidate budget')
 assert(#d.aggregateRows==1 and d.aggregateRows[1].meanNetReturn==.02 and d.aggregateRows[1].totalTrades==12,'aggregate filters selected configuration without summing or compounding returns')
 assert(d.aggregateRows[1].failedFolds==1 and d.aggregateRows[1].attemptedFolds==3,'incomplete fold counts remain visible')
 snapshot.latestRecord={states={coupled={nodes=nodes24}}};snapshot.selectedFold=999
 local smaller=Dashboard.describe(snapshot,{node=48})
 assert(smaller.nodeCount==24 and smaller.nodeIndex==24 and smaller.foldIndex==3,'node and fold selections clamp to actual available data')
 local empty=Dashboard.describe(nil,{node=48})
 assert(empty.foldCount==0 and empty.foldIndex==0 and empty.nodeCount==0 and #empty.aggregateRows==0 and empty.policyId==nil,'empty snapshots have no fabricated data or stale policy')
 local refit={selectedVariant='coupled',selectedConfiguration='saved_v2_24',selectedFold=1,
  latestRecord={feature={drive=table.create(8,.1)},states={coupled={nodes=nodes24}}},
  study={configurations={{id='saved_v2_24',nodeCount=24}},foldDescriptors={{id='saved'}}},
  comparisons={{id='coupled',report={selectedPolicyId='no_trade',policySelectionReason='no_candidate_passed_validation_gates',validationMeanMSE=.002,validationZeroMeanMSE=.00001,validationMseRatioToZero=200,
    preprocessing={originalDimension=84,activeDimension=80,clipZ=5,droppedFeatures={{name='a'},{name='b'},{name='c'},{name='d'}},validationClipping={rows=30,clippedRows=9,clippedValues=15}}},
    result={rows={{prediction={clipping={clippedValues=3}}},{prediction={clipping={clippedValues=0}}}}}},
   {id='zero',model=nil,report={baseline=true,selectedPolicyId='no_trade',validationMeanMSE=.00001,validationZeroMeanMSE=.00001,validationMseRatioToZero=1}}}}
 local rd=Dashboard.describe(refit,{node=24})
 assert(rd.savedRefit and rd.driveCount==8,'saved v2 captures retain their actual eight-drive identity')
 assert(not rd.configurationAvailability.grouped24 and not rd.configurationAvailability.grouped48,'new architectures cannot be selected for a saved v2 capture')
 assert(rd.validationMetrics.coupled.ratio==200 and rd.validationMetrics.zero.ratio==1,'sixth ZERO baseline and actual validation ratios are visible')
 assert(rd.policyReason=='no_candidate_passed_validation_gates','failed validation gate remains distinct from a fitted model')
 assert(rd.normalization.dropped==4 and rd.normalization.validationClippedRows==9 and rd.normalization.evaluationClippedRows==1,'dropped and clipped feature evidence remains visible')
 print('PASS Dashboard data binding: dynamic nodes, fold/config selection, policy identity and independent aggregate summaries')
 return true
end
function Probe.run(parent,options)
 local opts=options or{}
 local report={ok=false,checks={},scope="Native ScreenGui construction, data binding, layout and shared callback handlers; synthetic execution data; no physical mouse events"}
 local ui
 local function check(name,passed,detail)table.insert(report.checks,{name=name,passed=passed,detail=detail})end
 local ok,err=pcall(function()
  local root=script.Parent.Parent
  local Dashboard=require(root.src.Dashboard)
  local Execution=require(root.src.Execution)
 local calls={run=0,stop=0,replay=0,viewRig=0,variant=0,selectFold=0,selectConfiguration=0}
  local args={}
  ui=Dashboard.mount(parent,{
   run=function(...)calls.run+=1;args.run={...}end,
   stop=function()calls.stop+=1 end,replay=function()calls.replay+=1 end,
   viewRig=function()calls.viewRig+=1 end,variant=function(id)calls.variant+=1;args.variant=id end,
   selectFold=function(index)calls.selectFold+=1;args.fold=index end,
   selectConfiguration=function(id)calls.selectConfiguration+=1;args.configuration=id end,
  })
  local gui=ui.screenGui
  check('v3 dashboard identity',gui.Name=='RoAlgoMarketDashboard')
  local function named(name)return gui:FindFirstChild(name,true)end
  check('longer 80/20/20 profile is the default',gui:GetAttribute('SelectedProfile')==3)
  check('zero baseline has a sixth selectable comparison',named('Variant_zero')~=nil and named('zeroMSE')~=nil and named('zeroZeroRatio')~=nil)
  ui:testActivate("QQQ");ui:testActivate("Profile2");ui:testActivate("Run")
  ui:testActivate("Stop");ui:testActivate("Replay");ui:testActivate("ViewPhysics")
  check("run callback receives chosen symbol/session profile/end date",calls.run==1 and args.run[1]=="QQQ" and args.run[2]==2 and args.run[3]=="2024-12-31",args.run)
  check("stop/replay/view callbacks invoked",calls.stop==1 and calls.replay==1 and calls.viewRig==1,calls)
  ui:testActivate("Collapse")
  check("collapse shows compact panel",not named("Terminal").Visible and named("Compact").Visible)
  ui:testActivate("Expand")
  check("expand restores dashboard",named("Terminal").Visible and not named("Compact").Visible)
  ui:testActivate("Variant_numeric")
  check("variant callback uses selected model id",calls.variant==1 and args.variant=="numeric")
  local execution=Execution.new({stopVol=10,targetVol=10})
  local rows={}
  for i,mean in {.001,.001,-.001,-.001,.001,.001,0}do
   rows[i]=execution:step({t=1731925800+(i-1)*300,label="fixture "..i,o=100,h=101,l=99,c=100},
    {ready=true,volatility=.1},{mean=mean,contributions={{name="intercept",value=mean}}})
  end
  local result=execution:result()
  local nodes={}
  for i=1,48 do nodes[i]={x=.25,v=.125,force=3,bank=math.floor((i-1)/16)+1,group=math.floor(((i-1)%16)/4)+1}end
  local record={feature={drive=table.create(12,.5),regime={.2,.3,.5}},states={coupled={nodes=nodes},independent={nodes=nodes},numeric={nodes=nodes}}}
  ui:render({symbol="QQQ",selectedVariant="numeric",selectedFold=2,selectedConfiguration='grouped48',rows=rows,latestRecord=record,
   study={foldDescriptors={{id='first'},{id='second'},{id='third'}},configurations={{id='grouped24',nodeCount=24},{id='grouped48',nodeCount=48}},aggregate={groups={{id='numeric',configurationId='grouped48',meanNetReturn=.02,worstDrawdown=.03,totalTrades=12,folds=2,attemptedFolds=3,failedFolds=1}}}},
   metadata={first="2024-11-18 09:30 ET",last="2024-12-31 15:55 ET",bars=2268,
    requestedSplits={train=20,validation=5,test=5},sessions={"2024-11-18"},counts={}},
   comparisons={{id="numeric",model={status="ok",samples={train=128,validation=32}},report={selectedPolicyId='six_bar_timeout',policyCandidates={{},{},{},{}}},result=result}}})
  check("numeric state explicitly computed",string.find(named("Inspector").Title.Text,"COMPUTED",1,true)~=nil,named("Inspector").Title.Text)
  check("execution trade direction shows readable long/short",string.find(named("Trade1").Text,"SHORT",1,true)~=nil,named("Trade1").Text)
  check("trade ledger includes cost amounts",string.find(named("Trade1").Text,"fees",1,true)~=nil,named("Trade1").Text)
  local coverage=named("DataCoverage")
  check("dataset coverage and fitted sample counts displayed",coverage and string.find(coverage.Text,"2268",1,true)~=nil
   and string.find(coverage.Text,"128",1,true)~=nil and string.find(coverage.Text,"32",1,true)~=nil,coverage and coverage.Text)
  check("recorded chart points bound correctly",gui:GetAttribute("ChartPoints")==#rows,gui:GetAttribute("ChartPoints"))
  local fills=0;for _,row in rows do fills+=#row.executions end
  check("actual execution fills have distinct markers",gui:GetAttribute("FillMarkers")==fills and fills>0,gui:GetAttribute("FillMarkers"))
  ui:testActivate("Node48")
  check("48-node selector updates recorded diagnostic",string.find(named("NodeInfo").Text,"Node 48",1,true)~=nil,named("NodeInfo").Text)
  check('all twelve market drive rows bind',named('Drive12').Text=='+0.500')
  check('selected frozen policy is displayed',string.find(named('SelectedPolicy').Text,'six_bar_timeout',1,true)~=nil)
  check('independent aggregate labels and actual figures',string.find(named('AggregateTitle').Text,'INDEPENDENT',1,true)~=nil and string.find(named('Aggregate_numeric').Text,'+2.00%',1,true)~=nil)
  ui:testActivate('FoldNext');check('next fold callback',args.fold==3 and calls.selectFold==1)
  ui:testActivate('FoldPrevious');check('previous fold callback',args.fold==2 and calls.selectFold==2)
  ui:testActivate('Configuration_grouped24');check('configuration callback',args.configuration=='grouped24' and calls.selectConfiguration==1)
  ui:testActivate('Variant_memory');check('memory comparison callback',args.variant=='memory')
  local fewer={};for i=1,24 do fewer[i]=nodes[i] end
  local smallerRecord={feature=record.feature,states={coupled={nodes=fewer}}}
  ui:render({selectedVariant='memory',selectedConfiguration='grouped24',latestRecord=smallerRecord,comparisons={}})
  local active=ui:inspect()
  check('24-node snapshot clamps and hides unavailable selectors',active.nodeCount==24 and active.nodeIndex==24 and not named('Node48').Visible and named('Node24').Visible)
  check('memory inspector identifies native diagnostic unused by model',active.diagnosticOnly and string.find(named('Inspector').Title.Text,'UNUSED',1,true)~=nil)
  check('empty new selection clears stale policy and aggregate',gui:GetAttribute('SelectedPolicy')==nil and named('Aggregate_numeric').Text=='—')
  local refitRecord={feature={drive=table.create(8,.1)},states={coupled={nodes=fewer}}}
  local refitComparisons={
   {id='coupled',model={status='ok'},report={selectedPolicyId='no_trade',policySelectionReason='no_candidate_passed_validation_gates',policyCandidates={{},{},{},{}},validationMeanMSE=.002,validationZeroMeanMSE=.00001,validationMseRatioToZero=200,
    preprocessing={originalDimension=84,activeDimension=80,clipZ=5,droppedFeatures={{name='a'},{name='b'},{name='c'},{name='d'}},validationClipping={rows=30,clippedRows=9,clippedValues=15}}},result={rows={{prediction={clipping={clippedValues=3}}}}}},
   {id='zero',report={status='baseline',baseline=true,selectedPolicyId='no_trade',policySelectionReason='unfitted_zero_forecast_cash_baseline',validationMeanMSE=.00001,validationZeroMeanMSE=.00001,validationMseRatioToZero=1},result={summary={netReturn=0,maxDrawdown=0,tradeCount=0}}},
  }
  local refitSnapshot={selectedVariant='coupled',selectedConfiguration='saved_v2_24',latestRecord=refitRecord,comparisons=refitComparisons,
   study={configurations={{id='saved_v2_24',label='Saved v2 · 24 nodes · 8 drives'}},foldDescriptors={{id='saved'}},aggregate={groups={{id='zero',configurationId='saved_v2_24',meanNetReturn=0,worstDrawdown=0,totalTrades=0,folds=1,attemptedFolds=1}}}}}
  ui:render(refitSnapshot)
  check('saved captures clearly identify v2 readout refit',named('Terminal').Title.Text=='SAVED V2 / READOUT REFIT' and gui:GetAttribute('SavedStateRefit')==true)
  check('saved v2 uses eight actual drive rows',gui:GetAttribute('DriveCount')==8 and named('Drive8').Visible and not named('Drive9').Visible and named('DriveName5').Text=='PEER RELATIVE')
  check('validation MSE and zero ratio use recorded values',named('coupledMSE').Text=='2.000e-03' and named('coupledZeroRatio').Text=='200.00x' and named('zeroZeroRatio').Text=='1.00x')
  check('policy failure reason is visible',string.find(named('SelectedPolicy').Text,'no_candidate_passed_validation_gates',1,true)~=nil)
  check('normalization diagnostics bind actual drop and clipping counts',string.find(named('Normalization').Text,'dropped 4',1,true)~=nil and string.find(named('Normalization').Text,'V 9/30',1,true)~=nil and string.find(named('Normalization').Text,'E 1/1',1,true)~=nil)
  local configurationCalls=calls.selectConfiguration
  ui:testActivate('Configuration_grouped24');ui:testActivate('Configuration_grouped48')
  check('saved capture blocks unavailable configuration callbacks',calls.selectConfiguration==configurationCalls and not named('Configuration_grouped24').Interactable and not named('Configuration_grouped48').Interactable)
  check('selected saved configuration label remains visible',named('ConfigurationCaption').Text=='Saved v2 · 24 nodes · 8 drives')
  ui:testActivate('Variant_zero');check('zero selector invokes actual baseline id',args.variant=='zero')
  refitSnapshot.selectedVariant='zero';ui:render(refitSnapshot)
  check('unfitted zero is baseline rather than untrained',named('ModelCard').Value.Text=='BASELINE' and string.find(named('Normalization').Text,'Unfitted zero forecast',1,true)~=nil)
  check('six comparison rows fit before policy evidence',named('Variant_zero').Position.Y.Offset+named('Variant_zero').Size.Y.Offset<=named('SelectedPolicy').Position.Y.Offset)
  check('six aggregate rows remain inside the panel',named('Aggregate_zero').Position.Y.Offset+named('Aggregate_zero').Size.Y.Offset<=named('Aggregate').Size.Y.Offset)
  ui:setProgress(5,10,"CAPTURE")
  check("progress attribute uses fraction",gui:GetAttribute("Progress")==.5)
  local waitFrame=opts.waitFrame or function()game:GetService("RunService").Heartbeat:Wait()end
  waitFrame();waitFrame()
  local terminal=named("Terminal")
  local surface=named("Surface")
  local scale=terminal:FindFirstChildOfClass("UIScale")
  local size=surface.AbsoluteSize
  check("scaled terminal fits available viewport",size.X>0 and size.Y>0 and scale.Scale*1260<=size.X
   and scale.Scale*1000<=size.Y,{viewportX=size.X,viewportY=size.Y,scale=scale.Scale})
  ui:clear()
  check("clear removes chart point and marker attributes",gui:GetAttribute("ChartPoints")==0 and gui:GetAttribute("SignalMarkers")==0)
  check("clear removes stale model comparison/trade ledger",named("numericReturn").Text=="—" and named("Trade1").Text=="—")
  check('clear removes validation ratios and clipping evidence',named('coupledMSE').Text=='—' and named('zeroZeroRatio').Text=='—' and named('Normalization').Text=='Preprocessing / awaiting fitted model')
  check("clear removes stale inspected state and contributions",named("NodeInfo").Text=="Select a measured or computed node" and named("Contribution1").Text=="—")
  check("clear removes stale drive/regime values",named("Drive1").Text=="—" and named("Regime").Text=="Daily regime / awaiting data")
  ui:render(nil)
  check("empty render retains untrained model status",named("ModelCard").Value.Text=="UNTRAINED")
  ui:render({comparisons={{id="coupled",model={status="ok"},summary={netReturn=.1,tradeCount=3,maxDrawdown=.02}}}})
  ui:render({comparisons={}})
  check("new empty comparison removes old result",named("coupledReturn").Text=="—")
  ui:destroy()
  ui:testActivate("Run")
  check("destroy disconnects and blocks callbacks",calls.run==1)
 end)
 if ui then ui:destroy()end
 report.ok=ok
 for _,c in report.checks do if not c.passed then report.ok=false end end
 if not ok then report.error=tostring(err)end
 return report
end
if not script then
 -- The module keeps platform object construction inside mount, so its pure
 -- data binding runs without constructing or claiming a native ScreenGui.
 Probe.runData(require('../src/Dashboard'))
end
return Probe
