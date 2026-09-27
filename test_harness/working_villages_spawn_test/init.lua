-- Engine-only three-run test for real initial entity spawning and durability.
-- Use exclusively in a disposable world with a fixed initial owner.

local OWNER = "working_villages_spawn_test_owner"
local EXPECTED_JOBS = {
	["working_villages:job_woodcutter"] = 1,
	["working_villages:job_farmer"] = 1,
	["working_villages:job_autonome"] = 1,
	["working_villages:job_miner"] = 1,
	["working_villages:job_builder"] = 1,
}
local storage = minetest.get_mod_storage()
local instance_state_verified = false
local removal_started = false
local removal_forceloaded = false
local PAD_GROUND_Y = 200

-- Keep the engine test surface outside ordinary terrain so late mapgen cannot
-- overwrite the fixture between readiness and the delayed production scan.
minetest.settings:set("static_spawnpoint", "(0,201,0)")

-- A headless empty world has no emerged terrain without a player. Build a
-- small disposable test pad only after emergence has completed; writing nodes
-- while the mapblock is still `ignore` is a race on a genuinely new world.
local pad_ready = false

local function build_test_pad(attempt)
	if pad_ready then
		return
	end
	attempt = tonumber(attempt) or 1
	local minp = {x = -8, y = PAD_GROUND_Y - 2, z = -8}
	local maxp = {x = 8, y = PAD_GROUND_Y + 4, z = 8}
	minetest.load_area(minp, maxp)
	local ground_name = working_villages.compat.get_item("default:stone")
	for x = -8, 8 do
		for z = -8, 8 do
			minetest.set_node({x = x, y = PAD_GROUND_Y, z = z}, {name = ground_name})
			for y = PAD_GROUND_Y + 1, PAD_GROUND_Y + 3 do
				minetest.set_node({x = x, y = y, z = z}, {name = "air"})
			end
		end
	end
	local ground = minetest.get_node_or_nil({x = 0, y = PAD_GROUND_Y, z = 0})
	local headroom = minetest.get_node_or_nil({x = 0, y = PAD_GROUND_Y + 1, z = 0})
	if not ground or ground.name ~= ground_name or not headroom or headroom.name ~= "air" then
		if attempt >= 120 then
			error("[working_villages_spawn_test] test pad did not become writable after emergence", 2)
		end
		minetest.after(0.25, function()
			build_test_pad(attempt + 1)
		end)
		return
	end
	pad_ready = true
	minetest.log("action", "WORKING_VILLAGES_SPAWN_PAD_READY")
end

minetest.after(0, function()
	local minp = {x = -8, y = PAD_GROUND_Y - 2, z = -8}
	local maxp = {x = 8, y = PAD_GROUND_Y + 4, z = 8}
	if minetest.emerge_area then
		local completed = false
		minetest.emerge_area(minp, maxp, function(_, _, remaining)
			if not completed and (tonumber(remaining) or 0) == 0 then
				completed = true
				minetest.after(0, function()
					build_test_pad(1)
				end)
			end
		end)
	else
		minetest.load_area(minp, maxp)
		build_test_pad(1)
	end
end)

-- Fallback for games whose initial mapgen does not dispatch the emergence
-- callback before the first server steps. The readiness check makes this
-- idempotent if the callback already built the pad.
minetest.after(1, function()
	build_test_pad(1)
end)

local function fail(message)
	error("[working_villages_spawn_test] " .. message, 2)
end

