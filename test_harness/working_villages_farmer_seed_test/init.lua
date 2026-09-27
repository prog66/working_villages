-- Real-engine regression for a farmer starting without seeds.
--
-- The harness places only a registered natural grass/fern node whose real
-- drop table can yield a registered crop seed. A real farmer entity receives
-- one real hoe, but no seed, food or crop. The production on_step/job
-- coroutine must dig the vegetation, acquire a seed through node_dig, till a
-- dirt node and sow the acquired seed. No job function is called directly.

local OWNER = "working_villages_farmer_seed_test_owner"
local JOB = "working_villages:job_farmer"
local ENTITY = "working_villages:villager_female"
local POLL_INTERVAL = 0.05
local TIMEOUT_SECONDS = 150
local POST_SEED_OBSERVE_SECONDS = 120
local PAD_RADIUS = 10
local SOURCE_RADIUS = 8

local profile = working_villages.game_profile
	and working_villages.game_profile.id or "unknown"
local farming = working_villages.farming_compat
	or working_villages.require("farming_compat")
local compat = working_villages.compat

local finished = false
local villager = nil
local source_name = nil
local dirt_name = nil
local source_ground_name = nil
local initial_source_count = 0
local seed_was_observed = false
local observed_seed_name = nil
local observed_seed_peak = 0
local source_was_dug = false
local farmland_was_created = false
local farmland_name = nil
local seed_marker_logged = false
local seed_acquired_at = nil
local next_progress_report = 15

