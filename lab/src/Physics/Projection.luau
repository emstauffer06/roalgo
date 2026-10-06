--!strict
-- Fixed random input projection (plan section 4, "Driving the network"). ENGINE CODE: uses Roblox Random.
-- Entries are drawn row-major (node 1 columns 1..D, node 2 ...) with Random.new(seed):NextNumber(-1, 1);
-- each row is then scaled to Euclidean norm one. The generated matrix itself is saved and exported:
-- pure code and the CLI must consume the saved numbers, never try to regenerate them.

local Projection = {}

Projection.PRNG_IDENTITY = "Roblox Random.new(seed):NextNumber(-1, 1), row-major, then row L2 normalisation"

function Projection.generate(seed: number, rows: number, dimension: number): { { number } }
	local rng = Random.new(seed)
	local matrix = table.create(rows)
	for i = 1, rows do
		local row = table.create(dimension, 0)
		local norm2 = 0
		for j = 1, dimension do
			local v = rng:NextNumber(-1, 1)
			row[j] = v
			norm2 += v * v
		end
		assert(norm2 > 0, "Projection: zero row")
		local inv = 1 / math.sqrt(norm2)
		for j = 1, dimension do
			row[j] *= inv
		end
		matrix[i] = row
	end
	return matrix
end

return Projection
