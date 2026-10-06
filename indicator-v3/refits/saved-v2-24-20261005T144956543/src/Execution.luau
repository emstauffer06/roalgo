-- Signals use completed bars; orders fill at the next observed open.
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
 self.trades[#self.trades+1]=trade;self.openTrade=nil
end
function Execution:step(bar,feature,prediction)
 assert(type(bar)=="table" and finite(bar.t) and (not self.lastBar or bar.t>self.lastBar.t),"Execution: chronological bars required")
 for _,key in {"o","h","l","c"} do assert(finite(bar[key]) and bar[key]>0,"Execution: positive finite OHLC") end
 assert(bar.l<=math.min(bar.o,bar.c) and bar.h>=math.max(bar.o,bar.c),"Execution: consistent OHLC required")
 feature=feature or {}
 local executions={}
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
 local signal,reason="HOLD",if self.position~=0 then "holding" else "no_edge"
 local fitted=prediction and finite(prediction.mean)
 if self.position~=0 then
   if self.policyId=="no_trade" then signal="CLOSE";reason="no_trade_policy"
   elseif self.holdBars>=self.config.maxHoldBars then signal="CLOSE";reason="timeout"
  elseif self.policyId~="horizon6" and fitted and self.position*prediction.mean<= -self.config.exitBandBps/10000 then
   signal="CLOSE";reason=if self.config.exitBandBps>0 then "learned_adverse_band" else "learned_continuation"
  end
  if signal=="CLOSE" then self.pending={action="CLOSE",reason=reason,signalT=bar.t+300} end
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
    self.pending={action=signal,direction=direction,signalT=bar.t+300,volatility=feature.volatility}
   end
  end
 end
 local equity=self:_equity(bar.c)
 self.peak=math.max(self.peak,equity);self.maxDrawdown=math.max(self.maxDrawdown,1-equity/self.peak)
 local row={t=bar.t,label=bar.label,close=bar.c,signal=signal,reason=reason,position=self.position,equity=equity,cash=self.cash,shares=self.shares,executions=executions,prediction=prediction and copy(prediction) or nil,signalT=bar.t+300,holdBars=self.holdBars,stop=self.openTrade and self.openTrade.stop or nil,target=self.openTrade and self.openTrade.target or nil}
 -- A denominator floor keeps insolvency observations finite without hiding
 -- leverage from fees, adverse moves, or the preserved all-equity sizing.
 row.grossExposure=math.abs(self.shares*bar.c)/math.max(equity,self.config.initialEquity*1e-12,1e-12)
 self.rows[#self.rows+1]=row;self.lastBar=copy(bar);self.lastPrice=bar.c
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
 return {rows=self.rows,trades=self.trades,summary=summary,config=copy(self.config),policyId=self.policyId,experimental=self.experimental}
end
return Execution
