-- Blueprint Management Forms
-- Allows players to view and manage villager blueprints through the commanding sceptre

local forms = working_villages.require("forms")
local blueprints = working_villages.blueprints
local experiments = working_villages.blueprint_experiments
local permissions = working_villages.permissions
local blueprint_construction = working_villages.blueprint_construction

local function is_creative_test_mode()
	return working_villages.gameplay_mode == "creative_test"
end

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

local function send_error(player, message)
	if not player or type(player.get_player_name) ~= "function" then
		return
	end
	local player_name = player:get_player_name()
	if player_name and player_name ~= "" then
		minetest.chat_send_player(player_name, message)
	end
end

local function is_builder(villager)
	return villager and type(villager.get_job_name) == "function" and
		villager:get_job_name() == "working_villages:job_builder"
end

local function get_pending_proposal(villager)
	local job_data = villager and type(villager.job_data) == "table" and villager.job_data or nil
	local proposal = job_data and job_data.plan_proposal
	if type(proposal) ~= "table" or type(proposal.permission_key) ~= "string" or
		proposal.permission_key == "" then
		return nil
	end
	local requests = job_data.permission_requests
	local request = type(requests) == "table" and requests[proposal.permission_key] or nil
	if type(request) ~= "table" or request.status ~= "pending" then
		return nil
	end
	return proposal
end

-- Blueprint overview form
forms.register_page("working_villages:blueprints_menu", {
	requires_manage = true,
	constructor = function(self, villager, player_name)
		local inv_name = get_inv_name(villager)
		if not inv_name then
			return forms.form_base(10, 8, villager) ..
				"label[0.5,1;Erreur: villageois invalide]"
		end
		local data = blueprints.get_villager_data(inv_name)
		
		local formspec = forms.form_base(10, 9, villager)
		formspec = formspec .. "label[0.5,1;Connaissance des plans]"
		local note = villager.job_data and villager.job_data.learning_note
		local pending = 0
		if villager.job_data and type(villager.job_data.permission_requests) == "table" then
			for _, req in pairs(villager.job_data.permission_requests) do
				if type(req) == "table" and req.status == "pending" then
					pending = pending + 1
				end
			end
		end
		if villager.job_data and villager.job_data.plan_proposal then
			note = "Proposition .we en attente"
		elseif pending > 0 then
			note = "Autorisations en attente: " .. tostring(pending)
		end
		if note then
			formspec = formspec .. "label[0.5,1.3;" .. minetest.formspec_escape(note) .. "]"
		end
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
		
		formspec = formspec .. "button[0.5,6.4;3,0.8;learn_blueprints;Apprendre des plans]"
		formspec = formspec .. "button[3.7,6.4;3,0.8;improve_blueprints;Ameliorer les plans]"
		if is_creative_test_mode() then
			formspec = formspec .. "button[6.9,6.4;3,0.8;experiments_blueprints;Experiences .we]"
		end
		formspec = formspec .. "button[0.5,7.3;3,0.8;build_blueprints;Construire]"
		formspec = formspec .. "button_exit[7.0,7.3;2.5,0.8;close;Fermer]"
		if is_creative_test_mode() and villager and villager.get_job_name and
				villager:get_job_name() == "working_villages:job_builder" then
			formspec = formspec .. "button[3.7,7.3;3.0,0.8;force_experiment;Forcer experience]"
		end
		
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
		elseif fields.experiments_blueprints then
			if not is_creative_test_mode() then
				send_error(player, "Les experiences .we sont reservees au mode creative_test.")
				return
			end
			forms.show_formspec(villager, "working_villages:experiments_blueprints", player:get_player_name())
		elseif fields.build_blueprints then
			forms.show_formspec(villager, "working_villages:build_blueprints", player:get_player_name())
		elseif fields.force_experiment then
			if not is_creative_test_mode() then
				send_error(player, "Action reservee au mode creative_test.")
				return
			end
			if not is_builder(villager) then
				send_error(player, "Action refusee : ce villageois n'est plus constructeur.")
				return
			end
			villager.job_data = type(villager.job_data) == "table" and villager.job_data or {}
			villager.job_data.force_experiment = true
			villager.job_data.learning_note = "Recherche d'amelioration en cours..."
			minetest.chat_send_player(player:get_player_name(), "Le constructeur va rechercher une amelioration.")
		end
	end,
})

