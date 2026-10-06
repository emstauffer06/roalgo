-- Smoke check run by tools/prepare-lab.test.mjs in the real Luau CLI (from the project root):
--   luau tools/prepare-lab-smoke.luau
-- Loads every group/symbol through lab/generated/Sources and prints
--   SMOKE <group>/<symbol> <rowCount> <firstTimestamp> <lastTimestamp>
-- Timestamps only; no prices are read or printed.
local Sources = require("../lab/generated/Sources")

for _, groupId in Sources.groupOrder do
	local group = Sources.groups[groupId]
	for _, symbol in group.symbolOrder do
		local rows = Sources.get(groupId, symbol).load()
		print(string.format("SMOKE %s/%s %d %d %d", groupId, symbol, #rows, rows[1][1], rows[#rows][1]))
	end
end
