local Regime = require('../src/Regime')
local history = {}
local price = 100
for i=1,180 do
  local amplitude = if i%60<20 then 0.001 elseif i%60<40 then 0.008 else 0.025
  local before=price
  price *= 1+amplitude*math.sin(i*1.71)
  history[i]={t=i*86400,day=string.format('D%04d',i),o=before,c=price,h=math.max(before,price)*(1+amplitude),l=math.min(before,price)*(1-amplitude)}
end
local model=Regime.new(history,{iterations=12})
local info=model:info()
assert(info.status=='fit','real nondegenerate history must fit HMM')
assert(info.trainCount==179 and info.iterations==12,'fit must use only actual prehistory returns')
assert(info.stateVolatility[1]<=info.stateVolatility[2] and info.stateVolatility[2]<=info.stateVolatility[3],'states ordered by fitted volatility')
assert(info.logLikelihood==info.logLikelihood,'likelihood finite')
local future={t=181*86400,day='D0181',o=price,c=price*1.1,h=price*1.11,l=price*0.99}
local p=model:step(future)
assert(math.abs(p[1]+p[2]+p[3]-1)<1e-9 and p[3]>p[1],'large shock should favor high volatility state')
local steps=model:info().filterSteps
local repeated=model:step(future)
assert(model:info().filterSteps==steps,'repeated daily context must not refilter')
for j=1,3 do assert(repeated[j]==p[j] and p[j]>=0 and p[j]<=1,'probabilities normalized/repeat stable') end
local second=Regime.new(history,{iterations=12})
local p2=second:step(future)
for j=1,3 do assert(math.abs(p2[j]-p[j])<1e-12,'deterministic fit/filter') end
local insufficient=Regime.new({history[1]})
local u=insufficient:step(history[2])
assert(insufficient:info().status=='insufficient-history' and u[1]==1/3 and u[3]==1/3,'insufficient history uniform fallback')
local flat={}
for i=1,60 do flat[i]={t=i,c=100,o=100,h=100,l=100} end
assert(Regime.new(flat):info().status=='degenerate-history','degenerate history explicit neutral fallback')
print(string.format('PASS Regime HMM fit; train=%d iterations=%d likelihood=%.6f volatility=%.6f,%.6f,%.6f shockP=%.6f,%.6f,%.6f',info.trainCount,info.iterations,info.logLikelihood,info.stateVolatility[1],info.stateVolatility[2],info.stateVolatility[3],p[1],p[2],p[3]))
