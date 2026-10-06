--!strict
-- Deterministic JSON encoder and strict RFC 8259 decoder (pure Luau, no HttpService).
--
-- Encoding rules (stable bytes for the same value):
--   * Object keys are sorted by byte order (equal to Unicode code-point order for valid UTF-8).
--   * A table whose keys are exactly 1..n is an array; a table whose keys are all strings is an object.
--     Mixed tables, sparse arrays, non-integer or non-string keys, cycles, functions and other types raise.
--   * A plain empty table encodes as []; Json.object() (or an empty object returned by decode) encodes as {}.
--   * Numbers: exactly integral with |x| < 2^53 -> "%.0f" (no exponent, "-0" kept); otherwise "%.17g",
--     which round-trips every finite double. NaN and +/-Infinity raise.
--   * Strings must be valid UTF-8 (no encoded surrogates). '"', '\' and bytes < 0x20 are escaped
--     (\b \f \n \r \t short forms, otherwise \u00xx lowercase); other bytes pass through.
--   * JSON null is the sentinel Json.null.
--
-- Decoding is strict: one value, optional JSON whitespace (space, tab, CR, LF) around it, no BOM,
-- no comments, no trailing commas, no leading zeros, no duplicate object keys, no unescaped control
-- characters, valid UTF-8, \u surrogates only as proper pairs, and numbers must be finite as doubles.

local Json = {}

local MAX_DEPTH = 256
local TWO_53 = 2 ^ 53

Json.null = table.freeze({}) :: any

local OBJECT_MARKER = table.freeze({ __jsonObject = true })

-- Marks a table (new or given, without a metatable) so that it encodes as a JSON object even when empty.
function Json.object(t: { [string]: any }?): { [string]: any }
	local target = t or {}
	if getmetatable(target :: any) ~= nil then
		error("Json: object() target already has a metatable", 2)
	end
	return setmetatable(target :: any, OBJECT_MARKER) :: any
end

function Json.isObjectMarked(t: any): boolean
	return type(t) == "table" and getmetatable(t) == OBJECT_MARKER
end

local function fail(msg: string): never
	error("Json: " .. msg, 0)
end

local function checkUtf8(s: string, what: string)
	if utf8.len(s) == nil then
		fail("invalid UTF-8 in " .. what)
	end
end

local function encodeNumber(x: number): string
	if x ~= x or x == math.huge or x == -math.huge then
		fail("non-finite number")
	end
	if x == math.floor(x) and math.abs(x) < TWO_53 then
		return string.format("%.0f", x)
	end
	return string.format("%.17g", x)
end

local SHORT_ESCAPES: { [number]: string } = {
	[8] = "\\b",
	[9] = "\\t",
	[10] = "\\n",
	[12] = "\\f",
	[13] = "\\r",
	[34] = '\\"',
	[92] = "\\\\",
}

