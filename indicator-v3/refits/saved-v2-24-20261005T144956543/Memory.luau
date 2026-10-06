local Memory={}
function Memory.augment(records,driveNames)
 assert(#driveNames==8,'exactly eight recorded v2 drive names required')
 local names={};for _,name in driveNames do for _,suffix in {'lag1','lag3','ewmaFast','ewmaSlow'}do names[#names+1]=name..'.'..suffix end end
 local history,fast,slow={},{},{};local out={}
 for _,record in records do
  local f=record.feature;assert(#f.drive==8,'eight frozen drive values required')
  if f.reset then history={};fast={};slow={}end
  local memory={}
  for i,x in f.drive do
   assert(type(x)=='number' and x==x and math.abs(x)<math.huge,'finite recorded drive required')
   fast[i]=.5*(fast[i] or 0)+.5*x;slow[i]=.95*(slow[i] or 0)+.05*x
   memory[#memory+1]=history[1] and history[1][i] or 0;memory[#memory+1]=history[3] and history[3][i] or 0
   memory[#memory+1]=fast[i];memory[#memory+1]=slow[i]
  end
  table.insert(history,1,table.clone(f.drive));if #history>3 then table.remove(history)end
  local feature=table.clone(f);feature.memory=memory;feature.memoryNames=table.clone(names)
  out[#out+1]={bar=record.bar,feature=feature,states=record.states}
 end
 return out,names
end
return Memory
