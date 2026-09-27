local function fail(message)
	error("[working_villages_inventory_test] " .. message, 2)
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

local function run(base)
	local profile = working_villages.game_profile
	assert_true(profile and profile.supported, "active game profile is unsupported")
	local furnace_name = working_villages.compat.get_node("default:furnace")
	local expected_furnace = profile.is_voxelibre
		and "mcl_furnaces:furnace" or "default:furnace"
	assert_equal(furnace_name, expected_furnace, "furnace mapping is wrong")
	local furnace_def = minetest.registered_nodes[furnace_name]
	assert_true(furnace_def ~= nil, "mapped furnace is not registered")
	assert_true(type(furnace_def.on_construct) == "function", "furnace constructor is missing")
	assert_true(type(furnace_def.on_metadata_inventory_take) == "function",
		"furnace take callback is missing")

	-- make_actor must hand callbacks a genuine connected owner whenever one is
	-- available. A short synchronous lookup shim proves that selection without
	-- requiring a network client in this headless harness.
	local original_get_player = minetest.get_player_by_name
	local online_player = {
		is_player = function() return true end,
		get_player_name = function() return "inventory_online_owner" end,
	}
	minetest.get_player_by_name = function(name)
		if name == "inventory_online_owner" then
			return online_player
		end
		return original_get_player(name)
	end
	local resolved_actor, synthetic = working_villages.inventory_access.make_actor({
		owner_name = "inventory_online_owner",
	})
	minetest.get_player_by_name = original_get_player
	assert_equal(resolved_actor, online_player, "connected owner was not used as callback actor")
	assert_equal(synthetic, false, "connected owner was marked as a synthetic actor")

	local pos = vector.round(base)
	minetest.set_node(pos, {name = furnace_name})
	furnace_def.on_construct(pos)
	local meta = minetest.get_meta(pos)
	local furnace_inventory = meta:get_inventory()
	local expected_dst_size = profile.is_voxelibre and 1 or 4
	assert_equal(furnace_inventory:get_size("dst"), expected_dst_size,
		"furnace output was not initialized")

	local output_name = working_villages.compat.get_item("default:steel_ingot")
	local expected_output = profile.is_voxelibre
		and "mcl_core:iron_ingot" or "default:steel_ingot"
	assert_equal(output_name, expected_output, "furnace output mapping is wrong")
	assert_true(minetest.registered_items[output_name] ~= nil, "mapped ingot is not registered")
	furnace_inventory:set_stack("dst", 1, ItemStack(output_name .. " 2"))
	local expected_xp = profile.is_voxelibre and 7 or 0
	meta:set_int("xp", expected_xp)

	local nonce = tostring(minetest.get_us_time())
	local destination = minetest.create_detached_inventory(
		"working_villages_inventory_destination_" .. nonce, {})
	destination:set_size("main", 4)
	local offline_villager = {
		owner_name = "working_villages_inventory_offline_owner_" .. nonce,
		object = {
			get_pos = function() return vector.new(pos) end,
			get_yaw = function() return 0 end,
		},
		get_inventory = function() return destination end,
	}
	assert_equal(minetest.get_player_by_name(offline_villager.owner_name), nil,
		"offline test owner unexpectedly exists")

	-- Count the real registered callback itself in both games. VoxeLibre then
	-- gets an additional XP-specific probe: its private HUD cache rejects a
	-- synthetic table actor, which inventory_access must contain without losing
	-- either the furnace output or accumulated XP.
	local original_take_callback = furnace_def.on_metadata_inventory_take
	local callback_calls = 0
	furnace_def.on_metadata_inventory_take = function(...)
		callback_calls = callback_calls + 1
		return original_take_callback(...)
	end
	local original_add_xp = profile.is_voxelibre and mcl_experience.add_xp or nil
	local add_xp_calls = 0
	if original_add_xp then
		mcl_experience.add_xp = function(player, xp)
			add_xp_calls = add_xp_calls + 1
			-- Exercise the compensation branch too: even if a game callback
			-- consumes XP before rejecting its actor, the original value returns.
			meta:set_int("xp", 0)
			return original_add_xp(player, xp)
		end
	end
	local transfer_ok, first_moved = pcall(
		working_villages.inventory_access.take_to_inventory,
		offline_villager,
		pos,
		"dst",
		1,
		destination,
		"main",
		1
	)
	local second_ok, second_moved = pcall(
		working_villages.inventory_access.take_to_inventory,
		offline_villager,
		pos,
		"dst",
		1,
		destination,
		"main",
		1
	)
	furnace_def.on_metadata_inventory_take = original_take_callback
	if original_add_xp then
		mcl_experience.add_xp = original_add_xp
	end

	assert_true(transfer_ok, "first offline furnace take escaped its callback guard")
	assert_true(second_ok, "second offline furnace take escaped its callback guard")
	assert_equal(first_moved, 1, "first furnace output was not transferred exactly")
	assert_equal(second_moved, 1, "second furnace output was not transferred exactly")
	assert_equal(callback_calls, 2, "furnace take callback was not invoked for every transfer")
	if profile.is_voxelibre then
		assert_equal(add_xp_calls, 2, "VoxeLibre furnace did not attempt both XP grants")
	end
	assert_equal(destination:contains_item("main", ItemStack(output_name .. " 2")), true,
		"furnace output was lost")
	assert_equal(furnace_inventory:get_stack("dst", 1):is_empty(), true,
		"furnace output remained duplicated")
	assert_equal(meta:get_int("xp"), expected_xp, "offline furnace callback lost accumulated XP")

	meta:set_int("xp", 0)
	minetest.set_node(pos, {name = "air"})
	if profile.is_voxelibre then
		minetest.log("action", "VOXELIBRE_OFFLINE_FURNACE_CALLBACK_OK")
	else
		minetest.log("action", "MINETEST_GAME_OFFLINE_FURNACE_CALLBACK_OK")
	end
	minetest.log("action", "OFFLINE_FURNACE_CALLBACK_OK:" .. profile.id)
end

local base = {x = 984, y = 16, z = 984}
minetest.after(0, function()
	minetest.emerge_area(
		vector.subtract(base, {x = 2, y = 2, z = 2}),
		vector.add(base, {x = 2, y = 2, z = 2}),
		function(_, _, remaining)
			if remaining ~= 0 then
				return
			end
			minetest.after(0, function()
				local ok, err = xpcall(function() run(base) end, debug.traceback)
				if not ok then
					minetest.log("error", tostring(err))
				end
				minetest.request_shutdown(
					ok and "working_villages inventory callback tests completed"
						or "working_villages inventory callback tests failed",
					false,
					0
				)
			end)
		end)
end)
