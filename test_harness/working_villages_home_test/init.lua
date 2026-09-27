local function assert_true(value, message)
	if not value then
		error(message or "expected true", 2)
	end
end

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": got " .. tostring(actual)
			.. ", expected " .. tostring(expected), 2)
	end
end

minetest.register_node("working_villages_home_test:not_a_bed_top", {
	description = "Home validation fake top",
	drawtype = "airlike",
	walkable = false,
	pointable = false,
	groups = {not_in_creative_inventory = 1},
})

minetest.register_node("working_villages_home_test:not_a_bed_bottom", {
	description = "Home validation fake bottom",
	drawtype = "airlike",
	walkable = false,
	pointable = false,
	groups = {not_in_creative_inventory = 1},
})

local function add(pos, offset)
	return vector.add(pos, offset)
end

local function first_registered(names)
	for _, name in ipairs(names or {}) do
		if minetest.registered_nodes[name] then
			return name
		end
	end
	return nil
end

local function configure_marker(pos, owner, bed_pos, door_pos)
	minetest.set_node(pos, {name = "working_villages:building_marker"})
	local meta = minetest.get_meta(pos)
	meta:set_string("owner", owner)
	meta:set_string("state", "built")
	meta:set_string("valid", "true")
	meta:set_string("bed", minetest.pos_to_string(bed_pos))
	meta:set_string("door", minetest.pos_to_string(door_pos))
end

