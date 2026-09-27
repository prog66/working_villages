-- Public-server survival policy for working villagers.
--
-- Luanti lets an entity on_punch callback return true to suppress the default
-- damage mechanism.  Keeping the calculation here makes armor, shields,
-- activation protection and multiplayer ownership apply before a fatal hit,
-- instead of trying to restore HP after the engine has already removed the
-- entity.

local survival = {}

survival.SCHEMA_VERSION = 1

local function finite_number(value)
	value = tonumber(value)
	if not value or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

local function clamp(value, minimum, maximum, fallback)
	value = finite_number(value) or fallback
	return math.max(minimum, math.min(maximum, value))
end

local function read_number(name, fallback, minimum, maximum)
	local value = minetest.settings and minetest.settings:get(name) or nil
	return clamp(value, minimum, maximum, fallback)
end

local function read_mode()
	local value = minetest.settings and
		minetest.settings:get("working_villages_player_damage_mode") or nil
	value = tostring(value or "owner_only"):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if value ~= "none" and value ~= "owner_only" and value ~= "all" then
		value = "owner_only"
	end
	return value
end

survival.config = {
	hp_multiplier = read_number("working_villages_villager_hp_multiplier", 2.0, 0.5, 10),
	damage_multiplier = read_number("working_villages_incoming_damage_multiplier", 0.5, 0, 5),
	activation_protection_seconds = read_number(
		"working_villages_activation_protection_seconds", 10, 0, 120),
	regen_per_second = read_number("working_villages_health_regen_per_second", 0.25, 0, 20),
	regen_delay_seconds = read_number("working_villages_health_regen_delay_seconds", 20, 0, 600),
	retreat_health_ratio = read_number("working_villages_retreat_health_ratio", 0.5, 0.05, 0.95),
	player_damage_mode = read_mode(),
}

local function now_seconds()
	if type(minetest.get_us_time) == "function" then
		return minetest.get_us_time() / 1000000
	end
	if type(minetest.get_gametime) == "function" then
		return minetest.get_gametime()
	end
	return os.clock()
end

function survival.max_hp(base_hp)
	base_hp = math.max(1, finite_number(base_hp) or 1)
	return math.max(1, math.floor(base_hp * survival.config.hp_multiplier + 0.5))
end

function survival.is_player(puncher)
	if not puncher or type(puncher.is_player) ~= "function" then
		return false
	end
	local ok, result = pcall(puncher.is_player, puncher)
	return ok and result == true
end

function survival.player_can_damage(villager, puncher)
	if not survival.is_player(puncher) then
		return true
	end
	local player_name = type(puncher.get_player_name) == "function" and
		puncher:get_player_name() or ""
	if player_name ~= "" and type(minetest.check_player_privs) == "function" and
		minetest.check_player_privs(player_name, {protection_bypass = true}) then
		return true
	end
	local mode = survival.config.player_damage_mode
	if mode == "all" then
		return true
	end
	if mode == "owner_only" then
		return player_name ~= "" and player_name == (villager.owner_name or "")
	end
	return false
end

function survival.effective_damage(raw_damage, armor_reduction, shield_block)
	raw_damage = math.max(0, finite_number(raw_damage) or 0)
	if raw_damage == 0 or survival.config.damage_multiplier == 0 then
		return 0
	end
	local reduction = clamp(armor_reduction, 0, 0.8, 0)
	if shield_block then
		reduction = math.min(0.8, reduction + 0.25)
	end
	local result = raw_damage * (1 - reduction) * survival.config.damage_multiplier
	return math.max(1, math.floor(result + 0.5))
end

function survival.fallback_raw_damage(tool_capabilities, reported_damage)
	local reported = finite_number(reported_damage)
	if reported and reported >= 0 then
		return reported
	end
	local groups = tool_capabilities and tool_capabilities.damage_groups
	return math.max(0, finite_number(groups and groups.fleshy) or 1)
end

