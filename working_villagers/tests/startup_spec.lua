-- Standalone startup foundation tests.
-- Run from the repository root with:
--   lua working_villagers/tests/startup_spec.lua working_villagers

local modpath = (arg and arg[1]) or "working_villagers"
local loader = dofile(modpath .. "/loader.lua")

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": got " .. tostring(actual) .. ", expected " .. tostring(expected), 2)
	end
end

local function expect_error(pattern, callback)
	local ok, err = pcall(callback)
	if ok then
		error("expected an error matching " .. pattern, 2)
	end
	if not tostring(err):match(pattern) then
		error("unexpected error: " .. tostring(err), 2)
	end
end

local implementations = {}
local load_counts = {}
local fake_mod = {modpath = "/virtual"}

local function fake_load(path)
	local name = path:match("^/virtual/(.+)%.lua$")
	if not name or not implementations[name] then
		error("missing fake module for " .. path)
	end
	load_counts[name] = (load_counts[name] or 0) + 1
	return implementations[name]()
end

loader.install(fake_mod, {load_file = fake_load})
assert_equal(fake_mod.require("init"), fake_mod, "preloaded init module")

local cached_value = {ok = true}
implementations.cached = function()
	return cached_value
end
assert_equal(fake_mod.require("cached"), cached_value, "module result")
assert_equal(fake_mod.require("cached"), cached_value, "cached module result")
assert_equal(load_counts.cached, 1, "module execution count")

implementations.side_effect = function()
	return nil
end
assert_equal(fake_mod.require("side_effect"), nil, "nil module result")
assert_equal(fake_mod.require("side_effect"), nil, "cached nil module result")
assert_equal(load_counts.side_effect, 1, "nil module execution count")

implementations.cycle_a = function()
	return fake_mod.require("cycle_b")
end
implementations.cycle_b = function()
	return fake_mod.require("cycle_a")
end
expect_error("circular working_villages module dependency", function()
	fake_mod.require("cycle_a")
end)

for _, invalid_name in ipairs({"", "../escape", "/absolute", "jobs\\util", "module.lua", "a//b", "a/"}) do
	expect_error("invalid working_villages module name", function()
		fake_mod.require(invalid_name)
	end)
end
expect_error("invalid working_villages module name", function()
	fake_mod.require(false)
end)

local captured_logs = {}
local original_minetest = minetest
minetest = {
	log = function(level, message)
		captured_logs[#captured_logs + 1] = {level = level, message = message}
	end,
}
local log = dofile(modpath .. "/log.lua")
log.action("loaded %d module", 1)
assert_equal(captured_logs[1].level, "action", "logger level")
assert_equal(captured_logs[1].message, "[working_villages] loaded 1 module", "formatted logger message")

log.warning("invalid %d", "value")
assert_equal(captured_logs[2].level, "warning", "fallback logger level")
assert(captured_logs[2].message:find("format error", 1, true), "format failures must remain observable")

log.verbose("details")
assert_equal(captured_logs[3].level, "verbose", "verbose logger level")
assert_equal(log.debug, log.verbose, "debug logger alias")
minetest = original_minetest

print("STARTUP_SPEC_OK")
