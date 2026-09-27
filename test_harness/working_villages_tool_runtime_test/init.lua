-- Engine-only regression for the real miner coroutine.  It verifies the
-- player-visible failure mode: no pickaxe must trigger useful waiting without
-- pausing or changing profession, and a later real pickaxe must be equipped.

local OWNER = "working_villages_tool_runtime_test_owner"
local JOB = "working_villages:job_miner"
local ENTITY = "working_villages:villager_male"
local HOSTILE = "working_villages_tool_runtime_test:hostile"
local EMBEDDING_JOB = "working_villages_tool_runtime_test:embedding_job"

minetest.register_entity(HOSTILE, {
	initial_properties = {
		physical = false,
		pointable = false,
		visual = "sprite",
		textures = {"blank.png"},
		static_save = false,
	},
	spawn_class = "hostile",
	type = "monster",
	attack_npcs = true,
})

working_villages.register_job(EMBEDDING_JOB, {
	description = "Embedding recovery probe",
	inventory_image = "blank.png",
	jobfunc = function(self)
		while true do
			self.job_data.embedding_test_resumes =
				(self.job_data.embedding_test_resumes or 0) + 1
			coroutine.yield("embedding_test_step")
		end
	end,
})

local function fail(message)
	error("[working_villages_tool_runtime_test] " .. message, 2)
end

local function assert_true(value, message)
	if not value then
		fail(message or "expected a truthy value")
	end
end

local function count_tools(inv, group)
	local total = 0
	for _, listname in ipairs({"main", "wield_item"}) do
		for _, stack in ipairs(inv:get_list(listname) or {}) do
			if not stack:is_empty() and minetest.get_item_group(stack:get_name(), group) > 0 then
				total = total + stack:get_count()
			end
		end
	end
	return total
end

local function choose_pickaxe()
	local candidates = working_villages.compat.get_tool_items(
		"pickaxe", {"iron", "stone", "wood"})
	for _, name in ipairs(candidates) do
		if minetest.registered_items[name]
				and minetest.get_item_group(name, "pickaxe") > 0 then
			return name
		end
	end
	fail("the active game exposes no registered pickaxe candidate")
end

local function setup_pad()
	local stone = working_villages.compat.get_item("default:stone")
	assert_true(minetest.registered_nodes[stone], "test ground node is not registered")
	minetest.load_area({x = -10, y = -2, z = -10}, {x = 10, y = 5, z = 10})
	for x = -10, 10 do
		for z = -10, 10 do
			minetest.set_node({x = x, y = 0, z = z}, {name = stone})
			for y = 1, 4 do
				minetest.set_node({x = x, y = y, z = z}, {name = "air"})
			end
		end
	end
end

local function step_real_entity(villager, count)
	for _ = 1, count do
		assert_true(villager.object and villager.object:get_pos(),
			"real miner became unavailable during a manual engine step")
		villager.on_step(villager, 0.1)
	end
end

