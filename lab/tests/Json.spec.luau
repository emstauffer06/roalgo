-- Json: deterministic encoder and strict RFC 8259 decoder (lab/src/Util/Json.luau).
local Test = require("./Test")
local Json = require("../src/Util/Json")

local suite = Test.suite("Json")

local function sameDouble(a: number, b: number): boolean
	if a ~= a or b ~= b then
		return false
	end
	if a == 0 and b == 0 then
		return (1 / a) == (1 / b) -- distinguishes -0 from +0
	end
	return a == b
end

Test.case(suite, "numbers use %.17g, integers without exponent below 2^53", function()
	Test.eq(Json.encode(0.1), "0.10000000000000001")
	Test.eq(Json.encode(1), "1")
	Test.eq(Json.encode(-42), "-42")
	Test.eq(Json.encode(0), "0")
	Test.eq(Json.encode(-0), "-0")
	Test.eq(Json.encode(2 ^ 53 - 1), "9007199254740991")
	Test.eq(Json.encode(2 ^ 53), "9007199254740992")
	Test.eq(Json.encode(1704186000), "1704186000")
	Test.eq(Json.encode(1e21), "1e+21")
	Test.eq(Json.encode(-1.5), "-1.5")
	Test.eq(Json.encode(1e-300), "1e-300")
end)

