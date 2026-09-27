local forms = working_villages.require("forms")
working_villages.access = working_villages.access or working_villages.require("access")
local BLACKSMITH_JOB_NAME = "working_villages:job_blacksmith"
local LEARNER_JOB_NAME = working_villages.LEARNER_JOB_NAME or "working_villages:job_apprenant"

local function villager_has_job(villager, expected_job_name)
	if not villager or type(villager.get_job_name) ~= "function" then
		return false
	end
	return villager:get_job_name() == expected_job_name
end

forms.register_menu_page("working_villages:talking_menu", "bonjour")

forms.register_text_page("working_villages:job_desc",
	function(villager)
		local job = villager:get_job()
		if not job then
			return "Je n'ai pas de metier."
		end
		return job.long_description or "quelque chose..."
end)

forms.put_link("working_villages:talking_menu", "working_villages:job_desc",
	"Que fais-tu dans ton metier ?")

forms.register_text_page("working_villages:state",
  function(villager)
    return villager.state_info
end)

forms.put_link("working_villages:talking_menu", "working_villages:state",
  "Que fais-tu en ce moment ?")

forms.register_page("working_villages:blacksmith_orders", {
	constructor = function(_, villager)
		local form = forms.form_base(8, 7.5, villager)
		if not villager_has_job(villager, BLACKSMITH_JOB_NAME) then
			return form .. "label[0.5,1.6;Je ne suis pas forgeron.]"
		end
		local catalog = (working_villages.blacksmith and working_villages.blacksmith.get_catalog) and
			working_villages.blacksmith.get_catalog() or {}
		local labels = {}
		for _, entry in ipairs(catalog) do
			table.insert(labels, minetest.formspec_escape(entry.label))
		end
		local list = table.concat(labels, ",")
		local selected = 1
		if villager and villager.job_data and villager.job_data.blacksmith_order_index then
			selected = villager.job_data.blacksmith_order_index
		end
		form = form
			.. "label[0.5,1.4;Commande d'outil/arme]"
			.. "textlist[0.5,2.0;7,3;order_list;"..list..";"..selected..";]"
			.. "field[0.5,5.4;2,0.8;order_count;Qt;1]"
			.. "button[2.8,5.2;2.0,0.8;order_make;Commander]"
			.. "button[5.1,5.2;2.0,0.8;order_back;Retour]"
		return form
	end,
	receiver = function(_, villager, sender, fields)
		if not villager or not sender then
			return
		end
		local sender_name = sender:get_player_name()
		if fields.order_back then
			forms.go_back(villager, sender_name)
			return
		end
		if not working_villages.can_manage_villager(villager, sender) then
			if fields.order_list or fields.order_make then
				minetest.chat_send_player(sender_name, "Vous ne pouvez pas commander ce villageois.")
			end
			return
		end
		if fields.order_list then
			local idx = tonumber(fields.order_list:match(":(%d+)$") or fields.order_list)
			if idx then
				villager.job_data = villager.job_data or {}
				villager.job_data.blacksmith_order_index = idx
			end
		end
		if fields.order_make then
			local catalog = (working_villages.blacksmith and working_villages.blacksmith.get_catalog) and
				working_villages.blacksmith.get_catalog() or {}
			local idx = (villager.job_data and villager.job_data.blacksmith_order_index) or 1
			local entry = catalog[idx]
			if entry and working_villages.blacksmith and working_villages.blacksmith.enqueue_order then
				working_villages.blacksmith.enqueue_order(
					villager, entry.key, tonumber(fields.order_count) or 1, sender_name
				)
			end
		end
	end,
})

forms.put_link("working_villages:talking_menu", "working_villages:blacksmith_orders",
	"Commander un outil/arme")

