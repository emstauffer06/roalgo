-- Causal long/flat research backtest. Close decisions execute at the next open.
local Meta = if script then require(script.Parent.Meta) else require("./Meta")
local Core = {}
Core.defaults = {
	symbol = "SPY", initialEquity = 1, barSeconds = 300, minWarmup = 12,
	returnAlpha = 0.2, volatilityAlpha = 0.1, volumeAlpha = 0.1,
	minVolatility = 1e-5, maxDrive = 2,
	entryFast = 0.12, entrySpread = 0.035, entryAgreement = 0.3,
	exitFast = -0.08, exitSpread = -0.025, minEfficiency = 0.18,
	stopVol = 2, targetVol = 3, minStopFraction = 0.001, maxHoldBars = 24,
	feeBps = 1, slippageBps = 1, metaThreshold = 0.55,
}
local Methods = {}
Methods.__index = Methods
local function finite(n)
	return type(n) == "number" and n == n and math.abs(n) < math.huge
end
local function validBar(bar)
	for _, key in { "t", "o", "h", "l", "c", "v" } do
		assert(finite(bar[key]), "bar " .. key .. " must be finite")
	end
	assert(bar.o > 0 and bar.c > 0 and bar.l > 0 and bar.h >= bar.l, "invalid OHLC")
	assert(bar.h >= math.max(bar.o, bar.c) and bar.l <= math.min(bar.o, bar.c), "OHLC outside range")
	assert(bar.v >= 0 and type(bar.day) == "string" and type(bar.label) == "string", "invalid volume or time label")
end
local function sign(n)
	return if n > 0.005 then 1 elseif n < -0.005 then -1 else 0
end
function Core.new(config)
	local settings = table.clone(Core.defaults)
	for key, value in config or {} do settings[key] = value end
	for _, key in { "initialEquity", "barSeconds", "minWarmup", "minVolatility", "maxDrive", "stopVol", "targetVol", "maxHoldBars" } do
		assert(finite(settings[key]) and settings[key] > 0, "invalid config " .. key)
	end
	for _, key in { "returnAlpha", "volatilityAlpha", "volumeAlpha" } do
		assert(finite(settings[key]) and settings[key] > 0 and settings[key] <= 1, "invalid config " .. key)
	end
	for _, key in { "feeBps", "slippageBps", "minStopFraction" } do
		assert(finite(settings[key]) and settings[key] >= 0, "invalid config " .. key)
	end
	assert(settings.feeBps < 10000 and settings.slippageBps < 10000, "cost rates must be below 100 percent")
	return setmetatable({
		config = settings, rows = {}, trades = {}, cash = settings.initialEquity,
		position = nil, pending = nil, peak = settings.initialEquity, maxDrawdown = 0,
		totalFees = 0, exposedBars = 0, ambiguousBars = 0, featureCount = 0,
	}, Methods)
end
function Methods:features(bar)
	validBar(bar)
	local cfg, previous = self.config, self.featurePrevious
	if previous then assert(bar.t > previous.t, "features require strictly increasing bars") end
	local gap = if previous then bar.t - previous.t else 0
	local reset = previous == nil or previous.day ~= bar.day or gap ~= cfg.barSeconds
	local resetReason = if previous == nil then "initial" elseif previous.day ~= bar.day then "session" elseif reset then "missing-bar" else nil
	local returnValue = if reset then 0 else math.log(bar.c / previous.c)
	if reset then
		self.featureCount = 0
		self.meanReturn, self.squareReturn, self.absoluteReturn = 0, 0, 0
		self.averageVolume = bar.v
	end
	self.featureCount += 1
	local volumeRatio = if self.averageVolume > 0 then bar.v / self.averageVolume else 1
	self.meanReturn += cfg.returnAlpha * (returnValue - self.meanReturn)
	self.absoluteReturn += cfg.returnAlpha * (math.abs(returnValue) - self.absoluteReturn)
	self.squareReturn += cfg.volatilityAlpha * (returnValue ^ 2 - self.squareReturn)
	self.averageVolume += cfg.volumeAlpha * (bar.v - self.averageVolume)
	local volatility = math.max(math.sqrt(math.max(self.squareReturn, 0)), cfg.minVolatility)
	local drive = math.clamp(self.meanReturn / volatility, -cfg.maxDrive, cfg.maxDrive)
	local efficiency = if self.absoluteReturn > 1e-12 then math.clamp(math.abs(self.meanReturn) / self.absoluteReturn, 0, 1) else 0
	local feature = {
		t = bar.t, drive = drive, volatility = volatility, volumeRatio = volumeRatio,
		efficiency = efficiency, ready = self.featureCount >= cfg.minWarmup,
		reset = reset, resetReason = resetReason, warmupBars = self.featureCount,
		returnValue = returnValue, meanReturn = self.meanReturn, averageVolume = self.averageVolume,
		gapSeconds = gap, missingBars = if previous then math.max(0, math.floor(gap / cfg.barSeconds) - 1) else 0,
	}
	self.featurePrevious = { t = bar.t, c = bar.c, day = bar.day }
	return feature
