-- Two-run engine regressions for physical resource delivery.
--
-- The fresh-world prelude first proves that a real autonomous worker reserves
-- itself for the initial shared chest while still accepting an exact physical
-- delivery. Once a valid chest is registered, its deferred outbound request
-- must be released and delivered. Phase 1 then creates a real builder and
-- woodcutter, starts the production resource_delivery task, and stops only
-- after the supplier has travelled toward the requester without transferring
-- at range. Phase 2 reloads the same entities and task, observes resumed
-- travel, then requires one exact, proximity-bound transfer and a completed
-- task with no duplication.

local OWNER = "working_villages_physical_delivery_test_owner"
local REQUESTER_JOB = "working_villages:job_builder"
local SUPPLIER_JOB = "working_villages:job_woodcutter"
local AUTONOMOUS_JOB = "working_villages:job_autonome"
local REQUESTER_ENTITY = "working_villages:villager_female"
local SUPPLIER_ENTITY = "working_villages:villager_male"
local REQUEST_COUNT = 3
local INITIAL_SUPPLY = 4
local ARRIVAL_RADIUS = 3
local PHASE_ONE_MIN_REMAINING_DISTANCE = 8
local POLL_INTERVAL = 0.1
local PHASE_TIMEOUT_POLLS = 450
local STATE_VERSION = 3
local STATE_KEY = "physical_delivery_state_v1"
local CYCLE_ITEM = "working_villages_physical_delivery_test:cycle_token"
local BOOTSTRAP_ITEM = "working_villages_physical_delivery_test:bootstrap_token"
local BOOTSTRAP_OUTBOUND_TAG = "bootstrap_outbound_after_chest"
local BOOTSTRAP_INBOUND_TAG = "bootstrap_inbound_before_chest"
local BOOTSTRAP_TOTAL = 2
local BOOTSTRAP_CHEST_POS = {x = 0, y = 1, z = 3}

minetest.register_craftitem(CYCLE_ITEM, {
	description = "Physical delivery cycle token",
	inventory_image = "",
	stack_max = 99,
})

-- A seed group makes the autonomous profession retain this accounting token
-- after the chest appears. That keeps the regression focused on direct
-- villager-to-villager delivery instead of its ordinary chest-deposit policy.
minetest.register_craftitem(BOOTSTRAP_ITEM, {
	description = "Physical delivery bootstrap token",
	inventory_image = "",
	stack_max = 99,
	groups = {seed = 1},
})

local storage = minetest.get_mod_storage()
local collab = working_villages.collaborative_tasks
local profile = working_villages.game_profile and working_villages.game_profile.id or "unknown"
local job_coroutines = working_villages.require("job_coroutines")
local job_resume_counts = {}
local original_job_resume = job_coroutines.resume
job_coroutines.resume = function(villager, dtime)
	local id = villager and villager.inventory_name
	if id then
		job_resume_counts[id] = (job_resume_counts[id] or 0) + 1
	end
	return original_job_resume(villager, dtime)
end

local function job_resume_count(villager)
	return job_resume_counts[villager and villager.inventory_name] or 0
end

local function fail(message)
	error("[working_villages_physical_delivery_test] " .. tostring(message), 2)
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

local function copy_pos(pos)
	return pos and {x = pos.x, y = pos.y, z = pos.z} or nil
end

local function require_active_pos(villager, label)
	assert_true(villager, (label or "villager") .. " fixture is missing")
	local object = villager.object
	assert_true(object and object.get_pos,
		(label or "villager") .. " fixture has no live object reference")
	local pos = object:get_pos()
	assert_true(pos,
		(label or "villager") .. " fixture was unloaded or removed during the regression")
	return pos
end

local function load_state()
	local encoded = storage:get_string(STATE_KEY)
	if encoded == "" then
		return nil
	end
	local ok, decoded = pcall(minetest.deserialize, encoded)
	assert_true(ok and type(decoded) == "table", "persisted harness state is invalid")
	assert_equal(decoded.version, STATE_VERSION, "persisted harness state version mismatch")
	return decoded
end

local function save_state(state)
	state.version = STATE_VERSION
	storage:set_string(STATE_KEY, minetest.serialize(state))
end

local function setup_pad()
	local stone = working_villages.compat.get_item("default:stone")
	assert_true(minetest.registered_nodes[stone], "active game exposes no test ground node")
	local minp = {x = -32, y = -2, z = -24}
	local maxp = {x = 32, y = 5, z = 24}
	minetest.load_area(minp, maxp)
	for x = -32, 32 do
		for z = -24, 24 do
			minetest.set_node({x = x, y = 0, z = z}, {name = stone})
			for y = 1, 4 do
				minetest.set_node({x = x, y = y, z = z}, {name = "air"})
			end
		end
	end
	-- A headless server has no player maintaining active blocks. Keep every
	-- mapblock touched by the pad active, including its edge blocks; otherwise
	-- a fixture can deactivate before an assertion can report its real state.
	if minetest.forceload_block then
		for x = -32, 32, 16 do
			for z = -32, 32, 16 do
				minetest.forceload_block({x = x, y = 0, z = z}, true)
			end
		end
	end
end

local function choose_resource()
	local candidates = {
		working_villages.compat.get_item("default:wood"),
		"default:wood",
		"mcl_core:wood",
	}
	for _, name in ipairs(candidates) do
		local def = type(name) == "string" and minetest.registered_items[name] or nil
		if def and (def.stack_max or 99) >= INITIAL_SUPPLY then
			return name
		end
	end
	fail("active game exposes no stackable real wood resource")
end

local function choose_axe()
	local candidates = working_villages.compat.get_tool_items(
		"axe", {"stone", "wood", "iron"})
	for _, name in ipairs(candidates or {}) do
		if minetest.registered_items[name]
				and minetest.get_item_group(name, "axe") > 0 then
			return name
		end
	end
	return nil
end

local function count_inventory_item(villager, item_name)
	local inventory = villager and villager.get_inventory and villager:get_inventory() or nil
	assert_true(inventory, "real villager inventory is unavailable")
	local total = 0
	for _, list in pairs(inventory:get_lists() or {}) do
		for _, stack in ipairs(list or {}) do
			if stack:get_name() == item_name then
				total = total + stack:get_count()
			end
		end
	end
	return total
end

