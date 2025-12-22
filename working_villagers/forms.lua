local forms = {}
local registered_forms = {}
local log = working_villages.require("log")

forms.villagers = {}
function forms.get_villager(inv_name)
	return forms.villagers[inv_name]
end

forms.last_pages = {}

function forms.go_back(villager,player_name)
	if not villager or not villager.inventory_name then
		return
	end
	if not forms.last_pages[villager.inventory_name] then
		return
	end
	local last_page = forms.last_pages[villager.inventory_name].last
	forms.show_formspec(villager, last_page, player_name)
end

function forms.register_page(name, def)
	if registered_forms[name]~=nil then
		log.warning("overwriting formspec page %s",name)
	end
	assert(type(def.constructor)=="function")
	if def.receiver then assert(type(def.receiver)=="function") end
	if def.link_to then
		assert(type(def.link_to)=="table")
	else
		def.link_to = {}
	end
	if def.variables == nil then
		def.variables = {}
	end
	assert(type(def.variables)=="table")
	registered_forms[name] = def
end

function forms.put_link(source_page, target_page, description)
	assert(type(source_page)=="string")
	assert(type(target_page)=="string")
	assert(type(description)=="string")

	registered_forms[source_page].link_to[description] = target_page
end

function forms.show_formspec(villager, formname, playername)
	local page = registered_forms[formname]
	if page == nil then
		log.warning("page %s not registered", formname)
		page = registered_forms["working_villages:talking_menu"]
	end
	if not villager or not villager.inventory_name then
		local form = "size[8,3]" ..
			working_villages.voxelibre_compat.get_gui_bg() ..
			working_villages.voxelibre_compat.get_gui_bg_img() ..
			working_villages.voxelibre_compat.get_gui_slots() ..
			"label[0.5,0.8;Erreur: villageois introuvable]"
		minetest.show_formspec(playername, formname.."_invalid", form)
		return
	end
	minetest.show_formspec(playername, formname.."_"..villager.inventory_name, page:constructor(villager, playername))
	forms.villagers[villager.inventory_name] = villager

	if forms.last_pages[villager.inventory_name] == nil then
		forms.last_pages[villager.inventory_name] = {}
	end
	local last_page_store = forms.last_pages[villager.inventory_name]
	if last_page_store.current == nil then
		last_page_store.last = formname
	else
		last_page_store.last = last_page_store.current
	end
	last_page_store.current = formname
end

--receive fields when villager was rightclicked

minetest.register_on_player_receive_fields(
	function(player, formname, fields)
		for n,p in pairs(registered_forms) do
			if string.find(formname, n.."_")==1 then
				if p.receiver then
					local inv_name = string.sub(formname, string.len(n.."_")+1)
					p:receiver(forms.get_villager(inv_name),player,fields)
				end
			end
		end
	end
)

function forms.form_base(width,height,villager)
	local jobname
	local job_desc

	if villager then
		if type(villager.get_job) == "function" then
			local job_obj = villager:get_job()
			if job_obj and job_obj.description then
				job_desc = job_obj.description
			end
		elseif type(villager.get_job_name) == "function" then
			local job_name = villager:get_job_name()
			if job_name and working_villages.registered_jobs[job_name] then
				job_desc = working_villages.registered_jobs[job_name].description
			end
		end
	end
	if job_desc then
		jobname = job_desc
	else
		jobname = "aucun metier"
	end
	local villager_name = ""
	if villager and villager.nametag and villager.nametag~="" then
		villager_name = villager.nametag.." - "
	end

	return "size["..width..","..height.."]"
		.. working_villages.voxelibre_compat.get_gui_bg()
		.. working_villages.voxelibre_compat.get_gui_bg_img()
		.. working_villages.voxelibre_compat.get_gui_slots()
		.. "label[0,0;"..villager_name..jobname.."]"
end

