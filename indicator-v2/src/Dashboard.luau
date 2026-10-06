-- Native Studio research UI. Values are supplied by the controller, never invented.
local Dashboard={}
local C={bg=Color3.fromRGB(10,15,24),panel=Color3.fromRGB(18,26,39),raised=Color3.fromRGB(27,39,55),line=Color3.fromRGB(45,61,79),text=Color3.fromRGB(231,240,246),muted=Color3.fromRGB(144,162,181),cyan=Color3.fromRGB(84,218,237),green=Color3.fromRGB(109,233,172),red=Color3.fromRGB(251,116,143),amber=Color3.fromRGB(243,201,112),purple=Color3.fromRGB(181,153,246)}
local W,H,N=1260,900,160
local ids={"coupled","independent","numeric","raw","reduced"}
local titles={coupled="COUPLED NATIVE",independent="INDEPENDENT NATIVE",numeric="NUMERICAL MODEL",raw="MARKET ONLY",reduced="FAST INPUTS ONLY"}
local function finite(x)return type(x)=="number" and x==x and math.abs(x)<math.huge end
local function pct(x)return finite(x)and string.format("%+.2f%%",100*x)or"—"end
local function bp(x)return finite(x)and string.format("%+.2f bp",10000*x)or"—"end
local function make(kind,parent,props)local x=Instance.new(kind)for k,v in props do x[k]=v end x.Parent=parent return x end
local function round(x,r)make("UICorner",x,{CornerRadius=UDim.new(0,r or 8)})end
local function label(p,name,s,x,y,w,h,size,color)
 return make("TextLabel",p,{Name=name,Text=s,Position=UDim2.fromOffset(x,y),Size=UDim2.fromOffset(w,h),BackgroundTransparency=1,TextColor3=color or C.text,Font=Enum.Font.Gotham,TextSize=size or 12,TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Center,TextTruncate=Enum.TextTruncate.AtEnd})