end
function Core.numeric()
	local numeric = { fast = 0, medium = 0, slow = 0 }
	function numeric:step(drive, reset)
		assert(finite(drive), "numeric drive must be finite")
		if reset then self.fast, self.medium, self.slow = 0, 0, 0 end
		local oldFast = self.fast
		self.fast += 0.55 * (drive - self.fast)
		self.medium += 0.28 * (drive - self.medium)
		self.slow += 0.12 * (drive - self.slow)
		local velocity = self.fast - oldFast
		return {
			fast = self.fast, medium = self.medium, slow = self.slow,
			velocity = velocity, energy = (self.fast ^ 2 + self.medium ^ 2 + self.slow ^ 2 + velocity ^ 2) / 6,
			agreement = (sign(self.fast) + sign(self.medium) + sign(self.slow)) / 3,
		}
	end
	return numeric
end
local function closePosition(self, bar, rawPrice, reason, executions, ambiguous, exitSignalT)
	local p, cfg = self.position, self.config
	local price = rawPrice * (1 - cfg.slippageBps / 10000)
	local gross = p.quantity * price
	local fee = gross * cfg.feeBps / 10000
	self.cash = gross - fee
	self.totalFees += fee
	local trade = {
		signalT = p.signalT, signalLabel = p.signalLabel, entryT = p.entryT, entryLabel = p.entryLabel,
		exitSignalT = exitSignalT, exitT = bar.t, exitAvailableT = bar.t + cfg.barSeconds, exitLabel = bar.label,
		entryPrice = p.entryPrice, entryRawPrice = p.entryRawPrice, exitPrice = price, exitRawPrice = rawPrice,
		quantity = p.quantity, entryFee = p.entryFee, exitFee = fee, totalFees = p.entryFee + fee,
		netReturn = self.cash / p.capital - 1, pnl = self.cash - p.capital,
		reason = reason, holdingBars = p.holdingBars, ambiguous = ambiguous or false,
		vector = table.clone(p.vector), metaFiltered = p.metaFiltered, metaScore = p.metaScore,
		stop = p.stop, target = p.target, entryVolatility = p.entryVolatility,
	}
	table.insert(self.trades, trade)
	table.insert(executions, { side = "SELL", t = bar.t, label = bar.label, rawPrice = rawPrice, price = price, fee = fee, reason = reason })
	self.position = nil
	self.pending = nil
end
local function openPosition(self, bar, order, executions)
	local cfg, capital = self.config, self.cash
	local price = bar.o * (1 + cfg.slippageBps / 10000)
	local quantity = capital / (price * (1 + cfg.feeBps / 10000))
	local fee = quantity * price * cfg.feeBps / 10000
	self.cash = 0
	self.totalFees += fee
	self.position = {
		capital = capital, quantity = quantity, entryPrice = price, entryRawPrice = bar.o,
		entryFee = fee, entryT = bar.t, entryLabel = bar.label,
		signalT = order.signalT, signalLabel = order.signalLabel,
		stop = price - order.stopDistance, target = price + order.targetDistance,
		holdingBars = 0, vector = table.clone(order.vector), metaFiltered = order.metaFiltered,
		metaScore = order.metaScore, entryVolatility = order.entryVolatility,
	}
	table.insert(executions, { side = "BUY", t = bar.t, label = bar.label, rawPrice = bar.o, price = price, fee = fee, reason = "next-open entry" })