Test.case(suite, "awkward doubles round-trip bit-exactly", function()
	local values = {
		0.1, 0.2, 0.30000000000000004, 1e-300, -0, 0, 2 ^ 53, 2 ^ 53 + 2, -(2 ^ 53), 5e-324, 2.2250738585072014e-308,
		1.7976931348623157e308, -1.7976931348623157e308, 1 / 3, -2 / 3, math.pi, 123456789.123456789, 1e21, 1e-7,
		0.008, 4.35, 2 ^ -1074,
	}
	for _, v in values do
		local text = Json.encode(v)
		local back = Json.decode(text)
		Test.truthy(sameDouble(back, v), "round trip of " .. text)
		-- re-encoding is byte-identical (the format is a function of the double)
		Test.eq(Json.encode(back), text, "stable text for " .. text)
	end
	-- the same values inside an array
	local arr = Json.decode(Json.encode(values))
	Test.eq(#arr, #values)
	for i, v in values do
		Test.truthy(sameDouble(arr[i], v), "array element " .. i)
	end
end)

Test.case(suite, "non-finite numbers are rejected", function()
	Test.throws(function() Json.encode(0 / 0) end, "non-finite")
	Test.throws(function() Json.encode(math.huge) end, "non-finite")
	Test.throws(function() Json.encode({ a = -math.huge }) end, "non-finite")
	Test.throws(function() Json.encode({ 1, 2, 0 / 0 }) end, "non-finite")
end)

Test.case(suite, "object keys sorted by byte order, arrays keep order", function()
	Test.eq(Json.encode({ b = 1, a = 2, A = 3, ["_"] = 4 }), '{"A":3,"_":4,"a":2,"b":1}')
	Test.eq(Json.encode({ z = 1, ["\u{e9}"] = 2 }), '{"z":1,"\u{e9}":2}')
	Test.eq(Json.encode({ 3, 1, 2 }), "[3,1,2]")
	Test.eq(Json.encode({ x = { 2, 1 }, w = { q = true, p = false } }), '{"w":{"p":false,"q":true},"x":[2,1]}')
	-- deterministic: same content, different insertion order
	local a = {}
	a.k1 = 1; a.k2 = 2; a.k3 = 3
	local b = {}
	b.k3 = 3; b.k1 = 1; b.k2 = 2
	Test.eq(Json.encode(a), Json.encode(b))
end)

Test.case(suite, "strings escaped per RFC 8259", function()
	Test.eq(Json.encode('a"b\\c'), '"a\\"b\\\\c"')
	Test.eq(Json.encode("\n\r\t\b\f"), '"\\n\\r\\t\\b\\f"')
	Test.eq(Json.encode("\0\1\31"), '"\\u0000\\u0001\\u001f"')
	Test.eq(Json.encode("/"), '"/"')
	Test.eq(Json.encode("\127"), '"\127"') -- DEL is not a JSON control character
	Test.eq(Json.decode(Json.encode('a"b\\c\n\0\31')), 'a"b\\c\n\0\31')
end)

Test.case(suite, "unicode round trips and \\u escapes decode to UTF-8", function()
	local s = "caf\u{e9} \u{65e5}\u{672c} \u{1F600} \u{10FFFF}"
	Test.eq(Json.encode(s), '"' .. s .. '"', "non-ASCII passes through unescaped")
	Test.eq(Json.decode(Json.encode(s)), s)
	Test.eq(Json.decode('"\\u00e9"'), "\u{e9}")
	Test.eq(Json.decode('"\\u65E5"'), "\u{65e5}")
	Test.eq(Json.decode('"\\ud83d\\ude00"'), "\u{1F600}", "surrogate pair")
	Test.eq(Json.decode('"\\/"'), "/")
	Test.throws(function() Json.decode('"\\ud83d"') end, "surrogate")
	Test.throws(function() Json.decode('"\\ude00"') end, "surrogate")
	Test.throws(function() Json.decode('"\\ud83dx"') end, "surrogate")
	Test.throws(function() Json.encode("\xC3") end, "UTF-8")
	Test.throws(function() Json.encode("\xED\xA0\x80") end, "UTF-8") -- encoded surrogate
	Test.throws(function() Json.decode('"\xC3"') end, "UTF-8")
	Test.throws(function() Json.encode({ ["\xFF"] = 1 }) end, "UTF-8")
end)

Test.case(suite, "mixed, sparse, and non-string-key tables are rejected", function()
	Test.throws(function() Json.encode({ 1, 2, a = 3 }) end, "mixed")
	local sparse = {}
	sparse[1] = 1
	sparse[3] = 3
	Test.throws(function() Json.encode(sparse) end, "sparse")
	Test.throws(function() Json.encode({ [2] = "x" }) end, "sparse")
	Test.throws(function() Json.encode({ [1.5] = "x" }) end, "key")
	Test.throws(function() Json.encode({ [true] = 1 } :: any) end, "key")
	Test.throws(function() Json.encode(function() end :: any) end, "unsupported")
	local cyclic: any = {}
	cyclic.self = cyclic
	Test.throws(function() Json.encode(cyclic) end, "cycle")
end)

Test.case(suite, "null, booleans, empty containers", function()
	Test.eq(Json.encode(Json.null), "null")
	Test.eq(Json.decode("null"), Json.null)
	Test.eq(Json.encode({ 1, Json.null, 3 }), "[1,null,3]")
	Test.eq(Json.encode(true), "true")
	Test.eq(Json.encode({}), "[]", "a plain empty table is an empty array")
	Test.eq(Json.encode(Json.object()), "{}", "object marker")
	Test.eq(Json.encode(Json.decode("{}")), "{}", "decoded empty object stays an object")
	Test.eq(Json.encode(Json.decode("[]")), "[]")
	Test.eq(Json.encode(Json.decode('{"a":{},"b":[]}')), '{"a":{},"b":[]}')
end)

Test.case(suite, "strict decoder rejects malformed text", function()
	local bad = {
		"", " ", "01", "+1", ".5", "1.", "1e", "-", "--1", "NaN", "Infinity", "-Infinity", "nan", "'a'",
		"[1,]", "{\"a\":1,}", "[1 2]", "{\"a\" 1}", "{a:1}", "1 2", "[1]x", "// c\n1", "/* c */1", "\"a\tb\"",
		"\"a\nb\"", "\"\\x41\"", "\"\\u12\"", "\"abc", "[", "{", "tru", "nul", "1e400", "-1e400", "\xEF\xBB\xBF1",
		"{\"a\":1,\"a\":2}", "\"\\U0041\"", "[1,,2]", "0x10", "\v1",
	}
	for _, text in bad do
		local ok = pcall(Json.decode, text)
		Test.falsy(ok, "should reject " .. string.format("%q", text))
	end
end)

Test.case(suite, "decoder accepts valid RFC 8259 text", function()
	Test.eq(Json.decode(" \t\r\n 1 \n"), 1)
	Test.eq(Json.decode("-0.5e+2"), -50)
	Test.eq(Json.decode("1E2"), 100)
	Test.eq(Json.decode('"x"'), "x")
	local v = Json.decode('{"b":[1,2,{"c":null}],"a":true,"s":"\\"q\\""}')
	Test.eq(v.a, true)
	Test.eq(#v.b, 3)
	Test.eq(v.b[3].c, Json.null)
	Test.eq(v.s, '"q"')
	-- deep structures re-encode byte-identically after a decode
	local text = '{"a":[0.10000000000000001,-0,9007199254740992,1e-300],"b":{"c":"\u{e9}","d":[]}}'
	Test.eq(Json.encode(Json.decode(text)), text)
end)

Test.case(suite, "nesting limit guards runaway input", function()
	local deep = string.rep("[", 300) .. string.rep("]", 300)
	Test.throws(function() Json.decode(deep) end, "depth")
end)

return suite