end
local function panel(p,name,x,y,w,h)local f=make("Frame",p,{Name=name,Position=UDim2.fromOffset(x,y),Size=UDim2.fromOffset(w,h),BackgroundColor3=C.panel,BorderSizePixel=0})round(f)make("UIStroke",f,{Color=C.line,Thickness=1,Transparency=.3})return f end
local function color(x)return finite(x)and(x<0 and C.red or C.green)or C.text end
function Dashboard.mount(parent,callbacks)
 callbacks=callbacks or{}
 local ui={_rows={},_connections={},_handlers={},_symbol="SPY",_profile=1,_variant="coupled",_node=1,_destroyed=false,_collapsed=false,_snapshot={}}
 local gui=make("ScreenGui",parent,{Name="RoAlgoResearchDashboard",ResetOnSpawn=false,IgnoreGuiInset=true,DisplayOrder=60,ZIndexBehavior=Enum.ZIndexBehavior.Sibling})
 ui.screenGui=gui
 local surface=make("Frame",gui,{Name="Surface",Size=UDim2.fromScale(1,1),BackgroundTransparency=1})
 local main=panel(surface,"Terminal",0,14,W,H);main.AnchorPoint=Vector2.new(.5,0);main.Position=UDim2.new(.5,0,0,14)
 local scale=make("UIScale",main,{Scale=1})
 local function resize()local a=surface.AbsoluteSize;if a.X>0 and a.Y>0 then scale.Scale=math.max(.1,math.min(1,(a.X-28)/W,(a.Y-28)/H))end end
 table.insert(ui._connections,surface:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize));resize()
 local status=label(main,"Status","READY",24,849,1212,23,11,C.muted)
 local coverage=label(main,"DataCoverage","Dataset coverage / awaiting data",24,832,1212,15,9,C.muted)
 local compact=panel(surface,"Compact",14,14,420,92);compact.Visible=false
 label(compact,"Name","ROALGO / MECHANICAL POLICY LAB",14,8,390,22,13,C.cyan)
 local compactStatus=label(compact,"Status","Ready",14,33,390,17,10,C.muted)
 function ui:setStatus(value)status.Text=tostring(value);compactStatus.Text=tostring(value);gui:SetAttribute("Status",tostring(value))end
 local function invoke(key,...)local f=callbacks[key];if not f then return end;local ok,err=pcall(f,...);if not ok then ui:setStatus("Error: "..tostring(err))end end
 local buttons={}
 local function button(p,id,text,x,y,w,h,fn,primary)
  local b=make("TextButton",p,{Name=id,Text=text,Position=UDim2.fromOffset(x,y),Size=UDim2.fromOffset(w,h),BackgroundColor3=primary and C.cyan or C.raised,TextColor3=primary and C.bg or C.text,TextSize=11,Font=Enum.Font.GothamMedium,BorderSizePixel=0,Active=true,Interactable=true,AutoButtonColor=true});round(b,5)
  local function handler()if not ui._destroyed then fn()end end
  buttons[id]=b;ui._handlers[id]=handler;table.insert(ui._connections,b.MouseButton1Click:Connect(handler));return b
 end
 function ui:setCollapsed(value)self._collapsed=value==true;main.Visible=not self._collapsed;compact.Visible=self._collapsed;gui:SetAttribute("Collapsed",self._collapsed)end
 button(compact,"Expand","Open dashboard",14,58,184,23,function()ui:setCollapsed(false)end)
 button(compact,"CompactStop","Stop run",210,58,194,23,function()invoke("stop")end)
 label(main,"Brand","ROALGO",24,16,190,35,28,C.text)
 label(main,"Title","MECHANICAL POLICY LAB",223,19,450,20,15,C.cyan)
 label(main,"Subtitle","LEARNED LONG / SHORT / CLOSE  ·  VERIFIED NATIVE PHYSICS",223,41,730,17,9,C.muted)
 label(main,"Scope","HISTORICAL / EXPLORATORY",945,25,243,20,10,C.amber)
 button(main,"Collapse","−",1200,21,32,31,function()ui:setCollapsed(true)end)
 local controls=panel(main,"Controls",24,72,1212,65)
 label(controls,"Symbols","SYMBOL",12,4,100,14,8,C.muted)
 local function selectors()
  for _,s in{"SPY","QQQ"}do buttons[s].BackgroundColor3=ui._symbol==s and C.cyan or C.raised;buttons[s].TextColor3=ui._symbol==s and C.bg or C.text end
  for i=1,3 do buttons["Profile"..i].BackgroundColor3=ui._profile==i and Color3.fromRGB(58,72,93)or C.raised end
  gui:SetAttribute("SelectedSymbol",ui._symbol);gui:SetAttribute("SelectedProfile",ui._profile)
 end
 for i,s in{"SPY","QQQ"}do button(controls,s,s,12+(i-1)*57,23,51,29,function()ui._symbol=s;selectors()end)end
 label(controls,"Sessions","TRAIN / VALIDATE / EVALUATE SESSIONS",137,4,327,14,8,C.muted)
 for i,s in{"20 / 5 / 5","40 / 10 / 10","80 / 20 / 20"}do button(controls,"Profile"..i,s,137+(i-1)*106,23,100,29,function()ui._profile=i;selectors()end)end
 label(controls,"EndLabel","END DATE",466,4,112,14,8,C.muted)
 local endBox=make("TextBox",controls,{Name="EndDate",Text="2024-12-31",ClearTextOnFocus=false,Position=UDim2.fromOffset(466,23),Size=UDim2.fromOffset(105,29),BackgroundColor3=C.bg,TextColor3=C.text,TextSize=11,Font=Enum.Font.Code,BorderSizePixel=0});round(endBox,5)
 button(controls,"Run","Capture + train",584,23,137,29,function()invoke("run",ui._symbol,ui._profile,endBox.Text)end,true)
 button(controls,"Stop","Stop",731,23,66,29,function()invoke("stop")end)
 button(controls,"Replay","Replay",807,23,84,29,function()invoke("replay")end)
 button(controls,"ViewPhysics","View physics",901,23,121,29,function()invoke("viewRig")end)
 local progress=label(controls,"Progress","Ready",1034,23,164,29,11,C.muted);progress.TextXAlignment=Enum.TextXAlignment.Right
 selectors()
 function ui:setSelection(symbol,profile,endDate)self._symbol=symbol;self._profile=profile or self._profile;if endDate then endBox.Text=endDate end;selectors()end
 function ui:setProgress(done,total,phase)progress.Text=string.format("%s %d / %d",phase or"",done or 0,total or 0);gui:SetAttribute("Progress",total and total>0 and(done or 0)/total or 0)end
 local metrics={}
 for i,m in{{"Action","LATEST ACTION"},{"Position","POSITION"},{"Return","NET RETURN"},{"Drawdown","MAX DRAWDOWN"},{"Trades","CLOSED TRADES"},{"Model","MODEL"}}do
  local card=panel(main,m[1].."Card",24+(i-1)*205,150,187,69);label(card,"Caption",m[2],12,8,165,13,8,C.muted);metrics[m[1]]=label(card,"Value","—",12,24,165,30,23,C.text)
 end
 local chart=panel(main,"Chart",24,232,813,220)
 local chartTitle=label(chart,"Title","PRICE / NO FITTED DECISIONS YET",15,10,610,20,12,C.text)
 local lastPrice=label(chart,"Last","—",635,10,162,20,12,C.cyan);lastPrice.TextXAlignment=Enum.TextXAlignment.Right
 local chartArea=make("Frame",chart,{Name="Plot",Position=UDim2.fromOffset(16,42),Size=UDim2.fromOffset(780,146),BackgroundTransparency=1,ClipsDescendants=true})
 for i=0,3 do make("Frame",chartArea,{Position=UDim2.fromOffset(0,i*48),Size=UDim2.fromOffset(780,1),BackgroundColor3=C.line,BackgroundTransparency=.6,BorderSizePixel=0})end
 local lines,markers,fillMarkers={},{},{}
 for i=1,N do
  lines[i]=make("Frame",chartArea,{Name="Segment"..i,AnchorPoint=Vector2.new(.5,.5),BackgroundColor3=C.cyan,BorderSizePixel=0,Visible=false})
  markers[i]=label(chartArea,"Marker"..i,"",0,0,15,17,10,C.bg);markers[i].BackgroundTransparency=0;markers[i].TextXAlignment=Enum.TextXAlignment.Center;markers[i].Visible=false;markers[i].ZIndex=3
  fillMarkers[i]=label(chartArea,"Fill"..i,"F",0,0,13,14,9,C.text);fillMarkers[i].BackgroundTransparency=0;fillMarkers[i].BackgroundColor3=C.raised;fillMarkers[i].TextXAlignment=Enum.TextXAlignment.Center;fillMarkers[i].Visible=false;fillMarkers[i].ZIndex=4;round(fillMarkers[i],7)
 end
 local range=label(chart,"Range","B / S / C = close-time signals · F = executed fill",16,194,780,15,9,C.muted)
 local function paint()
  local rows=ui._rows;local count=#rows;local lo,hi=math.huge,-math.huge
  for _,r in rows do
   if finite(r.close)then lo=math.min(lo,r.close);hi=math.max(hi,r.close)end
   for _,fill in r.executions or{}do if finite(fill.price)then lo=math.min(lo,fill.price);hi=math.max(hi,fill.price)end end
  end
  for i=1,N do lines[i].Visible=false;markers[i].Visible=false;fillMarkers[i].Visible=false end
  gui:SetAttribute("ChartPoints",0);gui:SetAttribute("SignalMarkers",0);gui:SetAttribute("FillMarkers",0)
  if count==0 or lo==math.huge then lastPrice.Text="—";range.Text="B / S / C = close-time signals · F = executed fill";return end
  local span=math.max(hi-lo,math.abs(hi)*.0001);local prior;local signalCount,fillCount=0,0
  for i,r in rows do
   local x=(i-1)/math.max(1,count-1)*776+2;local y=136-(r.close-lo)/span*124
   if prior and r.t-prior.t==300 then local dx,dy=x-prior.x,y-prior.y;local l=lines[i];l.Position=UDim2.fromOffset((x+prior.x)/2,(y+prior.y)/2);l.Size=UDim2.fromOffset(math.sqrt(dx*dx+dy*dy),1.6);l.Rotation=math.deg(math.atan2(dy,dx));l.Visible=true end
   if r.signal=="BUY"or r.signal=="SELL"or r.signal=="CLOSE"then local m=markers[i];m.Text=r.signal=="CLOSE"and"C"or string.sub(r.signal,1,1);m.Position=UDim2.fromOffset(math.clamp(x-7,0,763),math.clamp(y-9,0,128));m.BackgroundColor3=r.signal=="BUY"and C.green or(r.signal=="SELL"and C.red or C.amber);m.Visible=true;signalCount+=1 end
   local fills=r.executions or{}
   if #fills>0 then
    local fill=fills[#fills];local price=finite(fill.price)and fill.price or r.close
    local fy=136-(price-lo)/span*124;local m=fillMarkers[i]
    m.Position=UDim2.fromOffset(math.clamp(x+7,0,763),math.clamp(fy-7,0,128));m.Visible=true
    m:SetAttribute("FillCount",#fills);m:SetAttribute("Price",price);fillCount+=#fills
   end
   prior={x=x,y=y,t=r.t}
  end
  lastPrice.Text=string.format("%.2f",rows[count].close);range.Text=tostring(rows[1].label or rows[1].t).." → "..tostring(rows[count].label or rows[count].t).." / "..count.." bars · B/S/C signals · F fills"
  gui:SetAttribute("ChartPoints",count);gui:SetAttribute("SignalMarkers",signalCount);gui:SetAttribute("FillMarkers",fillCount)
 end
 local comparison=panel(main,"Comparison",24,466,813,174)
 label(comparison,"Title","SAME EVALUATION BARS / SAME EXECUTION RULES",14,8,690,19,11,C.text)
 label(comparison,"Columns","MODEL                                     RETURN       DRAWDOWN       TRADES",14,32,770,16,9,C.muted)
 local comparisonRows={}
 for i,id in ids do
  local b=button(comparison,"Variant_"..id,titles[id],14,54+(i-1)*22,252,20,function()ui._variant=id;invoke("variant",id)end)
  comparisonRows[id]={button=b,ret=label(comparison,id.."Return","—",307,54+(i-1)*22,135,20,11,C.text),dd=label(comparison,id.."DD","—",469,54+(i-1)*22,128,20,11,C.text),trades=label(comparison,id.."Trades","—",638,54+(i-1)*22,149,20,11,C.text)}
 end
 local inspector=panel(main,"Inspector",852,232,384,408)
 local inspectTitle=label(inspector,"Title","MEASURED NATIVE STATE",14,9,355,21,12,C.cyan)
 local nodeButtons={}
 for i=1,24 do local bank=math.floor((i-1)/8);nodeButtons[i]=button(inspector,"Node"..i,tostring(i),14+((i-1)%8)*44,41+bank*26,38,22,function()ui._node=i;ui:inspect()end)end
 local nodeInfo=label(inspector,"NodeInfo","Select a measured or computed node",14,123,355,38,10,C.muted);nodeInfo.TextWrapped=true
 local driveBars,driveText={},{}
 for i,name in{"TREND","RETURN","RANGE / ACTIVITY","VOLUME","PEER RELATIVE","HOURLY","DAILY","REGIME"}do
  label(inspector,"DriveName"..i,name,14,173+(i-1)*21,128,17,8,C.muted)
  local track=make("Frame",inspector,{Position=UDim2.fromOffset(145,178+(i-1)*21),Size=UDim2.fromOffset(135,5),BackgroundColor3=C.line,BorderSizePixel=0})
  driveBars[i]=make("Frame",track,{Size=UDim2.fromScale(0,1),BackgroundColor3=C.cyan,BorderSizePixel=0});driveText[i]=label(inspector,"Drive"..i,"—",293,173+(i-1)*21,74,17,9,C.text)
 end
 local regimeText=label(inspector,"Regime","Daily regime / awaiting data",14,350,355,44,10,C.muted);regimeText.TextWrapped=true
 local contributions=panel(main,"Contributions",852,654,384,174)
 label(contributions,"Title","MEAN RETURN / LINEAR CONTRIBUTIONS",14,9,355,19,10,C.text)
 local contributionLabels={}
 for i=1,6 do contributionLabels[i]=label(contributions,"Contribution"..i,"—",14,35+(i-1)*21,355,18,9,C.muted)end
 local ledger=panel(main,"Ledger",24,654,813,174)
 label(ledger,"Title","EXECUTED TRADES / COSTS INCLUDED",14,9,785,19,11,C.text)
 local ledgerRows={}
 for i=1,4 do ledgerRows[i]=label(ledger,"Trade"..i,"—",14,39+(i-1)*29,784,24,10,C.muted)end
 label(main,"Disclaimer","EXPLORATORY RESEARCH · NOT AN UNTOUCHED HOLDOUT · MODEL SCORES ARE NOT CALIBRATED CONFIDENCE",24,875,1212,13,8,C.muted)
 local currentRecord,currentRow
 function ui:inspect()
  local rec=currentRecord
  if not rec then
   inspectTitle.Text="MEASURED NATIVE / COMPUTED NUMERIC"
   nodeInfo.Text="Select a measured or computed node"
   for i=1,8 do driveBars[i].Size=UDim2.fromScale(0,1);driveText[i].Text="—"end
   regimeText.Text="Daily regime / awaiting data"
   for _,l in contributionLabels do l.Text="—";l.TextColor3=C.muted end
   return
  end
  local selected=self._variant;local st=rec.states and rec.states[selected]
  if selected=="raw"or selected=="reduced"then st=rec.states and rec.states.coupled end
  inspectTitle.Text=(selected=="raw"or selected=="reduced")and"NATIVE DIAGNOSTIC / UNUSED BY MODEL"or(selected=="numeric"and"NUMERICAL MODEL / COMPUTED STATE"or(titles[selected].." / MEASURED X, V"))
  nodeInfo.Text="Recorded node state unavailable"
  if st and st.nodes then local n=st.nodes[self._node];if n then nodeInfo.Text=string.format("Node %d · bank %s · normalized x, v\nx %.4f · v %.4f · modeled force %.3f",self._node,tostring(n.bank or"—"),n.x or 0,n.v or 0,n.force or 0)end end
  for i,b in nodeButtons do b.BackgroundColor3=i==self._node and C.purple or C.raised end
  local f=rec.feature or{};for i=1,8 do local v=f.drive and f.drive[i];driveBars[i].Size=UDim2.fromScale(finite(v)and math.min(1,math.abs(v)/2)or 0,1);driveBars[i].BackgroundColor3=finite(v)and v<0 and C.red or C.cyan;driveText[i].Text=finite(v)and string.format("%+.3f",v)or"—"end
  local r=f.regime;regimeText.Text="Daily regime / awaiting data";if r and #r>=3 then regimeText.Text=string.format("FILTERED DAILY REGIME\nLow %.0f%%   Mid %.0f%%   High %.0f%%",100*r[1],100*r[2],100*r[3])end
  local pred=currentRow and currentRow.prediction;local parts={}
  if pred and pred.contributions then for _,v in pred.contributions do table.insert(parts,v)end;table.sort(parts,function(a,b)return math.abs(a.value)>math.abs(b.value)end)end
  for i,l in contributionLabels do local p=parts[i];l.Text=p and(tostring(p.name).."  "..bp(p.value))or"—";l.TextColor3=p and color(p.value)or C.muted end
 end
 function ui:clear()
  self._rows={};self._snapshot={};currentRecord=nil;currentRow=nil;paint()
  for _,v in metrics do v.Text="—";v.TextColor3=C.text end
  for _,r in comparisonRows do r.ret.Text="—";r.dd.Text="—";r.trades.Text="—";r.ret.TextColor3=C.text end
  for _,l in ledgerRows do l.Text="—";l.TextColor3=C.muted end
  coverage.Text="Dataset coverage / awaiting data";chartTitle.Text="PRICE / NO FITTED DECISIONS YET"
  gui:SetAttribute("Progress",0);progress.Text="Ready";self:inspect()
 end
 function ui:append(row,record)
  if self._destroyed then return end
  if row and finite(row.close)then table.insert(self._rows,row);if #self._rows>N then table.remove(self._rows,1)end;currentRow=row end
  if record then currentRecord=record end
  metrics.Action.Text=currentRow and currentRow.signal or"OBSERVE"
  local pos=currentRow and currentRow.position;metrics.Position.Text=pos==1 and"LONG"or(pos==-1 and"SHORT"or"FLAT")
  metrics.Action.TextColor3=metrics.Action.Text=="BUY"and C.green or(metrics.Action.Text=="SELL"and C.red or C.amber)
  paint();self:inspect()
 end
 function ui:render(snapshot)
  if self._destroyed then return end
  snapshot=snapshot or{};self._snapshot=snapshot
  if snapshot.selectedVariant then self._variant=snapshot.selectedVariant end
  chartTitle.Text=(snapshot.symbol or self._symbol).." / "..titles[self._variant].." / "..(snapshot.phase or"EVALUATION")
  if snapshot.message then self:setStatus(snapshot.message)end
  local chosen
  for _,r in comparisonRows do r.ret.Text="—";r.dd.Text="—";r.trades.Text="—";r.ret.TextColor3=C.text end
  for _,item in snapshot.comparisons or{}do
   local r=comparisonRows[item.id];local s=item.result and item.result.summary or item.summary or{}
   if r then r.ret.Text=pct(s.netReturn);r.ret.TextColor3=color(s.netReturn);r.dd.Text=finite(s.maxDrawdown)and string.format("%.2f%%",s.maxDrawdown*100)or"—";r.trades.Text=finite(s.tradeCount)and tostring(s.tradeCount)or(item.model and item.model.status or"untrained")end
   if item.id==self._variant then chosen=item end
  end
  for id,r in comparisonRows do r.button.BackgroundColor3=id==self._variant and Color3.fromRGB(50,77,89)or C.raised end
  local result=chosen and chosen.result;local s=result and result.summary or{}
  metrics.Return.Text=pct(s.netReturn);metrics.Return.TextColor3=color(s.netReturn);metrics.Drawdown.Text=finite(s.maxDrawdown)and string.format("%.2f%%",s.maxDrawdown*100)or"—";metrics.Trades.Text=finite(s.tradeCount)and tostring(s.tradeCount)or"—"
  metrics.Model.Text=chosen and chosen.model and chosen.model.status=="ok"and"TRAINED"or"UNTRAINED";metrics.Model.TextColor3=metrics.Model.Text=="TRAINED"and C.green or C.amber
  local trades=result and result.trades or{}
  for i,l in ledgerRows do
   local t=trades[#trades-i+1]
   if t then
    local side=t.direction==1 and"LONG"or(t.direction==-1 and"SHORT"or tostring(t.side or"—"))
    local function time(value,caption)if caption then return tostring(caption)end;if finite(value)then return DateTime.fromUnixTimestamp(value):FormatUniversalTime("MM-DD HH:mm","en-us").." UTC"end;return"—"end
    local basis=finite(t.entryEquity)and t.entryEquity>0 and t.entryEquity or 1
    l.Text=string.format("%s %s → %s  %s  fees %s / borrow %s  %s",side,time(t.entryT,t.entryLabel),time(t.exitT,t.exitLabel),pct(t.netReturn),bp((t.totalFees or 0)/basis),bp((t.borrow or 0)/basis),tostring(t.reason or""))
   else l.Text="—"end
   l.TextColor3=t and color(t.netReturn)or C.muted
  end
  local metadata=snapshot.metadata or(snapshot.dataset and snapshot.dataset.metadata)
  local samples=chosen and(chosen.report and chosen.report.samples or chosen.model and chosen.model.samples)
  if type(snapshot.coverage)=="string"then coverage.Text=snapshot.coverage
  elseif metadata then
   local split=metadata.requestedSplits or{}
   coverage.Text=string.format("%s → %s · %s bars · sessions T/V/E %s/%s/%s · fitted labels T/V %s/%s",tostring(metadata.first or"—"),tostring(metadata.last or"—"),tostring(metadata.bars or"—"),tostring(split.train or"—"),tostring(split.validation or"—"),tostring(split.test or"—"),tostring(samples and samples.train or"—"),tostring(samples and samples.validation or"—"))
  else coverage.Text="Dataset coverage / awaiting data"end
  if snapshot.rows then self._rows={};for i=math.max(1,#snapshot.rows-N+1),#snapshot.rows do local row=snapshot.rows[i];if finite(row.close)then table.insert(self._rows,row)end end;currentRow=self._rows[#self._rows];currentRecord=nil;paint()end
  if snapshot.latestRecord then currentRecord=snapshot.latestRecord end
  metrics.Action.Text=currentRow and currentRow.signal or"OBSERVE";metrics.Position.Text=currentRow and(currentRow.position==1 and"LONG"or(currentRow.position==-1 and"SHORT"or"FLAT"))or"FLAT"
  metrics.Action.TextColor3=metrics.Action.Text=="BUY"and C.green or(metrics.Action.Text=="SELL"and C.red or C.amber)
  self:inspect()
 end
 function ui:testActivate(id)assert(self._handlers[id],"Unknown control");self._handlers[id]()end
 function ui:destroy()if self._destroyed then return end;self._destroyed=true;for _,c in self._connections do c:Disconnect()end;gui:Destroy()end
 return ui
end
return Dashboard