end
function Methods:step(bar, feature, physical)
	validBar(bar)
	if self.lastT then assert(bar.t > self.lastT, "step requires strictly increasing bars") end
	for _, key in { "fast", "medium", "slow", "velocity", "energy", "agreement" } do
		assert(finite(physical[key]), "physical " .. key .. " must be finite")
	end
	for _, key in { "drive", "volatility", "volumeRatio", "efficiency" } do
		assert(finite(feature[key]), "feature " .. key .. " must be finite")
	end
	assert(feature.volatility >= 0 and feature.volumeRatio >= 0, "invalid feature scale")
	if feature.t then assert(feature.t == bar.t, "feature timestamp differs from bar") end
	local cfg, executions = self.config, {}
	local exited, exposed, reason = false, false, "no entry setup"
	-- A supplied feature is supported for frozen chronological replay; no hidden feature state is read.
	local reset = feature.reset or (self.lastT ~= nil and (bar.day ~= self.lastDay or bar.t - self.lastT ~= cfg.barSeconds))
	if reset then
		local resetReason = feature.resetReason or (if bar.day ~= self.lastDay then "session" else "missing-bar")
		self.pending = nil
		if self.position then
			closePosition(self, bar, bar.o, resetReason .. " reset", executions)
			exited = true
		end
		reason = resetReason .. " reset"
	elseif self.pending then
		local order = self.pending
		self.pending = nil
		if order.side == "BUY" and not self.position then
			openPosition(self, bar, order, executions)
		elseif order.side == "SELL" and self.position then
			closePosition(self, bar, bar.o, order.reason, executions, false, order.signalT)
			exited = true
		end
	end
	if self.position then
		exposed = true
		local p = self.position
		p.holdingBars += 1
		if bar.o <= p.stop then
			closePosition(self, bar, bar.o, "stop-gap", executions)
			exited = true
		elseif bar.o >= p.target then
			-- Favorable gaps receive the target, a conservative limit-fill assumption.
			closePosition(self, bar, p.target, "target", executions)
			exited = true
		elseif bar.l <= p.stop then
			local ambiguous = bar.h >= p.target
			if ambiguous then self.ambiguousBars += 1 end
			closePosition(self, bar, p.stop, "stop", executions, ambiguous)
			exited = true
		elseif bar.h >= p.target then
			closePosition(self, bar, p.target, "target", executions)
			exited = true
		end
	end
	local signal, metaScore = "HOLD", nil
	local spread = physical.fast - physical.slow
	if self.position then
		if physical.fast < cfg.exitFast or spread < cfg.exitSpread then
			signal, reason = "SELL", "trend exit"
		elseif self.position.holdingBars >= cfg.maxHoldBars then
			signal, reason = "SELL", "holding timeout"
		else reason = "holding long" end
		if signal == "SELL" then self.pending = { side = "SELL", signalT = bar.t, reason = reason } end
	elseif exited then
		reason = executions[#executions].reason .. " executed"
	elseif not feature.ready then
		reason = "warming up"
	elseif reset then
		reason = "reset; awaiting next completed bar"
	elseif feature.efficiency < cfg.minEfficiency then
		reason = "chop suppresses entry"
	elseif physical.fast > cfg.entryFast and spread > cfg.entrySpread and physical.agreement >= cfg.entryAgreement then
		local vector = Meta.vector(feature, physical)
		local accepted = true
		if cfg.metaModel then
			if bar.t < cfg.metaModel.cutoff then accepted, reason = false, "meta training period"
			else
				metaScore = Meta.score(cfg.metaModel, vector)
				if metaScore < cfg.metaThreshold then accepted, reason = false, "experimental meta gate rejected" end
			end
		end
		if accepted then
			signal, reason = "BUY", "bullish alignment"
			local unit = math.max(bar.c * feature.volatility, bar.c * cfg.minStopFraction / cfg.stopVol)
			self.pending = {
				side = "BUY", signalT = bar.t, signalLabel = bar.label,
				stopDistance = unit * cfg.stopVol, targetDistance = unit * cfg.targetVol,
				vector = vector, entryVolatility = feature.volatility,
				metaFiltered = cfg.metaModel ~= nil, metaScore = metaScore,
			}
		end
	end
	if exposed then self.exposedBars += 1 end
	local equity = self.cash + (if self.position then self.position.quantity * bar.c else 0)
	self.peak = math.max(self.peak, equity)
	self.maxDrawdown = math.max(self.maxDrawdown, 1 - equity / self.peak)
	local row = {
		t = bar.t, label = bar.label, day = bar.day, o = bar.o, h = bar.h, l = bar.l, close = bar.c, volume = bar.v,
		signal = signal, reason = reason, fast = physical.fast, medium = physical.medium, slow = physical.slow,
		equity = equity, position = self.position ~= nil, feature = table.clone(feature), state = table.clone(physical),
		executions = executions, pendingSignal = if self.pending then self.pending.side else nil,
		metaScore = metaScore, reset = reset, gapSeconds = feature.gapSeconds,
	}
	table.insert(self.rows, row)
	self.lastT, self.lastDay, self.lastClose = bar.t, bar.day, bar.c
	return row
end
function Methods:result()
	local wins, realized = 0, 0
	for _, trade in self.trades do
		if trade.netReturn > 0 then wins += 1 end
		realized += trade.pnl
	end
	local equity = if #self.rows > 0 then self.rows[#self.rows].equity else self.config.initialEquity
	local details = nil
	if self.position then
		details = table.clone(self.position)
		details.markPrice = self.lastClose
		details.markValue = self.position.quantity * self.lastClose
		details.unrealizedPnl = details.markValue - self.position.capital
	end
	local summary = {
		netReturn = equity / self.config.initialEquity - 1, maxDrawdown = self.maxDrawdown,
		tradeCount = #self.trades, winRate = if #self.trades > 0 then wins / #self.trades else 0,
		exposure = if #self.rows > 0 then self.exposedBars / #self.rows else 0,
		ambiguousBars = self.ambiguousBars, openPosition = self.position ~= nil, openPositionDetails = details,
		finalEquity = equity, totalFees = self.totalFees, realizedPnl = realized,
		pendingSignal = if self.pending then self.pending.side else nil, rowCount = #self.rows,
		markConvention = "Open exposure marked at last close; exit costs charged only on execution",
	}
	return { rows = self.rows, trades = self.trades, summary = summary, config = self.config }
end
return Core
