local Regime=if script then require(script.Parent.Regime) else require('./Regime')
local Features={}
Features.__index=Features
local NAMES={'return1','trend','volatility','range','body','vwapDeviation','logVolume','volumeActivity','tradeActivity','peerReturn','peerRelative','spyHourReturn','qqqHourReturn','iwmHourReturn','tltHourReturn','targetDailyReturn','spyDailyReturn','qqqDailyReturn','dailyRange','minuteSin','minuteCos','missingPeer','missingSpyHour','missingQqqHour','missingIwmHour','missingTltHour','missingSpyDaily','missingQqqDaily','gap','overnight','regimeLow','regimeMid','regimeHigh'}
local CONTEXT={'peerFive','spyHour','qqqHour','iwmHour','tltHour','spyDaily','qqqDaily'}
local SECTORS={'xlkHour','xlfHour','xleHour'}
local DRIVE_NAMES={'trend','immediateReturn','rangeActivity','volume','qqqMinusSpy','iwmMinusSpy','tltReturn','xlkMinusSpy','xlfMinusSpy','xleMinusSpy','targetDailyReturn','regimeStress'}
for _,name in {'xlkHourReturn','xlfHourReturn','xleHourReturn','qqqMinusSpy','iwmMinusSpy','xlkMinusSpy','xlfMinusSpy','xleMinusSpy','missingXlkHour','missingXlfHour','missingXleHour','missingQqqMinusSpy','missingIwmMinusSpy','missingXlkMinusSpy','missingXlfMinusSpy','missingXleMinusSpy'} do table.insert(NAMES,name) end
local RELATIVES={qqqHour='qqqMinusSpy',iwmHour='iwmMinusSpy',xlkHour='xlkMinusSpy',xlfHour='xlfMinusSpy',xleHour='xleMinusSpy'}
local MEMORY_NAMES={}
for _,name in DRIVE_NAMES do for _,suffix in {'lag1','lag3','ewmaFast','ewmaSlow'} do table.insert(MEMORY_NAMES,name..'.'..suffix) end end
local function finite(x) return type(x)=='number' and x==x and math.abs(x)<math.huge end
local function safe(x) return if finite(x) then x else 0 end
local function fraction(c,o) return if finite(c) and finite(o) and o>0 then safe(c/o-1) else 0 end
local function valid(c,b,name)
  if type(c)~='table' or not finite(c.t) or not finite(c.availableT) or c.availableT>b.t+300 or not finite(c.c) or not finite(c.o) or c.c<=0 or c.o<=0 then return false end
  if string.find(name,'Daily') then return type(c.day)=='string' and c.day<b.day and c.t<b.t end
  if name=='peerFive' then return c.t==b.t and c.availableT>=c.t+300 end
  return c.t+3600<=b.t+300 and c.availableT>=c.t+3600 and b.t+300-c.availableT<=7200
