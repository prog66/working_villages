-- Deterministic public-server survival policy regression.
-- Run with: lua5.1 working_villagers/tests/survival_spec.lua working_villagers

local root = (arg and arg[1]) or "working_villagers"
local settings_values = {}
local clock = 0

minetest = {
	settings = {
		get = function(_, name)
			return settings_values[name]
		end,
	},
	get_us_time = function()
		return clock * 1000000
	end,
	check_player_privs = function(name, privileges)
		return name == "admin" and privileges.protection_bypass == true
	end,
}

local function load_survival(values)
	settings_values = values or {}
	return dofile(root .. "/survival.lua")
end

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected=" .. tostring(expected) ..
			" actual=" .. tostring(actual), 2)
	end
end

local function player(name)
	return {
		is_player = function() return true end,
		get_player_name = function() return name end,
	}
end

local mob = {
	is_player = function() return false end,
	get_pos = function() return {x = 4, y = 1, z = 2} end,
}

local survival = load_survival()
assert_equal(survival.max_hp(30), 60, "default male public-server health")
assert_equal(survival.max_hp(20), 40, "default female public-server health")
assert_equal(survival.effective_damage(10, 0.2, false), 4,
	"armor-aware incoming damage")
assert_equal(survival.effective_damage(10, 0.2, true), 3,
	"shield-aware incoming damage")
assert_equal(survival.fallback_raw_damage({damage_groups = {fleshy = 7}}, nil), 7,
	"legacy callback damage fallback")
assert_equal(survival.fallback_raw_damage({damage_groups = {fleshy = 7}}, 11), 11,
	"engine-reported damage must win")

local villager = {owner_name = "alice"}
assert_equal(survival.player_can_damage(villager, player("alice")), true,
	"owner_only rejected the owner")
assert_equal(survival.player_can_damage(villager, player("mallory")), false,
	"owner_only allowed a stranger")
assert_equal(survival.player_can_damage(villager, player("admin")), true,
	"protection_bypass administrator was rejected")
assert_equal(survival.player_can_damage(villager, mob), true,
	"hostile entity damage was rejected")

survival = load_survival({working_villages_player_damage_mode = "none"})
assert_equal(survival.player_can_damage(villager, player("alice")), false,
	"none mode allowed owner damage")
survival = load_survival({working_villages_player_damage_mode = "all"})
assert_equal(survival.player_can_damage(villager, player("mallory")), true,
	"all mode rejected player damage")

survival = load_survival()
local properties = {hp_max = 30}
local hp = 15
local object = {
	set_properties = function(_, updates)
		for key, value in pairs(updates) do properties[key] = value end
	end,
	get_properties = function() return properties end,
	get_hp = function() return hp end,
	set_hp = function(_, value) hp = value end,
}
villager = {
	object = object,
	initial_properties = {hp_max = 60},
	job_data = {},
}
clock = 0
survival.activate(villager, 30, {})
assert_equal(properties.hp_max, 60, "scaled object hp_max")
assert_equal(hp, 30, "one-time health-ratio migration")
assert_equal(villager.survival_schema_version, survival.SCHEMA_VERSION,
	"survival schema was not recorded")
assert_equal(survival.is_activation_protected(villager), true,
	"activation protection did not start")
clock = 11
assert_equal(survival.is_activation_protected(villager), false,
	"activation protection did not expire")

survival.note_attack(villager, mob)
assert_equal(villager.job_data.danger_ticks, 200,
	"a real hit did not trigger immediate danger")
assert_equal(villager.job_data.danger_pos.x, 4,
	"attacker position was not retained")
assert_equal(survival.should_retreat(villager), true,
	"half-health villager did not request retreat")

clock = 32
villager.job_data.danger_ticks = 0
for _ = 1, 4 do
	survival.tick_regeneration(villager, 1, true)
end
assert_equal(hp, 31, "safe delayed regeneration")
survival.tick_regeneration(villager, 4, false)
assert_equal(hp, 31, "regeneration continued during danger")

survival = load_survival({
	working_villages_incoming_damage_multiplier = "0",
	working_villages_villager_hp_multiplier = "1.5",
})
assert_equal(survival.effective_damage(100, 0, false), 0,
	"zero-damage server policy was ignored")
assert_equal(survival.max_hp(20), 30, "custom health multiplier")

print("VILLAGER_SURVIVAL_SPEC_OK:hp=2x:damage=0.5x:owner_only:activation:regen:retreat")
