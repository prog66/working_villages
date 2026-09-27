local source_root = minetest.settings:get("working_villages_source_root")
assert(source_root and source_root ~= "", "working_villages_source_root is required")

local function run_profile_contract()
	local profile = assert(working_villages.game_profile,
		"game profile is unavailable").id
	local compat = assert(working_villages.compat or working_villages.voxelibre_compat,
		"compatibility layer is unavailable")
	local ore_name = assert(compat.get_item("default:stone_with_iron"),
		"iron ore mapping is unavailable")
	local stone_pick = assert(compat.get_tool_item("pickaxe", "stone"),
		"stone pickaxe mapping is unavailable")
	local stone_name = assert(compat.get_item("default:stone"),
		"stone mapping is unavailable")
	local cobble_name = assert(compat.get_item("default:cobble"),
		"cobble mapping is unavailable")
	local furnace_candidates = assert(compat.get_furnace_item_candidates(),
		"furnace candidates are unavailable")
	local furnace_name = assert(furnace_candidates[1],
		"registered furnace candidate is unavailable")
	local ore_def = assert(minetest.registered_nodes[ore_name],
		"mapped iron ore is not registered: " .. ore_name)
	assert(minetest.registered_nodes[stone_name],
		"mapped stone is not registered: " .. stone_name)
	assert(minetest.registered_items[cobble_name],
		"mapped cobble is not registered: " .. cobble_name)
	assert(minetest.registered_items[furnace_name],
		"mapped furnace is not registered: " .. furnace_name)
	local direct_ore = compat.is_ore_item(ore_name)
	local declared_drop = type(ore_def.drop) == "string"
		and ItemStack(ore_def.drop):get_name() or ""
	assert(direct_ore or compat.is_ore_item(declared_drop)
			or ore_name:find(":stone_with_", 1, true),
		"mapped iron-ore node exposes no production classification signal")
	local stone_stack = ItemStack(stone_pick)
	local stone_params = minetest.get_dig_params(ore_def.groups or {},
		stone_stack:get_tool_capabilities(), stone_stack:get_wear())
	assert(stone_params and stone_params.diggable == true,
		"registered stone pickaxe cannot dig mapped iron ore")

	local useful_drop = false
	for _, drop in ipairs(minetest.get_node_drops(ore_name, stone_pick) or {}) do
		if compat.is_ore_item(ItemStack(drop):get_name()) then
			useful_drop = true
			break
		end
	end
	assert(useful_drop, "safe stone pickaxe exposes no useful iron-ore drop")

	local cobble_drop = false
	for _, drop in ipairs(minetest.get_node_drops(stone_name, stone_pick) or {}) do
		local drop_name = ItemStack(drop):get_name()
		if drop_name == cobble_name or minetest.get_item_group(drop_name, "cobble") > 0 then
			cobble_drop = true
			break
		end
	end
	assert(cobble_drop, "mapped stone does not physically drop compatible cobble")

	local furnace_recipe = false
	for _, recipe in ipairs(minetest.get_all_craft_recipes(furnace_name) or {}) do
		if recipe.method == "normal" or recipe.method == "shapeless" then
			local cobble_inputs = 0
			local unsupported = 0
			for _, raw in pairs(recipe.items or {}) do
				if raw and raw ~= "" then
					if raw == cobble_name or (type(raw) == "string"
							and raw:sub(1, 6) == "group:"
							and minetest.get_item_group(cobble_name, raw:sub(7)) > 0) then
						cobble_inputs = cobble_inputs + 1
					else
						unsupported = unsupported + 1
					end
				end
			end
			local output = ItemStack(recipe.output or "")
			if unsupported == 0 and cobble_inputs == 8
					and output:get_name() == furnace_name and output:get_count() == 1 then
				furnace_recipe = true
				break
			end
		end
	end
	assert(furnace_recipe,
		"furnace has no exact registered eight-cobble recipe")

	if profile == "voxelibre" then
		local wood_pick = assert(compat.get_tool_item("pickaxe", "wood"),
			"wooden pickaxe mapping is unavailable")
		local wood_stack = ItemStack(wood_pick)
		local wood_params = minetest.get_dig_params(ore_def.groups or {},
			wood_stack:get_tool_capabilities(), wood_stack:get_wear())
		assert(wood_params and wood_params.diggable == true,
			"VoxeLibre fixture no longer exposes the breakable-without-drop edge case")
		assert(mcl_autogroup and type(mcl_autogroup.can_harvest) == "function",
			"VoxeLibre harvest API is unavailable")
		assert(mcl_autogroup.can_harvest(ore_name, wood_pick, nil) == false,
			"wooden pick unexpectedly harvests VoxeLibre iron ore")
		assert(mcl_autogroup.can_harvest(ore_name, stone_pick, nil) == true,
			"stone pick unexpectedly cannot harvest VoxeLibre iron ore")
	end
	minetest.log("action", "MINER_ORE_PROFILE_CONTRACT_OK:" .. profile
		.. ":ore=" .. ore_name .. ":pick=" .. stone_pick)
	minetest.log("action", "MINER_FURNACE_BOOTSTRAP_PROFILE_CONTRACT_OK:" .. profile
		.. ":stone=" .. stone_name .. ":cobble=" .. cobble_name
		.. ":furnace=" .. furnace_name .. ":recipe_cobble=8")
