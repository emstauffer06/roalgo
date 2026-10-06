local Probe = {}
function Probe.run(root)
    assert(root:FindFirstChild("src") and root.src:FindFirstChild("App"), "AppProbe: controller is installed")
    local app = require(root.src.App)
    assert(type(app.start) == "function", "AppProbe: controller exports start")
    local control = game:GetService("CoreGui"):FindFirstChild("RoAlgoIndicatorControl")
    assert(control and control:IsA("BindableFunction"), "AppProbe: live controls exist")
    local status = control:Invoke("status")
    assert(status.placeId == 0, "AppProbe: correct Studio target")
    assert(status.hasUI == true, "AppProbe: mounted UI")
    if status.phase == "complete" then
        assert(status.completed == status.total and status.total > 0, "AppProbe: full historical coverage")
        assert(status.native and status.native.totalSteps >= status.total * 12, "AppProbe: verified native steps")
        assert(status.exportPath and #status.exportPath > 0, "AppProbe: results exported")
    end
    return {ok=true, status=status}
end
return Probe