-- Learn new blueprints form
forms.register_page("working_villages:learn_blueprints", {
	requires_manage = true,
	constructor = function(self, villager, player_name)
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
			if type(field_name) == "string" and field_name:sub(1, 6) == "learn_" then
				local bp_name = field_name:sub(7)
				local available = blueprints.get_available_to_learn(inv_name)
				if bp_name == "" or not available[bp_name] then
					send_error(player, "Plan indisponible ou formulaire perime.")
					return
				end
				local success, msg = blueprints.teach(inv_name, bp_name)
				if success then
					minetest.chat_send_player(player:get_player_name(), "Le villageois a appris : " .. bp_name)
					villager.job_data = type(villager.job_data) == "table" and villager.job_data or {}
					villager.job_data.learning_note = "Appris : " .. bp_name
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
	requires_manage = true,
	constructor = function(self, villager, player_name)
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
			if type(field_name) == "string" and field_name:sub(1, 8) == "improve_" then
				local bp_name = field_name:sub(9)
				local available = blueprints.get_available_to_improve(inv_name)
				if bp_name == "" or not available[bp_name] then
					send_error(player, "Amelioration indisponible ou formulaire perime.")
					return
				end
				local success, msg = blueprints.improve(inv_name, bp_name)
				if success then
					minetest.chat_send_player(player:get_player_name(), msg)
					villager.job_data = type(villager.job_data) == "table" and villager.job_data or {}
					villager.job_data.learning_note = "Ameliore : " .. bp_name
					forms.show_formspec(villager, "working_villages:blueprints_menu", player:get_player_name())
				else
					minetest.chat_send_player(player:get_player_name(), "Echec de l'amelioration : " .. msg)
				end
				return
			end
		end
	end,
})

-- Blueprint experiments (.we editing)
forms.register_page("working_villages:experiments_blueprints", {
	requires_manage = true,
	constructor = function(self, villager, player_name)
		if not is_creative_test_mode() then
			return forms.form_base(10, 8, villager) ..
				"label[0.5,1;Experiences .we indisponibles en mode survie]" ..
				"button[0.5,7.3;2,1;back;Retour]"
		end
		local inv_name = get_inv_name(villager)
		if not inv_name then
			return forms.form_base(10, 8, villager) ..
				"label[0.5,1;Erreur: villageois invalide]"
		end
		local formspec = forms.form_base(10, 8, villager)
		villager.job_data = type(villager.job_data) == "table" and villager.job_data or {}
		formspec = formspec .. "label[0.5,1;Experiences de plans (.we)]"

		local proposal = get_pending_proposal(villager)
		if proposal and type(proposal.blueprint) == "table" then
			local proposal_name = proposal.blueprint.description or proposal.blueprint.name or "plan"
			formspec = formspec .. "label[0.5,1.7;Proposition en attente : " .. minetest.formspec_escape(proposal_name) .. "]"
			formspec = formspec .. "label[0.5,2.2;Type : " .. minetest.formspec_escape(proposal.description or "inconnue") .. "]"
			formspec = formspec .. "label[0.5,2.7;Exemples : " .. experiments.summary(proposal, 2) .. "]"
			formspec = formspec .. "button[0.5,6.5;2.5,1;approve_plan;Approuver]"
			formspec = formspec .. "button[3.2,6.5;2.5,1;reject_plan;Rejeter]"
		else
			formspec = formspec .. "label[0.5,1.7;Aucune proposition en attente]"
		end

		local y = 3.6
		formspec = formspec .. "label[0.5," .. y .. ";Proposer une amelioration :]"
		y = y + 0.6
		local count = 0
		for bp_name, bp in pairs(blueprints.get_all()) do
			if bp.schematic_file then
				formspec = formspec .. "label[0.5," .. y .. ";" .. bp.description .. "]"
				formspec = formspec .. "button[7.5," .. (y-0.2) .. ";2,0.8;propose_stone_" .. bp_name .. ";Style pierre]"
				y = y + 0.9
				count = count + 1
				if count >= 3 then
					break
				end
			end
		end

		formspec = formspec .. "button[0.5,7.3;2,1;back;Retour]"
		return formspec
	end,
	receiver = function(self, villager, player, fields)
		if fields.back then
			forms.go_back(villager, player:get_player_name())
			return
		end
		if not is_creative_test_mode() then
			send_error(player, "Les experiences .we sont reservees au mode creative_test.")
			return
		end
		local inv_name = get_inv_name(villager)
		if not inv_name then
			return
		end
		if fields.approve_plan then
			local proposal = get_pending_proposal(villager)
			if not proposal or not permissions.respond(villager, proposal.permission_key, true) then
				send_error(player, "Proposition introuvable ou deja traitee.")
				return
			end
			minetest.chat_send_player(player:get_player_name(), "Demande approuvee.")
			return
		end
		if fields.reject_plan then
			local proposal = get_pending_proposal(villager)
			if not proposal or not permissions.respond(villager, proposal.permission_key, false) then
				send_error(player, "Proposition introuvable ou deja traitee.")
				return
			end
			villager.job_data.plan_proposal = nil
			minetest.chat_send_player(player:get_player_name(), "Proposition annulee.")
			return
		end

		for field_name, _ in pairs(fields) do
			if type(field_name) == "string" and field_name:sub(1, 14) == "propose_stone_" then
				local bp_name = field_name:sub(15)
				local bp = blueprints.get(bp_name)
				if not bp or not bp.schematic_file then
					send_error(player, "Plan introuvable, obsolete ou incompatible avec cette experience.")
					return
				end
				local proposal, err = experiments.propose_stone_style(bp)
				if type(proposal) ~= "table" or proposal.id == nil then
					minetest.chat_send_player(player:get_player_name(), err or "Impossible de proposer.")
					return
				end
				proposal.permission_key = "save_plan:" .. proposal.id
				villager.job_data = type(villager.job_data) == "table" and villager.job_data or {}
				villager.job_data.plan_proposal = proposal
				local msg = ("Puis-je sauvegarder l'amelioration '%s' pour %s ?"):format(
					proposal.description, bp.description or bp_name)
				permissions.request(villager, proposal.permission_key, msg, { blueprint = bp_name })
				minetest.chat_send_player(player:get_player_name(), "Proposition creee. Le villageois demande validation.")
				forms.show_formspec(villager, "working_villages:experiments_blueprints", player:get_player_name())
				return
			end
		end
	end,
})

