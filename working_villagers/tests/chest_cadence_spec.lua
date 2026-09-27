local modpath = assert(arg and arg[1], "working_villages mod path is required")

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected)
			.. ", got " .. tostring(actual), 2)
	end
end

local function make_stack(name, count)
	return {
		name = name or "",
		count = count or ((name and name ~= "") and 1 or 0),
		is_empty = function(self) return self.name == "" or self.count <= 0 end,
		get_name = function(self) return self.name end,
		get_count = function(self) return self.count end,
	}
end

local function make_inventory(size)
	local inventory = {slots = {}, size = size}
	function inventory:get_size(listname)
		assert_equal(listname, "main", "unexpected inventory list")
		return self.size
	end
	function inventory:get_stack(listname, index)
		assert_equal(listname, "main", "unexpected inventory list")
		return self.slots[index] or make_stack()
	end
	function inventory:set_stack(index, value)
		self.slots[index] = value
	end
	return inventory
end

local chest_pos = {x = 4, y = 2, z = 7}
local villager_inventory = make_inventory(4)
local chest_inventory = make_inventory(4)
local meta_reads = 0
local action_logs = 0

local fake_log = {
	action = function() action_logs = action_logs + 1 end,
	info = function() end,
	warning = function() end,
	error = function() end,
}
local fake_util = {
	is_chest = function(pos) return pos == chest_pos end,
	find_adjacent_clear = function(pos) return {x = pos.x - 1, y = pos.y, z = pos.z} end,
	find_ground_below = function(pos) return pos end,
}

working_villages = {
	villager = {},
	coroutine_can_yield = function() return false end,
	inventory_access = {},
}
function working_villages.require(name)
	local modules = {
		failures = {},
		log = fake_log,
		["jobs/util"] = fake_util,
		pathfinder = {},
		timers = {increment = function() return 1 end},
		inventory_access = working_villages.inventory_access,
	}
	assert(modules[name], "unexpected production dependency " .. tostring(name))
	return modules[name]
end

minetest = {
	registered_items = {},
	registered_nodes = {},
	get_meta = function(pos)
		assert(pos == chest_pos, "cadence probe inspected another container")
		meta_reads = meta_reads + 1
		return {get_inventory = function() return chest_inventory end}
	end,
	get_node = function() return {name = "test:chest", param2 = 0} end,
	facedir_to_dir = function() return {x = 1, y = 0, z = 0} end,
	pos_to_string = function(pos)
		return ("(%d,%d,%d)"):format(pos.x, pos.y, pos.z)
	end,
}

dofile(modpath .. "/async_actions.lua")

local villager = setmetatable({
	inventory_name = "cadence_farmer",
	job_data = {},
	pos_data = {chest_pos = chest_pos},
	time_counters = {},
	state_info = "Je cultive.",
	displayed_action = "cultive",
	go_to_calls = 0,
	transfer_calls = 0,
}, {__index = working_villages.villager})

function villager:get_inventory() return villager_inventory end
function villager:ensure_shared_storage_pos() return chest_pos end
function villager:get_shared_storage_chests() return {chest_pos} end
function villager:set_timer(timer_id, value) self.time_counters[timer_id] = value end
function villager:count_timer(timer_id)
	self.time_counters[timer_id] = (self.time_counters[timer_id] or 0) + 1
end
function villager:timer_exceeded(timer_id, limit)
	if (self.time_counters[timer_id] or 0) < limit then
		return false
	end
	self.time_counters[timer_id] = 0
	return true
end
function villager:set_state_info(value) self.state_info = value end
function villager:set_displayed_action(value) self.displayed_action = value end
function villager:go_to()
	self.go_to_calls = self.go_to_calls + 1
	return true
end
function villager:manipulate_chest()
	self.transfer_calls = self.transfer_calls + 1
	local stack = chest_inventory:get_stack("main", 1)
	if stack:get_name() == "test:resource" and not stack:is_empty() then
		chest_inventory:set_stack(1, make_stack())
		villager_inventory:set_stack(1, stack)
		return {
			moved_any = true,
			put_candidates = 0,
			take_candidates = 1,
			blocked_put = 0,
			blocked_take = 0,
		}
	end
	return {
		moved_any = false,
		put_candidates = 0,
		take_candidates = 0,
		blocked_put = 0,
		blocked_take = 0,
	}
end

local function take_resource(_, stack)
	return stack:get_name() == "test:resource"
end
local function keep_working_once()
	villager:handle_chest(take_resource, nil)
	villager.work_ticks = (villager.work_ticks or 0) + 1
end

-- Hundreds of profession decisions with an empty chest must not cause a
-- single trip. The lightweight inventory probe backs off from 2 to 4 seconds,
-- while the caller continues its normal job code after every invocation.
keep_working_once()
for _ = 1, 220 do
	keep_working_once()
end
assert_equal(villager.go_to_calls, 0, "empty chest caused pathfinding")
assert_equal(villager.transfer_calls, 0, "empty chest caused a physical visit")
assert(meta_reads <= 8, "empty chest was polled too often: " .. tostring(meta_reads))
assert_equal(action_logs, 0, "empty chest emitted action log spam")
assert_equal(villager.work_ticks, 221, "chest cooldown stopped the profession loop")
assert_equal(villager.state_info, "Je cultive.", "empty chest replaced profession state")
assert_equal(villager.displayed_action, "cultive", "empty chest replaced profession action")

-- Even at maximum backoff, a newly delivered useful resource is collected in
-- no more than 40 logical steps (4 seconds with the default 0.1 s timer step).
chest_inventory:set_stack(1, make_stack("test:resource", 1))
local delivery_delay = 0
while villager.transfer_calls == 0 and delivery_delay <= 40 do
	delivery_delay = delivery_delay + 1
	keep_working_once()
end
assert(delivery_delay <= 40, "real chest resource waited beyond the bounded backoff")
assert_equal(villager.go_to_calls, 1, "real resource caused the wrong trip count")
assert_equal(villager.transfer_calls, 1, "real resource caused the wrong transfer count")
assert_equal(villager_inventory:get_stack("main", 1):get_name(), "test:resource",
	"real resource was not transferred")
assert_equal(action_logs, 1, "successful transfer did not produce exactly one action log")

-- A normal successful-transfer cooldown remains shorter than the empty retry
-- ceiling, so another real delivery is not delayed by the previous empty run.
villager_inventory:set_stack(1, make_stack())
chest_inventory:set_stack(1, make_stack("test:resource", 1))
for _ = 1, 23 do
	keep_working_once()
end
assert_equal(villager.transfer_calls, 1, "successful cooldown ended too early")
keep_working_once()
assert_equal(villager.transfer_calls, 2, "successful cooldown delayed a real transfer")
assert_equal(villager.go_to_calls, 2, "second real transfer caused extra trips")
assert_equal(action_logs, 2, "second real transfer caused noisy logging")

print("CHEST_CADENCE_SPEC_OK")
return true