local function sorted_owner_snapshot()
	local ids = {}
	local jobs = {}
	for inventory_name, record in pairs(working_villages.population.snapshot()) do
		if record.owner_name == OWNER then
			ids[#ids + 1] = inventory_name
			jobs[record.job_name or ""] = (jobs[record.job_name or ""] or 0) + 1
		end
	end
	table.sort(ids)
	return ids, jobs
end

local function same_array(left, right)
	if type(left) ~= "table" or #left ~= #right then
		return false
	end
	for index, value in ipairs(left) do
		if right[index] ~= value then
			return false
		end
	end
	return true
end

local function assert_initial_slot_state(ids)
	local state = working_villages._initial_spawn_state_snapshot()
	if type(state) ~= "table" or state.version ~= 3 then
		fail("initial slot state was not migrated to version 3")
	end
	if not state.completed or working_villages.spawn_state.count_spawned(state) ~= 5 then
		fail("initial slot state is not exactly complete")
	end
	local expected = {}
	for _, identity in ipairs(ids) do
		expected[identity] = true
	end
	local seen = {}
	for index = 1, 5 do
		local identity = state.slot_ids[index]
		if type(identity) ~= "string" or identity == "" then
			fail("initial slot " .. index .. " has no persistent identity")
		end
		if seen[identity] then
			fail("persistent identity occupies two initial slots: " .. identity)
		end
		if not expected[identity] then
			fail("initial slot references an unexpected villager: " .. identity)
		end
		local pos = state.slot_positions[index]
		if type(pos) ~= "table" or type(pos.x) ~= "number"
				or type(pos.y) ~= "number" or type(pos.z) ~= "number" then
			fail("initial slot " .. index .. " has no reconciliation position")
		end
		seen[identity] = true
	end
	return state
end

local function assert_dummy_entities_are_transient()
	local names = {
		"working_villages:dummy_item",
		"working_villages:dummy_offhand",
		"working_villages:dummy_head",
		"working_villages:dummy_armor_head",
		"working_villages:dummy_armor_torso",
		"working_villages:dummy_armor_legs",
		"working_villages:dummy_armor_feet",
	}
	for _, name in ipairs(names) do
		local def = minetest.registered_entities[name]
		if not def or not def.initial_properties
				or def.initial_properties.static_save ~= false then
			fail("dummy equipment entity is persistable: " .. name)
		end
	end
end

local function loaded_owner_entity(identity)
	for _, entity in pairs(minetest.luaentities or {}) do
		if entity and working_villages.is_villager(entity.name)
				and entity.owner_name == OWNER and entity.inventory_name == identity then
			return entity
		end
	end
	return nil
end

local function poll_exact_replacement(attempt)
	local ids, jobs = sorted_owner_snapshot()
	if #ids == 5 then
		local removed_id = storage:get_string("removed_id")
		local survivors = minetest.deserialize(storage:get_string("survivor_ids")) or {}
		local present = {}
		for _, identity in ipairs(ids) do
			present[identity] = true
		end
		if not present[removed_id] then
			for _, identity in ipairs(survivors) do
				if not present[identity] then
					fail("real removal replaced more than one initial villager")
				end
			end
			for job_name, expected in pairs(EXPECTED_JOBS) do
				if jobs[job_name] ~= expected then
					fail("replacement changed initial role count for " .. job_name)
				end
			end
			local state = assert_initial_slot_state(ids)
			local removed_slot = storage:get_int("removed_slot")
			if state.slot_ids[removed_slot] == removed_id then
				fail("removed identity still owns its initial slot")
			end
			local replacement = loaded_owner_entity(state.slot_ids[removed_slot])
			if replacement and replacement.initial_spawn_slot ~= removed_slot then
				fail("replacement entity is not tied back to the released slot")
			end
			storage:set_string("replacement_ids", minetest.serialize(ids))
			storage:set_int("phase", 2)
			minetest.log("action", "WORKING_VILLAGES_SPAWN_DURABILITY_OK:replacement:5")
			minetest.request_shutdown("working_villages replacement phase completed", false, 0)
			return
		end
	end
	if attempt >= 120 then
		fail("timed out waiting for one exact initial-slot replacement")
	end
	minetest.after(0.25, function()
		poll_exact_replacement(attempt + 1)
	end)
end

local function remove_one_initial_entity(ids, activation_attempt)
	if removal_started then
		return
	end
	activation_attempt = activation_attempt or 1
	local state = assert_initial_slot_state(ids)
	local removed_slot = 3
	local removed_id = state.slot_ids[removed_slot]
	local entity = loaded_owner_entity(removed_id)
	if not entity or not entity.object or not entity.object:get_pos() then
		local pos = state.slot_positions[removed_slot]
		if pos and not removal_forceloaded and minetest.forceload_block then
			local ok, held = pcall(minetest.forceload_block, pos, true)
			if not ok or held == false then
				fail("could not activate selected initial villager block")
			end
			removal_forceloaded = true
		end
		if activation_attempt >= 120 then
			fail("selected initial villager did not activate for real removal")
		end
		minetest.after(0.25, function()
			remove_one_initial_entity(ids, activation_attempt + 1)
		end)
		return
	end
	local survivors = {}
	for _, identity in ipairs(ids) do
		if identity ~= removed_id then
			survivors[#survivors + 1] = identity
		end
	end
	storage:set_string("removed_id", removed_id)
	storage:set_int("removed_slot", removed_slot)
	storage:set_string("survivor_ids", minetest.serialize(survivors))
	removal_started = true
	entity.object:remove()
	if removal_forceloaded and minetest.forceload_free_block then
		minetest.forceload_free_block(state.slot_positions[removed_slot], true)
		removal_forceloaded = false
	end
	minetest.after(0.25, function()
		poll_exact_replacement(1)
	end)
end

local function try_instance_owned_state()
	local villagers = {}
	for _, entity in pairs(minetest.luaentities or {}) do
		if entity and working_villages.is_villager(entity.name)
				and entity.owner_name == OWNER then
			villagers[#villagers + 1] = entity
		end
	end
	if #villagers ~= 5 then
		return false
	end
	local mutable_fields = {
		"time_counters", "job_data", "pos_data", "destination", "needs", "memory",
	}
	for _, field in ipairs(mutable_fields) do
		local seen = {}
		for _, villager in ipairs(villagers) do
			local value = villager[field]
			if type(value) ~= "table" then
				fail("missing instance table " .. field .. " on " .. tostring(villager.inventory_name))
			end
			if seen[value] then
				fail("shared mutable table " .. field .. " between villager instances")
			end
			seen[value] = true
		end
	end
	for _, villager in ipairs(villagers) do
		local job_pos = villager.pos_data and villager.pos_data.job_pos or nil
		if type(job_pos) ~= "table" or type(job_pos.x) ~= "number"
				or type(job_pos.y) ~= "number" or type(job_pos.z) ~= "number" then
			fail("initial villager has no persistent job anchor: "
				.. tostring(villager.inventory_name))
		end
	end
	instance_state_verified = true
	minetest.log("action", "WORKING_VILLAGES_INITIAL_JOB_ANCHOR_OK:5")
	minetest.log("action", "WORKING_VILLAGES_INSTANCE_STATE_OK:5")
	return true
end

-- In a headless world there is no player keeping entities active. Poll shortly
-- after the production spawn, while all five are loaded, instead of assuming
-- they will still be active at the later persistence assertion.
local function poll_instance_state(attempt)
	if instance_state_verified or try_instance_owned_state() then
		return
	end
	if attempt < 160 then
		minetest.after(0.25, function()
			poll_instance_state(attempt + 1)
		end)
	end
end

minetest.after(5.25, function()
	poll_instance_state(1)
end)

local function verify_phase(attempt)
	local ids, jobs = sorted_owner_snapshot()
	if #ids ~= 5 then
		if attempt < 120 then
			minetest.after(0.25, function()
				verify_phase(attempt + 1)
			end)
			return
		end
		fail("expected exactly five persistent villagers, got " .. #ids)
	end
	for job_name, expected in pairs(EXPECTED_JOBS) do
		if jobs[job_name] ~= expected then
			fail("initial role mismatch for " .. job_name .. ": got " ..
				tostring(jobs[job_name]) .. ", expected " .. expected)
		end
	end
	local phase = storage:get_int("phase")
	if phase == 0 then
		if not instance_state_verified then
			fail("could not observe five simultaneously loaded villagers for instance-state check")
		end
		storage:set_string("initial_ids", minetest.serialize(ids))
		storage:set_int("phase", 1)
		assert_initial_slot_state(ids)
		assert_dummy_entities_are_transient()
		minetest.log("action", "WORKING_VILLAGES_INITIAL_SLOT_IDENTITY_OK:5")
		minetest.log("action", "WORKING_VILLAGES_SPAWN_OK:created:5")
		minetest.request_shutdown("working_villages spawn creation phase completed", false, 0)
	elseif phase == 1 then
		local previous = minetest.deserialize(storage:get_string("initial_ids"))
		if not same_array(previous, ids) then
			fail("villager identities changed or duplicated after restart")
		end
		minetest.log("action", "WORKING_VILLAGES_SPAWN_OK:reloaded:5")
		minetest.log("action", "WORKING_VILLAGES_SPAWN_DURABILITY_OK:unload_reload:5")
		remove_one_initial_entity(ids)
	else
		local replacement_ids = minetest.deserialize(storage:get_string("replacement_ids"))
		if not same_array(replacement_ids, ids) then
			fail("replacement identities changed or duplicated after final restart")
		end
		assert_initial_slot_state(ids)
		minetest.log("action", "WORKING_VILLAGES_SPAWN_DURABILITY_OK:restart:5")
		minetest.request_shutdown("working_villages spawn durability test completed", false, 0)
	end
end

minetest.after(14, function()
	verify_phase(1)
end)
