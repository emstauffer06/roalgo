-- Intent-mode ledger seam (Execution:stepIntent; contract D4-D11). Synthetic fixtures only: no market data,
-- no P&L claims. Self-running: luau.exe tests/SpringExecution.spec.luau
local loaded, Execution = pcall(require, "../src/Execution")
assert(loaded and type(Execution)=="table" and type(Execution.stepIntent)=="function", "Execution must implement the stepIntent seam")
local passed=0
local function test(n,f) f();passed+=1;print("PASS "..n) end
local function near(a,b,e) assert(math.abs(a-b)<=(e or 1e-10), tostring(a).." != "..tostring(b)) end
local function raises(f,needle)
 local ok,err=pcall(f)
 assert(not ok,"expected an error containing "..tostring(needle))
 if needle then assert(string.find(tostring(err),needle,1,true),"unexpected error: "..tostring(err)) end
 return err
end
local function sameList(a,b) assert(#a==#b,"length "..#a.." vs "..#b);for i=1,#a do assert(a[i]==b[i],tostring(a[i]).." vs "..tostring(b[i])) end end
local function keySet(t) local out={};for k in t do out[#out+1]=tostring(k) end;table.sort(out);return table.concat(out,",") end
local function deepEqual(a,b,path)
 path=path or "value"
 assert(type(a)==type(b),path..": type "..type(a).." vs "..type(b))
 if type(a)=="table" then
  for k,v in a do deepEqual(v,b[k],path.."."..tostring(k)) end
  for k in b do assert(a[k]~=nil,path.."."..tostring(k)..": missing on the left") end
 else assert(a==b or (a~=a and b~=b),path..": "..tostring(a).." vs "..tostring(b)) end
end
local YEAR=365*86400
local function make(c)
 local config={feeBps=0,slippageBps=0,borrowAnnual=0,minStopFraction=0,stopVol=2,targetVol=3}
 for k,v in c or {} do config[k]=v end
 return Execution.new(config)
end
-- Synthetic completed bar; availableT = t + 300 as measured on the saved dataset.
local function bar(t,o,h,l,c,day)
 return {t=t,availableT=t+300,day=day or "d1",label=tostring(t),o=o or 100,h=h or 100.5,l=l or 99.5,c=c or 100}
end
local RISK={volatility=0.01,ready=true}
local function intentFor(b,action,source,reason,sampleId,diagnostics)
 return {action=action,source=source or "physics",reason=reason or ("fixture_"..string.lower(action)),availableT=b.availableT or b.t+300,sampleId=sampleId or ("fixture:"..tostring(b.t)),diagnostics=diagnostics or {score=0}}
end
-- Steps one bar with a fixed intent; returns the row and the position context decide received.
local function go(e,b,action,opts)
 opts=opts or {}
 local calls,seen=0,nil
 local row=e:stepIntent(b,opts.risk or RISK,function(ctx) calls+=1;seen=ctx;return intentFor(b,action,opts.source,opts.reason,opts.sampleId,opts.diagnostics) end)
 assert(calls==1,"decide must run exactly once per bar")
 return row,seen
end

test("an intent at a completed bar fills only at the next observed open with signalT equal to its availableT",function()
 local e=make();local b1=bar(300)
 local r1=go(e,b1,"BUY")
 assert(r1.signal=="BUY" and r1.position==0 and #r1.executions==0 and r1.signalT==b1.availableT)
 assert(r1.pending.action=="BUY" and r1.pending.signalT==b1.availableT)
 local b2=bar(600,101,101.5,100.5,101)
 local r2=go(e,b2,"HOLD")
 assert(r2.position==1 and #r2.executions==1)
 local f=r2.executions[1]
 assert(f.action=="BUY" and f.side=="BUY" and f.t==b2.t and f.signalT==b1.availableT);near(f.rawPrice,101)
 -- After a missing interval (four 5-minute bars absent) the order waits for the next observed open.
 local m=make();local s1=bar(300);go(m,s1,"SELL")
 local after=bar(300+5*300,99,99.5,98.5,99)
 local g=go(m,after,"HOLD")
 assert(g.position==-1 and #g.executions==1 and g.executions[1].action=="SELL" and g.executions[1].t==after.t and g.executions[1].signalT==s1.availableT)
 near(g.executions[1].rawPrice,99)
 -- Across an overnight gap: the last bar of a session signals, the next session's first open fills.
 local n=make();local late=bar(57300,100,100.5,99.5,100,"d1")
 assert(#go(n,late,"BUY").executions==0)
 local nextDay=bar(late.t+63300,102,102.5,101.5,102,"d2")
 local fr=go(n,nextDay,"CLOSE")
 assert(fr.position==1 and #fr.executions==1 and fr.executions[1].t==nextDay.t and fr.executions[1].signalT==late.availableT);near(fr.executions[1].rawPrice,102)
 local third=bar(nextDay.t+63300,103,103.5,102.5,103,"d3")
 local cr=go(n,third,"HOLD")
 assert(cr.position==0 and #cr.executions==1 and cr.executions[1].action=="CLOSE" and cr.executions[1].t==third.t and cr.executions[1].signalT==nextDay.availableT)
 -- A bar without availableT uses t + 300.
 local bare=make();local plain={t=300,o=100,h=100.5,l=99.5,c=100}
 local pr=bare:stepIntent(plain,RISK,function() return intentFor(plain,"BUY") end)
 assert(pr.signalT==600 and pr.pending.signalT==600)
end)

test("fill-time causality: an order available after the next open asserts in intent mode",function()
 local e=make();go(e,bar(300),"BUY")
 raises(function() go(e,bar(500),"HOLD") end,"signalT is later than the fill open")
 local late=make();local b={t=300,availableT=1200,o=100,h=100.5,l=99.5,c=100}
 late:stepIntent(b,RISK,function() return intentFor(b,"BUY") end)
 raises(function() go(late,bar(600),"HOLD") end,"signalT is later than the fill open")
 local ok=make();local b2={t=300,availableT=1200,o=100,h=100.5,l=99.5,c=100}
 ok:stepIntent(b2,RISK,function() return intentFor(b2,"BUY") end)
 local row=go(ok,bar(1200),"HOLD")
 assert(row.executions[1].signalT==1200 and row.executions[1].t==1200)
end)

test("intent availableT must equal the bar availableT, or t + 300 when the bar has none",function()
 local function attempt(b,availableT)
  local e=make()
  return pcall(function() e:stepIntent(b,RISK,function() local i=intentFor(b,"HOLD");i.availableT=availableT;return i end) end)
 end
 local b=bar(300)
 assert(attempt(b,600))
 local ok,err=attempt(b,300);assert(not ok and string.find(tostring(err),"does not match bar availableT",1,true))
 assert(not attempt(b,601))
 local missing,why=attempt(b,nil);assert(not missing and string.find(tostring(why),"finite intent availableT",1,true))
 local custom={t=300,availableT=900,o=100,h=100.5,l=99.5,c=100}
 assert(attempt(custom,900) and not attempt(custom,600))
 local plain={t=300,o=100,h=100.5,l=99.5,c=100}
 assert(attempt(plain,600) and not attempt(plain,900))
 raises(function() make():stepIntent({t=300,availableT=300,o=100,h=100.5,l=99.5,c=100},RISK,function() error("unreachable") end) end,"availableT must be finite and after")
end)

test("decide runs once per bar after fills and barriers with the exact position context",function()
 local e=make()
 local plan={
  {action="HOLD",position=0,exited=false,since=nil,trades=0},
  {action="BUY",position=0,exited=false,since=nil,trades=0},
  {action="HOLD",position=1,exited=false,since=nil,trades=0},
  {action="CLOSE",position=1,exited=false,since=nil,trades=0},
  {action="HOLD",position=0,exited=true,since=0,trades=1},
  {action="HOLD",position=0,exited=false,since=1,trades=1},
  {action="HOLD",position=0,exited=false,since=2,trades=1},
  {action="SELL",position=0,exited=false,since=3,trades=1},
  {action="HOLD",position=0,exited=true,since=0,trades=2,stopBar=true},
  {action="HOLD",position=0,exited=false,since=1,trades=2},
  {action="HOLD",position=0,exited=false,since=2,trades=2},
 }
 local calls=0
 for i,x in plan do
  local b=if x.stopBar then bar(i*300,100,103,99.5,100) else bar(i*300)
  local row=e:stepIntent(b,RISK,function(ctx)
   calls+=1
   assert(table.isfrozen(ctx),"decide receives a read-only context")
   assert(keySet(ctx)==(if x.since==nil then "exitedThisBar,pending,position" else "barsSinceExit,exitedThisBar,pending,position"),"context keys "..keySet(ctx))
   assert(ctx.position==x.position and ctx.pending==false and ctx.exitedThisBar==x.exited and ctx.barsSinceExit==x.since,"context at bar "..i)
   -- Fills and intrabar barriers have already happened when decide runs.
   assert(e.position==x.position and #e.trades==x.trades and e.pending==nil and #e.rows==i-1)
   return intentFor(b,x.action)
  end)
  assert(calls==i)
  assert(row.exitedThisBar==x.exited and row.barsSinceExit==x.since)
  local pc=row.positionContext
  assert(pc.position==x.position and pc.pending==false and pc.exitedThisBar==x.exited and pc.barsSinceExit==x.since)
 end
 local trades=e:result().trades
 assert(trades[1].reason=="fixture_close" and trades[2].reason=="stop" and trades[2].direction==-1)
end)

test("ledger rejects override well-formed intents to HOLD with their reasons",function()
 local function rejected(row,intentAction,reason)
  assert(row.signal=="HOLD" and row.reason==reason and row.primaryReason==reason and row.signalSource=="risk" and row.overridden==true,"reject "..reason)
  sameList(row.riskConditions,{reason})
  assert(row.intent.action==intentAction and row.pending==nil)
 end
 for _,side in {1,-1} do
  local e=make();go(e,bar(300),if side==1 then "BUY" else "SELL");go(e,bar(600),"HOLD")
  assert(e.position==side)
  rejected(go(e,bar(900),"BUY"),"BUY","rejected_entry_while_positioned")
  rejected(go(e,bar(1200),"SELL"),"SELL","rejected_entry_while_positioned")
  assert(e.pending==nil and e.position==side)
  local after=go(e,bar(1500),"HOLD");assert(#after.executions==0 and after.position==side)
 end
 local f=make();rejected(go(f,bar(300),"CLOSE"),"CLOSE","rejected_close_while_flat")
 assert(#go(f,bar(600),"HOLD").executions==0 and f.position==0)
 -- A next-open CLOSE fill makes its bar the exit bar.
 local x=make();go(x,bar(300),"BUY");go(x,bar(600),"CLOSE")
 local exitRow=go(x,bar(900),"SELL")
 assert(#exitRow.executions==1 and exitRow.executions[1].action=="CLOSE" and exitRow.exitedThisBar==true and exitRow.barsSinceExit==0)
 rejected(exitRow,"SELL","rejected_exited_this_bar")
 assert(#go(x,bar(1200),"HOLD").executions==0)
 -- The ledger rejects only on the exit bar; the 1-2 bar cooldown is the policy's job (D4/D5).
 local later=go(x,bar(1500),"BUY");assert(later.signal=="BUY" and later.overridden==false and later.barsSinceExit==2)
end)

test("risk context blocks entries with risk reasons and never forces an exit",function()
 local cases={
  {risk={volatility=0.01,ready=false},reasons={"risk_not_ready"}},
  {risk={volatility=0/0,ready=true},reasons={"invalid_risk_volatility"}},
  {risk={volatility=math.huge,ready=true},reasons={"invalid_risk_volatility"}},
  {risk={volatility=-0.001,ready=true},reasons={"invalid_risk_volatility"}},
  {risk={ready=true},reasons={"invalid_risk_volatility"}},
  {risk={volatility=0/0},reasons={"risk_not_ready","invalid_risk_volatility"}},
 }
 for _,case in cases do
  for _,action in {"BUY","SELL"} do
   local e=make()
   local row=go(e,bar(300),action,{risk=case.risk})
   assert(row.signal=="HOLD" and row.signalSource=="risk" and row.overridden==true and row.reason==case.reasons[1] and row.primaryReason==case.reasons[1])
   assert(row.pending==nil and e.pending==nil and row.intent.action==action)
   sameList(row.riskConditions,case.reasons)
   assert(#go(e,bar(600),"HOLD").executions==0)
  end
 end
 -- Equity exhausted: a deliberately extreme fee fixture leaves a flat ledger with equity <= 0.
 local z=make({feeBps=10000});go(z,bar(300),"BUY");go(z,bar(600),"CLOSE")
 local flat=go(z,bar(900),"HOLD");assert(flat.position==0 and flat.equity<=0)
 local blocked=go(z,bar(1200),"SELL")
 assert(blocked.signal=="HOLD" and blocked.reason=="equity_exhausted" and blocked.signalSource=="risk" and blocked.pending==nil)
 sameList(blocked.riskConditions,{"equity_exhausted"})
 -- HOLD is never overridden, and a held position is not closed by a risk-context problem.
 local h=make();local hold=go(h,bar(300),"HOLD",{risk={volatility=0/0,ready=false}})
 assert(hold.overridden==false and #hold.riskConditions==0 and hold.signalSource=="physics" and hold.reason=="fixture_hold" and hold.primaryReason=="fixture_hold")
 go(h,bar(600),"BUY");go(h,bar(900),"HOLD")
 local held=go(h,bar(1200),"HOLD",{risk={volatility=0/0,ready=false}})
 assert(held.position==1 and held.signal=="HOLD" and held.overridden==false and h.pending==nil)
 -- An accepted entry locks the risk volatility into its order.
 local v=make();local row=go(v,bar(300),"BUY",{risk={volatility=0.02,ready=true}})
 assert(row.pending.volatility==0.02 and row.overridden==false and #row.riskConditions==0)
 local filled=go(v,bar(600),"HOLD");near(filled.stop,96);near(filled.target,106)
 raises(function() make():stepIntent(bar(300),{volatility=0.01,ready=true,mean=0.5},function() return intentFor(bar(300),"HOLD") end) end,"riskContext carries only volatility and ready")
end)

test("D8 priority: invalid state over timeout over the intent, one callback, risk provenance on the fill",function()
 local function heldLong(maxHold)
  local e=make({maxHoldBars=maxHold});go(e,bar(300),"BUY",{sampleId="s:1"});go(e,bar(600),"HOLD")
  return e
 end
 local function decideOnce(e,b,action,source,reason,sampleId)
  local calls=0
  local row=e:stepIntent(b,RISK,function() calls+=1;return intentFor(b,action,source,reason,sampleId) end)
  assert(calls==1,"decide runs once even when its intent is overridden")
  return row
 end
 -- Timeout coincides with a physics CLOSE.
 local a=heldLong(2)
 local ra=decideOnce(a,bar(900),"CLOSE","physics","physics_loss_of_conviction","s:3")
 assert(ra.holdBars==2 and ra.signal=="CLOSE" and ra.signalSource=="risk" and ra.reason=="timeout" and ra.primaryReason=="timeout" and ra.overridden==true)
 sameList(ra.riskConditions,{"timeout"})
 assert(ra.intent.action=="CLOSE" and ra.intent.source=="physics" and ra.intent.reason=="physics_loss_of_conviction" and ra.intent.sampleId=="s:3")
 assert(ra.pending.action=="CLOSE" and ra.pending.source=="risk" and ra.pending.reason=="timeout" and ra.pending.sampleId=="s:3")
 local fa=go(a,bar(1200),"HOLD").executions[1]
 assert(fa.action=="CLOSE" and fa.source=="risk" and fa.reason=="timeout" and fa.intentReason=="timeout" and fa.signalT==1200 and fa.t==1200)
 local ta=a:result().trades[1];assert(ta.reason=="timeout" and ta.exitSource=="risk" and ta.exitSignalT==1200 and ta.entrySource=="physics")
 -- Timeout with a persisting entry intent while positioned.
 local b=heldLong(2)
 local rb=decideOnce(b,bar(900),"BUY","physics","confirmed_positive_setup","s:3")
 assert(rb.signal=="CLOSE" and rb.signalSource=="risk" and rb.reason=="timeout" and rb.overridden==true and rb.intent.action=="BUY")
 sameList(rb.riskConditions,{"timeout"})
 assert(go(b,bar(1200),"HOLD").executions[1].source=="risk")
 -- Timeout with the invalid-state CLOSE: invalid wins, both conditions recorded, the intent itself is kept.
 local c=heldLong(2)
 local rc=decideOnce(c,bar(900),"CLOSE","risk","invalid_physics_state","s:3")
 assert(rc.signal=="CLOSE" and rc.signalSource=="risk" and rc.reason=="invalid_physics_state" and rc.primaryReason=="invalid_physics_state" and rc.overridden==false)
 sameList(rc.riskConditions,{"invalid_physics_state","timeout"})
 assert(rc.pending.reason=="invalid_physics_state" and rc.pending.source=="risk")
 local fc=go(c,bar(1200),"HOLD").executions[1]
 assert(fc.source=="risk" and fc.intentReason=="invalid_physics_state" and fc.reason=="invalid_physics_state")
 assert(c:result().trades[1].exitSource=="risk")
 -- Invalid-state CLOSE without timeout.
 local d=heldLong(24)
 local rd=decideOnce(d,bar(900),"CLOSE","risk","invalid_physics_state","s:3")
 assert(rd.signal=="CLOSE" and rd.overridden==false and rd.signalSource=="risk");sameList(rd.riskConditions,{"invalid_physics_state"})
 -- The safety CLOSE is recognised by the exact triple only.
 local e1=heldLong(24)
 local re=decideOnce(e1,bar(900),"CLOSE","physics","invalid_physics_state","s:3")
 assert(#re.riskConditions==0 and re.signalSource=="physics" and re.overridden==false and re.pending.source=="physics")
 local e2=heldLong(24)
 local rf=decideOnce(e2,bar(900),"CLOSE","risk","manual_review","s:3")
 assert(#rf.riskConditions==0 and rf.signalSource=="risk" and rf.reason=="manual_review")
 -- An intrabar exit on the timeout bar takes priority: no order is queued.
 local s=heldLong(2)
 local sb=bar(900,100,100.5,97,100)
 local rs=decideOnce(s,sb,"CLOSE","risk","invalid_physics_state","s:3")
 assert(rs.position==0 and rs.executions[1].reason=="stop" and rs.signal=="HOLD" and rs.reason=="rejected_close_while_flat" and rs.pending==nil)
 assert(s:result().trades[1].reason=="stop")
end)

test("fees and adverse slippage reduce long and short round trips",function()
 for _,side in {1,-1} do
  local e=make({feeBps=10,slippageBps=10})
  go(e,bar(300),if side==1 then "BUY" else "SELL");go(e,bar(600),"CLOSE");go(e,bar(900),"HOLD")
  local r=e:result();local tr=r.trades[1]
  assert(tr.entryFee>0 and tr.exitFee>0 and r.summary.equity<1)
  near(tr.entryPrice,if side==1 then 100.1 else 99.9);near(tr.exitPrice,if side==1 then 99.9 else 100.1)
  near(tr.quantity,1/(if side==1 then 100.1 else 99.9))
  near(tr.entryFee,tr.quantity*tr.entryPrice*0.001);near(tr.exitFee,tr.quantity*tr.exitPrice*0.001)
  near(r.summary.totalFees,tr.entryFee+tr.exitFee);near(r.summary.equity,1+tr.netPnl)
 end
end)

test("short P&L is signed and a short cover is recorded as CLOSE side BUY",function()
 local e=make();go(e,bar(300),"SELL");go(e,bar(600),"HOLD")
 local mark=go(e,bar(900,99,99.5,98.5,99),"CLOSE")
 assert(mark.position==-1);near(mark.cash,2);near(mark.shares,-0.01);near(mark.equity,1.01)
 local cover=go(e,bar(1200,98,98.5,97.5,98),"HOLD")
 local f=cover.executions[1]
 assert(#cover.executions==1 and f.action=="CLOSE" and f.side=="BUY" and f.shares>0 and f.source=="physics" and f.intentReason=="fixture_close")
 local tr=e:result().trades[1]
 assert(tr.direction==-1 and tr.reason=="fixture_close");near(tr.grossPnl,0.02);near(tr.netPnl,0.02)
 near(e:result().summary.equity,1.02)
end)

test("short borrow charges actual seconds across an overnight gap and only through a next-open cover",function()
 local e=make({borrowAnnual=0.03});go(e,bar(300),"SELL");go(e,bar(600),"HOLD");go(e,bar(600+86400),"HOLD")
 near(e:result().summary.totalBorrow,0.03*(300+86400)/YEAR)
 near(e:result().summary.equity,1-e:result().summary.totalBorrow)
 local c=make({borrowAnnual=0.03});go(c,bar(300),"SELL");go(c,bar(600),"CLOSE");go(c,bar(900),"HOLD")
 local r=c:result();near(r.summary.totalBorrow,0.03*300/YEAR);near(r.trades[1].borrow,r.summary.totalBorrow)
 local l=make({borrowAnnual=0.03});go(l,bar(300),"BUY");go(l,bar(600),"HOLD");go(l,bar(600+86400),"HOLD")
 assert(l:result().summary.totalBorrow==0)
end)

test("gap stops, stop-first ambiguity and targets are risk exits without a signal time",function()
 local g=make();go(g,bar(300),"SELL");go(g,bar(600),"HOLD")
 local gap=go(g,bar(900,105,106,104,105),"HOLD")
 local gf=gap.executions[1]
 assert(gf.reason=="stop_gap" and gf.t==900 and gf.action=="CLOSE" and gf.side=="BUY" and gf.source=="risk" and gf.signalT==nil and gf.sampleId==nil and gf.intentReason==nil)
 local gt=g:result().trades[1];near(gt.exitRawPrice,105);near(gt.netPnl,-0.05)
 assert(gt.exitSource=="risk" and gt.exitSignalT==nil and gt.exitSampleId==nil and gt.entrySource=="physics")
 assert(gap.exitedThisBar==true and gap.barsSinceExit==0)
 for _,side in {1,-1} do
  local e=make();go(e,bar(300),if side==1 then "BUY" else "SELL")
  local row=go(e,bar(600,100,104,96,100),"HOLD")
  local f=row.executions[2]
  assert(#row.executions==2 and f.reason=="stop" and f.source=="risk" and f.signalT==nil and f.t==900);near(f.rawPrice,if side==1 then 98 else 102)
  local t=make();go(t,bar(300),if side==1 then "BUY" else "SELL");go(t,bar(600),"HOLD")
  local tb=bar(900,100,if side==1 then 104 else 101,if side==1 then 99 else 96,100)
  local tr=t:stepIntent(tb,{volatility=0.5,ready=true},function() return intentFor(tb,"HOLD") end)
  local tf=tr.executions[1]
  assert(tf.reason=="target" and tf.source=="risk" and tf.signalT==nil and tf.t==1200);near(tf.rawPrice,if side==1 then 103 else 97)
  assert(t:result().trades[1].exitSource=="risk" and t:result().trades[1].reason=="target")
 end
end)

test("the default ledger times out after 24 held bars and the final order stays unfilled with the position marked",function()
 local e=make({feeBps=10})
 go(e,bar(300),"BUY")
 for i=2,24 do local row=go(e,bar(i*300),"HOLD");assert(row.signal=="HOLD" and row.holdBars==i-1 and #row.riskConditions==0) end
 local deadline=go(e,bar(25*300),"HOLD")
 assert(deadline.holdBars==24 and deadline.signal=="CLOSE" and deadline.reason=="timeout" and deadline.signalSource=="risk" and deadline.overridden==true)
 sameList(deadline.riskConditions,{"timeout"})
 local r=e:result()
 assert(#r.trades==0 and r.summary.openPosition==1 and r.summary.tradeCount==0)
 assert(r.summary.pendingSignal.action=="CLOSE" and r.summary.pendingSignal.source=="risk" and r.summary.pendingSignal.reason=="timeout" and r.summary.pendingSignal.signalT==7800)
 near(r.summary.equity,r.summary.cash+r.summary.shares*100);near(r.summary.equity,0.999)
 near(r.summary.totalFees,0.001)
 assert(r.summary.openTrade.entrySource=="physics" and r.summary.mode=="intent")
 local fill=go(e,bar(26*300+63300,101,101.5,100.5,101),"HOLD")
 local f=fill.executions[1]
 assert(f.reason=="timeout" and f.source=="risk" and f.signalT==7800 and f.t==26*300+63300);near(f.rawPrice,101)
end)

test("an intrabar exit suppresses same-bar re-entry",function()
 for _,side in {1,-1} do
  local action=if side==1 then "BUY" else "SELL"
  local e=make();go(e,bar(300),action)
  local row,seen=go(e,bar(600,100,104,96,100),action)
  assert(#row.executions==2 and row.executions[2].reason=="stop" and row.position==0)
  assert(seen.exitedThisBar==true and seen.barsSinceExit==0 and seen.position==0)
  assert(row.signal=="HOLD" and row.reason=="rejected_exited_this_bar" and row.pending==nil and e.pending==nil)
  assert(#go(e,bar(900),"HOLD").executions==0 and e.position==0)
  local g=make();go(g,bar(300),action);go(g,bar(600),"HOLD")
  local gapRow=go(g,bar(900,if side==1 then 95 else 105,if side==1 then 95.5 else 105.5,if side==1 then 94.5 else 104.5,if side==1 then 95 else 105),action)
  assert(gapRow.executions[1].reason=="stop_gap" and gapRow.reason=="rejected_exited_this_bar" and g.pending==nil)
 end
end)

test("intent provenance flows into pending orders, fills and trades",function()
 for _,source in {"physics","baseline"} do
  local e=make()
  local r1=go(e,bar(300),"BUY",{source=source,reason="confirmed_positive_setup",sampleId="coupled:7"})
  assert(keySet(r1.pending)=="action,direction,reason,sampleId,signalT,source,volatility")
  assert(r1.pending.source==source and r1.pending.reason=="confirmed_positive_setup" and r1.pending.sampleId=="coupled:7" and r1.pending.signalT==600 and r1.pending.direction==1 and r1.pending.volatility==0.01)
  assert(r1.signalSource==source and r1.primaryReason=="confirmed_positive_setup")
  r1.pending.action="SELL";r1.pending.direction=-1
  local r2=go(e,bar(600),"CLOSE",{source=source,reason="physics_loss_of_conviction",sampleId="coupled:8"})
  local entry=r2.executions[1]
  assert(entry.action=="BUY" and r2.position==1,"the row holds a copy of the order")
  assert(entry.source==source and entry.sampleId=="coupled:7" and entry.intentReason=="confirmed_positive_setup" and entry.reason=="entry" and entry.signalT==600)
  assert(keySet(r2.pending)=="action,reason,sampleId,signalT,source")
  local r3=go(e,bar(900),"HOLD")
  local exit=r3.executions[1]
  assert(exit.action=="CLOSE" and exit.source==source and exit.sampleId=="coupled:8" and exit.intentReason=="physics_loss_of_conviction" and exit.signalT==900)
  local tr=e:result().trades[1]
  assert(tr.entrySource==source and tr.entrySampleId=="coupled:7" and tr.exitSource==source and tr.exitSampleId=="coupled:8")
  assert(tr.exitSignalT==900 and tr.entrySignalT==600 and tr.reason=="physics_loss_of_conviction")
 end
end)

test("the spring score stays in the intent diagnostics and never reaches prediction",function()
 local e=make()
 local diagnostics={score=0.42,bankScores={0.2,0.15,0.07},nodeContributions={0.42}}
 local b=bar(300)
 local returned=intentFor(b,"BUY","physics","confirmed_positive_setup","coupled:12",diagnostics)
 local row=e:stepIntent(b,RISK,function() return returned end)
 assert(row.prediction==nil)
 assert(row.intent.diagnostics.score==0.42 and row.intent~=returned and row.intent.diagnostics~=diagnostics)
 diagnostics.score=-9;returned.action="SELL"
 assert(row.intent.diagnostics.score==0.42 and row.intent.action=="BUY")
 local function scan(t,path)
  for k,v in t do
   assert(k~="mean" and k~="prediction" and k~="score","score leaked at "..path.."."..tostring(k))
   if type(v)=="table" and k~="intent" then scan(v,path.."."..tostring(k)) end
  end
 end
 for i=2,4 do scan(go(e,bar(i*300),"HOLD",{diagnostics={score=0.5}}),"row"..i) end
 scan(row,"row1")
 for _,r in e:result().rows do assert(r.prediction==nil) end
 scan(e:result().trades,"trades");scan(e:result().summary,"summary")
end)

test("a ledger is locked to one mode",function()
 local f=make();f:step(bar(300),{ready=true,volatility=0.01},{mean=0.01})
 raises(function() go(f,bar(600),"HOLD") end,"forecast ledger cannot run intent mode")
 assert(f.pending.action=="BUY" and #f.rows==1)
 local i=make();go(i,bar(300),"BUY")
 raises(function() i:step(bar(600),{ready=true,volatility=0.01},{mean=0.01}) end,"intent ledger cannot run forecast mode")
 local row=go(i,bar(600),"HOLD");assert(row.position==1 and #row.executions==1 and #i.rows==2)
 raises(function() Execution.new({policyId="no_trade"}):stepIntent(bar(300),RISK,function() return intentFor(bar(300),"HOLD") end) end,"not policyId no_trade")
end)

test("malformed intents and decide errors are programming errors",function()
 local function bad(mutate,needle)
  local e=make();local b=bar(300)
  raises(function() e:stepIntent(b,RISK,function() return mutate(intentFor(b,"HOLD")) end) end,needle)
 end
 bad(function() return nil end,"decide must return a SignalIntent table")
 bad(function() return "BUY" end,"decide must return a SignalIntent table")
 bad(function(i) i.action="LONG";return i end,"intent action")
 bad(function(i) i.action="buy";return i end,"intent action")
 bad(function(i) i.source="market";return i end,"intent source")
 bad(function(i) i.source=nil;return i end,"intent source")
 bad(function(i) i.reason="";return i end,"intent reason")
 bad(function(i) i.reason=nil;return i end,"intent reason")
 bad(function(i) i.sampleId=7;return i end,"sampleId")
 bad(function(i) i.diagnostics=0.4;return i end,"diagnostics")
 bad(function(i) i.availableT=0/0;return i end,"finite intent availableT")
 raises(function() make():stepIntent(bar(300),RISK,function() error("decide exploded") end) end,"decide exploded")
 raises(function() make():stepIntent(bar(300),RISK,nil) end,"decide callback required")
 raises(function() make():stepIntent(bar(300),nil,function() end) end,"riskContext table required")
 raises(function() make():stepIntent({t=300,o=100,h=99,l=99.5,c=100},RISK,function() end) end,"consistent OHLC required")
end)

test("identical intents give identical ledgers and the same mechanics as forecast mode",function()
 local config={feeBps=3,slippageBps=2,borrowAnnual=0.05}
 local quotes={{100,100.4,99.7,100.2},{100.3,100.6,99.9,100.1},{99.8,100.2,99.5,99.9},{100.1,100.5,99.8,100.4},{100.6,100.9,100.2,100.7},{100.5,100.8,100.1,100.3},{100.2,100.5,99.9,100},{100.1,100.6,99.8,100.5},{100.4,100.9,100.1,100.6},{100.8,101,100.4,100.9}}
 local plan={"SELL","HOLD","HOLD","CLOSE","HOLD","HOLD","BUY","HOLD","CLOSE","HOLD"}
 local means={-0.01,-0.01,-0.01,0.01,nil,nil,0.01,0.01,-0.01,nil}
 local bars={};local t=300
 for i,q in quotes do
  if i==3 then t+=63300 elseif i>1 then t+=300 end
  bars[i]=bar(t,q[1],q[2],q[3],q[4])
 end
 local forecast=Execution.new(config);local first=Execution.new(config);local second=Execution.new(config)
 for i,b in bars do
  local fr=forecast:step(b,{ready=true,volatility=0.01},if means[i]==nil then nil else {mean=means[i]})
  local ir=first:stepIntent(b,RISK,function() return intentFor(b,plan[i]) end)
  second:stepIntent(b,RISK,function() return intentFor(b,plan[i]) end)
  assert(fr.signal==plan[i] and ir.signal==plan[i],"bar "..i)
  for _,key in {"position","equity","cash","shares","holdBars","grossExposure","signalT","stop","target"} do assert(fr[key]==ir[key],"bar "..i.." "..key) end
  assert(#fr.executions==#ir.executions)
  for j,ff in fr.executions do
   local fi=ir.executions[j]
   for _,key in {"t","signalT","rawPrice","price","shares","quantity","fee","side","action"} do assert(ff[key]==fi[key],"fill "..i.." "..key) end
  end
 end
 local fres,ires=forecast:result(),first:result()
 assert(#fres.trades==2 and #ires.trades==2 and fres.summary.totalBorrow>0)
 for j,tf in fres.trades do
  for _,key in {"direction","quantity","entryPrice","exitPrice","entryFee","exitFee","borrow","grossPnl","netPnl","holdSeconds","entrySignalT"} do assert(tf[key]==ires.trades[j][key],"trade "..j.." "..key) end
 end
 for _,key in {"equity","cash","totalFees","totalBorrow","maxDrawdown","totalTurnover","meanGrossExposure","maxGrossExposure","exposedBars"} do assert(fres.summary[key]==ires.summary[key],"summary "..key) end
 deepEqual(first:result(),second:result(),"result")
end)

test("intent rows fills trades and summary extend the forecast shapes only by the declared keys",function()
 local forecast=make();local intent=make()
 local means={0.01,0.01,-0.01,nil};local plan={"BUY","HOLD","CLOSE","HOLD"}
 local fRows,iRows={},{}
 for i=1,4 do
  local b=bar(i*300)
  fRows[i]=forecast:step(b,{ready=true,volatility=0.01},if means[i]==nil then nil else {mean=means[i]})
  iRows[i]=go(intent,b,plan[i])
 end
 assert(keySet(fRows[3])=="cash,close,equity,executions,grossExposure,holdBars,label,position,prediction,reason,shares,signal,signalT,stop,t,target")
 assert(keySet(iRows[3])=="cash,close,equity,executions,exitedThisBar,grossExposure,holdBars,intent,label,mode,overridden,pending,position,positionContext,primaryReason,reason,riskConditions,shares,signal,signalSource,signalT,stop,t,target")
 assert(keySet(iRows[4])=="barsSinceExit,cash,close,equity,executions,exitedThisBar,grossExposure,holdBars,intent,label,mode,overridden,position,positionContext,primaryReason,reason,riskConditions,shares,signal,signalSource,signalT,t")
 assert(iRows[3].mode=="intent" and fRows[3].mode==nil)
 assert(keySet(fRows[2].executions[1])=="action,fee,price,quantity,rawPrice,reason,shares,side,signalT,t")
 assert(keySet(iRows[2].executions[1])=="action,fee,intentReason,price,quantity,rawPrice,reason,sampleId,shares,side,signalT,source,t")
 local fTrade,iTrade=forecast:result().trades[1],intent:result().trades[1]
 local forecastTradeKeys="borrow,direction,entryEquity,entryFee,entryPrice,entryRawPrice,entrySignalT,entryT,exitEquity,exitFee,exitPrice,exitRawPrice,exitT,grossPnl,holdSeconds,netPnl,netReturn,position,quantity,reason,stop,target,totalFees"
 assert(keySet(fTrade)==forecastTradeKeys)
 assert(keySet(iTrade)=="borrow,direction,entryEquity,entryFee,entryPrice,entryRawPrice,entrySampleId,entrySignalT,entrySource,entryT,exitEquity,exitFee,exitPrice,exitRawPrice,exitSampleId,exitSignalT,exitSource,exitT,grossPnl,holdSeconds,netPnl,netReturn,position,quantity,reason,stop,target,totalFees")
 local fSummary,iSummary=forecast:result().summary,intent:result().summary
 local extra={}
 for k in iSummary do if fSummary[k]==nil then extra[#extra+1]=k end end
 for k in fSummary do assert(iSummary[k]~=nil,"intent summary lost "..k) end
 sameList(extra,{"mode"});assert(iSummary.mode=="intent" and fSummary.mode==nil)
 assert(keySet(forecast:result())==keySet(intent:result()))
end)

-- Appended after review: boundary values, signal times and the shared accounting both modes now use.

test("barsSinceExit keeps counting from the most recent exit while a later position is open",function()
 local e=make()
 local plan={"BUY","HOLD","CLOSE","HOLD","HOLD","HOLD","BUY","HOLD","HOLD","CLOSE","HOLD","HOLD"}
 local since={[4]=0,[5]=1,[6]=2,[7]=3,[8]=4,[9]=5,[10]=6,[11]=0,[12]=1}
 local position={0,1,1,0,0,0,0,1,1,1,0,0}
 for i,action in plan do
  local row,seen=go(e,bar(i*300),action)
  assert(seen.position==position[i] and row.position==position[i],"position at bar "..i)
  assert(seen.barsSinceExit==since[i] and row.barsSinceExit==since[i] and row.positionContext.barsSinceExit==since[i],"barsSinceExit at bar "..i)
  assert(seen.exitedThisBar==(since[i]==0) and row.exitedThisBar==(since[i]==0),"exit bar at bar "..i)
  assert(row.signal==action and row.overridden==false,"bar "..i)
 end
 assert(#e:result().trades==2)
end)

test("an override that changes only the reason is still overridden",function()
 local e=make({maxHoldBars=2});go(e,bar(300),"BUY");go(e,bar(600),"HOLD")
 local row=go(e,bar(900),"CLOSE",{source="risk",reason="manual_review",sampleId="s:3"})
 assert(row.signal=="CLOSE" and row.signalSource=="risk" and row.reason=="timeout" and row.primaryReason=="timeout" and row.overridden==true)
 sameList(row.riskConditions,{"timeout"})
 assert(row.intent.action=="CLOSE" and row.intent.source=="risk" and row.intent.reason=="manual_review")
 assert(row.pending.reason=="timeout" and row.pending.source=="risk" and row.pending.sampleId=="s:3")
 local fill=go(e,bar(1200),"HOLD").executions[1]
 assert(fill.reason=="timeout" and fill.intentReason=="timeout" and fill.source=="risk" and fill.sampleId=="s:3")
 -- Without the timeout the same risk CLOSE is executed as given.
 local k=make();go(k,bar(300),"BUY");go(k,bar(600),"HOLD")
 local kept=go(k,bar(900),"CLOSE",{source="risk",reason="manual_review"})
 assert(kept.signal=="CLOSE" and kept.reason=="manual_review" and kept.overridden==false and #kept.riskConditions==0)
end)

test("the invalid-state override needs the whole D7 triple, action included",function()
 for _,action in {"HOLD","BUY","SELL"} do
  local e=make();go(e,bar(300),"BUY");go(e,bar(600),"HOLD")
  local row=go(e,bar(900),action,{source="risk",reason="invalid_physics_state"})
  assert(row.signal=="HOLD" and row.pending==nil and e.pending==nil,action)
  if action=="HOLD" then
   assert(row.reason=="invalid_physics_state" and row.signalSource=="risk" and row.overridden==false and #row.riskConditions==0)
  else
   assert(row.reason=="rejected_entry_while_positioned" and row.overridden==true)
   sameList(row.riskConditions,{"rejected_entry_while_positioned"})
  end
  local after=go(e,bar(1200),"HOLD");assert(#after.executions==0 and after.position==1)
 end
 -- Flat, the wrapper's HOLD with reason invalid_physics_state passes through unchanged.
 local f=go(make(),bar(300),"HOLD",{source="risk",reason="invalid_physics_state"})
 assert(f.signal=="HOLD" and f.signalSource=="risk" and f.reason=="invalid_physics_state" and f.overridden==false and #f.riskConditions==0)
end)

test("zero risk volatility is a valid entry and the continuation defaults set the minimum barrier distance",function()
 local c=Execution.new().config
 assert(c.feeBps==1 and c.slippageBps==1 and c.borrowAnnual==0.03 and c.stopVol==2 and c.targetVol==3 and c.minStopFraction==0.001 and c.maxHoldBars==24,"D10 continuation defaults")
 for _,side in {1,-1} do
  local action=if side==1 then "BUY" else "SELL"
  -- 0 and -0 are not < 0 (D6); 0.0002 gives 2 and 3 volatilities below the 0.001 floor.
  for _,volatility in {0,-0,0.0002} do
   local e=make({minStopFraction=0.001})
   local r1=go(e,bar(300),action,{risk={volatility=volatility,ready=true}})
   assert(r1.signal==action and r1.overridden==false and #r1.riskConditions==0 and r1.pending.volatility==volatility,"volatility "..volatility)
   local r2=go(e,bar(600,100,100.05,99.95,100),"HOLD")
   assert(r2.position==side and #r2.executions==1)
   near(r2.stop,100*(1-side*0.001));near(r2.target,100*(1+side*0.001))
  end
 end
 -- The default ledger (fee, slippage and borrow on) measures the floor from the raw open, not the slipped fill.
 local d=Execution.new();go(d,bar(300),"BUY",{risk={volatility=0,ready=true}})
 local filled=go(d,bar(600,100,100.05,99.95,100),"HOLD")
 near(filled.stop,99.9);near(filled.target,100.1);near(filled.executions[1].price,100.01)
 -- Above the floor the stop and target sit 2 and 3 volatilities away.
 local w=Execution.new();go(w,bar(300),"SELL",{risk={volatility=0.01,ready=true}})
 local ws=go(w,bar(600,100,100.05,99.95,100),"HOLD");near(ws.stop,102);near(ws.target,97)
end)

test("equity of exactly zero blocks a flat entry",function()
 for _,action in {"BUY","SELL"} do
  -- feeBps=5000 with no slippage: a 100 -> 100 round trip leaves cash and equity at exactly 0.
  local z=make({feeBps=5000});go(z,bar(300),"BUY");go(z,bar(600),"CLOSE")
  local flat=go(z,bar(900),"HOLD");assert(flat.position==0 and flat.equity==0 and flat.cash==0,"equity "..tostring(flat.equity))
  local blocked=go(z,bar(1200),action)
  assert(blocked.signal=="HOLD" and blocked.reason=="equity_exhausted" and blocked.signalSource=="risk" and blocked.overridden==true and blocked.pending==nil and z.pending==nil)
  sameList(blocked.riskConditions,{"equity_exhausted"})
  assert(#go(z,bar(1500),"HOLD").executions==0)
 end
end)

test("row and order signal times follow a bar availableT that is not t + 300",function()
 local e=make();go(e,bar(300),"BUY");go(e,bar(600),"HOLD")
 local b={t=900,availableT=1500,o=100,h=100.5,l=99.5,c=100}
 local r=e:stepIntent(b,RISK,function() return intentFor(b,"CLOSE") end)
 assert(r.signal=="CLOSE" and r.signalT==1500 and r.pending.signalT==1500 and e.pending.signalT==1500)
 raises(function() go(e,bar(1200),"HOLD") end,"signalT is later than the fill open")
 -- The causality check runs before any state changes, so the ledger still fills the order at its own open.
 local fill=go(e,bar(1500),"HOLD")
 assert(fill.position==0 and #fill.executions==1 and fill.executions[1].action=="CLOSE" and fill.executions[1].signalT==1500 and fill.executions[1].t==1500)
 assert(e:result().trades[1].exitSignalT==1500 and #e.rows==4)
 local h={t=300,availableT=1200,o=100,h=100.5,l=99.5,c=100}
 local hr=make():stepIntent(h,RISK,function() return intentFor(h,"HOLD") end)
 assert(hr.signalT==1200 and hr.pending==nil)
 local s={t=300,availableT=1200,o=100,h=100.5,l=99.5,c=100}
 local sr=make():stepIntent(s,RISK,function() return intentFor(s,"SELL") end)
 assert(sr.signalT==1200 and sr.pending.signalT==1200)
end)

test("realized trade accounting: borrow inside net P&L, hold seconds, net return and exit equity",function()
 local rate=0.3
 local e=make({borrowAnnual=rate});go(e,bar(300),"SELL");go(e,bar(600),"HOLD");go(e,bar(900),"CLOSE");go(e,bar(1200,98,98.5,97.5,98),"HOLD")
 local t1=e:result().trades[1]
 local borrow=2*0.01*100*rate*300/YEAR
 near(t1.borrow,borrow);near(t1.grossPnl,0.02);near(t1.netPnl,0.02-borrow);assert(t1.borrow>1e-6)
 assert(t1.holdSeconds==600 and t1.entryT==600 and t1.exitT==1200)
 near(t1.netReturn,t1.netPnl);near(t1.exitEquity,1+t1.netPnl)
 near(e:result().summary.realizedNetPnl,t1.netPnl);near(e:result().summary.totalBorrow,borrow)
 -- A second trade starts from the grown equity, so netReturn is normalised by entryEquity.
 go(e,bar(1500,98,98.5,97.5,98),"BUY");go(e,bar(1800,98,98.5,97.5,98),"HOLD");go(e,bar(2100,98,98.5,97.5,98),"CLOSE")
 go(e,bar(2400,100,100.5,99.5,100),"HOLD")
 local t2=e:result().trades[2]
 near(t2.entryEquity,1+t1.netPnl);assert(math.abs(t2.entryEquity-1)>0.01)
 near(t2.netReturn,t2.netPnl/t2.entryEquity);near(t2.exitEquity,t2.entryEquity+t2.netPnl)
 near(t2.grossPnl,t2.entryEquity/98*2);assert(t2.borrow==0 and t2.holdSeconds==600)
 near(e:result().summary.realizedNetPnl,t1.netPnl+t2.netPnl)
end)

test("gap borrow is priced at the prior close and in-bar borrow at the open",function()
 local rate=0.5
 local risk={volatility=0.1,ready=true}
 local e=make({borrowAnnual=rate});go(e,bar(300),"SELL",{risk=risk});go(e,bar(600),"HOLD")
 local g=go(e,bar(63900,101,103.5,100.5,103),"HOLD")
 assert(g.position==-1 and #g.executions==0)
 local expected=rate/YEAR*(0.01*100*300+0.01*100*63000+0.01*101*300)
 near(e:result().summary.totalBorrow,expected,1e-12)
 near(e:result().summary.openTrade.borrow,expected,1e-12)
 near(g.equity,2-expected-0.01*103,1e-12)
end)

test("max drawdown follows the running peak",function()
 local risk={volatility=0.1,ready=true}
 local e=make();go(e,bar(300),"BUY",{risk=risk})
 go(e,bar(600,100,102.5,99.5,102),"HOLD")
 near(e:result().summary.maxDrawdown,0)
 go(e,bar(900,102,102.5,97.5,98),"HOLD")
 near(e:result().summary.maxDrawdown,1-0.98/1.02,1e-12)
 go(e,bar(1200,98,103,97.5,102),"HOLD")
 near(e:result().summary.maxDrawdown,1-0.98/1.02,1e-12)
 go(e,bar(1500,102,104.5,101.5,104),"HOLD");go(e,bar(1800,104,104.5,98.5,99),"HOLD")
 near(e:result().summary.maxDrawdown,1-0.99/1.04,1e-12)
end)

test("a barrier touched exactly is hit, for stops, stop gaps and targets on both sides",function()
 for _,side in {1,-1} do
  local action=if side==1 then "BUY" else "SELL"
  local function held() local e=make();go(e,bar(300),action);go(e,bar(600),"HOLD");return e,e.openTrade end
  local g,gt=held()
  local gap=go(g,bar(900,gt.stop,gt.stop+0.5,gt.stop-0.5,gt.stop),"HOLD")
  assert(gap.executions[1].reason=="stop_gap" and gap.executions[1].t==900 and gap.executions[1].rawPrice==gt.stop)
  local s,st=held()
  local touch=go(s,bar(900,100,if side==1 then 100.5 else st.stop,if side==1 then st.stop else 99.5,100),"HOLD")
  assert(touch.executions[1].reason=="stop" and touch.executions[1].t==1200 and touch.executions[1].rawPrice==st.stop)
  local t,tt=held()
  local hit=go(t,bar(900,100,if side==1 then tt.target else 100.5,if side==1 then 99.5 else tt.target,100),"HOLD")
  assert(hit.executions[1].reason=="target" and hit.executions[1].t==1200 and hit.executions[1].rawPrice==tt.target)
 end
end)

test("holdBars resets on the bar a position closes",function()
 local e=make();go(e,bar(300),"BUY");go(e,bar(600),"HOLD");go(e,bar(900),"CLOSE")
 local exit=go(e,bar(1200),"HOLD")
 assert(exit.position==0 and #exit.executions==1 and exit.holdBars==0 and exit.stop==nil and exit.target==nil)
 for _,low in {90,97} do
  local s=make();go(s,bar(300),"BUY");go(s,bar(600),"HOLD")
  local row=go(s,bar(900,if low==90 then 97 else 100,100.5,low,if low==90 then 97 else 100),"HOLD")
  assert(row.position==0 and row.holdBars==0 and #row.executions==1)
  assert(row.executions[1].reason==(if low==90 then "stop_gap" else "stop"))
 end
end)

test("an exit-bar reject keeps every risk block that also held",function()
 local e=make();go(e,bar(300),"BUY");go(e,bar(600),"CLOSE")
 local row=go(e,bar(900),"SELL",{risk={volatility=0/0,ready=false}})
 assert(#row.executions==1 and row.exitedThisBar==true and row.signal=="HOLD" and row.reason=="rejected_exited_this_bar" and row.signalSource=="risk")
 sameList(row.riskConditions,{"rejected_exited_this_bar","risk_not_ready","invalid_risk_volatility"})
end)

test("a rejected call never locks a fresh ledger's mode",function()
 local a=make()
 raises(function() a:stepIntent({t=300,o=100,h=99,l=99.5,c=100},RISK,function() error("unreachable") end) end,"consistent OHLC required")
 raises(function() a:stepIntent(bar(300),{volatility=0.01,ready=true,mean=1},function() error("unreachable") end) end,"riskContext carries only")
 raises(function() a:stepIntent(bar(300),RISK,nil) end,"decide callback required")
 local fr=a:step(bar(300),{ready=true,volatility=0.01},{mean=0.01});assert(fr.signal=="BUY" and #a.rows==1)
 raises(function() go(a,bar(600),"HOLD") end,"forecast ledger cannot run intent mode")
 -- A no_trade ledger refused by intent mode still runs forecast mode.
 local n=Execution.new({policyId="no_trade"})
 raises(function() n:stepIntent(bar(300),RISK,function() return intentFor(bar(300),"HOLD") end) end,"not policyId no_trade")
 assert(n:step(bar(300),{ready=true,volatility=0.01},{mean=0.01}).reason=="no_trade_policy")
 -- A failed forecast call on a fresh ledger leaves it free to run intent mode.
 local b=make()
 raises(function() b:step({t=300,o=100,h=99,l=99.5,c=100},{ready=true,volatility=0.01},{mean=0.01}) end,"consistent OHLC required")
 local ir=go(b,bar(300),"BUY");assert(ir.mode=="intent" and #b.rows==1)
 raises(function() b:step(bar(600),{ready=true,volatility=0.01},{mean=0.01}) end,"intent ledger cannot run forecast mode")
end)

test("an intent ledger that aborted mid-bar refuses every later bar",function()
 -- decide raises after this bar's entry fill: the ledger is half-stepped and must not count the bar twice.
 local e=make();go(e,bar(300),"BUY")
 raises(function() e:stepIntent(bar(600),RISK,function() error("decide exploded") end) end,"decide exploded")
 assert(e.position==1 and #e.rows==1)
 raises(function() go(e,bar(600),"HOLD") end,"mid-bar")
 raises(function() go(e,bar(900),"HOLD") end,"mid-bar")
 assert(#e.rows==1 and e.holdBars==1)
 -- A malformed intent after the fills does the same.
 local m=make();go(m,bar(300),"SELL")
 raises(function() m:stepIntent(bar(600),RISK,function() return {action="SELL"} end) end,"intent source")
 raises(function() go(m,bar(900),"HOLD") end,"mid-bar")
 -- decide may not re-enter its own ledger.
 local r=make()
 raises(function() r:stepIntent(bar(300),RISK,function() return r:stepIntent(bar(600),RISK,function() return intentFor(bar(600),"HOLD") end) end) end,"mid-bar")
 -- Argument errors happen before any state changes and do not spend the ledger.
 local ok=make();go(ok,bar(300),"BUY")
 raises(function() ok:stepIntent(bar(300),RISK,function() error("unreachable") end) end,"chronological bars required")
 raises(function() ok:stepIntent(bar(600),{volatility=0.01,ready=true,extra=1},function() error("unreachable") end) end,"riskContext carries only")
 local row=go(ok,bar(600),"HOLD");assert(row.position==1 and #row.executions==1 and #ok.rows==2)
 local again=go(ok,bar(900),"HOLD");assert(again.holdBars==2 and #ok.rows==3)
end)

print("SpringExecution: "..passed.." tests passed")
