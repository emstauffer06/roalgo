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
print("Execution: "..passed.." tests passed")
