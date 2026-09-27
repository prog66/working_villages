-- Standalone fake-Luanti regression tests for working_villages.villager
-- pause/state-info helpers (villager_state.lua).
-- Run from the repository root with:
--   lua5.1 working_villagers/tests/villager_state_spec.lua working_villagers

local modpath = (arg and arg[1]) or "working_villagers"
local gametime = 1000
local chats = {}

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) ..
			", got " .. tostring(actual), 2)
	end
end

working_villages = {
	villager = {},
	animation_frames = {STAND = "stand"},
}

vector = {
	distance = function(a, b)
		local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
		return math.sqrt(dx * dx + dy * dy + dz * dz)
	end,
}

local connected_players = {}
local online_names = {}

minetest = {
	get_gametime = function() return gametime end,
	get_player_by_name = function(name) return online_names[name] end,
	chat_send_player = function(name, message)
		table.insert(chats, {name = name, message = message})
	end,
	get_connected_players = function() return connected_players end,
}

dofile(modpath .. "/villager_state.lua")

local function make_villager()
	local self = {
		job_data = {},
		object = {
			set_velocity = function() end,
			get_pos = function() return {x = 0, y = 0, z = 0} end,
		},
	}
	self.set_animation = function() end
	self.update_infotext = function() end
	return setmetatable(self, {__index = working_villages.villager})
end

-- set_pause(true) stops the villager and does not touch pause_reason/job_error_state.
local v = make_villager()
v.job_data.pause_reason = "manual"
v.job_data.job_error_state = {job_name = "x", exhausted = true}
v:set_pause(true)
assert_equal(v.pause, true, "pause flag set")
assert_equal(v.job_data.pause_reason, "manual", "pausing does not touch pause_reason")
assert_equal(v.job_data.job_error_state.exhausted, true, "pausing does not touch job_error_state")

-- set_pause(false) after a manual pause: clears the reason, keeps any error state
-- (a manual pause is unrelated to job exhaustion, so nothing to forgive here).
v = make_villager()
v.job_data.pause_reason = "manual"
v.job_data.job_error_state = {job_name = "x", exhausted = true}
v:set_pause(false)
assert_equal(v.job_data.pause_reason, nil, "manual resume clears pause_reason")
assert_equal(v.job_data.job_error_state.exhausted, true,
	"manual resume unrelated to an error must not erase job_error_state")

-- set_pause(false) after an exhausted-job pause: clears job_error_state so the
-- job actually gets to run again (job_coroutines.resume() otherwise refuses
-- forever once exhausted=true, whether the resume was triggered manually via
-- the sceptre or by the generic 200-tick auto-resume timer).
v = make_villager()
v.job_data.pause_reason = "error"
v.job_data.job_error_state = {job_name = "x", exhausted = true, retries = 3}
v:set_pause(false)
assert_equal(v.job_data.pause_reason, nil, "error resume clears pause_reason")
assert_equal(v.job_data.job_error_state, nil,
	"resuming from an error pause must clear job_error_state")

-- set_pause(false) with no job_error_state at all must not error.
v = make_villager()
v.job_data.pause_reason = "error"
v:set_pause(false)
assert_equal(v.job_data.pause_reason, nil, "error resume with no error state still clears reason")

-- set_state_info: "detailed" notify level reaches the owner when online.
v = make_villager()
v.owner_name = "alice"
v.nametag = "Marie"
v.get_village_control = function() return {notify_level = "detailed"} end
online_names.alice = {}
chats = {}
v:set_state_info("Je coupe du bois.")
assert_equal(#chats, 1, "detailed notify sends one message when owner is online")
assert_equal(chats[1].name, "alice", "detailed notify targets the owner")
assert_equal(chats[1].message, "Marie: Je coupe du bois.", "message is prefixed with the nametag")

-- set_state_info: "detailed" notify level falls back to the nearest connected
-- player when the owner is offline, instead of silently dropping the message.
v = make_villager()
v.owner_name = "bob"
v.get_village_control = function() return {notify_level = "detailed"} end
online_names = {}
local near_player = {
	get_pos = function() return {x = 1, y = 0, z = 0} end,
	get_player_name = function() return "carol" end,
}
connected_players = {near_player}
chats = {}
gametime = gametime + 100
v:set_state_info("Je repare la cloture.")
assert_equal(#chats, 1, "detailed notify falls back to nearest player when owner is offline")
assert_equal(chats[1].name, "carol", "fallback targets the nearest connected player")

-- set_state_info: "silent" notify level never sends anything.
v = make_villager()
v.get_village_control = function() return {notify_level = "silent"} end
chats = {}
gametime = gametime + 100
v:set_state_info("Je me repose.")
assert_equal(#chats, 0, "silent notify level sends nothing")

print("STANDALONE_SPEC_OK:villager_state_spec.lua")
