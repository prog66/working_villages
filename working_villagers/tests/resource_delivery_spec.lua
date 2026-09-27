-- Standalone regression tests for the production resource-delivery slice.
-- Run from the repository root with:
--   lua5.1 working_villagers/tests/resource_delivery_spec.lua working_villagers

local modpath = assert(arg and arg[1], "working_villages mod path is required")

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected)
			.. ", got " .. tostring(actual), 2)
	end
end

local function assert_true(value, message)
	if not value then
		error(message or "expected a truthy value", 2)
	end
end

local saved_globals = {
	working_villages = _G.working_villages,
	minetest = _G.minetest,
	vector = _G.vector,
	inventory_access = _G.inventory_access,
	is_food_item = _G.is_food_item,
	is_chest_pos = _G.is_chest_pos,
	find_shared_storage_chest_for_item = _G.find_shared_storage_chest_for_item,
}

local function restore_globals()
	_G.working_villages = saved_globals.working_villages
	_G.minetest = saved_globals.minetest
	_G.vector = saved_globals.vector
	_G.inventory_access = saved_globals.inventory_access
	_G.is_food_item = saved_globals.is_food_item
	_G.is_chest_pos = saved_globals.is_chest_pos
	_G.find_shared_storage_chest_for_item = saved_globals.find_shared_storage_chest_for_item
end

local function make_stack(name, count)
	local stack = {
		name = name or "",
		count = math.max(0, math.floor(tonumber(count) or 0)),
	}
	function stack:is_empty()
		return self.name == "" or self.count <= 0
	end
	function stack:get_name()
		return self.name
	end
	function stack:get_count()
		return self.count
	end
	function stack:take_item(requested)
		local moved = math.min(self.count, math.max(0, math.floor(tonumber(requested) or 0)))
		local result = make_stack(self.name, moved)
		self.count = self.count - moved
		if self.count <= 0 then
			self.name = ""
		end
		return result
	end
	function stack:add_item(other)
		if not other or other:is_empty() then
			return make_stack()
		end
		if self:is_empty() then
			self.name = other:get_name()
			self.count = other:get_count()
			return make_stack()
		end
		if self.name == other:get_name() then
			self.count = self.count + other:get_count()
			return make_stack()
		end
		return make_stack(other:get_name(), other:get_count())
	end
	return stack
end

