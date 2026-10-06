-- Local Edit-mode research application. Finance is calculated in Luau; state comes from native physics.
local Core = require("./Core")
local Meta = require("./Meta")
local Engine = require("./Engine")
local Dashboard = require("./Dashboard")
local Http = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local BASE = "http://127.0.0.1:47622"
local App = {}

function App.start(options)
    options = options or {}
    assert(game.PlaceId == 0, "RoAlgo: this app targets the RoAlgo place")
    assert(not RunService:IsRunning(), "RoAlgo: use Studio Edit mode for verified native stepping")
    local previous = CoreGui:FindFirstChild("RoAlgoIndicatorControl")
    if previous then
        local status = previous:Invoke("status")
        assert(not status.busy, "RoAlgo: stop the current run before reloading")
        previous:Invoke("destroy")
    end
    local status = {placeId=game.PlaceId,phase="ready",busy=false,hasUI=false,completed=0,total=0,symbol="SPY"}
    local cancelled, destroyed = false, false
    local ui, engine, currentResult, comparison, metaReport, records
    local control = Instance.new("BindableFunction")
    control.Name = "RoAlgoIndicatorControl"
    local statusValue = Instance.new("StringValue")
    statusValue.Name = "RoAlgoIndicatorStatus"
    local function publish()
        if statusValue.Parent then statusValue.Value = Http:JSONEncode(status) end
    end
    local function message(text)
        status.message = text
        if ui and not destroyed then ui:setStatus(text) end
        publish()
    end
    local function viewRig()
        if engine and engine.model then
            -- The invisible step-verification bodies sit at y=5000; do not frame their bounding box.
            local pivot = engine.rig.nodes[2].rest + Vector3.new(-180,0,0)
            workspace.CurrentCamera.CFrame = CFrame.lookAt(pivot+Vector3.new(0,32,520),pivot)
            if ui and ui.setCollapsed then ui:setCollapsed(true) end
        end
    end
    local function export()
        local sourceHashes = {}
        for _,m in script.Parent:GetChildren() do
            if m:IsA("ModuleScript") then
                local savedHash=m:FindFirstChild("SourceSHA256")
                sourceHashes[m.Name] = m:GetAttribute("sha256") or (savedHash and savedHash.Value)
            end
        end
        local payload = {
            name="RoAlgo_"..status.symbol.."_"..tostring(DateTime.now().UnixTimestampMillis),
            result={version="roalgo-indicator-v1",scope="historical exploratory research",metadata=status.metadata,
                physics=currentResult,control=comparison,meta=metaReport,native=status.native,sourceHashes=sourceHashes,
                completed=status.completed,total=status.total,cancelled=cancelled,phase=status.phase,error=status.error,studioVersion=version(),placeId=game.PlaceId},
        }
        local response = Http:RequestAsync({Url=BASE.."/result",Method="POST",Headers={["Content-Type"]="application/json"},Body=Http:JSONEncode(payload)})
        assert(response.Success, "RoAlgo: result export failed: "..response.Body)
        local receipt = Http:JSONDecode(response.Body)
        status.exportPath, status.exportSHA256 = receipt.path, receipt.sha256
    end
    local function evaluateMeta(bars, baseTrades, symbol)
        local split = math.max(1, math.floor(#bars*.65))
        local cutoff = bars[split].t
        local training = {}
        for _,trade in baseTrades do
            if trade.exitT and trade.exitT < cutoff then table.insert(training,trade) end
        end
        local model, reason = Meta.fit(training,{cutoff=cutoff})
        local report={status=model and "trained: exploratory chronological evaluation" or "not trained",
            reason=reason,trainTrades=#training,cutoff=cutoff,cutoffLabel=bars[split].label,
            probabilityMeaning="Experimental model score; calibration not established"}
        if not model then return report end
        local gated=Core.new({symbol=symbol,metaModel=model})
        local ungated=Core.new({symbol=symbol})
        local numerical=Core.new({symbol=symbol})
        for i=split,#records do
            local r=records[i]
            gated:step(r.bar,r.feature,r.state)
            ungated:step(r.bar,r.feature,r.state)
            numerical:step(r.bar,r.feature,r.controlState)
        end
        report.model=model
        report.result=gated:result()
        report.ungated=ungated:result()
        report.control=numerical:result()
        return report
    end
    local function run(symbol,days)
        if status.busy or destroyed then return end
        assert(symbol=="SPY" or symbol=="QQQ","RoAlgo: unsupported symbol")
        assert(days==5 or days==20 or days==60,"RoAlgo: choose 5, 20 or 60 sessions")
        cancelled=false
        ui:setSelection(symbol,days)
        status.busy=true status.phase="loading" status.symbol=symbol status.completed=0 status.total=0
        status.days=days
        status.exportPath=nil status.exportSHA256=nil status.error=nil
        message("Loading completed five-minute "..symbol.." candles…")
        task.spawn(function()
            local finance,reference
            local ok,err=xpcall(function()
                local data=Http:JSONDecode(Http:GetAsync(BASE.."/bars?symbol="..symbol.."&days="..tostring(days).."&end=2024-12-31"))
                assert(#data.bars>0,"RoAlgo: no candles in requested interval")
                status.metadata=data.metadata status.total=#data.bars status.phase="running"
                if engine then engine:destroy() end
                engine=Engine.new(workspace,{name="RoAlgoIndicatorPhysics"})
                finance=Core.new({symbol=symbol})
                reference=Core.new({symbol=symbol})
                local filter=Core.numeric()
                records={} currentResult=nil comparison=nil metaReport=nil
                ui:render(finance:result(),reference:result(),{status="waiting for completed trade samples"})
                message("Computing native physics • "..symbol.." • "..data.metadata.first.." to "..data.metadata.last)
                for i,bar in data.bars do
                    if cancelled then break end
                    local feature=finance:features(bar)
                    if feature.reset then engine:reset() end
                    local physical=engine:step(feature.drive)
                    local numerical=filter:step(feature.drive,feature.reset)
                    local row=finance:step(bar,feature,physical)
                    reference:step(bar,feature,numerical)
                    records[i]={bar=bar,feature=feature,state=physical,controlState=numerical}
                    status.completed=i
                    ui:append(row)
                    if i%5==0 or i==#data.bars then
                        ui:setProgress(i,#data.bars)
                        status.native=engine:stats() publish()
                    end
                end
                currentResult=finance:result() comparison=reference:result()
                status.native=engine:stats()
                if not cancelled then metaReport=evaluateMeta(data.bars,currentResult.trades,symbol)
                else metaReport={status="not trained",reason="Run stopped before completion"} end
                ui:render(currentResult,comparison,metaReport)
                status.summary=currentResult.summary status.controlSummary=comparison.summary
                status.metaStatus=metaReport.status
                status.phase=cancelled and "stopped" or "complete"
                export()
                message((cancelled and "Stopped; partial results saved. " or "Complete; results saved. ")..tostring(status.completed).." bars • historical research • estimated costs included")
            end,debug.traceback)
            status.busy=false
            if not ok then
                status.phase="error" status.error=tostring(err)
                if finance and reference then
                    currentResult=finance:result() comparison=reference:result()
                    status.native=engine and engine:stats()
                    metaReport={status="not trained",reason="Failed run; partial completed rows only"}
                    pcall(function()ui:render(currentResult,comparison,metaReport)end)
                    local saved,saveError=pcall(export)
                    if not saved then status.partialExportError=tostring(saveError) end
                end
                message("Run failed: "..tostring(err))
                warn("RoAlgo indicator: "..tostring(err))
            end
            publish()
        end)
    end
    local function stop()
        cancelled=true
        if status.busy then message("Stopping after the current verified physics step…") end
    end
    local function replay()
        if status.busy or not currentResult or #currentResult.rows==0 then return end
        status.busy=true cancelled=false status.phase="replay"
        ui:render({rows={},trades={},summary={},config=currentResult.config})
        message("Recorded chart replay • physics measurements from the completed run")
        task.spawn(function()
            for i,row in currentResult.rows do
                if cancelled or destroyed then break end
                ui:append(row) ui:setProgress(i,#currentResult.rows)
                task.wait(.035)
            end
            if not destroyed then
                ui:render(currentResult,comparison,metaReport)
                status.busy=false status.phase="complete" message("Recorded replay complete. Saved results unchanged.")
            end
        end)
    end
    local function destroy()
        assert(not status.busy,"RoAlgo: stop current work before closing")
        destroyed=true
        if ui then ui:destroy() end
        if engine then engine:destroy() end
        statusValue:Destroy() control:Destroy()
    end
    ui=Dashboard.mount(CoreGui,{run=run,stop=stop,replay=replay,viewRig=viewRig})
    status.hasUI=true
    control.OnInvoke=function(command,args)
        if command=="status" then return table.clone(status)
        elseif command=="run" then run(args.symbol or "SPY",args.days or 5) return {accepted=true}
        elseif command=="stop" then stop() return {accepted=true}
        elseif command=="replay" then replay() return {accepted=true}
        elseif command=="viewRig" then viewRig() return {accepted=true}
        elseif command=="destroy" then destroy() return {accepted=true}
        elseif command=="result" then return {physics=currentResult,control=comparison,meta=metaReport}
        else error("RoAlgo: unknown control command") end
    end
    control.Parent=CoreGui statusValue.Parent=CoreGui
    message("Ready • choose SPY or QQQ, then Run • cached historical five-minute candles")
    if options.autoRun then run(options.symbol or "SPY",options.days or 5) end
    return {ok=true,placeId=game.PlaceId,control=control.Name}
end

-- Existing MarketReservoirLab plugin can launch this function on a plugin-owned thread.
function App.run(_context,args) return App.start(args) end
return App
