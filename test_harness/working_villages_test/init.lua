local function fail(message)
	error("[working_villages_test] " .. message, 2)
end

local function assert_true(value, message)
	if not value then
		fail(message or "expected a truthy value")
	end
end

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		fail((message or "values differ") .. ": got " .. tostring(actual)
			.. ", expected " .. tostring(expected))
	end
end

assert_equal(working_villages.release_version, "0.13.0-alpha.7",
	"runtime release version does not match the packaged alpha")
minetest.log("action", "WORKING_VILLAGES_VERSION_OK:" .. working_villages.release_version)

local function assert_near(actual, expected, tolerance, message)
	if math.abs(actual - expected) > tolerance then
		fail((message or "values are not close") .. ": got " .. tostring(actual)
			.. ", expected " .. tostring(expected))
	end
end

local inventory_callback_state = {
	deny = false,
	put_count = 0,
	take_count = 0,
}

minetest.register_node("working_villages_test:callback_container", {
	description = "working_villages callback test container",
	tiles = {"blank.png"},
	groups = {cracky = 1, villager_chest = 1},
	allow_metadata_inventory_put = function(_, listname, _, stack, player)
		assert_equal(listname, "main", "test container received a put for another list")
		assert_equal(player:get_player_name(), "runtime_inventory_owner",
			"container callback received the wrong actor")
		if inventory_callback_state.deny then
			return 0
		end
		return math.min(2, stack:get_count())
	end,
	allow_metadata_inventory_take = function(_, listname, _, stack, player)
		assert_equal(listname, "main", "test container received a take for another list")
		assert_equal(player:get_player_name(), "runtime_inventory_owner",
			"container callback received the wrong actor")
		if inventory_callback_state.deny then
			return 0
		end
		return stack:get_count()
	end,
	on_metadata_inventory_put = function(_, _, _, stack)
		inventory_callback_state.put_count = inventory_callback_state.put_count + stack:get_count()
	end,
	on_metadata_inventory_take = function(_, _, _, stack)
		inventory_callback_state.take_count = inventory_callback_state.take_count + stack:get_count()
	end,
})

assert_true(type(working_villages) == "table", "global module table is missing")
assert_true(type(working_villages.require) == "function", "local module loader is missing")

local bundled_spec_root = working_villages.modpath .. "/tests"
local external_spec_root = minetest.get_modpath("working_villages_specs")
local spec_root = external_spec_root or bundled_spec_root
local spec_probe = io.open(spec_root .. "/village_registry_spec.lua", "r")
assert_true(spec_probe ~= nil,
	"test specifications are missing; enable the external working_villages_specs test mod for a packaged runtime")
spec_probe:close()
if external_spec_root then
	minetest.log("action", "WORKING_VILLAGES_EXTERNAL_SPECS_OK")
end
local previous_arg = arg
arg = {working_villages.modpath}
local registry_spec_ok, registry_spec_error = pcall(
	dofile,
	spec_root .. "/village_registry_spec.lua"
)
arg = previous_arg
assert_true(registry_spec_ok,
	"village registry specification failed: " .. tostring(registry_spec_error))

local spawn_state = working_villages.spawn_state
assert_true(type(spawn_state) == "table", "spawn state helpers were not loaded")
assert_equal(working_villages.require("spawn_state"), spawn_state, "module cache is not stable")

local unsafe_ok = pcall(working_villages.require, "../outside")
assert_equal(unsafe_ok, false, "module loader accepted path traversal")

local state = spawn_state.create(5, "tester", {x = 4, y = 8, z = 15})
assert_equal(spawn_state.count_spawned(state), 0, "new spawn state is not empty")
assert_equal(state.completed, false, "new spawn state is already complete")

for index = 1, 4 do
	assert_true(spawn_state.mark_spawned(
		state,
		index,
		"initial-villager-" .. index,
		{x = index, y = 8, z = 15}
	), "could not mark a valid spawn slot")
end
assert_equal(spawn_state.count_spawned(state), 4, "partial spawn count is wrong")
assert_equal(state.completed, false, "partial spawn was marked complete")

local roundtrip = spawn_state.normalize(
	minetest.deserialize(minetest.serialize(state)),
	5,
	false
)
assert_equal(roundtrip.owner_name, "tester", "spawn owner did not survive serialization")
assert_equal(roundtrip.anchor_pos.z, 15, "spawn anchor did not survive serialization")
assert_equal(roundtrip.slot_ids[3], "initial-villager-3",
	"spawn identity did not survive serialization")
assert_equal(roundtrip.slot_positions[3].x, 3,
	"spawn reconciliation position did not survive serialization")
assert_equal(roundtrip.completed, false, "partial state did not survive serialization")

assert_equal(spawn_state.mark_spawned(roundtrip, 5, "initial-villager-4"), false,
	"one persistent identity was accepted in two initial slots")
assert_true(spawn_state.mark_spawned(
	roundtrip,
	5,
	"initial-villager-5",
	{x = 5, y = 8, z = 15}
), "could not mark final spawn slot")
assert_equal(roundtrip.completed, true, "complete spawn state is not complete")
assert_equal(spawn_state.release_slot(roundtrip, 3, "wrong-villager"), false,
	"a mismatched removal released an occupied initial slot")
assert_true(spawn_state.release_slot(roundtrip, 3, "initial-villager-3"),
	"the matching real removal did not release its initial slot")
assert_equal(roundtrip.completed, false, "released initial slot remained complete")
assert_true(spawn_state.mark_spawned(
	roundtrip,
	3,
	"replacement-villager-3",
	{x = 30, y = 8, z = 15}
), "replacement identity could not claim the released slot")
assert_equal(spawn_state.find_slot_by_id(roundtrip, "replacement-villager-3"), 3,
	"replacement identity is not tied to its initial slot")
assert_equal(spawn_state.available_population_slots(18, 20), 2, "population allowance is wrong")
assert_equal(spawn_state.available_population_slots(22, 20), 0, "population allowance became negative")

local legacy = spawn_state.normalize(nil, 5, true)
assert_equal(legacy.completed, true, "legacy completed marker was not migrated")
assert_equal(spawn_state.count_spawned(legacy), 5, "legacy migration did not fill all slots")

