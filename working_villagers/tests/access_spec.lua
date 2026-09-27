-- Standalone fake-Luanti regression tests for multiplayer village access.
-- Run from the repository root with:
--   lua working_villagers/tests/access_spec.lua working_villagers

local modpath = (arg and arg[1]) or "working_villagers"

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) ..
			", got " .. tostring(actual), 2)
	end
end

local villages = {}
local registry = {}
function registry.ensure(owner)
	if not villages[owner] then
		villages[owner] = {owner = owner, governance = {public = false, allies = {}}}
	end
	return villages[owner], true
end
function registry.get(owner)
	return villages[owner]
end
function registry.update(owner, patch)
	local village = villages[owner]
	if not village then
		return nil, "missing"
	end
	for key, value in pairs(patch) do
		village[key] = value
	end
	return village
end

local public_self_employed = false
local players = {}
local commands = {}
local function player(name, sceptre)
	local result = {
		get_player_name = function() return name end,
		get_wielded_item = function()
			return {get_name = function()
				return sceptre and "working_villages:commanding_sceptre" or ""
			end}
		end,
		get_inventory = function()
			return {contains_item = function(_, _, item)
				return sceptre and item == "working_villages:commanding_sceptre"
			end}
		end,
	}
	players[name] = result
	return result
end

minetest = {
	get_player_by_name = function(name) return players[name] end,
	check_player_privs = function(name, requested)
		return name == "admin" and (requested.server or requested.protection_bypass or requested.debug) or false
	end,
	settings = {
		get_bool = function(_, name)
			if name == "working_villages_self_employed_public" then
				return public_self_employed
			end
			return nil
		end,
	},
	register_chatcommand = function(name, definition)
		commands[name] = definition
	end,
}

working_villages = {village_registry = registry}
local access = dofile(modpath .. "/access.lua")
registry.ensure("alice")
player("alice", false)
player("bob", false)
player("carol", true)
player("admin", false)

assert_equal(select(1, access.can_manage_owner("alice", "alice")), true, "owner access")
assert_equal(select(1, access.can_manage_owner("alice", "bob")), false, "visitor isolation")
assert_equal(select(2, access.can_manage_owner("alice", "bob")), "not_owner", "visitor role")
assert_equal(select(1, access.can_manage_owner("alice", "admin")), true, "administrator access")

assert_equal(select(1, access.set_ally("alice", "bob", true, "alice")), true, "owner adds ally")
assert_equal(select(2, access.can_manage_owner("alice", "bob")), "ally", "explicit ally access")
assert_equal(select(1, access.set_ally("alice", "bob", false, "alice")), true, "owner removes ally")
assert_equal(select(1, access.can_manage_owner("alice", "bob")), false, "removed ally isolation")

assert_equal(select(1, access.set_public("alice", true, "alice")), true, "owner enables public mode")
assert_equal(select(1, access.can_manage_owner("alice", "bob")), false, "public visitor needs sceptre")
assert_equal(select(2, access.can_manage_owner("alice", "carol")), "public_village", "public sceptre access")
assert_equal(select(1, access.set_public("alice", false, "alice")), true, "owner disables public mode")
assert_equal(select(1, access.can_manage_owner("alice", "carol")), false, "public mode is not implicit")

public_self_employed = true
assert_equal(select(1, access.can_manage_owner("working_villages:self_employed", "bob")), false,
	"self-employed public access needs sceptre")
assert_equal(select(2, access.can_manage_owner("working_villages:self_employed", "carol")),
	"public_self_employed", "self-employed explicit public access")

assert_equal(type(commands.wv_village_public), "table", "public governance command registration")
assert_equal(type(commands.wv_village_ally), "table", "ally governance command registration")

print("[working_villages] access_spec.lua passed")