end
function Features.new(prehistory,options)
  options=options or {}
  return setmetatable({prehistory=prehistory or {},options=options,observations=0,previous=nil,trend=0,var=1e-8,volumeMean=nil,tradeMean=nil,driveScales=table.create(#DRIVE_NAMES,1e-6),history={},memoryFast=table.create(#DRIVE_NAMES,0),memorySlow=table.create(#DRIVE_NAMES,0),alpha=math.clamp(options.alpha or 0.05,0.001,1),regimeModel=nil},Features)
end
function Features:step(bar)
  assert(finite(bar.t) and finite(bar.c) and bar.c>0 and type(bar.day)=='string','valid decision bar required')
  assert(not self.previous or bar.t>self.previous.t,'decision bars must increase')
  if not self.regimeModel then
    local prior={}
    for _,d in self.prehistory.targetDaily or {} do if type(d.day)=='string' and d.day<bar.day and finite(d.t) and d.t<bar.t and finite(d.availableT) and d.availableT<=bar.t then table.insert(prior,d) end end
    self.regimeModel=Regime.new(prior,self.options.hmm)
  end
  local previous=self.previous
  local gap=previous and previous.day==bar.day and bar.t-previous.t~=300 or false
  local overnight=previous and previous.day~=bar.day or false
  local reset=not previous or gap
  local r=if previous then fraction(bar.c,previous.c) else fraction(bar.c,bar.o)
  local a=self.alpha
  self.trend=(1-a)*self.trend+a*r;self.var=(1-a)*self.var+a*r*r
  local volatility=math.sqrt(math.max(self.var,1e-10))
  local range,body=safe((safe(bar.h)-safe(bar.l))/bar.c),fraction(bar.c,bar.o)
  local lv,ln=math.log(1+math.max(0,safe(bar.v))),math.log(1+math.max(0,safe(bar.n)))
  if not self.volumeMean then self.volumeMean=lv;self.tradeMean=ln end
  local volumeActivity,tradeActivity=lv-self.volumeMean,ln-self.tradeMean
  self.volumeMean=(1-a)*self.volumeMean+a*lv;self.tradeMean=(1-a)*self.tradeMean+a*ln
  local contexts,missing,returns=bar.contexts or {},{},{}
  for _,name in CONTEXT do local c=contexts[name];missing[name]=not valid(c,bar,name);returns[name]=if missing[name] then 0 else fraction(c.c,c.o) end
  for _,name in SECTORS do local c=contexts[name];missing[name]=not valid(c,bar,name);returns[name]=if missing[name] then 0 else fraction(c.c,c.o) end
  for name,relativeName in RELATIVES do missing[relativeName]=missing[name] or missing.spyHour or contexts[name].t~=contexts.spyHour.t end
  local function relative(name) return if missing[RELATIVES[name]] then 0 else returns[name]-returns.spyHour end
  local targetName=if self.options.symbol=='QQQ' then 'qqqDaily' else 'spyDaily'
  local target=if missing[targetName] then nil else contexts[targetName]
  local probabilities=self.regimeModel:step(target)
  local dailyRange=if target and finite(target.h) and finite(target.l) then safe((target.h-target.l)/target.c) else 0
  local peer=returns.peerFive
  local peerRelative=if missing.peerFive then 0 else body-peer
  local minute=if finite(bar.minute) then bar.minute else (self.observations%78)*5+570
  local angle=2*math.pi*(minute-570)/390
  local raw={r,self.trend,volatility,range,body,fraction(bar.c,bar.vwap),lv,volumeActivity,tradeActivity,peer,peerRelative,returns.spyHour,returns.qqqHour,returns.iwmHour,returns.tltHour,returns[targetName],returns.spyDaily,returns.qqqDaily,dailyRange,math.sin(angle),math.cos(angle)}
  for _,name in CONTEXT do table.insert(raw,if missing[name] then 1 else 0) end
  table.insert(raw,if gap then 1 else 0);table.insert(raw,if overnight then 1 else 0)
  for _,p in probabilities do table.insert(raw,p) end
  for _,name in SECTORS do table.insert(raw,returns[name]) end
  for _,name in {'qqqHour','iwmHour','xlkHour','xlfHour','xleHour'} do table.insert(raw,relative(name)) end
  for _,name in SECTORS do table.insert(raw,if missing[name] then 1 else 0) end
  for _,name in {'qqqHour','iwmHour','xlkHour','xlfHour','xleHour'} do table.insert(raw,if missing[RELATIVES[name]] then 1 else 0) end
  for i,v in raw do raw[i]=safe(v) end
  local inputs,drive={self.trend,r,range*(1+math.clamp(tradeActivity,-0.9,2)),volumeActivity,relative('qqqHour'),relative('iwmHour'),returns.tltHour,relative('xlkHour'),relative('xlfHour'),relative('xleHour'),returns[targetName]},{}
  for i,x in inputs do
    self.driveScales[i]=(1-a)*self.driveScales[i]+a*x*x
    drive[i]=math.clamp(safe(x/math.sqrt(math.max(self.driveScales[i],1e-8))),-2,2)
  end
  drive[12]=math.clamp(2*(probabilities[3]-probabilities[1]),-2,2)
  if reset then self.history={};self.memoryFast=table.create(#DRIVE_NAMES,0);self.memorySlow=table.create(#DRIVE_NAMES,0) end
  local memory={}
  for i,x in drive do
    self.memoryFast[i]=0.5*self.memoryFast[i]+0.5*x
    self.memorySlow[i]=0.95*self.memorySlow[i]+0.05*x
    table.insert(memory,if self.history[1] then self.history[1][i] else 0)
    table.insert(memory,if self.history[3] then self.history[3][i] else 0)
    table.insert(memory,self.memoryFast[i]);table.insert(memory,self.memorySlow[i])
  end
  table.insert(self.history,1,table.clone(drive));if #self.history>3 then table.remove(self.history) end
  self.observations+=1;self.previous={t=bar.t,c=bar.c,day=bar.day}
  return {t=bar.t,raw=raw,names=table.clone(NAMES),drive=drive,driveNames=table.clone(DRIVE_NAMES),memory=memory,memoryNames=table.clone(MEMORY_NAMES),volatility=volatility,ready=self.observations>=12,reset=reset,regime=probabilities,contextMissing=missing}
end
function Features:info()
  return {schemaVersion=3,names=table.clone(NAMES),rawCount=#NAMES,driveCount=#DRIVE_NAMES,driveNames=table.clone(DRIVE_NAMES),memoryCount=#MEMORY_NAMES,memoryNames=table.clone(MEMORY_NAMES),memoryDefinition='normalized drive lag1/lag3 plus current-inclusive EWMA alpha .5/.05, zero initialized; gap reset',hourlyMaxAgeSeconds=7200,observations=self.observations,alpha=self.alpha,readyAfter=12,regime=if self.regimeModel then self.regimeModel:info() else {status='awaiting-first-decision'},scaling='causal EWMA RMS, current/past observations only; regimeStress=2*(high-low)',volumeMeaning='observed target ETF volume, not underlying index volume',reset='first observation or missing intraday interval; overnight does not reset'}
end
return Features
