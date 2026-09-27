-- Pure fake-Luanti regression tests for village_registry.lua.
-- Run with Lua 5.1/LuaJIT, or load this file from an isolated Luanti harness.

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

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) ..
			", got " .. tostring(actual), 2)
	end
end

local function assert_true(value, message)
	if not value then
		error(message or "expected a truthy value", 2)
	end
end

local source = debug.getinfo(1, "S").source
if source:sub(1, 1) == "@" then
	source = source:sub(2)
end
local test_dir = source:match("^(.*[/\\])") or ""
local modpath = arg and arg[1]
local module_path = modpath and (modpath .. "/village_registry.lua")
	or (test_dir .. "../village_registry.lua")

local function new_storage(initial)
	local data = deep_copy(initial or {})
	local writes = 0
	local storage = {}
	function storage:get_string(key)
		local value = data[key]
		return value == nil and "" or deep_copy(value)
	end
	function storage:set_string(key, value)
		writes = writes + 1
		data[key] = deep_copy(value)
	end
	return storage, function() return writes end, data
end

local function load_registry(storage)
	local fake_minetest = {
		get_mod_storage = function() return storage end,
		serialize = function(value) return deep_copy(value) end,
		deserialize = function(value) return deep_copy(value) end,
		log = function() end,
	}
	local environment = setmetatable({minetest = fake_minetest}, {__index = _G})
	local chunk = assert(loadfile(module_path))
	setfenv(chunk, environment)
	return chunk()
end

local storage, write_count = new_storage()
local villages = load_registry(storage)
assert_equal(write_count(), 0, "loading absent state must not write anything")

local alice, created = villages.ensure("alice", {
	center = {x = 12, y = 7, z = -4},
	radius = 40,
})
assert_true(alice, created)
assert_equal(created, true, "first ensure must create a village")
assert_equal(alice.schema_version, villages.SCHEMA_VERSION)
assert_equal(alice.id, villages.id_for_owner("alice"), "owner ID must be deterministic")
assert_equal(alice.owner, "alice")
assert_equal(alice.center.x, 12)
assert_equal(alice.radius, 40)
assert_equal(type(alice.governance.allies), "table")
assert_equal(type(alice.chests), "table")
assert_equal(type(alice.residents), "table")
assert_equal(type(alice.homes), "table")
assert_equal(type(alice.beds), "table")
assert_equal(type(alice.work_zones), "table")
assert_equal(type(alice.priorities), "table")
assert_equal(type(alice.resources), "table")
assert_equal(type(alice.danger), "table")
assert_equal(type(alice.construction_sites), "table")
assert_equal(write_count(), 1, "creation must be persisted immediately")

local by_id = assert(villages.get(alice.id))
assert_equal(by_id.owner, "alice", "ID lookup failed")
alice.center.x = 999
alice.governance.allies.intruder = true
local isolated = assert(villages.get("alice"))
assert_equal(isolated.center.x, 12, "returned center leaked mutable registry state")
assert_equal(isolated.governance.allies.intruder, nil, "returned nested table leaked registry state")

local updated = assert(villages.update("alice", {
	governance = {public = true},
	center = {x = 20, y = 8, z = -6},
	radius = 48,
	danger = {active = true, level = 2},
}))
assert_equal(updated.governance.public, true)
assert_equal(updated.center.x, 20)
assert_equal(updated.radius, 48)
assert_equal(updated.danger.active, true)
assert_equal(updated.danger.level, 2)
assert_equal(villages.can_access("alice", "alice"), true)
assert_equal(villages.can_access("alice", "stranger"), true,
	"public village governance did not grant public access")

local with_resident, resident_key, resident_added = villages.add(
	"alice", "residents", "villager:0001")
assert_true(with_resident)
assert_equal(resident_key, "villager:0001")
assert_equal(resident_added, true)
assert_equal(with_resident.residents[resident_key], "villager:0001")

local writes_before_duplicate = write_count()
local _, duplicate_key, duplicate_added = villages.add("alice", "residents", "villager:0001")
assert_equal(duplicate_key, "villager:0001")
assert_equal(duplicate_added, false, "identical collection add must be idempotent")
assert_equal(write_count(), writes_before_duplicate, "idempotent add must not rewrite storage")