local function inventory_snapshot(inv)
	local names = {}
	for listname in pairs(inv:get_lists()) do
		names[#names + 1] = listname
	end
	table.sort(names)
	local parts = {}
	for _, listname in ipairs(names) do
		parts[#parts + 1] = listname .. "="
		for index, stack in ipairs(inv:get_list(listname) or {}) do
			parts[#parts + 1] = index .. ":" .. stack:to_string() .. ";"
		end
	end
	return table.concat(parts)
end

local function assert_near(actual, expected, tolerance, message)
	assert_true(math.abs(actual - expected) <= tolerance,
		(message or "values differ") .. ": expected=" .. expected
			.. " actual=" .. actual)
end

local function fill_embedding_volume(stone, center_x)
	for x = center_x - 1, center_x + 1 do
		for z = -1, 1 do
			for y = 1, 2 do
				minetest.set_node({x = x, y = y, z = z}, {name = stone})
			end
		end
	end
end

local function make_underground_cavity(stone)
	minetest.load_area({x = -8, y = -4, z = -2}, {x = -4, y = 1, z = 2})
	for x = -7, -5 do
		for z = -1, 1 do
			for y = -3, 0 do
				minetest.set_node({x = x, y = y, z = z}, {name = stone})
			end
		end
	end
	minetest.set_node({x = -6, y = -2, z = 0}, {name = "air"})
	minetest.set_node({x = -6, y = -1, z = 0}, {name = "air"})
end

minetest.after(0, function()
	local ok, err = xpcall(function()
		minetest.set_timeofday(0.5)
		setup_pad()
		local object = minetest.add_entity({x = 0, y = 1, z = 0}, ENTITY)
		assert_true(object, "could not create the real villager entity")
		local villager = object:get_luaentity()
		assert_true(villager, "created entity has no Lua state")
		villager.owner_name = OWNER
		working_villages.needs.set(villager, "hunger", 100)
		working_villages.needs.set(villager, "energy", 100)
		local changed, reason = villager:change_job(JOB)
		assert_true(changed, "could not assign miner job: " .. tostring(reason))
		local suspended_job_thread = villager.job_thread
		assert_true(type(suspended_job_thread) == "thread"
				and coroutine.status(suspended_job_thread) == "suspended",
			"assigned miner has no suspended profession coroutine")
		local inventory = villager:get_inventory()
		assert_true(inventory and count_tools(inventory, "pickaxe") == 0,
			"new miner unexpectedly owns a pickaxe")

		-- Exercise the exact production crash path from the engine callback:
		-- on_step -> emergency retreat -> go_to.  It must steer away immediately
		-- without yielding or disturbing the suspended miner coroutine.
		local hostile = minetest.add_entity({x = 4, y = 1, z = 0}, HOSTILE)
		assert_true(hostile and villager:is_enemy(hostile),
			"runtime hostile is not recognized as an enemy")
		assert_true(villager:get_nearest_enemy(8) == hostile,
			"runtime hostile is not the nearest enemy")
		assert_true(villager:get_nearest_enemy(2) == nil,
			"runtime hostile is close enough to trigger combat instead of flight")
		assert_true(villager:get_emergency_shelter_pos() == nil,
			"runtime retreat unexpectedly found a shelter")

		-- Exercise the real ObjectRef punch path. A newly activated villager is
		-- protected while its AI comes online; after that window the production
		-- callback must suppress engine damage and apply the configured reduction
		-- itself. This catches the old fatal-hit-before-armor race.
		local maximum_hp = villager.object:get_properties().hp_max
		local initial_hp = villager.object:get_hp()
		assert_true(maximum_hp == 60 and initial_hp == 60,
			"public-server health multiplier was not applied to the real entity")
		local punch_caps = {
			full_punch_interval = 1,
			damage_groups = {fleshy = 10},
		}
		villager.object:punch(hostile, 1, punch_caps, {x = -1, y = 0, z = 0})
		assert_true(villager.object:get_hp() == initial_hp,
			"activation protection did not prevent an immediate real punch")
		villager._survival_activated_at = minetest.get_us_time() / 1000000 - 20
		villager.object:punch(hostile, 1, punch_caps, {x = -1, y = 0, z = 0})
		assert_true(villager.object:get_hp() == initial_hp - 5,
			"real punch did not apply exactly the configured 0.5 damage multiplier")
		assert_true(villager.job_data.danger_ticks >= 200,
			"real punch did not trigger immediate danger response")
		local unauthorized_player = {
			is_player = function() return true end,
			get_player_name = function() return "not_the_owner" end,
			get_pos = function() return {x = 1, y = 1, z = 0} end,
		}
		local denied = villager.on_punch(villager, unauthorized_player, 1,
			punch_caps, {x = -1, y = 0, z = 0}, 10)
		assert_true(denied == true and villager.object:get_hp() == initial_hp - 5,
			"owner_only policy allowed an unauthorized player to hurt the villager")
		minetest.log("action", "PUBLIC_SERVER_SURVIVAL_RUNTIME_OK:"
			.. working_villages.game_profile.id
			.. ":hp=" .. maximum_hp .. ":real_damage=5:unauthorized=blocked")
		villager.object:set_hp(initial_hp)
		villager.job_data.danger_ticks = 2
		local retreat_ok, retreat_error = xpcall(function()
			villager.on_step(villager, 0.1)
		end, debug.traceback)
		assert_true(retreat_ok,
			"emergency retreat crashed in real on_step: " .. tostring(retreat_error))
		assert_true(villager.job_data.danger_ticks == 1,
			"real emergency branch did not consume one danger step")
		assert_true(villager.disp_action == "fuite",
			"real emergency branch did not expose the flight action")
		local retreat_velocity = villager.object:get_velocity()
		assert_true(retreat_velocity and retreat_velocity.x < -0.1,
			"real emergency branch did not move away from the hostile")
		assert_true(villager:get_job_name() == JOB and villager.pause ~= true,
			"emergency retreat paused or reassigned the miner")
		assert_true(villager.job_thread == suspended_job_thread
				and coroutine.status(suspended_job_thread) == "suspended",
			"emergency retreat resumed or replaced the miner coroutine")
		local retreat_state = villager._step_navigations
			and villager._step_navigations.emergency_retreat
		assert_true(type(retreat_state) == "table"
				and retreat_state.requested.x < villager.object:get_pos().x,
			"emergency retreat did not retain an independent path away from danger")
		villager.on_step(villager, 0.1)
		assert_true(villager.job_data.danger_ticks == 0,
			"real emergency branch did not continue its bounded retreat")
		assert_true(villager._step_navigations
				and villager._step_navigations.emergency_retreat == retreat_state,
			"emergency retreat recreated its path on every engine step")
		assert_true(villager.job_thread == suspended_job_thread
				and coroutine.status(suspended_job_thread) == "suspended",
			"continued retreat resumed or replaced the miner coroutine")
		hostile:remove()
		villager.on_step(villager, 0.1)
		assert_true(not villager._step_navigations
				or villager._step_navigations.emergency_retreat == nil,
			"emergency navigation survived after the danger window")
		minetest.log("action", "EMERGENCY_RETREAT_RUNTIME_OK:"
			.. working_villages.game_profile.id)

		-- A playerless headless world deactivates entities outside a player range.
		-- Step this real registered entity synchronously while it is active. The
		-- production on_step and job coroutine are used without fake inventory or
		-- fake ItemStacks.
		step_real_entity(villager, 40)
		assert_true(villager:get_job_name() == JOB,
			"miner changed profession while waiting for a pickaxe")
		assert_true(villager.pause ~= true,
			"miner entered a global pause while waiting for a pickaxe")
		local state = villager.job_data and villager.job_data.work_fallback
		assert_true(type(state) == "table" and state.key == "miner_pickaxe",
			"real miner did not enter the missing-pickaxe fallback")
		assert_true((state.request_count or 0) == 1,
			"missing-pickaxe request was delayed or duplicated")
		assert_true(count_tools(inventory, "pickaxe") == 0,
			"fallback created a pickaxe without resources")
		assert_true(type(villager.disp_action) == "string"
				and villager.disp_action ~= "inactif\nAucun metier",
			"waiting miner remained visibly inactive")

		local pickaxe = choose_pickaxe()
		local leftover = inventory:add_item("main", ItemStack(pickaxe))
		assert_true(leftover:is_empty(), "could not deliver the test pickaxe")
		assert_true(count_tools(inventory, "pickaxe") == 1,
			"test delivery did not add exactly one pickaxe")

		step_real_entity(villager, 20)
		assert_true(villager:get_job_name() == JOB,
			"miner changed profession after pickaxe delivery")
		assert_true(villager.pause ~= true,
			"miner stayed paused after pickaxe delivery")
		local wield = villager:get_wield_item_stack()
		assert_true(wield and minetest.get_item_group(wield:get_name(), "pickaxe") > 0,
			"delivered pickaxe was not equipped")
		assert_true(villager.job_data.work_fallback == nil,
			"missing-tool fallback was not cleared after delivery")
		local previous = villager.job_data.last_work_fallback
		assert_true(previous and previous.key == "miner_pickaxe"
				and previous.request_count == 1,
			"resolved fallback lost its request accounting")
		assert_true(count_tools(inventory, "pickaxe") == 1,
			"recovery duplicated or destroyed the delivered pickaxe")
		local profile = working_villages.game_profile.id
		minetest.log("action", "TOOL_FALLBACK_RUNTIME_OK:" .. profile)

		-- Being below ground is not an error.  A genuine two-node-high cavity on
		-- solid support must remain a valid miner pose even when an older safe
		-- surface position is cached.
		local stone = working_villages.compat.get_item("default:stone")
		make_underground_cavity(stone)
		villager.object:set_pos({x = -6, y = -2.5, z = 0})
		for _ = 1, 4 do
			villager.on_step(villager, 0.1)
		end
		local underground_pos = villager.object:get_pos()
		assert_near(underground_pos.x, -6, 0.01,
			"valid underground miner cavity triggered horizontal recovery")
		assert_near(underground_pos.y, -2.5, 0.01,
			"valid underground miner cavity triggered vertical recovery")
		assert_true(villager:get_job_name() == JOB,
			"valid underground cavity changed the miner job")
		assert_true(villager._safe_standing_pos
				and math.abs(villager._safe_standing_pos.y + 2.5) <= 0.01,
			"valid underground cavity was not retained as the current safe pose")
		minetest.log("action", "UNDERGROUND_CAVITY_RUNTIME_OK:" .. profile)

		-- Reuse the same real LuaEntity with a deterministic yielding profession.
		-- The physics guard must restore only position/velocity: identity,
		-- inventory, job_data and the exact coroutine object all survive.
		local embedding_job_changed, embedding_job_error =
			villager:change_job(EMBEDDING_JOB)
		assert_true(embedding_job_changed,
			"could not assign embedding probe job: " .. tostring(embedding_job_error))
		villager.object:set_pos({x = 0, y = 0.5, z = 0})
		villager.object:set_velocity({x = 0, y = 0, z = 0})
		villager.on_step(villager, 0.1)
		assert_true(villager.job_data.embedding_test_resumes == 1,
			"embedding probe job did not start from a safe grounded pose")
		local embedding_thread = villager.job_thread
		assert_true(type(embedding_thread) == "thread"
				and coroutine.status(embedding_thread) == "suspended",
			"embedding probe has no suspended profession coroutine")

		local identity_before = {
			inventory_name = villager.inventory_name,
			manufacturing_number = villager.manufacturing_number,
			nametag = villager.nametag,
			owner_name = villager.owner_name,
			product_name = villager.product_name,
		}
		local inventory_before = inventory_snapshot(inventory)
		fill_embedding_volume(stone, 6)
		villager.object:set_pos({x = 6, y = 0.5, z = 0})
		villager.object:set_velocity({x = 3, y = -2, z = 1})

		-- A cached pose was produced by the immediately preceding clear callback.
		-- The production failure can unload a villager before callback two, so a
		-- fully-known solid intersection must use that revalidated cache now.
		villager.on_step(villager, 0.1)
		local cached_recovery_pos = villager.object:get_pos()
		assert_near(cached_recovery_pos.x, 0, 0.01,
			"villager did not return to its cached safe pose on callback one")
		assert_near(cached_recovery_pos.y, 0.5, 0.01,
			"cached recovery changed the grounded feet height")
		local stopped_velocity = villager.object:get_velocity()
		assert_true(stopped_velocity and stopped_velocity.x == 0
				and stopped_velocity.y == 0 and stopped_velocity.z == 0,
			"embedding recovery did not clear velocity")
		assert_true(villager.job_thread == embedding_thread
				and coroutine.status(embedding_thread) == "suspended",
			"cached recovery replaced or resumed the profession coroutine")
		assert_true(villager.job_data.embedding_test_resumes == 1,
			"profession advanced during first-callback cached recovery")
		assert_true(villager:get_job_name() == EMBEDDING_JOB,
			"cached recovery changed the profession")
		assert_true(inventory_snapshot(inventory) == inventory_before,
			"cached recovery changed the inventory")
		for key, value in pairs(identity_before) do
			assert_true(villager[key] == value,
				"cached recovery changed identity field " .. key)
		end
		minetest.log("action", "EMBEDDING_FIRST_CALLBACK_RUNTIME_OK:" .. profile)

		villager.on_step(villager, 0.1)
		assert_true(villager.job_thread == embedding_thread
				and villager.job_data.embedding_test_resumes == 2,
			"profession did not resume on the next clear callback")

		-- Make the cache ambiguous and force the entity into the same solid
		-- volume.  Without a cache timestamp the fallback must retain the
		-- multi-callback confirmation, then find nearby headroom (the volume top
		-- in this fixture), without assuming that underground itself is invalid.
		villager._safe_standing_at = nil
		villager.object:set_pos({x = 6, y = 0.5, z = 0})
		for callback = 1, 2 do
			villager.on_step(villager, 0.1)
			assert_near(villager.object:get_pos().x, 6, 0.01,
				"ambiguous cache triggered recovery before confirmation "
					.. callback)
		end
		villager.on_step(villager, 0.1)
		local searched_recovery_pos = villager.object:get_pos()
		assert_true(searched_recovery_pos.y >= 2.49,
			"cacheless recovery did not find nearby safe headroom")
		assert_true(villager.job_thread == embedding_thread
				and villager.job_data.embedding_test_resumes == 2,
			"cacheless recovery disturbed the profession coroutine")
		assert_true(villager:get_job_name() == EMBEDDING_JOB
				and inventory_snapshot(inventory) == inventory_before,
			"cacheless recovery changed job or inventory")
		for key, value in pairs(identity_before) do
			assert_true(villager[key] == value,
				"cacheless recovery changed identity field " .. key)
		end
		villager.on_step(villager, 0.1)
		assert_true(villager.job_thread == embedding_thread
				and villager.job_data.embedding_test_resumes == 3,
			"profession did not resume after cacheless recovery")

		-- Even a simultaneous solid intersection is ambiguous when any body cell
		-- is ignore/unloaded.  Keep a valid recent cache deliberately: this proves
		-- the guard does not teleport merely because another sampled cell is solid.
		fill_embedding_volume(stone, 4)
		villager.object:set_pos({x = 4, y = 0.5, z = 0})
		villager.object:set_velocity({x = 2, y = -1, z = 0})
		-- Luanti intentionally rejects writing CONTENT_IGNORE.  Inject the exact
		-- get_node_or_nil result an unloaded body cell produces, while every other
		-- node and the entity itself continue through the real engine APIs.
		local real_get_node_or_nil = minetest.get_node_or_nil
		minetest.get_node_or_nil = function(pos)
			if pos.x == 4 and pos.y == 1 and pos.z == 0 then
				return {name = "ignore", param1 = 0, param2 = 0}
			end
			return real_get_node_or_nil(pos)
		end
		local ignore_step_ok, ignore_step_error = xpcall(function()
			villager.on_step(villager, 0.1)
		end, debug.traceback)
		minetest.get_node_or_nil = real_get_node_or_nil
		assert_true(ignore_step_ok,
			"ignore/unknown engine callback failed: " .. tostring(ignore_step_error))
		assert_near(villager.object:get_pos().x, 4, 0.01,
			"ignore/unknown body cell triggered cached recovery")
		assert_true(villager.job_thread == embedding_thread
				and coroutine.status(embedding_thread) == "suspended"
				and villager.job_data.embedding_test_resumes == 4,
			"ignore/unknown probe disturbed the profession coroutine")
		assert_true(villager:get_job_name() == EMBEDDING_JOB
				and inventory_snapshot(inventory) == inventory_before,
			"ignore/unknown probe changed job or inventory")
		for key, value in pairs(identity_before) do
			assert_true(villager[key] == value,
				"ignore/unknown probe changed identity field " .. key)
		end
		villager.object:set_pos(searched_recovery_pos)
		villager.object:set_velocity({x = 0, y = 0, z = 0})
		minetest.log("action", "EMBEDDING_IGNORE_RUNTIME_OK:" .. profile)
		minetest.log("action", "EMBEDDING_RECOVERY_RUNTIME_OK:" .. profile)

		-- A wounded guard must disengage instead of taking the old close-combat
		-- branch until death. The profession and exact coroutine remain assigned;
		-- only the emergency movement temporarily owns the callback.
		local guard_changed, guard_error = villager:change_job("working_villages:job_guard")
		assert_true(guard_changed, "could not assign guard for wounded retreat: "
			.. tostring(guard_error))
		local guard_thread = villager.job_thread
		villager.object:set_pos({x = 0, y = 1, z = 0})
		villager.object:set_hp(math.floor(villager.object:get_properties().hp_max * 0.5))
		local guard_hostile = minetest.add_entity({x = 4, y = 1, z = 0}, HOSTILE)
		assert_true(guard_hostile, "could not create wounded-guard hostile")
		villager.job_data.danger_ticks = 2
		villager.on_step(villager, 0.1)
		assert_true(villager.disp_action == "fuite",
			"wounded guard stayed in combat instead of retreating")
		assert_true(villager:get_job_name() == "working_villages:job_guard"
				and villager.job_thread == guard_thread,
			"wounded retreat replaced the guard profession or coroutine")
		guard_hostile:remove()
		minetest.log("action", "WOUNDED_GUARD_RETREAT_RUNTIME_OK:" .. profile)
	end, debug.traceback)
	if not ok then
		minetest.log("error", tostring(err))
	end
	minetest.request_shutdown(
		ok and "working_villages tool fallback runtime test completed"
			or "working_villages tool fallback runtime test failed",
		false,
		0
	)
end)
