-- Native UI construction/layout and callback-handler probe. No physical mouse/input claim.
local Probe={}
function Probe.run(parent,options)
 local opts=options or{}
 local report={ok=false,checks={},scope="Native ScreenGui construction, data binding, layout and shared callback handlers; synthetic execution data; no physical mouse events"}
 local ui
 local function check(name,passed,detail)table.insert(report.checks,{name=name,passed=passed,detail=detail})end
 local ok,err=pcall(function()
  local root=script.Parent.Parent
  local Dashboard=require(root.src.Dashboard)
  local Execution=require(root.src.Execution)
  local calls={run=0,stop=0,replay=0,viewRig=0,variant=0}
  local args={}
  ui=Dashboard.mount(parent,{
   run=function(...)calls.run+=1;args.run={...}end,
   stop=function()calls.stop+=1 end,replay=function()calls.replay+=1 end,
   viewRig=function()calls.viewRig+=1 end,variant=function(id)calls.variant+=1;args.variant=id end,
  })
  local gui=ui.screenGui
  local function named(name)return gui:FindFirstChild(name,true)end
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
  for i=1,24 do nodes[i]={x=.25,v=.125,force=3,bank=math.floor((i-1)/8)+1}end
  local record={feature={drive=table.create(8,.5),regime={.2,.3,.5}},states={coupled={nodes=nodes},independent={nodes=nodes},numeric={nodes=nodes}}}
  ui:render({symbol="QQQ",selectedVariant="numeric",rows=rows,latestRecord=record,
   metadata={first="2024-11-18 09:30 ET",last="2024-12-31 15:55 ET",bars=2268,
    requestedSplits={train=20,validation=5,test=5},sessions={"2024-11-18"},counts={}},
   comparisons={{id="numeric",model={status="ok",samples={train=128,validation=32}},result=result}}})
  check("numeric state explicitly computed",string.find(named("Inspector").Title.Text,"COMPUTED",1,true)~=nil,named("Inspector").Title.Text)
  check("execution trade direction shows readable long/short",string.find(named("Trade1").Text,"SHORT",1,true)~=nil,named("Trade1").Text)
  check("trade ledger includes cost amounts",string.find(named("Trade1").Text,"fees",1,true)~=nil,named("Trade1").Text)
  local coverage=named("DataCoverage")
  check("dataset coverage and fitted sample counts displayed",coverage and string.find(coverage.Text,"2268",1,true)~=nil
   and string.find(coverage.Text,"128",1,true)~=nil and string.find(coverage.Text,"32",1,true)~=nil,coverage and coverage.Text)
  check("recorded chart points bound correctly",gui:GetAttribute("ChartPoints")==#rows,gui:GetAttribute("ChartPoints"))
  local fills=0;for _,row in rows do fills+=#row.executions end
  check("actual execution fills have distinct markers",gui:GetAttribute("FillMarkers")==fills and fills>0,gui:GetAttribute("FillMarkers"))
  ui:testActivate("Node24")
  check("node selector updates recorded diagnostic",string.find(named("NodeInfo").Text,"Node 24",1,true)~=nil,named("NodeInfo").Text)
  ui:setProgress(5,10,"CAPTURE")
  check("progress attribute uses fraction",gui:GetAttribute("Progress")==.5)
  local waitFrame=opts.waitFrame or function()game:GetService("RunService").Heartbeat:Wait()end
  waitFrame();waitFrame()
  local terminal=named("Terminal")
  local surface=named("Surface")
  local scale=terminal:FindFirstChildOfClass("UIScale")
  local size=surface.AbsoluteSize
  check("scaled terminal fits available viewport",size.X>0 and size.Y>0 and scale.Scale*1260<=size.X
   and scale.Scale*900<=size.Y,{viewportX=size.X,viewportY=size.Y,scale=scale.Scale})
  ui:clear()
  check("clear removes chart point and marker attributes",gui:GetAttribute("ChartPoints")==0 and gui:GetAttribute("SignalMarkers")==0)
  check("clear removes stale model comparison/trade ledger",named("numericReturn").Text=="—" and named("Trade1").Text=="—")
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
return Probe
