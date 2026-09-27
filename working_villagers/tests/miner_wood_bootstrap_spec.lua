-- Deterministic regression for the miner's renewable first-tool bootstrap.
-- Run from the repository root with:
--   lua5.1 working_villagers/tests/miner_wood_bootstrap_spec.lua working_villagers

local modpath = (arg and arg[1]) or "working_villagers"

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected)
			.. ", got " .. tostring(actual), 2)
	end
end

local Stack = {}
Stack.__index = Stack

local function stack_from(value)
	if getmetatable(value) == Stack then
		return setmetatable({name = value.name, count = value.count}, Stack)
	end
	if type(value) == "table" and value.name then
		return setmetatable({name = value.name, count = tonumber(value.count) or 1}, Stack)
	end
	local name, count = tostring(value or ""):match("^(%S+)%s*(%d*)$")
	if not name or name == "" then
		return setmetatable({name = "", count = 0}, Stack)
	end
	return setmetatable({name = name, count = tonumber(count) or 1}, Stack)
end

function Stack:is_empty()
	return self.name == "" or self.count <= 0
end

function Stack:get_name()
	return self:is_empty() and "" or self.name
end

function Stack:get_count()
	return self:is_empty() and 0 or self.count
end

function Stack:get_wear()
	return 0
end

function Stack:get_tool_capabilities()
	return {}
end

function Stack:take_item(count)
	count = math.min(tonumber(count) or 1, self:get_count())
	local taken = stack_from({name = self.name, count = count})
	self.count = self.count - count
	if self.count <= 0 then
		self.name = ""
		self.count = 0
	end
	return taken
end

function Stack:to_string()
	if self:is_empty() then
		return ""
	end
	return self.name .. (self.count > 1 and (" " .. self.count) or "")
end

_G.ItemStack = stack_from

local Inventory = {}
Inventory.__index = Inventory

function Inventory:new(items)
	local result = setmetatable({main = {}}, self)
	for index = 1, 16 do
		result.main[index] = stack_from(items and items[index] or "")
	end
	return result
end

function Inventory:get_list(name)
	local copy = {}
	for index, stack in ipairs(self[name] or {}) do
		copy[index] = stack_from(stack)
	end
	return copy
end

function Inventory:set_list(name, stacks)
	for index = 1, #(self[name] or {}) do
		self[name][index] = stack_from(stacks and stacks[index] or "")
	end
end

function Inventory:get_size(name)
	return #(self[name] or {})
end

function Inventory:get_stack(name, index)
	return stack_from((self[name] or {})[index] or "")
end

function Inventory:set_stack(name, index, stack)
	self[name][index] = stack_from(stack)
end

function Inventory:add_item(name, incoming)
	local stack = stack_from(incoming)
	if stack:is_empty() then
		return stack
	end
	for _, current in ipairs(self[name]) do
		if not current:is_empty() and current:get_name() == stack:get_name() then
			current.count = current.count + stack:get_count()
			return stack_from("")
		end
	end
	for index, current in ipairs(self[name]) do
		if current:is_empty() then
			self[name][index] = stack
			return stack_from("")
		end
	end
	return stack
end

function Inventory:room_for_item()
	return true
end

local WOOD_PICK = "mcl_tools:pick_wood"
local STONE_PICK = "mcl_tools:pick_stone"
local IRON_PICK = "mcl_tools:pick_iron"
local LOG = "test:log"
local PLANK = "test:plank"
local STICK = "test:stick"
local COBBLE = "test:cobble"
local IRON = "test:iron"
local STONE_NODE = "test:stone"
local IRON_ORE_NODE = "test:stone_with_iron"
local FURNACE_NODE = "test:furnace"
local CHEST_NODE = "test:chest"
local WORKBENCH_NODE = "test:workbench"
local BED_NODE = "test:bed"
local DOOR_NODE = "test:door"
local INVENTORY_NODE = "test:modded_inventory_machine"
local MARKER_NODE = "working_villages:building_marker"

