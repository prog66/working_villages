-- Standalone fake-Luanti regression tests for persisted runtime timestamps.
-- Run from the repository root with:
--   lua5.1 working_villagers/tests/timekeeping_spec.lua working_villagers

local modpath = (arg and arg[1]) or "working_villagers"
local gametime = 100
local auto_approve = true

local function hash_pos(pos)
	return table.concat({pos.x, pos.y, pos.z}, ":")
end

minetest = {
	get_gametime = function()
		return gametime
	end,
	hash_node_position = hash_pos,
	settings = {
		get_bool = function()
			return auto_approve
		end,
	},
}

vector = {
	round = function(pos)
		return {
			x = math.floor(pos.x + 0.5),
			y = math.floor(pos.y + 0.5),
			z = math.floor(pos.z + 0.5),
		}
	end,
}

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) ..
			", got " .. tostring(actual), 2)
	end
end

local memory = dofile(modpath .. "/memory.lua")
working_villages = {memory = memory}
local ai_behavior = dofile(modpath .. "/ai_behavior.lua")
local permissions = dofile(modpath .. "/permissions.lua")

-- Persistent memory uses Luanti game time and honors the TTL boundary.
local villager = {}
memory.remember_pos(villager, "resource_locations", {x = 1, y = 2, z = 3}, {node = "tree"})
local resource = memory.list(villager, "resource_locations")["1:2:3"]
assert_equal(resource.time, 100, "memory timestamp")
assert_equal(resource.time_clock, "gametime_v1", "memory timestamp source")

gametime = 105
memory.forget_old(villager, 5)
assert(memory.list(villager, "resource_locations")["1:2:3"],
	"memory must survive at the exact TTL boundary")
gametime = 106
memory.forget_old(villager, 5)
assert_equal(memory.list(villager, "resource_locations")["1:2:3"], nil,
	"memory must expire after its TTL")

-- Legacy os.clock records have an unknown epoch; future timestamps can occur
-- after a world rollback or a game-time reset. Both are expired safely.
villager.memory.resource_locations.legacy = {time = 1}
villager.memory.resource_locations.future = {time = 999, time_clock = "gametime_v1"}
gametime = 200
memory.forget_old(villager, 3600)
assert_equal(villager.memory.resource_locations.legacy, nil, "legacy memory migration")
assert_equal(villager.memory.resource_locations.future, nil, "future memory migration")

-- State durations use the same runtime clock and restart uncomparable TTLs.
local stateful = {}
ai_behavior.state_machine.set_state(stateful, ai_behavior.STATES.WORKING)
assert_equal(stateful.ai_state_time, 200, "state timestamp")
assert_equal(stateful.ai_state_time_clock, "gametime_v1", "state timestamp source")
gametime = 203
assert_equal(ai_behavior.state_machine.get_state_duration(stateful), 3, "state duration")

stateful.ai_state_time = 1
stateful.ai_state_time_clock = nil
gametime = 300
assert_equal(ai_behavior.state_machine.get_state_duration(stateful), 0,
	"legacy state duration must restart")
assert_equal(stateful.ai_state_time, 300, "legacy state timestamp migration")
assert_equal(stateful.ai_state_time_clock, "gametime_v1", "legacy state clock migration")

stateful.ai_state_time = 999
stateful.ai_state_time_clock = "gametime_v1"
assert_equal(ai_behavior.state_machine.get_state_duration(stateful), 0,
	"future state duration must restart")
assert_equal(stateful.ai_state_time, 300, "future state timestamp migration")

-- AI location recall excludes unknown-age records only when a TTL is requested;
-- an unfiltered inspection can still expose them before cleanup.
local remembering = {}
ai_behavior.memory.remember_location(remembering, "resource", {x = 4, y = 5, z = 6})
local remembered = remembering.memory.resource["4:5:6"]
assert_equal(remembered.time, 300, "AI memory timestamp")
assert_equal(remembered.time_clock, "gametime_v1", "AI memory timestamp source")
gametime = 305
assert_equal(#ai_behavior.memory.recall_locations(remembering, "resource", 5), 1,
	"AI memory at TTL boundary")
