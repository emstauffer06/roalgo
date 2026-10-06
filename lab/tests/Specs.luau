-- Registry of pure spec modules. Loaded lazily so one missing or broken spec is reported as a failure
-- of that spec only. Studio's RunAll and the CLI's RunPure both use this list.
-- Physics.spec is engine-only and is registered in RunAll.luau, not here.
return {
	{ name = "Harness", load = function() return require("./Harness.spec") end },
	{ name = "Config", load = function() return require("./Config.spec") end },
	{ name = "Json", load = function() return require("./Json.spec") end },
	{ name = "Data", load = function() return require("./Data.spec") end },
	{ name = "Features", load = function() return require("./Features.spec") end },
	{ name = "Context", load = function() return require("./Context.spec") end },
	{ name = "Ridge", load = function() return require("./Ridge.spec") end },
	{ name = "Markov", load = function() return require("./Markov.spec") end },
	{ name = "Experiment", load = function() return require("./Experiment.spec") end },
	{ name = "Export", load = function() return require("./Export.spec") end },
}