local recipes = {
	[WOOD_PICK] = {{
		method = "normal", width = 3,
		items = {[1] = PLANK, [2] = PLANK, [3] = PLANK, [5] = STICK, [8] = STICK},
		output = WOOD_PICK,
	}},
	[STONE_PICK] = {{
		method = "normal", width = 3,
		items = {[1] = COBBLE, [2] = COBBLE, [3] = COBBLE, [5] = STICK, [8] = STICK},
		output = STONE_PICK,
	}},
	[IRON_PICK] = {{
		method = "normal", width = 3,
		items = {[1] = IRON, [2] = IRON, [3] = IRON, [5] = STICK, [8] = STICK},
		output = IRON_PICK,
	}},
	[PLANK] = {{method = "normal", width = 1, items = {[1] = LOG}, output = PLANK .. " 4"}},
	[STICK] = {{
		method = "normal", width = 1,
		items = {[1] = PLANK, [2] = PLANK}, output = STICK .. " 4",
	}},
}

local recipe_lookups = {}
local groups = {
	[WOOD_PICK] = {pickaxe = 1},
	[STONE_PICK] = {pickaxe = 1},
	[IRON_PICK] = {pickaxe = 1},
	[COBBLE] = {cobble = 1},
	[STONE_NODE] = {stone = 1, pickaxey = 1},
	[IRON_ORE_NODE] = {pickaxey = 3},
	[FURNACE_NODE] = {pickaxey = 1, furnace = 1},
	[CHEST_NODE] = {pickaxey = 1, container = 1},
	[WORKBENCH_NODE] = {pickaxey = 1, crafting_table = 1},
	[BED_NODE] = {pickaxey = 1, bed = 1},
	[DOOR_NODE] = {pickaxey = 1, door = 1},
	[INVENTORY_NODE] = {pickaxey = 1},
	[MARKER_NODE] = {pickaxey = 1},
}

local function empty_grid(size)
	local result = {}
	for index = 1, size do
		result[index] = stack_from("")
	end
	return result
end

_G.vector = {
	new = function(pos) return {x = pos.x, y = pos.y, z = pos.z} end,
	round = function(pos)
		return {x = math.floor(pos.x + 0.5), y = math.floor(pos.y + 0.5),
			z = math.floor(pos.z + 0.5)}
	end,
	add = function(left, right)
		return {x = left.x + right.x, y = left.y + right.y, z = left.z + right.z}
	end,
	subtract = function(left, right)
		return {x = left.x - right.x, y = left.y - right.y, z = left.z - right.z}
	end,
	distance = function(left, right)
		local x, y, z = left.x - right.x, left.y - right.y, left.z - right.z
		return math.sqrt(x * x + y * y + z * z)
	end,
}

local metadata_inventories = {}
local workbench_positions = {}
local nearby_objects = {}

