-- Lightweight harness to validate compat mappings and detection.
-- Run manually in a dev world with: dofile(minetest.get_modpath("working_villages").."/tests/compat_spec.lua").run()

local compat = working_villages.compat or working_villages.require("compat/vl")
local farming_compat = working_villages.farming_compat or working_villages.require("farming_compat")

local function assert_eq(a, b, msg)
	if a ~= b then
		error(msg .. " (got " .. tostring(a) .. ", expected " .. tostring(b) .. ")", 2)
	end
end

local function contains(values, expected)
	for _, value in ipairs(values or {}) do
		if value == expected then
			return true
		end
	end
	return false
end

local function assert_registered(values, label)
	for _, name in ipairs(values or {}) do
		assert(minetest.registered_items[name], ("%s contains unregistered item %s"):format(label, name))
	end
end

local function run()
	-- Mapping checks (default -> VoxeLibre alias when applicable)
	assert(compat.get_item("default:stone"), "mapping stone")
	assert(compat.get_item("default:torch"), "mapping torch")
	assert(compat.get_item("doors:door_wood_a"), "mapping door")
	assert(compat.get_item("beds:bed_top"), "mapping bed")
	assert(type(compat.get_food_items) == "function", "food compatibility helper is missing")
	assert(type(compat.get_chest_search_nodes) == "function", "chest search helper is missing")
	assert(type(compat.get_tool_item) == "function", "tool compatibility helper is missing")
	assert(type(compat.get_armor_items) == "function", "armor compatibility helper is missing")

	local chest_search = compat.get_chest_search_nodes()
	assert(contains(chest_search, "group:villager_chest"), "villager chest group missing from search list")
	assert(contains(chest_search, "group:chest"), "generic chest group missing from search list")
	local chest_candidates = compat.get_chest_item_candidates()
	local furnace_candidates = compat.get_furnace_item_candidates()
	local workbench_candidates = compat.get_crafting_table_item_candidates()
	assert(#chest_candidates > 0, "no registered placeable chest candidate")
	assert(#furnace_candidates > 0, "no registered furnace candidate")
	assert_registered(chest_candidates, "chest candidates")
	assert_registered(furnace_candidates, "furnace candidates")
	assert_registered(workbench_candidates, "workbench candidates")

	if compat.is_voxelibre then
		assert_eq(compat.get_item("default:book"), "mcl_books:book", "mapping book")
		assert_eq(compat.get_item("flowers:mushroom_brown"),
			"mcl_mushrooms:mushroom_brown", "mapping brown mushroom")
		assert_eq(compat.get_item("flowers:mushroom_red"),
			"mcl_mushrooms:mushroom_red", "mapping red mushroom")
		assert_eq(compat.get_item("default:ladder_wood"), "mcl_core:ladder", "mapping ladder")
		assert_eq(compat.get_item("default:hoe_iron"), "mcl_farming:hoe_iron", "mapping iron hoe")
		assert_eq(compat.get_item("default:hoe_gold"), "mcl_farming:hoe_gold", "mapping gold hoe")
		assert_eq(chest_candidates[1], "mcl_chests:chest", "VoxeLibre placeable chest")
		assert_eq(furnace_candidates[1], "mcl_furnaces:furnace", "VoxeLibre furnace")
		assert_eq(workbench_candidates[1], "mcl_crafting_table:crafting_table", "VoxeLibre workbench")
		assert_eq(compat.get_tool_item("axe", "iron"), "mcl_tools:axe_iron", "VoxeLibre iron axe")
		assert_eq(compat.get_tool_item("hoe", "iron"), "mcl_farming:hoe_iron", "VoxeLibre iron hoe")
		assert_eq(compat.get_tool_item("sword", "diamond"), "mcl_tools:sword_diamond",
			"VoxeLibre diamond sword")
		assert_eq(compat.is_tillable_dirt("mcl_core:dirt"), true,
			"VoxeLibre dirt must remain tillable")
		assert_eq(compat.is_tillable_dirt("mcl_core:dirt_with_grass"), true,
			"VoxeLibre grass dirt must remain tillable")
		assert_eq(compat.is_farmland_node("mcl_core:dirt"), false,
			"VoxeLibre raw dirt was treated as farmland")
		assert_eq(compat.is_farmland_node("mcl_core:dirt_with_grass"), false,
			"VoxeLibre grass dirt was treated as farmland")
		assert_eq(compat.is_farmland_node("mcl_farming:soil"), true,
			"VoxeLibre cultivated soil was not treated as farmland")
		assert_eq(compat.is_ore_item("mcl_raw_ores:raw_iron"), true,
			"VoxeLibre raw iron was absent from village metal stock")

		for _, crop in ipairs({"wheat", "carrot", "potato", "beetroot"}) do
			assert(farming_compat.is_plant("mcl_farming:" .. crop),
				"mature VoxeLibre " .. crop .. " was not recognized")
		end
		assert_eq(farming_compat.is_plant("mcl_farming:wheat_7"), false,
			"premature VoxeLibre wheat_7 was treated as mature")
		assert_eq(farming_compat.is_plant("mcl_farming:beetroot_7"), false,
			"nonexistent VoxeLibre beetroot_7 was treated as mature")
	end
	if compat.game_profile and compat.game_profile.is_minetest_game then
		assert(minetest.get_item_group("default:apple", "food") > 0,
			"Minetest Game apple was not normalized as edible food")
		assert_eq(minetest.get_item_group("farming:wheat", "food"), 0,
			"Minetest Game wheat was incorrectly normalized as ready food")
		assert_eq(chest_candidates[1], "default:chest", "Minetest Game placeable chest")
		assert_eq(furnace_candidates[1], "default:furnace", "Minetest Game furnace")
		assert_eq(compat.get_tool_item("axe", "iron"), "default:axe_steel", "Minetest Game steel axe")
		assert_eq(compat.get_tool_item("hoe", "iron"), "farming:hoe_steel", "Minetest Game steel hoe")
		assert_eq(compat.get_tool_item("sword", "diamond"), "default:sword_diamond",
			"Minetest Game diamond sword")
		assert_eq(compat.get_tool_item("sword", "gold"), nil,
			"Minetest Game must not invent a gold sword")
		assert_eq(compat.is_tillable_dirt("default:dirt"), true,
			"Minetest Game dirt must remain tillable")
		assert_eq(compat.is_tillable_dirt("default:dirt_with_grass"), true,
			"Minetest Game grass dirt must remain tillable")
		assert_eq(compat.is_farmland_node("default:dirt"), false,
			"Minetest Game raw dirt was treated as farmland")
		assert_eq(compat.is_farmland_node("default:dirt_with_grass"), false,
			"Minetest Game grass dirt was treated as farmland")
		assert_eq(compat.is_farmland_node("farming:soil"), true,
			"Minetest Game cultivated soil was not treated as farmland")
		assert_eq(compat.is_ore_item("default:iron_lump"), true,
			"Minetest Game iron lump was absent from village metal stock")
	end

	for _, tool_kind in ipairs({"pick", "shovel", "axe", "sword", "hoe"}) do
		local candidates = compat.get_tool_items(tool_kind, {"iron", "stone", "wood"})
		assert(#candidates == 3, "expected three base candidates for " .. tool_kind)
		assert_registered(candidates, tool_kind .. " candidates")
	end
	assert_eq(compat.get_tool_item("pickaxe", "iron"),
		compat.get_tool_item("pick", "iron"), "pickaxe group alias")
	assert_registered(compat.get_tool_items("pickaxe", {"iron", "stone", "wood"}),
		"pickaxe group candidates")

	local catalog = working_villages.blacksmith and working_villages.blacksmith.get_catalog and
		working_villages.blacksmith.get_catalog() or {}
	local catalog_by_key = {}
	for _, entry in ipairs(catalog) do
		catalog_by_key[entry.key] = entry
	end
	assert(catalog_by_key.sword_iron, "blacksmith iron sword catalog entry is missing")
	assert(catalog_by_key.hoe_iron, "blacksmith iron hoe catalog entry is missing")
	assert_eq(catalog_by_key.sword_iron.output, compat.get_tool_item("sword", "iron"),
		"blacksmith iron sword output")
	assert_eq(catalog_by_key.hoe_iron.output, compat.get_tool_item("hoe", "iron"),
		"blacksmith iron hoe output")

	-- Growth stage parsing
	assert_eq(compat.get_growth_stage("mcl_farming:wheat_3"), 3, "growth stage wheat_3")
	assert_eq(compat.get_growth_stage("farming:wheat_8"), 8, "growth stage wheat_8")
	assert_eq(compat.get_growth_stage("default:stone"), nil, "growth stage stone")

	-- Bed meta pairing
	local bed_pairs = compat.get_bed_items()
	if #bed_pairs.top > 0 then
		local meta = compat.bed_meta(bed_pairs.top[1])
		assert(meta and meta.part == "top", "bed_meta top part")
	end
	if #bed_pairs.bottom > 0 then
		local meta = compat.bed_meta(bed_pairs.bottom[1])
		assert(meta and meta.part == "bottom", "bed_meta bottom part")
	end

	-- Detection with simulated mods
	local vl_profile = compat.detect_profile({mcl_core = true})
	assert_eq(vl_profile.id, "voxelibre", "profile id voxelibre")
	assert(vl_profile.is_voxelibre == true, "profile flag voxelibre")
	local mtg_profile = compat.detect_profile({default = true})
	assert_eq(mtg_profile.id, "minetest_game", "profile id minetest_game")
	assert(mtg_profile.is_voxelibre == false, "profile flag mtg")
	assert(mtg_profile.is_minetest_game == true, "profile flag minetest_game")
	local unknown_profile = compat.detect_profile({})
	assert_eq(unknown_profile.id, "unknown", "profile id unknown")
	assert(unknown_profile.supported == false, "unknown profile must be unsupported")

	if minetest and minetest.log then
		minetest.log("action", "COMPAT_CANDIDATES_OK:" .. (compat.game_profile and compat.game_profile.id or "unknown"))
		minetest.log("action", "[working_villages] compat_spec.lua passed")
	else
		print("[working_villages] compat_spec.lua passed")
	end
end

return {
	run = run,
}
