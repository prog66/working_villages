local OWNER = "working_villages_native_combat_owner"
local ENTITY = "working_villages:villager_male"
local JOB = "working_villages:job_guard"
local DURATION_SECONDS = 60
local REQUIRED_KILLS = 3
local POLL_SECONDS = 0.25
local MAX_STALL_SECONDS = 15

local finished = false
local started_at
local guard
local guard_identity
local native_target
local native_name
local native_hp
local native_spawned_at
local last_progress_at
local combat_completed_at
local kills = 0
local waves = 0
local damage_taken = 0
local minimum_guard_hp

local function fail(message)
	if finished then return end
	finished = true
	minetest.log("error", "WORKING_VILLAGES_NATIVE_COMBAT_FAILED:"
		.. tostring(message))
	minetest.request_shutdown("working_villages native combat test failed", false, 0)
end

local function assert_true(value, message)
	if not value then error(message or "expected truthy value", 2) end
end

local function choose_registered(candidates, registry)
	for _, name in ipairs(candidates) do
		if registry[name] then return name end
	end
	return nil
end

local function setup_pad()
	local stone = working_villages.compat.get_item("default:stone")
	assert_true(minetest.registered_nodes[stone], "no registered stone for arena")
	minetest.load_area({x = -16, y = -2, z = -16}, {x = 16, y = 5, z = 16})
	for x = -14, 14 do
		for z = -14, 14 do
			minetest.set_node({x = x, y = 0, z = z}, {name = stone})
			for y = 1, 4 do
				minetest.set_node({x = x, y = y, z = z}, {name = "air"})
			end
		end
	end
	-- A headless server has no player keeping this arena active. Keep the exact
	-- four mapblocks used by the fight loaded so native mobs and villagers run
	-- through their real engine callbacks for the whole minute.
	if minetest.forceload_block then
		for x = -16, 0, 16 do
			for z = -16, 0, 16 do
				assert_true(minetest.forceload_block({x = x, y = 0, z = z}, true),
					"could not forceload native combat arena")
			end
		end
	end
end

local function add_equipment(villager)
	local inventory = assert(villager:get_inventory())
	local sword = choose_registered({
		"mcl_tools:sword_iron", "mcl_tools:sword_stone", "default:sword_steel",
		"default:sword_stone",
	}, minetest.registered_items)
	assert_true(sword, "no registered survival sword")
	assert_true(inventory:add_item("main", ItemStack(sword)):is_empty(),
		"could not provision combat sword")
	villager:equip_best_weapon()

	local armor = {
		"mcl_armor:helmet_iron", "mcl_armor:chestplate_iron",
		"mcl_armor:leggings_iron", "mcl_armor:boots_iron",
	}
	for _, item_name in ipairs(armor) do
		if minetest.registered_items[item_name] then
			assert_true(inventory:add_item("main", ItemStack(item_name)):is_empty(),
				"could not provision " .. item_name)
		end
	end
	if villager.equip_best_armor then villager:equip_best_armor() end
	return sword
end

local function choose_native_monster()
	return choose_registered({
		"mobs_mc:zombie", "mobs_mc:husk", "mobs_mc:skeleton",
		"mobs_mc:spider", "mobs_mc:vindicator",
	}, minetest.registered_entities)
end

local function spawn_wave()
	if native_target and native_target:get_pos() then native_target:remove() end
	local guard_pos = guard.object:get_pos()
	local angle = (waves % 4) * math.pi / 2
	local pos = {
		x = guard_pos.x + math.cos(angle) * 3,
		y = 1,
		z = guard_pos.z + math.sin(angle) * 3,
	}
	native_target = minetest.add_entity(pos, native_name)
	assert_true(native_target, "could not spawn native monster " .. native_name)
	native_target:set_hp(math.max(12, native_target:get_hp()))
	local lua = native_target:get_luaentity()
	assert_true(lua and (lua.type == "monster" or lua.spawn_class == "hostile"),
		"selected native entity is not hostile: " .. native_name)
	assert_true(guard:is_enemy(native_target),
		"guard does not recognize native monster " .. native_name)
	waves = waves + 1
	native_hp = native_target:get_hp()
	native_spawned_at = minetest.get_us_time() / 1000000
	last_progress_at = native_spawned_at
	minetest.log("action", "NATIVE_COMBAT_WAVE_STARTED:" .. waves
		.. ":" .. native_name .. ":hp=" .. native_hp)