local function encodeString(s: string): string
	checkUtf8(s, "string")
	local parts = table.create(#s + 2)
	parts[1] = '"'
	local n = 1
	local runStart = 1
	for i = 1, #s do
		local b = string.byte(s, i)
		if b < 32 or b == 34 or b == 92 then
			if runStart < i then
				n += 1
				parts[n] = string.sub(s, runStart, i - 1)
			end
			n += 1
			parts[n] = SHORT_ESCAPES[b] or string.format("\\u%04x", b)
			runStart = i + 1
		end
	end
	if runStart <= #s then
		n += 1
		parts[n] = string.sub(s, runStart)
	end
	n += 1
	parts[n] = '"'
	return table.concat(parts)
end

local encodeValue: (value: any, depth: number, visiting: { [any]: boolean }, out: { string }) -> ()

local function encodeTable(t: { [any]: any }, depth: number, visiting: { [any]: boolean }, out: { string })
	if depth > MAX_DEPTH then
		fail("nesting depth exceeds " .. MAX_DEPTH)
	end
	if visiting[t] then
		fail("cycle detected")
	end
	local mt = getmetatable(t :: any)
	if mt ~= nil and mt ~= OBJECT_MARKER then
		fail("unsupported table with a metatable")
	end
	local stringKeys: { string } = {}
	local numberCount, maxIndex = 0, 0
	for k in t do
		local kt = type(k)
		if kt == "string" then
			table.insert(stringKeys, k)
		elseif kt == "number" then
			if k ~= math.floor(k) or k < 1 or k ~= k then
				fail("non-integer or non-positive numeric key " .. tostring(k))
			end
			numberCount += 1
			if k > maxIndex then
				maxIndex = k
			end
		else
			fail("unsupported key type " .. kt)
		end
	end
	if #stringKeys > 0 and numberCount > 0 then
		fail("mixed table (string and numeric keys)")
	end
	visiting[t] = true
	if numberCount > 0 or (#stringKeys == 0 and mt ~= OBJECT_MARKER) then
		if numberCount ~= maxIndex then
			fail("sparse array (holes before index " .. tostring(maxIndex) .. ")")
		end
		table.insert(out, "[")
		for i = 1, maxIndex do
			if i > 1 then
				table.insert(out, ",")
			end
			encodeValue(t[i], depth + 1, visiting, out)
		end
		table.insert(out, "]")
	else
		table.sort(stringKeys)
		table.insert(out, "{")
		for i, k in stringKeys do
			if i > 1 then
				table.insert(out, ",")
			end
			table.insert(out, encodeString(k))
			table.insert(out, ":")
			encodeValue(t[k], depth + 1, visiting, out)
		end
		table.insert(out, "}")
	end
	visiting[t] = nil
end

encodeValue = function(value: any, depth: number, visiting: { [any]: boolean }, out: { string })
	local vt = type(value)
	if value == Json.null then
		table.insert(out, "null")
	elseif vt == "number" then
		table.insert(out, encodeNumber(value))
	elseif vt == "string" then
		table.insert(out, encodeString(value))
	elseif vt == "boolean" then
		table.insert(out, if value then "true" else "false")
	elseif vt == "table" then
		encodeTable(value, depth, visiting, out)
	else
		fail("unsupported value type " .. vt)
	end
end

-- Encodes a Luau value as deterministic JSON text. opts is reserved for future use and must be nil or a table.
function Json.encode(value: any, opts: { [string]: any }?): string
	if opts ~= nil and type(opts) ~= "table" then
		error("Json: opts must be a table", 2)
	end
	local out: { string } = {}
	local ok, err = pcall(function()
		encodeValue(value, 0, {}, out)
	end)
	if not ok then
		error(err, 2)
	end
	return table.concat(out)
end

-- Exposed for callers that build JSON fragments by hand (ResultStore page assembly).
Json.encodeString = function(s: string): string
	local ok, res = pcall(encodeString, s)
	if not ok then
		error(res, 2)
	end
	return res
end
Json.encodeNumber = function(x: number): string
	local ok, res = pcall(encodeNumber, x)
	if not ok then
		error(res, 2)
	end
	return res
end

---------------------------------------------------------------------------------------------------
-- Decoder
---------------------------------------------------------------------------------------------------

type Reader = { text: string, pos: number, len: number }

local function decodeFail(r: Reader, msg: string): never
	error(string.format("Json: %s at byte %d", msg, r.pos), 0)
end

local function skipWhitespace(r: Reader)
	local text, pos, len = r.text, r.pos, r.len
	while pos <= len do
		local b = string.byte(text, pos)
		if b == 32 or b == 9 or b == 10 or b == 13 then
			pos += 1
		else
			break
		end
	end
	r.pos = pos
end

local function hex4(r: Reader, at: number): number
	local h = string.sub(r.text, at, at + 3)
	if #h ~= 4 or not string.match(h, "^%x%x%x%x$") then
		r.pos = at
		decodeFail(r, "invalid \\u escape")
	end
	return tonumber(h, 16) :: number
end

local ESCAPE_MAP: { [number]: string } = {
	[34] = '"',
	[92] = "\\",
	[47] = "/",
	[98] = "\b",
	[102] = "\f",
	[110] = "\n",
	[114] = "\r",
	[116] = "\t",
}

local function decodeString(r: Reader): string
	local text, len = r.text, r.len
	local pos = r.pos + 1 -- skip opening quote
	local parts: { string } = {}
	local runStart = pos
	while true do
		if pos > len then
			r.pos = pos
			decodeFail(r, "unterminated string")
		end
		local b = string.byte(text, pos)
		if b == 34 then
			if runStart < pos then
				table.insert(parts, string.sub(text, runStart, pos - 1))
			end
			r.pos = pos + 1
			return table.concat(parts)
		elseif b == 92 then
			if runStart < pos then
				table.insert(parts, string.sub(text, runStart, pos - 1))
			end
			local e = string.byte(text, pos + 1)
			if e == 117 then -- u
				local cp = hex4(r, pos + 2)
				pos += 6
				if cp >= 0xD800 and cp <= 0xDBFF then
					if string.sub(text, pos, pos + 1) ~= "\\u" then
						r.pos = pos
						decodeFail(r, "unpaired high surrogate")
					end
					local lo = hex4(r, pos + 2)
					if lo < 0xDC00 or lo > 0xDFFF then
						r.pos = pos
						decodeFail(r, "invalid low surrogate")
					end
					cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
					pos += 6
				elseif cp >= 0xDC00 and cp <= 0xDFFF then
					r.pos = pos
					decodeFail(r, "unpaired low surrogate")
				end
				table.insert(parts, utf8.char(cp))
			else
				local mapped = if e then ESCAPE_MAP[e] else nil
				if not mapped then
					r.pos = pos
					decodeFail(r, "invalid escape")
				end
				table.insert(parts, mapped :: string)
				pos += 2
			end
			runStart = pos
		elseif b < 32 then
			r.pos = pos
			decodeFail(r, "unescaped control character in string")
		else
			pos += 1
		end
	end
end

local function decodeNumber(r: Reader): number
	local text = r.text
	local s, e = string.find(text, "^-?%d+", r.pos)
	if not s then
		decodeFail(r, "invalid number")
	end
	local intPart = string.sub(text, r.pos, e :: number)
	local digits = if string.sub(intPart, 1, 1) == "-" then string.sub(intPart, 2) else intPart
	if #digits > 1 and string.sub(digits, 1, 1) == "0" then
		decodeFail(r, "leading zero in number")
	end
	local last = e :: number
	local fs, fe = string.find(text, "^%.%d+", last + 1)
	if fs then
		last = fe :: number
	elseif string.sub(text, last + 1, last + 1) == "." then
		r.pos = last + 1
		decodeFail(r, "missing fraction digits")
	end
	local es, ee = string.find(text, "^[eE][%+%-]?%d+", last + 1)
	if es then
		last = ee :: number
	elseif string.match(string.sub(text, last + 1, last + 1), "^[eE]$") then
		r.pos = last + 1
		decodeFail(r, "missing exponent digits")
	end
	local literal = string.sub(text, r.pos, last)
	local value = tonumber(literal)
	if value == nil or value ~= value or value == math.huge or value == -math.huge then
		decodeFail(r, "number is not a finite double: " .. literal)
	end
	r.pos = last + 1
	return value :: number
end

local decodeValue: (r: Reader, depth: number) -> any

local function decodeArray(r: Reader, depth: number): { any }
	local arr = {}
	r.pos += 1
	skipWhitespace(r)
	if string.byte(r.text, r.pos) == 93 then
		r.pos += 1
		return arr
	end
	while true do
		skipWhitespace(r)
		table.insert(arr, decodeValue(r, depth + 1))
		skipWhitespace(r)
		local b = string.byte(r.text, r.pos)
		if b == 44 then
			r.pos += 1
		elseif b == 93 then
			r.pos += 1
			return arr
		else
			decodeFail(r, "expected ',' or ']' in array")
		end
	end
end

local function decodeObject(r: Reader, depth: number): { [string]: any }
	local obj = {}
	r.pos += 1
	skipWhitespace(r)
	if string.byte(r.text, r.pos) == 125 then
		r.pos += 1
		return Json.object(obj)
	end
	while true do
		skipWhitespace(r)
		if string.byte(r.text, r.pos) ~= 34 then
			decodeFail(r, "expected string key")
		end
		local key = decodeString(r)
		if obj[key] ~= nil then
			decodeFail(r, "duplicate object key " .. string.format("%q", key))
		end
		skipWhitespace(r)
		if string.byte(r.text, r.pos) ~= 58 then
			decodeFail(r, "expected ':' after key")
		end
		r.pos += 1
		skipWhitespace(r)
		obj[key] = decodeValue(r, depth + 1)
		skipWhitespace(r)
		local b = string.byte(r.text, r.pos)
		if b == 44 then
			r.pos += 1
		elseif b == 125 then
			r.pos += 1
			return obj
		else
			decodeFail(r, "expected ',' or '}' in object")
		end
	end
end

decodeValue = function(r: Reader, depth: number): any
	if depth > MAX_DEPTH then
		decodeFail(r, "nesting depth exceeds " .. MAX_DEPTH)
	end
	local b = string.byte(r.text, r.pos)
	if b == nil then
		decodeFail(r, "unexpected end of input")
	elseif b == 123 then
		return decodeObject(r, depth)
	elseif b == 91 then
		return decodeArray(r, depth)
	elseif b == 34 then
		return decodeString(r)
	elseif b == 45 or (b >= 48 and b <= 57) then
		return decodeNumber(r)
	elseif string.sub(r.text, r.pos, r.pos + 3) == "true" then
		r.pos += 4
		return true
	elseif string.sub(r.text, r.pos, r.pos + 4) == "false" then
		r.pos += 5
		return false
	elseif string.sub(r.text, r.pos, r.pos + 3) == "null" then
		r.pos += 4
		return Json.null
	end
	error(string.format("Json: unexpected character at byte %d", r.pos), 0)
end

-- Strictly decodes one JSON text. Objects become string-keyed tables (empty ones marked with Json.object),
-- arrays become 1..n tables, null becomes Json.null.
function Json.decode(text: string): any
	if type(text) ~= "string" then
		error("Json: decode expects a string", 2)
	end
	if utf8.len(text) == nil then
		error("Json: invalid UTF-8 in input", 2)
	end
	local r: Reader = { text = text, pos = 1, len = #text }
	local ok, result = pcall(function()
		skipWhitespace(r)
		local v = decodeValue(r, 0)
		skipWhitespace(r)
		if r.pos <= r.len then
			decodeFail(r, "trailing characters")
		end
		return v
	end)
	if not ok then
		error(result, 2)
	end
	return result
end

return table.freeze(Json)
