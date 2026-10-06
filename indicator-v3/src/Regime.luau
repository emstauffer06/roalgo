-- Three-state diagonal Gaussian HMM. Fit is restricted to supplied prior daily history.
-- Standardization, emission and transition estimates are frozen after bounded EM.
local Regime = {}
Regime.__index = Regime
local K=3
local FLOOR=0.05 -- standardized variance floor
local function finite(x) return type(x)=='number' and x==x and math.abs(x)<math.huge end
local function copy(x) return {x[1],x[2],x[3]} end
local function normalize(x)
  local total=0
  for j=1,K do total+=x[j] end
  if not finite(total) or total<=1e-300 then return {1/3,1/3,1/3},1 end
  for j=1,K do x[j]/=total end
  return x,total
end
local function usable(b) return b and finite(b.t) and finite(b.c) and finite(b.h) and finite(b.l) and b.c>0 and b.h>=b.l and b.l>0 end
local function obs(b,previous) return {math.log(b.c/previous),math.log(math.max((b.h-b.l)/b.c,1e-6))} end
local function emissions(self,x)
  local logs={}
  local peak=-math.huge
  for j=1,K do
    local s=0
    for d=1,2 do local v=self.variance[j][d];local delta=x[d]-self.means[j][d];s-=0.5*(math.log(2*math.pi*v)+delta*delta/v) end
    logs[j]=s;peak=math.max(peak,s)
  end
  local values={}
  for j=1,K do values[j]=math.exp(math.max(-700,logs[j]-peak)) end
  return values,peak
end
local function standardized(self,x) return {(x[1]-self.center[1])/self.scale[1],(x[2]-self.center[2])/self.scale[2]} end
local function filter(self,p,x)
  local emission=emissions(self,x)
  local nextP={0,0,0}
  for j=1,K do for k=1,K do nextP[j]+=p[k]*self.transition[k][j] end nextP[j]*=emission[j] end
  return normalize(nextP)
