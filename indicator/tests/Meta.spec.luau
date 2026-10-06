local loaded, Meta = pcall(require, "../src/Meta")
assert(loaded and type(Meta) == "table", "Meta module must implement the experimental filter contract")
local passed = 0
local function test(name, run) run(); passed += 1; print("PASS " .. name) end
local function examples(n)
	local trades = {}
	for i = 1, n do
		local positive = i % 2 == 0
		trades[i] = { signalT = i * 100, entryT = i * 100 + 10, exitT = i * 100 + 20, netReturn = if positive then 0.01 else -0.01, vector = { if positive then 1 else -1, i % 3, 0, 1, 0.1, 0, 0, 0.1, 0.1 }, metaFiltered = false }
	end
	return trades
end
test("refuses small and one-class training sets", function()
	local model, reason = Meta.fit(examples(29))
	assert(model == nil and type(reason) == "string")
	local oneClass = examples(40)
	for _, t in oneClass do t.netReturn = -0.01 end
	assert(Meta.fit(oneClass) == nil)
end)
test("learns finite deterministic scores from closed after-cost labels", function()
	local trades = examples(40)
	local model = Meta.fit(trades)
	assert(model and model.sampleCount == 40 and model.cutoff > 4020)
	assert(Meta.score(model, trades[2].vector) > Meta.score(model, trades[1].vector))
	local again = Meta.fit(trades)
	for i, weight in model.weights do assert(weight == again.weights[i]) end
	local extreme = Meta.score(model, { 1e9, -1e9, 1e9, 0, 0, 0, 0, 0, 0 })
	assert(extreme > 0 and extreme < 1)
end)
test("cutoff excludes future labels and normalization uses training only", function()
	local trades = examples(60)
	local model = Meta.fit(trades, { cutoff = 4021 })
	assert(model and model.sampleCount == 40 and model.cutoff == 4021)
	for i = 41, 60 do trades[i].vector[1] = 1e8; trades[i].netReturn = -1 end
	local again = Meta.fit(trades, { cutoff = 4021 })
	assert(again.means[1] == 0)
	for i, weight in model.weights do assert(weight == again.weights[i]) end
end)
test("trade exiting on cutoff bar is excluded until its outcome is available", function()
	local model = Meta.fit(examples(40), { cutoff = 4020 })
	assert(model and model.sampleCount == 39)
end)
test("a supplied label availability time prevents unfinished-bar training", function()
	local trades = examples(40)
	trades[40].exitAvailableT = 4300
	local model = Meta.fit(trades, { cutoff = 4100 })
	assert(model and model.sampleCount == 39)
	local complete = Meta.fit(trades)
	assert(complete and complete.cutoff >= 4300)
end)
test("open or already-filtered trades never enter training", function()
	local trades = examples(40)
	for i = 1, 6 do trades[i].exitT = nil end
	for i = 7, 12 do trades[i].metaFiltered = true end
	assert(Meta.fit(trades) == nil)
end)
test("feature vectors are copied and preserve signal-time information", function()
	local feature = { drive = 1, volatility = 0.01, volumeRatio = 2, efficiency = 0.8 }
	local state = { fast = 0.5, slow = 0.1, velocity = 0.2, energy = 0.3 }
	local vector = Meta.vector(feature, state)
	feature.drive = -10; state.fast = -10
	assert(#vector == 9 and vector[1] == 1 and vector[5] == 0.5)
	assert(vector[9] == 0.4)
end)
print("Meta: " .. passed .. " behavioral tests passed")
