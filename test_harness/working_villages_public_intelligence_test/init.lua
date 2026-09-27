-- Real-engine public-server intelligence regression.

local OWNER = "working_villages_public_intelligence_owner"
local ENTITY = "working_villages:villager_female"
local FARM_JOB = "working_villages:job_farmer"
local BUILDER_JOB = "working_villages:job_builder"
local FARM_CENTER = {x = 1400, y = 1001, z = 1400}
local BUILD_CENTER = {x = 1420, y = 1001, z = 1400}
local TIMEOUT = 90
local profile = working_villages.game_profile and working_villages.game_profile.id or "unknown"
local compat = working_villages.compat
local farming = working_villages.farming_compat
local finished = false
local farmer
local builder
local seed_names
local seed_initial
local crop_verified = false
local construction_started_at
local construction_probe
local next_progress = 0

local function fail(message)
	error("[working_villages_public_intelligence_test] " .. tostring(message), 2)
end

local function assert_true(value, message)
	if not value then
		fail(message or "expected a truthy value")
	end
end

local function finish(ok, message)
	if finished then
		return
	end
	finished = true
	if not ok then
		minetest.log("error", "PUBLIC_INTELLIGENCE_RUNTIME_FAILED:" .. profile .. ":" .. tostring(message))
	end
	minetest.request_shutdown(ok and
		"working_villages public intelligence test completed" or
		"working_villages public intelligence test failed", false, 0)
end

local function protected(callback)
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
		protected(callback)
	end)
end

local function choose_registered(candidates, registry)
	for _, name in ipairs(candidates) do
		if name and registry[name] then
			return name
		end
	end
	return nil
end

local function choose_stone()
	return choose_registered({
		compat.get_item("default:stone"), "default:stone", "mcl_core:stone",
	}, minetest.registered_nodes) or fail("no stone foundation node")
end

local function choose_farmland()
	local best
	local best_score = -1
	for name in pairs(minetest.registered_nodes) do
		if compat.is_farmland_node(name) then
			local score = minetest.get_item_group(name, "soil")
			if name:lower():find("wet", 1, true) then
				score = score + 10
			end
			if score > best_score then
				best = name
				best_score = score
			end
		end
	end
	return best or fail("no farmland node")
end

local function forceload_area(center, radius)
	if type(minetest.forceload_block) ~= "function" then
		return
	end
	for x = center.x - radius, center.x + radius, 16 do
		for z = center.z - radius, center.z + radius, 16 do
			minetest.forceload_block({x = x, y = center.y, z = z}, true)
		end
	end
end

