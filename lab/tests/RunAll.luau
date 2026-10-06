-- Studio test entry point: RunAll.run(filter) runs the pure specs plus engine specs.
-- Returns the harness result; callers must treat failed > 0 as failure (it never prints "done" on failure).
local Test = require("./Test")
local pureSpecs = require("./Specs")

local RunAll = {}

function RunAll.specs()
	local all = table.clone(pureSpecs)
	table.insert(all, { name = "Physics", load = function() return require("./Physics.spec") end })
	return all
end

function RunAll.run(filter: string?, log: ((string) -> ())?)
	local result = Test.run(RunAll.specs(), filter, log)
	result.ok = result.failed == 0 and result.passed > 0
	return result
end

-- Entry used by the plugin's runDev request: ctx is the plugin context, args = {filter}.
function RunAll.fromPlugin(ctx: any, args: any)
	local lines = {}
	local result = RunAll.run(args and args.filter, function(s) table.insert(lines, s) end)
	return { ok = result.ok, passed = result.passed, failed = result.failed, ran = result.ran, failures = result.failures, context = ctx and ctx.context, log = lines }
end

return RunAll
