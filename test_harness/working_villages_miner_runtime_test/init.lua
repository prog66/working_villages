-- Focused real-engine acceptance test for the production miner profession.
--
-- The miner starts with an empty cargo inventory. A real shared chest contains
-- exactly the registered ingredients for one stone pickaxe, but no tool. The
-- production crafting layer must withdraw those counted supplies, craft and
-- equip the pickaxe, mine one real iron-ore node through get_dig_params inside
-- the real shared-chest village claim, carry the genuine drop to the shared
-- chest and deposit it without loss or copy.

local OWNER = "working_villages_miner_runtime_test_owner"
local JOB = "working_villages:job_miner"
local ENTITY = "working_villages:villager_female"
local POLL_SECONDS = 0.05
local TIMEOUT_SECONDS = 150
local PAD_RADIUS = 16
local AREA_MIN = {x = -PAD_RADIUS - 2, y = -12, z = -PAD_RADIUS - 2}
local AREA_MAX = {x = PAD_RADIUS + 2, y = 14, z = PAD_RADIUS + 2}
local MINEABLE_MIN = {x = -PAD_RADIUS, y = -9, z = -PAD_RADIUS}
local MINEABLE_MAX = {x = PAD_RADIUS, y = 12, z = PAD_RADIUS}
local CHEST_POS = {x = -5, y = 1, z = 0}
local WORKBENCH_POS = {x = -5, y = 1, z = 3}
local FURNACE_POS = {x = -5, y = 1, z = 6}
local SPAWN_POS = {x = 0, y = 1, z = 0}
local ORE_POS = {x = 5, y = 1, z = 0}
local OTHER_CLAIM_POS = {x = 5, y = 1, z = 1}
local LATE_PROTECTED_POS = {x = 4, y = 1, z = 2}
local OUTSIDER = OWNER .. "_outsider"

local profile = working_villages.game_profile
	and working_villages.game_profile.id or "unknown"
local compat = working_villages.compat or working_villages.voxelibre_compat
local finished = false
local miner = nil
local chest_inventory = nil
local ore_name = nil
local raw_name = nil
local expected_raw_count = 0
local foundation_name = nil
local cobble_name = nil
local stick_name = nil
local pick_name = nil
local chest_node_name = nil
local furnace_name = nil
local started_at = nil
local dig_attempts = 0
local dig_origin = nil
local dig_actor_name = nil
local dig_actor_owner = nil
local dig_actor_is_player = nil
local dig_context_thread = nil
local travel_last_pos = nil
local cargo_travelled = 0
local pick_observed = false
local ore_observed = false
local deposit_observed = false
local settle_started_at = nil
local last_diagnostic = 0
local late_protection_installed = false
local late_protection_saw_claim_wrapper = false
local late_protection_calls = 0
local late_protection_last_name = nil
local ore_protection_names = {}

local function fail(message)
	error("[working_villages_miner_runtime_test] " .. tostring(message), 2)
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

local function same_pos(left, right)
	return left and right
		and minetest.hash_node_position(vector.round(left))
			== minetest.hash_node_position(vector.round(right))
end