local function choose_two_seeds()
	local preferred = profile == "voxelibre" and {
		"mcl_farming:wheat_seeds", "mcl_farming:beetroot_seeds",
		"mcl_farming:carrot_item", "mcl_farming:potato_item",
	} or {
		"farming:seed_wheat", "farming:seed_cotton",
	}
	local result = {}
	local seen = {}
	local function add(name)
		if name and minetest.registered_items[name] and not seen[name] then
			seen[name] = true
			result[#result + 1] = name
		end
	end
	for _, name in ipairs(preferred) do
		add(name)
	end
	for _, data in pairs(farming.get_plants() or {}) do
		for _, name in ipairs(data.replant or {}) do
			add(name)
		end
	end
	assert_true(#result >= 2, "active game exposes fewer than two plantable seeds")
	return {result[1], result[2]}
end

local function clear_inventory(villager)
	local inv = villager:get_inventory()
	assert_true(inv, "villager detached inventory unavailable")
	for list_name, list in pairs(inv:get_lists() or {}) do
		for index = 1, #list do
			inv:set_stack(list_name, index, ItemStack())
		end
	end
end

local function count_item(villager, item_name)
	local count = 0
	for _, list in pairs(villager:get_inventory():get_lists() or {}) do
		for _, stack in ipairs(list or {}) do
			if stack:get_name() == item_name then
				count = count + stack:get_count()
			end
		end
	end
	return count
end

local function prepare_farm()
	local stone = choose_stone()
	local farmland = choose_farmland()
	forceload_area(FARM_CENTER, 16)
	minetest.load_area(
		{x = FARM_CENTER.x - 6, y = FARM_CENTER.y - 2, z = FARM_CENTER.z - 6},
		{x = FARM_CENTER.x + 6, y = FARM_CENTER.y + 4, z = FARM_CENTER.z + 6})
	for x = FARM_CENTER.x - 4, FARM_CENTER.x + 4 do
		for z = FARM_CENTER.z - 4, FARM_CENTER.z + 4 do
			minetest.set_node({x = x, y = FARM_CENTER.y - 2, z = z}, {name = stone})
			minetest.set_node({x = x, y = FARM_CENTER.y - 1, z = z}, {name = farmland})
			for y = FARM_CENTER.y, FARM_CENTER.y + 3 do
				minetest.set_node({x = x, y = y, z = z}, {name = "air"})
			end
		end
	end
end

local function create_farmer()
	seed_names = choose_two_seeds()
	local object = minetest.add_entity(FARM_CENTER, ENTITY)
	assert_true(object, "could not create real farmer")
	farmer = object:get_luaentity()
	assert_true(farmer, "real farmer has no Lua state")
	clear_inventory(farmer)
	farmer.owner_name = OWNER
	farmer.inventory_name = farmer.inventory_name or "public_intelligence_farmer"
	farmer.pos_data = farmer.pos_data or {}
	farmer.pos_data.job_pos = vector.new(FARM_CENTER)
	working_villages.needs.set(farmer, "hunger", 100)
	working_villages.needs.set(farmer, "energy", 100)
	local changed, reason = farmer:change_job(FARM_JOB)
	assert_true(changed, "could not assign farmer job: " .. tostring(reason))
	for _, name in ipairs(seed_names) do
		local leftover = farmer:add_item_to_main(ItemStack(name .. " 20"))
		assert_true(leftover:is_empty(), "could not provide seed " .. name)
	end
	seed_initial = {
		[seed_names[1]] = count_item(farmer, seed_names[1]),
		[seed_names[2]] = count_item(farmer, seed_names[2]),
	}
end

local function crop_count()
	local count = 0
	for x = FARM_CENTER.x - 4, FARM_CENTER.x + 4 do
		for z = FARM_CENTER.z - 4, FARM_CENTER.z + 4 do
			if minetest.get_node({x = x, y = FARM_CENTER.y, z = z}).name ~= "air" then
				count = count + 1
			end
		end
	end
	return count
end

local function choose_flora()
	local preferred = profile == "voxelibre" and {
		"mcl_flowers:tallgrass", "mcl_flowers:fern",
	} or {
		"default:grass_1", "default:junglegrass", "flowers:dandelion_yellow",
	}
	for _, name in ipairs(preferred) do
		local def = minetest.registered_nodes[name]
		if def and def.buildable_to and minetest.get_item_group(name, "liquid") == 0 then
			return name
		end
	end
	for name, def in pairs(minetest.registered_nodes) do
		if name ~= "air" and def.buildable_to and minetest.get_item_group(name, "liquid") == 0 then
			return name
		end
	end
	return nil
end

local function prepare_build_pad()
	local stone = choose_stone()
	forceload_area(BUILD_CENTER, 32)
	minetest.load_area(
		{x = BUILD_CENTER.x - 14, y = BUILD_CENTER.y - 2, z = BUILD_CENTER.z - 14},
		{x = BUILD_CENTER.x + 14, y = BUILD_CENTER.y + 8, z = BUILD_CENTER.z + 14})
	for x = BUILD_CENTER.x - 12, BUILD_CENTER.x + 12 do
		for z = BUILD_CENTER.z - 12, BUILD_CENTER.z + 12 do
			minetest.set_node({x = x, y = BUILD_CENTER.y - 2, z = z}, {name = stone})
			minetest.set_node({x = x, y = BUILD_CENTER.y - 1, z = z}, {name = stone})
			for y = BUILD_CENTER.y, BUILD_CENTER.y + 7 do
				minetest.set_node({x = x, y = y, z = z}, {name = "air"})
			end
		end
	end
	-- The first deterministic candidate is deliberately invalid.
	local bad = {x = BUILD_CENTER.x - 6, y = BUILD_CENTER.y - 1, z = BUILD_CENTER.z - 6}
	local water = choose_registered({
		compat.get_item("default:water_source"), "default:water_source", "mcl_core:water_source",
	}, minetest.registered_nodes)
	if water then
		minetest.set_node(bad, {name = water})
	else
		minetest.set_node({x = bad.x, y = BUILD_CENTER.y, z = bad.z}, {name = stone})
	end
	return bad
end

local function start_construction_probe()
	local bad = prepare_build_pad()
	-- Reuse the already-active real entity. Dedicated headless servers may
	-- deactivate a second object immediately when no player is connected,
	-- which would test active-block policy rather than construction behavior.
	builder = farmer
	assert_true(builder and builder.object, "real builder has no Lua state")
	builder.object:set_pos(BUILD_CENTER)
	clear_inventory(builder)
	builder.owner_name = OWNER
	builder.pos_data = builder.pos_data or {}
	builder.pos_data.job_pos = vector.new(BUILD_CENTER)
	working_villages.needs.set(builder, "hunger", 100)
	working_villages.needs.set(builder, "energy", 100)
	local changed, change_reason = builder:change_job(BUILDER_JOB)
	assert_true(changed, "could not assign builder job: " .. tostring(change_reason))
	local learned, learn_reason = working_villages.blueprints.force_teach(
		builder:get_inventory_name(), "minimal_shelter")
	assert_true(learned, "could not teach minimal shelter: " .. tostring(learn_reason))
	local started, start_reason = working_villages.blueprint_construction.start_site(
		builder, "minimal_shelter")
	assert_true(started, "safe site planner found no site: " .. tostring(start_reason))
	local marker_positions = minetest.find_nodes_in_area(
		{x = BUILD_CENTER.x - 40, y = BUILD_CENTER.y - 2, z = BUILD_CENTER.z - 40},
		{x = BUILD_CENTER.x + 40, y = BUILD_CENTER.y + 10, z = BUILD_CENTER.z + 40},
		{"working_villages:building_marker"})
	assert_true(#marker_positions == 1, "expected exactly one deterministic construction marker")
	local marker_pos = marker_positions[1]
	local meta = minetest.get_meta(marker_pos)
	local build_pos = working_villages.buildings.get_build_pos(meta)
	assert_true(build_pos.x ~= bad.x or build_pos.z ~= bad.z,
		"site planner accepted the deliberately liquid/occupied first candidate")
	local building = working_villages.buildings.get(build_pos)
	assert_true(building and type(building.nodedata) == "table", "site lost its construction plan")
	local air_entry
	local air_count = 0
	local seen_solid = false
	for _, entry in ipairs(building.nodedata) do
		local name = working_villages.buildings.get_registered_nodename(entry.node.name)
		if name == "air" then
			assert_true(not seen_solid, "air clearing is scheduled after structural placement")
			air_entry = air_entry or entry
			air_count = air_count + 1
		else
			seen_solid = true
		end
	end
	assert_true(air_entry and air_count > 0, "complete shelter plan has no interior air cells")
	local flora = choose_flora()
	assert_true(flora, "active game exposes no harmless buildable vegetation")
	minetest.set_node(air_entry.pos, {name = flora})
	local work_pos
	for _, offset in ipairs({
		{x = 1, y = 0, z = 0}, {x = -1, y = 0, z = 0},
		{x = 0, y = 0, z = 1}, {x = 0, y = 0, z = -1},
	}) do
		local candidate = vector.add(air_entry.pos, offset)
		local below = vector.add(candidate, {x = 0, y = -1, z = 0})
		local below_def = minetest.registered_nodes[minetest.get_node(below).name]
		if minetest.get_node(candidate).name == "air" and below_def and below_def.walkable then
			work_pos = candidate
			break
		end
	end
	assert_true(work_pos, "no reachable position beside planned interior vegetation")
	builder.object:set_pos(work_pos)
	builder.pos_data.job_pos = vector.round(work_pos)
	builder.job_data.in_work = true
	construction_probe = {
		marker = vector.round(marker_pos),
		meta = meta,
		air_pos = vector.round(air_entry.pos),
		air_count = air_count,
		flora = flora,
		build_pos = vector.round(build_pos),
	}
	construction_started_at = minetest.get_gametime()
	minetest.log("action", "SAFE_SITE_SELECTED:" .. profile .. ":"
		.. minetest.pos_to_string(build_pos) .. ":air=" .. air_count)
end

local started_at
local function poll()
	if finished then
		return
	end
	if minetest.get_gametime() - started_at > TIMEOUT then
		fail("timeout")
	end
	if not crop_verified then
		local deltas = {}
		local consumed_types = 0
		local consumed_total = 0
		for _, name in ipairs(seed_names) do
			deltas[name] = seed_initial[name] - count_item(farmer, name)
			if deltas[name] > 0 then
				consumed_types = consumed_types + 1
				consumed_total = consumed_total + deltas[name]
			end
		end
		local elapsed = minetest.get_gametime() - started_at
		if elapsed >= next_progress then
			next_progress = elapsed + 5
			minetest.log("action", "PUBLIC_INTELLIGENCE_PROGRESS:" .. profile
				.. ":elapsed=" .. elapsed .. ":crops=" .. crop_count()
				.. ":consumed=" .. consumed_total .. ":action="
				.. tostring(farmer.disp_action) .. ":state=" .. tostring(farmer.state_info)
				.. ":thread=" .. tostring(farmer.job_thread and coroutine.status(farmer.job_thread)))
		end
		if crop_count() >= 3 and consumed_total >= 3 then
			assert_true(consumed_types == 1,
				"uniform field consumed multiple seed types: " .. minetest.serialize(deltas))
			local primary = working_villages.crop_planner.get_primary(farmer)
			assert_true(primary and deltas[primary] and deltas[primary] > 0,
				"persisted crop plan does not match the physically planted seed")
			crop_verified = true
			minetest.log("action", "DETERMINISTIC_CROP_RUNTIME_OK:" .. profile
				.. ":seed=" .. primary .. ":crops=" .. crop_count())
			start_construction_probe()
		end
	elseif construction_probe then
		local elapsed = minetest.get_gametime() - construction_started_at
		local encoded = construction_probe.meta:get_string("working_villages_construction_ledger_v1")
		local ledger = encoded ~= "" and minetest.deserialize(encoded) or nil
		local cleared = ledger and ledger.totals and tonumber(ledger.totals.cleared) or 0
		if elapsed >= next_progress then
			next_progress = elapsed + 5
			minetest.log("action", "PUBLIC_BUILDER_PROGRESS:" .. profile
				.. ":elapsed=" .. elapsed .. ":index="
				.. construction_probe.meta:get_int("index") .. ":cleared=" .. cleared
				.. ":action=" .. tostring(builder.disp_action) .. ":state="
				.. tostring(builder.state_info) .. ":in_work="
				.. tostring(builder.job_data and builder.job_data.in_work)
				.. ":marker=" .. minetest.serialize(builder.get_job_data
					and builder:get_job_data("builder_marker"))
				.. ":pos=" .. minetest.pos_to_string(builder.object:get_pos()
					or construction_probe.build_pos)
				.. ":target=" .. minetest.pos_to_string(construction_probe.air_pos)
				.. ":velocity=" .. minetest.pos_to_string(builder.object:get_velocity()
					or vector.zero())
				.. ":thread=" .. tostring(builder.job_thread
					and coroutine.status(builder.job_thread)))
		end
		if minetest.get_node(construction_probe.air_pos).name == "air" and cleared >= 1 then
			assert_true(construction_probe.meta:get_int("index") > 1,
				"builder cleared vegetation without advancing the plan")
			minetest.log("action", "SAFE_CONSTRUCTION_RUNTIME_OK:" .. profile
				.. ":cleared=" .. cleared .. ":index="
				.. construction_probe.meta:get_int("index"))
			finish(true)
			return
		end
		-- Dedicated headless VoxeLibre deliberately coalesces idle server steps
		-- when no player is connected, so coroutine animations advance much more
		-- slowly than in a live public session.
		if elapsed > 70 then
			fail("real builder did not clear the planned interior vegetation")
		end
	end
	schedule(0.2, poll)
end

minetest.after(0, function()
	protected(function()
		started_at = minetest.get_gametime()
		minetest.set_timeofday(0.5)
		prepare_farm()
		create_farmer()
		schedule(0.2, poll)
	end)
end)
