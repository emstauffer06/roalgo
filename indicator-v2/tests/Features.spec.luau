local Features=require('../src/Features')
local function bar(i)
  return {t=1733149800+(i-1)*300,day='2024-12-02',minute=570+(i-1)*5,o=100+i/100,h=101+i/100,l=99+i/100,c=100.1+i/100,v=1000+i,n=50+i,vwap=100,contexts={}}
end
local a,b=Features.new({targetDaily={}}),Features.new({targetDaily={}})
for i=1,18 do
  local x,y=a:step(bar(i)),b:step(bar(i))
  assert(#x.raw==33 and #x.names==33 and #x.drive==8,'stable declared dimensions')
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
print('PASS Features33 raw /8 drive, readiness, finite missingness, causality, availability, reset rules')