_G.minetest = {
	registered_items = {
		[WOOD_PICK] = {}, [STONE_PICK] = {}, [IRON_PICK] = {},
		[LOG] = {}, [PLANK] = {}, [STICK] = {}, [COBBLE] = {}, [IRON] = {},
	},
	registered_nodes = {
		[STONE_NODE] = {groups = groups[STONE_NODE], drop = COBBLE},
		[IRON_ORE_NODE] = {groups = groups[IRON_ORE_NODE], drop = IRON},
		[FURNACE_NODE] = {groups = groups[FURNACE_NODE]},
		[CHEST_NODE] = {groups = groups[CHEST_NODE]},
		[WORKBENCH_NODE] = {groups = groups[WORKBENCH_NODE]},
		[BED_NODE] = {groups = groups[BED_NODE]},
		[DOOR_NODE] = {groups = groups[DOOR_NODE]},
		[INVENTORY_NODE] = {
			groups = groups[INVENTORY_NODE],
			allow_metadata_inventory_put = function() return 0 end,
		},
		[MARKER_NODE] = {groups = groups[MARKER_NODE]},
	},
	get_item_group = function(name, group)
		return groups[name] and groups[name][group] or 0
	end,
	get_node_drops = function(name)
		local def = minetest.registered_nodes[name]
		if def and type(def.drop) == "string" and def.drop ~= "" then
			return {def.drop}
		end
		return def and {name} or {}
	end,
	get_meta = function(pos)
		local key = table.concat({pos.x, pos.y, pos.z}, ",")
		return {get_inventory = function() return metadata_inventories[key] end}
	end,
	find_nodes_in_area = function()
		local result = {}
		for index, pos in ipairs(workbench_positions) do
			result[index] = {x = pos.x, y = pos.y, z = pos.z}
		end
		return result
	end,
	hash_node_position = function(pos)
		return table.concat({pos.x, pos.y, pos.z}, ":")
	end,
	luaentities = {},
	get_all_craft_recipes = function(name)
		recipe_lookups[#recipe_lookups + 1] = name
		return recipes[name]
	end,
	get_craft_result = function(input)
		local function name_at(index)
			local stack = input.items[index]
			return stack and stack:get_name() or ""
		end
		if input.width == 1 and #input.items == 1 and name_at(1) == LOG then
			return {item = stack_from(PLANK .. " 4"), replacements = {}},
				{items = empty_grid(1)}
		end
		if input.width == 1 and #input.items == 2
				and name_at(1) == PLANK and name_at(2) == PLANK then
			return {item = stack_from(STICK .. " 4"), replacements = {}},
				{items = empty_grid(2)}
		end
		if input.width == 3 and #input.items == 9
				and name_at(1) == PLANK and name_at(2) == PLANK and name_at(3) == PLANK
				and name_at(5) == STICK and name_at(8) == STICK then
			return {item = stack_from(WOOD_PICK), replacements = {}},
				{items = empty_grid(9)}
		end
		return {item = stack_from(""), replacements = {}}, {items = {}}
	end,
	get_gametime = function() return 100 end,
	get_dig_params = function()
		-- Mirrors VoxeLibre's important edge case: breaking time may exist even
		-- when mcl_autogroup later says that the useful drop is unavailable.
		return {diggable = true, time = 1}
	end,
	get_objects_inside_radius = function() return nearby_objects end,
	add_item = function()
		error("bootstrap unexpectedly dropped an item into the world")
	end,
}

local direct_node_ore_classification = true
local compat = {
	is_voxelibre = false,
	get_torch_items = function() return {floor = "test:torch"} end,
	get_item = function(name)
		local mapped = {
			["default:pick_wood"] = WOOD_PICK,
			["default:pick_stone"] = STONE_PICK,
			["default:pick_steel"] = IRON_PICK,
			["default:cobble"] = COBBLE,
		}
		return mapped[name] or name
	end,
	get_crafting_table_items = function() return {WORKBENCH_NODE} end,
	is_ore_item = function(name)
		return name == IRON or (direct_node_ore_classification and name == IRON_ORE_NODE)
	end,
	is_furnace = function(name) return name == FURNACE_NODE end,
	is_crafting_table = function(name) return name == WORKBENCH_NODE end,
	is_chest = function(name) return name == CHEST_NODE end,
	is_door = function(name) return name == DOOR_NODE end,
}

local job_util = {}
local registered_job
local storage_ready = false
local furnace_present = false
local shared_storage_pos = {x = 0, y = 1, z = 0}
_G.working_villages = {
	gameplay_mode = "survival",
	compat = compat,
	voxelibre_compat = compat,
	blueprints = {add_experience = function() end},
	require = function(name)
		assert_equal(name, "jobs/util", "unexpected miner helper request")
		return job_util
	end,
	failed_pos_test = function() return false end,
	failed_pos_record = function() end,
	get_shared_storage_pos = function()
		return storage_ready and shared_storage_pos or nil
	end,
	is_chest_pos = function(pos)
		return storage_ready and pos and pos.x == shared_storage_pos.x
			and pos.y == shared_storage_pos.y and pos.z == shared_storage_pos.z
	end,
	is_villager = function(name) return name == "test:villager" end,
	register_job = function(name, definition)
		assert_equal(name, "working_villages:job_miner", "unexpected registered job")
		registered_job = definition
	end,
}

working_villages.crafting = dofile(modpath .. "/crafting.lua")
local fallback = dofile(modpath .. "/work_fallback.lua")
local production_ensure_tool = fallback.ensure_tool
local fallback_candidates
fallback.ensure_tool = function(self, options)
	fallback_candidates = options.candidates
	return production_ensure_tool(self, options)
end
working_villages.work_fallback = fallback

dofile(modpath .. "/jobs/miner.lua")
assert(registered_job and type(registered_job.jobfunc) == "function",
	"miner job was not registered")

local inventory = Inventory:new()
local shared = Inventory:new({LOG .. " 2"})
metadata_inventories[table.concat({shared_storage_pos.x, shared_storage_pos.y,
	shared_storage_pos.z}, ",")] = shared
local villager_pos = {x = 0, y = 0, z = 0}
local villager = {
	inventory_name = "miner_bootstrap_test",
	owner_name = "owner",
	job_data = {},
	wield = stack_from(""),
	object = {get_pos = function() return vector.new(villager_pos) end},
}

function villager:get_job_name()
	return "working_villages:job_miner"
end

function villager:get_inventory()
	return inventory
end

function villager:get_wield_item_stack()
	return stack_from(self.wield)
end

function villager:add_item_to_main(stack)
	return inventory:add_item("main", stack)
end

function villager:move_main_to_wield(predicate)
	for index, stack in ipairs(inventory:get_list("main")) do
		if not stack:is_empty() and predicate(stack:get_name()) then
			local taken = stack:take_item(1)
			inventory:set_stack("main", index, stack)
			self.wield = taken
			return true
		end
	end
	return false
end

local function transfer_from_shared(predicate, wanted)
	local remaining = wanted
	for index, stack in ipairs(shared:get_list("main")) do
		while remaining > 0 and not stack:is_empty() and predicate(stack:get_name()) do
			local taken = stack:take_item(1)
			local leftover = inventory:add_item("main", taken)
			assert(leftover:is_empty(), "miner inventory overflowed during shared transfer")
			remaining = remaining - 1
		end
		shared:set_stack("main", index, stack)
		if remaining == 0 then
			break
		end
	end
	return wanted - remaining
end

function villager:take_from_shared_storage(request)
	for name, count in pairs(request or {}) do
		transfer_from_shared(function(candidate) return candidate == name end, count)
	end
end

function villager:take_from_shared_storage_by_predicate(predicate, count)
	return transfer_from_shared(predicate, count)
end

function villager:take_tool_from_shared_storage()
	return false
end

function villager:get_shared_storage_chests()
	return storage_ready and {shared_storage_pos} or {}
end

local mining_phase = false
function villager:set_timer() end
function villager:count_timer() end
function villager:timer_exceeded(key)
	return mining_phase and key == "miner:search"
end
function villager:set_displayed_action(value) self.displayed_action = value end
function villager:set_state_info(value) self.state_info = value end
function villager:announce_action() end
function villager:handle_night() end
local last_chest_data = nil
local last_chest_put = nil
function villager:handle_chest(_, put, data)
	last_chest_data = data
	last_chest_put = put
end
function villager:handle_job_pos() end
function villager:handle_obstacles() end
function villager:get_inventory_name() return self.inventory_name end

registered_job.jobfunc(villager)

local function count_item(inv, name)
	local total = 0
	for _, stack in ipairs(inv:get_list("main")) do
		if stack:get_name() == name then
			total = total + stack:get_count()
		end
	end
	return total
end

assert_equal(fallback_candidates[1], IRON_PICK,
	"normal capable-tool ranking must remain strongest-first")
assert_equal(fallback_candidates[2], STONE_PICK,
	"normal capable-tool ranking lost its stone tier")
assert_equal(fallback_candidates[3], WOOD_PICK,
	"normal capable-tool ranking lost its wood fallback")
assert_equal(recipe_lookups[1], WOOD_PICK,
	"bootstrap did not try the renewable wooden pickaxe first")
assert_equal(villager.wield:get_name(), WOOD_PICK,
	"empty miner did not equip the wooden pickaxe crafted from shared wood")
assert_equal(villager.wield:get_count(), 1, "bootstrap tool count")
assert_equal(count_item(inventory, IRON_PICK) + count_item(inventory, STONE_PICK), 0,
	"bootstrap created a stronger pickaxe without materials")
assert_equal(count_item(shared, LOG) + count_item(inventory, LOG), 0,
	"the two shared logs were not consumed exactly")
assert_equal(count_item(inventory, PLANK), 3, "remaining planks after bootstrap")
assert_equal(count_item(inventory, STICK), 2, "remaining sticks after bootstrap")

-- One log is four planks; four sticks cost two planks; one wooden pick costs
-- three planks plus two sticks.  Scale plank-equivalents by two to stay integer.
local conserved_units = count_item(inventory, PLANK) * 2
	+ count_item(inventory, STICK)
	+ villager.wield:get_count() * 8
assert_equal(conserved_units, 2 * 8,
	"wood bootstrap created or destroyed material equivalents")

print("MINER_WOOD_BOOTSTRAP_SPEC_OK")

-- Target selection and harvest-safety regression. The deterministic search
-- order deliberately presents nearer generic stone before farther iron ore.
-- A capable miner must still select ore; an under-tier VoxeLibre pick must
-- never be allowed to destroy the ore merely because get_dig_params says the
-- node is breakable.
local nearby_stone = {x = 1, y = 0, z = 0}
local exposed_ore = {x = 4, y = 0, z = 0}
local infrastructure_positions = {
	{x = -6, y = 0, z = 0, node = FURNACE_NODE},
	{x = -5, y = 0, z = 0, node = CHEST_NODE},
	{x = -4, y = 0, z = 0, node = WORKBENCH_NODE},
	{x = -3, y = 0, z = 0, node = BED_NODE},
	{x = -2, y = 0, z = 0, node = DOOR_NODE},
	{x = -1, y = 0, z = 0, node = INVENTORY_NODE},
	{x = 0, y = 0, z = 1, node = MARKER_NODE},
}
local node_at = {
	["1,0,0"] = STONE_NODE,
	["4,0,0"] = IRON_ORE_NODE,
}
for _, fixture in ipairs(infrastructure_positions) do
	node_at[table.concat({fixture.x, fixture.y, fixture.z}, ",")] = fixture.node
end
local function pos_key(pos)
	return table.concat({pos.x, pos.y, pos.z}, ",")
end

minetest.get_node = function(pos)
	return {name = node_at[pos_key(pos)] or "air"}
end
minetest.get_node_or_nil = minetest.get_node
job_util.is_protected = function() return false end
job_util.walkable_pos = function(pos)
	return minetest.get_node(pos).name ~= "air"
end
job_util.find_nearby_furnace = function()
	return furnace_present and {x = 1, y = 1, z = 1} or nil
end
job_util.find_adjacent_clear = function(pos)
	return {x = pos.x - 1, y = pos.y, z = pos.z}
end
job_util.find_ground_below = function(pos) return pos end

local search_calls = 0
local search_candidates_override = nil
job_util.search_surrounding = function(_, predicate)
	search_calls = search_calls + 1
	local candidates = search_candidates_override
	if not candidates then
		candidates = {}
		for _, fixture in ipairs(infrastructure_positions) do
			candidates[#candidates + 1] = fixture
		end
		candidates[#candidates + 1] = nearby_stone
		candidates[#candidates + 1] = exposed_ore
	end
	for _, pos in ipairs(candidates) do
		if predicate(pos) then
			return {x = pos.x, y = pos.y, z = pos.z}
		end
	end
	return nil
end

local dug_positions = {}
function villager:go_to() return true end
function villager:dig(pos)
	dug_positions[#dug_positions + 1] = pos_key(pos)
	if rawget(_G, "mcl_autogroup")
			and self.wield:get_name() == WOOD_PICK
			and pos_key(pos) == pos_key(exposed_ore) then
		error("under-tier VoxeLibre pick destroyed ore without its useful drop")
	end
	return true
end

local function clear_main()
	inventory:set_list("main", {})
end

local function run_mining_case(profile_name, wield_name, harvest_callback,
	direct_node_classification)
	clear_main()
	villager.wield = stack_from(wield_name)
	villager.job_data = {}
	dug_positions = {}
	search_calls = 0
	direct_node_ore_classification = direct_node_classification ~= false
	storage_ready = false
	furnace_present = false
	villager_pos = {x = 0, y = 0, z = 0}
	villager.pos_data = nil
	search_candidates_override = nil
	workbench_positions = {}
	minetest.luaentities = {}
	_G.mcl_autogroup = harvest_callback and {can_harvest = harvest_callback} or nil
	mining_phase = true
	registered_job.jobfunc(villager)
	mining_phase = false
	assert_equal(#dug_positions, 1, profile_name .. " mining attempt count")
	return dug_positions[1], search_calls
end

local function voxelibre_harvest(node_name, tool_name)
	if node_name == IRON_ORE_NODE then
		return tool_name == STONE_PICK or tool_name == IRON_PICK
	end
	return tool_name == WOOD_PICK or tool_name == STONE_PICK or tool_name == IRON_PICK
end

local dug, scans = run_mining_case("voxelibre weak-tool", WOOD_PICK,
	voxelibre_harvest)
assert_equal(dug, pos_key(nearby_stone),
	"VoxeLibre under-tier pick did not leave the useful ore intact")
assert_equal(scans, 2, "VoxeLibre blocked ore should require exactly two scans")
print("MINER_NO_DROP_DESTRUCTION_GUARD_OK:voxelibre")
print("MINER_INFRASTRUCTURE_GUARD_OK:furnace,chest,workbench,bed,door,inventory,marker")

dug, scans = run_mining_case("voxelibre ore-first", STONE_PICK,
	voxelibre_harvest)
assert_equal(dug, pos_key(exposed_ore),
	"VoxeLibre capable miner preferred nearer generic stone over exposed ore")
assert_equal(scans, 1, "VoxeLibre capable ore lookup added a redundant scan")
print("MINER_ORE_FIRST_OK:voxelibre")

dug, scans = run_mining_case("minetest_game ore-first", WOOD_PICK, nil, false)
assert_equal(dug, pos_key(exposed_ore),
	"MTG miner preferred nearer generic stone over exposed ore")
assert_equal(scans, 1, "MTG capable ore lookup added a redundant scan")
print("MINER_ORE_FIRST_OK:minetest_game")

-- Furnace bootstrap regression.  The physical chest, not job_data, controls
-- the decision so a restart at 4/8 cobbles resumes stone gathering and 8/8
-- immediately restores the normal ore-first policy.  Unsafe support blocks
-- are deliberately presented before the one quarry stone.
local chest_support = {x = 0, y = 0, z = 0}
local workbench_pos = {x = 3, y = 1, z = 0}
local workbench_support = {x = 3, y = 0, z = 0}
local villager_support = {x = 6, y = 0, z = 0}
local exposed_floor = {x = 7, y = 0, z = 0}
local deep_foundation = {x = 8, y = -1, z = 0}
local quarry_stand_support = {x = 8, y = 0, z = 0}
local safe_quarry_stone = {x = 9, y = 1, z = 0}
local bootstrap_ore = {x = 10, y = 1, z = 0}
for _, pos in ipairs({chest_support, workbench_support, villager_support,
	exposed_floor, deep_foundation, quarry_stand_support, safe_quarry_stone}) do
	node_at[pos_key(pos)] = STONE_NODE
end
node_at[pos_key(workbench_pos)] = WORKBENCH_NODE
node_at[pos_key(bootstrap_ore)] = IRON_ORE_NODE

local bootstrap_candidates = {
	chest_support, workbench_support, villager_support, exposed_floor,
	deep_foundation, safe_quarry_stone, bootstrap_ore,
}

local function dropped_fixture(itemstring)
	local removed = false
	local entity = {name = "__builtin:item", itemstring = itemstring}
	return {
		is_player = function() return false end,
		get_luaentity = function() return entity end,
		remove = function() removed = true end,
		was_removed = function() return removed end,
	}
end

local function set_shared_cobble(count)
	shared:set_list("main", {})
	if count > 0 then
		shared:set_stack("main", 1, stack_from({name = COBBLE, count = count}))
	end
end

local function run_furnace_bootstrap_case(label, shared_cobble, has_furnace,
	candidates, expected_digs, carried_cobble, dropped, carried_furnace)
	clear_main()
	if (carried_cobble or 0) > 0 then
		inventory:set_stack("main", 1,
			stack_from({name = COBBLE, count = carried_cobble}))
	end
	if carried_furnace then
		inventory:set_stack("main", 2, stack_from(FURNACE_NODE))
	end
	villager.wield = stack_from(STONE_PICK)
	villager.job_data = {} -- simulate a fresh activation/restart
	dug_positions = {}
	search_calls = 0
	storage_ready = true
	furnace_present = has_furnace == true
	villager_pos = {x = 0, y = 1, z = 0}
	villager.pos_data = {job_pos = {x = 0, y = 1, z = 0}}
	set_shared_cobble(shared_cobble)
	workbench_positions = {workbench_pos}
	nearby_objects = dropped or {}
	last_chest_data = nil
	last_chest_put = nil
	minetest.luaentities = {{
		name = "test:villager",
		owner_name = villager.owner_name,
		object = {get_pos = function() return {x = 6, y = 1, z = 0} end},
		pos_data = {job_pos = {x = 6, y = 1, z = 0}},
	}}
	search_candidates_override = candidates or bootstrap_candidates
	_G.mcl_autogroup = {can_harvest = voxelibre_harvest}
	mining_phase = true
	registered_job.jobfunc(villager)
	mining_phase = false
	assert_equal(#dug_positions, expected_digs == nil and 1 or expected_digs,
		label .. " mining attempt count")
	nearby_objects = {}
	return dug_positions[1], search_calls, villager.displayed_action,
		last_chest_data, last_chest_put
end

dug, scans = run_furnace_bootstrap_case("fresh 0/8", 0, false)
assert_equal(dug, pos_key(safe_quarry_stone),
	"fresh furnace bootstrap did not prefer safe cobble-producing stone")
assert_equal(scans, 1, "fresh furnace bootstrap added a redundant terrain scan")

local foreign_drop = dropped_fixture(LOG .. " 3")
local useful_drop = dropped_fixture(COBBLE)
dug, scans = run_furnace_bootstrap_case("busy-village pickup", 0, false,
	bootstrap_candidates, 1, 0, {foreign_drop, useful_drop})
assert_equal(dug, pos_key(safe_quarry_stone),
	"foreign dropped work interrupted the safe quarry target")
assert_equal(foreign_drop:was_removed(), false,
	"furnace bootstrap stole another profession's dropped resource")
assert_equal(useful_drop:was_removed(), true,
	"furnace bootstrap ignored useful dropped cobble")
assert_equal(count_item(inventory, LOG), 0,
	"foreign dropped work entered the miner cargo")
assert_equal(count_item(inventory, COBBLE), 1,
	"useful dropped cobble was not counted in miner cargo")
assert_equal(scans, 1, "busy-village bootstrap added a redundant terrain scan")

dug, scans = run_furnace_bootstrap_case("restart 4/8", 4, false)
assert_equal(dug, pos_key(safe_quarry_stone),
	"restart at 4/8 cobbles did not resume safe stone gathering")
assert_equal(scans, 1, "restart 4/8 added a redundant terrain scan")

dug, scans = run_furnace_bootstrap_case("restart 7/8", 7, false)
assert_equal(dug, pos_key(safe_quarry_stone),
	"restart at 7/8 cobbles did not gather the final stone")
assert_equal(scans, 1, "restart 7/8 added a redundant terrain scan")

dug, scans = run_furnace_bootstrap_case("restart 8/8", 8, false)
assert_equal(dug, pos_key(bootstrap_ore),
	"8/8 durable cobbles did not restore ore-first selection")
assert_equal(scans, 1, "8/8 ore-first lookup added a redundant scan")

dug, scans = run_furnace_bootstrap_case("existing furnace", 0, true)
assert_equal(dug, pos_key(bootstrap_ore),
	"an existing furnace did not disable the cobble bootstrap")
assert_equal(scans, 1, "existing-furnace ore lookup added a redundant scan")

dug, scans = run_furnace_bootstrap_case("carried furnace", 0, false,
	bootstrap_candidates, 1, 0, nil, true)
assert_equal(dug, pos_key(bootstrap_ore),
	"a carried furnace did not disable redundant cobble mining")
assert_equal(scans, 1, "carried-furnace ore lookup added a redundant scan")

local wait_action
dug, scans, wait_action = run_furnace_bootstrap_case(
	"missing safe stone", 4, false, {bootstrap_ore}, 0)
assert_equal(dug, nil,
	"furnace bootstrap fell back to ore when no safe cobble stone existed")
assert_equal(scans, 1,
	"missing safe stone unexpectedly ran the ore or generic fallback scan")
assert_equal(wait_action, "cherche la pierre du four",
	"missing safe stone did not expose a bounded bootstrap wait state")

local ready_action, ready_data, ready_put
dug, scans, ready_action, ready_data, ready_put = run_furnace_bootstrap_case(
	"ready counted delivery", 4, false, bootstrap_candidates, 0, 4)
assert_equal(dug, nil, "ready 4+4 cobbles triggered a ninth mining attempt")
assert_equal(scans, 0, "ready counted delivery performed an unnecessary terrain scan")
assert_equal(ready_action, "livre la pierre du four",
	"ready counted cargo did not enter its delivery state")
assert(ready_data and ready_data.furnace_bootstrap,
	"ready delivery lost its furnace bootstrap chest context")
assert_equal(ready_data.furnace_bootstrap.mine_count, 0,
	"ready delivery context did not count durable chest plus cargo")
assert_equal(ready_put(villager, stack_from(COBBLE), ready_data), true,
	"ready delivery did not offer its cobble to shared storage")
assert_equal(ready_put(villager, stack_from(LOG), ready_data), false,
	"ready delivery offered unrelated cargo to shared storage")

print("MINER_FURNACE_COBBLE_BOOTSTRAP_OK:restart=0,4,7,8:surface_floor=blocked:safe_destination=horizontal:foreign_pickup=ignored:counted_delivery=4+4")