function survival.activate(villager, base_hp, persisted_data)
	local object = villager and villager.object
	if not object then
		return
	end
	base_hp = math.max(1, finite_number(base_hp) or 1)
	local maximum = survival.max_hp(base_hp)
	if type(object.set_properties) == "function" then
		object:set_properties({hp_max = maximum})
	end

	local current = type(object.get_hp) == "function" and object:get_hp() or nil
	local saved_version = type(persisted_data) == "table" and
		math.floor(finite_number(persisted_data.survival_schema_version) or 0) or 0
	-- Migrate an old saved villager once while preserving its health ratio.
	-- A later reload sees the persisted schema version and cannot be abused as
	-- a free heal.
	if current and current > 0 and saved_version < survival.SCHEMA_VERSION and
		maximum ~= base_hp and current <= base_hp then
		current = math.max(1, math.floor((current / base_hp) * maximum + 0.5))
		object:set_hp(math.min(maximum, current))
	elseif current and current > maximum then
		object:set_hp(maximum)
	end

	villager.survival_schema_version = survival.SCHEMA_VERSION
	villager._survival_activated_at = now_seconds()
	villager._survival_last_damage_at = villager._survival_activated_at
	villager._survival_regen_elapsed = 0
	villager._survival_regen_carry = 0
end

function survival.is_activation_protected(villager)
	local duration = survival.config.activation_protection_seconds
	if duration <= 0 then
		return false
	end
	local activated = finite_number(villager and villager._survival_activated_at)
	return activated ~= nil and now_seconds() - activated < duration
end

function survival.note_attack(villager, puncher)
	if not villager then
		return
	end
	villager.job_data = villager.job_data or {}
	villager.job_data.danger_ticks = math.max(
		200, finite_number(villager.job_data.danger_ticks) or 0)
	if puncher and type(puncher.get_pos) == "function" then
		local ok, pos = pcall(puncher.get_pos, puncher)
		if ok and type(pos) == "table" then
			villager.job_data.danger_pos = pos
		end
	end
	villager._survival_last_damage_at = now_seconds()
	villager._survival_regen_elapsed = 0
end

function survival.should_retreat(villager)
	local object = villager and villager.object
	if not object or type(object.get_hp) ~= "function" then
		return false
	end
	local hp = finite_number(object:get_hp())
	local properties = type(object.get_properties) == "function" and
		object:get_properties() or nil
	local maximum = finite_number(properties and properties.hp_max) or
		finite_number(villager.initial_properties and villager.initial_properties.hp_max)
	return hp ~= nil and maximum ~= nil and maximum > 0 and hp > 0 and
		hp / maximum <= survival.config.retreat_health_ratio
end

function survival.tick_regeneration(villager, dtime, safe)
	if not villager or not villager.object or survival.config.regen_per_second <= 0 then
		return 0
	end
	dtime = clamp(dtime, 0, 10, 0)
	villager._survival_regen_elapsed =
		(finite_number(villager._survival_regen_elapsed) or 0) + dtime
	if villager._survival_regen_elapsed < 1 then
		return 0
	end
	local elapsed = villager._survival_regen_elapsed
	villager._survival_regen_elapsed = 0
	if not safe or now_seconds() -
		(finite_number(villager._survival_last_damage_at) or now_seconds()) <
		survival.config.regen_delay_seconds then
		return 0
	end

	local object = villager.object
	local hp = finite_number(object:get_hp()) or 0
	local properties = type(object.get_properties) == "function" and
		object:get_properties() or nil
	local maximum = finite_number(properties and properties.hp_max) or hp
	if hp <= 0 or hp >= maximum then
		return 0
	end
	local amount = survival.config.regen_per_second * elapsed +
		(finite_number(villager._survival_regen_carry) or 0)
	local whole = math.floor(amount)
	villager._survival_regen_carry = amount - whole
	if whole <= 0 then
		return 0
	end
	local healed = math.min(whole, maximum - hp)
	object:set_hp(hp + healed)
	return healed
end

return survival