-- Add learning mode specific dialogue
forms.register_text_page("working_villages:learning_status",
	function(villager)
		if not villager_has_job(villager, LEARNER_JOB_NAME) then
			return "Je ne suis pas en mode apprentissage actuellement."
		end
		
		local messages = {
			"J'explore le monde et j'apprends de nouvelles choses chaque jour.",
			"Je parle avec les autres villageois pour comprendre comment fonctionne notre village.",
			"J'essaie différentes activités pour voir ce que je pourrais faire.",
			"Je cherche encore ma voie. Peut-être avez-vous un métier pour moi ?",
		}
		return messages[math.random(#messages)]
	end)

forms.put_link("working_villages:talking_menu", "working_villages:learning_status",
	"Que penses-tu de l'apprentissage ?")

-- Add encouragement option for learners
forms.register_text_page("working_villages:encouragement",
	function(villager)
		if not villager_has_job(villager, LEARNER_JOB_NAME) then
			return "Merci pour l'encouragement !"
		end
		return "Merci beaucoup ! Vos encouragements m'aident à apprendre. " ..
			"Un jour, j'espère devenir aussi compétent que les autres villageois !"
	end)

forms.put_link("working_villages:talking_menu", "working_villages:encouragement",
	"Continue d'apprendre, c'est bien !")

local focus_button_actions = {
	focus_balanced = "balanced",
	focus_food = "food",
	focus_defense = "defense",
	focus_housing = "housing",
	focus_industry = "industry",
	focus_exploration = "exploration",
}

local notify_button_actions = {
	notify_important = "important",
	notify_detailed = "detailed",
	notify_silent = "silent",
}

local build_button_actions = {
	build_none = "",
	build_farm = "farm_plot",
	build_house = "simple_house",
	build_tower = "watchtower",
	build_workshop = "workshop",
	build_forge = "blacksmith_forge",
}

local build_labels = {
	[""] = "aucun",
	farm_plot = "champ",
	simple_house = "maison simple",
	watchtower = "tour de guet",
	workshop = "atelier",
	blacksmith_forge = "forge",
}

local function get_control(villager)
	if working_villages.get_owner_village_control then
		return working_villages.get_owner_village_control(villager.owner_name)
	end
	return {
		focus = "balanced",
		notify_level = "important",
		next_build = "",
	}
end

local function describe_build_order(name)
	local normalized = working_villages.normalize_blueprint_name and working_villages.normalize_blueprint_name(name) or (name or "")
	return build_labels[normalized] or normalized
end

local village_dashboard_selection = {}

local function get_inv_name(villager)
	if not villager then
		return nil
	end
	if type(villager.get_inventory_name) == "function" then
		local inv_name = villager:get_inventory_name()
		if inv_name and inv_name ~= "" then
			return inv_name
		end
	end
	if type(villager.inventory_name) == "string" and villager.inventory_name ~= "" then
		return villager.inventory_name
	end
	return nil
end

local function get_village_label(villager)
	if villager and villager.village_name and villager.village_name ~= "" then
		return villager.village_name
	end
	return "village du proprietaire"
end

local function simplify_job_label(label)
	label = tostring(label or "")
	label = label:gsub("%s*%b()$", "")
	label = label:match("^%s*(.-)%s*$") or ""
	if label == "" then
		return "aucun metier"
	end
	return label
end

local function get_job_label(villager)
	if not villager or type(villager.get_job) ~= "function" then
		return "aucun metier"
	end
	local job = villager:get_job()
	if not job or not job.description then
		return "aucun metier"
	end
	return simplify_job_label(job.description)
end

local function get_villager_label(villager)
	if villager and villager.nametag and villager.nametag ~= "" then
		return villager.nametag
	end
	return get_inv_name(villager) or "Villageois"
end

local function normalize_inline_text(text)
	text = tostring(text or "")
	text = text:gsub("[\r\n]+", " / ")
	text = text:gsub("%s+", " ")
	return text:match("^%s*(.-)%s*$") or ""
end

local function truncate_text(text, limit)
	text = normalize_inline_text(text)
	if #text <= limit then
		return text
	end
	if limit <= 3 then
		return text:sub(1, limit)
	end
	return text:sub(1, limit - 3) .. "..."
end

local function describe_pause_reason(villager)
	if not villager or not villager.pause then
		return nil
	end
	local reason = villager.job_data and villager.job_data.pause_reason or nil
	if reason == "manual" then
		return "pause manuelle"
	end
	if reason == "auto" then
		return "pause auto"
	end
	if reason == "error" then
		return "metier bloque"
	end
	return "en pause"
end

local function get_action_label(villager)
	local action = normalize_inline_text(villager and villager.disp_action or "")
	if action == "" then
		action = "inactif"
	end
	local pause_reason = describe_pause_reason(villager)
	if pause_reason then
		action = action .. " (" .. pause_reason .. ")"
	end
	return action
end

local function same_village(anchor, candidate)
	if not anchor or not candidate then
		return false
	end
	if (anchor.owner_name or "") ~= (candidate.owner_name or "") then
		return false
	end
	local anchor_village = anchor.village_name or ""
	local candidate_village = candidate.village_name or ""
	if anchor_village ~= "" and candidate_village ~= "" then
		return anchor_village == candidate_village
	end
	return true
end

local function list_village_villagers(anchor)
	local villagers = {}
	for _, lua in pairs(minetest.luaentities or {}) do
		if lua and lua.name and working_villages.is_villager(lua.name) and same_village(anchor, lua) then
			table.insert(villagers, lua)
		end
	end
	table.sort(villagers, function(left, right)
		local left_name = string.lower(get_villager_label(left))
		local right_name = string.lower(get_villager_label(right))
		if left_name ~= right_name then
			return left_name < right_name
		end
		return get_job_label(left) < get_job_label(right)
	end)
	return villagers
end

local function clamp_selection(index, size)
	if size <= 0 then
		return 0
	end
	index = tonumber(index) or 1
	if index < 1 then
		return 1
	end
	if index > size then
		return size
	end
	return index
end

local function get_dashboard_selection(anchor, player_name, villagers)
	local player_key = player_name or "_"
	local anchor_key = get_inv_name(anchor) or "_"
	village_dashboard_selection[player_key] = village_dashboard_selection[player_key] or {}
	local selected = clamp_selection(village_dashboard_selection[player_key][anchor_key], #villagers)
	if selected == 0 and #villagers > 0 then
		selected = 1
	end
	village_dashboard_selection[player_key][anchor_key] = selected
	return selected
end

local function set_dashboard_selection(anchor, player_name, index, villagers)
	local player_key = player_name or "_"
	local anchor_key = get_inv_name(anchor) or "_"
	village_dashboard_selection[player_key] = village_dashboard_selection[player_key] or {}
	village_dashboard_selection[player_key][anchor_key] = clamp_selection(index, #villagers)
	return village_dashboard_selection[player_key][anchor_key]
end

local function get_selected_villager(anchor, player_name, villagers)
	local index = get_dashboard_selection(anchor, player_name, villagers)
	return villagers[index], index
end

local function count_pending_permissions(villager)
	local pending = 0
	local requests = villager and villager.job_data and villager.job_data.permission_requests or nil
	if type(requests) ~= "table" then
		return pending
	end
	for _, request in pairs(requests) do
		if type(request) == "table" and request.status == "pending" then
			pending = pending + 1
		end
	end
	return pending
end

local function format_position_line(label, pos)
	if not pos then
		return nil
	end
	return label .. ": " .. minetest.pos_to_string(vector.round(pos), 0)
end

local function build_villager_detail_text(villager, reveal_positions)
	if not villager then
		return "Aucun villageois charge pour ce village."
	end

	local lines = {
		"Nom: " .. get_villager_label(villager),
		"Metier: " .. get_job_label(villager),
		"Action: " .. get_action_label(villager),
	}

	local state_text = normalize_inline_text(villager.state_info)
	if state_text == "" then
		state_text = "aucune information detaillee"
	end
	table.insert(lines, "Etat: " .. state_text)

	local inbox_count = villager.job_data and villager.job_data.inbox and #villager.job_data.inbox or 0
	if inbox_count > 0 then
		table.insert(lines, "Messages recus: " .. inbox_count)
	end

	local pending_permissions = count_pending_permissions(villager)
	if pending_permissions > 0 then
		table.insert(lines, "Demandes en attente: " .. pending_permissions)
	end

	-- Exact chest/home coordinates are only shown to owners/managers: any
	-- viewer could otherwise right-click a stranger's wandering villager and
	-- read the precise location of that village's chest and houses.
	if reveal_positions then
		local pos_data = villager.pos_data or {}
		local job_pos_line = format_position_line("Poste", pos_data.job_pos)
		if job_pos_line then
			table.insert(lines, job_pos_line)
		end
		local storage_line = format_position_line("Coffre", pos_data.storage_pos)
		if storage_line then
			table.insert(lines, storage_line)
		end

		if villager.has_home and villager.get_home and villager:has_home() then
			local home = villager:get_home()
			local home_pos = home and home.get_pos and home:get_pos() or nil
			local home_line = format_position_line("Maison", home_pos)
			if home_line then
				table.insert(lines, home_line)
			end
		end
	end

	return table.concat(lines, "\n")
end

local function build_villager_list(villagers)
	local entries = {}
	for _, member in ipairs(villagers) do
		local line = string.format(
			"%s | %s | %s",
			truncate_text(get_villager_label(member), 16),
			truncate_text(get_job_label(member), 16),
			truncate_text(get_action_label(member), 20)
		)
		table.insert(entries, minetest.formspec_escape(line))
	end
	return table.concat(entries, ",")
end

local function village_resource_line(status)
	status = status or {}
	return string.format(
		"Ressources : nourriture %d | bois %d | minerais %d | outils %d",
		status.available_food or status.food or 0,
		status.available_wood or status.wood or 0,
		status.available_ore or status.ore or 0,
		status.available_tools or status.tools or 0
	)
end

local function count_active_village_tasks(owner_name)
	local collab = working_villages.collaborative_tasks
	if not collab or type(collab.list) ~= "function" then
		return 0
	end
	return #collab.list(owner_name, "active")
end

forms.register_page("working_villages:village_dashboard", {
	constructor = function(_, villager, player_name)
		local status = working_villages.get_village_status and working_villages.get_village_status(villager, 50) or nil
		local villagers = list_village_villagers(villager)
		local selected_villager, selected_index = get_selected_villager(villager, player_name, villagers)
		local control = status and status.control or get_control(villager)
		local can_manage = working_villages.can_manage_villager(villager, player_name)
		local bootstrap_stage = status and (status.bootstrap_stage or working_villages.get_village_bootstrap_stage(status)) or "build"
		local bootstrap_label = working_villages.describe_bootstrap_stage(bootstrap_stage)
		local storage_label = (status and status.shared_storage_ready) and "pret" or "a installer"
		local access_label = can_manage and "gestion" or "lecture seule"
		local population = status and status.population or #villagers
		local population_limit = math.max(5,
			tonumber(minetest.settings:get("working_villages_population_limit")) or 20)
		local homeless = status and status.homeless or 0
		local active_sites = status and status.active_sites or 0
		local houses = status and status.houses or 0
		local active_tasks = count_active_village_tasks(villager.owner_name)
		local mode = working_villages.gameplay_mode or "survival"
		local selected_name = selected_villager and get_villager_label(selected_villager) or "Aucun villageois selectionne"
		local selected_details = build_villager_detail_text(selected_villager, can_manage)

		local form = forms.form_base(12, 10.4, villager)
		form = form
			.. "label[0.4,1.25;Tableau du village : " .. minetest.formspec_escape(get_village_label(villager)) .. "]"
			.. "label[0.4,1.7;Priorite : " .. minetest.formspec_escape(working_villages.describe_village_focus(control.focus))
				.. " | Phase : " .. minetest.formspec_escape(bootstrap_label)
				.. " | Coffre : " .. minetest.formspec_escape(storage_label)
				.. " | Mode : " .. minetest.formspec_escape(mode)
				.. " | Acces : " .. minetest.formspec_escape(access_label) .. "]"
			.. "label[0.4,2.15;Population : " .. population .. "/" .. population_limit
				.. " | Sans-abri : " .. homeless
				.. " | Chantiers : " .. active_sites
				.. " | Maisons : " .. houses .. "]"
			.. "label[0.4,2.6;" .. minetest.formspec_escape(village_resource_line(status)) .. "]"
			.. "label[0.4,3.0;Danger : " .. (status and status.recent_danger or 0)
				.. " | Taches collaboratives : " .. active_tasks .. "]"
			.. "label[0.4,3.4;Villageois charges]"
			.. "label[6.0,3.4;" .. minetest.formspec_escape(truncate_text(selected_name, 38)) .. "]"
			.. "textlist[0.4,3.75;5.2,4.7;dashboard_villagers;" .. build_villager_list(villagers) .. ";" .. selected_index .. ";]"
			.. forms.text_widget(6.0, 3.75, 5.6, 4.7, "dashboard_details", selected_details)
			.. "button[0.4,8.75;1.8,0.8;dashboard_refresh;Actualiser]"
			.. "button[2.35,8.75;1.9,0.8;dashboard_open;Voir menu]"
			.. "button[4.4,8.75;1.2,0.8;back;Retour]"
			.. "button[6.0,8.75;1.6,0.8;dashboard_report;Rapport]"
			.. "button[7.8,8.75;1.6,0.8;dashboard_orders;Ordres]"
			.. "button[9.6,8.75;2.0,0.8;dashboard_coord;Mode IA]"

		return form
	end,
	receiver = function(_, villager, sender, fields)
		if not villager or not sender then
			return
		end

		local sender_name = sender:get_player_name()
		local villagers = list_village_villagers(villager)
		local selected_villager = get_selected_villager(villager, sender_name, villagers)

		if fields.dashboard_villagers then
			local selected_index = tonumber(fields.dashboard_villagers:match(":(%d+)$") or fields.dashboard_villagers)
			if selected_index then
				set_dashboard_selection(villager, sender_name, selected_index, villagers)
			end
			forms.show_formspec(villager, "working_villages:village_dashboard", sender_name)
			return
		end

		if fields.dashboard_refresh then
			forms.show_formspec(villager, "working_villages:village_dashboard", sender_name)
			return
		end

		if fields.dashboard_open then
			local target = selected_villager or villager
			forms.show_formspec(target, "working_villages:talking_menu", sender_name)
			return
		end

		if fields.dashboard_report then
			forms.show_formspec(villager, "working_villages:village_report", sender_name)
			return
		end

		if fields.dashboard_orders then
			forms.show_formspec(villager, "working_villages:village_orders", sender_name)
			return
		end

		if fields.dashboard_coord then
			if not working_villages.can_manage_villager(villager, sender_name) then
				minetest.chat_send_player(sender_name, "Seul le proprietaire peut relancer la coordination du village.")
				return
			end
			if not working_villages.activate_village_coordination then
				minetest.chat_send_player(sender_name, "Coordination intelligente indisponible.")
				return
			end
			local result = working_villages.activate_village_coordination(villager)
			if not result then
				minetest.chat_send_player(sender_name, "Impossible de relancer la coordination du village.")
				return
			end
			minetest.chat_send_player(
				sender_name,
				("Coordination relancee: priorite %s, phase %s, %d villageois relances.")
					:format(
						working_villages.describe_village_focus(result.control.focus),
						result.stage_label or working_villages.describe_bootstrap_stage(result.stage),
						result.nudged or 0
					)
			)
			forms.show_formspec(villager, "working_villages:village_dashboard", sender_name)
			return
		end

		if fields.back then
			forms.go_back(villager, sender_name)
		end
	end,
})

local function village_report_text(villager)
	if not working_villages.get_village_status then
		return "Rapport du village indisponible."
	end

	local status = working_villages.get_village_status(villager, 50)
	if not status then
		return "Rapport du village indisponible."
	end

	local control = status.control or get_control(villager)
	local counts = status.counts or {}
	local bootstrap_stage = status.bootstrap_stage or working_villages.get_village_bootstrap_stage(status)
	local bootstrap_label = working_villages.describe_bootstrap_stage(bootstrap_stage)
	local storage_label = status.shared_storage_ready and "pret" or "a installer"
	local village_name = (villager.village_name and villager.village_name ~= "") and villager.village_name or "village du proprietaire"
	local population_limit = math.max(5,
		tonumber(minetest.settings:get("working_villages_population_limit")) or 20)
	local active_tasks = count_active_village_tasks(villager.owner_name)
	local lines = {
		"Village: " .. village_name,
		"Mode: " .. (working_villages.gameplay_mode or "survival"),
		"Priorite: " .. working_villages.describe_village_focus(control.focus),
		"Suivi: " .. working_villages.describe_notification_level(control.notify_level),
		"Prochain chantier force: " .. describe_build_order(control.next_build),
		"Phase bootstrap: " .. bootstrap_label,
		"Coffre commun: " .. storage_label,
		"",
		("Population: %d / %d"):format(status.population or 0, population_limit),
		("Sans-abri: %d"):format(status.homeless or 0),
		("Danger recent: %d"):format(status.recent_danger or 0),
		("Taches collaboratives actives: %d"):format(active_tasks),
		("Chantiers actifs: %d"):format(status.active_sites or 0),
		("Maisons connues: %d"):format(status.houses or 0),
		"",
		("Nourriture: %d (total: %d)"):format(status.food or 0, status.available_food or status.food or 0),
		("Nourriture crue: %d (total: %d)"):format(status.raw_food or 0, status.available_raw_food or status.raw_food or 0),
		("Bois: %d (total: %d)"):format(status.wood or 0, status.available_wood or status.wood or 0),
		("Minerais: %d (total: %d)"):format(status.ore or 0, status.available_ore or status.ore or 0),
		("Outils: %d (total: %d)"):format(status.tools or 0, status.available_tools or status.tools or 0),
		"",
		"Metiers:",
		("- Fermiers: %d"):format(counts["working_villages:job_farmer"] or 0),
		("- Bucherons: %d"):format(counts["working_villages:job_woodcutter"] or 0),
		("- Mineurs: %d"):format(counts["working_villages:job_miner"] or 0),
		("- Cuisiniers: %d"):format(counts["working_villages:job_cook"] or 0),
		("- Forgerons: %d"):format(counts["working_villages:job_blacksmith"] or 0),
		("- Constructeurs: %d"):format(counts["working_villages:job_builder"] or 0),
		("- Gardes: %d"):format(counts["working_villages:job_guard"] or 0),
		("- Autonomes: %d"):format(counts["working_villages:job_autonome"] or 0),
	}

	return table.concat(lines, "\n")
end

forms.register_text_page("working_villages:village_report",
	function(villager)
		return village_report_text(villager)
	end)

forms.register_page("working_villages:village_orders", {
	constructor = function(_, villager, player_name)
		local control = get_control(villager)
		local can_manage = working_villages.can_manage_villager(villager, player_name)
		local status = working_villages.get_village_status and working_villages.get_village_status(villager, 50) or nil
		local bootstrap_stage = status and (status.bootstrap_stage or working_villages.get_village_bootstrap_stage(status)) or "build"
		local bootstrap_label = working_villages.describe_bootstrap_stage(bootstrap_stage)
		local storage_label = (status and status.shared_storage_ready) and "pret" or "a installer"
		local form = forms.form_base(10, 9.7, villager)
		form = form
			.. "label[0.4,1.25;Priorite actuelle : " .. minetest.formspec_escape(working_villages.describe_village_focus(control.focus)) .. "]"
			.. "label[0.4,1.7;Suivi actuel : " .. minetest.formspec_escape(working_villages.describe_notification_level(control.notify_level)) .. "]"
			.. "label[0.4,2.15;Prochain chantier : " .. minetest.formspec_escape(describe_build_order(control.next_build)) .. "]"
			.. "label[0.4,2.6;Phase bootstrap : " .. minetest.formspec_escape(bootstrap_label) .. " | Coffre commun : " .. minetest.formspec_escape(storage_label) .. "]"
			.. "label[0.4,3.15;Priorite strategique]"
			.. "button[0.4,3.55;1.35,0.8;focus_balanced;Equilibre]"
			.. "button[1.85,3.55;1.35,0.8;focus_food;Nourriture]"
			.. "button[3.3,3.55;1.35,0.8;focus_defense;Defense]"
			.. "button[4.75,3.55;1.35,0.8;focus_housing;Logement]"
			.. "button[6.2,3.55;1.55,0.8;focus_industry;Production]"
			.. "button[7.85,3.55;1.55,0.8;focus_exploration;Explorer]"
			.. "label[0.4,4.55;Niveau d'informations]"
			.. "button[0.4,4.95;2.2,0.8;notify_important;Importantes]"
			.. "button[2.8,4.95;2.2,0.8;notify_detailed;Detaillees]"
			.. "button[5.2,4.95;2.2,0.8;notify_silent;Silence]"
			.. "label[0.4,5.85;Ordre de chantier]"
			.. "button[0.4,6.25;1.6,0.8;build_none;Aucun]"
			.. "button[2.1,6.25;1.6,0.8;build_farm;Champ]"
			.. "button[3.8,6.25;2.1,0.8;build_house;Maison]"
			.. "button[6.1,6.25;2.8,0.8;build_tower;Tour de guet]"
			.. "button[0.4,7.15;2.1,0.8;build_workshop;Atelier]"
			.. "button[2.7,7.15;2.1,0.8;build_forge;Forge]"
			.. "button[5.8,8.5;1.6,0.8;back;Retour]"
			.. "button[7.6,8.5;1.8,0.8;report;Rapport]"

		if not can_manage then
			form = form .. "label[0.4,8.1;Lecture seule : seul le proprietaire peut modifier ces ordres.]"
		end

		return form
	end,
	receiver = function(_, villager, sender, fields)
		if not villager or not sender then
			return
		end

		local sender_name = sender:get_player_name()
		if fields.back then
			forms.go_back(villager, sender_name)
			return
		end
		if fields.report then
			forms.show_formspec(villager, "working_villages:village_report", sender_name)
			return
		end

		local can_manage = working_villages.can_manage_villager(villager, sender_name)
		if not can_manage then
			for field_name in pairs(focus_button_actions) do
				if fields[field_name] then
					minetest.chat_send_player(sender_name, "Seul le proprietaire peut modifier la strategie du village.")
					return
				end
			end
			for field_name in pairs(notify_button_actions) do
				if fields[field_name] then
					minetest.chat_send_player(sender_name, "Seul le proprietaire peut modifier le suivi du village.")
					return
				end
			end
			for field_name in pairs(build_button_actions) do
				if fields[field_name] then
					minetest.chat_send_player(sender_name, "Seul le proprietaire peut donner un ordre de chantier.")
					return
				end
			end
			return
		end

		for field_name, focus in pairs(focus_button_actions) do
			if fields[field_name] then
				working_villages.set_owner_village_control(villager.owner_name, {focus = focus})
				villager:set_state_info("J'applique votre priorite strategique.")
				minetest.chat_send_player(sender_name,
					"Priorite du village definie sur : " .. working_villages.describe_village_focus(focus))
				forms.show_formspec(villager, "working_villages:village_orders", sender_name)
				return
			end
		end

		for field_name, notify_level in pairs(notify_button_actions) do
			if fields[field_name] then
				working_villages.set_owner_village_control(villager.owner_name, {notify_level = notify_level})
				villager:set_state_info("Je vais adapter mes retours au joueur.")
				minetest.chat_send_player(sender_name,
					"Suivi du village regle sur : " .. working_villages.describe_notification_level(notify_level))
				forms.show_formspec(villager, "working_villages:village_orders", sender_name)
				return
			end
		end

		for field_name, blueprint_name in pairs(build_button_actions) do
			if fields[field_name] then
				working_villages.set_owner_village_control(villager.owner_name, {next_build = blueprint_name})
				villager:set_state_info("J'ai bien note votre ordre de chantier.")
				minetest.chat_send_player(sender_name,
					"Ordre de chantier memorise : " .. describe_build_order(blueprint_name))
				forms.show_formspec(villager, "working_villages:village_orders", sender_name)
				return
			end
		end
	end,
})

forms.put_link("working_villages:talking_menu", "working_villages:village_dashboard",
	"Tableau du village")

forms.put_link("working_villages:talking_menu", "working_villages:village_report",
	"Rapport du village")

forms.put_link("working_villages:talking_menu", "working_villages:village_orders",
	"Ordres du village")
