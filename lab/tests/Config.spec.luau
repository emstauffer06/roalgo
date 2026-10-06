local Test = require("./Test")
local Config = require("../src/Config")
local suite = Test.suite("Config")

Test.case(suite, "frozen version-1 values", function()
	local c = Config.values
	Test.eq(c.splits.validationStart, 1704085200, "2024-01-01T05:00:00Z")
	Test.eq(c.splits.testStart, 1735707600, "2025-01-01T05:00:00Z")
	Test.eq(c.splits.datasetEnd, 1791000000, "2026-10-03T04:00:00Z")
	Test.eq(c.physics.stepsPerBar, 12)
	Test.eq(#Config.sourceSha256, 64, "source hash recorded")
end)

Test.case(suite, "validate rejects a changed step schedule", function()
	local bad = table.clone(Config.values)
	bad.physics = table.clone(Config.values.physics)
	bad.physics.stepsPerBar = 11
	Test.throws(function() Config.validate(bad) end, "12 steps")
end)

return suite
