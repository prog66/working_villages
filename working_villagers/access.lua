local access = {}

local SELF_EMPLOYED_OWNER = "working_villages:self_employed"
local COMMANDING_SCEPTRE = "working_villages:commanding_sceptre"
local village_registry = working_villages.village_registry

local function resolve_player(player_or_name)
	if type(player_or_name) == "string" then
		if player_or_name == "" then
			return nil, nil
		end
		return player_or_name, minetest.get_player_by_name(player_or_name)
	end
	if not player_or_name or type(player_or_name.get_player_name) ~= "function" then
		return nil, nil
	end
	local player_name = player_or_name:get_player_name()
	if not player_name or player_name == "" then
		return nil, nil
	end
	return player_name, player_or_name
end

local function has_privilege(player_name, privilege)
	if not player_name or not minetest.check_player_privs then
		return false
	end
	local requested = {}
	requested[privilege] = true
	return minetest.check_player_privs(player_name, requested) == true
end

local function is_admin(player_name)
	return has_privilege(player_name, "server")
		or has_privilege(player_name, "protection_bypass")
		or has_privilege(player_name, "debug")
end

local function has_commanding_sceptre(player)
	if not player then
		return false
	end
	if type(player.get_wielded_item) == "function" then
		local wielded = player:get_wielded_item()
		if wielded and wielded:get_name() == COMMANDING_SCEPTRE then
			return true
		end
	end
	if type(player.get_inventory) ~= "function" then
		return false
	end
	local inv = player:get_inventory()
	return inv and inv:contains_item("main", COMMANDING_SCEPTRE) or false
end

local function get_governance(owner_name, create)
	if not village_registry or type(owner_name) ~= "string" or owner_name == "" then
		return nil
	end
	local village = village_registry.get(owner_name)
	if not village and create then
		village = village_registry.ensure(owner_name)
	end
	if not village then
		return nil
	end
	village.governance = type(village.governance) == "table" and village.governance or {}
	village.governance.allies = type(village.governance.allies) == "table"
		and village.governance.allies or {}
	return village.governance
end

local function is_ally(governance, player_name)
	if not governance or not player_name then
		return false
	end
	local entry = governance.allies and governance.allies[player_name]
	return entry == true or entry == player_name or
		(type(entry) == "table" and entry.enabled ~= false)
end

function access.can_manage_owner(owner_name, player_or_name)
	local player_name, player = resolve_player(player_or_name)
	if not player_name then
		return false, "invalid_player"
	end
	if is_admin(player_name) then
		return true, "admin"
	end

	owner_name = owner_name or ""
	if owner_name == SELF_EMPLOYED_OWNER then
		local public = minetest.settings:get_bool("working_villages_self_employed_public", false)
		if not public then
			return false, "self_employed_private"
		end
		if not has_commanding_sceptre(player) then
			return false, "commanding_sceptre_required"
		end
		return true, "public_self_employed"
	end

	if owner_name ~= "" and owner_name == player_name then
		return true, "owner"
	end

	local governance = get_governance(owner_name, false)
	if is_ally(governance, player_name) then
		return true, "ally"
	end
	if governance and governance.public == true then
		if not has_commanding_sceptre(player) then
			return false, "commanding_sceptre_required"
		end
		return true, "public_village"
	end
	return false, "not_owner"
end

function access.can_govern_owner(owner_name, player_or_name)
	local player_name = resolve_player(player_or_name)
	if not player_name then
		return false, "invalid_player"
	end
	if is_admin(player_name) then
		return true, "admin"
	end
	if owner_name ~= "" and owner_name == player_name then
		return true, "owner"
	end
	return false, "not_owner"
end

function access.set_public(owner_name, enabled, actor)
	local allowed, reason = access.can_govern_owner(owner_name, actor)
	if not allowed then
		return false, reason
	end
	local governance = get_governance(owner_name, true)
	if not governance then
		return false, "village_registry_unavailable"
	end
	governance.public = enabled == true
	local updated, update_error = village_registry.update(owner_name, {governance = governance})
	return updated ~= nil, update_error
end

function access.set_ally(owner_name, ally_name, enabled, actor)
	local allowed, reason = access.can_govern_owner(owner_name, actor)
	if not allowed then
		return false, reason
	end
	if type(ally_name) ~= "string" or ally_name == "" or ally_name == owner_name then
		return false, "invalid_ally"
	end
	local governance = get_governance(owner_name, true)
	if not governance then
		return false, "village_registry_unavailable"
	end
	governance.allies[ally_name] = enabled == true and true or nil
	local updated, update_error = village_registry.update(owner_name, {governance = governance})
	return updated ~= nil, update_error
end

if minetest.register_chatcommand then
	minetest.register_chatcommand("wv_village_public", {
		params = "on|off|status",
		description = "Active ou desactive explicitement le controle public de votre village.",
		func = function(name, param)
			param = tostring(param or "status"):lower():match("^%s*(.-)%s*$")
			local governance = get_governance(name, true)
			if param == "status" or param == "" then
				return true, "Village public: " .. ((governance and governance.public) and "oui" or "non")
			end
			if param ~= "on" and param ~= "off" then
				return false, "Usage: /wv_village_public on|off|status"
			end
			local ok, err = access.set_public(name, param == "on", name)
			if not ok then
				return false, "Modification refusee: " .. tostring(err)
			end
			return true, "Village public: " .. (param == "on" and "oui" or "non")
		end,
	})

	minetest.register_chatcommand("wv_village_ally", {
		params = "add|remove|list [joueur]",
		description = "Gere les allies autorises a controler votre village.",
		func = function(name, param)
			local action, ally_name = tostring(param or ""):match("^%s*(%S*)%s*(.-)%s*$")
			if action == "list" then
				local governance = get_governance(name, true)
				local names = {}
				for candidate, entry in pairs((governance and governance.allies) or {}) do
					if entry == true or entry == candidate then
						names[#names + 1] = candidate
					end
				end
				table.sort(names)
				return true, #names > 0 and ("Allies: " .. table.concat(names, ", ")) or "Aucun allie."
			end
			if (action ~= "add" and action ~= "remove") or ally_name == "" then
				return false, "Usage: /wv_village_ally add|remove|list [joueur]"
			end
			local ok, err = access.set_ally(name, ally_name, action == "add", name)
			if not ok then
				return false, "Modification refusee: " .. tostring(err)
			end
			return true, action == "add" and (ally_name .. " est maintenant allie.")
				or (ally_name .. " n'est plus allie.")
		end,
	})
end

function access.can_manage_villager(villager, player_or_name)
	if not villager then
		return false, "invalid_villager"
	end
	return access.can_manage_owner(villager.owner_name or "", player_or_name)
end

working_villages.access = access
working_villages.can_manage_villager = access.can_manage_villager
working_villages.can_manage_owner = access.can_manage_owner
working_villages.can_govern_owner = access.can_govern_owner

return access
