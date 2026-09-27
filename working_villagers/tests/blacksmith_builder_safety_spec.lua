-- Deterministic regression for forged-output ownership and builder tool choice.
-- Run from the repository root with:
--   lua5.1 working_villagers/tests/blacksmith_builder_safety_spec.lua working_villagers

local modpath = (arg and arg[1]) or "working_villagers"

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected)
			.. ", got " .. tostring(actual), 2)
	end
end

local function assert_true(value, message)
	if value ~= true then
		error(message or "expected true", 2)
	end
end

local item_groups = {
	["test:pick_wood"] = {pickaxe = 1},
	["test:pick_stone"] = {pickaxe = 1},
	["test:pick_iron"] = {pickaxe = 1},
	["test:axe_wood"] = {axe = 1},
	["test:shovel_wood"] = {shovel = 1},
	["test:wrong_pick"] = {pickaxe = 1},
	["test:forged_tool"] = {pickaxe = 1},
}

local tool_caps = {
	["test:pick_wood"] = {can = {pickaxey = 1, cracky = 1}},
	["test:pick_stone"] = {can = {pickaxey = 2, cracky = 2}},
	["test:pick_iron"] = {can = {pickaxey = 4, cracky = 4}},
	["test:axe_wood"] = {can = {axey = 4, choppy = 4}},
	["test:shovel_wood"] = {can = {shovely = 4, crumbly = 4}},
	-- It advertises the semantic inventory group but cannot dig pickaxey.
	["test:wrong_pick"] = {can = {axey = 4}},
	["test:forged_tool"] = {can = {pickaxey = 4}},
}

local Stack = {}
Stack.__index = Stack

local function new_stack(name, count)
	return setmetatable({name = name or "", count = tonumber(count) or 1}, Stack)
end

function Stack:is_empty()
	return self.name == "" or self.count <= 0
end

function Stack:get_name()
	return self.name
end

function Stack:get_count()
	return self.count
end

function Stack:get_wear()
	return 0
end

function Stack:get_tool_capabilities()
	return tool_caps[self.name] or {can = {}}
end

function ItemStack(value)
	if getmetatable(value) == Stack then
		return new_stack(value.name, value.count)
	end
	if type(value) == "table" and value.name then
		return new_stack(value.name, value.count)
	end
	local raw = tostring(value or "")
	local name, count = raw:match("^(%S+)%s+(%d+)$")
	return new_stack(name or raw, count or (raw == "" and 0 or 1))
end

local registered_nodes = {
	["test:vl_rock"] = {groups = {pickaxey = 3}},
	["test:vl_wood"] = {groups = {axey = 1}},
	["test:vl_dirt"] = {groups = {shovely = 1}},
	["test:mtg_rock"] = {groups = {cracky = 1}},
}

minetest = {
	registered_nodes = registered_nodes,
	registered_items = item_groups,
	settings = {
		get = function() return nil end,
		get_bool = function(_, _, default) return default end,
	},
	get_item_group = function(name, group)
		return item_groups[name] and item_groups[name][group] or 0
	end,
	get_dig_params = function(groups, capabilities)
		for name, needed in pairs(groups or {}) do
			local level = capabilities and capabilities.can and capabilities.can[name]
			if level and level >= needed then
				return {diggable = true, time = 1}
			end
		end
		return {diggable = false}
	end,
	get_gametime = function() return 100 end,
	register_chatcommand = function() end,
}

vector = {
	round = function(value) return value end,
}

local function tool_name(kind, tier)
	if kind == "pick" or kind == "pickaxe" then
		return "test:pick_" .. tier
	end
	return "test:" .. kind .. "_" .. tier
end

