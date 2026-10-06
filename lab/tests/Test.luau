--!strict
-- Dependency-free test harness shared by the Luau CLI (RunPure.luau) and Studio (RunAll.luau).
-- A failing assertion fails the run: Test.run returns failed > 0 and the entry points turn that into an error.

local Test = {}
Test.__index = Test

export type Case = { name: string, fn: () -> () }
export type Suite = { name: string, cases: { Case } }
export type Failure = { suite: string, case: string, err: string }
export type Result = { passed: number, failed: number, failures: { Failure }, ran: { string } }

function Test.suite(name: string): Suite
	return { name = name, cases = {} }
end

function Test.case(suite: Suite, name: string, fn: () -> ())
	table.insert(suite.cases, { name = name, fn = fn })
end

local function show(v: any): string
	if type(v) == "number" then
		return string.format("%.17g", v)
	end
	return tostring(v)
end

function Test.eq(actual: any, expected: any, msg: string?)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", msg or "eq", show(expected), show(actual)), 2)
	end
end

function Test.near(actual: number, expected: number, tol: number, msg: string?)
	if type(actual) ~= "number" or actual ~= actual or math.abs(actual - expected) > tol then
		error(string.format("%s: expected %s within %s, got %s", msg or "near", show(expected), show(tol), show(actual)), 2)
	end
end

function Test.truthy(v: any, msg: string?)
	if not v then
		error(msg or "expected a truthy value", 2)
	end
end

function Test.falsy(v: any, msg: string?)
	if v then
		error(msg or "expected a falsy value", 2)
	end
end

-- Asserts fn raises; when pattern is given the message must contain it (plain find).
function Test.throws(fn: () -> (), pattern: string?, msg: string?)
	local ok, err = pcall(fn)
	if ok then
		error((msg or "throws") .. ": expected an error", 2)
	end
	if pattern and not string.find(tostring(err), pattern, 1, true) then
		error(string.format("%s: error %q does not contain %q", msg or "throws", tostring(err), pattern), 2)
	end
end

local function deepEqual(a: any, b: any, path: string): (boolean, string?)
	if type(a) ~= type(b) then
		return false, path .. ": type " .. type(a) .. " vs " .. type(b)
	end
	if type(a) ~= "table" then
		if a == b then
			return true, nil
		end
		return false, path .. ": " .. show(a) .. " vs " .. show(b)
	end
	for k, v in a do
		local ok, why = deepEqual(v, b[k], path .. "." .. tostring(k))
		if not ok then
			return false, why
		end
	end
	for k in b do
		if a[k] == nil then
			return false, path .. "." .. tostring(k) .. ": missing on left"
		end
	end
	return true, nil
end

function Test.deepEq(actual: any, expected: any, msg: string?)
	local ok, why = deepEqual(actual, expected, "$")
	if not ok then
		error(string.format("%s: %s", msg or "deepEq", why or "?"), 2)
	end
end

-- specs: array of {name = string, load = () -> Suite | {Suite}}
-- filter: nil runs everything; otherwise a spec name, or "Spec/case substring".
function Test.run(specs: { { name: string, load: () -> any } }, filter: string?, log: ((string) -> ())?): Result
	local out = log or print
	local result: Result = { passed = 0, failed = 0, failures = {}, ran = {} }
	local specFilter, caseFilter = nil, nil
	if filter and filter ~= "" then
		local slash = string.find(filter, "/", 1, true)
		if slash then
			specFilter, caseFilter = string.sub(filter, 1, slash - 1), string.sub(filter, slash + 1)
		else
			specFilter = filter
		end
	end
	for _, spec in specs do
		if specFilter and spec.name ~= specFilter then
			continue
		end
		table.insert(result.ran, spec.name)
		local okLoad, loaded = pcall(spec.load)
		if not okLoad then
			result.failed += 1
			table.insert(result.failures, { suite = spec.name, case = "<load>", err = tostring(loaded) })
			out("FAIL " .. spec.name .. " <load>: " .. tostring(loaded))
			continue
		end
		local suites = loaded
		if type(loaded) == "table" and loaded.cases then
			suites = { loaded }
		end
		for _, suite in suites do
			for _, c in suite.cases do
				if caseFilter and not string.find(c.name, caseFilter, 1, true) then
					continue
				end
				local ok, err = xpcall(c.fn, function(e)
					return tostring(e) .. "\n" .. debug.traceback(nil, 2)
				end)
				if ok then
					result.passed += 1
				else
					result.failed += 1
					table.insert(result.failures, { suite = suite.name, case = c.name, err = tostring(err) })
					out("FAIL " .. suite.name .. " / " .. c.name .. ": " .. tostring(err))
				end
			end
		end
	end
	out(string.format("RESULT passed=%d failed=%d specs=%s", result.passed, result.failed, table.concat(result.ran, ",")))
	return result
end

return Test