end

local function run_furnace_crafting_contract()
	local compat = assert(working_villages.compat or working_villages.voxelibre_compat,
		"compatibility layer is unavailable")
	local crafting = assert(working_villages.crafting,
		"production crafting API is unavailable")
	local cobble_name = assert(compat.get_item("default:cobble"),
		"cobble mapping is unavailable")
	local furnace_name = assert(compat.get_furnace_item_candidates()[1],
		"registered furnace candidate is unavailable")
	local detached_name = "working_villages_furnace_contract_"
		.. tostring(working_villages.game_profile.id)
	pcall(minetest.remove_detached_inventory, detached_name)
	local inv = minetest.create_detached_inventory(detached_name, {})
	inv:set_size("main", 16)
	assert(inv:add_item("main", ItemStack(cobble_name .. " 8")):is_empty(),
		"could not seed the isolated eight-cobble inventory")

	local fake = {
		owner_name = "working_villages_furnace_contract",
		job_data = {},
		object = {get_pos = function() return {x = 0, y = 1, z = 0} end},
	}
	function fake:get_inventory() return inv end
	function fake:add_item_to_main(stack) return inv:add_item("main", stack) end
	function fake:take_from_shared_storage() return false end
	function fake:take_from_shared_storage_by_predicate() return false end
	function fake:set_displayed_action() end
	function fake:set_state_info() end

	-- This contract isolates the real registered recipe. Workstation discovery is
	-- covered by the integrated survival suite; temporarily bypassing that gate
	-- here lets the runner prove that the sparse 3x3 furnace grid itself is
	-- consumed exactly by the production recursive crafter.
	local previous_mode = working_villages.gameplay_mode
	working_villages.gameplay_mode = "creative"
	local crafted, result = crafting.ensure_any_item(fake, {furnace_name}, 1, {
		use_shared_storage = false,
		force = true,
		max_depth = 4,
	})
	working_villages.gameplay_mode = previous_mode
	assert(crafted == furnace_name,
		"production crafter failed the real furnace recipe: " .. minetest.serialize(result))
	assert(inv:contains_item("main", ItemStack(furnace_name)),
		"production crafter returned success without a furnace")
	assert(not inv:contains_item("main", ItemStack(cobble_name)),
		"production crafter did not consume exactly all eight cobbles")
	pcall(minetest.remove_detached_inventory, detached_name)
	minetest.log("action", "FURNACE_PRODUCTION_CRAFTING_CONTRACT_OK:"
		.. tostring(working_villages.game_profile.id)
		.. ":input=" .. cobble_name .. " 8:output=" .. furnace_name)
end

local function run_standalone_spec()
	local environment
	environment = setmetatable({
		_G = false,
		arg = {source_root .. "/working_villagers"},
		minetest = minetest,
		print = function(...)
			local values = {...}
			for index, value in ipairs(values) do
				values[index] = tostring(value)
			end
			local message = table.concat(values, "\t")
			_G.print(message)
			minetest.log("action", message)
		end,
	}, {
		__index = function(_, key)
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

	local spec_path = source_root
		.. "/working_villagers/tests/miner_wood_bootstrap_spec.lua"
	local chunk, load_error = loadfile(spec_path)
	assert(chunk, load_error)
	setfenv(chunk, environment)
	chunk()
	minetest.log("action", "MINER_ORE_PRIORITY_ENGINE_SPEC_OK")
end

minetest.register_on_mods_loaded(function()
	local ok, result = xpcall(function()
		run_profile_contract()
		run_furnace_crafting_contract()
		run_standalone_spec()
	end, debug.traceback)
	if not ok then
		minetest.log("error", "MINER_ORE_PRIORITY_ENGINE_SPEC_FAILED:"
			.. tostring(result))
	end
	minetest.request_shutdown(ok and "miner ore priority spec complete"
		or "miner ore priority spec failed", false, 0)
end)
