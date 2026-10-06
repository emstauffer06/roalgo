--!strict
-- Validated experiment configuration. Values come from lab/config/default.json via tools/gen-config.mjs.
local data = require("../generated/ConfigData")

local Config = {}

local function check(cond: any, msg: string)
	if not cond then
		error("Config: " .. msg, 3)
	end
end

function Config.validate(c: any)
	check(c.barSeconds == 3600, "barSeconds must be 3600")
	check(c.horizonHours == 8, "horizonHours must be 8")
	check(c.warmupObservations == 4, "warmupObservations must be 4 (version 1)")
	local s = c.splits
	check(s.validationStart < s.testStart and s.testStart < s.datasetEnd, "split boundaries out of order")
	check(c.maxLag == 8 and #c.lags == 3, "lag grid must be {1,4,8}")
	check(#c.lambdas == 7, "lambda grid must have seven values")
	for i = 2, #c.lambdas do
		check(c.lambdas[i] > c.lambdas[i - 1], "lambdas must increase")
	end
	local p = c.physics
	check(p.rows * p.columns == p.nodeCount and p.nodeCount == 24, "24 nodes in 4x6")
	check(#p.omegaByColumn == p.columns and #p.zetaByRow == p.rows, "omega/zeta lengths")
	check(math.abs(p.dt - 1 / 60) < 1e-15 and p.stepsPerBar == 12, "frozen dt=1/60 and 12 steps per bar")
	check(c.profiles.O14.dimension == 14 and c.profiles.R50.dimension == 50, "profile dimensions")
	check(c.profiles.H14.dimension == 14 and c.profiles.R60.dimension == 60, "profile dimensions")
	return c
end

Config.values = table.freeze(Config.validate(data.values))
Config.sourceSha256 = data.sourceSha256

return Config