-- This callback is registered by a mod which depends on working_villages, so
-- it runs after the production claim wrapper. It models a protection mod which
-- finalizes its own wrapper late during register_on_mods_loaded.
minetest.register_on_mods_loaded(function()
	late_protection_saw_claim_wrapper = working_villages._claim_protection_installed == true
	local previous_is_protected = minetest.is_protected
	assert(type(previous_is_protected) == "function",
		"late protection fixture found no protection function")
	minetest.is_protected = function(pos, name)
		if same_pos(pos, ORE_POS) then
			ore_protection_names[#ore_protection_names + 1] = name == nil and "<nil>" or name
		end
		if same_pos(pos, LATE_PROTECTED_POS) then
			late_protection_calls = late_protection_calls + 1
			late_protection_last_name = name
			return true
		end
		return previous_is_protected(pos, name)
	end
	late_protection_installed = true
end)

local function finish(ok, message)
	if finished then
		return
	end
	finished = true
	if not ok then
		minetest.log("error", "WORKING_VILLAGES_MINER_RUNTIME_FAILED:"
			.. profile .. ":" .. tostring(message))
	end
	minetest.request_shutdown(
		ok and "working_villages miner runtime test completed"
			or "working_villages miner runtime test failed",
		false,
		0
	)
end

local function protected_call(callback)
	if finished then
		return
	end
	local ok, err = xpcall(callback, debug.traceback)
	if not ok then
		finish(false, err)
	end
end

local function schedule(delay, callback)
	minetest.after(delay, function()
		protected_call(callback)
	end)
end

local function choose_registered_node(candidates, predicate, label)
	for _, name in ipairs(candidates) do
		if minetest.registered_nodes[name]
				and (not predicate or predicate(name)) then
			return name
		end
	end
	fail("active game exposes no suitable registered " .. label)
end

local function count_in_inventory(inventory, item_name, include_job)
	local count = 0
	if not inventory then
		return count
	end
	for list_name, list in pairs(inventory:get_lists() or {}) do
		if include_job or list_name ~= "job" then
			for _, stack in ipairs(list or {}) do
				if stack:get_name() == item_name then
					count = count + stack:get_count()
				end
			end
		end
	end
	return count
end

local function count_group_in_inventory(inventory, group)
	local count = 0
	if not inventory then
		return count
	end
	for list_name, list in pairs(inventory:get_lists() or {}) do
		if list_name ~= "job" then
			for _, stack in ipairs(list or {}) do
				if minetest.get_item_group(stack:get_name(), group) > 0 then
					count = count + stack:get_count()
				end
			end
		end
	end
	return count
end

local function count_dropped(item_name)
	local count = 0
	for _, object in ipairs(minetest.get_objects_inside_radius(SPAWN_POS, PAD_RADIUS + 4)) do
		local lua = object:get_luaentity()
		if lua and lua.name == "__builtin:item" then
			local stack = ItemStack(lua.itemstring or "")
			if stack:get_name() == item_name then
				count = count + stack:get_count()
			end
		end
	end
	return count
end

local function clear_cargo_inventory(entity)
	local inventory = entity:get_inventory()
	assert_true(inventory, "real miner detached inventory is unavailable")
	for list_name, list in pairs(inventory:get_lists() or {}) do
		for index = 1, #list do
			inventory:set_stack(list_name, index, ItemStack(""))
		end
	end
	for list_name, list in pairs(inventory:get_lists() or {}) do
		if list_name ~= "job" then
			for _, stack in ipairs(list or {}) do
				assert_true(stack:is_empty(),
					"miner did not start empty in list " .. tostring(list_name))
			end
		end
	end
end

local function find_pick_recipe()
	for _, recipe in ipairs(minetest.get_all_craft_recipes(pick_name) or {}) do
		if recipe.method == "normal" or recipe.method == "shapeless" then
			local cobble = 0
			local sticks = 0
			local unsupported = 0
			for _, raw in pairs(recipe.items or {}) do
				if raw and raw ~= "" then
					if raw == stick_name
							or (type(raw) == "string" and raw:sub(1, 6) == "group:"
								and minetest.get_item_group(stick_name, raw:sub(7)) > 0) then
						sticks = sticks + 1
					elseif raw == cobble_name
							or (type(raw) == "string" and raw:sub(1, 6) == "group:"
								and minetest.get_item_group(cobble_name, raw:sub(7)) > 0) then
						cobble = cobble + 1
					else
						unsupported = unsupported + 1
					end
				end
			end
			local output = ItemStack(recipe.output or "")
			if unsupported == 0 and cobble == 3 and sticks == 2
					and output:get_name() == pick_name and output:get_count() == 1 then
				return recipe
			end
		end
	end
	return nil
end

local function select_resources()
	assert_true(profile == "voxelibre" or profile == "minetest_game",
		"unsupported game profile " .. tostring(profile))
	foundation_name = choose_registered_node(profile == "voxelibre" and {
		"mcl_core:dirt", "mcl_core:dirt_with_grass",
	} or {
		"default:dirt", "default:dirt_with_grass",
	}, function(name)
		return minetest.get_item_group(name, "stone") == 0
			and minetest.get_item_group(name, "cracky") == 0
			and minetest.get_item_group(name, "pickaxey") == 0
	end, "non-mineable walking foundation")
	ore_name = choose_registered_node({
		compat.get_item("default:stone_with_iron"),
		"mcl_core:stone_with_iron", "default:stone_with_iron",
	}, nil, "real iron ore")
	cobble_name = profile == "voxelibre" and "mcl_core:cobble" or "default:cobble"
	stick_name = profile == "voxelibre" and "mcl_core:stick" or "default:stick"
	pick_name = profile == "voxelibre" and "mcl_tools:pick_stone" or "default:pick_stone"
	furnace_name = assert((compat.get_furnace_item_candidates() or {})[1],
		"registered furnace candidate is unavailable")
	assert_true(minetest.registered_items[cobble_name], "cobble ingredient is not registered")
	assert_true(minetest.registered_items[stick_name], "stick ingredient is not registered")
	assert_true(minetest.registered_items[pick_name], "stone pickaxe is not registered")
	assert_true(minetest.registered_nodes[furnace_name],
		"furnace fixture is not registered: " .. furnace_name)
	assert_true(find_pick_recipe(), "stone pickaxe has no exact registered 3 cobble + 2 stick recipe")

	local drops = minetest.get_node_drops(ore_name, pick_name) or {}
	for _, value in ipairs(drops) do
		local stack = ItemStack(value)
		if compat.is_ore_item(stack:get_name()) then
			if raw_name and raw_name ~= stack:get_name() then
				fail("selected ore has multiple metal drop types")
			end
			raw_name = stack:get_name()
			expected_raw_count = expected_raw_count + stack:get_count()
		end
	end
	assert_true(raw_name and raw_name ~= "", "real iron ore exposes no recognized metal drop")
	assert_equal(expected_raw_count, 1, "iron ore drop must be deterministic for conservation proof")

	local ore_def = minetest.registered_nodes[ore_name]
	local params = minetest.get_dig_params(
		ore_def.groups or {}, ItemStack(pick_name):get_tool_capabilities(), 0)
	assert_true(params and params.diggable == true,
		"registered stone pickaxe cannot dig the selected iron ore through get_dig_params")
	minetest.log("action", "MINER_RESOURCE_CONTRACT_OK:" .. profile
		.. ":ore=" .. ore_name .. ":drop=" .. raw_name
		.. ":pick=" .. pick_name .. ":dig_time=" .. tostring(params.time))
end

local function setup_pad()
	minetest.load_area(AREA_MIN, AREA_MAX)
	for x = -PAD_RADIUS, PAD_RADIUS do
		for z = -PAD_RADIUS, PAD_RADIUS do
			-- The miner scans ten nodes vertically. Replace the whole reachable
			-- underground search band with non-pickaxe ground so the single exposed
			-- ore is the only production target, independent of generated terrain.
			for y = -9, 0 do
				minetest.set_node({x = x, y = y, z = z}, {name = foundation_name})
			end
			for y = 1, 12 do
				minetest.set_node({x = x, y = y, z = z}, {name = "air"})
			end
		end
	end
	minetest.set_node(ORE_POS, {name = ore_name})
	assert_equal(minetest.get_node(ORE_POS).name, ore_name, "ore fixture placement failed")
	assert_equal(#minetest.find_nodes_in_area(MINEABLE_MIN, MINEABLE_MAX, {ore_name}), 1,
		"test arena must expose exactly one iron ore node")
	if minetest.forceload_block then
		for x = -16, 16, 16 do
			for z = -16, 16, 16 do
				local pos = {x = x, y = 0, z = z}
				assert_true(minetest.forceload_block(pos, true),
					"could not forceload miner arena mapblock at " .. minetest.pos_to_string(pos, 0))
			end
		end
	end
end

local function setup_real_chest()
	chest_node_name = profile == "voxelibre"
		and "mcl_chests:chest_small" or "default:chest"
	local def = minetest.registered_nodes[chest_node_name]
	assert_true(def, "real chest node is not registered: " .. chest_node_name)
	minetest.set_node(CHEST_POS, {name = chest_node_name})
	if type(def.on_construct) == "function" then
		def.on_construct(CHEST_POS)
	end
	chest_node_name = minetest.get_node(CHEST_POS).name
	assert_true(working_villages.is_chest_pos(CHEST_POS),
		"constructed active-game chest is not a usable village chest: " .. chest_node_name)
	chest_inventory = minetest.get_meta(CHEST_POS):get_inventory()
	assert_true(chest_inventory and chest_inventory:get_size("main") >= 5,
		"real chest main inventory was not initialized")
	for index = 1, chest_inventory:get_size("main") do
		chest_inventory:set_stack("main", index, ItemStack(""))
	end
	chest_inventory:set_stack("main", 1, ItemStack(cobble_name .. " 3"))
	chest_inventory:set_stack("main", 2, ItemStack(stick_name .. " 2"))
	assert_equal(count_in_inventory(chest_inventory, cobble_name, true), 3,
		"initial cobble fixture count is wrong")
	assert_equal(count_in_inventory(chest_inventory, stick_name, true), 2,
		"initial stick fixture count is wrong")
	assert_equal(count_group_in_inventory(chest_inventory, "pickaxe"), 0,
		"initial chest illegally contains a pickaxe")

	if profile == "voxelibre" then
		local workbench_name = "mcl_crafting_table:crafting_table"
		assert_true(minetest.registered_nodes[workbench_name],
			"VoxeLibre crafting table is not registered")
		minetest.set_node(WORKBENCH_POS, {name = workbench_name})
		local workstation_def = minetest.registered_nodes[workbench_name]
		if workstation_def and type(workstation_def.on_construct) == "function" then
			workstation_def.on_construct(WORKBENCH_POS)
		end
		assert_true(compat.is_crafting_table(minetest.get_node(WORKBENCH_POS).name),
			"real VoxeLibre crafting table fixture was not recognized")
	end
	minetest.set_node(FURNACE_POS, {name = furnace_name})
	local furnace_def = minetest.registered_nodes[furnace_name]
	if furnace_def and type(furnace_def.on_construct) == "function" then
		furnace_def.on_construct(FURNACE_POS)
	end
	assert_true(compat.is_furnace(minetest.get_node(FURNACE_POS).name),
		"focused ore fixture furnace was not recognized")
	minetest.log("action", "MINER_INITIAL_RESOURCES_OK:" .. profile
		.. ":cobble=3:sticks=2:pickaxes=0:workbench="
		.. tostring(profile == "voxelibre" and 1 or 0)
		.. ":furnace=" .. furnace_name)
end

local function verify_claim_context_contracts()
	local with_context = working_villages.with_npc_claim_protection_context
	local context_depth = working_villages._protection_context_depth
	assert_true(type(with_context) == "function", "claim context API is unavailable")
	assert_true(type(context_depth) == "function", "claim context diagnostic is unavailable")
	assert_equal(context_depth(), 0, "main protection context was not initially empty")

	ore_protection_names = {}
	local one_shot_ok, first_check, second_check = with_context(OWNER, ORE_POS, function()
		assert_equal(context_depth(), 1, "claim context was not pushed")
		assert_true(minetest.is_protected(OTHER_CLAIM_POS, ""),
			"claim identity escaped its exact node position")
		return minetest.is_protected(ORE_POS, ""),
			minetest.is_protected(ORE_POS, "")
	end)
	assert_true(one_shot_ok, "one-shot claim context failed: " .. tostring(first_check))
	assert_equal(first_check, false, "owner claim identity did not authorize its first check")
	assert_equal(second_check, true, "owner claim identity was reusable after its first check")
	assert_equal(context_depth(), 0, "successful claim context leaked on the main thread")
	assert_true(#ore_protection_names >= 2,
		"late protection wrapper did not observe the claim checks")
	for _, observed_name in ipairs(ore_protection_names) do
		assert_equal(observed_name, "",
			"third-party protection received the claim owner instead of anonymity")
	end
	assert_true(minetest.is_protected(ORE_POS, ""),
		"anonymous claim access remained authorized after successful restoration")

	local no_check_ok, no_check_value = with_context(OWNER, ORE_POS, function()
		assert_equal(context_depth(), 1, "unconsumed success frame is missing")
		return "success_sentinel"
	end)
	assert_true(no_check_ok, "unconsumed success context failed: " .. tostring(no_check_value))
	assert_equal(no_check_value, "success_sentinel", "success context lost its return value")
	assert_equal(context_depth(), 0, "unconsumed success context was not removed")
	assert_true(minetest.is_protected(ORE_POS, ""),
		"unconsumed success context leaked owner authorization")

	local nested_ok, nested_result = with_context(OWNER, ORE_POS, function()
		assert_equal(context_depth(), 1, "outer success sentinel was not installed")
		local inner_ok, inner_value = with_context(OUTSIDER, ORE_POS, function()
			assert_equal(context_depth(), 2, "nested success frame was not stacked")
			return "inner_success_sentinel"
		end)
		assert_true(inner_ok, "nested success context failed: " .. tostring(inner_value))
		assert_equal(inner_value, "inner_success_sentinel", "nested success value changed")
		assert_equal(context_depth(), 1, "nested success did not restore the outer frame")
		return minetest.is_protected(ORE_POS, "")
	end)
	assert_true(nested_ok, "outer success context failed: " .. tostring(nested_result))
	assert_equal(nested_result, false, "nested success did not restore the owner sentinel")
	assert_equal(context_depth(), 0, "nested success left a protection frame")

	local error_marker = "expected_nested_claim_context_error"
	local outer_error_ok, outer_error_result = with_context(OWNER, ORE_POS, function()
		assert_equal(context_depth(), 1, "outer error sentinel was not installed")
		local inner_ok, inner_error = with_context(OUTSIDER, ORE_POS, function()
			assert_equal(context_depth(), 2, "nested error frame was not stacked")
			error(error_marker, 0)
		end)
		assert_equal(inner_ok, false, "nested callback error escaped its protected call")
		assert_true(tostring(inner_error):find(error_marker, 1, true) ~= nil,
			"nested callback returned the wrong error: " .. tostring(inner_error))
		assert_equal(context_depth(), 1, "nested error did not restore the outer sentinel")
		return minetest.is_protected(ORE_POS, "")
	end)
	assert_true(outer_error_ok, "outer error sentinel failed: " .. tostring(outer_error_result))
	assert_equal(outer_error_result, false, "nested error lost the restored owner sentinel")
	assert_equal(context_depth(), 0, "error restoration left a protection frame")
	assert_true(minetest.is_protected(ORE_POS, ""),
		"error restoration leaked owner authorization")

	local function make_interleaved_probe(label, owner_name)
		return coroutine.create(function()
			local call_ok, protected = with_context(owner_name, ORE_POS, function()
				assert_equal(context_depth(), 1, label .. " frame was not coroutine-local")
				coroutine.yield(label .. "_ready")
				assert_equal(context_depth(), 1, label .. " frame changed while suspended")
				return minetest.is_protected(ORE_POS, "")
			end)
			assert_true(call_ok, label .. " context failed: " .. tostring(protected))
			assert_equal(context_depth(), 0, label .. " context was not restored")
			return protected
		end)
	end

	local owner_probe = make_interleaved_probe("owner", OWNER)
	local outsider_probe = make_interleaved_probe("outsider", OUTSIDER)
	local owner_started, owner_marker = coroutine.resume(owner_probe)
	assert_true(owner_started, "owner interleaving probe failed to start: " .. tostring(owner_marker))
	assert_equal(owner_marker, "owner_ready", "owner interleaving marker changed")
	local outsider_started, outsider_marker = coroutine.resume(outsider_probe)
	assert_true(outsider_started,
		"outsider interleaving probe failed to start: " .. tostring(outsider_marker))
	assert_equal(outsider_marker, "outsider_ready", "outsider interleaving marker changed")
	assert_equal(context_depth(), 0, "suspended coroutine context leaked onto the main thread")

	local owner_finished, owner_protected = coroutine.resume(owner_probe)
	assert_true(owner_finished, "owner interleaving probe failed: " .. tostring(owner_protected))
	assert_equal(owner_protected, false, "owner coroutine received the outsider context")
	local outsider_finished, outsider_protected = coroutine.resume(outsider_probe)
	assert_true(outsider_finished,
		"outsider interleaving probe failed: " .. tostring(outsider_protected))
	assert_equal(outsider_protected, true, "outsider coroutine received the owner context")
	assert_equal(coroutine.status(owner_probe), "dead", "owner probe did not finish")
	assert_equal(coroutine.status(outsider_probe), "dead", "outsider probe did not finish")
	assert_equal(context_depth(), 0, "interleaved contexts leaked after completion")
	minetest.log("action", "MINER_CLAIM_CONTEXT_ISOLATION_OK:" .. profile
		.. ":one_shot=true:nested=true:error=true:interleaved=true")
end

local function verify_late_external_protection()
	assert_true(late_protection_installed, "late protection wrapper was not installed")
	assert_true(late_protection_saw_claim_wrapper,
		"late protection fixture did not install after the village claim wrapper")
	assert_true(not working_villages.is_externally_protected(ORE_POS, ""),
		"external-only check reapplied the working_villages claim")
	assert_true(working_villages.is_externally_protected(LATE_PROTECTED_POS, ""),
		"late third-party protection wrapper was bypassed")
	assert_true(late_protection_calls >= 1,
		"late third-party protection wrapper was not called")
	assert_equal(late_protection_last_name, "",
		"late third-party protection received a non-anonymous actor")
	assert_equal(working_villages._protection_context_depth(), 0,
		"external-only context was not restored")

	local before = minetest.get_node(LATE_PROTECTED_POS)
	local dug = miner:dig(LATE_PROTECTED_POS, false)
	assert_equal(dug, false, "villager dig bypassed late third-party protection")
	local after = minetest.get_node(LATE_PROTECTED_POS)
	assert_equal(after.name, before.name, "blocked late-protected node changed")
	assert_equal(after.param1, before.param1, "blocked late-protected node param1 changed")
	assert_equal(after.param2, before.param2, "blocked late-protected node param2 changed")
	assert_equal(working_villages._protection_context_depth(), 0,
		"blocked external protection check leaked its context")
	minetest.log("action", "MINER_LATE_EXTERNAL_PROTECTION_OK:" .. profile
		.. ":anonymous=true:blocked=true")
end

local function create_miner()
	local object = minetest.add_entity(SPAWN_POS, ENTITY)
	assert_true(object, "could not create real miner entity")
	miner = object:get_luaentity()
	assert_true(miner, "created miner has no Lua entity state")
	clear_cargo_inventory(miner)
	miner.owner_name = OWNER
	miner.nametag = "Counted runtime miner"
	object:set_nametag_attributes({text = miner.nametag})
	working_villages.needs.set(miner, "hunger", 100)
	working_villages.needs.set(miner, "energy", 100)
	miner.pos_data = miner.pos_data or {}
	miner.pos_data.job_pos = vector.new(SPAWN_POS)
	miner.job_data = miner.job_data or {}
	miner.job_data.in_work = true
	-- Keep this focused profession regression independent of the village-wide
	-- role-rotation timer while still running the ordinary production on_step.
	miner.job_data.auto_job_cooldown_until = os.time() + 3600

	miner._last_placed_node = {
		pos = vector.round(CHEST_POS),
		node_name = minetest.get_node(CHEST_POS).name,
		at_us = minetest.get_us_time(),
	}
	assert_true(working_villages.set_shared_storage_pos(CHEST_POS, OWNER, miner),
		"production API rejected the real shared chest registration")
	assert_true(same_pos(working_villages.get_shared_storage_pos(OWNER), CHEST_POS),
		"production API did not retain the shared chest position")
	local claim = working_villages.get_owner_village_claim(OWNER)
	assert_true(claim and same_pos(claim.center, CHEST_POS),
		"shared chest did not create the production village claim")
	assert_true(vector.distance(claim.center, ORE_POS) <= claim.radius,
		"real ore fixture is unexpectedly outside the village claim")
	assert_true(minetest.is_protected(ORE_POS, ""),
		"anonymous actors should remain blocked by the village claim")
	assert_true(not minetest.is_protected(ORE_POS, OWNER),
		"the village owner should be allowed to mine inside the claim")
	minetest.log("action", "MINER_VILLAGE_CLAIM_GATE_OK:" .. profile
		.. ":anonymous=blocked:owner=allowed")
	verify_claim_context_contracts()
	verify_late_external_protection()
	ore_protection_names = {}

	local changed, reason = miner:change_job(JOB)
	assert_true(changed, "could not assign miner profession: " .. tostring(reason))
	assert_equal(miner.owner_name, OWNER,
		"assigning the miner profession cleared the configured owner")
	miner.job_data.in_work = true
	miner.job_data.auto_job_cooldown_until = os.time() + 3600
	assert_equal(miner:get_job_name(), JOB, "real entity did not retain miner profession")
	assert_equal(count_group_in_inventory(miner:get_inventory(), "pickaxe"), 0,
		"new miner unexpectedly owns a pickaxe")
	assert_equal(count_in_inventory(miner:get_inventory(), cobble_name, false), 0,
		"new miner unexpectedly owns cobble")
	assert_equal(count_in_inventory(miner:get_inventory(), stick_name, false), 0,
		"new miner unexpectedly owns sticks")
	minetest.log("action", "MINER_ZERO_INVENTORY_OK:" .. profile
		.. ":entity=" .. tostring(miner.inventory_name))
end

local original_node_dig = minetest.node_dig
minetest.node_dig = function(pos, node, digger)
	local observed_ore = same_pos(pos, ORE_POS) and node and node.name == ore_name
	if observed_ore then
		dig_attempts = dig_attempts + 1
		dig_context_thread = coroutine.running()
		assert_true(type(dig_context_thread) == "thread",
			"production dig did not run in its job coroutine")
		assert_equal(working_villages._protection_context_depth(dig_context_thread), 1,
			"production dig entered without exactly one claim context frame")
		local actor_ok, actor_value = pcall(function()
			return digger and digger.get_player_name and digger:get_player_name() or nil
		end)
		dig_actor_name = actor_ok and actor_value or ("actor_error:" .. tostring(actor_value))
		dig_actor_owner = digger and digger._working_villages_owner_name or nil
		local player_ok, player_value = pcall(function()
			if digger and digger.is_player then
				return digger:is_player()
			end
			return nil
		end)
		dig_actor_is_player = player_ok and player_value or nil
		minetest.log("action", "MINER_DIG_ACTOR_OBSERVED:" .. profile
			.. ":callback_name=" .. tostring(dig_actor_name)
			.. ":owner=" .. tostring(dig_actor_owner)
			.. ":is_player=" .. tostring(dig_actor_is_player))
		local stack = digger:get_wielded_item()
		assert_equal(stack:get_name(), pick_name,
			"iron ore was dug with an unexpected wielded item")
		local params = minetest.get_dig_params(
			(minetest.registered_nodes[node.name] or {}).groups or {},
			stack:get_tool_capabilities(), stack:get_wear())
		assert_true(params and params.diggable == true,
			"production ore attempt bypassed get_dig_params capability")
		dig_origin = vector.new(miner.object:get_pos())
		travel_last_pos = vector.new(dig_origin)
		minetest.log("action", "MINER_GET_DIG_PARAMS_OK:" .. profile
			.. ":tool=" .. stack:get_name() .. ":ore=" .. node.name
			.. ":wear=" .. tostring(stack:get_wear()))
	end
	local dug = original_node_dig(pos, node, digger)
	if observed_ore then
		assert_equal(working_villages._protection_context_depth(dig_context_thread), 1,
			"production dig corrupted its context before scoped restoration")
	end
	return dug
end

local function carried_count(item_name)
	return count_in_inventory(miner and miner:get_inventory() or nil, item_name, false)
end

local function global_raw_count()
	return count_in_inventory(chest_inventory, raw_name, true)
		+ carried_count(raw_name) + count_dropped(raw_name)
end

local function verify_crafted_pick()
	local wield = miner:get_wield_item_stack()
	if wield:get_name() ~= pick_name then
		return false
	end
	assert_equal(count_group_in_inventory(miner:get_inventory(), "pickaxe"), 1,
		"crafted pickaxe count is not exactly one")
	assert_equal(count_group_in_inventory(chest_inventory, "pickaxe"), 0,
		"pickaxe appeared in the shared chest instead of being equipped")
	assert_equal(count_in_inventory(chest_inventory, cobble_name, true), 0,
		"stone pickaxe did not consume exactly three chest cobbles")
	assert_equal(count_in_inventory(chest_inventory, stick_name, true), 0,
		"stone pickaxe did not consume exactly two chest sticks")
	assert_equal(carried_count(cobble_name), 0,
		"unused cobble remained on the miner after exact crafting")
	assert_equal(carried_count(stick_name), 0,
		"unused sticks remained on the miner after exact crafting")
	assert_equal(count_dropped(cobble_name), 0, "crafting dropped cobble into the world")
	assert_equal(count_dropped(stick_name), 0, "crafting dropped sticks into the world")
	local params = minetest.get_dig_params(
		minetest.registered_nodes[ore_name].groups or {},
		wield:get_tool_capabilities(), wield:get_wear())
	assert_true(params and params.diggable == true,
		"equipped crafted pickaxe is not capable of the real ore")
	minetest.log("action", "MINER_PICK_CRAFTED_OK:" .. profile
		.. ":tool=" .. pick_name .. ":cobble_consumed=3:sticks_consumed=2")
	return true
end

local function poll()
	assert_true(miner and miner.object and miner.object:get_pos(),
		"real miner became unavailable during the scenario")
	assert_equal(miner:get_job_name(), JOB,
		"real miner changed profession during focused validation")
	local error_state = miner.job_data and miner.job_data.job_error_state
	assert_true(not (error_state and error_state.exhausted),
		"real miner profession exhausted its coroutine retries: "
			.. minetest.serialize(error_state))

	if not pick_observed and miner:get_wield_item_stack():get_name() == pick_name then
		pick_observed = verify_crafted_pick()
	end

	if dig_origin then
		local current = miner.object:get_pos()
		if travel_last_pos then
			cargo_travelled = cargo_travelled + vector.distance(travel_last_pos, current)
		end
		travel_last_pos = vector.new(current)
	end

	if minetest.get_node(ORE_POS).name ~= ore_name and not ore_observed then
		assert_true(pick_observed, "iron ore disappeared before the pickaxe craft was observed")
		assert_equal(dig_attempts, 1, "real iron ore was attempted more than once")
		assert_equal(dig_actor_name, "",
			"production dig exposed an offline owner name to player-only callbacks")
		assert_equal(dig_actor_owner, OWNER,
			"production dig lost its private owner marker")
		assert_true(dig_actor_is_player == true,
			"production dig actor no longer satisfies the player callback contract")
		assert_true(type(dig_context_thread) == "thread",
			"production dig coroutine was not observed")
		assert_equal(working_villages._protection_context_depth(dig_context_thread), 0,
			"successful production dig retained a protection context")
		assert_true(#ore_protection_names >= 1,
			"third-party wrapper did not observe production ore protection checks")
		for _, observed_name in ipairs(ore_protection_names) do
			assert_equal(observed_name, "",
				"production ore protection exposed the owner to a third-party wrapper")
		end
		assert_true(minetest.is_protected(ORE_POS, ""),
			"successful production dig leaked anonymous claim authorization")
		assert_equal(#minetest.find_nodes_in_area(MINEABLE_MIN, MINEABLE_MAX, {ore_name}), 0,
			"iron ore source count did not decrease exactly from one to zero")
		assert_equal(global_raw_count(), expected_raw_count,
			"raw ore conservation failed immediately after extraction")
		ore_observed = true
		minetest.log("action", "MINER_ORE_EXTRACTED_OK:" .. profile
			.. ":source=" .. ore_name .. ":drop=" .. raw_name
			.. ":count=" .. tostring(expected_raw_count) .. ":attempts=" .. tostring(dig_attempts))
	end

	local chest_raw = count_in_inventory(chest_inventory, raw_name, true)
	if ore_observed and chest_raw == expected_raw_count and not deposit_observed then
		assert_equal(carried_count(raw_name), 0,
			"raw ore remained on miner after shared-chest deposit")
		assert_equal(count_dropped(raw_name), 0,
			"raw ore was dropped instead of deposited")
		assert_equal(global_raw_count(), expected_raw_count,
			"raw ore was lost or duplicated at deposit")
		assert_true(cargo_travelled >= 0.5,
			"ore reached the chest without observable miner travel")
		assert_true(vector.distance(miner.object:get_pos(), CHEST_POS) <= 4.5,
			"ore appeared in chest while miner was not physically nearby")
		deposit_observed = true
		settle_started_at = minetest.get_us_time() / 1000000
		miner.pause = true
		miner.pause_auto = nil
		miner.job_data.pause_reason = "manual"
		miner.object:set_velocity({x = 0, y = 0, z = 0})
		minetest.log("action", ("MINER_PHYSICAL_DEPOSIT_OK:%s:item=%s:count=%d:travel=%.2f")
			:format(profile, raw_name, expected_raw_count, cargo_travelled))
	end

	if deposit_observed
			and minetest.get_us_time() / 1000000 - settle_started_at >= 1 then
		assert_equal(count_in_inventory(chest_inventory, raw_name, true), expected_raw_count,
			"deposited ore count changed during settle window")
		assert_equal(global_raw_count(), expected_raw_count,
			"global ore balance changed during settle window")
		assert_equal(count_group_in_inventory(miner:get_inventory(), "pickaxe"), 1,
			"crafted pickaxe was lost or duplicated")
		assert_equal(count_in_inventory(chest_inventory, cobble_name, true)
			+ carried_count(cobble_name) + count_dropped(cobble_name), 0,
			"consumed cobble reappeared")
		assert_equal(count_in_inventory(chest_inventory, stick_name, true)
			+ carried_count(stick_name) + count_dropped(stick_name), 0,
			"consumed sticks reappeared")
		minetest.log("action", "MINER_CONSERVATION_OK:" .. profile
			.. ":ore_nodes=1->0:raw=0->" .. tostring(expected_raw_count)
			.. ":craft=3_cobble+2_sticks->1_pick")
		minetest.log("action", "WORKING_VILLAGES_MINER_RUNTIME_OK:" .. profile)
		finish(true)
		return
	end

	local elapsed = minetest.get_us_time() / 1000000 - started_at
	if elapsed - last_diagnostic >= 5 then
		last_diagnostic = elapsed
		local pos = vector.round(miner.object:get_pos())
		minetest.log("action", "MINER_RUNTIME_PROGRESS:" .. profile
			.. ":elapsed=" .. tostring(math.floor(elapsed))
			.. ":pos=" .. minetest.pos_to_string(pos, 0)
			.. ":search_timer=" .. tostring(miner:get_timer("miner:search"))
			.. ":chest_timer=" .. tostring(miner:get_timer("handle_chest"))
			.. ":manipulated_chest=" .. tostring(miner.job_data.manipulated_chest)
			.. ":thread=" .. tostring(miner.job_thread and coroutine.status(miner.job_thread))
			.. ":owner=" .. tostring(miner.owner_name)
			.. ":action=" .. tostring(miner.disp_action))
	end
	if elapsed >= TIMEOUT_SECONDS then
		fail("timeout: pick=" .. tostring(pick_observed)
			.. ", ore=" .. tostring(ore_observed)
			.. ", deposit=" .. tostring(deposit_observed)
			.. ", node=" .. minetest.get_node(ORE_POS).name
			.. ", wield=" .. miner:get_wield_item_stack():get_name()
			.. ", chest_raw=" .. tostring(chest_raw)
			.. ", carried_raw=" .. tostring(carried_count(raw_name))
			.. ", action=" .. tostring(miner.disp_action)
			.. ", state=" .. tostring(miner.state_info)
			.. ", job_error=" .. minetest.serialize(error_state))
	end
	schedule(POLL_SECONDS, poll)
end

local function run()
	select_resources()
	setup_pad()
	setup_real_chest()
	create_miner()
	minetest.set_timeofday(0.5)
	started_at = minetest.get_us_time() / 1000000
	minetest.log("action", "MINER_RUNTIME_STARTED:" .. profile
		.. ":ore_pos=" .. minetest.pos_to_string(ORE_POS, 0)
		.. ":chest_pos=" .. minetest.pos_to_string(CHEST_POS, 0))
	schedule(POLL_SECONDS, poll)
end

minetest.after(0, function()
	minetest.emerge_area(AREA_MIN, AREA_MAX, function(_, _, remaining)
		if remaining ~= 0 then
			return
		end
		schedule(0, run)
	end)
end)
