-- CLI helper for tools/gen-result-fixtures.mjs: luau lab/tests/fixtures/PrintFixture.luau -a <PrngVectors|ExportSample>
-- Prints the builder's compact JSON on one line. Pure; no engine globals.
local name = ...
if name == "PrngVectors" then
	print(require("./PrngVectorsBuilder").build())
elseif name == "ExportSample" then
	print(require("./ExportSampleBuilder").build())
else
	error("PrintFixture: unknown fixture " .. tostring(name), 0)
end
