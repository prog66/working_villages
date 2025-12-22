-- Blueprint Management Forms
-- Allows players to view and manage villager blueprints through the commanding sceptre

local forms = working_villages.require("forms")
local blueprints = working_villages.blueprints

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

-- Blueprint overview form
forms.register_page("working_villages:blueprints_menu", {
	constructor = function(villager, player_name)
		local inv_name = get_inv_name(villager)
		if not inv_name then
			return forms.form_base(10, 8, villager) ..
				"label[0.5,1;Erreur: villageois invalide]"
		end
		local data = blueprints.get_villager_data(inv_name)
		
		local formspec = forms.form_base(10, 8, villager)
		formspec = formspec .. "label[0.5,1;Connaissance des plans]"
		formspec = formspec .. "label[0.5,1.5;Experience : " .. data.experience .. "]"
		formspec = formspec .. "label[0.5,2;Constructions terminees : " .. data.construction_count .. "]"
		
		-- Show learned blueprints
		formspec = formspec .. "label[0.5,2.8;Plans appris :]"
		local y = 3.3
		local count = 0
		for bp_name, level in pairs(data.blueprints) do
			local bp = blueprints.get(bp_name)
			if bp then
				formspec = formspec .. "label[0.5," .. y .. ";" .. bp.description .. " (Niveau " .. level .. "/" .. bp.max_level .. ")]"
				y = y + 0.5
				count = count + 1
				if count >= 6 then
					break
				end
			end
		end
		
		if count == 0 then
			formspec = formspec .. "label[0.5,3.3;Aucun plan appris]"
		end
		
		formspec = formspec .. "button[0.5,7;3,1;learn_blueprints;Apprendre des plans]"
		formspec = formspec .. "button[3.7,7;3,1;improve_blueprints;Ameliorer les plans]"
		formspec = formspec .. "button_exit[6.9,7;2.6,1;close;Fermer]"
		
		return formspec
	end,
	receiver = function(self, villager, player, fields)
		local inv_name = get_inv_name(villager)
		if not inv_name then
			return
		end
		if fields.learn_blueprints then
			forms.show_formspec(villager, "working_villages:learn_blueprints", player:get_player_name())
		elseif fields.improve_blueprints then
			forms.show_formspec(villager, "working_villages:improve_blueprints", player:get_player_name())
		end
	end,
})

-- Learn new blueprints form
forms.register_page("working_villages:learn_blueprints", {
	constructor = function(villager, player_name)
		local inv_name = get_inv_name(villager)
		if not inv_name then
			return forms.form_base(10, 8, villager) ..
				"label[0.5,1;Erreur: villageois invalide]"
		end
		local available = blueprints.get_available_to_learn(inv_name)
		local data = blueprints.get_villager_data(inv_name)
		
		local formspec = forms.form_base(10, 8, villager)
		formspec = formspec .. "label[0.5,1;Plans disponibles a apprendre]"
		formspec = formspec .. "label[0.5,1.5;Votre experience : " .. data.experience .. "]"
		
		local y = 2.5
		local count = 0
		for bp_name, bp in pairs(available) do
			local req_exp = bp.difficulty * 10
			formspec = formspec .. "label[0.5," .. y .. ";" .. bp.description .. "]"
			formspec = formspec .. "label[5," .. y .. ";Difficulte : " .. bp.difficulty .. " | Requis : " .. req_exp .. " XP]"
			formspec = formspec .. "button[7.5," .. (y-0.2) .. ";2,0.8;learn_" .. bp_name .. ";Apprendre]"
			y = y + 1
			count = count + 1
			if count >= 4 then
				formspec = formspec .. "label[0.5," .. y .. ";... et plus]"
				break
			end
		end
		
		if count == 0 then
			formspec = formspec .. "label[0.5,2.5;Aucun plan a apprendre]"
			formspec = formspec .. "label[0.5,3;Gagnez de l'experience en terminant des taches !]"
		end
		
		formspec = formspec .. "button[0.5,7;2,1;back;Retour]"
		
		return formspec
	end,
	receiver = function(self, villager, player, fields)
		local inv_name = get_inv_name(villager)
		if not inv_name then
			return
		end
		
		if fields.back then
			forms.go_back(villager, player:get_player_name())
			return
		end
		
		-- Check for learn buttons
		for field_name, _ in pairs(fields) do
			if field_name:sub(1, 6) == "learn_" then
				local bp_name = field_name:sub(7)
				local success, msg = blueprints.teach(inv_name, bp_name)
				if success then
					minetest.chat_send_player(player:get_player_name(), "Le villageois a appris : " .. bp_name)
					forms.show_formspec(villager, "working_villages:blueprints_menu", player:get_player_name())
				else
					minetest.chat_send_player(player:get_player_name(), "Echec de l'apprentissage : " .. msg)
				end
				return
			end
		end
	end,
})

-- Improve blueprints form
forms.register_page("working_villages:improve_blueprints", {
	constructor = function(villager, player_name)
		local inv_name = get_inv_name(villager)
		if not inv_name then
			return forms.form_base(10, 8, villager) ..
				"label[0.5,1;Erreur: villageois invalide]"
		end
		local available = blueprints.get_available_to_improve(inv_name)
		local data = blueprints.get_villager_data(inv_name)
		
		local formspec = forms.form_base(10, 8, villager)
		formspec = formspec .. "label[0.5,1;Plans prets a ameliorer]"
		formspec = formspec .. "label[0.5,1.5;Votre experience : " .. data.experience .. "]"
		
		local y = 2.5
		local count = 0
		for bp_name, improvement_data in pairs(available) do
			local bp = improvement_data.blueprint
			local level = improvement_data.current_level
			local req_exp = improvement_data.required_exp
			
			formspec = formspec .. "label[0.5," .. y .. ";" .. bp.description .. " (Niveau " .. level .. " -> " .. (level+1) .. ")]"
			formspec = formspec .. "label[5," .. y .. ";Cout : " .. req_exp .. " XP]"
			formspec = formspec .. "button[7.5," .. (y-0.2) .. ";2,0.8;improve_" .. bp_name .. ";Ameliorer]"
			y = y + 1
			count = count + 1
			if count >= 4 then
				break
			end
		end
		
		if count == 0 then
			formspec = formspec .. "label[0.5,2.5;Aucun plan a ameliorer]"
			formspec = formspec .. "label[0.5,3;Il faut plus d'experience ou les plans sont au maximum !]"
		end
		
		formspec = formspec .. "button[0.5,7;2,1;back;Retour]"
		
		return formspec
	end,
	receiver = function(self, villager, player, fields)
		local inv_name = get_inv_name(villager)
		if not inv_name then
			return
		end
		
		if fields.back then
			forms.go_back(villager, player:get_player_name())
			return
		end
		
		-- Check for improve buttons
		for field_name, _ in pairs(fields) do
			if field_name:sub(1, 8) == "improve_" then
				local bp_name = field_name:sub(9)
				local success, msg = blueprints.improve(inv_name, bp_name)
				if success then
					minetest.chat_send_player(player:get_player_name(), msg)
					forms.show_formspec(villager, "working_villages:blueprints_menu", player:get_player_name())
				else
					minetest.chat_send_player(player:get_player_name(), "Echec de l'amelioration : " .. msg)
				end
				return
			end
		end
	end,
})

-- Add link from main menu to blueprints
forms.put_link("working_villages:talking_menu", "working_villages:blueprints_menu", "Plans")
