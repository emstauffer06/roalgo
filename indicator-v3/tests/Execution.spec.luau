local loaded, Execution = pcall(require, "../src/Execution")
assert(loaded and type(Execution)=="table", "Execution must implement signed-share next-open ledger")
local passed=0
local function test(n,f) f();passed+=1;print("PASS "..n) end
local function near(a,b,e) assert(math.abs(a-b)<=(e or 1e-10), tostring(a).." != "..tostring(b)) end
local function make(c)
 local config={feeBps=0,slippageBps=0,borrowAnnual=0,minStopFraction=0,stopVol=2,targetVol=3}
 for k,v in c or {} do config[k]=v end
 return Execution.new(config)
end
local function step(e,i,mean,o,h,l,c,t)
 return e:step({t=t or i*300,day="one",label=tostring(i),o=o or 100,h=h or 100.5,l=l or 99.5,c=c or 100},{ready=true,volatility=0.01}, if mean==nil then nil else {mean=mean,upside=0.03,downside=0.02})
end

test("policy declarations are isolated immutable copies with continuation default",function()
 assert(type(Execution.policies)=="function", "Execution must declare the four policies")
 local policies=Execution.policies();assert(#policies==4)
 local expected={"continuation","horizon6","buffered","excursion"}
 for i,policy in policies do
  assert(policy.id==expected[i] and policy.experimental==(i==4))
  assert(table.isfrozen(policy) and table.isfrozen(policy.config))
 end
 assert(table.isfrozen(policies) and policies~=Execution.policies())
 assert(not pcall(function() policies[3].config.entryMarginBps=999 end))
 local default=Execution.new():result();assert(default.policyId=="continuation")
 local override=Execution.new({policyId="horizon6",maxHoldBars=2}):result()
 assert(override.policyId=="horizon6" and override.config.maxHoldBars==2)
 assert(not pcall(function() Execution.new({policyId="unknown"}) end))
end)

test("horizon6 ignores sign changes and exits after six observed held bars",function()
 for _,side in {1,-1} do
  local e=make({policyId="horizon6"});step(e,1,side*0.01)
  for i=2,6 do
   local row=step(e,i,-side*0.01)
   assert(row.position==side and row.signal=="HOLD" and row.holdBars==i-1)
  end
  local sixth=step(e,7,-side*0.01)
  assert(sixth.position==side and sixth.signal=="CLOSE" and sixth.reason=="timeout" and sixth.holdBars==6)
  assert(#e:result().trades==0)
  local close=step(e,8,nil,100,100.5,99.5,100,86400)
  assert(close.position==0 and #close.executions==1)
  local trade=e:result().trades[1];assert(trade.exitT==86400 and trade.reason=="timeout")
 end
end)

test("buffered exit hysteresis tolerates mild adverse mean and closes at two bps",function()
 for _,policyId in {"buffered","excursion"} do
  -- The helper's excursion forecasts favor longs, so test short excursion with a custom forecast below.
  local sides=if policyId=="buffered" then {1,-1} else {1}
  for _,side in sides do
   local e=make({policyId=policyId});step(e,1,side*0.01);step(e,2,side*0.01)
   assert(step(e,3,0).signal=="HOLD")
   assert(step(e,4,-side*0.000199).signal=="HOLD")
   local close=step(e,5,-side*0.0002)
   assert(close.signal=="CLOSE" and close.position==side and close.reason=="learned_adverse_band")
   assert(#e:result().trades==0)
   step(e,6,nil);assert(e:result().trades[1].reason=="learned_adverse_band")
  end
 end
end)

test("all policies preserve next-open entries and cost-aware entry margins",function()
 for _,policy in Execution.policies() do
  local e=Execution.new({policyId=policy.id})
  local threshold=if policy.id=="continuation" or policy.id=="horizon6" then 0.0005 else 0.0008
  assert(step(e,1,threshold).signal=="HOLD")
  local signal=step(e,2,threshold+0.000001)
  assert(signal.signal=="BUY" and signal.position==0 and #signal.executions==0)
  local entry=step(e,3,0.01)
  assert(entry.position==1 and #entry.executions==1 and entry.executions[1].signalT==900)
  assert(entry.executions[1].fee>0 and entry.executions[1].price>entry.executions[1].rawPrice)
 end
end)

test("excursion gate maps favorable magnitudes by trade direction",function()
 local function forecast(e,i,mean,upside,downside)
  return e:step({t=i*300,o=100,h=100.5,l=99.5,c=100},{ready=true,volatility=0.01},{mean=mean,upside=upside,downside=downside})
 end
 for _,side in {1,-1} do
  local e=make({policyId="excursion"})
  local rejected=forecast(e,1,side*0.01,0.02,0.02)
  assert(rejected.signal=="HOLD" and rejected.reason=="excursion_ratio")
  local accepted=forecast(e,2,side*0.01,if side==1 then 0.024 else 0.02,if side==1 then 0.02 else 0.024)
  assert(accepted.signal==(if side==1 then "BUY" else "SELL") and #accepted.executions==0)
  local held=forecast(e,3,side*0.01,0.02,0.02)
  assert(held.position==side and held.signal=="HOLD")
  assert(forecast(e,4,-side*0.000199,0.02,0.02).signal=="HOLD")
  assert(forecast(e,5,-side*0.0002,0.02,0.02).signal=="CLOSE")
 end
 local invalid=make({policyId="excursion"})
 assert(forecast(invalid,1,0.01,nil,nil).reason=="excursion_unavailable")
 assert(forecast(invalid,2,0.01,-0.04,0.02).reason=="excursion_unavailable")
 -- These are return magnitudes, not probabilities; values larger than one remain valid.
 assert(forecast(invalid,3,-0.01,1,1.2).signal=="SELL")
end)

test("continuation buffered and excursion enforce the 24-bar holding budget",function()
 for _,policyId in {"continuation","buffered","excursion"} do
  local e=make({policyId=policyId});step(e,1,0.01)
  for i=2,24 do assert(step(e,i,0.01).signal=="HOLD") end
  local deadline=step(e,25,0.01)
  assert(deadline.signal=="CLOSE" and deadline.holdBars==24 and #e:result().trades==0)
  step(e,26,nil);assert(e:result().trades[1].reason=="timeout")
 end
end)
test("zero favorable excursion cannot qualify a ratio after head clamping",function()
 for _,side in {1,-1} do
  local e=make({policyId="excursion"})
  local row=e:step({t=300,o=100,h=100.5,l=99.5,c=100},{ready=true,volatility=0.01},{mean=side*0.01,upside=0,downside=0})
  assert(row.signal=="HOLD" and row.reason=="excursion_ratio" and e.pending==nil)
 end
end)

test("turnover sums executed notionals and exposure uses current marked equity",function()
 local e=make()
 local empty=e:result().summary
 near(empty.totalTurnover,0);near(empty.meanGrossExposure,0);near(empty.maxGrossExposure,0);near(empty.exposureFraction,0)
 local first=step(e,1,0.01);near(first.grossExposure,0)
 local entered=step(e,2,0.01);near(entered.grossExposure,1)
 local closeSignal=step(e,3,0);near(closeSignal.grossExposure,1)
 local flat=step(e,4,nil);near(flat.grossExposure,0)
 local r=e:result();near(r.summary.totalTurnover,2);near(r.summary.totalTradedNotional,2)
 near(r.summary.meanGrossExposure,0.5);near(r.summary.maxGrossExposure,1)
 near(r.summary.exposureFraction,0.5);assert(r.summary.exposedBars==2)
 local short=make();step(short,1,-0.01);step(short,2,-0.01)
 local mark=step(short,3,-0.01,99,99.5,98.5,99)
 near(mark.grossExposure,0.99/1.01)
 near(e:result().summary.totalTurnover,2)
end)

test("exposure is finite at exhausted equity and includes real fees and slipped turnover",function()
 local e=make({feeBps=10000})
 -- A deliberately extreme cost fixture exercises a zero equity denominator.
 step(e,1,3);local row=step(e,2,3)
 near(row.equity,0)
 assert(row.grossExposure==row.grossExposure and row.grossExposure>0 and row.grossExposure<math.huge)
 local charged=make({feeBps=10,slippageBps=10})
 step(charged,1,0.01);local held=step(charged,2,0)
 assert(held.grossExposure>1)
 step(charged,3,nil)
 local r=charged:result();local tr=r.trades[1]
 near(r.summary.totalTurnover,tr.quantity*(tr.entryPrice+tr.exitPrice))
 near(r.summary.totalFees,tr.entryFee+tr.exitFee)
end)
test("BUY and SELL signals enter at next open with signed shares",function()
 for _,side in {1,-1} do
  local e=make();local first=step(e,1,side*0.01)
  assert(first.signal==(if side==1 then "BUY" else "SELL") and first.position==0 and #first.executions==0)
  local fill=step(e,2,side*0.01,101,101.5,100.5,101)
  assert(fill.position==side and #fill.executions==1);near(fill.executions[1].rawPrice,101)
  near(e:result().summary.shares,side/101)
 end
end)
test("fees and adverse slippage reduce both long and short round trip equity",function()
 for _,side in {1,-1} do
  local e=make({feeBps=10,slippageBps=10})
  step(e,1,side*0.01);step(e,2,0);step(e,3,0)
  local r=e:result();local tr=r.trades[1]
  assert(tr.entryFee>0 and tr.exitFee>0 and r.summary.equity<1)
  near(tr.entryPrice,if side==1 then 100.1 else 99.9)
  near(tr.exitPrice,if side==1 then 99.9 else 100.1)
  near(r.summary.equity,1+tr.netPnl)
 end
end)
test("short profit follows cash plus negative marked shares",function()
 local e=make();step(e,1,-0.01);step(e,2,-0.01);step(e,3,-0.01,99,99.5,98.5,99)
 near(e:result().summary.cash,2);near(e:result().summary.equity,1.01)
end)
test("borrow charges actual seconds held including overnight gaps",function()
 local e=make({borrowAnnual=0.03});step(e,1,-0.01);step(e,2,-0.01)
 step(e,3,-0.01,100,100.5,99.5,100,600+86400)
 near(e:result().summary.totalBorrow,0.03*(300+86400)/(365*86400))
 near(e:result().summary.equity,1-e:result().summary.totalBorrow)
end)
test("adverse short stop gap uses worse opening price",function()
 local e=make();step(e,1,-0.01);step(e,2,-0.01);step(e,3,-0.01,105,106,104,105)
 local tr=e:result().trades[1];near(tr.exitRawPrice,105);near(tr.netPnl,-0.05);assert(tr.reason=="stop_gap")
end)
test("simultaneous stop and target uses stop first in both directions",function()
 for _,side in {1,-1} do
  local e=make();step(e,1,side*0.01);step(e,2,side*0.01,100,104,96,100)
  local tr=e:result().trades[1];near(tr.exitRawPrice,if side==1 then 98 else 102);assert(tr.reason=="stop")
 end
end)
test("learned continuation closes next open before any later reversal",function()
 local e=make();step(e,1,0.01);step(e,2,0.01)
 local close=step(e,3,-0.01);assert(close.signal=="CLOSE" and close.position==1)
 local flat=step(e,4,-0.01);assert(flat.position==0 and #flat.executions==1 and flat.signal=="SELL")
 local short=step(e,5,-0.01);assert(short.position==-1 and #short.executions==1)
end)
test("no pyramiding and absent fit suppresses entry",function()
 local e=make();assert(step(e,1,nil).signal=="HOLD");step(e,2,0.01);step(e,3,0.01)
 local row=step(e,4,0.01);assert(row.signal=="HOLD" and #row.executions==0);near(e:result().summary.shares,0.01)
end)
test("final marking has no fictitious exit or fee and result is idempotent",function()
 local e=make({feeBps=10});step(e,1,0.01);step(e,2,0.01,100,101.5,99.5,101)
 local r=e:result();near(r.summary.equity,1.009);assert(#r.trades==0 and r.summary.openPosition==1)
 near(e:result().summary.equity,r.summary.equity);near(r.summary.totalFees,0.001)
end)
test("later changes preserve earlier emitted rows",function()
 local a,b=make(),make()
 for i=1,4 do step(a,i,0.01);step(b,i,0.01) end
 step(a,5,0.01);step(b,5,-0.01,110,111,109,110)
 for i=1,4 do local x,y=a:result().rows[i],b:result().rows[i];assert(x.signal==y.signal and x.position==y.position);near(x.equity,y.equity) end
end)
test("entry threshold covers two sides of costs and signal margin",function()
 local e=Execution.new();assert(step(e,1,0.0005).signal=="HOLD")
 assert(step(e,2,0.000501).signal=="BUY")
end)
test("timeout close occurs at following observed open",function()
 local e=make({maxHoldBars=2});step(e,1,0.01);step(e,2,0.01)
 assert(step(e,3,0.01).signal=="CLOSE")
 step(e,4,0.01);assert(e:result().trades[1].reason=="timeout")
end)
test("historical contribution rows stay fixed when a later prediction is mutated",function()
 local e=make();local prediction={mean=0.01,contributions={{name="trend",value=0.01}}}
 local row=e:step({t=300,label="one",o=100,h=101,l=99,c=100},{ready=true,volatility=0.01},prediction)
 prediction.contributions[1].value=99
 near(row.prediction.contributions[1].value,0.01)
end)
test("short scheduled close charges borrow only through fill open",function()
 local e=make({borrowAnnual=0.03});step(e,1,-0.01);step(e,2,0);step(e,3,0)
 local r=e:result();near(r.summary.totalBorrow,0.03*300/(365*86400));near(r.trades[1].borrow,r.summary.totalBorrow)
end)
test("long and short target fills lock signal-time volatility",function()
 for _,side in {1,-1} do
  local e=make();step(e,1,side*0.01);step(e,2,side*0.01)
  local row=e:step({t=900,label="three",o=100,h=if side==1 then 104 else 101,l=if side==1 then 99 else 96,c=100},{ready=true,volatility=0.5},{mean=side*0.01})
  assert(#row.executions==1);local tr=e:result().trades[1];near(tr.exitRawPrice,if side==1 then 103 else 97);assert(tr.reason=="target")
 end
end)
test("explicit no-trade policy stays flat even with strong forecasts and adds no search candidate",function()
 local e=Execution.new({policyId="no_trade"})
 for i=1,10 do local row=step(e,i,if i%2==0 then 10 else -10);assert(row.signal=="HOLD" and row.reason=="no_trade_policy" and row.position==0 and #row.executions==0) end
 local result=e:result();near(result.summary.netReturn,0);near(result.summary.totalFees,0)
 assert(result.policyId=="no_trade" and result.summary.tradeCount==0 and #Execution.policies()==4)
end)
test("no-trade does not reopen an existing position after its next-open close",function()
 local e=make();step(e,1,0.01);step(e,2,0.01)
 assert(e.position==1);e.policyId="no_trade"
 local signal=step(e,3,0.01);assert(signal.signal=="CLOSE" and signal.reason=="no_trade_policy")
 local closed=step(e,4,0.01)
 assert(closed.position==0 and #closed.executions==1 and closed.executions[1].action=="CLOSE" and closed.signal=="HOLD")
 assert(step(e,5,-0.01).position==0 and e.pending==nil)
end)
test("forecast rows fills trades pending orders and summary keep their pre-intent key sets",function()
 local function keys(t) local out={};for k in t do out[#out+1]=tostring(k) end;table.sort(out);return table.concat(out,",") end
 local e=make()
 step(e,1,0.01);assert(keys(e.pending)=="action,direction,signalT,volatility")
 local held=step(e,2,0.01)
 assert(keys(held)=="cash,close,equity,executions,grossExposure,holdBars,label,position,prediction,reason,shares,signal,signalT,stop,t,target")
 assert(keys(held.executions[1])=="action,fee,price,quantity,rawPrice,reason,shares,side,signalT,t")
 step(e,3,-0.01);assert(keys(e.pending)=="action,reason,signalT")
 local flat=step(e,4,nil)
 assert(keys(flat)=="cash,close,equity,executions,grossExposure,holdBars,label,position,reason,shares,signal,signalT,t")
 local r=e:result()
 assert(keys(r)=="config,experimental,policyId,rows,summary,trades")
 assert(keys(r.trades[1])=="borrow,direction,entryEquity,entryFee,entryPrice,entryRawPrice,entrySignalT,entryT,exitEquity,exitFee,exitPrice,exitRawPrice,exitT,grossPnl,holdSeconds,netPnl,netReturn,position,quantity,reason,stop,target,totalFees")
 assert(keys(r.summary)=="borrowConvention,cash,equity,experimental,exposedBars,exposureFraction,finalEquity,finalMarking,firstT,grossExposureConvention,initialEquity,lastT,losses,maxDrawdown,maxGrossExposure,meanGrossExposure,netReturn,openPosition,policyId,realizedNetPnl,scope,shares,totalBorrow,totalFees,totalTradedNotional,totalTurnover,tradeCount,turnoverConvention,winRate,wins")
 local s=make();step(s,1,0.01);local stopped=step(s,2,0.01,100,104,96,100)
 assert(keys(stopped.executions[2])=="action,fee,price,quantity,rawPrice,reason,shares,side,t")
end)
test("forecast ledgers refuse stepIntent and keep bar.t plus 300 signal times",function()
 local e=make()
 local row=e:step({t=300,availableT=900,day="one",label="1",o=100,h=100.5,l=99.5,c=100},{ready=true,volatility=0.01},{mean=0.01})
 assert(row.signalT==600 and e.pending.signalT==600 and row.mode==nil)
 assert(not pcall(function() e:stepIntent({t=600,availableT=900,o=100,h=100.5,l=99.5,c=100},{volatility=0.01,ready=true},function() return {action="HOLD",source="physics",reason="fixture",availableT=900} end) end))
 local fill=step(e,2,0.01);assert(fill.position==1 and fill.executions[1].signalT==600)
 assert(e:result().summary.mode==nil)
end)
test("forecast orders still fill at a next observed open earlier than their t plus 300 signal time",function()
 -- Forecast signalT stays bar.t + 300 and is never checked against the fill open (D9/D11); only intent mode asserts it.
 local e=make()
 local row=step(e,1,0.01)
 assert(row.signal=="BUY" and e.pending.signalT==600)
 local entry=step(e,2,0.01,101,101.5,100.5,101,360)
 assert(entry.position==1 and #entry.executions==1 and entry.executions[1].t==360 and entry.executions[1].signalT==600)
 near(entry.executions[1].rawPrice,101)
 local close=step(e,3,-0.01,101,101.5,100.5,101,420)
 assert(close.signal=="CLOSE" and e.pending.signalT==720)
 local exit=step(e,4,nil,102,102.5,101.5,102,480)
 assert(exit.position==0 and #exit.executions==1 and exit.executions[1].action=="CLOSE" and exit.executions[1].t==480 and exit.executions[1].signalT==720)
 local trade=e:result().trades[1];assert(trade.exitT==480 and trade.entrySignalT==600);near(trade.grossPnl,1/101)
end)
print("Execution: "..passed.." tests passed")