local function count_dropped_item(item_name)
	local total = 0
	for _, object in ipairs(minetest.get_objects_inside_radius({x = 0, y = 1, z = 0}, 32)) do
		local lua = object:get_luaentity()
		if lua and lua.name == "__builtin:item" then
			local stack = ItemStack(lua.itemstring or "")
			if stack:get_name() == item_name then
				total = total + stack:get_count()
			end
		end
	end
	return total
end

local function count_node_inventory_item(pos, item_name)
	if not pos or not working_villages.is_chest_pos(pos) then
		return 0
	end
	local inventory = minetest.get_meta(pos):get_inventory()
	local total = 0
	for _, stack in ipairs(inventory and inventory:get_list("main") or {}) do
		if stack:get_name() == item_name then
			total = total + stack:get_count()
		end
	end
	return total
end

local function normalize_exact_item_in_main(villager, item_name, expected)
	local inventory = villager and villager.get_inventory and villager:get_inventory() or nil
	assert_true(inventory, "cannot normalize an unavailable villager inventory")
	local total = 0
	for list_name, list in pairs(inventory:get_lists() or {}) do
		for index, stack in ipairs(list or {}) do
			if stack:get_name() == item_name then
				total = total + stack:get_count()
				inventory:set_stack(list_name, index, ItemStack())
			end
		end
	end
	assert_equal(total, expected,
		"fixture token distribution changed before main-list normalization")
	local replacement = ItemStack(item_name)
	replacement:set_count(expected)
	assert_true(inventory:add_item("main", replacement):is_empty(),
		"could not restore the exact fixture token to the main list")

	local main_total = 0
	for _, stack in ipairs(inventory:get_list("main") or {}) do
		if stack:get_name() == item_name then
			main_total = main_total + stack:get_count()
		end
	end
	assert_equal(main_total, expected,
		"fixture token is not exact in the supplier main list")
	assert_equal(count_inventory_item(villager, item_name), expected,
		"fixture token was duplicated while restoring the main list")
end

local function assert_bootstrap_conserved(autonomous, supplier, requester)
	local autonomous_count = count_inventory_item(autonomous, BOOTSTRAP_ITEM)
	local supplier_count = count_inventory_item(supplier, BOOTSTRAP_ITEM)
	local requester_count = count_inventory_item(requester, BOOTSTRAP_ITEM)
	local chest_count = count_node_inventory_item(BOOTSTRAP_CHEST_POS, BOOTSTRAP_ITEM)
	local dropped_count = count_dropped_item(BOOTSTRAP_ITEM)
	assert_equal(autonomous_count + supplier_count + requester_count
			+ chest_count + dropped_count, BOOTSTRAP_TOTAL,
		"bootstrap delivery token was duplicated or lost")
	assert_equal(dropped_count, 0, "bootstrap delivery token was dropped into the world")
	return autonomous_count, supplier_count, requester_count, chest_count
end

local function inventory_snapshot(requester, supplier, item_name)
	local requester_count = count_inventory_item(requester, item_name)
	local supplier_count = count_inventory_item(supplier, item_name)
	local dropped_count = count_dropped_item(item_name)
	return requester_count, supplier_count, dropped_count,
		requester_count + supplier_count + dropped_count
end

local function assert_conserved(requester, supplier, item_name)
	local requester_count, supplier_count, dropped_count, total =
		inventory_snapshot(requester, supplier, item_name)
	assert_equal(total, INITIAL_SUPPLY, "delivery resource was duplicated or lost")
	assert_equal(dropped_count, 0, "delivery resource was dropped into the world")
	return requester_count, supplier_count
end

local function find_loaded_villager(inventory_name)
	local found = nil
	local matches = 0
	for _, lua in pairs(minetest.luaentities or {}) do
		if lua and lua.name and working_villages.is_villager(lua.name)
				and lua.inventory_name == inventory_name then
			matches = matches + 1
			found = lua
		end
	end
	if matches > 1 then
		fail("duplicate real entity identity after reload: " .. inventory_name)
	end
	return found
end

local function set_safe_needs(villager)
	working_villages.needs.set(villager, "hunger", 100)
	working_villages.needs.set(villager, "energy", 100)
end

local function clear_inventory(villager)
	local inventory = villager:get_inventory()
	for list_name, list in pairs(inventory:get_lists() or {}) do
		for index = 1, #list do
			inventory:set_stack(list_name, index, ItemStack())
		end
	end
end

local function create_villager(entity_name, pos, job_name, label)
	local object = minetest.add_entity(pos, entity_name)
	assert_true(object, "could not create real " .. label .. " entity")
	local villager = object:get_luaentity()
	assert_true(villager, "created " .. label .. " has no Lua entity state")
	clear_inventory(villager)
	villager.owner_name = OWNER
	villager.nametag = "Physical delivery " .. label
	object:set_nametag_attributes({text = villager.nametag})
	set_safe_needs(villager)
	local changed, reason = villager:change_job(job_name)
	assert_true(changed, "could not assign " .. label .. " job: " .. tostring(reason))
	-- Engine-spawned workers receive a stable work anchor. Reproduce that
	-- invariant in the fixture so a profession cannot wander out of the
	-- headless active area while waiting for the logistics cadence.
	villager.pos_data = villager.pos_data or {}
	villager.pos_data.job_pos = vector.round(pos)
	villager.job_data = villager.job_data or {}
	-- The fixture is spawned directly at that anchor, so it is already at work.
	-- Avoid testing an unrelated first-arrival path before logistics starts.
	villager.job_data.in_work = true
	if working_villages.population then
		working_villages.population.register(villager, pos)
	end
	return villager
end

local function message_has_bootstrap_tag(message, tag)
	return type(message) == "table" and message.type == "help_needed"
		and type(message.data) == "table"
		and message.data.physical_delivery_test_tag == tag
end

local function has_bootstrap_message(villager, tag)
	local data = villager and villager.job_data or nil
	if not data then
		return false
	end
	if message_has_bootstrap_tag(data.pending_resource_message, tag) then
		return true
	end
	for _, message in ipairs(data.inbox or {}) do
		if message_has_bootstrap_tag(message, tag) then
			return true
		end
	end
	return false
end

local function find_bootstrap_message(villager, tag)
	local data = villager and villager.job_data or nil
	if not data then
		return nil
	end
	if message_has_bootstrap_tag(data.pending_resource_message, tag) then
		return data.pending_resource_message
	end
	for _, message in ipairs(data.inbox or {}) do
		if message_has_bootstrap_tag(message, tag) then
			return message
		end
	end
	return nil
