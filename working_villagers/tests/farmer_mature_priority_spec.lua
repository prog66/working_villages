-- Deterministic regression for mature-crop priority over bootstrap seed search.
-- Run from the repository root with:
--   lua5.1 working_villagers/tests/farmer_mature_priority_spec.lua working_villagers

local modpath = (arg and arg[1]) or "working_villagers"

local MATURE = "test:mature_wheat"
local SEED = "test:wheat_seed"
local SOURCE = "test:wild_seed_source"
local AIR = "air"
local crop_pos = {x = 1, y = 1, z = 0}
local source_pos = {x = 3, y = 1, z = 0}

local function key(pos)
	return table.concat({pos.x, pos.y, pos.z}, ",")
end

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected)
			.. ", got " .. tostring(actual), 2)
	end
end

local Stack = {}
Stack.__index = Stack
local function stack(value)
	local name = type(value) == "table" and value.name or tostring(value or "")
	name = name:match("^(%S*)") or ""
	return setmetatable({name = name}, Stack)
end
function Stack:get_name() return self.name end
function Stack:is_empty() return self.name == "" end
function Stack:set_count() end
_G.ItemStack = stack

local groups = {
	[SOURCE] = {flora = 1},
	[SEED] = {seed = 1},
}
local nodes = {}
_G.minetest = {
	registered_nodes = {
		[MATURE] = {drop = SEED},
		[SOURCE] = {drop = SEED, buildable_to = true, groups = groups[SOURCE]},
	},
	registered_items = {[SEED] = {}},
	get_item_group = function(name, group)
		return groups[name] and groups[name][group] or 0
	end,
	get_node = function(pos) return {name = nodes[key(pos)] or AIR} end,
	get_node_or_nil = function(pos) return {name = nodes[key(pos)] or AIR} end,
	get_gametime = function() return 100 end,
}

_G.vector = {
	add = function(pos, offset)
		return {x = pos.x + offset.x, y = pos.y + offset.y, z = pos.z + offset.z}
	end,
}

local farming = {}
function farming.get_plants()
	return {[MATURE] = {replant = {SEED}}}
end
function farming.get_demands() return {} end
function farming.is_plant(name) return name == MATURE end
function farming.is_plant_node(pos) return minetest.get_node(pos).name == MATURE end
function farming.get_plant(name)
	return name == MATURE and {replant = {SEED}} or nil
end

local compat = {
	is_voxelibre = true,
	get_tool_items = function() return {} end,
	is_farmland_node = function() return false end,
	is_tillable_dirt = function() return false end,
}

local util = {}
function util.search_surrounding(_, predicate)
	for _, pos in ipairs({crop_pos, source_pos}) do
		if predicate(pos) then
			return {x = pos.x, y = pos.y, z = pos.z}
		end
	end
	return nil
end
function util.find_adjacent_clear(pos)
	return {x = pos.x - 1, y = pos.y, z = pos.z}
end
function util.find_ground_below(pos) return pos end
function util.is_protected() return false end

local registered_job
_G.working_villages = {
	voxelibre_compat = compat,
	blueprints = {add_experience = function() end},
	crafting = nil,
	collaborative_tasks = nil,
	require = function(name)
		if name == "jobs/util" then return util end
		if name == "farming_compat" then return farming end
		error("unexpected module request: " .. tostring(name))
	end,
	register_job = function(name, definition)
		assert_equal(name, "working_villages:job_farmer", "registered farmer job")
		registered_job = definition
	end,
	failed_pos_test = function() return false end,
	failed_pos_record = function() end,
}

dofile(modpath .. "/jobs/farmer.lua")
assert(registered_job and type(registered_job.jobfunc) == "function",
	"farmer job was not registered")

local empty_inventory = {}
function empty_inventory:get_list() return {} end
function empty_inventory:room_for_item() return true end

local function run_case(has_mature_crop)
	nodes = {
		[key(crop_pos)] = has_mature_crop and MATURE or AIR,
		[key(source_pos)] = SOURCE,
	}
	local dug = {}
	local villager = {
		inventory_name = "farmer_priority_test",
		job_data = {},
		object = {get_pos = function() return {x = 0, y = 1, z = 0} end},
	}
	function villager:get_inventory() return empty_inventory end
	function villager:get_wield_item_stack() return stack("") end
	function villager:move_main_to_wield() return false end
	function villager:handle_night() end
	function villager:handle_chest() end
	function villager:handle_job_pos() end
	function villager:handle_obstacles() end
	function villager:collect_nearest_item_by_condition() end
	function villager:count_timer() end
	function villager:timer_exceeded(name)
		return name == "farmer:search" or name == "farmer:seed_search"
	end
	function villager:set_timer() end
	function villager:set_state_info(value) self.state_info = value end
	function villager:set_displayed_action(value) self.displayed_action = value end
	function villager:go_to() return true end
	function villager:dig(pos)
		local node_name = minetest.get_node(pos).name
		dug[#dug + 1] = node_name
		nodes[key(pos)] = AIR
		return true
	end
	function villager:change_direction_randomly() end
	function villager:announce_action() end

	registered_job.jobfunc(villager)
	return dug
end

local dug = run_case(true)
assert_equal(#dug, 1, "mature-crop decision dig count")
assert_equal(dug[1], MATURE,
	"natural seed search preempted a mature crop when both timers were due")
print("FARMER_MATURE_PRIORITY_SPEC_OK")

dug = run_case(false)
assert_equal(#dug, 1, "seed fallback decision dig count")
assert_equal(dug[1], SOURCE,
	"natural seed fallback stopped when no mature crop was available")
print("FARMER_NATURAL_SEED_FALLBACK_SPEC_OK")