function forms.register_menu_page(pageid, title)
	--TODO: conditional disabling buttons
	forms.register_page(pageid, {
		variables = {
			form_bottom = 9,
			title = title,
		},
		constructor = function(self,villager) --self, villager, playername
			local formbottom = self.variables.form_bottom
			local form = forms.form_base(8,formbottom,villager)
			local text = self.variables.title
			--TODO: random text from list
			form = form .. "label["..(4-(#text/10))..",1;"..text.."]"
			local y = 1
			for description, page_to in pairs(self.link_to) do
				y = y + 1
				form = form .. "button[0.5,"..y..";7,1;to_page-"..page_to..";"..minetest.formspec_escape(description).."]"
				if y >= formbottom-1 then
					log.warning("too many linked pages")
					--TODO: scroll down button
					break
				end
			end
			form = form .. "button_exit[3.5,"..(formbottom-1)..";1,1;exit;fermer]"
			return form
		end,
		receiver = function(_, villager, sender, fields) --self, villager, sender, fields
			local sender_name = sender:get_player_name()
			local button = next(fields)
			if button:find("to_page-")==1 then
				local page_to = button:sub(9)
				forms.show_formspec(villager, page_to, sender_name)
			end
		end,
	})
end

-- Maximum characters per line in the text widget
local TEXT_LINELENGTH = 80

-- Inserts automatic line breaks into an entire text and preserves existing newlines
local linebreaker = function(text, linelength)
	local out = ""
	for s in string.gmatch(text, "([^\n]*)") do
		local l = minetest.wrap_text(s, linelength)
		out = out .. l
		if(string.len(l) == 0) then
			out = out .. "\n"
		end
	end
	-- Remove last newline
	if string.len(out) >= 1 then
		out = string.sub(out, 1, string.len(out) - 1)
	end
	return out
end

-- Inserts text suitable for a textlist (including automatic word-wrap)
local text_for_textlist = function(text, linelength)
	if text == nil then return "" end
	text = linebreaker(text, linelength)
	text = minetest.formspec_escape(text)
	text = string.gsub(text, "\n", ",")
	return text
end

forms.text_widget = function(x, y, width, height, widget_id, data)
	local baselength = TEXT_LINELENGTH
	local widget_basewidth = 10
	local linelength = math.max(20, math.floor(baselength * (width / widget_basewidth)))

	-- TODO: Wait for Minetest to provide a native widget for scrollable read-only text with automatic line breaks.
	-- Currently, all of this had to be hacked into this script manually by using/abusing the table widget
	local formstring = "tablecolumns[text]"..
	"tableoptions[color=#ffffffff;background=#00000000;border=false;highlight=#00000000;highlight_text=#ffffffff]"..
	"table["..tostring(x)..","..tostring(y)..";"..tostring(width)..","..tostring(height)..
		";"..widget_id..";"..text_for_textlist(data, linelength).."]"
	return formstring
end

function forms.register_text_page(pageid,text_constructor)
	forms.register_page(pageid, {
		constructor = function(_, villager, playername)
			local form = forms.form_base(6,8,villager)

			local out_text = type(text_constructor)
			if out_text=="string" then
				out_text = text_constructor
			elseif out_text=="function" then
				out_text = text_constructor(villager, playername)
			else
				out_text = "invalid text_constructor type: " .. out_text
				log.error(out_text)
				out_text = "(error) " .. out_text
			end
			form = form .. forms.text_widget(0,1,6,6,"out_text",out_text)
			form = form .. "button[2.5,7;1,1;back;retour]"
			return form
		end,
		receiver = function(_,villager,sender,fields)
			if fields.back then
				local sender_name = sender:get_player_name()
				forms.go_back(villager,sender_name)
			end
		end,
	})
end

forms.register_page("working_villages:job_change",{
	constructor = function(_, villager) --self, villager, playername
		local villager_name = "Villageois"
		if villager.nametag and villager.nametag~="" then
			villager_name = villager.nametag
		end
		
		local current_job = "aucun"
		local job = villager:get_job()
		if job then
			current_job = job.description
		end
		
		return "size[8.5,7]"
			.. working_villages.voxelibre_compat.get_gui_bg()
			.. working_villages.voxelibre_compat.get_gui_bg_img()
			.. working_villages.voxelibre_compat.get_gui_slots()
			.. "label[0.2,0.2;" .. minetest.formspec_escape("=== Changement de métier: " .. villager_name .. " ===") .. "]"
			.. "label[0.2,0.7;" .. minetest.formspec_escape("Métier actuel: " .. current_job) .. "]"
			.. "label[3.5,1.3;Métier actuel:]"
			.. "list[detached:".. villager.inventory_name ..";job;3.75,1.6;1,1;]"
			.. "label[0.2,2.8;Métiers disponibles:]"
			.. "label[0.2,3.1;(Glissez un métier dans l'emplacement ci-dessus)]"
			.. "list[detached:working_villages:job_inv;main;0.2,3.5;8,3;]"
			.. "listring[]"
			.. "button[6.5,1.6;1.5,0.8;back;Retour]"
	end,
	receiver = function(_, villager, sender, fields)
		local sender_name = sender:get_player_name()
		if fields.back then
			forms.show_formspec(villager, "working_villages:inv_gui", sender_name)
			return
		end
	end
})

local function floor_pos(pos)
	pos.x = math.floor(pos.x)
	pos.y = math.floor(pos.y)
	pos.z = math.floor(pos.z)
	return pos
end
local function load_pos(pos, villager, nodes)
	if (pos=="near") then
		pos = minetest.find_node_near(villager.object:get_pos(), 5, nodes, true) or nil
	elseif (pos~="") then
		pos = minetest.string_to_pos(pos)
		if pos then
			pos = minetest.find_node_near(pos, 0.2, nodes, true) or nil
		end
	else
		pos = nil
	end
	return pos
end
local function soft_table_update(table_old, table_new)
	for k,v in pairs(table_new) do
		if type(v)=="table" then
			if table_old[k] then
				soft_table_update(table_old[k], table_new[k])
			else
				table_old[k] = v
			end
		else
			table_old[k] = v
		end
	end
	for k,_ in pairs(table_old) do
		if not table_new[k] then
			table_old[k] = nil
		end
	end
end

local function set_villager_home(sender_name, villager, marker_pos)
	if not (marker_pos.x and marker_pos.y and marker_pos.z) then
		-- fail on illegal input of coordinates
		minetest.chat_send_player(sender_name, 'Coordonnees invalides pour la position de la maison. '..
			'Entrez X, Y et Z sous forme de liste separee par des virgules. '..
			'Exemple : "10,20,30" correspond a X=10, Y=20 et Z=30.')
		return
	end
	if(marker_pos.x>30927 or marker_pos.x<-30912 or marker_pos.y>30927 or marker_pos.y<-30912 or marker_pos.z>30927 or marker_pos.z<-30912) then
		minetest.chat_send_player(sender_name, "Les coordonnees de la maison sont hors limites. "..
			"Plage valide : -30912 a 30927 pour chaque axe.")
		return
	end
	if minetest.get_node(marker_pos).name ~= "working_villages:building_marker" then
		minetest.chat_send_player(sender_name, "Aucun marqueur de maison a cette position.")
		return
	end

	villager:set_home(marker_pos)
	minetest.chat_send_player(sender_name, "Marqueur de maison defini.")
	if minetest.get_meta(marker_pos):get_string("valid") == "false" then
		minetest.chat_send_player(sender_name, "Marqueur non configure, "..
			"clic droit pour le configurer.")
	end
end

local change_index = 0

forms.register_page("working_villages:data_change",{
	constructor = function(_, villager, player_name) --self, villager, playername
		-- villager data
		local data = villager.pos_data
		-- references
		local villager_pos = minetest.pos_to_string(floor_pos(villager.object:get_pos()))
		local player = minetest.get_player_by_name(player_name)
		local player_pos = villager_pos
		if player then
			player_pos = minetest.pos_to_string(floor_pos(player:get_pos()))
		end
		-- type set
		local marker_pos = ""
		if villager:has_home() then
			local home = villager:get_home()
			marker_pos = minetest.pos_to_string(floor_pos(home:get_marker()))
		end
		local villager_name = ""
		if villager.nametag and villager.nametag~="" then
			villager_name = villager.nametag
		end
		local village_name = ""
		if villager.village_name then
			village_name = villager.village_name
		end
		-- villager positions
		local home_pos = ""
		if (data.home_pos~=nil) then
			home_pos = minetest.pos_to_string(data.home_pos)
		end
		local bed_pos = ""
		if (data.bed_pos~=nil) then
			bed_pos = minetest.pos_to_string(data.bed_pos)
		end
		local chest_pos = ""
		if (data.chest_pos~=nil) then
			chest_pos = minetest.pos_to_string(data.chest_pos)
		end
		-- village positions
		local food_pos = ""
		if (data.food_pos~=nil) then
			food_pos = minetest.pos_to_string(data.food_pos)
		end
		local tools_pos = ""
		if (data.tools_pos~=nil) then
			tools_pos = minetest.pos_to_string(data.tools_pos)
		end
		local storage_pos = ""
		if (data.storage_pos~=nil) then
			storage_pos = minetest.pos_to_string(data.storage_pos)
		end
		-- job positon
		local job_pos = ""
		if (data.job_pos~=nil) then
			job_pos = minetest.pos_to_string(data.job_pos)
		end

		change_index = change_index + 1
		return "size[8.5,8]"
			.. working_villages.voxelibre_compat.get_gui_bg()
			.. working_villages.voxelibre_compat.get_gui_bg_img()
			.. working_villages.voxelibre_compat.get_gui_slots()
			.. "label[0.2,0.2;" .. minetest.formspec_escape("=== Paramètres: " .. (villager_name ~= "" and villager_name or "Villageois") .. " ===") .. "]"
			.. "label[-1,-1;"..change_index.."]"
			-- Identity section
			.. "label[0.2,0.8;Identité:]"
			.. "field[0.2,1.3;2.5,0.8;villager_name;Nom du villageois;" .. minetest.formspec_escape(villager_name) .. "]"
			.. "field[3,1.3;2.5,0.8;village_name;Village;" .. minetest.formspec_escape(village_name) .. "]"
			-- Position reference
			.. "label[0.2,2.1;Positions de référence:]"
			.. "field[0.2,2.6;2.5,0.8;villager_pos;Position villageois;" .. minetest.formspec_escape(player_pos) .. "]"
			.. "field[3,2.6;2.5,0.8;player_pos;Position joueur;" .. minetest.formspec_escape(villager_pos) .. "]"
			.. "field[5.7,2.6;2.5,0.8;marker_pos;Marqueur maison;" .. minetest.formspec_escape(marker_pos) .. "]"
			.. "tooltip[marker_pos;Position du marqueur de construction de maison]"
			-- Home positions
			.. "label[0.2,3.5;Positions de la maison:]"
			.. "field[0.2,4;2.5,0.8;home_pos;Porte;" .. minetest.formspec_escape(home_pos) .. "]"
			.. "tooltip[home_pos;Porte d'entrée (\"near\" pour auto-détection)]"
			.. "field[3,4;2.5,0.8;bed_pos;Lit;" .. minetest.formspec_escape(bed_pos) .. "]"
			.. "tooltip[bed_pos;Position du lit (\"near\" pour auto-détection)]"
			.. "field[5.7,4;2.5,0.8;chest_pos;Coffre personnel;" .. minetest.formspec_escape(chest_pos) .. "]"
			.. "tooltip[chest_pos;Coffre personnel (\"near\" pour auto-détection)]"
			-- Village positions
			.. "label[0.2,4.9;Positions du village:]"
			.. "field[0.2,5.4;2.5,0.8;food_pos;Nourriture;" .. minetest.formspec_escape(food_pos) .. "]"
			.. "tooltip[food_pos;Coffre de nourriture partagé]"
			.. "field[3,5.4;2.5,0.8;tools_pos;Outils;" .. minetest.formspec_escape(tools_pos) .. "]"
			.. "tooltip[tools_pos;Coffre d'outils partagé]"
			.. "field[5.7,5.4;2.5,0.8;storage_pos;Stockage;" .. minetest.formspec_escape(storage_pos) .. "]"
			.. "tooltip[storage_pos;Coffre de stockage partagé]"
			-- Job position
			.. "label[0.2,6.3;Poste de travail:]"
			.. "field[0.2,6.8;2.5,0.8;job_pos;Position métier;" .. minetest.formspec_escape(job_pos) .. "]"
			.. "tooltip[job_pos;Position où le villageois exerce son métier]"
			-- Buttons
			.. "button[3.5,7.2;1.5,0.8;set_data;Valider]"
			.. "button[5.5,7.2;1.5,0.8;back;Retour]"
	end,
	--receiver = function(page, villager, sender, fields)
	receiver = function(_, villager, sender, fields)
		local sender_name = sender:get_player_name()
		if fields.set_data then
			local data = {}
			local marker_pos = load_pos(fields.marker_pos, villager, "working_villages:building_marker")
			--data.home_pos = load_pos(fields.home_pos, villager, "group:door")
			data.home_pos = load_pos(fields.home_pos, villager, "group:villager_door")
			data.bed_pos = load_pos(fields.bed_pos, villager, "group:villager_bed_bottom")
			data.chest_pos = load_pos(fields.chest_pos, villager, "group:villager_chest")
			data.food_pos = load_pos(fields.food_pos, villager, "group:villager_chest")
			data.tools_pos = load_pos(fields.tools_pos, villager, "group:villager_chest")
			data.storage_pos = load_pos(fields.storage_pos, villager, "group:villager_chest")
			if fields.job_pos then
				data.job_pos = minetest.string_to_pos(fields.job_pos)
			end

			-- soft update have to be done here, do not break pointers
			soft_table_update(villager.pos_data, data)
			-- marked pos update
			if marker_pos then
				local home = villager:get_home()
				if (not home) or (not vector.equals(home:get_marker(), marker_pos)) then
					set_villager_home(sender_name, villager, marker_pos)
				end
			else
				if villager:has_home() then
					villager:remove_home()
				end
			end
			-- villager name update
			if fields.villager_name ~= villager.nametag then
				villager.nametag = fields.villager_name
				villager.object:set_nametag_attributes({
						text = villager.nametag
					})
			end
			-- village connect update
			if fields.village_name ~= villager.village_name then
				villager.village_name = fields.village_name
				-- TODO: Add some connection data update function here?
			end
			forms.show_formspec(villager, "working_villages:data_change", sender_name)
		end
		if fields.back then
			forms.show_formspec(villager, "working_villages:inv_gui", sender_name)
			return
		end
	end
})

forms.register_page("working_villages:inv_gui", {
	constructor = function(_, villager) --self, villager, playername
		-- Header information
		local villager_name = "Villageois"
		if villager.nametag and villager.nametag~="" then
			villager_name = villager.nametag
		end
		
		local jobname = villager:get_job()
		if jobname then
			jobname = jobname.description
		else
			jobname = "aucun metier"
		end
		
		local village_info = ""
		if villager.village_name and villager.village_name ~= "" then
			village_info = " - Village: " .. villager.village_name
		end
		
		return "size[9,10]"
			.. working_villages.voxelibre_compat.get_gui_bg()
			.. working_villages.voxelibre_compat.get_gui_bg_img()
			.. working_villages.voxelibre_compat.get_gui_slots()
			-- Header section
			.. "label[0.2,0.2;" .. minetest.formspec_escape("=== " .. villager_name .. " ===") .. "]"
			.. "label[0.2,0.6;" .. minetest.formspec_escape("Métier: " .. jobname .. village_info) .. "]"
			-- Main inventory section
			.. "label[0.2,1.2;Inventaire du villageois:]"
			.. "list[detached:"..villager.inventory_name..";main;0.2,1.5;4,4;]"
			-- Wield item section
			.. "label[4.5,1.2;Outil équipé:]"
			.. "list[detached:"..villager.inventory_name..";wield_item;4.5,1.5;1,1;]"
			-- Armor section with cleaner layout
			.. "label[6.2,1.2;Équipement:]"
			.. "label[6.2,1.6;Casque:]"
			.. "list[detached:"..villager.inventory_name..";head;7,1.5;1,1;]"
			.. "label[6.2,2.6;Plastron:]"
			.. "list[detached:"..villager.inventory_name..";torso;7,2.5;1,1;]"
			.. "label[6.2,3.6;Jambières:]"
			.. "list[detached:"..villager.inventory_name..";legs;7,3.5;1,1;]"
			.. "label[6.2,4.6;Bottes:]"
			.. "list[detached:"..villager.inventory_name..";feet;7,4.5;1,1;]"
			-- Player inventory
			.. "label[0.2,5.7;Votre inventaire:]"
			.. "list[current_player;main;0.2,6;8,1;]"
			.. "list[current_player;main;0.2,7.2;8,3;8]"
			-- Listring for item transfer
			.. "listring[detached:"..villager.inventory_name..";main]"
			.. "listring[detached:"..villager.inventory_name..";head]"
			.. "listring[detached:"..villager.inventory_name..";torso]"
			.. "listring[detached:"..villager.inventory_name..";legs]"
			.. "listring[detached:"..villager.inventory_name..";feet]"
			.. "listring[current_player;main]"
			-- Action buttons at the bottom
			.. "button[4.5,2.8;2,0.8;job;Changer métier]"
			.. "button[4.5,3.8;2,0.8;data;Paramètres]"
			.. "button_exit[4.5,4.8;2,0.8;ok;Fermer]"
	end,
	receiver = function(_, villager, sender, fields)
		local sender_name = sender:get_player_name()
		if fields.job then
			forms.show_formspec(villager, "working_villages:job_change", sender_name)
			return
		end
		if fields.data then
			forms.show_formspec(villager, "working_villages:data_change", sender_name)
			return
		end
	end,
})

--TODO: see if working_villages.registered_forms should really be public
working_villages.regisered_forms = registered_forms

return forms
