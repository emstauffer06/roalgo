--!strict
-- SpringJson: deterministic, ASCII-only JSON encoder for the spring runner harness (contract D18).
-- Part of the CLI harness only (spring-runner/); it is never packaged into the plugin.
--
-- Rules (same value -> same bytes):
--   * Object keys are sorted by byte order. A table whose keys are exactly 1..n (n >= 1) is an array;
--     a table whose keys are all strings is an object; an empty table encodes as [].
--     Mixed tables, sparse arrays, non-integer/non-positive numeric keys, other key types, cycles,
--     functions, userdata, threads, buffers and vectors raise.
--   * Numbers: integral with |x| < 2^53 -> "%.0f" (negative zero keeps "-0"); otherwise the first of
--     "%.15g", "%.16g", "%.17g" that reads back to the identical double (round-trip precision).
--     NaN and +/-Infinity raise.
--   * Strings must be valid UTF-8. '"' and '\' are escaped, control bytes (< 0x20, 0x7F) become
--     short escapes or \u00xx, every non-ASCII code point becomes \uXXXX (astral code points as a
--     UTF-16 surrogate pair). The output therefore contains only bytes 0x20..0x7E.
--   * Errors name the failing path, e.g. "SpringJson: non-finite number at $.runs[2].score".

local SpringJson = {}

local TWO_53 = 2 ^ 53
local MAX_DEPTH = 200

local SHORT: { [number]: string } = {
	[8] = "\\b",
	[9] = "\\t",
	[10] = "\\n",
	[12] = "\\f",
	[13] = "\\r",
	[34] = '\\"',
	[92] = "\\\\",
}

local function pathString(path: { any }): string
	local parts = { "$" }
	for _, key in path do
		if type(key) == "number" then
			table.insert(parts, "[" .. tostring(key) .. "]")
		else
			table.insert(parts, "." .. tostring(key))
		end
	end
	return table.concat(parts)
end

local function fail(message: string, path: { any }): never
	error("SpringJson: " .. message .. " at " .. pathString(path), 0)
end

local function encodeNumber(x: number, path: { any }): string
	if x ~= x or x == math.huge or x == -math.huge then
		fail("non-finite number", path)
	end
	if x == math.floor(x) and math.abs(x) < TWO_53 then
		if x == 0 and 1 / x < 0 then
			return "-0"
		end
		return string.format("%.0f", x)
	end
	for _, fmt in { "%.15g", "%.16g" } do
		local s = string.format(fmt, x)
		if tonumber(s) == x then
			return s
		end
	end
	return string.format("%.17g", x)
end

local function escapeCodepoint(cp: number): string
	if cp < 0x10000 then
		return string.format("\\u%04x", cp)
	end
	local v = cp - 0x10000
	return string.format("\\u%04x\\u%04x", 0xD800 + bit32.rshift(v, 10), 0xDC00 + bit32.band(v, 0x3FF))
end

local function encodeString(s: string, path: { any }): string
	-- Fast path: printable ASCII without quote or backslash.
	if not string.find(s, '[%c"\\\128-\255]') then
		return '"' .. s .. '"'
	end
	if utf8.len(s) == nil then
		fail("invalid UTF-8 in string", path)
	end
	local out = { '"' }
	for _, cp in utf8.codes(s) do
		if cp >= 0xD800 and cp <= 0xDFFF then
			fail("encoded surrogate code point in string", path)
		end
		local short = SHORT[cp]
		if short then
			table.insert(out, short)
		elseif cp < 0x20 or cp >= 0x7F then
			table.insert(out, escapeCodepoint(cp))
		else
			table.insert(out, string.char(cp))
		end
	end
	table.insert(out, '"')
	return table.concat(out)
end

local encodeValue: (value: any, path: { any }, depth: number, visiting: { [any]: boolean }, out: { string }) -> ()

local function encodeTable(t: { [any]: any }, path: { any }, depth: number, visiting: { [any]: boolean }, out: { string })
	if depth > MAX_DEPTH then
		fail("nesting depth exceeds " .. MAX_DEPTH, path)
	end
	if visiting[t] then
		fail("cycle detected", path)
	end
	if getmetatable(t :: any) ~= nil then
		fail("table with a metatable", path)
	end
	local keys: { string } = {}
	local count, maxIndex = 0, 0
	for k in t do
		local kt = type(k)
		if kt == "string" then
			table.insert(keys, k)
		elseif kt == "number" then
			if k ~= k or k ~= math.floor(k) or k < 1 then
				fail("non-integer or non-positive numeric key " .. tostring(k), path)
			end
			count += 1
			if k > maxIndex then
				maxIndex = k
			end
		else
			fail("unsupported key type " .. kt, path)
		end
	end
	if #keys > 0 and count > 0 then
		fail("mixed table (string and numeric keys)", path)
	end
	visiting[t] = true
	if #keys == 0 then
		if count ~= maxIndex then
			fail("sparse array (holes before index " .. tostring(maxIndex) .. ")", path)
		end
		table.insert(out, "[")
		for i = 1, maxIndex do
			if i > 1 then
				table.insert(out, ",")
			end
			table.insert(path, i)
			encodeValue(t[i], path, depth + 1, visiting, out)
			table.remove(path)
		end
		table.insert(out, "]")
	else
		table.sort(keys)
		table.insert(out, "{")
		for i, k in keys do
			if i > 1 then
				table.insert(out, ",")
			end
			table.insert(path, k)
			table.insert(out, encodeString(k, path))
			table.insert(out, ":")
			encodeValue(t[k], path, depth + 1, visiting, out)
			table.remove(path)
		end
		table.insert(out, "}")
	end
	visiting[t] = nil
end

encodeValue = function(value: any, path: { any }, depth: number, visiting: { [any]: boolean }, out: { string })
	local vt = type(value)
	if vt == "number" then
		table.insert(out, encodeNumber(value, path))
	elseif vt == "string" then
		table.insert(out, encodeString(value, path))
	elseif vt == "boolean" then
		table.insert(out, if value then "true" else "false")
	elseif vt == "table" then
		encodeTable(value, path, depth, visiting, out)
	elseif vt == "nil" then
		fail("nil value", path)
	else
		fail("unsupported value type " .. vt, path)
	end
end

function SpringJson.encode(value: any): string
	local out: { string } = {}
	encodeValue(value, {}, 0, {}, out)
	return table.concat(out)
end

return table.freeze(SpringJson)