end

local function poll()
	if finished then return end
	local ok, err = xpcall(function()
		assert_true(guard and guard.object and guard.object:get_pos(),
			"guard disappeared during combat")
		assert_true(guard:get_job_name() == JOB, "guard changed profession during combat")
		assert_true(guard.inventory_name == guard_identity,
			"guard identity changed during combat")
		assert_true(guard.pause ~= true, "guard profession paused during combat")
		local now = minetest.get_us_time() / 1000000
		local guard_hp = guard.object:get_hp()
		assert_true(guard_hp > 0, "guard died during native combat")
		if guard_hp < minimum_guard_hp then
			damage_taken = damage_taken + (minimum_guard_hp - guard_hp)
			minimum_guard_hp = guard_hp
			last_progress_at = now
		end

		if kills >= REQUIRED_KILLS then
			-- Three consecutive native fights are enough to prove sustained combat.
			-- Leave the surviving guard active until the one-minute boundary so its
			-- danger cleanup and low-health policy still run without feeding it an
			-- endless synthetic stream of fresh enemies.
			if native_target and native_target:get_pos() then native_target:remove() end
			native_target = nil
		elseif not native_target or not native_target:get_pos() or native_target:get_hp() <= 0 then
			kills = kills + 1
			last_progress_at = now
			minetest.log("action", "NATIVE_COMBAT_WAVE_DEFEATED:" .. kills)
			if kills < REQUIRED_KILLS then
				spawn_wave()
			else
				native_target = nil
				combat_completed_at = now
			end
		else
			local current_hp = native_target:get_hp()
			if current_hp < native_hp then
				last_progress_at = now
				native_hp = current_hp
			end
			assert_true(now - last_progress_at <= MAX_STALL_SECONDS,
				"combat made no damage progress for " .. MAX_STALL_SECONDS .. " seconds")
		end

		local elapsed = now - started_at
		if elapsed >= DURATION_SECONDS and kills >= REQUIRED_KILLS and damage_taken > 0 then
			finished = true
			minetest.log("action", "WORKING_VILLAGES_NATIVE_COMBAT_OK:"
				.. working_villages.game_profile.id
				.. ":duration=" .. math.floor(elapsed)
				.. ":native=" .. native_name
				.. ":waves=" .. waves
				.. ":kills=" .. kills
				.. ":damage_taken=" .. damage_taken
				.. ":post_combat=" .. math.floor(now - (combat_completed_at or now))
				.. ":guard_hp=" .. guard_hp)
			minetest.request_shutdown("working_villages native combat test completed", false, 0)
			return
		end
		assert_true(elapsed < 150,
			"combat did not meet duration, kill and incoming-damage requirements")
		minetest.after(POLL_SECONDS, poll)
	end, debug.traceback)
	if not ok then fail(err) end
end

minetest.after(0, function()
	local ok, err = xpcall(function()
		assert_true(working_villages.game_profile.id == "voxelibre",
			"native combat harness currently requires VoxeLibre")
		native_name = choose_native_monster()
		assert_true(native_name, "no supported registered VoxeLibre monster")
		minetest.set_timeofday(0.8)
		setup_pad()
		local object = minetest.add_entity({x = 0, y = 1, z = 0}, ENTITY)
		assert_true(object, "could not spawn guard")
		guard = assert(object:get_luaentity())
		guard.owner_name = OWNER
		working_villages.needs.set(guard, "hunger", 100)
		working_villages.needs.set(guard, "energy", 100)
		local changed, reason = guard:change_job(JOB)
		assert_true(changed, "could not assign guard: " .. tostring(reason))
		assert_true(type(guard.job_thread) == "thread", "guard has no profession coroutine")
		guard_identity = guard.inventory_name
		assert_true(type(guard_identity) == "string" and guard_identity ~= "",
			"guard has no persistent identity")
		add_equipment(guard)
		guard._survival_activated_at = minetest.get_us_time() / 1000000 - 30
		minimum_guard_hp = guard.object:get_hp()
		started_at = minetest.get_us_time() / 1000000
		last_progress_at = started_at
		spawn_wave()
		minetest.after(POLL_SECONDS, poll)
	end, debug.traceback)
	if not ok then fail(err) end
end)