local compat
compat = {
	get_item = function(name) return "test:item:" .. name end,
	get_furnace_item_candidates = function() return {} end,
	get_tool_item = function(kind, tier)
		local name = tool_name(kind, tier)
		return item_groups[name] and name or nil
	end,
	get_tool_items = function(kind, tiers)
		local result = {}
		for _, tier in ipairs(tiers or {}) do
			local name = compat.get_tool_item(kind, tier)
			if name then result[#result + 1] = name end
		end
		return result
	end,
	get_shield_items = function() return {} end,
	get_armor_items = function() return {} end,
}

local put_mode = "none"
local chest_count = 0
local inventory_access = {
	can_put_stack = function()
		return put_mode ~= "none"
	end,
	put_stack = function(_, _, _, stack)
		if put_mode == "partial" then
			chest_count = chest_count + 1
			return new_stack(stack:get_name(), stack:get_count() - 1), 1
		end
		if put_mode == "full" then
			chest_count = chest_count + stack:get_count()
			return new_stack("", 0), stack:get_count()
		end
		return ItemStack(stack), 0
	end,
}

local util = {
	is_chest = function() return true end,
}

working_villages = {
	gameplay_mode = "survival",
	compat = compat,
	voxelibre_compat = compat,
	blueprints = {},
	permissions = {},
	communication = nil,
	collaborative_tasks = nil,
	blueprint_construction = {},
	crafting = {},
	work_fallback = {
		equip_tool = function() return false end,
		ensure_tool = function() return false end,
		perform = function() return false end,
	},
	inventory_access = inventory_access,
	buildings = {},
	require = function(name)
		if name == "jobs/util" then return util end
		if name == "inventory_access" then return inventory_access end
		if name == "farming_compat" then return {} end
		if name == "job_coroutines" then return {commands = {pause = "pause"}} end
		return {}
	end,
	register_job = function() end,
	failed_pos_test = function() return false end,
	failed_pos_record = function() end,
}

-- Builder loads before blacksmith in production. Loading it first here also
-- protects against accidentally capturing working_villages.blacksmith as nil.
dofile(modpath .. "/jobs/builder.lua")
local selection = assert(working_villages.builder_tool_selection,
	"builder tool selection API was not registered")
local material_handling = assert(working_villages.builder_material_handling,
	"builder material handling API was not registered")

assert_equal(selection.required_tool_group("test:vl_rock"), "pickaxe",
	"VoxeLibre pickaxey mapping")
assert_equal(selection.required_tool_group("test:vl_wood"), "axe",
	"VoxeLibre axey mapping")
assert_equal(selection.required_tool_group("test:vl_dirt"), "shovel",
	"VoxeLibre shovely mapping")
assert_equal(selection.required_tool_group("test:mtg_rock"), "pickaxe",
	"Minetest Game cracky mapping")
assert_equal(selection.stack_can_dig_node(ItemStack("test:wrong_pick"),
	"test:vl_rock", "pickaxe"), false,
	"group-only wrong pick was accepted")
assert_equal(selection.stack_can_dig_node(ItemStack("test:pick_wood"),
	"test:vl_rock", "pickaxe"), false,
	"under-tier wood pick was accepted")
assert_true(selection.stack_can_dig_node(ItemStack("test:pick_iron"),
	"test:vl_rock", "pickaxe"), "capable iron pick was rejected")
assert_equal(selection.minimum_capable_tool_tier("test:vl_rock", "pickaxe"),
	"iron", "builder did not request the minimum capable tier")

local inventory = {
	main = {ItemStack("test:pick_wood"), ItemStack("test:pick_iron")},
	wield = ItemStack("test:axe_wood"),
}
function inventory:get_list(name)
	return name == "main" and self.main or {}
end
local builder = {}
function builder:get_inventory() return inventory end
function builder:get_wield_item_stack() return inventory.wield end
function builder:get_job_data() return nil end
function builder:move_main_to_wield(predicate)
	for index, stack in ipairs(inventory.main) do
		if predicate(stack:get_name()) then
			local previous = inventory.wield
			inventory.wield = stack
			table.remove(inventory.main, index)
			inventory.main[#inventory.main + 1] = previous
			return true
		end
	end
	return false
end

assert_true(selection.equip_capable_tool(builder, "test:vl_rock"),
	"builder could not select a capable tool from its inventory")
assert_equal(builder:get_wield_item_stack():get_name(), "test:pick_iron",
	"builder equipped the wrong tool for a VoxeLibre obstacle")
assert_equal(material_handling.should_take_from_chest(
	builder, ItemStack("test:vl_rock")), false,
	"idle builder vacuumed a registered node from shared storage")

-- Load the blacksmith only after the builder, matching the real init order.
dofile(modpath .. "/jobs/blacksmith.lua")
local blacksmith = assert(working_villages.blacksmith,
	"blacksmith API was not registered")
assert_true(type(blacksmith.deliver_order_output) == "function",
	"forged-output ownership contract is missing")

local main_count = 0
local restore_calls = 0
local releases = 0
local smith = {
	job_data = {},
	pos_data = {chest_pos = {x = 1, y = 2, z = 3}},
}
function smith:get_shared_storage_chest_for_item()
	return {x = 4, y = 5, z = 6}
end
function smith:reserve_position() return true end
function smith:release_reserved_position() releases = releases + 1 end
function smith:add_item_to_main(stack)
	restore_calls = restore_calls + 1
	main_count = main_count + stack:get_count()
	return ItemStack("")
end

local order = {count = 2}
put_mode = "partial"
local delivered, moved = blacksmith.deliver_order_output(
	smith, order, ItemStack("test:forged_tool 2"))
assert_equal(delivered, false, "partial transfer was announced complete")
assert_equal(moved, 1, "partial transfer progress")
assert_equal(order.count, 1, "partial transfer did not reduce the active order")
assert_equal(main_count, 1, "undelivered remainder was not restored exactly once")
assert_equal(chest_count + main_count, 2, "partial transfer duplicated or lost output")

-- The next attempt removes the one restored item, then deposits only that
-- remainder. No additional forging is needed and the global count stays two.
main_count = main_count - 1
put_mode = "full"
delivered, moved = blacksmith.deliver_order_output(
	smith, order, ItemStack("test:forged_tool 1"))
assert_equal(delivered, true, "remainder was not delivered")
assert_equal(moved, 1, "remainder transfer count")
assert_equal(chest_count + main_count, 2, "retry duplicated forged output")

-- A total refusal restores the transferred stack once, even though both the
-- shared chest and configured output chest are considered.
put_mode = "none"
main_count = 0
restore_calls = 0
delivered, moved = blacksmith.deliver_order_output(
	smith, {count = 1}, ItemStack("test:forged_tool 1"))
assert_equal(delivered, false, "refused transfer was announced complete")
assert_equal(moved, 0, "refused transfer reported progress")
assert_equal(main_count, 1, "refused transfer did not preserve the tool")
assert_equal(restore_calls, 1, "refused transfer restored the tool more than once")
assert_true(releases >= 1, "shared storage reservation was not released")

print("BLACKSMITH_BUILDER_SAFETY_SPEC_OK")
