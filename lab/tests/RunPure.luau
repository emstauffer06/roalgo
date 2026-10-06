-- CLI entry point: luau lab/tests/RunPure.luau [-a <SpecName>[/<case substring>]]
-- Uses no engine globals. Exits non-zero (error) when any test fails.
local Test = require("./Test")
local specs = require("./Specs")
local filter = ...
local result = Test.run(specs, filter)
if result.failed > 0 or result.passed == 0 then
	error(string.format("RunPure: %d failed, %d passed", result.failed, result.passed), 0)
end