end

local function setup_bootstrap_chest(autonomous)
	local candidates = {}
	local seen = {}
	local function add_candidate(name)
		if type(name) == "string" and name ~= "" and not seen[name] then
			seen[name] = true
			candidates[#candidates + 1] = name
		end
	end
	if profile == "voxelibre" then
		add_candidate("mcl_chests:chest_small")
		add_candidate("mcl_chests:chest")
	else
		add_candidate("default:chest")
	end
	for _, name in ipairs(working_villages.compat.get_chest_items() or {}) do
		add_candidate(name)
	end

	local placed_name = nil
	for _, name in ipairs(candidates) do
		local definition = minetest.registered_nodes[name]
		if definition then
			minetest.remove_node(BOOTSTRAP_CHEST_POS)
			minetest.set_node(BOOTSTRAP_CHEST_POS, {name = name})
			if type(definition.on_construct) == "function" then
				local ok, err = pcall(definition.on_construct, BOOTSTRAP_CHEST_POS)
				assert_true(ok, "real bootstrap chest construction failed: " .. tostring(err))
			end
			if working_villages.is_chest_pos(BOOTSTRAP_CHEST_POS) then
				placed_name = minetest.get_node(BOOTSTRAP_CHEST_POS).name
				break
			end
		end
	end
	assert_true(placed_name, "active game exposes no usable real chest node")

	autonomous.object:set_pos({x = 0, y = 1, z = 1})
	autonomous.object:set_velocity({x = 0, y = 0, z = 0})
	autonomous._last_placed_node = {
		pos = vector.round(BOOTSTRAP_CHEST_POS),
		node_name = placed_name,
		at_us = minetest.get_us_time(),
	}
	assert_true(working_villages.set_shared_storage_pos(
		BOOTSTRAP_CHEST_POS, OWNER, autonomous),
		"production API rejected the real bootstrap shared chest")
	local registered = working_villages.get_shared_storage_pos(OWNER)
	assert_true(registered
			and minetest.hash_node_position(registered)
				== minetest.hash_node_position(BOOTSTRAP_CHEST_POS),
		"production API did not retain the bootstrap shared chest")
	return placed_name
end

local function assert_task_shape(record, state)
	assert_true(record, "collaborative task record is missing")
	assert_equal(record.name, "resource_delivery", "wrong collaborative task type")
	assert_equal(record.owner_name, OWNER, "collaborative task owner changed")
	assert_equal(record.initiator, state.requester_id, "collaborative task initiator changed")
	assert_equal(record.state, "active", "collaborative task ended before delivery")
	assert_true(type(record.data) == "table" and type(record.data.items) == "table",
		"collaborative task lost its resource request")
	assert_equal(record.data.items[state.item_name], REQUEST_COUNT,
		"collaborative task request count changed")
	local participants = {}
	for _, inventory_name in ipairs(record.participants or {}) do
		participants[inventory_name] = true
	end
	assert_true(participants[state.requester_id] and participants[state.supplier_id],
		"collaborative task lost a real participant")
end

local function request_clean_shutdown(message)
	minetest.request_shutdown(message, false, 0)
end

local function run_cycle_regression(first, second, callback)
	first.object:set_pos({x = -8, y = 1, z = 0})
	second.object:set_pos({x = 8, y = 1, z = 0})
	first.object:set_velocity({x = 0, y = 0, z = 0})
	second.object:set_velocity({x = 0, y = 0, z = 0})
	set_safe_needs(first)
	set_safe_needs(second)
	local first_leftover = first:add_item_to_main(ItemStack(CYCLE_ITEM))
	local second_leftover = second:add_item_to_main(ItemStack(CYCLE_ITEM))
	assert_true(first_leftover:is_empty() and second_leftover:is_empty(),
		"could not provision cycle-regression tokens")
	assert_equal(count_inventory_item(first, CYCLE_ITEM), 1,
		"first cycle participant has the wrong initial token count")
	assert_equal(count_inventory_item(second, CYCLE_ITEM), 1,
		"second cycle participant has the wrong initial token count")

	assert_true(first:queue_physical_delivery(second.inventory_name, {
		items = {[CYCLE_ITEM] = 1},
		info = "Cross-delivery deadlock regression A to B",
	}), "could not queue first side of the cross delivery")
	assert_true(second:queue_physical_delivery(first.inventory_name, {
		items = {[CYCLE_ITEM] = 1},
		info = "Cross-delivery deadlock regression B to A",
	}), "could not queue second side of the cross delivery")

	local first_completion_distance = nil
	local second_completion_distance = nil
	local function delivered_token(villager)
		local last = villager.job_data and villager.job_data.last_physical_delivery or nil
		local items = last and last.success and last.summary and last.summary.items or nil
		return items and items[CYCLE_ITEM] == 1
	end
	local function poll(attempt)
		local first_count = count_inventory_item(first, CYCLE_ITEM)
		local second_count = count_inventory_item(second, CYCLE_ITEM)
		local dropped = count_dropped_item(CYCLE_ITEM)
		assert_equal(first_count + second_count + dropped, 2,
			"cross delivery duplicated or lost a cycle token")
		assert_equal(dropped, 0, "cross delivery dropped a cycle token")
		local distance = vector.distance(
			require_active_pos(first, "first cycle participant"),
			require_active_pos(second, "second cycle participant"))
		if delivered_token(first) and not first_completion_distance then
			first_completion_distance = distance
		end
		if delivered_token(second) and not second_completion_distance then
			second_completion_distance = distance
		end
		if first_completion_distance and second_completion_distance then
			assert_true(first_completion_distance <= ARRIVAL_RADIUS,
				"first side of the cycle transferred outside physical proximity")
			assert_true(second_completion_distance <= ARRIVAL_RADIUS,
				"second side of the cycle transferred outside physical proximity")
			assert_equal(first_count, 1,
				"cross delivery left the first participant with the wrong exact count")
			assert_equal(second_count, 1,
				"cross delivery left the second participant with the wrong exact count")
			assert_true(first.job_data.pending_resource_message == nil
				and second.job_data.pending_resource_message == nil,
				"cross delivery left a participant in a pending-delivery deadlock")
			minetest.log("action", "PHYSICAL_DELIVERY_CYCLE_ORDER_OK:" .. profile)
			callback()
			return
		end
		if attempt >= PHASE_TIMEOUT_POLLS then
			fail("cross delivery deadlocked instead of applying deterministic order")
		end
		minetest.after(POLL_INTERVAL, function()
			poll(attempt + 1)
		end)
	end
	minetest.after(POLL_INTERVAL, function()
		poll(1)
	end)
end

local function run_bootstrap_reservation_regression(callback)
	setup_pad()
	if working_villages.clear_shared_storage_pos then
		working_villages.clear_shared_storage_pos(OWNER)
	end
	assert_true(working_villages.get_shared_storage_pos(OWNER) == nil,
		"bootstrap regression unexpectedly started with shared storage")

	local autonomous = create_villager(
		REQUESTER_ENTITY, {x = 0, y = 1, z = 0}, AUTONOMOUS_JOB, "bootstrap autonomous")
	local supplier = create_villager(
		SUPPLIER_ENTITY, {x = -14, y = 1, z = 0}, SUPPLIER_JOB, "bootstrap supplier")
	local requester = create_villager(
		REQUESTER_ENTITY, {x = 14, y = 1, z = 0}, REQUESTER_JOB, "bootstrap requester")
	for _, villager in ipairs({autonomous, supplier, requester}) do
		villager.job_data = villager.job_data or {}
		villager.job_data.auto_job_cooldown_until = os.time() + 3600
		set_safe_needs(villager)
	end
	-- Keep the unrelated requester at a stable physical destination. The
	-- regression exercises the autonomous profession and the supplier engine;
	-- allowing the builder to start its own broadcasts would add unrelated
	-- delivery traffic to this deliberately three-entity fixture.
	requester.job_data.pause_reason = "manual"
	requester.pause_auto = nil
	requester:set_pause(true)
	local axe = choose_axe()
	if axe then
		supplier:set_wield_item_stack(ItemStack(axe))
	end

	assert_true(autonomous:add_item_to_main(ItemStack(BOOTSTRAP_ITEM)):is_empty(),
		"could not provision autonomous bootstrap token")
	assert_true(supplier:add_item_to_main(ItemStack(BOOTSTRAP_ITEM)):is_empty(),
		"could not provision supplier bootstrap token")
	local autonomous_count, supplier_count, requester_count, chest_count =
		assert_bootstrap_conserved(autonomous, supplier, requester)
	assert_equal(autonomous_count, 1, "autonomous owns the wrong initial bootstrap count")
	assert_equal(supplier_count, 1, "supplier owns the wrong initial bootstrap count")
	assert_equal(requester_count, 0, "requester unexpectedly owns a bootstrap token")
	assert_equal(chest_count, 0, "bootstrap token unexpectedly started in a chest")

	local comm = working_villages.communication
	assert_true(comm and comm.send_message, "production communication API is unavailable")
	assert_true(comm.send_message(requester, autonomous, "help_needed", {
		items = {[BOOTSTRAP_ITEM] = 1},
		requester_id = requester.inventory_name,
		info = "Deferred until the first shared chest exists",
		physical_delivery_test_tag = BOOTSTRAP_OUTBOUND_TAG,
	}), "could not queue the autonomous outbound bootstrap regression")
	assert_true(has_bootstrap_message(autonomous, BOOTSTRAP_OUTBOUND_TAG),
		"autonomous did not retain the queued outbound bootstrap request")

	local resumes_before_reservation = job_resume_count(autonomous)
	local function wait_for_profession_resume(attempt)
		assert_true(autonomous.object and autonomous.object:get_pos(),
			"bootstrap autonomous unloaded before reservation proof")
		assert_true(working_villages.get_shared_storage_pos(OWNER) == nil,
			"shared chest appeared before reservation proof")
		assert_bootstrap_conserved(autonomous, supplier, requester)
		assert_true(has_bootstrap_message(autonomous, BOOTSTRAP_OUTBOUND_TAG),
			"autonomous consumed its outbound request before shared storage")
		assert_true(autonomous.job_data.pending_resource_message == nil
				and autonomous.job_data.physical_delivery_state == nil,
			"autonomous started an outbound delivery before shared storage")
		assert_true(autonomous.disp_action ~= "apporte des ressources",
			"autonomous displayed an outbound delivery before shared storage")

		if job_resume_count(autonomous) > resumes_before_reservation then
			minetest.log("action", "PHYSICAL_DELIVERY_BOOTSTRAP_RESERVED_OK:" .. profile)
			normalize_exact_item_in_main(supplier, BOOTSTRAP_ITEM, 1)
			assert_bootstrap_conserved(autonomous, supplier, requester)
			-- Start this assertion from a deterministic carrier position. Its
			-- profession was allowed to run above, but unrelated wood-search
			-- wandering must not consume the logistics timeout budget.
			supplier.object:set_pos({x = -14, y = 1, z = 0})
			supplier.object:set_velocity({x = 0, y = 0, z = 0})
			local supplier_process_calls = 0
			local supplier_process_last_result = nil
			local original_process_resource_requests = supplier.process_resource_requests
			supplier.process_resource_requests = function(self, ...)
				supplier_process_calls = supplier_process_calls + 1
				supplier_process_last_result = original_process_resource_requests(self, ...)
				return supplier_process_last_result
			end
			assert_true(supplier:queue_physical_delivery(autonomous.inventory_name, {
				items = {[BOOTSTRAP_ITEM] = 1},
				info = "Exact physical delivery to reserved autonomous worker",
				-- Match the production first-chest wood request. Infrastructure
				-- cargo must preempt the worker's deferred ordinary outbound order.
				bootstrap_infrastructure = true,
				physical_delivery_test_tag = BOOTSTRAP_INBOUND_TAG,
			}), "could not queue inbound bootstrap delivery")
			local queued_inbound = find_bootstrap_message(supplier, BOOTSTRAP_INBOUND_TAG)
			assert_true(queued_inbound and queued_inbound.data
					and queued_inbound.data.bootstrap_infrastructure == true,
				"queued bootstrap inbound lost its infrastructure priority payload")
			assert_equal(queued_inbound.type, "help_needed",
				"queued bootstrap inbound has the wrong message type")
			assert_equal(queued_inbound.data.requester_id, autonomous.inventory_name,
				"queued bootstrap inbound targets the wrong villager")
			assert_equal(queued_inbound.data.items
					and queued_inbound.data.items[BOOTSTRAP_ITEM], 1,
				"queued bootstrap inbound has the wrong exact item payload")
			-- Make the next engine callback evaluate the real request queue. This
			-- removes a cadence phase dependency without calling the delivery API
			-- directly or bypassing physical pathfinding.
			supplier:set_timer("resource_requests", 20)

			local incoming_observed = false
			local supplier_start = copy_pos(require_active_pos(
				supplier, "bootstrap supplier before reception"))
			local function reception_status()
				local supplier_data = supplier.job_data or {}
				local autonomous_data = autonomous.job_data or {}
				local supplier_pos = supplier.object and supplier.object:get_pos() or nil
				local autonomous_pos = autonomous.object and autonomous.object:get_pos() or nil
				local inbox = type(supplier_data.inbox) == "table" and supplier_data.inbox or {}
				local pending = supplier_data.pending_resource_message
				local delivery = supplier_data.physical_delivery_state
				local incoming = autonomous_data.physical_delivery_incoming
				local tagged = find_bootstrap_message(supplier, BOOTSTRAP_INBOUND_TAG)
				local retry = tagged and tagged.supply_retry or nil
				local failure = supplier_data.last_resource_request_failure
				local main_count = 0
				local supplier_inventory = supplier:get_inventory()
				for _, stack in ipairs(supplier_inventory:get_list("main") or {}) do
					if stack:get_name() == BOOTSTRAP_ITEM then
						main_count = main_count + stack:get_count()
					end
				end
				return table.concat({
					"calls=" .. tostring(supplier_process_calls),
					"last_result=" .. tostring(supplier_process_last_result),
					"inbox=" .. tostring(#inbox),
					"tagged=" .. tostring(tagged ~= nil),
					"tagged_type=" .. tostring(tagged and tagged.type),
					"tagged_requester=" .. tostring(tagged and tagged.data
						and tagged.data.requester_id),
					"tagged_item=" .. tostring(tagged and tagged.data and tagged.data.items
						and tagged.data.items[BOOTSTRAP_ITEM]),
					"tagged_bootstrap=" .. tostring(tagged and tagged.data
						and tagged.data.bootstrap_infrastructure == true),
					"main_bootstrap=" .. tostring(main_count),
					"retry_attempts=" .. tostring(retry and retry.attempts),
					"retry_reason=" .. tostring(retry and retry.reason),
					"retry_remaining=" .. tostring(retry and retry.remaining),
					"failure_reason=" .. tostring(failure and failure.reason),
					"pending=" .. tostring(type(pending) == "table"),
					"pending_bootstrap=" .. tostring(type(pending) == "table"
						and pending.data and pending.data.bootstrap_infrastructure == true),
					"state=" .. tostring(type(delivery) == "table"),
					"state_bootstrap=" .. tostring(type(delivery) == "table"
						and delivery.bootstrap_infrastructure == true),
					"incoming=" .. tostring(type(incoming) == "table" and next(incoming) ~= nil),
					"supplier_pos=" .. tostring(supplier_pos
						and minetest.pos_to_string(supplier_pos, 2) or "nil"),
					"autonomous_pos=" .. tostring(autonomous_pos
						and minetest.pos_to_string(autonomous_pos, 2) or "nil"),
					"supplier_action=" .. tostring(supplier.disp_action),
					"autonomous_action=" .. tostring(autonomous.disp_action),
					"supplier_job=" .. tostring(supplier:get_job_name()),
					"supplier_pause=" .. tostring(supplier.pause),
					"danger_ticks=" .. tostring(supplier_data.danger_ticks),
					"embedded_callbacks=" .. tostring(supplier._embedded_body_callbacks),
					"resource_timer=" .. tostring(supplier:get_timer("resource_requests")),
					"hunger=" .. tostring(working_villages.needs.get(supplier, "hunger")),
					"energy=" .. tostring(working_villages.needs.get(supplier, "energy")),
				}, ",")
			end
			local function wait_for_reception(reception_attempt)
				assert_true(working_villages.get_shared_storage_pos(OWNER) == nil,
					"shared chest appeared before inbound bootstrap reception")
				assert_true(has_bootstrap_message(autonomous, BOOTSTRAP_OUTBOUND_TAG),
					"autonomous consumed its outbound request during inbound reception")
				assert_true(autonomous.job_data.pending_resource_message == nil
						and autonomous.job_data.physical_delivery_state == nil,
					"autonomous started outbound delivery while receiving bootstrap stock")

				local auto_now, supplier_now, requester_now =
					assert_bootstrap_conserved(autonomous, supplier, requester)
				local incoming = autonomous.job_data.physical_delivery_incoming
				if type(incoming) == "table" and next(incoming) ~= nil
						and autonomous.disp_action == "attend une livraison" then
					incoming_observed = true
				end
				local autonomous_pos = require_active_pos(
					autonomous, "bootstrap autonomous during reception")
				local supplier_pos = require_active_pos(
					supplier, "bootstrap supplier during reception")
				local distance = vector.distance(autonomous_pos, supplier_pos)
				if auto_now == 1 then
					assert_equal(supplier_now, 1,
						"supplier stock changed before exact bootstrap reception")
					assert_equal(requester_now, 0,
						"deferred requester received a token before the chest")
					if distance > ARRIVAL_RADIUS then
						assert_equal(auto_now, 1,
							"bootstrap token transferred outside physical proximity")
					end
				elseif auto_now == 2 then
					assert_equal(supplier_now, 0, "bootstrap supplier retained its delivered token")
					assert_equal(requester_now, 0,
						"deferred outbound token moved before the chest existed")
					assert_true(distance <= ARRIVAL_RADIUS,
						"bootstrap reception occurred outside physical proximity")
					assert_true(incoming_observed,
						"autonomous never held a physical delivery rendezvous")
					local last = supplier.job_data.last_physical_delivery
					local delivered = last and last.success and last.summary
						and last.summary.items or nil
					assert_equal(delivered and delivered[BOOTSTRAP_ITEM], 1,
						"supplier recorded the wrong exact bootstrap delivery")
					assert_true(vector.distance(supplier_pos, supplier_start) >= 0.75,
						"bootstrap supplier did not physically travel")
					minetest.log("action", "PHYSICAL_DELIVERY_BOOTSTRAP_RECEPTION_OK:" .. profile)

					local resumes_at_reception = job_resume_count(autonomous)
					local function wait_for_post_reception_resume(resume_attempt)
						local final_auto, final_supplier, final_requester =
							assert_bootstrap_conserved(autonomous, supplier, requester)
						assert_equal(final_auto, 2,
							"autonomous bootstrap stock changed before chest release")
						assert_equal(final_supplier, 0,
							"supplier bootstrap stock changed after reception")
						assert_equal(final_requester, 0,
							"outbound request escaped before chest release")
						assert_true(has_bootstrap_message(autonomous, BOOTSTRAP_OUTBOUND_TAG),
							"deferred outbound request disappeared before chest release")
						assert_true(autonomous.job_data.pending_resource_message == nil
								and autonomous.job_data.physical_delivery_state == nil,
							"autonomous entered outbound delivery before chest release")
						local pending_incoming = autonomous.job_data.physical_delivery_incoming
						if job_resume_count(autonomous) > resumes_at_reception
								and (type(pending_incoming) ~= "table" or next(pending_incoming) == nil) then
							setup_bootstrap_chest(autonomous)
							local function wait_for_release(release_attempt)
								assert_true(working_villages.is_chest_pos(BOOTSTRAP_CHEST_POS),
									"bootstrap shared chest became invalid during release")
								local released_auto, released_supplier, released_requester,
									released_chest = assert_bootstrap_conserved(
										autonomous, supplier, requester)
								if released_requester == 1 then
									assert_equal(released_auto, 1,
										"autonomous delivered the wrong bootstrap token count")
									assert_equal(released_supplier, 0,
										"bootstrap supplier stock changed during outbound release")
									assert_equal(released_chest, 0,
										"direct bootstrap delivery leaked into shared storage")
									assert_true(vector.distance(
										require_active_pos(autonomous,
											"bootstrap autonomous during release"),
										require_active_pos(requester,
											"bootstrap requester during release")) <= ARRIVAL_RADIUS,
										"deferred outbound request transferred outside proximity")
									local last_outbound = autonomous.job_data.last_physical_delivery
									local outbound_items = last_outbound and last_outbound.success
										and last_outbound.summary and last_outbound.summary.items or nil
									assert_equal(outbound_items and outbound_items[BOOTSTRAP_ITEM], 1,
										"autonomous recorded the wrong released delivery")
									assert_true(not has_bootstrap_message(
										autonomous, BOOTSTRAP_OUTBOUND_TAG),
										"released outbound request remained queued")
									assert_true(autonomous.job_data.pending_resource_message == nil,
										"released outbound request remained pending")
									minetest.log("action", "PHYSICAL_DELIVERY_BOOTSTRAP_RELEASE_OK:" .. profile)

									assert_true(working_villages.clear_shared_storage_pos(OWNER),
										"could not clear bootstrap shared storage fixture")
									minetest.remove_node(BOOTSTRAP_CHEST_POS)
									for _, villager in ipairs({autonomous, supplier, requester}) do
										if villager.object and villager.object:get_pos() then
											villager.object:remove()
										end
									end
									minetest.after(POLL_INTERVAL, callback)
									return
								end
								if release_attempt >= PHASE_TIMEOUT_POLLS then
									fail("autonomous did not release its deferred request after chest registration")
								end
								minetest.after(POLL_INTERVAL, function()
									wait_for_release(release_attempt + 1)
								end)
							end
							minetest.after(POLL_INTERVAL, function()
								wait_for_release(1)
							end)
							return
						end
						if resume_attempt >= 80 then
							fail("autonomous profession did not resume after bootstrap reception")
						end
						minetest.after(POLL_INTERVAL, function()
							wait_for_post_reception_resume(resume_attempt + 1)
						end)
					end
					minetest.after(POLL_INTERVAL, function()
						wait_for_post_reception_resume(1)
					end)
					return
				end
				if reception_attempt >= PHASE_TIMEOUT_POLLS then
					fail("autonomous did not receive the exact physical bootstrap delivery: "
						.. reception_status())
				elseif reception_attempt == 10 or reception_attempt == 50
						or reception_attempt == 200 then
					minetest.log("action", "PHYSICAL_DELIVERY_BOOTSTRAP_STATUS:"
						.. reception_status())
				end
				minetest.after(POLL_INTERVAL, function()
					wait_for_reception(reception_attempt + 1)
				end)
			end
			minetest.after(POLL_INTERVAL, function()
				wait_for_reception(1)
			end)
			return
		end
		if attempt >= 80 then
			fail("autonomous profession did not continue while outbound request was reserved")
		end
		minetest.after(POLL_INTERVAL, function()
			wait_for_profession_resume(attempt + 1)
		end)
	end
	minetest.after(POLL_INTERVAL, function()
		wait_for_profession_resume(1)
	end)
end

local function run_phase_one()
	setup_pad()
	local item_name = choose_resource()
	local requester = create_villager(
		REQUESTER_ENTITY, {x = 12, y = 1, z = 0}, REQUESTER_JOB, "requester")
	local supplier = create_villager(
		SUPPLIER_ENTITY, {x = -12, y = 1, z = 0}, SUPPLIER_JOB, "supplier")
	local axe = choose_axe()
	if axe then
		supplier:set_wield_item_stack(ItemStack(axe))
	end
	local leftover = supplier:add_item_to_main(ItemStack(item_name .. " " .. INITIAL_SUPPLY))
	assert_true(leftover:is_empty(), "could not provision the supplier inventory")
	assert_equal(count_inventory_item(requester, item_name), 0,
		"requester unexpectedly owns the delivery resource")
	assert_equal(count_inventory_item(supplier, item_name), INITIAL_SUPPLY,
		"supplier does not own the exact initial resource count")

	local movement_start = copy_pos(requester.object:get_pos())
	local resumes_before_movement = job_resume_count(requester)
	local function begin_delivery()
		local requester_pos = copy_pos(requester.object:get_pos())
		local requester_movement = vector.distance(requester_pos, movement_start)
		assert_true(requester_movement >= 0.6,
			"requester was not actively moving before the delivery handshake")
		assert_true(job_resume_count(requester) > resumes_before_movement,
			"requester profession did not run before the delivery interruption")

		local started, task_id = collab.start_task("resource_delivery", requester, {
			items = {[item_name] = REQUEST_COUNT},
			requester_id = requester.inventory_name,
			info = "Physical delivery engine regression with moving requester",
		})
		assert_true(started,
			"could not start production resource_delivery task: " .. tostring(task_id))

		local supplier_pos = copy_pos(supplier.object:get_pos())
		local initial_distance = vector.distance(requester_pos, supplier_pos)
		assert_true(initial_distance > PHASE_ONE_MIN_REMAINING_DISTANCE + 4,
			"test villagers were not created far enough apart")
		local state = {
			phase = 1,
			task_id = task_id,
			item_name = item_name,
			requester_id = requester.inventory_name,
			supplier_id = supplier.inventory_name,
			requester_pos = requester_pos,
			requester_pre_delivery_movement = requester_movement,
			requester_resume_count_before_delivery = job_resume_count(requester),
			supplier_start_pos = supplier_pos,
			initial_distance = initial_distance,
		}
		assert_task_shape(collab.get(task_id), state)
		save_state(state)

		local requester_count, supplier_count = assert_conserved(requester, supplier, item_name)
		assert_equal(requester_count, 0, "resource transferred synchronously at task creation")
		assert_equal(supplier_count, INITIAL_SUPPLY, "supplier stock changed at task creation")
		local rendezvous_observed = false
		local paused_resume_count = nil
		local pause_stable_polls = 0

		local function poll(attempt)
			assert_true(requester.object and requester.object:get_pos(), "requester unloaded during phase one")
			assert_true(supplier.object and supplier.object:get_pos(), "supplier unloaded during phase one")
			local distance = vector.distance(requester.object:get_pos(), supplier.object:get_pos())
			requester_count, supplier_count = assert_conserved(requester, supplier, item_name)
			if distance > ARRIVAL_RADIUS then
				assert_equal(requester_count, 0, "resource transferred before physical proximity")
				assert_equal(supplier_count, INITIAL_SUPPLY, "supplier stock changed before physical proximity")
			end
			assert_task_shape(collab.get(task_id), state)

			local incoming = requester.job_data
				and requester.job_data.physical_delivery_incoming or nil
			if type(incoming) == "table" and next(incoming) ~= nil then
				if requester.disp_action == "attend une livraison" then
					rendezvous_observed = true
					local current_resumes = job_resume_count(requester)
					if paused_resume_count == current_resumes then
						pause_stable_polls = pause_stable_polls + 1
					else
						paused_resume_count = current_resumes
						pause_stable_polls = 0
					end
				end
			end

			local supplier_movement = vector.distance(supplier.object:get_pos(), supplier_pos)
			local progress = initial_distance - distance
			if supplier_movement >= 0.75 and progress >= 0.75
					and distance > PHASE_ONE_MIN_REMAINING_DISTANCE
					and rendezvous_observed and pause_stable_polls >= 3 then
				state.phase_one_supplier_pos = copy_pos(supplier.object:get_pos())
				state.phase_one_distance = distance
				state.phase_one_requester_pos = copy_pos(requester.object:get_pos())
				state.phase_one_requester_resume_count = job_resume_count(requester)
				save_state(state)
				minetest.log("action", "PHYSICAL_DELIVERY_MOVING_REQUESTER_OK:" .. profile)
				minetest.log("action", "PHYSICAL_DELIVERY_RENDEZVOUS_OK:" .. profile)
				minetest.log("action", "PHYSICAL_DELIVERY_NO_REMOTE_TRANSFER_OK:" .. profile)
				minetest.log("action", "PHYSICAL_DELIVERY_PHASE1_OK:" .. profile)
				request_clean_shutdown("physical delivery phase one completed; restart the same world")
				return
			end
			if attempt >= PHASE_TIMEOUT_POLLS then
				fail("supplier did not travel physically toward the moving requester in phase one")
			end
			minetest.after(POLL_INTERVAL, function()
				poll(attempt + 1)
			end)
		end
		minetest.after(POLL_INTERVAL, function()
			poll(1)
		end)
	end

	local function drive_requester(attempt)
		assert_true(requester.object and requester.object:get_pos(),
			"requester unloaded before the delivery handshake")
		requester:change_direction({x = 17, y = 1, z = 0})
		requester:set_animation(working_villages.animation_frames.WALK)
		local moved = vector.distance(requester.object:get_pos(), movement_start)
		if moved >= 0.6 and job_resume_count(requester) > resumes_before_movement then
			begin_delivery()
			return
		end
		if attempt >= 50 then
			fail("could not establish an actively moving real requester")
		end
		minetest.after(POLL_INTERVAL, function()
			drive_requester(attempt + 1)
		end)
	end
	minetest.after(POLL_INTERVAL, function()
		drive_requester(1)
	end)
end

local function wait_for_reloaded_entities(state, attempt, callback)
	local requester = find_loaded_villager(state.requester_id)
	local supplier = find_loaded_villager(state.supplier_id)
	if requester and supplier then
		callback(requester, supplier)
		return
	end
	if attempt >= 120 then
		fail("persisted real villagers did not reactivate after restart")
	end
	minetest.after(0.1, function()
		wait_for_reloaded_entities(state, attempt + 1, callback)
	end)
end

local function run_phase_two(state)
	setup_pad()
	wait_for_reloaded_entities(state, 1, function(requester, supplier)
		assert_equal(requester.owner_name, OWNER, "requester owner changed after restart")
		assert_equal(supplier.owner_name, OWNER, "supplier owner changed after restart")
		assert_equal(requester:get_job_name(), REQUESTER_JOB, "requester job changed after restart")
		assert_equal(supplier:get_job_name(), SUPPLIER_JOB, "supplier job changed after restart")
		set_safe_needs(requester)
		set_safe_needs(supplier)
		assert_task_shape(collab.get(state.task_id), state)
		local requester_count, supplier_count = assert_conserved(
			requester, supplier, state.item_name)
		assert_equal(requester_count, 0, "resource crossed the restart at range")
		assert_equal(supplier_count, INITIAL_SUPPLY, "supplier stock changed across restart")
		local persisted_delivery = supplier.job_data
			and supplier.job_data.physical_delivery_state or nil
		assert_true(type(persisted_delivery) == "table",
			"supplier lost its physical delivery state across restart")
		assert_true(type(persisted_delivery.rendezvous_pos) == "table",
			"supplier lost its stable rendezvous across restart")
		assert_true(type(supplier.job_data.pending_resource_message) == "table",
			"supplier lost its exact pending message across restart")
		minetest.log("action", "PHYSICAL_DELIVERY_RELOAD_OK:" .. profile)

		local resumed_movement = false
		local transfer_observed = false
		local restart_rendezvous_observed = false
		local function poll(attempt)
			assert_true(requester.object and requester.object:get_pos(), "requester unloaded during phase two")
			assert_true(supplier.object and supplier.object:get_pos(), "supplier unloaded during phase two")
			local requester_pos = requester.object:get_pos()
			local supplier_pos = supplier.object:get_pos()
			local distance = vector.distance(requester_pos, supplier_pos)
			local moved_since_restart = vector.distance(supplier_pos, state.phase_one_supplier_pos)
			if moved_since_restart >= 0.5 and distance <= state.phase_one_distance - 0.5 then
				resumed_movement = true
			end
			local incoming = requester.job_data
				and requester.job_data.physical_delivery_incoming or nil
			if type(incoming) == "table" and next(incoming) ~= nil
					and requester.disp_action == "attend une livraison" then
				restart_rendezvous_observed = true
			end

			requester_count, supplier_count = assert_conserved(requester, supplier, state.item_name)
			if not transfer_observed and requester_count > 0 then
				assert_true(distance <= ARRIVAL_RADIUS,
					"first resource transfer occurred outside the arrival radius")
				assert_equal(requester_count, REQUEST_COUNT, "arrival transfer was partial or excessive")
				assert_equal(supplier_count, INITIAL_SUPPLY - REQUEST_COUNT,
					"supplier retained the wrong amount after arrival")
				transfer_observed = true
			elseif not transfer_observed and distance > ARRIVAL_RADIUS then
				assert_equal(requester_count, 0, "resource transferred before proximity after restart")
				assert_equal(supplier_count, INITIAL_SUPPLY,
					"supplier stock changed before proximity after restart")
			elseif transfer_observed then
				assert_equal(requester_count, REQUEST_COUNT, "delivery duplicated while completion was pending")
				assert_equal(supplier_count, INITIAL_SUPPLY - REQUEST_COUNT,
					"supplier stock changed again while completion was pending")
			end

			local record = collab.get(state.task_id)
			if record and record.state == "completed" then
				assert_true(resumed_movement, "supplier did not resume physical travel after restart")
				assert_true(transfer_observed, "task completed without an observed physical transfer")
				assert_true(restart_rendezvous_observed,
					"requester did not restore its rendezvous wait after restart")
				local delivered = record.result and record.result.delivered_items
				assert_equal(delivered and delivered[state.item_name], REQUEST_COUNT,
					"completed task recorded the wrong delivered count")
				local resumes_at_completion = job_resume_count(requester)
				local function verify_resumed(resume_attempt)
					local final_requester, final_supplier = assert_conserved(
						requester, supplier, state.item_name)
					assert_equal(final_requester, REQUEST_COUNT,
						"requester inventory duplicated after task completion")
					assert_equal(final_supplier, INITIAL_SUPPLY - REQUEST_COUNT,
						"supplier inventory changed after task completion")
					local final_record = collab.get(state.task_id)
					assert_true(final_record and final_record.state == "completed",
						"completed collaborative task did not remain terminal")
					if job_resume_count(requester) <= resumes_at_completion then
						if resume_attempt >= 50 then
							fail("requester profession did not resume after physical delivery")
						end
						minetest.after(POLL_INTERVAL, function()
							verify_resumed(resume_attempt + 1)
						end)
						return
					end
					assert_true(requester.disp_action ~= "attend une livraison",
						"requester remained stuck in the delivery wait action")
					assert_equal(requester:get_job_name(), REQUESTER_JOB,
						"requester resumed a different profession after delivery")
					run_cycle_regression(requester, supplier, function()
						state.phase = 2
						save_state(state)
						minetest.log("action", "PHYSICAL_DELIVERY_MOVEMENT_OK:" .. profile)
						minetest.log("action", "PHYSICAL_DELIVERY_EXACT_OK:" .. profile)
						minetest.log("action", "PHYSICAL_DELIVERY_PERSISTENCE_OK:" .. profile)
						minetest.log("action", "PHYSICAL_DELIVERY_TASK_RESUME_OK:" .. profile)
						minetest.log("action", "PHYSICAL_DELIVERY_RUNTIME_OK:" .. profile)
						request_clean_shutdown("physical delivery persistence test completed")
					end)
				end
				minetest.after(POLL_INTERVAL, function()
					verify_resumed(1)
				end)
				return
			end
			if not record then
				fail("collaborative task disappeared during phase two")
			end
			if record.state ~= "active" then
				fail("collaborative task entered unexpected state " .. tostring(record.state))
			end
			if attempt >= PHASE_TIMEOUT_POLLS then
				fail("physical delivery did not complete after restart")
			end
			minetest.after(POLL_INTERVAL, function()
				poll(attempt + 1)
			end)
		end
		minetest.after(POLL_INTERVAL, function()
			poll(1)
		end)
	end)
end

local function run_completed_recheck(state)
	setup_pad()
	wait_for_reloaded_entities(state, 1, function(requester, supplier)
		local requester_count, supplier_count = assert_conserved(
			requester, supplier, state.item_name)
		assert_equal(requester_count, REQUEST_COUNT, "completed delivery duplicated on later restart")
		assert_equal(supplier_count, INITIAL_SUPPLY - REQUEST_COUNT,
			"completed supplier stock changed on later restart")
		assert_equal(count_inventory_item(requester, CYCLE_ITEM), 1,
			"completed cross delivery changed requester tokens on later restart")
		assert_equal(count_inventory_item(supplier, CYCLE_ITEM), 1,
			"completed cross delivery changed supplier tokens on later restart")
		assert_equal(count_dropped_item(CYCLE_ITEM), 0,
			"completed cross delivery dropped a token on later restart")
		local record = collab.get(state.task_id)
		assert_true(record and record.state == "completed",
			"completed delivery task changed state on later restart")
		minetest.log("action", "PHYSICAL_DELIVERY_RECHECK_OK:" .. profile)
		request_clean_shutdown("physical delivery completed-state recheck finished")
	end)
end

minetest.after(0, function()
	assert_true(collab and collab.start_task and collab.get,
		"production collaborative task API is unavailable")
	local state = load_state()
	if not state then
		run_bootstrap_reservation_regression(run_phase_one)
	elseif state.phase == 1 then
		run_phase_two(state)
	elseif state.phase == 2 then
		run_completed_recheck(state)
	else
		fail("unknown persisted harness phase " .. tostring(state.phase))
	end
end)
