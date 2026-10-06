-- Proves the harness reports failure: a deliberately failing case must be counted as failed.
local Test = require("./Test")
local suite = Test.suite("Harness")

Test.case(suite, "a failing assertion is counted as a failure, not a pass", function()
	local inner = {
		{
			name = "Inner",
			load = function()
				local s = Test.suite("Inner")
				Test.case(s, "deliberate failure", function()
					Test.eq(1, 2, "deliberate")
				end)
				Test.case(s, "pass", function()
					Test.eq(1, 1)
				end)
				return s
			end,
		},
	}
	local r = Test.run(inner, nil, function() end)
	Test.eq(r.failed, 1, "failed count")
	Test.eq(r.passed, 1, "passed count")
	Test.truthy(string.find(r.failures[1].err, "deliberate", 1, true), "failure message kept")
end)

Test.case(suite, "a spec that fails to load is a failure", function()
	local r = Test.run({ { name = "Broken", load = function() error("boom") end } }, nil, function() end)
	Test.eq(r.failed, 1)
end)

Test.case(suite, "throws/near/deepEq behave", function()
	Test.throws(function() error("needle in error") end, "needle")
	Test.near(0.1 + 0.2, 0.3, 1e-15)
	Test.deepEq({ a = { 1, 2 } }, { a = { 1, 2 } })
	local ok = pcall(Test.deepEq, { a = 1 }, { a = 2 })
	Test.falsy(ok, "deepEq must fail on mismatch")
end)

return suite