-- Build learned blueprint directly (near existing site or random)
forms.register_page("working_villages:build_blueprints", {
	requires_manage = true,
	constructor = function(self, villager, player_name)
		local inv_name = get_inv_name(villager)
		if not inv_name then
			return forms.form_base(10, 8, villager) ..
				"label[0.5,1;Erreur: villageois invalide]"
		end
		local formspec = forms.form_base(10, 8, villager)
		formspec = formspec .. "label[0.5,1;Construire un plan]"

		local all = blueprints.get_all()
		local list = {}
		for bp_name, bp in pairs(all) do
			if bp then
				local level = blueprints.get_level(inv_name, bp_name)
				if level > 0 or is_creative_test_mode() then
				local suffix = level > 0 and (" (Niveau " .. level .. ")") or " (non appris)"
				table.insert(list, {name = bp_name, label = (bp.description or bp_name) .. suffix})
				end
			end
		end
		table.sort(list, function(a, b) return a.label < b.label end)
		local labels = {}
		for _, entry in ipairs(list) do
			table.insert(labels, minetest.formspec_escape(entry.label))
		end
		villager.job_data = type(villager.job_data) == "table" and villager.job_data or {}
		villager.job_data.build_blueprint_list = list
		local selected_name = villager.job_data.selected_build_blueprint
		local selected_valid = false
		for _, entry in ipairs(list) do
			if entry.name == selected_name then
				selected_valid = true
				break
			end
		end
		if not selected_valid then
			villager.job_data.selected_build_blueprint = nil
		end
		formspec = formspec .. "textlist[0.5,1.6;9,4.5;build_list;" .. table.concat(labels, ",") .. "]"
		formspec = formspec .. "button[0.5,6.3;3.5,0.8;build_selected;Construire]"
		if is_creative_test_mode() then
			formspec = formspec .. "button[4.2,6.3;4.8,0.8;force_unlock;Forcer tous les plans (test)]"
		end
		formspec = formspec .. "button[0.5,7.3;2,1;back;Retour]"
		return formspec
	end,
	receiver = function(self, villager, player, fields)
		if fields.force_unlock then
			if not is_creative_test_mode() then
				send_error(player, "Action reservee au mode creative_test.")
				return
			end
			if not is_builder(villager) then
				send_error(player, "Action refusee : ce villageois n'est plus constructeur.")
				return
			end
			local inv_name = get_inv_name(villager)
			if not inv_name then
				send_error(player, "Villageois introuvable ou formulaire perime.")
				return
			end
			for bp_name, _ in pairs(blueprints.get_all()) do
				blueprints.force_teach(inv_name, bp_name)
			end
			minetest.chat_send_player(player:get_player_name(), "Plans forces pour le constructeur.")
			forms.show_formspec(villager, "working_villages:build_blueprints", player:get_player_name())
			return
		end
		if fields.back then
			forms.go_back(villager, player:get_player_name())
			return
		end
		local list = villager.job_data and villager.job_data.build_blueprint_list or nil
		local selected
		if fields.build_list then
			local evt, idx = fields.build_list:match("^(%u+):(%d+)$")
			if evt and idx then
				selected = tonumber(idx)
				local selected_entry = type(list) == "table" and list[selected] or nil
				villager.job_data = type(villager.job_data) == "table" and villager.job_data or {}
				villager.job_data.selected_build_blueprint = selected_entry and selected_entry.name or nil
				if evt == "DCL" then
					fields.build_selected = true
				end
			end
		end
		if fields.build_selected then
			if not is_builder(villager) then
				send_error(player, "Action refusee : ce villageois n'est plus constructeur.")
				return
			end
			local entry = type(list) == "table" and selected and list[selected] or nil
			local bp_name = type(entry) == "table" and entry.name or
				(villager.job_data and villager.job_data.selected_build_blueprint)
			if type(bp_name) ~= "string" or bp_name == "" or not blueprints.get(bp_name) then
				send_error(player, "Plan selectionne introuvable ou formulaire perime.")
				return
			end
			local inv_name = get_inv_name(villager)
			if not inv_name then
				send_error(player, "Villageois introuvable ou formulaire perime.")
				return
			end
			local level = blueprints.get_level(inv_name, bp_name)
			if level <= 0 then
				if not is_creative_test_mode() then
					send_error(player, "Ce plan n'est pas encore appris.")
					return
				end
				blueprints.force_teach(inv_name, bp_name)
			end
			local ok, msg = blueprint_construction.start_site(villager, bp_name)
			if ok then
				villager.job_data.learning_note = "Chantier lance: " .. bp_name
				minetest.chat_send_player(player:get_player_name(), msg)
			else
				minetest.chat_send_player(player:get_player_name(), "Echec: " .. (msg or ""))
			end
			return
		end
	end,
})

