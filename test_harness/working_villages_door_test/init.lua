local function fail(message)
	error("[working_villages_door_test] " .. message, 2)
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

local function run_coroutine(action)
	local thread = coroutine.create(action)
	local result, detail
	repeat
		local resumed, first, second = coroutine.resume(thread)
		assert_true(resumed, first)
		if coroutine.status(thread) == "dead" then
			result, detail = first, second
		end
	until coroutine.status(thread) == "dead"
	return result, detail
end

local function make_villager(pos, owner_name, material_name)
	local inventory_name = "working_villages_door_inventory_" .. tostring(minetest.get_us_time())
	local inv = minetest.create_detached_inventory(inventory_name, {})
	inv:set_size("main", 8)
	inv:set_size("wield_item", 1)
	inv:set_stack("wield_item", 1, ItemStack(material_name .. " 2"))
	local yaw = 0
	local object = {
		get_pos = function() return vector.new(pos) end,
		get_velocity = function() return {x = 0, y = 0, z = 0} end,
		get_yaw = function() return yaw end,
		set_yaw = function(_, value) yaw = value end,
		set_animation = function() end,
		set_properties = function() end,
	}
	return setmetatable({
		owner_name = owner_name,
		object = object,
		get_inventory = function() return inv end,
	}, {__index = working_villages.villager}), inv
end

local function clear_test_column(target)
	for dy = -1, 2 do
		minetest.set_node(vector.add(target, {x = 0, y = dy, z = 0}), {name = "air"})
	end
end

local function run(base)
	local profile = working_villages.game_profile
	local compat = working_villages.compat
	local buildings = working_villages.buildings
	assert_true(profile and profile.supported, "active game profile is unsupported")

	local expected_bottom = compat.get_item("doors:door_wood_a")
	local material_name = buildings.get_registered_nodename(expected_bottom)
	assert_true(minetest.registered_nodes[expected_bottom] ~= nil,
		"mapped concrete door bottom is not registered")
	assert_true(minetest.registered_items[material_name] ~= nil,
		"mapped door craftitem is not registered")
	assert_true(minetest.registered_nodes[material_name] == nil,
		"door material unexpectedly is a node; regression probe is not exercising on_place")
	assert_true(type(minetest.registered_items[material_name].on_place) == "function",
		"door craftitem has no on_place callback")
	assert_true(#(minetest.get_all_craft_recipes(material_name) or {}) > 0,
		"door material has no survival recipe")

	local support_name = compat.get_item("default:cobble")
	assert_true(minetest.registered_nodes[support_name] ~= nil, "support node is not registered")
	local target = vector.round(base)
	clear_test_column(target)
	minetest.set_node(vector.add(target, {x = 0, y = -1, z = 0}), {name = support_name})

	local owner_name = "working_villages_door_owner_" .. tostring(minetest.get_us_time())
	local villager, inv = make_villager(
		vector.add(target, {x = -2, y = 0, z = 0}), owner_name, material_name)
	local placed, place_error = run_coroutine(function()
		return villager:place({name = expected_bottom, param2 = 1}, target)
	end)
	assert_equal(placed, true, "real door placement failed: " .. tostring(place_error))
	assert_equal(inv:get_stack("wield_item", 1):get_name(), material_name,
		"door placement replaced the wielded item")
	assert_equal(inv:get_stack("wield_item", 1):get_count(), 1,
		"door placement did not consume exactly one craftitem")

	local bottom = minetest.get_node(target)
	local top = minetest.get_node(vector.add(target, {x = 0, y = 1, z = 0}))
	assert_true(buildings.door_pair_matches_item(expected_bottom, bottom.name, top.name),
		"real on_place did not create a matching two-node door")
	assert_true(buildings.node_matches_schematic(expected_bottom, bottom.name),
		"builder would retry the already-created bottom half")
	local expected_top = profile.is_voxelibre
		and compat.get_item("doors:door_wood_c") or "doors:hidden"
	assert_true(buildings.node_matches_schematic(expected_top, top.name),
		"builder would retry or double-consume the already-created top half")
	assert_equal(bottom.param2, top.param2, "door halves disagree on orientation")

	-- A second real placement exercises warning deduplication for games whose
	-- downstream callbacks require engine-owned state from an online PlayerRef.
	local second_target = vector.add(target, {x = 0, y = 0, z = 2})
	clear_test_column(second_target)
	minetest.set_node(vector.add(second_target, {x = 0, y = -1, z = 0}), {name = support_name})
	inv:set_stack("wield_item", 1, ItemStack(material_name .. " 2"))
	local second_placed, second_error = run_coroutine(function()
		return villager:place({name = expected_bottom, param2 = 1}, second_target)
	end)
	assert_equal(second_placed, true, "second real door placement failed: " .. tostring(second_error))
	assert_equal(inv:get_stack("wield_item", 1):get_count(), 1,
		"second door placement did not consume exactly one craftitem")
	local second_bottom = minetest.get_node(second_target)
	local second_top = minetest.get_node(vector.add(second_target, {x = 0, y = 1, z = 0}))
	assert_true(buildings.door_pair_matches_item(
		expected_bottom, second_bottom.name, second_top.name),
		"second real on_place did not create a matching door pair")
	clear_test_column(second_target)

	-- Protecting only the upper half must refuse the multi-node action before
	-- callbacks run and without consuming the craftitem.
	clear_test_column(target)
	minetest.set_node(vector.add(target, {x = 0, y = -1, z = 0}), {name = support_name})
	inv:set_stack("wield_item", 1, ItemStack(material_name .. " 2"))
	local protected_top = vector.add(target, {x = 0, y = 1, z = 0})
	local protected_hash = minetest.hash_node_position(protected_top)
	local original_is_protected = minetest.is_protected
	minetest.is_protected = function(pos, name)
		if minetest.hash_node_position(vector.round(pos)) == protected_hash then
			return true
		end
		return original_is_protected(pos, name)
	end
	local refused, refusal_reason = run_coroutine(function()
		return villager:place({name = expected_bottom, param2 = 1}, target)
	end)
	minetest.is_protected = original_is_protected
	assert_equal(refused, false, "door crossed protection on its upper half")
	assert_equal(refusal_reason, working_villages.require("failures").protected,
		"protected door returned the wrong failure")
	assert_equal(inv:get_stack("wield_item", 1):get_count(), 2,
		"protected door attempt consumed material")
	assert_equal(minetest.get_node(target).name, "air", "protected door bottom was placed")
	assert_equal(minetest.get_node(protected_top).name, "air", "protected door top was placed")

	clear_test_column(target)
	if profile.is_voxelibre then
		minetest.log("action", "VOXELIBRE_DOOR_PLACEMENT_OK")
	else
		minetest.log("action", "MINETEST_GAME_DOOR_PLACEMENT_OK")
	end
	minetest.log("action", "DOOR_PLACEMENT_EXACT_OK:" .. profile.id)
end

local base = {x = 992, y = 16, z = 992}
minetest.after(0, function()
	minetest.emerge_area(
		vector.subtract(base, {x = 2, y = 2, z = 2}),
		vector.add(base, {x = 2, y = 3, z = 2}),
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
					ok and "working_villages door tests completed"
						or "working_villages door tests failed",
					false,
					0
				)
			end)
		end)
end)