assert_true(type(working_villages.game_profile) == "table", "game profile is missing")
if minetest.get_modpath("mcl_core") then
	assert_equal(working_villages.game_profile.id, "voxelibre", "VoxeLibre profile detection failed")
	assert_equal(
		working_villages.compat.get_item("default:stone"),
		"mcl_core:stone",
		"VoxeLibre stone mapping failed"
	)
	local expected_mappings = {
		["default:book"] = "mcl_books:book",
		["default:ladder_wood"] = "mcl_core:ladder",
		["default:hoe_wood"] = "mcl_farming:hoe_wood",
		["default:hoe_stone"] = "mcl_farming:hoe_stone",
		["default:hoe_iron"] = "mcl_farming:hoe_iron",
		["default:hoe_gold"] = "mcl_farming:hoe_gold",
		["default:hoe_diamond"] = "mcl_farming:hoe_diamond",
		["flowers:mushroom_brown"] = "mcl_mushrooms:mushroom_brown",
		["flowers:mushroom_red"] = "mcl_mushrooms:mushroom_red",
	}
	for source_name, expected_name in pairs(expected_mappings) do
		assert_equal(working_villages.compat.get_item(source_name), expected_name,
			"VoxeLibre mapping failed for " .. source_name)
		assert_true(minetest.registered_items[expected_name] ~= nil,
			"mapped VoxeLibre item is not registered: " .. expected_name)
	end

	for _, crop in ipairs({"wheat", "carrot", "potato", "beetroot"}) do
		assert_true(working_villages.farming_compat.is_plant("mcl_farming:" .. crop),
			"mature VoxeLibre crop is not recognized: " .. crop)
	end
	assert_equal(working_villages.farming_compat.is_plant("mcl_farming:wheat_7"), false,
		"premature VoxeLibre wheat_7 is treated as mature")
	assert_equal(working_villages.farming_compat.is_plant("mcl_farming:beetroot_7"), false,
		"nonexistent VoxeLibre beetroot_7 is treated as mature")
	assert_true(working_villages.herbs.is_herb("mcl_mushrooms:mushroom_brown"),
		"brown VoxeLibre mushroom is not collectable")
	assert_true(working_villages.herbs.is_herb("mcl_mushrooms:mushroom_red"),
		"red VoxeLibre mushroom is not collectable")

	local hoe_outputs = {}
	for _, entry in ipairs(working_villages.blacksmith.get_catalog()) do
		if entry.key:find("^hoe_") then
			hoe_outputs[entry.output] = true
		end
	end
	for _, hoe_name in ipairs({
		"mcl_farming:hoe_wood",
		"mcl_farming:hoe_stone",
		"mcl_farming:hoe_iron",
		"mcl_farming:hoe_gold",
		"mcl_farming:hoe_diamond",
	}) do
		assert_true(hoe_outputs[hoe_name], "blacksmith catalog is missing " .. hoe_name)
	end

	local castle = working_villages.blueprints.get("castle_fortress")
	local ladder_count = 0
	for _, entry in ipairs(castle and castle.nodes or {}) do
		if entry.node and entry.node.name == "mcl_core:ladder" then
			ladder_count = ladder_count + 1
		end
	end
	assert_true(ladder_count > 0, "castle blueprint lost its converted ladder nodes")
end

-- Bootstrap wood must describe raw/plank material, never a wooden tool whose
-- item name merely happens to contain "wood". Check the real registered items
-- in both supported games so the standalone selection regression cannot hide
-- a profile-specific group assignment.
local profile_wooden_axe = working_villages.compat.get_tool_item("axe", "wood")
local profile_tree = working_villages.compat.get_item("default:tree")
assert_true(type(profile_wooden_axe) == "string"
		and minetest.registered_items[profile_wooden_axe] ~= nil,
	"current profile exposes no registered wooden axe")
assert_true(type(profile_tree) == "string" and minetest.registered_items[profile_tree] ~= nil,
	"current profile exposes no registered tree material")
assert_equal(minetest.get_item_group(profile_wooden_axe, "tree"), 0,
	"wooden axe is unexpectedly classified as tree material")
assert_equal(minetest.get_item_group(profile_wooden_axe, "wood"), 0,
	"wooden axe is unexpectedly classified as wood material")
assert_true(minetest.get_item_group(profile_tree, "tree") > 0,
	"registered tree material lacks the tree group")
minetest.log("action", "BOOTSTRAP_WOOD_PROFILE_GROUPS_OK:"
	.. working_villages.game_profile.id .. ":" .. profile_wooden_axe .. ":" .. profile_tree)

local compat_spec = dofile(spec_root .. "/compat_spec.lua")
assert_true(type(compat_spec) == "table" and type(compat_spec.run) == "function",
	"compatibility spec could not be loaded")
compat_spec.run()

local ore_smelting_spec = dofile(spec_root .. "/ore_smelting_spec.lua")
assert_true(type(ore_smelting_spec) == "table" and type(ore_smelting_spec.run) == "function",
	"ore smelting spec could not be loaded")
ore_smelting_spec.run()

assert_equal(working_villages.gameplay_mode, "survival", "test world is not in survival mode")

local timer_probe = setmetatable({
	inventory_name = "runtime_timer_probe",
	time_counters = {},
	_timer_dtime = 0.125,
}, {__index = working_villages.villager})
for _ = 1, 8 do
	timer_probe:count_timer("elapsed")
end
assert_near(timer_probe:get_timer("elapsed"), 10, 0.000001,
	"villager timers are not normalized to historical logical steps")
timer_probe:set_timer("elapsed", 0)
timer_probe:count_timer("elapsed", 0.4)
timer_probe:count_timer("elapsed", 0.6)
assert_equal(timer_probe:timer_exceeded("elapsed", 10), true,
	"explicit timer deltas do not reach the matching logical threshold")
assert_equal(timer_probe:get_timer("elapsed"), 0, "elapsed timer was not reset")
timer_probe:set_timer("all_a", 0)
timer_probe:set_timer("all_b", 1)
timer_probe:count_timers(0.25)
assert_near(timer_probe:get_timer("all_a"), 2.5, 0.000001, "count_timers ignored normalized delta")
assert_near(timer_probe:get_timer("all_b"), 3.5, 0.000001, "count_timers corrupted state")
minetest.log("action", "VILLAGER_DTIME_TIMERS_OK")
minetest.log("action", "VILLAGER_LOGICAL_TIMERS_OK")