local function run(base)
	local compat = working_villages.voxelibre_compat
	local validator = working_villages.buildings.validate_home_nodes
	assert_true(type(validator) == "function", "home validator is not exposed")
	assert_equal(compat.is_door("mcl_doors:trapdoor"), false,
		"VoxeLibre trapdoor was accepted as a full door")
	assert_equal(compat.is_door("doors:trapdoor"), false,
		"minetest_game trapdoor was accepted as a full door")
	assert_equal(compat.is_door("mcl_doors:stone_button"), false,
		"unrelated mcl_doors item was accepted as a full door")
	assert_equal(compat.is_door("doors:door_wood_a"), true,
		"legacy minetest_game door state was rejected")

	local beds = compat.get_bed_items()
	local bottom_name = first_registered(beds.bottom)
	local bottom_index = nil
	for index, name in ipairs(beds.bottom) do
		if name == bottom_name then
			bottom_index = index
			break
		end
	end
	local top_name = bottom_index and beds.top[bottom_index] or nil
	assert_true(bottom_name and top_name and minetest.registered_nodes[top_name],
		"no registered matching bed pair")

	local door_bottom = nil
	for _, name in ipairs(compat.get_door_items()) do
		if minetest.registered_nodes[name] and not name:find("_t_", 1, true) then
			door_bottom = name
			break
		end
	end
	assert_true(door_bottom ~= nil, "no registered full door bottom")
	assert_true(compat.is_door(door_bottom), "registered full door was rejected")
	local door_top = door_bottom:gsub("_b_([12])$", "_t_%1")
	if not minetest.registered_nodes[door_top] then
		door_top = "doors:hidden"
	end
	assert_true(minetest.registered_nodes[door_top] ~= nil, "no registered full door top")

	local floor_name = compat.get_item("default:stone")
	for x = -10, 14 do
		for z = -10, 14 do
			minetest.set_node(add(base, {x = x, y = -1, z = z}), {name = floor_name})
			for y = 0, 3 do
				minetest.set_node(add(base, {x = x, y = y, z = z}), {name = "air"})
			end
		end
	end

	local bed_bottom = add(base, {x = 5, y = 0, z = 0})
	local bed_dir = minetest.facedir_to_dir(0)
	local bed_top = add(bed_bottom, bed_dir)
	minetest.set_node(bed_bottom, {name = bottom_name, param2 = 0})
	minetest.set_node(bed_top, {name = top_name, param2 = 0})
	local door_pos = add(base, {x = 0, y = 0, z = 0})
	minetest.set_node(door_pos, {name = door_bottom, param2 = 1})
	minetest.set_node(add(door_pos, {x = 0, y = 1, z = 0}), {name = door_top, param2 = 1})
	local access_pos = add(base, {x = -1, y = 0, z = 0})
	local valid, reason, canonical = validator(bed_bottom, access_pos)
	assert_true(valid, "real reachable bed was rejected: " .. tostring(reason))
	assert_true(vector.equals(canonical, bed_bottom), "bottom bed was not canonical")
	valid, reason, canonical = validator(bed_top, access_pos)
	assert_true(valid, "top half of real bed was rejected: " .. tostring(reason))
	assert_true(vector.equals(canonical, bed_bottom), "top half did not normalize to bottom")
	minetest.set_node(bed_top, {name = "air"})
	valid, reason = validator(bed_bottom, access_pos)
	assert_equal(valid, false, "incomplete bed pair validated")
	assert_equal(reason, "invalid_bed", "wrong incomplete-bed rejection reason")
	minetest.set_node(bed_bottom, {name = bottom_name, param2 = 0})
	minetest.set_node(bed_top, {name = top_name, param2 = 1})
	valid, reason = validator(bed_bottom, access_pos)
	assert_equal(valid, false, "misoriented bed pair validated")
	assert_equal(reason, "invalid_bed", "wrong misoriented-bed rejection reason")
	minetest.set_node(bed_bottom, {name = bottom_name, param2 = 0})
	minetest.set_node(bed_top, {name = top_name, param2 = 0})

	for index, fake_name in ipairs({
		"working_villages_home_test:not_a_bed_top",
		"working_villages_home_test:not_a_bed_bottom",
	}) do
		local fake_pos = add(base, {x = 3 + index, y = 0, z = -4})
		minetest.set_node(fake_pos, {name = fake_name})
		local fake_beds = working_villages.buildings.find_beds({{
			pos = fake_pos,
			node = {name = fake_name, param2 = 0},
		}})
		assert_equal(#fake_beds, 0, "non-bed suffix node was discovered as a bed")
		valid, reason = validator(fake_pos, access_pos)
		assert_equal(valid, false, "non-bed suffix node validated as a bed")
		assert_equal(reason, "invalid_bed", "wrong non-bed rejection reason")
	end

	local trapdoor_name = first_registered({
		"mcl_doors:trapdoor",
		"doors:trapdoor",
	})
	if trapdoor_name then
		assert_equal(compat.is_door(trapdoor_name), false,
			"registered trapdoor was accepted as a full door")
		local trap_pos = add(base, {x = 0, y = 0, z = 10})
		local trap_access = add(base, {x = -1, y = 0, z = 10})
		minetest.set_node(trap_pos, {name = trapdoor_name})
		valid, reason = validator(bed_bottom, trap_access)
		assert_equal(valid, false, "trapdoor validated as a home entrance")
		assert_equal(reason, "invalid_access", "wrong trapdoor rejection reason")
	end

	local blocked = {}
	for _, half in ipairs({bed_bottom, bed_top}) do
		for _, offset in ipairs({
			{x = 1, y = 0, z = 0}, {x = -1, y = 0, z = 0},
			{x = 0, y = 0, z = 1}, {x = 0, y = 0, z = -1},
		}) do
			local pos = add(half, offset)
			local key = minetest.hash_node_position(pos)
			if not blocked[key] and not vector.equals(pos, bed_bottom)
					and not vector.equals(pos, bed_top) then
				blocked[key] = pos
				minetest.set_node(pos, {name = floor_name})
				minetest.set_node(add(pos, {x = 0, y = 1, z = 0}), {name = floor_name})
			end
		end
	end
	valid, reason = validator(bed_bottom, access_pos)
	assert_equal(valid, false, "sealed bed remained reachable")
	assert_equal(reason, "unreachable_bed", "wrong sealed-bed rejection reason")
	for _, pos in pairs(blocked) do
		minetest.set_node(pos, {name = "air"})
		minetest.set_node(add(pos, {x = 0, y = 1, z = 0}), {name = "air"})
	end

	local marker_one = add(base, {x = -4, y = 0, z = -4})
	local marker_two = add(base, {x = -6, y = 0, z = -4})
	local owner = "home_validation_owner"
	configure_marker(marker_one, owner, bed_bottom, access_pos)
	-- Deliberately store the other half: collision detection must normalize it.
	configure_marker(marker_two, owner, bed_top, access_pos)
	local inventory_one = "home_validation_villager_one"
	local inventory_two = "home_validation_villager_two"
	local previous_one = working_villages.homes[inventory_one]
	local previous_two = working_villages.homes[inventory_two]
	working_villages.homes[inventory_one] = working_villages.home:new({marker = marker_one})
	working_villages.homes[inventory_two] = nil
	local available, unavailable_reason = working_villages.is_home_available(
		marker_two, owner, inventory_two)
	assert_equal(available, false, "same physical bed was offered twice")
	assert_equal(unavailable_reason, "bed_occupied", "wrong duplicate-bed rejection reason")
	available, unavailable_reason = working_villages.is_home_available(
		marker_one, owner, inventory_one)
	assert_true(available, "villager could not retain its own bed: " .. tostring(unavailable_reason))
	working_villages.homes[inventory_two] = working_villages.home:new({marker = marker_two})
	assert_equal(working_villages.is_valid_home({
		inventory_name = inventory_one,
		owner_name = owner,
	}), false, "persisted duplicate bed was treated as valid")
	working_villages.homes[inventory_one] = previous_one
	working_villages.homes[inventory_two] = previous_two

	minetest.log("action", "HOME_VALIDATION_SPEC_OK")
end

local base = {x = 480, y = 24, z = 480}
minetest.after(0, function()
	minetest.emerge_area(add(base, {x = -12, y = -3, z = -12}),
		add(base, {x = 16, y = 5, z = 16}), function(_, _, remaining)
			if remaining ~= 0 then
				return
			end
			minetest.after(0, function()
				local ok, result = pcall(run, base)
				if not ok then
					minetest.log("error", "HOME_VALIDATION_SPEC_FAILED: " .. tostring(result))
				end
				minetest.request_shutdown(ok and "home validation tests completed"
					or "home validation tests failed", false, 0)
			end)
		end)
end)