local function make_inventory(items)
	local inv = {slots = {}}
	for index, entry in ipairs(items or {}) do
		inv.slots[index] = make_stack(entry[1], entry[2])
	end
	function inv:get_size(listname)
		assert_equal(listname, "main", "unexpected inventory list")
		return math.max(8, #self.slots)
	end
	function inv:get_stack(listname, index)
		assert_equal(listname, "main", "unexpected inventory list")
		self.slots[index] = self.slots[index] or make_stack()
		return self.slots[index]
	end
	function inv:set_stack(listname, index, stack)
		assert_equal(listname, "main", "unexpected inventory list")
		self.slots[index] = stack
	end
	function inv:add_item(stack)
		if not stack or stack:is_empty() then
			return make_stack()
		end
		for index = 1, self:get_size("main") do
			local current = self:get_stack("main", index)
			if current:is_empty() or current:get_name() == stack:get_name() then
				current:add_item(make_stack(stack:get_name(), stack:get_count()))
				self:set_stack("main", index, current)
				return make_stack()
			end
		end
		return make_stack(stack:get_name(), stack:get_count())
	end
	return inv
end

local function inventory_count(inv, item_name)
	local total = 0
	for index = 1, inv:get_size("main") do
		local stack = inv:get_stack("main", index)
		if not stack:is_empty() and stack:get_name() == item_name then
			total = total + stack:get_count()
		end
	end
	return total
end

local game_time = 100
local registry = {}
local craft_calls = 0
local craft_behavior = nil
local shared_storage_pos = nil
local shared_storage_inventory = make_inventory({})
local collaborative_records = {
	task_old = {id = "task_old", state = "active", owner_name = "owner"},
	task_zero = {id = "task_zero", state = "active", owner_name = "owner"},
}

_G.vector = {
	new = function(pos)
		return pos and {x = pos.x, y = pos.y, z = pos.z} or nil
	end,
	round = function(pos)
		return {x = math.floor(pos.x + 0.5), y = math.floor(pos.y + 0.5),
			z = math.floor(pos.z + 0.5)}
	end,
	distance = function(a, b)
		local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
		return math.sqrt(dx * dx + dy * dy + dz * dz)
	end,
}

_G.minetest = {
	get_gametime = function() return game_time end,
	get_item_group = function(item_name, group)
		if item_name == "test:pick" and group == "pickaxe" then
			return 1
		end
		return 0
	end,
}

local communication = {}
function communication.consume_messages(self)
	local messages = self.job_data.inbox or {}
	self.job_data.inbox = {}
	return messages
end
function communication.find_villager_by_inventory_name(inventory_name)
	return registry[inventory_name]
end
function communication.send_message(from, to, message_type, data)
	if not to then return false end
	to.job_data = to.job_data or {}
	to.job_data.inbox = to.job_data.inbox or {}
	table.insert(to.job_data.inbox, {
		from = from and from.inventory_name or "villager",
		type = message_type,
		data = data or {},
		time = game_time,
	})
	return true
end

_G.working_villages = {
	villager = {},
	communication = communication,
	animation_frames = {STAND = {x = 0, y = 0}},
	crafting = {
		ensure_item = function(self, item_name, count, opts)
			craft_calls = craft_calls + 1
			if craft_behavior then
				return craft_behavior(self, item_name, count, opts)
			end
			return false
		end,
	},
	collaborative_tasks = {
		get = function(task_id) return collaborative_records[task_id] end,
		update = function(task_id, updates)
			local record = collaborative_records[task_id]
			if not record or record.state ~= "active" then return false end
			for key, value in pairs(updates or {}) do record[key] = value end
			return true, record
		end,
		complete = function(task_id, result)
			local record = collaborative_records[task_id]
			if not record or record.state ~= "active" then return false end
			record.state = "completed"
			record.result = result
			return true, record
		end,
		fail = function(task_id)
			local record = collaborative_records[task_id]
			if record then record.state = "failed" end
		end,
	},
}
_G.inventory_access = {put_from_inventory = function(_, source_inv, source_list,
		source_index, target_pos, target_list, target_index, requested)
	if not shared_storage_pos or not target_pos
			or vector.distance(shared_storage_pos, target_pos) > 0.01 then
		return 0
	end
	local stack = source_inv:get_stack(source_list, source_index)
	local taken = stack:take_item(requested)
	local before = taken:get_count()
	local leftover = shared_storage_inventory:add_item(taken)
	if leftover and not leftover:is_empty() then stack:add_item(leftover) end
	source_inv:set_stack(source_list, source_index, stack)
	return before - (leftover and leftover:get_count() or 0)
end}
_G.is_food_item = function(item_name) return item_name == "test:food" end
_G.is_chest_pos = function(pos)
	return shared_storage_pos ~= nil and pos ~= nil
		and vector.distance(shared_storage_pos, pos) <= 0.01
end
_G.find_shared_storage_chest_for_item = function()
	return shared_storage_pos
end

local source_file = assert(io.open(modpath .. "/api.lua", "rb"))
local api_source = source_file:read("*a")
source_file:close()
local slice_start = assert(api_source:find("local physical_delivery_coordination = {", 1, true),
	"resource-delivery slice start was not found")
local slice_end = assert(api_source:find(
	"\nfunction working_villages.villager:count_shared_storage_items", slice_start, true),
	"resource-delivery slice end was not found")
local delivery_chunk = api_source:sub(slice_start, slice_end - 1)
	.. "\nreturn physical_delivery_coordination\n"
local load_chunk = loadstring or load
local compiled, compile_error = load_chunk(delivery_chunk, "@resource_delivery_api_slice")
assert_true(compiled, "resource-delivery slice did not compile: " .. tostring(compile_error))
-- Lua 5.1's loadstring uses the process-global environment, not the caller's
-- isolated fake-Luanti environment. Keep the production slice inside this
-- spec so an engine run cannot overwrite methods on the live mod table.
if setfenv and getfenv then
	setfenv(compiled, getfenv(1))
end
local coordination = compiled()

local function make_villager(inventory_name, pos, items)
	local entity = setmetatable({
		inventory_name = inventory_name,
		owner_name = "owner",
		job_data = {inbox = {}},
		inventory = make_inventory(items),
		position = {x = pos.x, y = pos.y, z = pos.z},
		delivery_go_calls = 0,
		wait_go_calls = 0,
		cancelled = {},
	}, {__index = working_villages.villager})
	entity.object = {
		get_pos = function()
			return {x = entity.position.x, y = entity.position.y, z = entity.position.z}
		end,
		set_velocity = function() end,
	}
	function entity:get_inventory() return self.inventory end
	function entity:add_item_to_main(stack) return self.inventory:add_item(stack) end
	function entity:ensure_shared_storage_pos() return shared_storage_pos end
	function entity:get_shared_storage_chest_for_item() return shared_storage_pos end
	function entity:reserve_position() return true end
	function entity:release_reserved_position() return true end
	function entity:set_displayed_action(value) self.displayed_action = value end
	function entity:set_state_info(value) self.state_info = value end
	function entity:set_animation(value) self.animation = value end
	function entity:cancel_go_to_step(key)
		self.cancelled[#self.cancelled + 1] = key
		return true
	end
	function entity:go_to_step(_, key)
		if key == "resource_delivery_wait" then
			self.wait_go_calls = self.wait_go_calls + 1
		else
			self.delivery_go_calls = self.delivery_go_calls + 1
		end
		return nil
	end
	registry[inventory_name] = entity
	return entity
end

local test_ok, test_error = xpcall(function()
	-- The active non-bootstrap pending message remains first among ordinary
	-- traffic, while bootstrap messages are sorted deterministically ahead of it.
	local sorter = make_villager("sorter", {x = 0, y = 0, z = 0}, {})
	local pending_normal = {
		from = "normal", type = "help_needed", time = 5,
		data = {items = {['test:stone'] = 1}, requester_id = "normal"},
	}
	local bootstrap_z = {
		from = "bootstrap", type = "help_needed", time = 20,
		data = {items = {['test:wood'] = 1}, requester_id = "z_requester",
			bootstrap_infrastructure = true},
	}
	local bootstrap_a = {
		from = "bootstrap", type = "help_needed", time = 20,
		data = {items = {['test:wood'] = 1}, requester_id = "a_requester",
			bootstrap_infrastructure = true},
	}
	local danger = {from = "guard", type = "danger_alert", time = 1, data = {}}
	sorter.job_data.pending_resource_message = pending_normal
	sorter.job_data.inbox = {bootstrap_z, danger, bootstrap_a}
	local ordered = coordination.collect_messages(sorter, communication)
	assert_equal(ordered[1], bootstrap_a, "bootstrap tie-break is not deterministic")
	assert_equal(ordered[2], bootstrap_z, "second bootstrap request order changed")
	assert_equal(ordered[3], pending_normal, "ordinary inbox preempted active pending work")
	assert_equal(ordered[4], danger, "non-delivery message was lost during merge")

	local requester_old = make_villager("requester_old", {x = 20, y = 0, z = 0}, {})
	local requester_boot = make_villager("requester_boot", {x = 10, y = 0, z = 0}, {})
	local supplier = make_villager("supplier", {x = 0, y = 0, z = 0}, {
		{"test:stone", 1}, {"test:wood", 1},
	})
	local old_message = {
		from = requester_old.inventory_name, type = "help_needed", time = 10,
		data = {items = {['test:stone'] = 1}, requester_id = requester_old.inventory_name,
			task_id = "task_old"},
	}
	supplier.job_data.inbox = {old_message}
	assert_true(supplier:process_resource_requests(), "ordinary delivery did not become pending")
	assert_equal(supplier.job_data.pending_resource_message, old_message,
		"ordinary pending message was not retained")
	assert_equal(inventory_count(supplier.inventory, "test:stone"), 1,
		"ordinary delivery moved cargo before reaching its target")

	-- With no queued bootstrap, an older incoming delivery is allowed to hold
	-- the supplier at its rendezvous.
	local incoming_supplier = make_villager("incoming_supplier", {x = -20, y = 0, z = 0}, {})
	incoming_supplier.job_data.physical_delivery_state = {delivery_key = "incoming_normal"}
	supplier.job_data.physical_delivery_incoming = {
		incoming_normal = {
			delivery_key = "incoming_normal",
			priority = "000000000001|direct|incoming_supplier|supplier",
			order = "000000000001|direct|incoming_supplier|supplier|incoming_normal",
			supplier_id = incoming_supplier.inventory_name,
			requester_id = supplier.inventory_name,
			rendezvous_pos = {x = 5, y = 0, z = 0},
			remaining = 5,
		},
	}
	assert_true(coordination.handle_incoming(supplier, 0.1),
		"ordinary incoming delivery was not honoured before bootstrap arrived")
	assert_equal(supplier.wait_go_calls, 1, "ordinary incoming rendezvous did not start")

	local bootstrap_message = {
		from = requester_boot.inventory_name, type = "help_needed", time = 20,
		data = {items = {['test:wood'] = 1}, requester_id = requester_boot.inventory_name,
			bootstrap_infrastructure = true},
	}
	local preserved_danger = {
		from = "guard", type = "danger_alert", time = 30, data = {},
	}
	supplier.job_data.inbox = {preserved_danger, bootstrap_message}
	assert_equal(coordination.handle_incoming(supplier, 0.1), false,
		"queued bootstrap was hidden behind an incoming rendezvous")
	assert_equal(supplier.wait_go_calls, 1,
		"supplier kept walking toward incoming work after bootstrap became visible")

	assert_true(supplier:process_resource_requests(), "bootstrap delivery did not preempt")
	assert_equal(supplier.job_data.pending_resource_message, bootstrap_message,
		"bootstrap request did not become the active pending delivery")
	assert_true(supplier.job_data.physical_delivery_state.bootstrap_infrastructure == true,
		"bootstrap priority was not stored in the active state")
	assert_true(supplier.job_data.physical_delivery_state.order:match("^0|") ~= nil,
		"bootstrap active order lacks its migration-safe priority prefix")
	assert_equal(supplier.job_data.inbox[1], old_message,
		"preempted ordinary message was not restored at the front of the queue")
	assert_equal(supplier.job_data.inbox[2], preserved_danger,
		"non-delivery message was lost while preempting")
	assert_equal(inventory_count(supplier.inventory, "test:wood"), 1,
		"bootstrap cargo moved before proximity")
	assert_equal(inventory_count(supplier.inventory, "test:stone"), 1,
		"preemption lost the previous delivery cargo")
	assert_equal(collaborative_records.task_old.state, "active",
		"preemption failed the collaborative task")

	-- Complete bootstrap, then observe the previous delivery resume unchanged.
	supplier.position = {x = 10, y = 0, z = 0}
	assert_true(supplier:process_resource_requests(),
		"preempted ordinary delivery did not resume after bootstrap")
	assert_equal(inventory_count(supplier.inventory, "test:wood"), 0,
		"bootstrap supplier did not transfer exactly one wood")
	assert_equal(inventory_count(requester_boot.inventory, "test:wood"), 1,
		"bootstrap requester did not receive exactly one wood")
	assert_equal(inventory_count(supplier.inventory, "test:stone"), 1,
		"resumed delivery moved stone before reaching its requester")
	assert_equal(supplier.job_data.pending_resource_message, old_message,
		"old request did not resume as pending")
	assert_equal(supplier.job_data.inbox[1], preserved_danger,
		"non-delivery message did not survive the second deferral")

	supplier.position = {x = 20, y = 0, z = 0}
	assert_equal(supplier:process_resource_requests(), false,
		"completed delivery left a spurious pending state")
	assert_equal(inventory_count(supplier.inventory, "test:stone"), 0,
		"ordinary supplier did not transfer exactly one stone")
	assert_equal(inventory_count(requester_old.inventory, "test:stone"), 1,
		"ordinary requester did not receive exactly one stone")
	assert_equal(inventory_count(supplier.inventory, "test:wood")
		+ inventory_count(requester_boot.inventory, "test:wood"), 1,
		"bootstrap preemption duplicated or lost wood")
	assert_equal(inventory_count(supplier.inventory, "test:stone")
		+ inventory_count(requester_old.inventory, "test:stone"), 1,
		"ordinary resume duplicated or lost stone")
	assert_equal(supplier.job_data.danger_ticks, 200,
		"preserved non-delivery message was not eventually processed")

	-- Empty item, tool and food requests must all be deferred without a single
	-- navigation call; the loop still reaches the following danger message and
	-- every request remains persisted behind a relative backoff.
	local empty_supplier = make_villager("empty_supplier", {x = 0, y = 0, z = 0}, {})
	local zero_requester = make_villager("zero_requester", {x = 12, y = 0, z = 0}, {})
	local craft_calls_before = craft_calls
	empty_supplier.job_data.inbox = {
		{from = "zero", type = "help_needed", time = 1,
			data = {items = {['test:missing'] = 2}, requester_id = zero_requester.inventory_name,
				task_id = "task_zero", bootstrap_infrastructure = true}},
		{from = "zero", type = "help_needed", time = 2,
			data = {tool_group = "pickaxe", count = 1,
				requester_id = zero_requester.inventory_name}},
		{from = "zero", type = "help_needed", time = 3,
			data = {resource = "food", count = 2,
				requester_id = zero_requester.inventory_name}},
		{from = "guard", type = "danger_alert", time = 4, data = {}},
	}
	assert_equal(empty_supplier:process_resource_requests(), false,
		"zero-stock requests created pending delivery work")
	assert_equal(empty_supplier.delivery_go_calls, 0,
		"zero-stock request started a physical trip")
	assert_equal(craft_calls, craft_calls_before + 1,
		"item request did not attempt local crafting before rejection")
	assert_equal(empty_supplier.job_data.danger_ticks, 200,
		"zero-stock rejection stopped the message loop")
	assert_equal(collaborative_records.task_zero.state, "active",
		"zero-stock supplier incorrectly failed the collaborative task")
	assert_true(empty_supplier.job_data.pending_resource_message == nil
		and empty_supplier.job_data.physical_delivery_state == nil,
		"zero-stock rejection left delivery state behind")
	assert_equal(#empty_supplier.job_data.inbox, 3,
		"zero-stock retry lost or duplicated a request")
	for _, retry_message in ipairs(empty_supplier.job_data.inbox) do
		assert_equal(retry_message.supply_retry.attempts, 1,
			"first shortage did not record one bounded retry")
		assert_equal(retry_message.supply_retry.remaining, 5,
			"first shortage backoff is not the expected relative duration")
	end

	-- A successful local craft is visible before the first navigation step.
	local event_order = {}
	local crafted_supplier = make_villager("crafted_supplier", {x = 0, y = 0, z = 0}, {})
	local crafted_requester = make_villager("crafted_requester", {x = 15, y = 0, z = 0}, {})
	craft_behavior = function(self, item_name, count)
		event_order[#event_order + 1] = "craft"
		self.inventory:add_item(make_stack(item_name, count))
		return true
	end
	function crafted_supplier:go_to_step(_, key)
		assert_equal(key, "resource_delivery", "crafted request used another navigation key")
		event_order[#event_order + 1] = "go"
		self.delivery_go_calls = self.delivery_go_calls + 1
		return nil
	end
	crafted_supplier.job_data.inbox = {{
		from = crafted_requester.inventory_name, type = "help_needed", time = 50,
		data = {items = {['test:crafted'] = 1}, requester_id = crafted_requester.inventory_name},
	}}
	assert_true(crafted_supplier:process_resource_requests(),
		"crafted stock did not start a pending delivery")
	assert_equal(event_order[1], "craft", "navigation started before local crafting")
	assert_equal(event_order[2], "go", "crafted stock never entered navigation")
	assert_equal(inventory_count(crafted_supplier.inventory, "test:crafted"), 1,
		"preflight craft result is not real supplier stock")

	craft_behavior = nil

	-- A shared-storage hand-off must credit the durable collaborative ledger
	-- even while the requester entity is unloaded. No synthetic requester or
	-- resource_found inbox is needed, and the exact moved count is conserved.
	game_time = 200
	shared_storage_pos = {x = 0, y = 0, z = 0}
	shared_storage_inventory = make_inventory({})
	collaborative_records.task_offline = {
		id = "task_offline",
		name = "resource_delivery",
		state = "active",
		owner_name = "owner",
		initiator = "offline_requester",
		participants = {"offline_supplier"},
		data = {items = {['test:stone'] = 2}},
	}
	registry.offline_requester = nil
	local offline_supplier = make_villager("offline_supplier", {x = 0, y = 0, z = 0}, {
		{"test:stone", 3},
	})
	offline_supplier.job_data.inbox = {{
		from = "offline_requester", type = "help_needed", time = 200,
		data = {items = {['test:stone'] = 2}, requester_id = "offline_requester",
			task_id = "task_offline"},
	}}
	assert_equal(offline_supplier:process_resource_requests(), false,
		"offline requester delivery left spurious pending work")
	assert_equal(inventory_count(offline_supplier.inventory, "test:stone"), 1,
		"offline delivery removed the wrong supplier quantity")
	assert_equal(inventory_count(shared_storage_inventory, "test:stone"), 2,
		"offline delivery did not put the exact quantity in shared storage")
	assert_equal(collaborative_records.task_offline.data.delivery_progress.items['test:stone'], 2,
		"offline delivery was not credited exactly once")
	assert_equal(collaborative_records.task_offline.state, "completed",
		"offline shared-storage delivery did not complete its task")

	-- Stock retries use a persisted remaining duration. A gametime rollback to
	-- zero simulates a server restart and must preserve five seconds of backoff,
	-- not reinterpret the old clock value as a multi-thousand-second deadline.
	shared_storage_pos = nil
	game_time = 5000
	collaborative_records.task_retry = {
		id = "task_retry", name = "resource_delivery", state = "active",
		owner_name = "owner", initiator = "retry_requester",
		participants = {"retry_supplier"}, data = {items = {['test:missing'] = 1}},
	}
	local retry_supplier = make_villager("retry_supplier", {x = 0, y = 0, z = 0}, {})
	retry_supplier.job_data.inbox = {{
		from = "retry_requester", type = "help_needed", time = 5000,
		data = {items = {['test:missing'] = 1}, requester_id = "retry_requester",
			task_id = "task_retry"},
	}}
	assert_equal(retry_supplier:process_resource_requests(), false)
	assert_equal(retry_supplier.job_data.inbox[1].supply_retry.remaining, 5)
	game_time = 0
	assert_equal(retry_supplier:process_resource_requests(), false)
	assert_equal(retry_supplier.job_data.inbox[1].supply_retry.remaining, 5,
		"restart rollback expanded or consumed the relative stock backoff")
	game_time = 4
	assert_equal(retry_supplier:process_resource_requests(), false)
	assert_equal(retry_supplier.job_data.inbox[1].supply_retry.remaining, 1)
	game_time = 5
	assert_equal(retry_supplier:process_resource_requests(), false)
	assert_equal(retry_supplier.job_data.inbox[1].supply_retry.attempts, 2,
		"stock request did not retry when its relative backoff elapsed")
	game_time = 15
	retry_supplier:process_resource_requests()
	game_time = 35
	retry_supplier:process_resource_requests()
	game_time = 65
	retry_supplier:process_resource_requests()
	assert_equal(#retry_supplier.job_data.inbox, 0,
		"bounded stock retry remained queued after its final attempt")
	assert_equal(collaborative_records.task_retry.state, "failed",
		"exhausted collaborative shortage did not release the task")
	assert_equal(retry_supplier.delivery_go_calls, 0,
		"stock retry started a trip without physical cargo")

	-- The unavailable-target timeout is also relative across restart. Cargo is
	-- retained and the pending state expires after 120 new-session seconds.
	game_time = 5000
	local waiting_supplier = make_villager("waiting_supplier", {x = 0, y = 0, z = 0}, {
		{"test:stone", 1},
	})
	waiting_supplier.job_data.inbox = {{
		from = "offline_wait", type = "help_needed", time = 5000,
		data = {items = {['test:stone'] = 1}, requester_id = "offline_wait"},
	}}
	assert_true(waiting_supplier:process_resource_requests(),
		"unavailable target did not retain a pending delivery")
	game_time = 0
	assert_true(waiting_supplier:process_resource_requests(),
		"restart discarded the pending unavailable-target delivery")
	game_time = 119
	assert_true(waiting_supplier:process_resource_requests(),
		"relative target wait expired too early after restart")
	game_time = 120
	assert_equal(waiting_supplier:process_resource_requests(), false,
		"relative target wait did not expire at its bounded TTL")
	assert_equal(inventory_count(waiting_supplier.inventory, "test:stone"), 1,
		"target timeout consumed cargo without a physical hand-off")

	-- Legacy saves may still contain the first implementation's absolute
	-- retry_at. On a new-session clock it is capped to a short relative wait.
	game_time = 0
	local legacy_requester = make_villager("legacy_requester", {x = 12, y = 0, z = 0}, {})
	local legacy_supplier = make_villager("legacy_supplier", {x = 0, y = 0, z = 0}, {
		{"test:stone", 1},
	})
	local legacy_message = {
		from = "legacy_requester", type = "help_needed", time = 5000,
		data = {items = {['test:stone'] = 1}, requester_id = "legacy_requester"},
	}
	legacy_supplier.job_data.pending_resource_message = legacy_message
	legacy_supplier.job_data.physical_delivery_state = {
		delivery_key = coordination.message_key(legacy_supplier, legacy_message),
		started_at = 5000,
		retry_at = 5000,
		rendezvous_pos = {x = 12, y = 0, z = 0},
	}
	assert_true(legacy_supplier:process_resource_requests())
	assert_equal(legacy_supplier.job_data.physical_delivery_state.retry_remaining, 30,
		"legacy absolute navigation retry was not capped during restart migration")
	assert_equal(legacy_supplier.delivery_go_calls, 0)
	game_time = 29
	assert_true(legacy_supplier:process_resource_requests())
	assert_equal(legacy_supplier.delivery_go_calls, 0,
		"legacy navigation retry resumed before its relative delay")
	game_time = 30
	assert_true(legacy_supplier:process_resource_requests())
	assert_equal(legacy_supplier.delivery_go_calls, 1,
		"legacy navigation retry did not resume after its relative delay")

	-- A stale task message restored from staticdata is discarded before craft or
	-- movement, preventing a completed task from receiving a duplicate delivery.
	game_time = 300
	collaborative_records.task_stale = {
		id = "task_stale", name = "resource_delivery", state = "completed",
		owner_name = "owner", initiator = "stale_requester",
		participants = {"stale_supplier"}, data = {items = {['test:stone'] = 1}},
	}
	local stale_supplier = make_villager("stale_supplier", {x = 0, y = 0, z = 0}, {
		{"test:stone", 1},
	})
	stale_supplier.job_data.inbox = {{
		from = "stale_requester", type = "help_needed", time = 250,
		data = {items = {['test:stone'] = 1}, requester_id = "stale_requester",
			task_id = "task_stale"},
	}}
	assert_equal(stale_supplier:process_resource_requests(), false)
	assert_equal(inventory_count(stale_supplier.inventory, "test:stone"), 1,
		"stale completed task consumed cargo")
	assert_equal(stale_supplier.delivery_go_calls, 0,
		"stale completed task started navigation")
end, debug.traceback)

restore_globals()
if not test_ok then
	error(test_error, 0)
end

print("RESOURCE_DELIVERY_SPEC_OK")
return true
