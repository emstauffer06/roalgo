--!strict
-- Test-only JSON encode/decode used by Ridge.spec and Markov.spec to prove artifacts survive a real text round trip.
-- Numbers are written with %.17g (exact for IEEE doubles) and parsed with tonumber. Non-finite numbers are rejected,
-- as JSON cannot carry them. Object keys are sorted so output is deterministic. This is a fixture helper, not the
-- production serializer.
local MiniJson = {}

local function isArray(t: { [any]: any }): boolean
	local n = #t
	local count = 0
	for _ in t do
		count += 1
	end
	return count == n
end

local function encodeString(s: string): string
	local out = string.gsub(s, '[%c"\\]', function(c: string): string
		if c == '"' then
			return '\\"'
		elseif c == "\\" then
			return "\\\\"
		elseif c == "\n" then
			return "\\n"
		elseif c == "\r" then
			return "\\r"
		elseif c == "\t" then
			return "\\t"
		end
		return string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. out .. '"'
end

local function encodeValue(v: any, parts: { string })
	local tv = type(v)
	if tv == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			error("MiniJson: non-finite number", 0)
		end
		table.insert(parts, string.format("%.17g", v))
	elseif tv == "string" then
		table.insert(parts, encodeString(v))
	elseif tv == "boolean" then
		table.insert(parts, if v then "true" else "false")
	elseif tv == "table" then
		if isArray(v) then
			table.insert(parts, "[")
			for i = 1, #v do
				if i > 1 then
					table.insert(parts, ",")
				end
				encodeValue(v[i], parts)
			end
			table.insert(parts, "]")
		else
			local keys = {}
			for k in v do
				if type(k) ~= "string" then
					error("MiniJson: object keys must be strings", 0)
				end
				table.insert(keys, k)
			end
			table.sort(keys)
			table.insert(parts, "{")
			for i, k in keys do
				if i > 1 then
					table.insert(parts, ",")
				end
				table.insert(parts, encodeString(k))
				table.insert(parts, ":")
				encodeValue(v[k], parts)
			end
			table.insert(parts, "}")
		end
	else
		error("MiniJson: cannot encode " .. tv, 0)
	end
end

function MiniJson.encode(v: any): string
	local parts = {}
	encodeValue(v, parts)
	return table.concat(parts)
end

function MiniJson.decode(text: string): any
	local pos = 1
	local function skip()
		pos = string.find(text, "[^ \t\r\n]", pos) or (#text + 1)
	end
	local parseValue: () -> any
	local function parseString(): string
		local buf = {}
		pos += 1 -- opening quote
		while true do
			local c = string.sub(text, pos, pos)
			if c == "" then
				error("MiniJson: unterminated string", 0)
			elseif c == '"' then
				pos += 1
				return table.concat(buf)
			elseif c == "\\" then
				local e = string.sub(text, pos + 1, pos + 1)
				if e == "u" then
					table.insert(buf, string.char(tonumber(string.sub(text, pos + 2, pos + 5), 16) :: number))
					pos += 6
				else
					local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", n = "\n", r = "\r", t = "\t", b = "\b", f = "\f" }
					table.insert(buf, map[e] or error("MiniJson: bad escape", 0))
					pos += 2
				end
			else
				table.insert(buf, c)
				pos += 1
			end
		end
	end
	parseValue = function(): any
		skip()
		local c = string.sub(text, pos, pos)
		if c == "{" then
			pos += 1
			local obj = {}
			skip()
			if string.sub(text, pos, pos) == "}" then
				pos += 1
				return obj
			end
			while true do
				skip()
				local key = parseString()
				skip()
				assert(string.sub(text, pos, pos) == ":", "MiniJson: expected ':'")
				pos += 1
				obj[key] = parseValue()
				skip()
				local d = string.sub(text, pos, pos)
				pos += 1
				if d == "}" then
					return obj
				end
				assert(d == ",", "MiniJson: expected ',' or '}'")
			end
		elseif c == "[" then
			pos += 1
			local arr = {}
			skip()
			if string.sub(text, pos, pos) == "]" then
				pos += 1
				return arr
			end
			while true do
				table.insert(arr, parseValue())
				skip()
				local d = string.sub(text, pos, pos)
				pos += 1
				if d == "]" then
					return arr
				end
				assert(d == ",", "MiniJson: expected ',' or ']'")
			end
		elseif c == '"' then
			return parseString()
		elseif string.sub(text, pos, pos + 3) == "true" then
			pos += 4
			return true
		elseif string.sub(text, pos, pos + 4) == "false" then
			pos += 5
			return false
		else
			local s, e = string.find(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
			if not s then
				error("MiniJson: unexpected character at " .. pos, 0)
			end
			local num = tonumber(string.sub(text, s :: number, e :: number))
			if num == nil then
				error("MiniJson: bad number at " .. pos, 0)
			end
			pos = (e :: number) + 1
			return num
		end
	end
	local v = parseValue()
	skip()
	if pos <= #text then
		error("MiniJson: trailing characters", 0)
	end
	return v
end

return MiniJson