local chest = {pos = {x = 3, y = 4, z = 5}, kind = "shared"}
local with_chest, chest_key = villages.add("alice", "chests", chest)
assert_true(with_chest.chests[chest_key], "position-keyed chest was not stored")
local with_ally, ally_key = villages.add("alice", "allies", "bob")
assert_equal(ally_key, "bob")
assert_equal(with_ally.governance.allies.bob, "bob")
local with_site, site_key = villages.add("alice", "construction_sites", {
		id = "site:1", blueprint = "simple_house"})
assert_equal(site_key, "site:1")
assert_equal(with_site.construction_sites[site_key].blueprint, "simple_house")
local with_resource, resource_key = villages.add("alice", "resources", {
		id = "wood", item = "mcl_core:wood", count = 24})
assert_equal(resource_key, "wood")
assert_equal(with_resource.resources.wood.count, 24)

local without_resident, resident_removed = villages.remove("alice", "residents", resident_key)
assert_equal(resident_removed, true)
assert_equal(without_resident.residents[resident_key], nil)
local without_chest, chest_removed = villages.remove("alice", "chests", chest)
assert_equal(chest_removed, true)
assert_equal(without_chest.chests[chest_key], nil)

local writes_before_invalid = write_count()
local invalid, invalid_error = villages.update("alice", {metadata = {callback = function() end}})
assert_equal(invalid, nil, "function entered persisted village data")
assert_true(type(invalid_error) == "string")
assert_equal(write_count(), writes_before_invalid, "invalid update rewrote storage")
local immutable = villages.update("alice", {owner = "mallory"})
assert_equal(immutable, nil, "owner mutation must be rejected")

local reloaded = load_registry(storage)
local after_reload = assert(reloaded.get("alice"))
assert_equal(after_reload.id, by_id.id, "village ID changed after module reload")
assert_equal(after_reload.center.x, 20, "updated state did not survive module reload")
assert_equal(after_reload.governance.allies.bob, "bob", "allies did not survive reload")
assert_equal(after_reload.resources.wood.count, 24, "resources did not survive reload")
assert_equal(reloaded.can_access("alice", "bob"), true, "ally access did not survive reload")
local same, created_again = reloaded.ensure("alice", {radius = 999})
assert_equal(created_again, false, "repeated ensure created a duplicate village")
assert_equal(same.radius, 48, "repeated ensure overwrote existing village state")

local bob = assert(reloaded.ensure("bob"))
assert_true(bob.id ~= after_reload.id, "different owners received the same village ID")
local second_reload = load_registry(storage)
assert_equal(assert(second_reload.get("alice")).id, after_reload.id)
assert_equal(assert(second_reload.get("bob")).id, bob.id)

local legacy_storage, legacy_writes = new_storage({
	[reloaded.STORAGE_KEY] = {
		villages = {
			legacy = {owner = "legacy", legacy_note = "keep-me"},
		},
		owners = {legacy = "legacy"},
	},
})
local migrated = load_registry(legacy_storage)
assert_equal(assert(migrated.get("legacy")).legacy_note, "keep-me",
	"migration discarded an unknown serializable village field")
assert_equal(legacy_writes(), 1, "unversioned state was not migrated exactly once")

local future_payload = {
	[reloaded.STORAGE_KEY] = {
		schema_version = 99,
		villages = {},
		owners = {},
		future_marker = "keep-me",
	},
}
local future_storage, future_writes, future_data = new_storage(future_payload)
local future = load_registry(future_storage)
local future_create, future_error = future.ensure("future-owner")
assert_equal(future_create, nil, "unsupported future schema accepted a write")
assert_true(type(future_error) == "string")
assert_equal(future_writes(), 0, "unsupported future schema was overwritten")
assert_equal(future_data[reloaded.STORAGE_KEY].future_marker, "keep-me",
	"unsupported future schema was modified")

print("VILLAGE_REGISTRY_SPEC_OK")
if minetest and type(minetest.log) == "function" then
	minetest.log("action", "VILLAGE_REGISTRY_SPEC_OK")
end