end
function Regime.new(history,options)
  options=options or {}
  local self=setmetatable({probability={1/3,1/3,1/3},status='insufficient-history',trainCount=0,iterations=0,filterSteps=0,lastT=-math.huge,lastClose=nil,center={0,0},scale={1,1},stateVolatility={0,0,0},logLikelihood=0},Regime)
  local xs={}
  for _,b in history or {} do
    if usable(b) and b.t>self.lastT then
      if self.lastClose then table.insert(xs,obs(b,self.lastClose)) end
      self.lastT=b.t;self.lastClose=b.c
    end
  end
  self.trainCount=#xs
  if #xs<30 then return self end
  local center,scale={0,0},{0,0}
  for _,x in xs do for d=1,2 do center[d]+=x[d]/#xs end end
  for _,x in xs do for d=1,2 do scale[d]+=(x[d]-center[d])^2/#xs end end
  if scale[1]<1e-12 and scale[2]<1e-12 then self.status='degenerate-history';return self end
  for d=1,2 do scale[d]=math.sqrt(math.max(scale[d],1e-12)) end
  self.center=center;self.scale=scale
  for i,x in xs do xs[i]=standardized(self,x) end
  local ordered=table.clone(xs);table.sort(ordered,function(a,b)return a[2]<b[2] end)
  self.means={};self.variance={};self.transition={};self.initial={1/3,1/3,1/3}
  for j=1,K do
    self.means[j]={0,ordered[math.clamp(math.floor((j-0.5)*#xs/K),1,#xs)][2]}
    self.variance[j]={1,1};self.transition[j]={0.05,0.05,0.05};self.transition[j][j]=0.9
  end
  local iterations=math.clamp(math.floor(options.iterations or 20),1,30)
  for iteration=1,iterations do
    local emit,alpha,beta={}, {}, {}
    local likelihood=0
    for i,x in xs do
      local e,peak=emissions(self,x);emit[i]=e
      local p={0,0,0}
      for j=1,K do
        if i==1 then p[j]=self.initial[j] else for k=1,K do p[j]+=alpha[i-1][k]*self.transition[k][j] end end
        p[j]*=e[j]
      end
      local total;alpha[i],total=normalize(p);likelihood+=math.log(math.max(total,1e-300))+peak
    end
    beta[#xs]={1,1,1}
    for i=#xs-1,1,-1 do
      local p={0,0,0}
      for j=1,K do for k=1,K do p[j]+=self.transition[j][k]*emit[i+1][k]*beta[i+1][k] end end
      beta[i]=normalize(p)
    end
    local weight,sum,squares={0,0,0},{{0,0},{0,0},{0,0}},{{0,0},{0,0},{0,0}}
    local transitions={{0.001,0.001,0.001},{0.001,0.001,0.001},{0.001,0.001,0.001}}
    for i,x in xs do
      local gamma=normalize({alpha[i][1]*beta[i][1],alpha[i][2]*beta[i][2],alpha[i][3]*beta[i][3]})
      if i==1 then self.initial=gamma end
      for j=1,K do weight[j]+=gamma[j];for d=1,2 do sum[j][d]+=gamma[j]*x[d];squares[j][d]+=gamma[j]*x[d]^2 end end
      if i<#xs then
        local total=0;local xi={{0,0,0},{0,0,0},{0,0,0}}
        for j=1,K do for k=1,K do xi[j][k]=alpha[i][j]*self.transition[j][k]*emit[i+1][k]*beta[i+1][k];total+=xi[j][k] end end
        if total>1e-300 then for j=1,K do for k=1,K do transitions[j][k]+=xi[j][k]/total end end end
      end
    end
    for j=1,K do
      if weight[j]>1e-8 then for d=1,2 do self.means[j][d]=sum[j][d]/weight[j];self.variance[j][d]=math.max(FLOOR,squares[j][d]/weight[j]-self.means[j][d]^2) end end
      self.transition[j]=normalize(transitions[j])
    end
    self.iterations=iteration;self.logLikelihood=likelihood
  end
  -- Label order is an emission estimate of fractional daily range, not a market label.
  local order={1,2,3}
  table.sort(order,function(a,b)return self.means[a][2]<self.means[b][2] end)
  local means,variance,transition,initial={},{},{},{}
  for j=1,K do
    local old=order[j];means[j]=self.means[old];variance[j]=self.variance[old];initial[j]=self.initial[old];transition[j]={}
    for k=1,K do transition[j][k]=self.transition[old][order[k]] end
    self.stateVolatility[j]=math.exp(means[j][2]*self.scale[2]+self.center[2])
  end
  self.means=means;self.variance=variance;self.transition=transition;self.initial=initial
  local p=copy(initial)
  for i,x in xs do
    if i==1 then local e=emissions(self,x);p=normalize({p[1]*e[1],p[2]*e[2],p[3]*e[3]}) else p=filter(self,p,x) end
  end
  self.probability=p;self.status='fit'
  return self
end
function Regime:step(daily)
  if usable(daily) and daily.t>self.lastT then
    if self.status=='fit' and self.lastClose then self.probability=filter(self,self.probability,standardized(self,obs(daily,self.lastClose)));self.filterSteps+=1 end
    self.lastT=daily.t;self.lastClose=daily.c
  end
  return copy(self.probability)
end
function Regime:info()
  return {status=self.status,trainCount=self.trainCount,iterations=self.iterations,filterSteps=self.filterSteps,lastT=self.lastT,logLikelihood=self.logLikelihood,stateVolatility=copy(self.stateVolatility),center={self.center[1],self.center[2]},scale={self.scale[1],self.scale[2]},probabilities=copy(self.probability),varianceFloor=FLOOR,method='3-state diagonal Gaussian HMM; frozen prior-history standardization and EM fit; completed daily forward filter'}
end
return Regime
