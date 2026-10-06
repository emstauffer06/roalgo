-- Run in Edit mode after a completed real-data application run.
local Probe={}
function Probe.run(control)
 local s=control:Invoke("status")
 assert(s.phase=="complete" and not s.busy,"complete nonbusy run required")
 local r=control:Invoke("result")
 assert(r.completed==r.total and r.total>1000,"full dataset captured")
 assert(r.native.totalSteps==r.total*12 and r.native.corruptSteps==0,"verified native intervals")
 assert(#r.comparisons==5 and #r.replayRecords>0,"five comparisons with replay")
 local samples,nrows
 local actions={BUY=0,SELL=0,CLOSE=0,HOLD=0}
 for _,v in r.comparisons do
  assert(v.model and v.model.status=="ok","all readouts trained: "..v.id)
  assert(v.model.sampleRanges.train.lastLabelAvailableT<=r.split.trainEndT,"training label cutoff")
  assert(v.model.sampleRanges.validation.lastLabelAvailableT<=r.split.validationEndT,"validation label cutoff")
  samples=samples or v.model.samples.train;assert(v.model.samples.train==samples,"matched training samples")
  local rows=v.result.rows;nrows=nrows or #rows;assert(#rows==nrows and nrows==#r.replayRecords,"matched evaluation rows")
  assert(rows[1].t==r.split.testStartT,"evaluation starts at cutoff")
  for i,row in rows do
   assert(row.t==r.replayRecords[i].bar.t,"aligned record")
   assert(actions[row.signal]~=nil,"valid action")
   actions[row.signal]+=1
   for _,fill in row.executions do
    if fill.action~="CLOSE" then assert(fill.signalT<=fill.t,"no early entry fill")end
   end
  end
 end
 assert(r.sourceHashes["src/App"] and r.sourceHashes["src/Engine"],"source provenance")
 assert(#r.cacheChunks>0,"captured states persisted")
 return {ok=true,comparisons=5,bars=r.total,evaluationRows=nrows,trainSamples=samples,actions=actions,nativeSteps=r.native.totalSteps,sourceHashes=r.sourceHashes}
end
return Probe
