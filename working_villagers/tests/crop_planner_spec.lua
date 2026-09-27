-- Deterministic crop layout regression.

local modpath = (arg and arg[1]) or "working_villagers"

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected)
			.. ", got " .. tostring(actual), 2)
	end
end

_G.minetest = {
	settings = {
		get = function(_, name)
			if name == "working_villages_farmer_crop_strategy" then
				return "uniform"
			end
		end,
	},
}

local planner = dofile(modpath .. "/crop_planner.lua")
local farmer = {inventory_name = "farmer:stable", job_data = {}}
local center = {x = 0, y = 1, z = 0}
local first_pos = {x = 1, y = 1, z = 0}

local first = planner.choose(farmer, {"test:seed_z", "test:seed_a"}, first_pos, center)
assert(first == "test:seed_a" or first == "test:seed_z", "uniform plan chose no seed")
assert_equal(
	planner.choose(farmer, {"test:seed_a", "test:seed_z"}, first_pos, center),
	first,
	"inventory order changed the uniform crop plan"
)
assert_equal(planner.get_primary(farmer), first, "uniform primary seed was not persisted")

local alternative = first == "test:seed_a" and "test:seed_z" or "test:seed_a"
assert_equal(planner.choose(farmer, {alternative}, first_pos, center), nil,
	"transient missing primary replanned immediately")
assert_equal(planner.choose(farmer, {alternative}, first_pos, center), nil,
	"second transient miss replanned immediately")
assert_equal(planner.choose(farmer, {alternative}, first_pos, center), alternative,
	"uniform plan did not recover after a sustained seed shortage")
print("CROP_PLANNER_UNIFORM_SPEC_OK")

local row_farmer = {
	inventory_name = "farmer:rows",
	job_data = {
		farmer_crop_plan = {schema = 1, strategy = "rows", rows = {}, missing = {}},
	},
}
local row_pos = {x = 2, y = 1, z = 4}
local row_seed = planner.choose(row_farmer, {"test:beet", "test:wheat"}, row_pos, center)
assert_equal(
	planner.choose(row_farmer, {"test:wheat", "test:beet"}, {x = -3, y = 1, z = 5}, center),
	row_seed,
	"two cells in the same planned row selected different crops"
)
planner.remember(row_farmer, "test:carrot", row_pos, center)
assert_equal(planner.choose(row_farmer, {"test:carrot", "test:wheat"}, row_pos, center),
	"test:carrot", "harvested row crop was not remembered")
print("CROP_PLANNER_ROWS_SPEC_OK")

local available_farmer = {
	inventory_name = "farmer:available",
	job_data = {
		farmer_crop_plan = {schema = 1, strategy = "available", rows = {}, missing = {}},
	},
}
assert_equal(planner.choose(available_farmer, {"test:z", "test:a"}, first_pos, center),
	"test:a", "available strategy depends on inventory ordering")
print("CROP_PLANNER_AVAILABLE_SPEC_OK")
