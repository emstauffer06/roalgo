local Features=require('../src/Features')
local function bar(i)
  return {t=1733149800+(i-1)*300,day='2024-12-02',minute=570+(i-1)*5,o=100+i/100,h=101+i/100,l=99+i/100,c=100.1+i/100,v=1000+i,n=50+i,vwap=100,contexts={}}
end
local a,b=Features.new({targetDaily={}}),Features.new({targetDaily={}})
for i=1,18 do
  local x,y=a:step(bar(i)),b:step(bar(i))
  assert(#x.raw==49 and #x.names==49 and #x.drive==12,'v3 declared market dimensions')
  assert(#x.memory==48 and #x.memoryNames==48,'causal memory baseline has a named schema')
  assert(x.ready==(i>=12),'warmup12 observations')
  assert(x.reset==(i==1),'reset only first/gap')
  for j,v in x.raw do assert(v==v and math.abs(v)<math.huge and v==y.raw[j],'finite causal prefix') end
  for _,v in x.drive do assert(v>=-2 and v<=2,'bounded drive') end
end
local extreme=bar(19);extreme.c=1e9;extreme.h=1e9;b:step(extreme)
assert(a:info().observations==18,'later bars cannot mutate independent prefix')
local invalid=bar(19)
invalid.contexts.spyHour={t=invalid.t,o=100,c=110,availableT=invalid.t+3600}
invalid.contexts.spyDaily={t=invalid.t-10000,day=invalid.day,o=100,c=110,h=110,l=100,availableT=invalid.t}
local f=a:step(invalid)
assert(f.contextMissing.spyHour and f.contextMissing.spyDaily,'incomplete hourly and current-date daily rejected')
assert(f.raw[12]==0 and f.raw[17]==0,'unavailable context never leaks into vector')
local gap=bar(21);assert(a:step(gap).reset,'intraday missing interval resets mechanics')
local overnight=bar(22);overnight.day='2024-12-03';overnight.t+=86400;overnight.minute=570
local z=a:step(overnight);assert(not z.reset and z.raw[30]==1,'overnight does not cause physical missing interval reset')
local c=Features.new({targetDaily={}})
local valid=bar(1);valid.contexts.spyHour={t=valid.t-3600,o=100,c=101,availableT=valid.t};valid.contexts.spyDaily={t=valid.t-86400,day='2024-11-29',o=100,c=102,h=103,l=99,availableT=valid.t-100}
local q=c:step(valid);assert(q.raw[12]>0 and q.raw[17]>0,'completed prior context used')
assert(q.raw[23]==0 and q.raw[27]==0,'valid context missing indicators clear')
local prior={}
for i=1,60 do prior[i]={t=1733149800-(61-i)*86400,day=string.format('2024-10-%02d',i),availableT=1733149800-(61-i)*86400+93600,c=100+i/10,h=102+i/10,l=98+i/10} end
prior[60].day='2024-12-02';prior[60].availableT=1733149800+3600
local causal=Features.new({targetDaily=prior})
causal:step(bar(1))
assert(causal:info().regime.trainCount==58,'incomplete or current-date supplied prehistory excluded from HMM fit')
local startsLate=table.clone(prior)
startsLate[60]={t=bar(1).t-86400,day='2024-11-29',availableT=bar(1).t+100,c=110,h=111,l=109}
local fixedHistory=Features.new({targetDaily=startsLate})
fixedHistory:step(bar(1))
assert(fixedHistory:info().regime.trainCount==58,'HMM fitting prehistory must be available before first bar start, not during its interval')
local qq=Features.new({targetDaily={}},{symbol='QQQ'})
valid.contexts.qqqDaily={t=valid.t-86400,day='2024-11-29',o=200,c=198,h=201,l=197,availableT=valid.t-100}
local qqf=qq:step(valid);assert(qqf.raw[16]<0 and qqf.raw[17]>0,'target symbol selects its own daily context')
local driveNames={'trend','immediateReturn','rangeActivity','volume','qqqMinusSpy','iwmMinusSpy','tltReturn','xlkMinusSpy','xlfMinusSpy','xleMinusSpy','targetDailyReturn','regimeStress'}
for i,name in driveNames do assert(c:info().driveNames[i]==name,'financial drive identity '..name) end
local sectors=Features.new({targetDaily={}})
local market=bar(1)
for name,close in {spyHour=101,qqqHour=103,iwmHour=99,tltHour=98,xlkHour=105,xlfHour=100,xleHour=102} do
  market.contexts[name]={t=market.t-3600,availableT=market.t,o=100,c=close}
end
local m=sectors:step(market)
assert(m.drive[5]>0 and m.drive[6]<0 and m.drive[7]<0 and m.drive[8]>0 and m.drive[9]<0 and m.drive[10]>0,'individual market-relative drives preserve directions')
for i=1,12 do assert(m.memory[(i-1)*4+1]==0 and m.memory[(i-1)*4+2]==0,'first observation has no invented lag history') end
local second=sectors:step(bar(2))
for i=1,12 do assert(second.memory[(i-1)*4+1]==m.drive[i],'lag1 uses exactly previous completed drive') end
sectors:step(bar(3))
local fourth=sectors:step(bar(4))
for i=1,12 do assert(fourth.memory[(i-1)*4+2]==m.drive[i],'lag3 uses exactly three prior observations') end
local afterGap=sectors:step(bar(6))
for i=1,12 do assert(afterGap.memory[(i-1)*4+1]==0 and afterGap.memory[(i-1)*4+2]==0,'missing intraday interval clears lag history') end
local stale=bar(1)
stale.contexts.xlkHour={t=stale.t-12000,availableT=stale.t-8400,o=100,c=105}
stale.contexts.xlfHour={t=stale.t,availableT=stale.t+3600,o=100,c=95}
stale.contexts.xleHour={t=stale.t-3600,availableT=stale.t-1,o=100,c=103}
local unavailable=Features.new({targetDaily={}}):step(stale)
assert(unavailable.contextMissing.xlkHour and unavailable.contextMissing.xlfHour and unavailable.contextMissing.xleHour,'stale, future and prematurely available hourly context rejected')
assert(unavailable.drive[8]==0 and unavailable.drive[9]==0 and unavailable.drive[10]==0,'unavailable relative contexts neutral with explicit missing flags')
local oneSided=bar(1);oneSided.contexts.qqqHour=market.contexts.qqqHour
assert(Features.new({targetDaily={}}):step(oneSided).drive[5]==0,'relative return requires both legs')
local asynchronous=bar(1)
asynchronous.contexts.spyHour={t=asynchronous.t-7200,availableT=asynchronous.t-3600,o=100,c=101}
asynchronous.contexts.qqqHour={t=asynchronous.t-3600,availableT=asynchronous.t,o=100,c=105}
local noncontemporaneous=Features.new({targetDaily={}}):step(asynchronous)
assert(noncontemporaneous.drive[5]==0,'different hourly intervals cannot form a contemporaneous relative drive')
assert(noncontemporaneous.contextMissing.qqqMinusSpy and noncontemporaneous.raw[45]==1,'relative missingness is explicit even when both individual returns are available')
assert(not noncontemporaneous.contextMissing.spyHour and not noncontemporaneous.contextMissing.qqqHour,'individual completed observations remain available separately')
print('PASS Features49 raw /12 drive /48 memory: financial direction, lag history, gaps, stale/future context, matched hourly intervals')

