-- Guard Job Configuration Forms
-- Allows players to configure guard behavior through the commanding sceptre

local forms = working_villages.require("forms")

-- Constants
local MAX_PATROL_RADIUS = 100

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
	if inv_name == "" then
		return nil
	end
	return inv_name
end

-- Main guard configuration form
forms.register_page("working_villages:guard_config", {
	constructor = function(_, villager, player_name)
		local inv_name = get_inv_name(villager)
		if not inv_name then
			return forms.form_base(8, 8, villager) ..
				"label[0.5,1;Erreur: villageois invalide]"
		end
		
		-- Check if the villager has the guard job
		local job = villager:get_job()
		if not job or job.description ~= "garde (working_villages)" then
			return forms.form_base(8, 8, villager) ..
				"label[0.5,1;Ce villageois n'est pas un garde.]" ..
				"button[3,7;2,1;back;Retour]"
		end
		
		-- Get current configuration
		local current_mode = villager:get_job_data("mode") or "patrol"
		local guard_target = villager:get_job_data("guard_target")
		
		-- Build the form
		local formspec = forms.form_base(9, 9, villager)
		formspec = formspec .. "label[0.5,1;Configuration du garde]"
		formspec = formspec .. "label[0.5,1.7;Mode actuel : " .. current_mode .. "]"
		
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
			if type(guard_target) == "table" and guard_target.x then
				pos_str = minetest.pos_to_string(guard_target)
			end
			formspec = formspec .. "label[0.5,4.7;Position de stationnement :]"
			formspec = formspec .. "field[0.8,5.5;6,1;station_pos;;" .. pos_str .. "]"
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
			formspec = formspec .. "field[0.8,5.5;6,1;escort_target;;" .. escort_name .. "]"
			formspec = formspec .. "tooltip[escort_target;Nom du joueur a suivre et proteger]"
		
		-- Patrol mode options
		elseif current_mode == "patrol" then
			-- Get current patrol radius from job_data or fall back to settings default
			local patrol_radius = villager:get_job_data("patrol_radius") or tonumber(minetest.settings:get("working_villages_guard_patrol_radius")) or 12
			local patrol_center = guard_target
			local center_str = ""
			if type(patrol_center) == "table" and patrol_center.x then
				center_str = minetest.pos_to_string(patrol_center)
			end
			
			formspec = formspec .. "label[0.5,4.7;Rayon de patrouille (noeuds) :]"
			formspec = formspec .. "field[0.8,5.5;3,1;patrol_radius;;" .. patrol_radius .. "]"
			formspec = formspec .. "tooltip[patrol_radius;Distance maximale de patrouille depuis le centre (1-" .. MAX_PATROL_RADIUS .. " noeuds)]"
			
			formspec = formspec .. "label[0.5,6;Centre de patrouille :]"
			formspec = formspec .. "field[0.8,6.8;6,1;patrol_center;;" .. center_str .. "]"
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
			return
		end
		
		local player_name = player:get_player_name()
		
		-- Handle mode change and apply settings
		if fields.apply then
			local new_mode = "patrol" -- default
			
			-- Parse dropdown selection (dropdown returns selected index as string)
			if fields.guard_mode then
				local modes = {"stationary", "escort", "patrol", "wandering"}
				local mode_index = tonumber(fields.guard_mode)
				if mode_index and mode_index >= 1 and mode_index <= #modes then
					new_mode = modes[mode_index]
				end
			end
			
			-- Set the mode
			villager:set_job_data("mode", new_mode)
			
			-- Apply mode-specific settings
			if new_mode == "stationary" then
				if fields.station_pos and fields.station_pos ~= "" then
					local pos = minetest.string_to_pos(fields.station_pos)
					if pos then
						villager:set_job_data("guard_target", pos)
						minetest.chat_send_player(player_name, "Position de stationnement definie.")
					else
						minetest.chat_send_player(player_name, "Position invalide. Format: (x,y,z)")
					end
				else
					-- Use current position if no position specified
					local current_pos = villager.object:get_pos()
					villager:set_job_data("guard_target", current_pos)
					minetest.chat_send_player(player_name, "Position de stationnement definie a la position actuelle.")
				end
				
			elseif new_mode == "escort" then
				if fields.escort_target and fields.escort_target ~= "" then
					villager:set_job_data("guard_target", fields.escort_target)
					minetest.chat_send_player(player_name, "Cible d'escorte definie : " .. fields.escort_target)
				else
					villager:set_job_data("guard_target", villager.owner_name or "")
					minetest.chat_send_player(player_name, "Cible d'escorte definie au proprietaire.")
				end
				
			elseif new_mode == "patrol" then
				-- Save patrol radius per guard in job_data
				if fields.patrol_radius and fields.patrol_radius ~= "" then
					local radius = tonumber(fields.patrol_radius)
					if radius and radius > 0 and radius <= MAX_PATROL_RADIUS then
						villager:set_job_data("patrol_radius", radius)
						minetest.chat_send_player(player_name, "Rayon de patrouille : " .. radius .. " noeuds")
					else
						minetest.chat_send_player(player_name, "Rayon invalide. Utilisez une valeur entre 1 et " .. MAX_PATROL_RADIUS .. ".")
					end
				end
				
				-- Set patrol center
				if fields.patrol_center and fields.patrol_center ~= "" then
					local pos = minetest.string_to_pos(fields.patrol_center)
					if pos then
						villager:set_job_data("guard_target", pos)
						minetest.chat_send_player(player_name, "Centre de patrouille defini.")
					else
						minetest.chat_send_player(player_name, "Position invalide. Format: (x,y,z)")
					end
				else
					-- Use current position if no center specified
					local current_pos = villager.object:get_pos()
					villager:set_job_data("guard_target", current_pos)
					minetest.chat_send_player(player_name, "Centre de patrouille defini a la position actuelle.")
				end
				
			elseif new_mode == "wandering" then
				-- No specific configuration needed for wandering mode
				villager:set_job_data("guard_target", nil)
			end
			
			minetest.chat_send_player(player_name, "Configuration du garde appliquee : mode " .. new_mode)
			
			-- Refresh the form to show updated settings
			forms.show_formspec(villager, "working_villages:guard_config", player_name)
			
		elseif fields.set_here then
			-- Set stationary position to current location
			local current_pos = villager.object:get_pos()
			villager:set_job_data("guard_target", current_pos)
			minetest.chat_send_player(player_name, "Position definie a : " .. minetest.pos_to_string(current_pos))
			forms.show_formspec(villager, "working_villages:guard_config", player_name)
			
		elseif fields.set_center_here then
			-- Set patrol center to current location
			local current_pos = villager.object:get_pos()
			villager:set_job_data("guard_target", current_pos)
			minetest.chat_send_player(player_name, "Centre de patrouille defini a : " .. minetest.pos_to_string(current_pos))
			forms.show_formspec(villager, "working_villages:guard_config", player_name)
			
		elseif fields.back then
			forms.go_back(villager, player_name)
		end
	end,
})

-- Add a conditional link to guard configuration
-- Create a wrapper page that checks if the villager is a guard
forms.register_page("working_villages:guard_check", {
	constructor = function(_, villager, player_name)
		local job = villager:get_job()
		if job and job.description == "garde (working_villages)" then
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
forms.put_link("working_villages:talking_menu", "working_villages:guard_check",
	"Configurer le garde")

return true