-- Add link from main menu to blueprints
forms.put_link("working_villages:talking_menu", "working_villages:blueprints_menu", "Plans")

-- Permissions menu (pending approvals)
forms.register_page("working_villages:permissions_menu", {
	requires_manage = true,
	constructor = function(self, villager, player_name)
		local formspec = forms.form_base(10, 7, villager)
		formspec = formspec .. "label[0.5,1;Autorisations en attente]"

		villager.job_data = type(villager.job_data) == "table" and villager.job_data or {}
		local requests = type(villager.job_data.permission_requests) == "table" and
			villager.job_data.permission_requests or {}
		local key_map = {}
		local y = 2
		local count = 0
		for key, req in pairs(requests) do
			if type(key) == "string" and type(req) == "table" and req.status == "pending" then
				count = count + 1
				local safe = tostring(count)
				key_map[safe] = key
				formspec = formspec .. "label[0.5," .. y .. ";" .. minetest.formspec_escape(req.message or key) .. "]"
				formspec = formspec .. "button[7.0," .. (y-0.2) .. ";1.3,0.8;perm_ok_" .. safe .. ";OK]"
				formspec = formspec .. "button[8.4," .. (y-0.2) .. ";1.3,0.8;perm_no_" .. safe .. ";Non]"
				y = y + 0.9
				if count >= 4 then
					break
				end
			end
		end
		villager.job_data.permission_key_map = key_map
		if count == 0 then
			formspec = formspec .. "label[0.5,2;Aucune autorisation en attente]"
		end
		formspec = formspec .. "button[0.5,6.2;2,1;back;Retour]"
		return formspec
	end,
	receiver = function(self, villager, player, fields)
		if fields.back then
			forms.go_back(villager, player:get_player_name())
			return
		end
		local map = villager.job_data and type(villager.job_data.permission_key_map) == "table" and
			villager.job_data.permission_key_map or {}
		for field_name, _ in pairs(fields) do
			local ok = type(field_name) == "string" and field_name:match("^perm_ok_(%d+)$") or nil
			local no = type(field_name) == "string" and field_name:match("^perm_no_(%d+)$") or nil
			if ok or no then
				local safe = ok or no
				local key = map[safe]
				local requests = type(villager.job_data) == "table" and
					type(villager.job_data.permission_requests) == "table" and
					villager.job_data.permission_requests or nil
				local request = type(requests) == "table" and key and requests[key] or nil
				if type(key) ~= "string" or type(request) ~= "table" or request.status ~= "pending" or
					not permissions.respond(villager, key, ok ~= nil) then
					send_error(player, "Autorisation introuvable ou deja traitee.")
					return
				end
				minetest.chat_send_player(player:get_player_name(), "Decision enregistree.")
				return
			end
		end
	end,
})

forms.put_link("working_villages:talking_menu", "working_villages:permissions_menu", "Autorisations")
