-- Real-engine regression for the first woodcutter of an empty village.
--
-- No wood, chest, workbench or tool is injected.  The production entity/job
-- coroutine must remove registered tree nodes with the active game's real hand
-- capabilities, retain the real drops, use registered recipes and finish with
-- exactly one crafted axe.  VoxeLibre must additionally craft, place and
-- consume exactly one real workbench because its axe recipe is 3x3.

local OWNER = "working_villages_woodcutter_bootstrap_test_owner"
local JOB = "working_villages:job_woodcutter"
local AUTONOMOUS_JOB = "working_villages:job_autonome"
local ENTITY = "working_villages:villager_female"
local POLL_INTERVAL = 0.02
local TIMEOUT_SECONDS = 120
local PAD_RADIUS = 10
local TEST_FORBIDDEN_TREE = "working_villages_woodcutter_bootstrap_test:tool_only_tree"

local profile = working_villages.game_profile
	and working_villages.game_profile.id or "unknown"
local compat = working_villages.compat or working_villages.voxelibre_compat

local finished = false
local villager = nil
local arbitration_villager = nil
local arbitration_observed = false
local log_name = nil
local plank_name = nil
local stick_name = nil
local foundation_name = nil
local initial_log_count = 0
local raw_log_observed = false
local axe_observed = false
local started_at = nil
local previous_snapshot = nil

local function fail(message)
	error("[working_villages_woodcutter_bootstrap_test] " .. tostring(message), 2)
end

local function assert_true(value, message)
	if not value then
		fail(message or "expected a truthy value")
	end
end

local function approx_equal(left, right)
	return math.abs(left - right) < 0.0001
end