local function run_async_suite()
	local async_ok, async_error = xpcall(function()
	local runtime_nonce = tostring(
		type(minetest.get_us_time) == "function" and minetest.get_us_time()
			or minetest.get_gametime())
	local callback_pos = {x = 940, y = 12, z = 940}
	minetest.set_node(callback_pos, {name = "working_villages_test:callback_container"})
	local callback_inventory = minetest.get_meta(callback_pos):get_inventory()
	callback_inventory:set_size("main", 2)
	callback_inventory:set_list("main", {})
	local callback_item = working_villages.compat.get_item("default:stick")
	local source_inventory = minetest.create_detached_inventory("runtime_callback_source", {})
	source_inventory:set_size("main", 2)
	source_inventory:set_stack("main", 1, ItemStack(callback_item .. " 3"))
	local destination_inventory = minetest.create_detached_inventory("runtime_callback_destination", {})
	destination_inventory:set_size("main", 2)
	local inventory_actor = {
		owner_name = "runtime_inventory_owner",
		object = {get_pos = function() return vector.new(callback_pos) end},
		get_inventory = function() return source_inventory end,
	}
	local moved_to_node = working_villages.inventory_access.put_from_inventory(
		inventory_actor, source_inventory, "main", 1, callback_pos, "main")
	assert_equal(moved_to_node, 3, "callback-aware container put lost a partial allowance")
	assert_equal(source_inventory:get_stack("main", 1):is_empty(), true,
		"accepted container items remained duplicated in source inventory")
	assert_equal(inventory_callback_state.put_count, 3,
		"put callback did not receive the exact moved count")
	local moved_from_node = working_villages.inventory_access.take_to_inventory(
		inventory_actor, callback_pos, "main", 1, destination_inventory, "main", 2)
	assert_equal(moved_from_node, 2, "callback-aware container take moved the wrong quantity")
	assert_equal(inventory_callback_state.take_count, 2,
		"take callback did not receive the exact moved count")
	inventory_callback_state.deny = true
	source_inventory:set_stack("main", 1, ItemStack(callback_item .. " 1"))
	assert_equal(working_villages.inventory_access.put_from_inventory(
		inventory_actor, source_inventory, "main", 1, callback_pos, "main"), 0,
		"denied container put still moved an item")
	assert_equal(source_inventory:get_stack("main", 1):get_count(), 1,
		"denied container put consumed its source")
	assert_equal(working_villages.inventory_access.take_to_inventory(
		inventory_actor, callback_pos, "main", 2, destination_inventory, "main", 1), 0,
		"denied container take still moved an item")
	inventory_callback_state.deny = false
	minetest.set_node(callback_pos, {name = "air"})
	minetest.log("action", "CONTAINER_CALLBACK_ACCOUNTING_OK")

local owner_allowed = working_villages.can_manage_villager({owner_name = "tester"}, "tester")
assert_equal(owner_allowed, true, "a villager owner cannot manage their villager")
local stranger_allowed = working_villages.can_manage_villager({owner_name = "tester"}, "stranger")
assert_equal(stranger_allowed, false, "a stranger can manage another player's villager")
local public_allowed = working_villages.can_manage_villager(
	{owner_name = "working_villages:self_employed"}, "stranger")
assert_equal(public_allowed, false, "self-employed villagers are public in survival defaults")

-- Initial spawn must use the same published public-self-employed setting as
-- the access layer. The historical working_villages_enable_* variant is a
-- deliberate decoy here and must have no effect.
assert_true(type(working_villages._resolve_initial_spawn_owner) == "function",
	"initial spawn owner resolver is unavailable")
local public_setting_name = "working_villages_self_employed_public"
local divergent_setting_name = "working_villages_enable_self_employed_public"
local configured_owner_setting_name = "working_villages_initial_village_owner"
local old_public_setting = minetest.settings:get(public_setting_name)
local old_divergent_setting = minetest.settings:get(divergent_setting_name)
local old_configured_owner = minetest.settings:get(configured_owner_setting_name)
minetest.settings:set(configured_owner_setting_name, "configured_initial_owner")
assert_equal(working_villages._resolve_initial_spawn_owner({
	owner_name = "joining_player",
}, {}), "configured_initial_owner",
	"joining player overrode working_villages_initial_village_owner")
assert_equal(working_villages._resolve_initial_spawn_owner({
	force = true,
	owner_name = "manual_requester",
}, {}), "manual_requester",
	"forced manual spawn did not keep its explicit owner")
minetest.settings:set(configured_owner_setting_name, "")
minetest.settings:set_bool(public_setting_name, true)
minetest.settings:set_bool(divergent_setting_name, false)
assert_equal(working_villages._resolve_initial_spawn_owner({force = true}, {}),
	"working_villages:self_employed",
	"published self-employed setting did not enable ownerless initial spawn")
minetest.settings:set_bool(public_setting_name, false)
minetest.settings:set_bool(divergent_setting_name, true)
assert_equal(working_villages._resolve_initial_spawn_owner({force = true}, {}), nil,
	"divergent working_villages_enable_* key still controls initial spawn")
local function restore_setting(name, value)
	if value ~= nil then
		minetest.settings:set(name, value)
	elseif type(minetest.settings.remove) == "function" then
		minetest.settings:remove(name)
	else
		minetest.settings:set(name, "")
	end
end
restore_setting(public_setting_name, old_public_setting)
restore_setting(divergent_setting_name, old_divergent_setting)
restore_setting(configured_owner_setting_name, old_configured_owner)
minetest.log("action", "INITIAL_SPAWN_PUBLIC_SETTING_OK")

local claim_pos = {x = 900, y = 10, z = 900}
assert_true(working_villages.village_registry.ensure("runtime_claim_b"))
assert_equal(working_villages.access.set_ally(
	"runtime_claim_b", "runtime_claim_a", false, "runtime_claim_b"), true,
	"could not reset the persisted overlap-test ally")
assert_true(working_villages.set_owner_village_claim("runtime_claim_a", claim_pos, {radius = 8}))
assert_true(working_villages.set_owner_village_claim("runtime_claim_b", claim_pos, {radius = 8}))
local overlapping_claims = working_villages.get_village_claims_at(claim_pos)
assert_equal(#overlapping_claims, 2, "overlapping village claims were not all returned")
assert_equal(overlapping_claims[1].owner_name, "runtime_claim_a",
	"overlapping village claims are not deterministic")
assert_equal(working_villages.village_claims_allow_name(claim_pos, "runtime_claim_a"), false,
	"one claim owner bypassed an overlapping foreign claim")
assert_equal(working_villages.access.set_ally(
	"runtime_claim_b", "runtime_claim_a", true, "runtime_claim_b"), true,
	"could not authorize an ally for overlapping claim test")
assert_equal(working_villages.village_claims_allow_name(claim_pos, "runtime_claim_a"), true,
	"an explicit ally was rejected by overlapping claim governance")
working_villages.clear_owner_village_claim("runtime_claim_a")
working_villages.clear_owner_village_claim("runtime_claim_b")
minetest.log("action", "VILLAGE_CLAIM_OVERLAP_OK")

assert_true(minetest.registered_items["working_villages:commanding_sceptre"] ~= nil,
	"commanding sceptre is not registered")
assert_true(#(minetest.get_all_craft_recipes("working_villages:commanding_sceptre") or {}) > 0,
	"commanding sceptre has no survival recipe")
local expected_stick = working_villages.game_profile.id == "voxelibre"
	and "mcl_core:stick" or "default:stick"
assert_equal(working_villages.compat.get_item("default:stick"), expected_stick,
	"active-game stick mapping failed")

local function assert_nodes_within(nodes, minp, maxp, label)
	assert_true(type(nodes) == "table" and #nodes > 0, label .. " returned no nodes")
	for _, entry in ipairs(nodes) do
		local pos = entry.pos
		assert_true(pos ~= nil, label .. " returned a node without a position")
		assert_true(pos.x >= minp.x and pos.x <= maxp.x
			and pos.y >= minp.y and pos.y <= maxp.y
			and pos.z >= minp.z and pos.z <= maxp.z,
			label .. " escaped its expected construction bounds")
	end
end

local layout_inventory = "runtime_layout_villager"
local layout_data = working_villages.blueprints.get_villager_data(layout_inventory)
layout_data.blueprints.garden = 1
layout_data.blueprints.farm_plot = 1
local garden_nodes = working_villages.blueprint_construction.get_construction_data(
	layout_inventory, "garden", {x = 100, y = 20, z = -50})
assert_nodes_within(garden_nodes,
	{x = 98, y = 20, z = -52}, {x = 102, y = 20, z = -48}, "garden blueprint")
local farm_nodes = working_villages.blueprint_construction.get_construction_data(
	layout_inventory, "farm_plot", {x = 100, y = 20, z = -50})
assert_nodes_within(farm_nodes,
	{x = 97, y = 20, z = -53}, {x = 103, y = 21, z = -47}, "farm plot blueprint")
working_villages.blueprints.learned[layout_inventory] = nil

local village_registry = working_villages.village_registry
assert_true(type(village_registry) == "table", "persistent village registry is missing")
local runtime_village, registry_created = village_registry.ensure("runtime_registry_owner", {
	center = {x = 31, y = 9, z = -17},
	radius = 44,
})
assert_true(runtime_village ~= nil, "could not ensure persistent runtime village")
if registry_created then
	assert(village_registry.add("runtime_registry_owner", "resources", {
		id = "wood", item = "mcl_core:wood", count = 12,
	}))
	assert(village_registry.add("runtime_registry_owner", "allies", "runtime_ally"))
	assert(village_registry.update("runtime_registry_owner", {
		danger = {active = true, level = 1},
	}))
end
runtime_village = assert(village_registry.get("runtime_registry_owner"))
assert_equal(runtime_village.id, village_registry.id_for_owner("runtime_registry_owner"),
	"runtime village ID is not stable")
assert_equal(runtime_village.center.x, 31, "runtime village center did not persist")
assert_equal(runtime_village.radius, 44, "runtime village radius did not persist")
assert_equal(runtime_village.resources.wood.count, 12, "runtime village resources did not persist")
local ally_allowed, ally_reason = village_registry.can_access("runtime_registry_owner", "runtime_ally")
assert_equal(ally_allowed, true, "runtime village ally permission did not persist")
assert_equal(ally_reason, "ally", "runtime village ally permission reason is wrong")
minetest.log("action", "VILLAGE_REGISTRY_STORAGE_OK:" .. (registry_created and "created" or "reloaded"))

-- A mixed village may contain a marker written by an old release beside a
-- marker already present in the registry.  The first bounded query must index
-- the old marker once; every later query must stay on the sparse registry path.
assert_true(type(working_villages.sync_construction_site_registry) == "function",
	"construction-site registry synchronizer is missing")
assert_true(type(working_villages._test_collect_building_site_stats) == "function"
	and type(working_villages._test_construction_site_stats_metrics) == "function",
	"construction-site registry test probes are missing")

local construction_lbm = nil
for _, definition in ipairs(minetest.registered_lbms or {}) do
	if definition.name == "working_villages:index_construction_markers_v1" then
		construction_lbm = definition
		break
	end
end
assert_true(construction_lbm ~= nil and construction_lbm.run_at_every_load == true
	and type(construction_lbm.action) == "function",
	"legacy construction-marker LBM is not registered for every mapblock load")

local construction_owner = "runtime_construction_owner_" .. runtime_nonce
local foreign_construction_owner = construction_owner .. "_foreign"
local construction_center = {x = 938, y = 12, z = 954}
local construction_radius = 2
local legacy_marker = {x = 937, y = 12, z = 954}
local indexed_marker = {x = 939, y = 12, z = 954}
local foreign_marker = {x = 938, y = 12, z = 953}
local outside_marker = {x = 941, y = 12, z = 954}
local lbm_marker = {x = 938, y = 12, z = 956}
local construction_support_node = working_villages.compat.get_item("default:stone")

local function set_construction_marker(pos, owner, marker_state, schematic)
	minetest.set_node({x = pos.x, y = pos.y - 1, z = pos.z}, {name = construction_support_node})
	minetest.set_node(pos, {name = "working_villages:building_marker", param2 = 1})
	local meta = minetest.get_meta(pos)
	meta:set_string("owner", owner)
	meta:set_string("state", marker_state)
	meta:set_string("schematic", schematic)
end

local function construction_site_entry(village, pos)
	for key, entry in pairs(village.construction_sites or {}) do
		if type(entry) == "table" and type(entry.marker) == "table" and
				vector.equals(vector.round(entry.marker), vector.round(pos)) then
			return entry, key
		end
	end
	return nil, nil
end

set_construction_marker(legacy_marker, construction_owner, "begun", "simple_hut.we")
set_construction_marker(indexed_marker, construction_owner, "built", "farm_plot")
set_construction_marker(foreign_marker, foreign_construction_owner, "built", "simple_house")
set_construction_marker(outside_marker, construction_owner, "built", "simple_house")
assert_true(working_villages.sync_construction_site_registry(indexed_marker),
	"could not seed the indexed construction-site fixture")
assert_true(working_villages.sync_construction_site_registry(foreign_marker),
	"could not seed the foreign construction-site fixture")
assert_true(working_villages.sync_construction_site_registry(outside_marker),
	"could not seed the out-of-radius construction-site fixture")

local construction_village = assert(village_registry.get(construction_owner))
local _, legacy_marker_registry_key = construction_site_entry(construction_village, legacy_marker)
local pre_migration_sites = construction_village.construction_sites or {}
if legacy_marker_registry_key then
	pre_migration_sites[legacy_marker_registry_key] = nil
end
construction_village = assert(village_registry.update(construction_owner, {
	construction_sites = pre_migration_sites,
}))
assert_equal(construction_site_entry(construction_village, legacy_marker), nil,
	"legacy fixture was indexed before the migration query")
assert_true(construction_site_entry(construction_village, indexed_marker) ~= nil,
	"indexed construction fixture is absent from the registry")

local site_metrics_before = working_villages._test_construction_site_stats_metrics()
local warmup_started = minetest.get_us_time()
local site_stats = working_villages._test_collect_building_site_stats(
	construction_center, construction_radius, construction_owner)
local warmup_us = minetest.get_us_time() - warmup_started
local site_metrics_warm = working_villages._test_construction_site_stats_metrics()
assert_equal(site_metrics_warm.legacy_scans, site_metrics_before.legacy_scans + 1,
	"mixed construction registry migration did not perform exactly one bounded scan")
assert_equal(site_stats.active_sites, 1, "legacy active construction site was lost")
assert_equal(site_stats.built_sites, 1, "indexed built construction site was lost")
assert_equal(site_stats.active_houses, 1, "legacy house classification was lost")
assert_equal(site_stats.built_houses, 0, "non-house blueprint was classified as a house")
assert_equal(site_stats.buildings.simple_house, 1, "legacy schematic alias was not normalized")
assert_equal(site_stats.built_buildings.farm_plot, 1, "indexed blueprint count is wrong")

construction_village = assert(village_registry.get(construction_owner))
assert_true(construction_site_entry(construction_village, legacy_marker) ~= nil,
	"bounded migration did not persist the legacy construction marker")

local fast_calls = 250
local fast_started = minetest.get_us_time()
local fast_stats = nil
for _ = 1, fast_calls do
	fast_stats = working_villages._test_collect_building_site_stats(
		construction_center, 50, construction_owner)
end
local fast_total_us = minetest.get_us_time() - fast_started
local site_metrics_fast = working_villages._test_construction_site_stats_metrics()
assert_equal(site_metrics_fast.legacy_scans, site_metrics_warm.legacy_scans,
	"construction-site fast path repeated the cubic legacy scan")
assert_equal(site_metrics_fast.registry_fast_paths,
	site_metrics_warm.registry_fast_paths + fast_calls,
	"construction-site queries did not remain on the registry fast path")
assert_equal(fast_stats.active_sites, 1, "fast path changed active-site counts")
assert_equal(fast_stats.built_sites, 2, "radius-50 fast path changed built-site counts")
minetest.log("action", ("CONSTRUCTION_SITE_REGISTRY_FAST_PATH_OK:" ..
	"radius=50 calls=%d warmup_us=%d total_us=%d average_us=%.2f legacy_scans=%d"):format(
	fast_calls, warmup_us, fast_total_us, fast_total_us / fast_calls,
	site_metrics_fast.legacy_scans - site_metrics_before.legacy_scans))

minetest.get_meta(legacy_marker):set_string("state", "built")
assert_true(working_villages.sync_construction_site_registry(legacy_marker),
	"construction state transition was not synchronized")
site_stats = working_villages._test_collect_building_site_stats(
	construction_center, construction_radius, construction_owner)
assert_equal(site_stats.active_sites, 0, "built transition retained an active construction site")
assert_equal(site_stats.built_sites, 2, "built transition lost a construction site")
assert_equal(site_stats.built_houses, 1, "built transition lost the house classification")

minetest.remove_node(legacy_marker)
construction_village = assert(village_registry.get(construction_owner))
assert_equal(construction_site_entry(construction_village, legacy_marker), nil,
	"destroyed construction marker remained in the registry")
site_stats = working_villages._test_collect_building_site_stats(
	construction_center, construction_radius, construction_owner)
assert_equal(site_stats.built_sites, 1, "destroyed construction marker remained in status counts")

local lbm_owner = construction_owner .. "_lbm"
set_construction_marker(lbm_marker, lbm_owner, "paused", "minimal_shelter.we")
construction_lbm.action(lbm_marker)
local lbm_village = assert(village_registry.get(lbm_owner))
assert_true(construction_site_entry(lbm_village, lbm_marker) ~= nil,
	"registered LBM did not index an old construction marker")

for _, pos in ipairs({indexed_marker, foreign_marker, outside_marker, lbm_marker}) do
	minetest.remove_node(pos)
end
for _, pos in ipairs({legacy_marker, indexed_marker, foreign_marker, outside_marker, lbm_marker}) do
	minetest.remove_node({x = pos.x, y = pos.y - 1, z = pos.z})
end
minetest.log("action", "CONSTRUCTION_SITE_REGISTRY_MIGRATION_OK")

local population = working_villages.population
assert_true(type(population) == "table", "persistent population registry is missing")
local fake_population_entity = {
	inventory_name = "runtime_test_villager",
	owner_name = "runtime_test_owner",
	product_name = "working_villages:villager_male",
}
assert_true(population.register(fake_population_entity, {x = 1, y = 2, z = 3}),
	"could not register a persistent villager")
assert_equal(population.count("runtime_test_owner"), 1,
	"persistent population count is wrong")
assert_true(population.register(fake_population_entity, {x = 4, y = 5, z = 6}),
	"could not update a persistent villager")
assert_equal(population.count("runtime_test_owner"), 1,
	"persistent population registry duplicated an identity")
assert_true(population.unregister(fake_population_entity),
	"could not unregister a persistent villager")
assert_equal(population.count("runtime_test_owner"), 0,
	"persistent population cleanup failed")

local collab = working_villages.collaborative_tasks
local old_find_nearby = working_villages.communication.find_nearby_villagers
local function fake_villager(id, job)
	local villager = {
		inventory_name = id,
		owner_name = "runtime_test_owner",
		job_data = {},
	}
	villager.object = {get_pos = function() return {x = 0, y = 0, z = 0} end}
	function villager:get_job_name() return job end
	return villager
end
local fake_builder = fake_villager("runtime_builder_" .. runtime_nonce, "runtime:builder")
local fake_supplier = fake_villager("runtime_supplier_" .. runtime_nonce, "runtime:supplier")
working_villages.communication.find_nearby_villagers = function(_, _, job, owner_name)
	assert_equal(owner_name, "runtime_test_owner", "collaboration lookup lost village ownership")
	if job == "runtime:builder" then return {fake_builder} end
	if job == "runtime:supplier" then return {fake_supplier} end
	return {}
end
assert_true(collab.register_task("runtime_harness", {
	required_jobs = {"runtime:builder", "runtime:supplier"},
	min_villagers = 2,
	radius = 10,
	timeout = 60,
}))
local collab_ok, task_id = collab.start_task("runtime_harness", fake_builder, {proof = true})
assert_equal(collab_ok, true, "could not start a collaborative task: " .. tostring(task_id))
assert_equal(collab.get(task_id).state, "active", "collaborative task is not active")
collab.restore()
assert_equal(collab.get(task_id).state, "active", "collaborative task did not survive storage restore")
assert_equal(collab.complete(task_id, {proof = true}), true,
	"could not complete a collaborative task")
assert_equal(collab.get(task_id).state, "completed", "collaborative task did not complete")
collab.cleanup((minetest.get_gametime() or 0) + 1, {terminal_retention = 0})
working_villages.communication.find_nearby_villagers = old_find_nearby

-- A resource-delivery task must stay active after a partial transfer and only
-- complete once the initiating villager has really received the full amount.
local communication = working_villages.communication
local old_delivery_find_nearby = communication.find_nearby_villagers
local old_delivery_find_by_id = communication.find_villager_by_inventory_name
local old_crafting = working_villages.crafting
local delivery_owner = "runtime_delivery_owner"
local delivery_item = working_villages.compat.get_item("default:stone")
local function delivery_villager(id, job)
	local inv = minetest.create_detached_inventory(id, {})
	inv:set_size("main", 16)
	local villager = setmetatable({
		inventory_name = id,
		owner_name = delivery_owner,
		job_data = {},
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end},
	}, {__index = working_villages.villager})
	function villager:get_job_name() return job end
	function villager:get_inventory() return inv end
	function villager:add_item_to_main(stack) return inv:add_item("main", stack) end
	function villager:ensure_shared_storage_pos() return nil end
	function villager:set_displayed_action() end
	function villager:set_state_info() end
	return villager, inv
end
local delivery_builder, delivery_builder_inv = delivery_villager(
	"runtime_delivery_builder_" .. runtime_nonce, "working_villages:job_builder")
local delivery_supplier, delivery_supplier_inv = delivery_villager(
	"runtime_delivery_supplier_" .. runtime_nonce, "working_villages:job_woodcutter")
delivery_supplier_inv:add_item("main", ItemStack(delivery_item .. " 1"))
communication.find_nearby_villagers = function(_, _, job, owner_name)
	assert_equal(owner_name, delivery_owner, "delivery collaboration crossed village ownership")
	if job == "working_villages:job_builder" then return {delivery_builder} end
	if job == "working_villages:job_woodcutter" then return {delivery_supplier} end
	return {}
end
communication.find_villager_by_inventory_name = function(inventory_name)
	if inventory_name == delivery_builder.inventory_name then return delivery_builder end
	if inventory_name == delivery_supplier.inventory_name then return delivery_supplier end
	return nil
end
working_villages.crafting = nil
local delivery_started, delivery_task_id = collab.start_task(
	"resource_delivery", delivery_builder, {
		items = {[delivery_item] = 2},
		requester_id = delivery_builder.inventory_name,
	})
assert_equal(delivery_started, true,
	"could not start resource-delivery integration task: " .. tostring(delivery_task_id))
delivery_supplier:process_resource_requests()
delivery_builder:process_resource_requests()
assert_equal(collab.get(delivery_task_id).state, "active",
	"partial resource transfer completed the collaborative task")
assert_equal(delivery_builder_inv:contains_item("main", ItemStack(delivery_item .. " 1")), true,
	"partial resource transfer did not reach the requester")
delivery_supplier_inv:add_item("main", ItemStack(delivery_item .. " 1"))
communication.send_message(delivery_builder, delivery_supplier, "help_needed", {
	items = {[delivery_item] = 1},
	requester_id = delivery_builder.inventory_name,
	task_id = delivery_task_id,
})
delivery_supplier:process_resource_requests()
delivery_builder:process_resource_requests()
assert_equal(collab.get(delivery_task_id).state, "completed",
	"full cumulative resource delivery did not complete the task")
assert_equal(delivery_builder_inv:contains_item("main", ItemStack(delivery_item .. " 2")), true,
	"requester did not receive the full collaborative delivery")
collab.cleanup((minetest.get_gametime() or 0) + 1, {terminal_retention = 0})
working_villages.crafting = old_crafting
communication.find_nearby_villagers = old_delivery_find_nearby
communication.find_villager_by_inventory_name = old_delivery_find_by_id
minetest.log("action", "COLLAB_DELIVERY_ACCOUNTING_OK")

-- A village food-support task replenishes shared stock. The requester is only
-- notified: it must not withdraw the contribution back out of that stock, and
-- task progress must equal the quantities the container actually accepted.
local food_pos = {x = 944, y = 12, z = 944}
minetest.set_node(food_pos, {name = "working_villages_test:callback_container"})
local food_chest_inv = minetest.get_meta(food_pos):get_inventory()
food_chest_inv:set_size("main", 4)
food_chest_inv:set_list("main", {})
inventory_callback_state.put_count = 0
inventory_callback_state.take_count = 0
local food_item
for item_name in pairs(minetest.registered_items) do
	if minetest.get_item_group(item_name, "food") > 0
			and (not food_item or item_name < food_item) then
		food_item = item_name
	end
end
assert_true(food_item ~= nil, "runtime game exposes no food item for stock test")

local food_owner = "runtime_inventory_owner"
local function food_villager(id, job)
	local inv = minetest.create_detached_inventory(id, {})
	inv:set_size("main", 16)
	local villager = setmetatable({
		inventory_name = id,
		owner_name = food_owner,
		job_data = {},
		object = {get_pos = function() return vector.new(food_pos) end},
	}, {__index = working_villages.villager})
	function villager:get_job_name() return job end
	function villager:get_inventory() return inv end
	function villager:add_item_to_main(stack) return inv:add_item("main", stack) end
	function villager:ensure_shared_storage_pos() return vector.new(food_pos) end
	function villager:set_displayed_action() end
	function villager:set_state_info(message) self._state_info = message end
	return villager, inv
end
local stock_farmer, stock_farmer_inv = food_villager(
	"runtime_stock_farmer_" .. runtime_nonce, "working_villages:job_farmer")
local stock_cook, stock_cook_inv = food_villager(
	"runtime_stock_cook_" .. runtime_nonce, "working_villages:job_cook")
stock_cook_inv:add_item("main", ItemStack(food_item .. " 1"))
communication.find_nearby_villagers = function(_, _, job, owner_name)
	assert_equal(owner_name, food_owner, "food collaboration crossed village ownership")
	if job == "working_villages:job_farmer" then return {stock_farmer} end
	if job == "working_villages:job_cook" then return {stock_cook} end
	return {}
end
communication.find_villager_by_inventory_name = function(inventory_name)
	if inventory_name == stock_farmer.inventory_name then return stock_farmer end
	if inventory_name == stock_cook.inventory_name then return stock_cook end
	return nil
end
local food_started, food_task_id = collab.start_task("food_support", stock_farmer, {
	resource = "food",
	count = 3,
	delivery_target = "shared_storage",
	requester_id = stock_farmer.inventory_name,
})
assert_equal(food_started, true,
	"could not start shared-stock food task: " .. tostring(food_task_id))
stock_cook:process_resource_requests()
stock_farmer:process_resource_requests()
local partial_food_record = collab.get(food_task_id)
assert_equal(partial_food_record.state, "active",
	"partial food stock deposit completed the task")
assert_equal(partial_food_record.data.delivery_progress.food, 1,
	"partial food progress does not equal the accepted deposit")
assert_equal(food_chest_inv:contains_item("main", ItemStack(food_item .. " 1")), true,
	"accepted food deposit did not remain in shared stock")
assert_equal(stock_farmer_inv:is_empty("main"), true,
	"stock notification withdrew food into the requester inventory")
assert_equal(inventory_callback_state.take_count, 0,
	"stock notification invoked a shared-container take callback")

stock_cook_inv:add_item("main", ItemStack(food_item .. " 2"))
communication.send_message(stock_farmer, stock_cook, "help_needed", {
	resource = "food",
	count = 2,
	delivery_target = "shared_storage",
	requester_id = stock_farmer.inventory_name,
	task_id = food_task_id,
})
stock_cook:process_resource_requests()
stock_farmer:process_resource_requests()
local completed_food_record = collab.get(food_task_id)
assert_equal(completed_food_record.state, "completed",
	"full food stock deposit did not complete the task")
assert_equal(completed_food_record.data.delivery_progress.food, 3,
	"completed food progress does not equal actual accepted deposits")
assert_equal(food_chest_inv:contains_item("main", ItemStack(food_item .. " 3")), true,
	"food contributions did not remain in shared stock")
assert_equal(stock_farmer_inv:is_empty("main"), true,
	"completion notification withdrew shared food into the requester")
assert_equal(inventory_callback_state.put_count, 3,
	"container callbacks did not observe the exact food deposits")
assert_equal(inventory_callback_state.take_count, 0,
	"food stock task removed items from the shared container")
collab.cleanup((minetest.get_gametime() or 0) + 1, {terminal_retention = 0})
communication.find_nearby_villagers = old_delivery_find_nearby
communication.find_villager_by_inventory_name = old_delivery_find_by_id
minetest.set_node(food_pos, {name = "air"})
minetest.log("action", "FOOD_SUPPORT_STOCK_ACCOUNTING_OK")

-- Corrupt legacy staticdata must never abort entity activation. A scalar is
-- migrated as a fresh villager; usable identity fields survive when the saved
-- inventory is absent or has the wrong type.
local migration_entity_name = "working_villages:villager_male"
local migration_entity_def = minetest.registered_entities[migration_entity_name]
assert_true(type(migration_entity_def) == "table", "runtime villager entity is not registered")
local migration_pos = {x = 950, y = 12, z = 950}
local function spawn_migration_probe(staticdata)
	local object = minetest.add_entity(migration_pos, migration_entity_name, staticdata)
	assert_true(object ~= nil, "could not spawn staticdata migration probe")
	local luaentity = object:get_luaentity()
	assert_true(luaentity ~= nil, "migration probe activation removed its entity")
	local inventory = luaentity:get_inventory()
	assert_true(inventory ~= nil, "migration probe has no detached inventory")
	assert_equal(inventory:get_size("main"), 16, "migrated inventory has the wrong main size")
	return object, luaentity, inventory
end

local function remove_migration_probe(object, luaentity)
	local inventory_name = luaentity and luaentity.inventory_name
	object:remove()
	if inventory_name and type(minetest.remove_detached_inventory) == "function" then
		minetest.remove_detached_inventory(inventory_name)
	end
end

local scalar_object, scalar_entity = spawn_migration_probe(
	minetest.serialize("corrupt legacy scalar"))
assert_equal(scalar_entity.product_name, migration_entity_name,
	"scalar staticdata did not migrate to the registered entity type")
assert_true(type(scalar_entity.manufacturing_number) == "number"
	and scalar_entity.manufacturing_number >= 0,
	"scalar staticdata did not receive a safe identity")
local migration_number = scalar_entity.manufacturing_number
remove_migration_probe(scalar_object, scalar_entity)

local missing_inventory_object, missing_inventory_entity, missing_inventory =
	spawn_migration_probe(minetest.serialize({
		product_name = migration_entity_name,
		manufacturing_number = migration_number,
		nametag = "Migration sans inventaire",
		job_data = "invalid",
		pos_data = false,
		needs = "invalid",
		memory = 7,
	}))
assert_equal(missing_inventory_entity.manufacturing_number, migration_number,
	"inventory-less migration lost its usable identity")
assert_equal(missing_inventory:is_empty("main"), true,
	"inventory-less migration did not start with an empty main list")
assert_true(type(missing_inventory_entity.job_data) == "table"
	and type(missing_inventory_entity.pos_data) == "table"
	and type(missing_inventory_entity.needs) == "table"
	and type(missing_inventory_entity.memory) == "table",
	"inventory-less migration retained non-table persistent state")
remove_migration_probe(missing_inventory_object, missing_inventory_entity)

local non_table_inventory_object, non_table_inventory_entity, non_table_inventory =
	spawn_migration_probe(minetest.serialize({
		product_name = migration_entity_name,
		manufacturing_number = migration_number,
		nametag = "Migration inventaire invalide",
		inventory = "invalid",
	}))
assert_equal(non_table_inventory:is_empty("main"), true,
	"non-table saved inventory populated the migrated main list")
remove_migration_probe(non_table_inventory_object, non_table_inventory_entity)
minetest.log("action", "STATICDATA_INVENTORY_MIGRATION_OK")

-- A rest target must be a real bed in a validated, completed house. Door/job
-- coordinates, a chest, non-house markers, and begun/paused sites are all
-- intentionally present here; none may be returned as emergency shelter.
assert_true(type(migration_entity_def.get_emergency_shelter_pos) == "function",
	"villager shelter resolver is not exposed for runtime validation")
local shelter_owner = "runtime_shelter_owner_" .. runtime_nonce
local shelter_center = {x = 944, y = 12, z = 944}
local shelter_chest = {x = 945, y = 12, z = 944}
local shelter_job = {x = 944, y = 12, z = 945}
local shelter_door = {x = 943, y = 12, z = 944}
local shelter_markers = {
	{{x = 943, y = 12, z = 943}, "begun", "simple_house", "false"},
	{{x = 945, y = 12, z = 943}, "paused", "simple_house", "false"},
	{{x = 943, y = 12, z = 945}, "built", "farm_plot", "true"},
	{{x = 945, y = 12, z = 945}, "built", "simple_house", "false"},
}
minetest.set_node(shelter_chest, {name = "working_villages_test:callback_container"})
for _, marker_data in ipairs(shelter_markers) do
	local marker_pos = marker_data[1]
	minetest.set_node(marker_pos, {name = "working_villages:building_marker"})
	local meta = minetest.get_meta(marker_pos)
	meta:set_string("owner", shelter_owner)
	meta:set_string("state", marker_data[2])
	meta:set_string("schematic", marker_data[3])
	meta:set_string("valid", marker_data[4])
end
local shelter_probe = {
	owner_name = shelter_owner,
	inventory_name = "runtime_shelter_probe_" .. runtime_nonce,
	pos_data = {
		home_pos = vector.new(shelter_door),
		storage_pos = vector.new(shelter_chest),
		job_pos = vector.new(shelter_job),
	},
	object = {get_pos = function() return vector.new(shelter_center) end},
	has_home = function() return false end,
	get_home = function() return nil end,
}
assert_equal(migration_entity_def.get_emergency_shelter_pos(shelter_probe), nil,
	"door/chest/job/unfinished or non-house target was accepted as shelter")

local assigned_bed = {x = 946, y = 12, z = 946}
shelter_probe.has_home = function() return true end
shelter_probe.get_home = function()
	return {get_bed = function() return vector.new(assigned_bed) end}
end
local resolved_assigned_bed = migration_entity_def.get_emergency_shelter_pos(shelter_probe)
assert_true(resolved_assigned_bed and vector.equals(resolved_assigned_bed, assigned_bed),
	"validated assigned-home bed was not accepted as shelter")
minetest.set_node(shelter_chest, {name = "air"})
for _, marker_data in ipairs(shelter_markers) do
	minetest.set_node(marker_data[1], {name = "air"})
end
minetest.log("action", "STRICT_COMPLETED_HOME_SHELTER_OK")

-- Failed rest navigation is terminal for the current attempt and installs a
-- measured retry delay, so the low-energy branch cannot relaunch go_to every
-- engine step.
assert_true(type(migration_entity_def.advance_rest_navigation) == "function"
	and type(migration_entity_def.rest_retry_is_waiting) == "function",
	"rest navigation hardening helpers are unavailable")
local rest_probe = {
	job_data = {resting = true, rest_pos = vector.new(assigned_bed)},
	go_to_calls = 0,
	go_to = function(self)
		self.go_to_calls = self.go_to_calls + 1
		return false, "no_path"
	end,
	set_displayed_action = function(self, action) self._displayed_action = action end,
	set_state_info = function(self, info) self._state_info = info end,
}
assert_equal(migration_entity_def.advance_rest_navigation(rest_probe, assigned_bed), false,
	"failed go_to was treated as successful rest navigation")
assert_equal(rest_probe.go_to_calls, 1, "failed rest navigation called go_to more than once")
assert_equal(rest_probe.job_data.resting, nil, "failed rest navigation kept resting active")
assert_equal(rest_probe.job_data.rest_pos, nil, "failed rest navigation kept its bad target")
assert_equal(rest_probe.job_data.rest_retry_remaining, 30,
	"failed rest navigation did not install its retry delay")
assert_equal(migration_entity_def.rest_retry_is_waiting(rest_probe, 1), true,
	"rest retry delay did not block the next attempt")
assert_equal(rest_probe.job_data.rest_retry_remaining, 29,
	"rest retry delay did not use elapsed seconds")
assert_equal(migration_entity_def.rest_retry_is_waiting(rest_probe, 29), false,
	"rest retry delay did not expire")
assert_equal(rest_probe.job_data.rest_retry_remaining, nil,
	"expired rest retry delay remained persisted")
minetest.log("action", "REST_GO_TO_FAILURE_COOLDOWN_OK")

-- Async actions are also part of the public villager API, but entity on_step
-- is entered from C and cannot yield.  The direct go_to fallback must steer one
-- step without overwriting a suspended job's path, and maintenance placement
-- must keep its real inventory accounting without yielding.
assert_equal(working_villages.coroutine_can_yield(), false,
	"mod initialization unexpectedly reports a yieldable coroutine")
local direct_ground = working_villages.compat.get_item("default:stone")
for x = 948, 956 do
	for z = 948, 952 do
		minetest.set_node({x = x, y = 11, z = z}, {name = direct_ground})
		minetest.set_node({x = x, y = 12, z = z}, {name = "air"})
		minetest.set_node({x = x, y = 13, z = z}, {name = "air"})
	end
end
local direct_place_object, direct_place_entity, direct_place_inventory =
	spawn_migration_probe("")
local preserved_path = {{x = 99, y = 12, z = 99}}
local preserved_destination = {x = 98, y = 12, z = 98}
direct_place_entity.path = preserved_path
direct_place_entity.destination = preserved_destination
local direct_destination = {x = 954, y = 12, z = 950}
local direct_ok, direct_result = pcall(
	migration_entity_def.go_to, direct_place_entity, direct_destination)
assert_true(direct_ok, "direct go_to attempted to yield across the engine callback")
assert_equal(direct_result, nil, "direct go_to reported a completed multi-step path")
local direct_state = direct_place_entity._step_navigations
	and direct_place_entity._step_navigations.engine_callback
assert_true(type(direct_state) == "table"
		and vector.equals(direct_state.requested, direct_destination),
	"direct go_to did not retain its independent pathfinding state")
local direct_velocity = direct_place_object:get_velocity()
assert_true(direct_velocity and direct_velocity.x > 0.1,
	"direct go_to did not steer toward the requested destination")
assert_true(direct_place_entity.path == preserved_path
		and direct_place_entity.destination == preserved_destination,
	"direct go_to overwrote a suspended job's navigation state")
assert_equal(direct_place_entity:cancel_go_to_step("engine_callback", true), true,
	"direct navigation state could not be cancelled")
local direct_place_item = "working_villages_test:callback_container"
local direct_place_target = vector.add(migration_pos, {x = 1, y = 0, z = 0})
minetest.set_node(direct_place_target, {name = "air"})
local direct_place_leftover = direct_place_inventory:add_item(
	"main", ItemStack(direct_place_item))
assert_true(direct_place_leftover:is_empty(),
	"could not prepare the direct maintenance placement")
local direct_place_ok, direct_place_result, direct_place_error = pcall(
	migration_entity_def.place, direct_place_entity, direct_place_item, direct_place_target)
assert_true(direct_place_ok,
	"direct maintenance placement attempted to yield across the engine callback: "
		.. tostring(direct_place_result))
assert_equal(direct_place_result, true,
	"direct maintenance placement failed: " .. tostring(direct_place_error))
assert_equal(minetest.get_node(direct_place_target).name, direct_place_item,
	"direct maintenance placement did not mutate the target node")
assert_equal(direct_place_inventory:contains_item("main", direct_place_item), false,
	"direct maintenance placement did not consume its main-inventory item")
assert_equal(direct_place_inventory:contains_item("wield_item", direct_place_item), false,
	"direct maintenance placement did not consume its wielded item")
minetest.set_node(direct_place_target, {name = "air"})
remove_migration_probe(direct_place_object, direct_place_entity)
minetest.log("action", "C_CALLBACK_ASYNC_GUARDS_OK")

-- VoxeLibre has no usable global `doors.get` object. Exercise the real wooden
-- door callbacks: the villager opens a closed door, crosses its plane, and the
-- bounded pending-door state closes only that door behind it.
if working_villages.voxelibre_compat.is_voxelibre then
	local closed_bottom = nil
	for _, candidate in ipairs(working_villages.voxelibre_compat.get_door_items()) do
		if candidate:match("_b_1$") and minetest.registered_nodes[candidate] then
			closed_bottom = candidate
			break
		end
	end
	assert_true(closed_bottom ~= nil, "no closed VoxeLibre wooden door node is registered")
	local closed_top = closed_bottom:gsub("_b_1$", "_t_1")
	assert_true(minetest.registered_nodes[closed_top] ~= nil,
		"matching VoxeLibre wooden door top is not registered")
	local door_pos = {x = 948, y = 12, z = 948}
	local door_top_pos = vector.add(door_pos, {x = 0, y = 1, z = 0})
	minetest.set_node(door_pos, {name = closed_bottom, param2 = 0})
	minetest.set_node(door_top_pos, {name = closed_top, param2 = 0})
	minetest.get_meta(door_pos):set_int("is_open", 0)
	minetest.get_meta(door_top_pos):set_int("is_open", 0)

	local door_probe_inventory = minetest.create_detached_inventory(
		"runtime_door_probe_" .. runtime_nonce, {})
	door_probe_inventory:set_size("main", 1)
	door_probe_inventory:set_size("wield_item", 1)
	local door_probe_position = vector.new({x = 947, y = 12, z = 948})
	local door_probe_object = {
		get_pos = function() return vector.new(door_probe_position) end,
		get_yaw = function() return -math.pi / 2 end,
		get_velocity = function() return {x = 0, y = 0, z = 0} end,
		set_velocity = function() end,
		set_animation = function() end,
		set_properties = function() end,
	}
	local door_probe = setmetatable({
		owner_name = "runtime_door_owner",
		inventory_name = "runtime_door_probe_" .. runtime_nonce,
		object = door_probe_object,
		time_counters = {},
	}, {__index = working_villages.villager})
	function door_probe:get_inventory() return door_probe_inventory end
	function door_probe:change_direction_randomly() end
	function door_probe:jump() end

	door_probe:handle_obstacles(false, false)
	assert_equal(minetest.get_meta(door_pos):get_int("is_open"), 1,
		"VoxeLibre door was not opened by fallback use_node")
	assert_true(type(door_probe._pending_voxelibre_doors) == "table",
		"opened VoxeLibre door was not tracked for closure")

	door_probe_position = vector.new({x = 949, y = 12, z = 948})
	local now = minetest.get_gametime()
	door_probe._last_node_use.time = now - 2
	for _, pending in pairs(door_probe._pending_voxelibre_doors) do
		pending.opened_at = now - 2
		pending.next_attempt_at = now - 1
		pending.expires_at = now + 8
	end
	door_probe:handle_obstacles(false, false)
	assert_equal(minetest.get_meta(door_pos):get_int("is_open"), 0,
		"VoxeLibre door remained open after the villager crossed it")
	assert_equal(door_probe._pending_voxelibre_doors, nil,
		"completed VoxeLibre door closure retained pending state")
	minetest.set_node(door_pos, {name = "air"})
	minetest.set_node(door_top_pos, {name = "air"})
	if type(minetest.remove_detached_inventory) == "function" then
		minetest.remove_detached_inventory(door_probe.inventory_name)
	end
	minetest.log("action", "VOXELIBRE_TRAVERSED_DOOR_CLOSE_OK")
else
	minetest.log("action", "MINETEST_GAME_DOOR_API_LOAD_OK")
end

-- Execute the standalone fake-Luanti suites inside the engine's Lua 5.1
-- runtime. Each suite gets isolated globals and the real mod globals are
-- restored even when an assertion fails.
local function run_standalone_spec(filename)
	local real_working_villages = working_villages
	local environment
	environment = setmetatable({
		_G = false,
		arg = {real_working_villages.modpath},
		minetest = minetest,
	}, {
		__index = function(_, key)
			if key == "working_villages" then
				return nil
			end
			return _G[key]
		end,
	})
	environment._G = environment
	environment.dofile = function(path)
		local child, load_error = loadfile(path)
		assert(child, load_error)
		setfenv(child, environment)
		return child()
	end
	local chunk, load_error = loadfile(
		spec_root .. "/" .. filename
	)
	assert_true(chunk ~= nil, filename .. " could not be loaded: " .. tostring(load_error))
	setfenv(chunk, environment)
	local ok, result = pcall(chunk)
	assert_true(ok, filename .. " failed: " .. tostring(result))
	minetest.log("action", "STANDALONE_SPEC_OK:" .. filename)
end

for _, filename in ipairs({
	"startup_spec.lua",
	"needs_spec.lua",
	"population_spec.lua",
	"access_spec.lua",
	"forms_access_spec.lua",
	"collaborative_tasks_spec.lua",
	"crafting_spec.lua",
	"timekeeping_spec.lua",
	"job_coroutines_spec.lua",
	"chest_cadence_spec.lua",
	"tool_fallback_spec.lua",
	"farmer_mature_priority_spec.lua",
	"crop_planner_spec.lua",
	"construction_planner_spec.lua",
	"miner_wood_bootstrap_spec.lua",
	"autonomous_bootstrap_wait_spec.lua",
	"resource_delivery_spec.lua",
	"blacksmith_builder_safety_spec.lua",
	"survival_spec.lua",
}) do
	run_standalone_spec(filename)
end

minetest.log("action", "WORKING_VILLAGES_TESTS_OK")
	end, debug.traceback)
	if not async_ok then
		minetest.log("error", "[working_villages_test] asynchronous suite failed: "
			.. tostring(async_error))
	end
	minetest.request_shutdown(
		async_ok and "working_villages runtime tests completed"
			or "working_villages runtime tests failed",
		false,
		0
	)
end

minetest.after(0, function()
	local started = false
	minetest.emerge_area(
		{x = 936, y = 0, z = 936},
		{x = 952, y = 31, z = 952},
		function(_, _, calls_remaining)
			if calls_remaining == 0 and not started then
				started = true
				-- Emerge callbacks run on the emerge worker. Return to the server
				-- thread before touching registries, inventories, or task routing.
				minetest.after(0, run_async_suite)
			end
		end
	)
end)
