-- Blueprint Management Forms
-- Allows players to view and manage villager blueprints through the commanding sceptre

local forms = working_villages.require("forms")
local blueprints = working_villages.blueprints

-- Blueprint overview form
forms.register_page("working_villages:blueprints_menu", {
	constructor = function(villager, player_name)
		local inv_name = villager:get_inventory_name()
		local data = blueprints.get_villager_data(inv_name)
		
		local formspec = forms.form_base(10, 8, villager)
		formspec = formspec .. "label[0.5,1;Blueprint Knowledge]"
		formspec = formspec .. "label[0.5,1.5;Experience: " .. data.experience .. "]"
		formspec = formspec .. "label[0.5,2;Buildings Completed: " .. data.construction_count .. "]"
		
		-- Show learned blueprints
		formspec = formspec .. "label[0.5,2.8;Learned Blueprints:]"
		local y = 3.3
		local count = 0
		for bp_name, level in pairs(data.blueprints) do
			local bp = blueprints.get(bp_name)
			if bp then
				formspec = formspec .. "label[0.5," .. y .. ";" .. bp.description .. " (Level " .. level .. "/" .. bp.max_level .. ")]"
				y = y + 0.5
				count = count + 1
				if count >= 6 then
					break
				end
			end
		end
		
		if count == 0 then
			formspec = formspec .. "label[0.5,3.3;No blueprints learned yet]"
		end
		
		formspec = formspec .. "button[0.5,7;3,1;learn_blueprints;Learn New Blueprints]"
		formspec = formspec .. "button[3.7,7;3,1;improve_blueprints;Improve Blueprints]"
		formspec = formspec .. "button_exit[6.9,7;2.6,1;close;Close]"
		
		return formspec
	end,
	receiver = function(self, villager, player, fields)
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
		local inv_name = villager:get_inventory_name()
		local available = blueprints.get_available_to_learn(inv_name)
		local data = blueprints.get_villager_data(inv_name)
		
		local formspec = forms.form_base(10, 8, villager)
		formspec = formspec .. "label[0.5,1;Available Blueprints to Learn]"
		formspec = formspec .. "label[0.5,1.5;Your Experience: " .. data.experience .. "]"
		
		local y = 2.5
		local count = 0
		for bp_name, bp in pairs(available) do
			local req_exp = bp.difficulty * 10
			formspec = formspec .. "label[0.5," .. y .. ";" .. bp.description .. "]"
			formspec = formspec .. "label[5," .. y .. ";Difficulty: " .. bp.difficulty .. " | Req: " .. req_exp .. " XP]"
			formspec = formspec .. "button[7.5," .. (y-0.2) .. ";2,0.8;learn_" .. bp_name .. ";Learn]"
			y = y + 1
			count = count + 1
			if count >= 4 then
				formspec = formspec .. "label[0.5," .. y .. ";... and more]"
				break
			end
		end
		
		if count == 0 then
			formspec = formspec .. "label[0.5,2.5;No blueprints available to learn]"
			formspec = formspec .. "label[0.5,3;Gain more experience by completing tasks!]"
		end
		
		formspec = formspec .. "button[0.5,7;2,1;back;Back]"
		
		return formspec
	end,
	receiver = function(self, villager, player, fields)
		local inv_name = villager:get_inventory_name()
		
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
					minetest.chat_send_player(player:get_player_name(), "Villager learned: " .. bp_name)
					forms.show_formspec(villager, "working_villages:blueprints_menu", player:get_player_name())
				else
					minetest.chat_send_player(player:get_player_name(), "Failed to learn: " .. msg)
				end
				return
			end
		end
	end,
})

-- Improve blueprints form
forms.register_page("working_villages:improve_blueprints", {
	constructor = function(villager, player_name)
		local inv_name = villager:get_inventory_name()
		local available = blueprints.get_available_to_improve(inv_name)
		local data = blueprints.get_villager_data(inv_name)
		
		local formspec = forms.form_base(10, 8, villager)
		formspec = formspec .. "label[0.5,1;Blueprints Ready to Improve]"
		formspec = formspec .. "label[0.5,1.5;Your Experience: " .. data.experience .. "]"
		
		local y = 2.5
		local count = 0
		for bp_name, improvement_data in pairs(available) do
			local bp = improvement_data.blueprint
			local level = improvement_data.current_level
			local req_exp = improvement_data.required_exp
			
			formspec = formspec .. "label[0.5," .. y .. ";" .. bp.description .. " (Lvl " .. level .. " → " .. (level+1) .. ")]"
			formspec = formspec .. "label[5," .. y .. ";Cost: " .. req_exp .. " XP]"
			formspec = formspec .. "button[7.5," .. (y-0.2) .. ";2,0.8;improve_" .. bp_name .. ";Improve]"
			y = y + 1
			count = count + 1
			if count >= 4 then
				break
			end
		end
		
		if count == 0 then
			formspec = formspec .. "label[0.5,2.5;No blueprints ready to improve]"
			formspec = formspec .. "label[0.5,3;Either you need more experience or your blueprints are maxed out!]"
		end
		
		formspec = formspec .. "button[0.5,7;2,1;back;Back]"
		
		return formspec
	end,
	receiver = function(self, villager, player, fields)
		local inv_name = villager:get_inventory_name()
		
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
					minetest.chat_send_player(player:get_player_name(), "Failed to improve: " .. msg)
				end
				return
			end
		end
	end,
})

-- Add link from main menu to blueprints
forms.put_link("working_villages:talking_menu", "working_villages:blueprints_menu", "Blueprints")