local function fail(message)
	error("[working_villages_farmer_seed_test] " .. tostring(message), 2)
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
		minetest.log("error", "FARMER_SEED_RUNTIME_FAILED:" .. profile .. ":" .. tostring(message))
	end
	minetest.request_shutdown(
		ok and "working_villages farmer seed runtime test completed"
			or "working_villages farmer seed runtime test failed",
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

local seed_names = {}
for _, plant in pairs(farming.get_plants() or {}) do
	for _, item_name in ipairs(plant.replant or {}) do
		if minetest.registered_items[item_name] then
			seed_names[item_name] = true
		end
	end
end

local function is_seed_name(item_name)
	return type(item_name) == "string" and item_name ~= "" and
		(seed_names[item_name] == true or minetest.get_item_group(item_name, "seed") > 0)
end

local function drop_mentions_seed(value, depth)
	depth = depth or 0
	if depth > 8 then
		return false
	end
	if type(value) == "string" then
		return is_seed_name(ItemStack(value):get_name())
	end
	if type(value) ~= "table" then
		return false
	end
	for _, entry in pairs(value) do
		if drop_mentions_seed(entry, depth + 1) then
			return true
		end
	end
	return false
end

local function choose_natural_seed_source()
	local preferred = profile == "voxelibre" and {
		"mcl_flowers:tallgrass",
		"mcl_flowers:fern",
	} or {
		"default:grass_1",
		"default:grass_2",
		"default:grass_3",
		"default:grass_4",
		"default:grass_5",
		"default:junglegrass",
	}
	for _, name in ipairs(preferred) do
		local def = minetest.registered_nodes[name]
		if def and def.buildable_to and drop_mentions_seed(def.drop) then
			return name
		end
	end
	for name, def in pairs(minetest.registered_nodes or {}) do
		local lower = name:lower()
		local natural_name = lower:find("grass", 1, true)
			or lower:find("fern", 1, true)
		if natural_name and def.buildable_to and drop_mentions_seed(def.drop)
				and not farming.is_plant(name) then
			return name
		end
	end
	fail("active game exposes no natural vegetation node with a real seed drop")
end

local function choose_dirt()
	local candidates = {
		compat.get_item("default:dirt"),
		"default:dirt",
		"mcl_core:dirt",
	}
	for _, name in ipairs(candidates) do
		if minetest.registered_nodes[name] and compat.is_tillable_dirt(name) then
			return name
		end
	end
	fail("active game exposes no registered tillable dirt node")
end

local function choose_natural_source_ground()
	local candidates = {
		compat.get_item("default:dirt_with_grass"),
		"default:dirt_with_grass",
		"mcl_core:dirt_with_grass",
		dirt_name,
	}
	for _, name in ipairs(candidates) do
		if minetest.registered_nodes[name] and compat.is_tillable_dirt(name) then
			return name
		end
	end
	fail("active game exposes no valid ground for natural grass")
end

local function choose_stone()
	local candidates = {
		compat.get_item("default:stone"),
		"default:stone",
		"mcl_core:stone",
	}
	for _, name in ipairs(candidates) do
		if minetest.registered_nodes[name] then
			return name
		end
	end
	fail("active game exposes no registered foundation node")
end

local function choose_hoe()
	local candidates = compat.get_tool_items("hoe", {"wood", "stone", "iron"}) or {}
	for _, name in ipairs(candidates) do
		if minetest.registered_items[name]
				and minetest.get_item_group(name, "hoe") > 0 then
			return name
		end
	end
	for _, name in ipairs({
		"mcl_farming:hoe_wood",
		"farming:hoe_wood",
	}) do
		if minetest.registered_items[name] then
			return name
		end
	end
	fail("active game exposes no registered hoe")
end

local function clear_inventory(entity)
	local inventory = entity:get_inventory()
	assert_true(inventory, "real farmer detached inventory is unavailable")
	for list_name, list in pairs(inventory:get_lists() or {}) do
		for index = 1, #list do
			inventory:set_stack(list_name, index, ItemStack())
		end
	end
end

local function inventory_seed_snapshot(entity)
	local counts = {}
	local total = 0
	for _, list in pairs(entity:get_inventory():get_lists() or {}) do
		for _, stack in ipairs(list or {}) do
			local name = stack:get_name()
			if is_seed_name(name) then
				counts[name] = (counts[name] or 0) + stack:get_count()
				total = total + stack:get_count()
			end
		end
	end
	return total, counts
end

local function count_source_nodes()
	local count = 0
	for x = -SOURCE_RADIUS, SOURCE_RADIUS do
		for z = -SOURCE_RADIUS, SOURCE_RADIUS do
			if minetest.get_node({x = x, y = 1, z = z}).name == source_name then
				count = count + 1
			end
		end
	end
	return count
end

local function actual_farmland_node(name)
	if name == dirt_name then
		return false
	end
	-- Both supported games use soil=1 for ordinary dirt/grass and soil>=2
	-- only for cultivated ground. Requiring >=2 prevents grass spread from
	-- masquerading as hoe work.
	return minetest.get_item_group(name, "soil") >= 2
end

local function scan_field()
	local farmland_count = 0
	local crop_count = 0
	local crop_name = nil
	for x = -PAD_RADIUS, PAD_RADIUS do
		for z = -PAD_RADIUS, PAD_RADIUS do
			local below = minetest.get_node({x = x, y = 0, z = z}).name
			if actual_farmland_node(below) then
				farmland_count = farmland_count + 1
				farmland_name = farmland_name or below
			end
			local above = minetest.get_node({x = x, y = 1, z = z}).name
			if above ~= "air" and above ~= source_name
					and (above:find("^farming:") or above:find("^mcl_farming:")) then
				crop_count = crop_count + 1
				crop_name = crop_name or above
			end
		end
	end
	return farmland_count, crop_count, crop_name
end

local function setup_pad()
	dirt_name = choose_dirt()
	source_name = choose_natural_seed_source()
	source_ground_name = choose_natural_source_ground()
	assert_true(compat.is_farmland_node(dirt_name) == false,
		"production compatibility treats raw dirt as farmland: " .. dirt_name)
	assert_true(compat.is_farmland_node(source_ground_name) == false,
		"production compatibility treats natural grass ground as farmland: "
			.. source_ground_name)
	local stone_name = choose_stone()
	minetest.load_area(
		{x = -PAD_RADIUS - 2, y = -2, z = -PAD_RADIUS - 2},
		{x = PAD_RADIUS + 2, y = 5, z = PAD_RADIUS + 2}
	)
	for x = -PAD_RADIUS, PAD_RADIUS do
		for z = -PAD_RADIUS, PAD_RADIUS do
			minetest.set_node({x = x, y = -1, z = z}, {name = stone_name})
			minetest.set_node({x = x, y = 0, z = z}, {name = dirt_name})
			for y = 1, 4 do
				minetest.set_node({x = x, y = y, z = z}, {name = "air"})
			end
		end
	end

	-- Eighty-four genuine grass nodes give the random 1/5 (MTG) or 1/8
	-- (VoxeLibre) drop ample independent attempts without ever creating a seed
	-- item. They are spaced two nodes apart, leaving plenty of empty dirt for
	-- tilling while also putting the first legitimate source within two nodes of
	-- the farmer; this avoids turning a seed-drop test into a long-range path
	-- test.
	for x = -SOURCE_RADIUS, SOURCE_RADIUS, 2 do
		for z = -SOURCE_RADIUS, SOURCE_RADIUS, 2 do
			if x ~= 0 or z ~= 0 then
				minetest.set_node({x = x, y = 0, z = z}, {name = source_ground_name})
				minetest.set_node({x = x, y = 1, z = z}, {name = source_name})
			end
		end
	end
	for _, pos in ipairs({
		{x = 1, y = 1, z = 0},
		{x = -1, y = 1, z = 0},
		{x = 0, y = 1, z = 1},
		{x = 0, y = 1, z = -1},
	}) do
		minetest.set_node({x = pos.x, y = 0, z = pos.z}, {name = source_ground_name})
		minetest.set_node(pos, {name = source_name})
	end
	initial_source_count = count_source_nodes()
	assert_true(initial_source_count >= 80,
		"natural source field is too small: " .. tostring(initial_source_count))
	if minetest.forceload_block then
		-- Negative coordinates occupy neighbouring mapblocks. Keep the whole
		-- field active, not only the block containing the spawn point, so the
		-- real entity scheduler continues while the farmer walks to outer grass.
		for x = -16, 16, 16 do
			for z = -16, 16, 16 do
				minetest.forceload_block({x = x, y = 0, z = z}, true)
			end
		end
	end
	minetest.log("action", "FARMER_SEED_SOURCE_SELECTED:" .. profile .. ":"
		.. source_name .. ":" .. tostring(initial_source_count)
		.. ":ground=" .. source_ground_name)
end

local function create_farmer()
	local object = minetest.add_entity({x = 0, y = 1, z = 0}, ENTITY)
	assert_true(object, "could not create the real farmer entity")
	villager = object:get_luaentity()
	assert_true(villager, "created farmer has no Lua entity state")
	clear_inventory(villager)
	villager.owner_name = OWNER
	villager.nametag = "Autonomous seed farmer"
	object:set_nametag_attributes({text = villager.nametag})
	working_villages.needs.set(villager, "hunger", 100)
	working_villages.needs.set(villager, "energy", 100)
	villager.pos_data = villager.pos_data or {}
	villager.pos_data.job_pos = {x = 0, y = 1, z = 0}
	local changed, reason = villager:change_job(JOB)
	assert_true(changed, "could not assign farmer job: " .. tostring(reason))
	local hoe_name = choose_hoe()
	local leftover = villager:add_item_to_main(ItemStack(hoe_name))
	assert_true(leftover:is_empty(), "could not give the real hoe to the farmer")
	local seed_total = inventory_seed_snapshot(villager)
	assert_true(seed_total == 0, "farmer unexpectedly starts with a seed")
	local farmland_count, crop_count = scan_field()
	assert_true(farmland_count == 0, "test pad unexpectedly starts with farmland")
	assert_true(crop_count == 0, "test pad unexpectedly starts with a crop")
	minetest.log("action", "FARMER_SEED_ZERO_INJECTION_OK:" .. profile .. ":" .. hoe_name)
end

local started_at = nil
local function poll()
	assert_true(villager and villager.object and villager.object:get_pos(),
		"real farmer became unavailable before completing the scenario")
	assert_true(villager:get_job_name() == JOB,
		"real farmer changed profession during seed acquisition")
	assert_true(villager.pause ~= true,
		"real farmer paused during seed acquisition: "
			.. tostring(villager.job_data and villager.job_data.pause_reason))

	local remaining_sources = count_source_nodes()
	if remaining_sources < initial_source_count then
		source_was_dug = true
	end
	local seed_total, counts = inventory_seed_snapshot(villager)
	if seed_total > 0 then
		seed_was_observed = true
		observed_seed_peak = math.max(observed_seed_peak, seed_total)
		if not observed_seed_name then
			observed_seed_name = next(counts)
		end
	end
	local farmland_count, crop_count, crop_name = scan_field()
	if farmland_count > 0 then
		farmland_was_created = true
	end
	local elapsed = minetest.get_us_time() / 1000000 - started_at
	if elapsed >= next_progress_report then
		local current_pos = villager.object:get_pos()
		local velocity = villager.object:get_velocity() or {x = 0, y = 0, z = 0}
		local destination = villager.destination
		local path_count = type(villager.path) == "table" and #villager.path or 0
		minetest.log("action", ("FARMER_SEED_PROGRESS:%s:t=%.0f:pos=%s:dest=%s:"
			.. "path=%d:velocity=%.2f,%.2f,%.2f:sources=%d:seed=%d:soil=%d:action=%s:"
			.. "search=%.1f:seed_search=%.1f:expand=%.1f:thread=%s:wield=%s")
			:format(profile, elapsed, minetest.pos_to_string(current_pos),
				destination and minetest.pos_to_string(destination) or "nil",
				path_count, velocity.x or 0, velocity.y or 0, velocity.z or 0,
				remaining_sources, seed_total, farmland_count,
				tostring(villager.disp_action), villager:get_timer("farmer:search"),
				villager:get_timer("farmer:seed_search"),
				villager:get_timer("farmer:expand_farm"),
				villager.job_thread and coroutine.status(villager.job_thread) or "nil",
				villager:get_wield_item_stack():get_name()))
		next_progress_report = next_progress_report + 15
	end
	if seed_was_observed and source_was_dug and not seed_marker_logged then
		seed_marker_logged = true
		seed_acquired_at = elapsed
		minetest.log("action", "FARMER_NATURAL_SEED_ACQUIRED_OK:" .. profile .. ":"
			.. tostring(observed_seed_name) .. ":peak=" .. tostring(observed_seed_peak)
			.. ":sources_dug=" .. tostring(initial_source_count - remaining_sources))
	end

	if seed_marker_logged and farmland_was_created and crop_count > 0 then
		minetest.log("action", "FARMER_AUTONOMOUS_TILL_OK:" .. profile .. ":"
			.. tostring(farmland_name) .. ":count=" .. tostring(farmland_count))
		minetest.log("action", "FARMER_AUTONOMOUS_SOW_OK:" .. profile .. ":"
			.. tostring(crop_name) .. ":count=" .. tostring(crop_count))
		minetest.log("action", "FARMER_SEED_RUNTIME_OK:" .. profile)
		finish(true)
		return
	end
	if seed_marker_logged and elapsed - seed_acquired_at >= POST_SEED_OBSERVE_SECONDS then
		fail("seed acquired but real sowing was not reached; farmland="
			.. tostring(farmland_count) .. " seed_now=" .. tostring(seed_total)
			.. " action=" .. tostring(villager.disp_action))
	end

	if elapsed >= TIMEOUT_SECONDS then
		local current_pos = villager.object:get_pos()
		local destination = villager.destination
		local path_count = type(villager.path) == "table" and #villager.path or 0
		fail(("timeout after %.1fs; seed_seen=%s seed_peak=%d source_dug=%s "
			.. "sources_remaining=%d farmland_seen=%s farmland_now=%d crops=%d "
			.. "action=%s state=%s pos=%s destination=%s path=%d"):format(
			elapsed, tostring(seed_was_observed), observed_seed_peak,
			tostring(source_was_dug), remaining_sources,
			tostring(farmland_was_created), farmland_count, crop_count,
			tostring(villager.disp_action), tostring(villager.state_info),
			minetest.pos_to_string(current_pos),
			destination and minetest.pos_to_string(destination) or "nil", path_count))
	end
	schedule(POLL_INTERVAL, poll)
end

local function begin_scenario()
	setup_pad()
	create_farmer()
	started_at = minetest.get_us_time() / 1000000
	schedule(POLL_INTERVAL, poll)
end

schedule(0, function()
	assert_true(profile == "voxelibre" or profile == "minetest_game",
		"unsupported active game profile: " .. tostring(profile))
	minetest.set_timeofday(0.5)
	-- A fresh VoxeLibre world may still be generating neighbouring mapblocks
	-- after server start. Setting the field before that finishes lets mapgen
	-- overwrite natural sources and falsely count them as farmer digs. Emerge
	-- the complete pad first, then create every test node on the main thread.
	if minetest.emerge_area then
		local started = false
		minetest.emerge_area(
			{x = -PAD_RADIUS - 2, y = -2, z = -PAD_RADIUS - 2},
			{x = PAD_RADIUS + 2, y = 5, z = PAD_RADIUS + 2},
			function(_, _, remaining)
				if remaining == 0 and not started then
					started = true
					schedule(0, begin_scenario)
				end
			end
		)
	else
		begin_scenario()
	end
end)