local function finish(ok, message)
	if finished then
		return
	end
	finished = true
	if not ok then
		minetest.log("error", "WOODCUTTER_BOOTSTRAP_RUNTIME_FAILED:"
			.. profile .. ":" .. tostring(message))
	end
	minetest.request_shutdown(
		ok and "working_villages woodcutter bootstrap runtime test completed"
			or "working_villages woodcutter bootstrap runtime test failed",
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

minetest.register_node(TEST_FORBIDDEN_TREE, {
	description = "Woodcutter bootstrap tool-only test tree",
	tiles = {"default_tree.png"},
	diggable = false,
	groups = {tree = 1, unbreakable = 1},
	drop = TEST_FORBIDDEN_TREE,
})

local function hand_capabilities()
	local hand = working_villages.get_intrinsic_hand_stack
		and working_villages.get_intrinsic_hand_stack() or ItemStack("")
	local capabilities = hand:get_tool_capabilities()
	return capabilities and next(capabilities.groupcaps or {}) ~= nil
		and capabilities or nil
end

local function hand_can_dig(node_name)
	local def = minetest.registered_nodes[node_name]
	local capabilities = hand_capabilities()
	if not def or def.diggable == false or not capabilities then
		return false
	end
	local params = minetest.get_dig_params(def.groups or {}, capabilities, 0)
	return params and params.diggable == true
end

local function choose_registered_resource(candidates, predicate, label)
	for _, name in ipairs(candidates) do
		if minetest.registered_nodes[name]
				and (not predicate or predicate(name)) then
			return name
		end
	end
	fail("active game exposes no suitable registered " .. label)
end

local function choose_resources()
	if profile == "voxelibre" then
		log_name = choose_registered_resource({
			"mcl_core:tree",
			"mcl_core:birchtree",
		}, function(name)
			return minetest.get_item_group(name, "tree") > 0 and hand_can_dig(name)
		end, "hand-diggable VoxeLibre tree")
		foundation_name = choose_registered_resource({
			"mcl_core:stone", "mcl_core:dirt",
		}, nil, "VoxeLibre foundation")
		stick_name = "mcl_core:stick"
	else
		log_name = choose_registered_resource({
			"default:tree",
			"default:pine_tree",
		}, function(name)
			return minetest.get_item_group(name, "tree") > 0 and hand_can_dig(name)
		end, "hand-diggable Minetest Game tree")
		foundation_name = choose_registered_resource({
			"default:stone", "default:dirt",
		}, nil, "Minetest Game foundation")
		stick_name = "default:stick"
	end
	assert_true(minetest.registered_items[stick_name],
		"active game stick is not registered: " .. stick_name)

	local craft_result = minetest.get_craft_result({
		method = "normal",
		width = 1,
		items = {ItemStack(log_name)},
	})
	local plank_stack = craft_result and craft_result.item or ItemStack("")
	assert_true(not plank_stack:is_empty()
			and minetest.get_item_group(plank_stack:get_name(), "wood") > 0,
		"real trunk has no direct registered plank recipe: " .. log_name)
	plank_name = plank_stack:get_name()

	local drops = minetest.get_node_drops(log_name, "") or {}
	assert_true(#drops == 1, "selected trunk does not have one deterministic hand drop")
	local drop_stack = ItemStack(drops[1])
	assert_true(drop_stack:get_name() == log_name and drop_stack:get_count() == 1,
		"selected trunk hand drop is not exactly one matching trunk")
	assert_true(hand_can_dig(log_name),
		"selected real trunk is not diggable by the engine hand")
	assert_true(not hand_can_dig(TEST_FORBIDDEN_TREE),
		"negative-control tree unexpectedly became hand-diggable")

	minetest.log("action", "WOODCUTTER_HAND_GATE_OK:" .. profile .. ":"
		.. log_name .. ":plank=" .. plank_name)
end

local log_positions = {}
local function setup_pad()
	minetest.load_area(
		{x = -PAD_RADIUS - 2, y = -2, z = -PAD_RADIUS - 2},
		{x = PAD_RADIUS + 2, y = 8, z = PAD_RADIUS + 2}
	)
	for x = -PAD_RADIUS, PAD_RADIUS do
		for z = -PAD_RADIUS, PAD_RADIUS do
			minetest.set_node({x = x, y = 0, z = z}, {name = foundation_name})
			for y = 1, 7 do
				minetest.set_node({x = x, y = y, z = z}, {name = "air"})
			end
		end
	end

	-- Eight actual registered trunks, three nodes high, provide a renewable-job
	-- style tree cluster while keeping every source and removal count explicit.
	for _, base in ipairs({
		{x = 4, z = 0}, {x = -4, z = 0}, {x = 0, z = 4}, {x = 0, z = -4},
		{x = 4, z = 4}, {x = -4, z = 4}, {x = 4, z = -4}, {x = -4, z = -4},
	}) do
		for y = 1, 3 do
			local pos = {x = base.x, y = y, z = base.z}
			minetest.set_node(pos, {name = log_name})
			log_positions[#log_positions + 1] = vector.new(pos)
		end
	end
	minetest.set_node({x = 2, y = 1, z = 0}, {name = TEST_FORBIDDEN_TREE})
	initial_log_count = #log_positions
	if minetest.forceload_block then
		for x = -PAD_RADIUS, PAD_RADIUS, PAD_RADIUS do
			for z = -PAD_RADIUS, PAD_RADIUS, PAD_RADIUS do
				minetest.forceload_block({x = x, y = 0, z = z}, true)
			end
		end
	end
end

local function clear_inventory(entity)
	local inventory = entity:get_inventory()
	assert_true(inventory, "real woodcutter detached inventory is unavailable")
	for list_name, list in pairs(inventory:get_lists() or {}) do
		for index = 1, #list do
			inventory:set_stack(list_name, index, ItemStack(""))
		end
	end
end

local function create_woodcutter()
	local object = minetest.add_entity({x = 0, y = 1, z = 0}, ENTITY)
	assert_true(object, "could not create the real woodcutter entity")
	villager = object:get_luaentity()
	assert_true(villager, "created woodcutter has no Lua entity state")
	clear_inventory(villager)
	villager.owner_name = OWNER
	villager.nametag = "Empty bootstrap woodcutter"
	object:set_nametag_attributes({text = villager.nametag})
	working_villages.needs.set(villager, "hunger", 100)
	working_villages.needs.set(villager, "energy", 100)
	villager.pos_data = villager.pos_data or {}
	villager.pos_data.job_pos = {x = 0, y = 1, z = 0}
	local changed, reason = villager:change_job(JOB)
	assert_true(changed, "could not assign woodcutter job: " .. tostring(reason))

	local inventory = villager:get_inventory()
	for list_name, list in pairs(inventory:get_lists() or {}) do
		if list_name ~= "job" then
			for _, stack in ipairs(list or {}) do
				assert_true(stack:is_empty(),
					"woodcutter received an injected item in " .. list_name)
			end
		end
	end
	minetest.log("action", "WOODCUTTER_ZERO_INJECTION_OK:" .. profile
		.. ":logs=" .. tostring(initial_log_count))
end

local function create_paused_autonomous_worker()
	-- A loaded real autonomous worker must own the village utility bootstrap.
	-- Pause it so this focused regression proves arbitration without starting a
	-- second profession scenario or injecting wood into either entity.
	local object = minetest.add_entity({x = 1, y = 1, z = 1}, ENTITY)
	assert_true(object, "could not create arbitration autonomous worker")
	arbitration_villager = object:get_luaentity()
	assert_true(arbitration_villager,
		"created arbitration autonomous worker has no Lua entity state")
	clear_inventory(arbitration_villager)
	arbitration_villager.owner_name = OWNER
	local changed, reason = arbitration_villager:change_job(AUTONOMOUS_JOB)
	assert_true(changed, "could not assign arbitration autonomous job: " .. tostring(reason))
	arbitration_villager.pause = true
	arbitration_villager.pause_auto = nil
	arbitration_villager.job_data = arbitration_villager.job_data or {}
	arbitration_villager.job_data.pause_reason = "manual"
	object:set_velocity({x = 0, y = 0, z = 0})
end

local function count_world_logs()
	local count = 0
	for _, pos in ipairs(log_positions) do
		if minetest.get_node(pos).name == log_name then
			count = count + 1
		end
	end
	return count
end

local function inventory_count(item_name)
	local count = 0
	for list_name, list in pairs(villager:get_inventory():get_lists() or {}) do
		if list_name ~= "job" then
			for _, stack in ipairs(list or {}) do
				if stack:get_name() == item_name then
					count = count + stack:get_count()
				end
			end
		end
	end
	return count
end

local function dropped_count(item_name)
	local count = 0
	for _, object in ipairs(minetest.get_objects_inside_radius({x = 0, y = 2, z = 0}, 20)) do
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

local function axe_snapshot()
	local count = 0
	local name = nil
	for list_name, list in pairs(villager:get_inventory():get_lists() or {}) do
		if list_name ~= "job" then
			for _, stack in ipairs(list or {}) do
				if minetest.get_item_group(stack:get_name(), "axe") > 0 then
					count = count + stack:get_count()
					name = name or stack:get_name()
				end
			end
		end
	end
	return count, name
end

local function inventory_snapshot_text()
	local parts = {}
	for list_name, list in pairs(villager:get_inventory():get_lists() or {}) do
		if list_name ~= "job" then
			for index, stack in ipairs(list or {}) do
				if not stack:is_empty() then
					parts[#parts + 1] = list_name .. "[" .. tostring(index) .. "]="
						.. stack:get_name() .. " " .. tostring(stack:get_count())
				end
			end
		end
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

local function output_count(recipe)
	local output = ItemStack(recipe.output or "")
	return math.max(1, output:get_count())
end

local function raw_matches(raw, item_name)
	if raw == item_name then
		return true
	end
	if type(raw) == "string" and raw:sub(1, 6) == "group:" then
		return minetest.get_item_group(item_name, raw:sub(7)) > 0
	end
	return false
end

local function recipe_material_cost(item_name, plank_cost, stick_cost)
	local best = nil
	for _, recipe in ipairs(minetest.get_all_craft_recipes(item_name) or {}) do
		if recipe.method == "normal" or recipe.method == "shapeless" then
			local cost = 0
			local valid = true
			for _, raw in pairs(recipe.items or {}) do
				if raw and raw ~= "" then
					if raw_matches(raw, plank_name) then
						cost = cost + plank_cost
					elseif raw_matches(raw, stick_name) then
						cost = cost + stick_cost
					else
						valid = false
						break
					end
				end
			end
			if valid then
				cost = cost / output_count(recipe)
				if not best or cost < best then
					best = cost
				end
			end
		end
	end
	return best
end

local function plank_yield_per_log()
	local result = minetest.get_craft_result({
		method = "normal", width = 1, items = {ItemStack(log_name)},
	})
	local output = result and result.item or ItemStack("")
	assert_true(output:get_name() == plank_name,
		"trunk-to-plank recipe changed during the scenario")
	return output:get_count()
end

local function stick_cost_in_planks()
	local cost = recipe_material_cost(stick_name, 1, math.huge)
	assert_true(cost and cost > 0 and cost < math.huge,
		"could not resolve the registered stick recipe")
	return cost
end

local function count_workbenches()
	local count = 0
	local name = nil
	for x = -PAD_RADIUS, PAD_RADIUS do
		for z = -PAD_RADIUS, PAD_RADIUS do
			for y = 1, 3 do
				local node_name = minetest.get_node({x = x, y = y, z = z}).name
				if compat.is_crafting_table(node_name) then
					count = count + 1
					name = name or node_name
				end
			end
		end
	end
	return count, name
end

local function carried_workbench_count()
	local count = 0
	for _, name in ipairs(compat.get_crafting_table_item_candidates() or {}) do
		count = count + inventory_count(name) + dropped_count(name)
	end
	return count
end

local function verify_final_accounting(axe_name)
	local state = villager.job_data and villager.job_data.woodcutter_hand_bootstrap
	assert_true(type(state) == "table", "woodcutter bootstrap state was not persisted")
	local removed = initial_log_count - count_world_logs()
	assert_true(removed >= 1 and removed <= 6,
		"bare-hand trunk count is outside the bounded bootstrap: " .. tostring(removed))
	assert_true(state.logs_dug == removed,
		("persisted dig ledger %s differs from world removals %s"):format(
			tostring(state.logs_dug), tostring(removed)))
	assert_true(state.completed == true,
		"bootstrap was not marked complete after the axe was equipped")
	assert_true(minetest.get_node({x = 2, y = 1, z = 0}).name == TEST_FORBIDDEN_TREE,
		"tool-only negative-control tree was illegally hand-dug")

	local axe_count = select(1, axe_snapshot())
	assert_true(axe_count == 1, "expected exactly one axe, got " .. tostring(axe_count))
	assert_true(dropped_count(axe_name) == 0, "crafted axe was dropped instead of retained")
	assert_true(minetest.get_item_group(villager:get_wield_item_stack():get_name(), "axe") > 0,
		"crafted axe is not equipped in the real wield slot")

	local logs = inventory_count(log_name) + dropped_count(log_name)
	local planks = inventory_count(plank_name) + dropped_count(plank_name)
	local sticks = inventory_count(stick_name) + dropped_count(stick_name)
	local plank_yield = plank_yield_per_log()
	local stick_cost = stick_cost_in_planks()
	local axe_cost = recipe_material_cost(axe_name, 1, stick_cost)
	assert_true(axe_cost and axe_cost > 0,
		"could not resolve crafted axe material cost: " .. tostring(axe_name))

	local workbench_nodes, workbench_name = count_workbenches()
	local workbench_items = carried_workbench_count()
	local workbench_cost = 0
	if workbench_nodes + workbench_items > 0 then
		local workbench_item = workbench_name
		if not workbench_item then
			for _, name in ipairs(compat.get_crafting_table_item_candidates() or {}) do
				if inventory_count(name) + dropped_count(name) > 0 then
					workbench_item = name
					break
				end
			end
		end
		workbench_cost = recipe_material_cost(workbench_item, 1, stick_cost) or 0
		assert_true(workbench_cost > 0,
			"could not resolve workbench material cost: " .. tostring(workbench_item))
	end
	if profile == "voxelibre" then
		assert_true(arbitration_observed,
			"woodcutter did not yield workbench ownership to the real autonomous worker")
		assert_true(workbench_nodes == 1 and workbench_items == 0,
			("VoxeLibre requires one consumed/placed workbench, got nodes=%d items=%d"):format(
				workbench_nodes, workbench_items))
	else
		assert_true(workbench_nodes == 0 and workbench_items == 0,
			"Minetest Game bootstrap unexpectedly consumed a workbench")
	end

	local supplied_plank_units = removed * plank_yield
	local accounted_plank_units = logs * plank_yield + planks
		+ sticks * stick_cost + axe_cost
		+ (workbench_nodes + workbench_items) * workbench_cost
	assert_true(approx_equal(supplied_plank_units, accounted_plank_units),
		("wood ledger mismatch: supplied=%.4f accounted=%.4f removed=%d "
			.. "logs=%d planks=%d sticks=%d axe_cost=%.4f workbench_cost=%.4f"):format(
			supplied_plank_units, accounted_plank_units, removed,
			logs, planks, sticks, axe_cost, workbench_cost))

	local chest_name, chest_cost = nil, nil
	for _, candidate in ipairs(compat.get_chest_item_candidates() or {}) do
		if minetest.registered_items[candidate] then
			local cost = recipe_material_cost(candidate, 1, stick_cost)
			if cost and cost > 0 and (not chest_cost or cost < chest_cost) then
				chest_name, chest_cost = candidate, cost
			end
		end
	end
	assert_true(chest_name and chest_cost,
		"could not resolve a registered wooden chest recipe")
	local persisted_limit = math.floor(tonumber(state.limit) or 0)
	assert_true(persisted_limit >= 1 and persisted_limit <= 6,
		"persisted bootstrap limit is invalid: " .. tostring(state.limit))
	local bounded_budget = persisted_limit * plank_yield
	local required_budget = axe_cost + chest_cost + workbench_cost
	assert_true(bounded_budget >= required_budget,
		("bounded bootstrap cannot fund workbench/chest/axe: available=%.4f required=%.4f")
			:format(bounded_budget, required_budget))

	minetest.log("action", "WOODCUTTER_AXE_CRAFTED_OK:" .. profile .. ":"
		.. axe_name .. ":logs_dug=" .. tostring(removed))
	minetest.log("action", ("WOODCUTTER_BOOTSTRAP_BALANCE_OK:%s:supplied=%.4f:accounted=%.4f")
		:format(profile, supplied_plank_units, accounted_plank_units))
	minetest.log("action", ("WOODCUTTER_BOOTSTRAP_BUDGET_OK:%s:available=%.4f:required=%.4f:chest=%s")
		:format(profile, bounded_budget, required_budget, chest_name))
	minetest.log("action", "WOODCUTTER_BOOTSTRAP_RUNTIME_OK:" .. profile)
end

local function poll()
	assert_true(villager and villager.object and villager.object:get_pos(),
		"real woodcutter became unavailable before completing the scenario")
	assert_true(villager:get_job_name() == JOB,
		"real woodcutter changed profession during bootstrap")
	local removed = initial_log_count - count_world_logs()
	local raw_total = inventory_count(log_name) + dropped_count(log_name)
	local snapshot = inventory_snapshot_text()
	if snapshot ~= previous_snapshot then
		previous_snapshot = snapshot
		local workbench_count = select(1, count_workbenches())
		minetest.log("action", "WOODCUTTER_LEDGER_SNAPSHOT:" .. profile
			.. ":removed=" .. tostring(removed)
			.. ":workbenches=" .. tostring(workbench_count)
			.. ":inventory=" .. snapshot)
	end
	local state = villager.job_data and villager.job_data.woodcutter_hand_bootstrap
	if state and state.workbench_deferred_to_autonomous and not arbitration_observed then
		assert_true(arbitration_villager and arbitration_villager.object
			and arbitration_villager.object:get_pos(),
			"woodcutter recorded workbench arbitration without the real autonomous worker")
		assert_true(select(1, count_workbenches()) == 0,
			"woodcutter or paused autonomous worker placed a competing workbench")
		arbitration_observed = true
		minetest.log("action", "WOODCUTTER_WORKBENCH_ARBITRATION_OK:" .. profile
			.. ":job=" .. AUTONOMOUS_JOB)
		arbitration_villager.object:remove()
		arbitration_villager = nil
	end
	if removed > 0 and raw_total == removed and not raw_log_observed then
		raw_log_observed = true
		minetest.log("action", "WOODCUTTER_REAL_LOG_TRANSFER_OK:" .. profile .. ":"
			.. log_name .. ":removed=" .. tostring(removed)
			.. ":carried_or_dropped=" .. tostring(raw_total))
	end

	local axe_count, axe_name = axe_snapshot()
	if axe_count > 0 and not axe_observed then
		axe_observed = true
		villager.pause = true
		villager.pause_auto = nil
		villager.job_data.pause_reason = "manual"
		villager.object:set_velocity({x = 0, y = 0, z = 0})
		assert_true(raw_log_observed,
			"axe appeared before a physical trunk-to-inventory transfer was observed")
		schedule(0.2, function()
			verify_final_accounting(axe_name)
			finish(true)
		end)
		return
	end

	local elapsed = minetest.get_us_time() / 1000000 - started_at
	if elapsed >= TIMEOUT_SECONDS then
		local timeout_state = villager.job_data and villager.job_data.woodcutter_hand_bootstrap
		fail(("timeout after %.1fs; removed=%d raw=%d axe=%d bootstrap=%s action=%s state=%s")
			:format(elapsed, removed, raw_total, axe_count,
				minetest.serialize(timeout_state), tostring(villager.disp_action),
				tostring(villager.state_info)))
	end
	schedule(POLL_INTERVAL, poll)
end

schedule(0, function()
	assert_true(profile == "voxelibre" or profile == "minetest_game",
		"unsupported active game profile: " .. tostring(profile))
	minetest.set_timeofday(0.5)
	choose_resources()
	setup_pad()
	create_woodcutter()
	if profile == "voxelibre" then
		create_paused_autonomous_worker()
	end
	started_at = minetest.get_us_time() / 1000000
	schedule(POLL_INTERVAL, poll)
end)
