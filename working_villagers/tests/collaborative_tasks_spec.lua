-- Standalone fake-Luanti regression tests for collaborative_tasks.lua.
-- Run with a Lua 5.1+ interpreter from any directory.

local function deep_copy(value, seen)
	if type(value) ~= "table" then
		return value
	end
	seen = seen or {}
	if seen[value] then
		error("cycle in test serializer")
	end
	seen[value] = true
	local result = {}
	for key, entry in pairs(value) do
		result[deep_copy(key, seen)] = deep_copy(entry, seen)
	end
	seen[value] = nil
	return result
end

local storage_data = {}
local storage = {
	get_string = function(_, key)
		local value = storage_data[key]
		return value == nil and "" or deep_copy(value)
	end,
	set_string = function(_, key, value)
		storage_data[key] = deep_copy(value)
	end,
	get_int = function(_, key)
		return tonumber(storage_data[key]) or 0
	end,
	set_int = function(_, key, value)
		storage_data[key] = value
	end,
}

local gametime = 100
local globalsteps = {}
local loaded = {}
local candidates = {}
local sent_messages = {}
local broadcast_calls = {}

minetest = {
	luaentities = loaded,
	get_mod_storage = function()
		return storage
	end,
	serialize = function(value)
		return deep_copy(value)
	end,
	deserialize = function(value)
		return deep_copy(value)
	end,
	get_gametime = function()
		return gametime
	end,
	register_globalstep = function(callback)
		globalsteps[#globalsteps + 1] = callback
	end,
	log = function() end,
}

local communication = {
	find_nearby_villagers = function(_pos, _radius, job)
		return candidates[job] or {}
	end,
	find_villager_by_inventory_name = function(inventory_name)
		for _, entity in pairs(loaded) do
			if entity.inventory_name == inventory_name then
				return entity
			end
		end
		return nil
	end,
	send_message = function(from, to, message_type, data)
		sent_messages[#sent_messages + 1] = {
			from = from and from.inventory_name,
			to = to and to.inventory_name,
			type = message_type,
			data = deep_copy(data),
		}
		return true
	end,
}

communication.broadcast = function(from, targets, message_type, data)
	broadcast_calls[#broadcast_calls + 1] = {
		from = from and from.inventory_name,
		type = message_type,
		data = deep_copy(data),
	}
	local sent = 0
	for _, target in ipairs(targets or {}) do
		if communication.send_message(from, target, message_type, data) then
			sent = sent + 1
		end
	end
	return sent
end

working_villages = {communication = communication}

local source = debug.getinfo(1, "S").source
if source:sub(1, 1) == "@" then
	source = source:sub(2)
end
local test_dir = source:match("^(.*[/\\])") or ""
local modpath = arg and arg[1]
local module_path = modpath and (modpath .. "/collaborative_tasks.lua")
	or (test_dir .. "../collaborative_tasks.lua")

local function load_tasks()
	working_villages.communication = communication
	local module = dofile(module_path)
	working_villages.collaborative_tasks = module
	return module
end

local function villager(identifier, owner, job)
	local entity = {
		inventory_name = identifier,
		owner_name = owner,
		job_data = {},
		_job = job,
	}
	entity.object = {
		get_pos = function()
			return {x = 0, y = 0, z = 0}
		end,
	}
	function entity:get_job_name()
		return self._job
	end
	loaded[#loaded + 1] = entity
	return entity
end

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end

local builder = villager("builder:1", "alice", "job:builder")
local builder_two = villager("builder:2", "alice", "job:builder")
local woodcutter = villager("wood:1", "alice", "job:woodcutter")
candidates["job:builder"] = {builder, builder_two}
candidates["job:woodcutter"] = {}

local tasks = load_tasks()
local definition = {
	required_jobs = {"job:builder", "job:woodcutter"},
	min_villagers = 2,
	radius = 30,
	timeout = 10,
	description = "Test task",
}
assert(tasks.register_task("build", definition))

local ok, value = tasks.start_task("build", builder, {size = 20})
assert_equal(ok, false, "task must require every role")
assert(value:match("job:woodcutter"), "missing role must be reported")
assert_equal(definition.owner_name, nil, "registered definition must not be mutated")

local broadcast_before = #broadcast_calls
local fallback_sent
ok, value, fallback_sent = tasks.start_task_or_broadcast(
	"build", builder, {size = 20}, {builder_two})
assert_equal(ok, false, "missing role must use the fallback path")
assert(type(value) == "string" and value:match("job:woodcutter"),
	"fallback must preserve the missing-role diagnostic")
assert_equal(fallback_sent, 1, "fallback must report the exact broadcast count")
assert_equal(#broadcast_calls, broadcast_before + 1,
	"failed collaboration must broadcast exactly once")

candidates["job:woodcutter"] = {woodcutter}
local task_message_start = #sent_messages
broadcast_before = #broadcast_calls
ok, value, fallback_sent = tasks.start_task_or_broadcast(
	"build", builder, {size = 20}, {builder_two})
assert_equal(ok, true, value)
assert_equal(fallback_sent, 0, "successful collaboration reported a fallback broadcast")
assert_equal(#broadcast_calls, broadcast_before,
	"successful start_task must not also broadcast")
local first_id = value
local first = tasks.get(first_id)
assert_equal(first.state, "active")
assert_equal(type(first.participants[1]), "string", "participants must be stable identifiers")
assert_equal(#first.assignments, 2, "every required role must have an assignment")
assert_equal(builder.job_data.collab_task, first_id)
assert_equal(woodcutter.job_data.collab_task, first_id)
assert_equal(sent_messages[task_message_start + 1].data.task, "build",
	"legacy start message field must remain")
assert_equal(sent_messages[task_message_start + 1].data.task_id, first_id,
	"message must identify the task")

local updated, update_record = tasks.update(first_id, {progress = {done = 5}})
assert_equal(updated, true)
assert_equal(update_record.progress.done, 5)
local invalid_update = tasks.update(first_id, {bad = function() end})
assert_equal(invalid_update, false, "functions must not enter persisted task data")

local completed, completed_record = tasks.complete(first_id, {built = true})
assert_equal(completed, true)
assert_equal(completed_record.state, "completed")
assert_equal(builder.job_data.collab_task, nil, "completion must clear loaded assignments")
assert_equal(woodcutter.job_data.collab_task, nil, "completion must clear loaded assignments")

ok, value = tasks.start_task("build", builder, {size = 30})
assert_equal(ok, true, value)
local persisted_id = value
local restored = load_tasks()
assert(restored.register_task("build", definition))
assert_equal(restored.get(persisted_id).state, "active", "active task must survive module reload")
assert(restored.active[persisted_id], "restored active index must contain the task")

gametime = gametime + 11
local cleanup_result = restored.cleanup(gametime)
assert_equal(cleanup_result.expired, 1, "overdue task must expire")
assert_equal(restored.get(persisted_id).state, "expired")
assert_equal(builder.job_data.collab_task, nil, "expiration must clear loaded assignments")

-- Terminal lifecycle APIs remain queryable until history cleanup.
candidates["job:woodcutter"] = {woodcutter}
ok, value = restored.start_task("build", builder, {})
assert_equal(ok, true, value)
local failed_id = value
assert_equal(restored.fail(failed_id, "blocked"), true)
assert_equal(restored.get(failed_id).state, "failed")

ok, value = restored.start_task("build", builder, {})
assert_equal(ok, true, value)
local cancelled_id = value
assert_equal(restored.cancel(cancelled_id, "manual"), true)
assert_equal(restored.get(cancelled_id).state, "cancelled")
assert(first_id ~= persisted_id and persisted_id ~= failed_id and failed_id ~= cancelled_id,
	"persistent counter must generate collision-free identifiers")

-- Named survival scenarios keep the same persistent lifecycle contract.
local farmer = villager("farmer:1", "alice", "job:farmer")
local cook = villager("cook:1", "alice", "job:cook")
local miner = villager("miner:1", "alice", "job:miner")
local blacksmith = villager("smith:1", "alice", "job:blacksmith")
candidates["job:farmer"] = {farmer}
candidates["job:cook"] = {cook}
candidates["job:miner"] = {miner}
candidates["job:blacksmith"] = {blacksmith}

assert(restored.register_task("food_support", {
	required_jobs = {"job:farmer", "job:cook"},
	min_villagers = 2,
	radius = 30,
	timeout = 300,
}))
ok, value = restored.start_task("food_support", farmer, {
	resource = "food",
	count = 3,
	delivery_target = "shared_storage",
	requester_id = farmer.inventory_name,
})
assert_equal(ok, true, value)
local food_id = value
assert_equal(restored.get(food_id).data.resource, "food", "food request data must persist")
local recorded = restored.record_food_deposit(food_id, miner, 1)
assert_equal(recorded, false, "non-participant deposit must not advance shared stock")
assert_equal(restored.get(food_id).data.delivery_progress, nil,
	"rejected deposit changed delivery progress")
local food_record
recorded, food_record = restored.record_food_deposit(food_id, cook, 1)
assert_equal(recorded, true, food_record)
assert_equal(food_record.state, "active", "partial food deposit completed the task")
assert_equal(food_record.data.delivery_progress.food, 1,
	"partial food deposit was not counted exactly")
recorded, food_record = restored.record_food_deposit(food_id, cook.inventory_name, 2)
assert_equal(recorded, true, food_record)
assert_equal(food_record.state, "completed", "full shared-stock deposit did not complete the task")
assert_equal(food_record.data.delivery_progress.food, 3,
	"shared-stock progress does not equal actual deposits")
assert_equal(food_record.result.delivery_target, "shared_storage",
	"food task completion lost its stock objective")

assert(restored.register_task("mining_tool_supply", {
	required_jobs = {"job:miner", "job:blacksmith"},
	min_villagers = 2,
	radius = 30,
	timeout = 600,
}))
ok, value = restored.start_task("mining_tool_supply", miner, {
	tool_group = "pickaxe", requester_id = miner.inventory_name,
})
assert_equal(ok, true, value)
local mining_id = value
blacksmith._job = "job:cook"
restored.cleanup(gametime)
assert_equal(restored.get(mining_id).state, "failed",
	"job change must fail a mining supply task")
assert_equal(miner.job_data.collab_task, nil, "failed task must release miner")
assert_equal(blacksmith.job_data.collab_task, nil, "failed task must release blacksmith")

local removed = restored.cleanup(gametime + 3600, {terminal_retention = 0})
assert(removed.removed >= 3, "terminal cleanup must remove retained history")

print("COLLABORATIVE_TASKS_SPEC_OK")
