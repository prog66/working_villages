-- Guard Job Configuration Forms
-- Allows players to configure guard behavior through the commanding sceptre

local forms = working_villages.require("forms")
local GUARD_JOB_NAME = "working_villages:job_guard"

-- Constants
local MAX_PATROL_RADIUS = 100

local function is_guard(villager)
	if not villager or type(villager.get_job_name) ~= "function" then
		return false
	end
	return villager:get_job_name() == GUARD_JOB_NAME
end

local function is_position(value)
	return type(value) == "table" and type(value.x) == "number" and
		type(value.y) == "number" and type(value.z) == "number"
end

-- Helper function to get valid inventory name
local function get_inv_name(villager)
	if not villager then
		return nil
	end
	local inv_name = nil
	if type(villager.get_inventory_name) == "function" then
		inv_name = villager:get_inventory_name()
	end
	if not inv_name then
		inv_name = villager.inventory_name
	end
	if type(inv_name) ~= "string" or inv_name == "" then
		return nil
	end
	return inv_name
end

-- Main guard configuration form
forms.register_page("working_villages:guard_config", {
	requires_manage = true,
	constructor = function(_, villager, player_name)
		local inv_name = get_inv_name(villager)
		if not inv_name then
			return forms.form_base(8, 8, villager) ..
				"label[0.5,1;Erreur: villageois invalide]"
		end
		
		-- Check if the villager has the guard job
		if not is_guard(villager) then
			return forms.form_base(8, 8, villager) ..
				"label[0.5,1;Ce villageois n'est pas un garde.]" ..
				"button[3,7;2,1;back;Retour]"
		end
		
		-- Get current configuration
		local current_mode = villager:get_job_data("mode") or "patrol"
		if current_mode ~= "stationary" and current_mode ~= "escort" and
			current_mode ~= "patrol" and current_mode ~= "wandering" then
			current_mode = "patrol"
		end
		local guard_target = villager:get_job_data("guard_target")
		
		-- Build the form
		local formspec = forms.form_base(9, 9, villager)
		formspec = formspec .. "label[0.5,1;Configuration du garde]"
		formspec = formspec .. "label[0.5,1.7;Mode actuel : " .. minetest.formspec_escape(current_mode) .. "]"
		
		-- Mode selection dropdown
		local mode_index = 1
		if current_mode == "stationary" then mode_index = 1
		elseif current_mode == "escort" then mode_index = 2
		elseif current_mode == "patrol" then mode_index = 3
		elseif current_mode == "wandering" then mode_index = 4
		end
		
		formspec = formspec .. "label[0.5,2.5;Selectionner le mode :]"
		formspec = formspec .. "dropdown[0.5,3;7,1;guard_mode;stationner,escorter,patrouiller,errer;" .. mode_index .. "]"
		
		-- Mode-specific options
		formspec = formspec .. "label[0.5,4.2;Options du mode selectionne :]"
		
		-- Stationary mode options
		if current_mode == "stationary" then
			local pos_str = ""
			if is_position(guard_target) then
				pos_str = minetest.pos_to_string(guard_target)
			end
			formspec = formspec .. "label[0.5,4.7;Position de stationnement :]"
			formspec = formspec .. "field[0.8,5.5;6,1;station_pos;;" .. minetest.formspec_escape(pos_str) .. "]"
			formspec = formspec .. "tooltip[station_pos;Format: (x,y,z) ou laisser vide pour utiliser la position actuelle]"
			formspec = formspec .. "button[6.5,5.2;2,1;set_here;Ici]"
		
		-- Escort mode options
		elseif current_mode == "escort" then
			local escort_name = ""
			if type(guard_target) == "string" then
				escort_name = guard_target
			elseif guard_target == nil or guard_target == "" then
				escort_name = villager.owner_name or ""
			end
			formspec = formspec .. "label[0.5,4.7;Nom du joueur a escorter :]"
			formspec = formspec .. "field[0.8,5.5;6,1;escort_target;;" .. minetest.formspec_escape(escort_name) .. "]"
			formspec = formspec .. "tooltip[escort_target;Nom du joueur a suivre et proteger]"
		
		-- Patrol mode options
		elseif current_mode == "patrol" then
			-- Get current patrol radius from job_data or fall back to settings default
			local patrol_radius = villager:get_job_data("patrol_radius") or tonumber(minetest.settings:get("working_villages_guard_patrol_radius")) or 12
			local patrol_center = guard_target
			local center_str = ""
			if is_position(patrol_center) then
				center_str = minetest.pos_to_string(patrol_center)
			end
			
			formspec = formspec .. "label[0.5,4.7;Rayon de patrouille (noeuds) :]"
			formspec = formspec .. "field[0.8,5.5;3,1;patrol_radius;;" .. minetest.formspec_escape(tostring(patrol_radius)) .. "]"
			formspec = formspec .. "tooltip[patrol_radius;Distance maximale de patrouille depuis le centre (1-" .. MAX_PATROL_RADIUS .. " noeuds)]"
			
			formspec = formspec .. "label[0.5,6;Centre de patrouille :]"
			formspec = formspec .. "field[0.8,6.8;6,1;patrol_center;;" .. minetest.formspec_escape(center_str) .. "]"
			formspec = formspec .. "tooltip[patrol_center;Position centrale (x,y,z) ou laisser vide pour utiliser la position actuelle]"
			formspec = formspec .. "button[6.5,6.5;2,1;set_center_here;Ici]"
		
		-- Wandering mode (no specific options)
		elseif current_mode == "wandering" then
			formspec = formspec .. "label[0.5,4.7;Mode errance : le garde se deplace aleatoirement]"
			formspec = formspec .. "label[0.5,5.2;sans zone specifique.]"
		end
		
		-- Action buttons
		formspec = formspec .. "button[0.5,8;3,1;apply;Appliquer]"
		formspec = formspec .. "button[3.7,8;2,1;back;Retour]"
		formspec = formspec .. "button_exit[5.9,8;2.6,1;close;Fermer]"
		
		return formspec
	end,
	
	receiver = function(_, villager, player, fields)
		local inv_name = get_inv_name(villager)
		if not inv_name then
			if player and type(player.get_player_name) == "function" then
				minetest.chat_send_player(player:get_player_name(), "Villageois introuvable ou formulaire perime.")
			end
			return
		end
		
		local player_name = player:get_player_name()
		if fields.back then
			forms.go_back(villager, player_name)
			return
		end
		local sensitive_action = fields.apply or fields.set_here or fields.set_center_here
		if not sensitive_action then
			return
		end
		if not is_guard(villager) then
			minetest.chat_send_player(player_name, "Action refusee : ce villageois n'est plus garde.")
			return
		end

		local function parse_guard_mode(value)
			local modes = {"stationary", "escort", "patrol", "wandering"}
			local labels = {
				stationner = "stationary",
				escorter = "escort",
				patrouiller = "patrol",
				errer = "wandering",
			}
			if value == nil or value == "" then
				return nil
			end
			local mode_index = tonumber(value)
			if mode_index and modes[mode_index] then
				return modes[mode_index]
			end
			local key = tostring(value):lower()
			key = key:gsub("%s+", "")
			if labels[key] then
				return labels[key]
			end
			for _, mode in ipairs(modes) do
				if key == mode then
					return mode
				end
			end
			return nil
		end

		local function current_villager_pos()
			if not villager.object or type(villager.object.get_pos) ~= "function" then
				return nil
			end
			local ok, pos = pcall(villager.object.get_pos, villager.object)
			if not ok or not is_position(pos) then
				return nil
			end
			return pos
		end
		
		-- Handle mode change and apply settings
		if fields.apply then
			local new_mode = parse_guard_mode(fields.guard_mode)
			if not new_mode then
				minetest.chat_send_player(player_name, "Mode de garde invalide ou formulaire perime.")
				return
			end

			local new_target = nil
			local new_radius = nil
			if new_mode == "stationary" then
				if fields.station_pos and fields.station_pos ~= "" then
					new_target = minetest.string_to_pos(fields.station_pos)
					if not new_target then
						minetest.chat_send_player(player_name, "Position invalide. Format: (x,y,z)")
						return
					end
				else
					new_target = current_villager_pos()
					if not new_target then
						minetest.chat_send_player(player_name, "Position du garde indisponible ; aucune modification appliquee.")
						return
					end
				end
			elseif new_mode == "escort" then
				if fields.escort_target and fields.escort_target ~= "" then
					new_target = fields.escort_target
				else
					new_target = villager.owner_name or ""
				end
			elseif new_mode == "patrol" then
				if fields.patrol_radius and fields.patrol_radius ~= "" then
					new_radius = tonumber(fields.patrol_radius)
					if not new_radius or new_radius <= 0 or new_radius > MAX_PATROL_RADIUS then
						minetest.chat_send_player(player_name, "Rayon invalide. Utilisez une valeur entre 1 et " .. MAX_PATROL_RADIUS .. ".")
						return
					end
				end
				if fields.patrol_center and fields.patrol_center ~= "" then
					new_target = minetest.string_to_pos(fields.patrol_center)
					if not new_target then
						minetest.chat_send_player(player_name, "Position invalide. Format: (x,y,z)")
						return
					end
				else
					new_target = current_villager_pos()
					if not new_target then
						minetest.chat_send_player(player_name, "Position du garde indisponible ; aucune modification appliquee.")
						return
					end
				end
			end

			villager:set_job_data("mode", new_mode)
			if new_radius then
				villager:set_job_data("patrol_radius", new_radius)
			end
			villager:set_job_data("guard_target", new_target)
			minetest.chat_send_player(player_name, "Configuration du garde appliquee : mode " .. new_mode)
			forms.show_formspec(villager, "working_villages:guard_config", player_name)
		elseif fields.set_here then
			if villager:get_job_data("mode") ~= "stationary" then
				minetest.chat_send_player(player_name, "Formulaire perime : le garde n'est plus en mode stationnaire.")
				return
			end
			local current_pos = current_villager_pos()
			if not current_pos then
				minetest.chat_send_player(player_name, "Position du garde indisponible.")
				return
			end
			villager:set_job_data("guard_target", current_pos)
			minetest.chat_send_player(player_name, "Position definie a : " .. minetest.pos_to_string(current_pos))
			forms.show_formspec(villager, "working_villages:guard_config", player_name)
			
		elseif fields.set_center_here then
			if villager:get_job_data("mode") ~= "patrol" then
				minetest.chat_send_player(player_name, "Formulaire perime : le garde n'est plus en mode patrouille.")
				return
			end
			local current_pos = current_villager_pos()
			if not current_pos then
				minetest.chat_send_player(player_name, "Position du garde indisponible.")
				return
			end
			villager:set_job_data("guard_target", current_pos)
			minetest.chat_send_player(player_name, "Centre de patrouille defini a : " .. minetest.pos_to_string(current_pos))
			forms.show_formspec(villager, "working_villages:guard_config", player_name)
		end
	end,
})

-- Add a conditional link to guard configuration
-- Create a wrapper page that checks if the villager is a guard
forms.register_page("working_villages:guard_check", {
	requires_manage = true,
	constructor = function(_, villager, player_name)
		if is_guard(villager) then
			-- If it's a guard, redirect to guard config
			forms.show_formspec(villager, "working_villages:guard_config", player_name)
			return "" -- Return empty string since we're redirecting
		else
			-- Not a guard, show message
			return forms.form_base(8, 5, villager) ..
				"label[0.5,1;Ce villageois n'est pas un garde.]" ..
				"label[0.5,1.7;Cette option est seulement disponible pour les gardes.]" ..
				"button[3,3.5;2,1;back;Retour]"
		end
	end,
	receiver = function(_, villager, player, fields)
		if fields.back then
			forms.go_back(villager, player:get_player_name())
		end
	end,
})

-- Add link from talking menu to guard configuration
-- This link will be shown for all villagers, but will redirect properly
forms.put_link("working_villages:talking_menu", "working_villages:guard_config",
	"Configurer le garde")

return true
