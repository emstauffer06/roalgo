-- Signals use completed bars; orders fill at the next observed open.
-- One copy of the ledger mechanics (borrow, next-open fills, fees, slippage, gaps, intrabar barriers,
-- holding timeout, marking) serves two modes. Forecast mode (step) turns a learned prediction into orders
-- exactly as before. Intent mode (stepIntent) executes an explicit SignalIntent returned by a
-- decide(positionContext) callback. A ledger uses one mode for its whole life.
local Execution = {}
Execution.__index=Execution
local DEFAULTS={initialEquity=1,feeBps=1,slippageBps=1,borrowAnnual=0.03,stopVol=2,targetVol=3,minStopFraction=0.001,maxHoldBars=24,entryMarginBps=1,exitBandBps=0,minExcursionRatio=0}
local POLICY_DEFINITIONS={
 {id="continuation",experimental=false,config={}},
 {id="horizon6",experimental=false,config={maxHoldBars=6}},
 {id="buffered",experimental=false,config={entryMarginBps=4,exitBandBps=2}},
 {id="excursion",experimental=true,config={entryMarginBps=4,exitBandBps=2,minExcursionRatio=1.2}},
}
local YEAR_SECONDS=365*86400
local INTENT_ACTIONS={BUY=true,SELL=true,CLOSE=true,HOLD=true}
local INTENT_SOURCES={physics=true,risk=true,baseline=true}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
local function copy(t) local out={};for k,v in t do out[k]=if type(v)=="table" then copy(v) else v end;return out end
local function freeze(t) for _,v in t do if type(v)=="table" then freeze(v) end end;return table.freeze(t) end
local function policyConfig(policy)
 local config=copy(DEFAULTS)
 for k,v in policy.config do config[k]=v end
 return config
