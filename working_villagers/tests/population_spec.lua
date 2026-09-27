-- Standalone fake-Luanti regression tests for population.lua.
-- Run from the repository root with:
--   lua working_villagers/tests/population_spec.lua working_villagers

local modpath = (arg and arg[1]) or "working_villagers"

local function deep_copy(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, entry in pairs(value) do
		result[deep_copy(key)] = deep_copy(entry)
	end
	return result
end

local persisted = {}
local storage = {
	get_string = function(_, key)
		return persisted[key] or ""
	end,
	set_string = function(_, key, value)
		persisted[key] = value
	end,
}

minetest = {
	get_mod_storage = function()
		return storage
	end,
	serialize = function(value)
		return deep_copy(value)
	end,
	deserialize = function(value)
		return deep_copy(value)
	end,
}

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) ..
			", got " .. tostring(actual), 2)
	end
end

local function villager(id, owner, pos)
	return {
		inventory_name = id,
		owner_name = owner,
		name = "working_villages:villager_male",
		object = {
			get_pos = function()
				return deep_copy(pos)
			end,
		},
	}
end

local population = dofile(modpath .. "/population.lua")
local alice_near = villager("alice-near", "alice", {x = 3, y = 0, z = 4})
local alice_far = villager("alice-far", "alice", {x = 30, y = 0, z = 0})
local bob_near = villager("bob-near", "bob", {x = 1, y = 0, z = 1})

local crash_probe = villager("crash-probe", "alice", {x = 9, y = 1, z = 7})
crash_probe.product_name = "working_villages:villager_male"
crash_probe.manufacturing_number = 42
crash_probe.get_job_name = function()
	return "working_villages:job_miner"
end
crash_probe._serialize_persistent_state = function(self)
	return minetest.serialize({
		product_name = self.product_name,
		manufacturing_number = self.manufacturing_number,
		owner_name = self.owner_name,
		inventory = {
			job = {"working_villages:job_miner"},
			main = {"default:pick_steel", "default:stone 7"},
		},
		job_data = {resume_marker = "ore_target"},
		object_pos = self.object:get_pos(),
		persistence_revision = self.persistence_revision,
	})
end

assert_equal(population.register(alice_near), true, "near villager registration")
assert_equal(population.register(alice_far), true, "far villager registration")
assert_equal(population.register(bob_near), true, "other village registration")
assert_equal(population.count("alice"), 2, "owner count")
assert_equal(population.count("alice", {x = 0, y = 0, z = 0}, 5), 1, "radius count")
assert_equal(population.count("bob", {x = 0, y = 0, z = 0}, 5), 1, "owner isolation")
assert_equal(population.count(nil, {x = 0, y = 0, z = 0}, 5), 2, "unfiltered radius count")
assert_equal(population.register(crash_probe), true, "crash checkpoint registration")

local stale_data = {
	product_name = "working_villages:villager_male",
	manufacturing_number = 42,
	owner_name = "",
	inventory = {},
	persistence_revision = 0,
}
local recovered_data, did_recover, recovery_reason = population.recover_data("crash-probe", stale_data)
assert_equal(did_recover, true, "newer crash checkpoint was not selected")
assert_equal(recovery_reason, "checkpoint", "unexpected checkpoint recovery reason")
assert_equal(recovered_data.owner_name, "alice", "checkpoint lost owner")
assert_equal(recovered_data.inventory.job[1], "working_villages:job_miner", "checkpoint lost job")
assert_equal(recovered_data.inventory.main[2], "default:stone 7", "checkpoint lost main inventory")
assert_equal(recovered_data.job_data.resume_marker, "ore_target", "checkpoint lost job progress")
assert_equal(recovered_data.object_pos.x, 9, "checkpoint lost current position")

local newer_map_data = deep_copy(recovered_data)
newer_map_data.persistence_revision = recovered_data.persistence_revision + 1
newer_map_data.owner_name = "newer-map-owner"
local kept_data, newer_recovered = population.recover_data("crash-probe", newer_map_data)
assert_equal(newer_recovered, false, "older checkpoint replaced newer map staticdata")
assert_equal(kept_data.owner_name, "newer-map-owner", "newer map staticdata was modified")

local legacy_probe = villager("legacy-probe", "legacy-owner", {x = 4, y = 2, z = 8})
legacy_probe.product_name = "working_villages:villager_female"
legacy_probe.pos_data = {job_pos = {x = 5, y = 2, z = 8}}
legacy_probe.get_job_name = function()
	return "working_villages:job_farmer"
end
assert_equal(population.register(legacy_probe), true, "legacy metadata registration")
local legacy_data, legacy_recovered, legacy_reason = population.recover_data("legacy-probe", {
	product_name = "working_villages:villager_female",
	manufacturing_number = 9,
	owner_name = "",
	inventory = {},
})
assert_equal(legacy_recovered, true, "legacy initial staticdata was not repaired")
assert_equal(legacy_reason, "registry_metadata", "unexpected legacy recovery reason")
assert_equal(legacy_data.owner_name, "legacy-owner", "legacy repair lost owner")
assert_equal(legacy_data.inventory.job[1], "working_villages:job_farmer", "legacy repair lost job")
assert_equal(legacy_data.pos_data.job_pos.x, 5, "legacy repair lost work position")

local restored = dofile(modpath .. "/population.lua")
assert_equal(restored.count("alice"), 3, "registry survives module reload")
local reloaded_data, reloaded_recovered = restored.recover_data("crash-probe", {
	owner_name = "",
	persistence_revision = 0,
})
assert_equal(reloaded_recovered, true, "checkpoint did not survive module reload")
assert_equal(reloaded_data.inventory.main[1], "default:pick_steel", "reloaded checkpoint lost inventory")
assert_equal(restored.unregister(alice_near), true, "registered villager removal")
-- alice-far and crash-probe remain registered; removing alice-near must remove
-- exactly one resident rather than hiding another persistent villager.
assert_equal(restored.count("alice"), 2, "removed villager no longer counts")
assert_equal(restored.unregister("missing"), false, "unknown villager removal is harmless")

print("[working_villages] population_spec.lua passed")