gametime = 306
assert_equal(#ai_behavior.memory.recall_locations(remembering, "resource", 5), 0,
	"expired AI memory recall")
remembering.memory.resource.legacy = {time = 1}
local ttl_locations = ai_behavior.memory.recall_locations(remembering, "resource", 3600)
assert_equal(#ttl_locations, 1, "only valid AI memory must satisfy a TTL query")
assert_equal(ttl_locations[1], remembered, "TTL query must retain the valid AI memory")
assert_equal(#ai_behavior.memory.recall_locations(remembering, "resource"), 2,
	"unfiltered AI memory remains inspectable")
ai_behavior.memory.forget_old(remembering, 3600)
assert_equal(remembering.memory.resource.legacy, nil, "legacy AI memory cleanup")

-- Autonomous approvals wait five fresh game-time seconds. A legacy or future
-- pending request is migrated without being approved immediately.
local requester = {
	owner_name = "alice",
	job_data = {},
}
gametime = 400
assert_equal(permissions.request(requester, "build", "Build here", {}), false,
	"new permission request")
local request = requester.job_data.permission_requests.build
assert_equal(request.created, 400, "permission timestamp")
assert_equal(request.created_clock, "gametime_v1", "permission timestamp source")
gametime = 404
permissions.tick(requester)
assert_equal(request.status, "pending", "permission before delay")
gametime = 405
permissions.tick(requester)
assert_equal(request.status, "approved", "permission after delay")
assert_equal(request.responded, 405, "permission response timestamp")
assert_equal(request.responded_clock, "gametime_v1", "permission response clock")

requester.job_data.permission_requests.legacy = {
	status = "pending",
	created = 1,
}
gametime = 500
permissions.tick(requester)
local legacy = requester.job_data.permission_requests.legacy
assert_equal(legacy.status, "pending", "legacy permission must wait after migration")
assert_equal(legacy.created, 500, "legacy permission timestamp migration")
assert_equal(legacy.created_clock, "gametime_v1", "legacy permission clock migration")
gametime = 505
permissions.tick(requester)
assert_equal(legacy.status, "approved", "migrated permission after fresh delay")

requester.job_data.permission_requests.future = {
	status = "pending",
	created = 999,
	created_clock = "gametime_v1",
}
gametime = 600
permissions.tick(requester)
local future = requester.job_data.permission_requests.future
assert_equal(future.status, "pending", "future permission must wait after reset")
assert_equal(future.created, 600, "future permission timestamp migration")
gametime = 605
permissions.tick(requester)
assert_equal(future.status, "approved", "future permission after fresh delay")

gametime = 700
permissions.request(requester, "save_plan:test_house", "Save this plan", {})
local save_plan = requester.job_data.permission_requests["save_plan:test_house"]
gametime = 706
permissions.tick(requester)
assert_equal(save_plan.status, "pending", "save_plan must never be auto-approved")
permissions.respond(requester, "save_plan:test_house", true)
assert_equal(save_plan.status, "approved", "save_plan may be approved explicitly")
assert_equal(save_plan.responded, 706, "manual save_plan response timestamp")
assert_equal(save_plan.responded_clock, "gametime_v1", "manual save_plan response clock")
assert_equal(save_plan.decision_source, "manual", "manual save_plan decision source")

requester.job_data.permission_requests["save_plan:legacy_approved"] = {
	status = "approved",
	created = 1,
	responded = 2,
}
gametime = 800
auto_approve = false
permissions.tick(requester)
local legacy_save = requester.job_data.permission_requests["save_plan:legacy_approved"]
assert_equal(legacy_save.status, "pending", "unproven legacy save_plan approval must fail closed")
assert_equal(legacy_save.created, 800, "legacy save_plan must receive a fresh timestamp")
assert_equal(legacy_save.decision_source, nil, "legacy save_plan decision source must be cleared")

print("TIMEKEEPING_SPEC_OK")