end
function Execution.policies()
 local policies={}
 for _,policy in POLICY_DEFINITIONS do policies[#policies+1]={id=policy.id,experimental=policy.experimental,config=policyConfig(policy)} end
 return freeze(policies)
end
function Execution.new(options)
 options=options or {}
 local policyId=options.policyId or "continuation"
 -- No-trade is an explicit fallback/baseline, not an extra optimized candidate.
 local policy=if policyId=="no_trade" then {id="no_trade",experimental=false,config={}} else nil
 for _,candidate in POLICY_DEFINITIONS do if candidate.id==policyId then policy=candidate;break end end
 assert(policy,"Execution: unknown policy "..tostring(policyId))
 local config=policyConfig(policy)
 for k,v in options do if k~="policyId" then assert(config[k]~=nil,"Execution: unknown config "..tostring(k));config[k]=v end end
 for k,v in config do assert(finite(v) and v>=0,"Execution: nonnegative finite config "..k) end
 assert(config.initialEquity>0 and config.maxHoldBars>=1 and config.maxHoldBars%1==0,"Execution: positive equity and integer holding period")
 return setmetatable({config=config,policyId=policyId,experimental=policy.experimental,cash=config.initialEquity,shares=0,position=0,pending=nil,openTrade=nil,rows={},trades={},totalFees=0,totalBorrow=0,peak=config.initialEquity,maxDrawdown=0,lastBar=nil,lastPrice=nil,holdBars=0},Execution)
end
function Execution:_equity(price) return self.cash+self.shares*price end
function Execution:_borrow(seconds,price)
 if self.position~=-1 or seconds<=0 then return end
 local charge=math.abs(self.shares)*price*self.config.borrowAnnual*seconds/YEAR_SECONDS
 self.cash-=charge;self.totalBorrow+=charge;self.openTrade.borrow+=charge
end
function Execution:_fill(rawPrice,direction,quantity,t,reason,action,executions)
 local price=rawPrice*(1+direction*self.config.slippageBps/10000)
 assert(price>0 and finite(price),"Execution: invalid slipped price")
 local signed=direction*quantity;local fee=quantity*price*self.config.feeBps/10000
 self.cash-=signed*price+fee;self.shares+=signed;self.totalFees+=fee
 local fill={t=t,signalT=self.pending and self.pending.signalT or nil,rawPrice=rawPrice,price=price,shares=signed,quantity=quantity,fee=fee,side=if direction==1 then "BUY" else "SELL",action=action,reason=reason}
 if self.mode=="intent" then
  -- A next-open fill inherits its order's provenance. Intrabar barrier fills have no order: they are risk exits.
  local order=self.pending
  fill.source=if order then order.source else "risk"
  fill.sampleId=if order then order.sampleId else nil
  fill.intentReason=if order then order.reason else nil
 end
 executions[#executions+1]=fill
 return fill
end
function Execution:_enter(order,bar,executions)
 local equity=self:_equity(bar.o)
 if equity<=0 then return end
 local direction=order.direction
 local fillPrice=bar.o*(1+direction*self.config.slippageBps/10000)
 local quantity=equity/fillPrice
 local fill=self:_fill(bar.o,direction,quantity,bar.t,"entry",if direction==1 then "BUY" else "SELL",executions)
 self.position=direction;self.holdBars=0
 local stopFraction=math.max(self.config.minStopFraction,self.config.stopVol*order.volatility)
 local targetFraction=math.max(self.config.minStopFraction,self.config.targetVol*order.volatility)
 self.openTrade={direction=direction,position=direction,quantity=quantity,entryT=bar.t,entrySignalT=order.signalT,entryRawPrice=bar.o,entryPrice=fill.price,entryFee=fill.fee,entryEquity=equity,borrow=0,stop=bar.o*(1-direction*stopFraction),target=bar.o*(1+direction*targetFraction)}
 if self.mode=="intent" then self.openTrade.entrySource=fill.source;self.openTrade.entrySampleId=fill.sampleId end
end
function Execution:_close(rawPrice,t,reason,executions)
 if self.position==0 then return end
 local trade=self.openTrade
 local fill=self:_fill(rawPrice,-self.position,math.abs(self.shares),t,reason,"CLOSE",executions)
 self.shares=0;self.position=0;self.holdBars=0
 trade.exitT=t;trade.exitRawPrice=rawPrice;trade.exitPrice=fill.price;trade.exitFee=fill.fee;trade.totalFees=trade.entryFee+trade.exitFee
 trade.reason=reason;trade.grossPnl=trade.direction*trade.quantity*(trade.exitPrice-trade.entryPrice)
 trade.netPnl=trade.grossPnl-trade.totalFees-trade.borrow;trade.netReturn=trade.netPnl/trade.entryEquity
 trade.exitEquity=self.cash;trade.holdSeconds=t-trade.entryT
 if self.mode=="intent" then trade.exitSource=fill.source;trade.exitSampleId=fill.sampleId;trade.exitSignalT=fill.signalT end
 self.trades[#self.trades+1]=trade;self.openTrade=nil
end
-- A ledger is either a forecast ledger (step) or an intent ledger (stepIntent); mixing them is a programming error.
-- The mode is checked before a call's arguments and recorded only after they pass, so a rejected call never
-- locks a fresh ledger.
function Execution:_checkMode(mode)
 assert(self.mode==nil or self.mode==mode,"Execution: a "..tostring(self.mode).." ledger cannot run "..mode.." mode")
end
function Execution:_validateBar(bar)
 assert(type(bar)=="table" and finite(bar.t) and (not self.lastBar or bar.t>self.lastBar.t),"Execution: chronological bars required")
 for _,key in {"o","h","l","c"} do assert(finite(bar[key]) and bar[key]>0,"Execution: positive finite OHLC") end
 assert(bar.l<=math.min(bar.o,bar.c) and bar.h>=math.max(bar.o,bar.c),"Execution: consistent OHLC required")
end
-- Shared bar opening, in order: elapsed borrow, the prior completed-bar order at this open, intrabar barriers.
-- Returns this bar's fills and whether a position closed on this bar (the exit bar).
function Execution:_open(bar)
 local executions={}
 local tradeCount=#self.trades
 -- At a next-open exit, only time through that open accrues borrow. Missing
 -- market intervals and overnight gaps still accrue elapsed calendar seconds.
 if self.lastBar then self:_borrow(math.max(0,bar.t-(self.lastBar.t+300)),self.lastPrice) end
 local order=self.pending
 if order then
  if order.action=="CLOSE" then self:_close(bar.o,bar.t,order.reason,executions)
   elseif self.position==0 and self.policyId~="no_trade" then self:_enter(order,bar,executions) end
 end
 self.pending=nil
 if self.position~=0 then
  self.holdBars+=1
  local trade=self.openTrade;local side=self.position
  local stopGap=if side==1 then bar.o<=trade.stop else bar.o>=trade.stop
  local stopHit=if side==1 then bar.l<=trade.stop else bar.h>=trade.stop
  local targetHit=if side==1 then bar.h>=trade.target else bar.l<=trade.target
  if stopGap then self:_close(bar.o,bar.t,"stop_gap",executions)
  else
   -- OHLC does not identify barrier time. Charge full observed interval when a
   -- short survives its open; this is conservative and explicitly reproducible.
   self:_borrow(300,bar.o)
   if stopHit then self:_close(trade.stop,bar.t+300,"stop",executions)
   elseif targetHit then self:_close(trade.target,bar.t+300,"target",executions) end
  end
 end
 return executions,#self.trades>tradeCount
end
-- The holding budget counts the completed entry bar as 1.
function Execution:_timeoutDue() return self.position~=0 and self.holdBars>=self.config.maxHoldBars end
-- Pending orders. Forecast orders carry no provenance (nil arguments add no keys).
function Execution:_queueClose(reason,signalT,source,sampleId)
 local order={action="CLOSE",reason=reason,signalT=signalT}
 -- Assigning even nil to an absent key can rehash a Luau table, so forecast orders are left untouched.
 if source~=nil then order.source=source;order.sampleId=sampleId end
 self.pending=order
 return order
end
function Execution:_queueEntry(direction,signalT,volatility,source,reason,sampleId)
 local order={action=if direction==1 then "BUY" else "SELL",direction=direction,signalT=signalT,volatility=volatility}
 if source~=nil then order.source=source;order.reason=reason;order.sampleId=sampleId end
 self.pending=order
 return order
end
-- Shared bar close: mark at the close, update drawdown, record the row.
function Execution:_finish(bar,executions,signal,reason,prediction,signalT)
 local equity=self:_equity(bar.c)
 self.peak=math.max(self.peak,equity);self.maxDrawdown=math.max(self.maxDrawdown,1-equity/self.peak)
 local row={t=bar.t,label=bar.label,close=bar.c,signal=signal,reason=reason,position=self.position,equity=equity,cash=self.cash,shares=self.shares,executions=executions,prediction=prediction,signalT=signalT,holdBars=self.holdBars,stop=self.openTrade and self.openTrade.stop or nil,target=self.openTrade and self.openTrade.target or nil}
 -- A denominator floor keeps insolvency observations finite without hiding
 -- leverage from fees, adverse moves, or the preserved all-equity sizing.
 row.grossExposure=math.abs(self.shares*bar.c)/math.max(equity,self.config.initialEquity*1e-12,1e-12)
 self.rows[#self.rows+1]=row;self.lastBar=copy(bar);self.lastPrice=bar.c
 return row
end
function Execution:step(bar,feature,prediction)
 self:_checkMode("forecast")
 self:_validateBar(bar)
 self.mode="forecast"
 feature=feature or {}
 local executions=self:_open(bar)
 local signal,reason="HOLD",if self.position~=0 then "holding" else "no_edge"
 local fitted=prediction and finite(prediction.mean)
 if self.position~=0 then
   if self.policyId=="no_trade" then signal="CLOSE";reason="no_trade_policy"
   elseif self:_timeoutDue() then signal="CLOSE";reason="timeout"
  elseif self.policyId~="horizon6" and fitted and self.position*prediction.mean<= -self.config.exitBandBps/10000 then
   signal="CLOSE";reason=if self.config.exitBandBps>0 then "learned_adverse_band" else "learned_continuation"
  end
  if signal=="CLOSE" then self:_queueClose(reason,bar.t+300) end
 else
   if self.policyId=="no_trade" then reason="no_trade_policy"
   elseif not fitted then reason="model_unavailable"
  elseif not feature.ready then reason="warming"
  elseif self:_equity(bar.c)<=0 then reason="equity_exhausted"
  else
   local threshold=(2*(self.config.feeBps+self.config.slippageBps)+self.config.entryMarginBps)/10000
   local direction=if prediction.mean>threshold then 1 elseif prediction.mean< -threshold then -1 else 0
   if direction~=0 and self.config.minExcursionRatio>0 then
    -- These heads estimate nonnegative return magnitudes, never probabilities.
    local favorable=if direction==1 then prediction.upside else prediction.downside
    local adverse=if direction==1 then prediction.downside else prediction.upside
    if not finite(favorable) or not finite(adverse) or favorable<0 or adverse<0 then
     direction=0;reason="excursion_unavailable"
    elseif favorable<=0 or favorable<self.config.minExcursionRatio*adverse then
     direction=0;reason="excursion_ratio"
    end
   end
   if direction~=0 then
    assert(finite(feature.volatility) and feature.volatility>=0,"Execution: finite signal volatility required")
    signal=if direction==1 then "BUY" else "SELL";reason=if self.config.minExcursionRatio>0 then "learned_excursion_edge" else "learned_edge"
    self:_queueEntry(direction,bar.t+300,feature.volatility)
   end
  end
 end
 return self:_finish(bar,executions,signal,reason,prediction and copy(prediction) or nil,bar.t+300)
end
local function validIntent(intent,availableT)
 assert(type(intent)=="table","Execution: decide must return a SignalIntent table")
 assert(INTENT_ACTIONS[intent.action],"Execution: intent action must be BUY, SELL, CLOSE or HOLD, got "..tostring(intent.action))
 assert(INTENT_SOURCES[intent.source],"Execution: intent source must be physics, risk or baseline, got "..tostring(intent.source))
 assert(type(intent.reason)=="string" and intent.reason~="","Execution: intent reason string required")
 assert(finite(intent.availableT),"Execution: finite intent availableT required")
 assert(intent.availableT==availableT,"Execution: intent availableT "..tostring(intent.availableT).." does not match bar availableT "..tostring(availableT))
 assert(intent.sampleId==nil or type(intent.sampleId)=="string","Execution: intent sampleId must be a string")
 assert(intent.diagnostics==nil or type(intent.diagnostics)=="table","Execution: intent diagnostics must be a table")
end
-- Intent mode. Order: validate bar -> gap borrow -> fill the prior pending order at this open (signalT <= bar.t)
-- -> intrabar barriers (stop first) -> positionContext -> decide(positionContext) exactly once -> resolve
-- ledger rejects, risk blocks and risk overrides -> queue the next-open order -> mark -> row.
-- riskContext = {volatility, ready} reaches only the ledger; decide sees only the position context.
function Execution:stepIntent(bar,riskContext,decide)
 self:_checkMode("intent")
 -- An error inside decide or a malformed intent propagates after this bar's fills and barriers (D5). That ledger
 -- is half-stepped (no row, lastBar not advanced), so it refuses every later bar instead of double-counting one.
 assert(not self.inBar,"Execution: this intent ledger is mid-bar (an earlier call aborted after its fills, or decide re-entered it); create a new ledger")
 assert(self.policyId~="no_trade","Execution: the intent-mode no-trade comparator is decide -> HOLD, not policyId no_trade")
 self:_validateBar(bar)
 assert(bar.availableT==nil or (finite(bar.availableT) and bar.availableT>bar.t),"Execution: bar availableT must be finite and after the bar open")
 assert(type(riskContext)=="table","Execution: riskContext table required")
 for key in riskContext do assert(key=="volatility" or key=="ready","Execution: riskContext carries only volatility and ready, got "..tostring(key)) end
 assert(type(decide)=="function","Execution: decide callback required")
 -- Fill-time causality (D9): the prior order fills at this open, so its information must exist by bar.t.
 -- Checked before any state changes; forecast mode keeps its unchecked bar.t + 300 (D11).
 assert(self.pending==nil or self.pending.signalT<=bar.t,"Execution: pending order signalT is later than the fill open")
 self.mode="intent";self.inBar=true
 local availableT=if bar.availableT~=nil then bar.availableT else bar.t+300
 local executions,exited=self:_open(bar)
 -- Exit bar: barsSinceExit=0; it counts completed observed bars since; nil until the first exit (no cooldown).
 if exited then self.barsSinceExit=0 elseif self.barsSinceExit~=nil then self.barsSinceExit+=1 end
 local context={position=self.position,pending=self.pending~=nil,exitedThisBar=exited,barsSinceExit=self.barsSinceExit}
 local returned=decide(table.freeze(copy(context)))
 validIntent(returned,availableT)
 local intent=copy(returned)
 local action,source,reason=intent.action,intent.source,intent.reason
 -- riskConditions, in priority order. Positioned: the D8 risk conditions that held (invalid_physics_state, then
 -- timeout); the D5 entry reject is recorded only when neither holds, because a D8 override replaces the intent
 -- with a risk CLOSE instead of rejecting it to HOLD. Flat CLOSE: rejected_close_while_flat. Flat BUY/SELL:
 -- every D5/D6 block that held (exit bar, not ready, invalid volatility, equity exhausted). HOLD: none.
 local conditions={}
 local function add(condition) conditions[#conditions+1]=condition end
 if self.position~=0 then
  -- Priority with a position still open after barriers: invalid_physics_state > timeout > the intent.
  if action=="CLOSE" and source=="risk" and reason=="invalid_physics_state" then add("invalid_physics_state") end
  if self:_timeoutDue() then add("timeout") end
  if #conditions==0 and (action=="BUY" or action=="SELL") then add("rejected_entry_while_positioned") end
  if #conditions>0 then action=if conditions[1]=="rejected_entry_while_positioned" then "HOLD" else "CLOSE" end
 elseif action=="CLOSE" then
  add("rejected_close_while_flat");action="HOLD"
 elseif action=="BUY" or action=="SELL" then
  if exited then add("rejected_exited_this_bar") end
  if riskContext.ready~=true then add("risk_not_ready") end
  if not finite(riskContext.volatility) or riskContext.volatility<0 then add("invalid_risk_volatility") end
  if self:_equity(bar.c)<=0 then add("equity_exhausted") end
  if #conditions>0 then action="HOLD" end
 end
 if #conditions>0 then source="risk";reason=conditions[1] end
 local overridden=action~=intent.action or source~=intent.source or reason~=intent.reason
 local order=nil
 if action=="CLOSE" then order=self:_queueClose(reason,availableT,source,intent.sampleId)
 elseif action=="BUY" or action=="SELL" then order=self:_queueEntry(if action=="BUY" then 1 else -1,availableT,riskContext.volatility,source,reason,intent.sampleId) end
 local row=self:_finish(bar,executions,action,reason,nil,availableT)
 row.mode="intent";row.signalSource=source;row.primaryReason=reason;row.riskConditions=conditions;row.overridden=overridden
 row.intent=intent;row.positionContext=context;row.pending=if order then copy(order) else nil
 row.exitedThisBar=exited;row.barsSinceExit=self.barsSinceExit
 self.inBar=false
 return row
end
function Execution:result()
 local equity=if self.lastPrice then self:_equity(self.lastPrice) else self.config.initialEquity
 local wins,losses,totalPnl=0,0,0
 for _,trade in self.trades do totalPnl+=trade.netPnl;if trade.netPnl>0 then wins+=1 elseif trade.netPnl<0 then losses+=1 end end
 local exposureSum,maxExposure,exposedBars,totalNotional=0,0,0,0
 for _,row in self.rows do
  exposureSum+=row.grossExposure;maxExposure=math.max(maxExposure,row.grossExposure)
  if row.position~=0 then exposedBars+=1 end
  for _,fill in row.executions do totalNotional+=fill.quantity*fill.price end
 end
 local summary={scope="historical exploratory research; earlier date ranges have already been inspected",initialEquity=self.config.initialEquity,equity=equity,finalEquity=equity,netReturn=equity/self.config.initialEquity-1,maxDrawdown=self.maxDrawdown,totalFees=self.totalFees,totalBorrow=self.totalBorrow,cash=self.cash,shares=self.shares,openPosition=self.position,tradeCount=#self.trades,wins=wins,losses=losses,winRate=if #self.trades>0 then wins/#self.trades else 0,realizedNetPnl=totalPnl,openTrade=self.openTrade and copy(self.openTrade) or nil,borrowConvention="actual seconds; prior close mark over gaps, open mark for observed interval; full interval for OHLC barrier exits",finalMarking="cash + signed shares * last observed close; no exit fee",firstT=self.rows[1] and self.rows[1].t or nil,lastT=self.lastBar and self.lastBar.t or nil,pendingSignal=self.pending and copy(self.pending) or nil}
 summary.policyId=self.policyId;summary.experimental=self.experimental
 summary.totalTradedNotional=totalNotional;summary.totalTurnover=totalNotional/self.config.initialEquity
 summary.meanGrossExposure=if #self.rows>0 then exposureSum/#self.rows else 0
 summary.maxGrossExposure=maxExposure;summary.exposedBars=exposedBars
 summary.exposureFraction=if #self.rows>0 then exposedBars/#self.rows else 0
 summary.turnoverConvention="sum of absolute slipped fill notionals / initial equity; entry and exit counted separately"
 summary.grossExposureConvention="bar-end absolute marked shares / max(current equity, initial equity * 1e-12, 1e-12); observation-weighted, not elapsed-time-weighted"
 if self.mode=="intent" then summary.mode="intent" end
 return {rows=self.rows,trades=self.trades,summary=summary,config=copy(self.config),policyId=self.policyId,experimental=self.experimental}
end
return Execution
