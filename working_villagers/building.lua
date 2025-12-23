--TODO: replace with building_sign mod
local SCHEMS = {"simple_hut.we", "fancy_hut.we", "minimal_house.we", "minimal_shelter.we", "[custom house]"}
local DEFAULT_NODE = {name="air"}

local function out_of_limit(pos)
	if (pos.x>30927 or pos.x<-30912
	or  pos.y>30927 or pos.y<-30912
	or  pos.z>30927 or pos.z<-30912) then
		return true
	end
	return false
end

working_villages.building = (function()
	local file_name = minetest.get_worldpath() .. "/working_villages_building_sites"

	minetest.register_on_shutdown(function()
		local file = io.open(file_name, "w")
		file:write(minetest.serialize(working_villages.building))
		file:close()
	end)

	local file = io.open(file_name, "r")
	if file ~= nil then
		local data = file:read("*a")
		file:close()
		return minetest.deserialize(data)
	end
	return {}
end) ()

-- home is a prototype home object
working_villages.home = {
	update = {door = true, bed = true}
}

function working_villages.home:new(o)
	local new = setmetatable(o or {}, {__index = self})
	new.update = table.copy(self.update)
	return new
end

-- working_villages.homes represents a table that contains the villagers homes.
-- This table's keys are inventory names, and values are home objects.
working_villages.homes = (function()
	local file_name = minetest.get_worldpath() .. "/working_villages_homes"

	minetest.register_on_shutdown(function()
		local save_data = {}
		for k,v in pairs(working_villages.homes) do
			save_data[k]={marker=v.marker}
		end
		local file = io.open(file_name, "w")
		file:write(minetest.serialize(save_data))
		file:close()
	end)

	local file = io.open(file_name, "r")
	if file ~= nil then
		local data = file:read("*a")
		file:close()
		local load_data = minetest.deserialize(data)
		local home_data = {}
		for k,v in pairs(load_data) do
			home_data[k] = working_villages.home:new(v)
		end
		return home_data
	end
	return {}
end) ()

working_villages.buildings = {}

function working_villages.buildings.get(pos)
	local poshash = minetest.hash_node_position(pos)
	if working_villages.building[poshash] == nil then
		working_villages.building[poshash] = {}
	end
	return working_villages.building[poshash]
end

function working_villages.buildings.get_build_pos(meta)
	return minetest.string_to_pos(meta:get_string("build_pos"))
end

local function resolve_alias(name)
	local alias = minetest.registered_aliases[name]
	if alias then
		return alias
	end
	return name
end

function working_villages.buildings.get_registered_nodename(name)
	name = resolve_alias(name)
	if working_villages.voxelibre_compat.is_door(name) then
		-- Handle both minetest_game and VoxeLibre door formats
		name = name:gsub("_[b]_[12]", "")
		name = name:gsub("_[t]_[12]", "")
		name = name:gsub("_[a]", "")
		if string.find(name, "_t") or name:find("hidden") then
			name = "air"
		end
	elseif string.find(name, "stairs") then
		name = name:gsub("upside_down", "")
	elseif string.find(name, "farming") or string.find(name, "mcl_farming") then
		name = name:gsub("_%d", "")
	end
	if working_villages.voxelibre_compat.is_voxelibre then
		name = working_villages.voxelibre_compat.get_item(name)
	end
	name = resolve_alias(name)
	return name
end

function working_villages.buildings.load_schematic(filename,pos)
	local meta = minetest.get_meta(pos)
	local input = io.open(working_villages.modpath.."/schems/"..filename, "r")
	if not input then
		minetest.log("warning","schematic \""..working_villages.modpath.."/schems/"..filename.."\" does not exist")
		return
	end
	local data = minetest.deserialize(input:read('*all'))
	io.close(input)
	if not data then
		minetest.log("warning","schematic \""..working_villages.modpath.."/schems/"..filename.."\" is broken")
		return
	end
	table.sort(data, function(a,b)
		if a.y == b.y then
			if a.z == b.z then
				return a.x < b.x
			end
			return a.z < b.z
		end
		return a.y < b.y
	end)
	local nodedata = {}
	for i,v in ipairs(data) do --this is actually not nessecary
		if v.name and v.x and v.y and v.z then
			local node_name = v.name
			if working_villages.voxelibre_compat.is_voxelibre then
				node_name = working_villages.voxelibre_compat.get_item(node_name)
				local alias = minetest.registered_aliases[node_name]
				if alias then
					node_name = alias
				end
			end
			local node = {name=node_name, param1=v.param1, param2=v.param2}
			local npos = vector.add(working_villages.buildings.get_build_pos(meta), {x=v.x, y=v.y, z=v.z})
			local name = working_villages.buildings.get_registered_nodename(node_name)
			if minetest.registered_items[name]==nil then
				node = DEFAULT_NODE
			end
			nodedata[i] = {pos=npos, node=node}
		end
	end
	local buildpos = working_villages.buildings.get_build_pos(meta)
	local building = working_villages.buildings.get(buildpos)
	building.nodedata = nodedata
end

function working_villages.buildings.get_materials(nodelist)
	local materials = ""
	for _,el in pairs(nodelist) do
		materials = materials .. el.node.name .. ","
	end
	return materials:sub(1,#materials-1)
end

function working_villages.buildings.find_beds(nodedata) --TODO: save beds and use them
	local toplist = {}
	--local bottomlist = {}
	for id,el in pairs(nodedata) do
		if string.find(el.node.name,"bed") then
			if string.find(el.node.name, "_top") then
				table:insert(toplist,id,el)
			--elseif string.find(el.node.name, "_bottom")
			--	table.insert(bottomlist,id,el)
			end
		end
	end
	local bedlist = {}
	--FIXME: find bottoms fitting to tops
	for _,el in pairs(toplist) do
		local botpos = vector.add(el.pos, minetest.facedir_to_dir(el.param2))
		table.insert(bedlist, vector.divide(vector.add(el.pos, botpos), 2))
	end
	return bedlist
end

local function show_build_form(meta)
	local title = meta:get_string("schematic"):gsub("%.we","")
	local button_build
	if meta:get_string("state") == "planned" then
		button_build = "button_exit[5.0,1.0;3.0,0.5;build_start;Demarrer]"
	elseif meta:get_string("state") == "paused" then
		button_build = "button_exit[5.0,2.0;3.0,0.5;build_resume;Reprendre]"
	elseif meta:get_string("state") == "begun" then
		button_build = "button_exit[5.0,2.0;3.0,0.5;build_pause;Pause]"
	else
		button_build = "button_exit[5.0,2.0;3.0,0.5;build_update;Mettre a jour]"
	end
	local index = meta:get_int("index")
	local buildpos = working_villages.buildings.get_build_pos(meta)
	local building = working_villages.buildings.get(buildpos)
	local nodelist = building.nodedata
	if not nodelist then nodelist = {} end
	local formspec = "size[8,10]"
		.."label[3.0,0.0;Projet : "..title.."]"
		.."label[3.0,1.0;"..math.ceil(((index-1)/#nodelist)*100).."% termine]"
		.."textlist[0.0,2.0;4.0,3.5;inv_sel;"..working_villages.buildings.get_materials(nodelist)..";"..index..";]"
		..button_build
		.."button_exit[5.0,3.0;3.0,0.5;build_cancel;Annuler]"
	return formspec
end

working_villages.buildings.get_formspec = function(meta)
	local state = meta:get_string("state")
	if state == "unplanned" then
		local schemslist = {}
		for _,el in pairs(SCHEMS) do
			table.insert(schemslist,minetest.formspec_escape(el))
		end
		local schemlist = table.concat(schemslist, ",") or ""
		local formspec = "size[6,5]"
			.."textlist[0.0,0.0;5.0,4.0;schemlist;"..schemlist..";;]"
			.."button_exit[5.0,4.5;1.0,0.5;exit;fermer]"
		return formspec
	elseif state == "built" then
		local formspec = "size[5,5]"..
			"field[0.5,1;4,1;name;house label;${house_label}]"..
			"field[0.5,2;4,1;bed_pos;bed position;${bed}]"..
			"field[0.5,3;4,1;door_pos;position outside the house;${door}]"..
			"button_exit[1,4;2,1;assign_home;Ecrire]"
		return formspec
	elseif state == "planned" or state == "paused" or state == "begun" then
		return show_build_form(meta)
	end
end

local on_receive_fields = function(pos, _, fields, sender)
	local meta = minetest.get_meta(pos)
	local sender_name = sender:get_player_name()
	if minetest.is_protected(pos, sender_name) then
		minetest.record_protection_violation(pos, sender_name)
		return
	end
	if meta:get_string("owner") ~= sender_name then
		return
	end
	if fields.schemlist then
		local id = tonumber(string.match(fields.schemlist, "%d+"))
		if id then
			if SCHEMS[id] then
				meta:set_string("schematic",SCHEMS[id])
				if SCHEMS[id] == "[custom house]" then
					meta:set_string("state","built")
					meta:set_string("house_label", "house " .. minetest.pos_to_string(pos))
				else
					local bpos = { --TODO: mounted to the house
						x=math.ceil(pos.x) + 2,
						y=math.floor(pos.y),
						z=math.ceil(pos.z) + 2
					}
					meta:set_string("build_pos",minetest.pos_to_string(bpos))
					working_villages.buildings.load_schematic(meta:get_string("schematic"),pos)
					meta:set_int("index",0)
					meta:set_string("state","planned")
				end
			end
		end
	elseif fields.build_cancel then
		--reset_build()
		working_villages.buildings.get(working_villages.buildings.get_build_pos(meta)).nodedata = nil
		meta:set_string("schematic","")
		meta:set_int("index",0)
		meta:set_string("valid","false")
		meta:set_string("state","unplanned")
	elseif fields.build_start then
		local nodelist = working_villages.buildings.get(working_villages.buildings.get_build_pos(meta)).nodedata
		for _,v in ipairs(nodelist) do
			minetest.remove_node(v.pos)
			--FIXME: the villager ought to do this
		end
		meta:set_int("index",1)
		meta:set_string("state","paused")
	elseif fields.build_resume then
		meta:set_string("state","begun")
	elseif fields.build_pause then
		meta:set_string("state","paused")
	elseif fields.build_update then
		minetest.log("warning","The state of the building sign at "..minetest.pos_to_string(pos) .. " is unknown." )
		local paused = meta:get_string("paused")
		if paused == "true" then
			meta:set_string("state","paused")
		elseif paused == "false" then
			meta:set_string("state","begun")
		end
	elseif fields.assign_home then
		local house_label = fields.name
		if house_label == "" then
			house_label = "house " .. minetest.pos_to_string(pos)
		end
		meta:set_string("house_label", house_label)
		meta:set_string("infotext", house_label)
		meta:set_string("valid", "true")
		local coords = minetest.string_to_pos(fields.bed_pos)
		if coords == nil then
			-- fail on illegal input of coordinates
			minetest.chat_send_player(sender_name, 'Coordonnees invalides pour la position du lit. '..
				'Entrez X, Y et Z sous forme de liste separee par des virgules. '..
				'Exemple : "10,20,30" correspond a X=10, Y=20 et Z=30.')
			meta:set_string("valid", "false")
		elseif out_of_limit(coords) then
			minetest.chat_send_player(sender_name, 'Les coordonnees du lit sont hors limites. '..
				'Plage valide : -30912 a 30927 pour chaque axe.')
			meta:set_string("valid", "false")
		end
		meta:set_string("bed", fields.bed_pos)
		coords = minetest.string_to_pos(fields.door_pos)
		if coords == nil then
			-- fail on illegal input of coordinates
			minetest.chat_send_player(sender_name, 'Coordonnees invalides pour la position de la porte. '..
				'Entrez X, Y et Z sous forme de liste separee par des virgules. '..
				'Exemple : "10,20,30" correspond a X=10, Y=20 et Z=30.')
			meta:set_string("valid", "false")
		elseif out_of_limit(coords) then
			minetest.chat_send_player(sender_name, 'Les coordonnees de la porte sont hors limites. '..
				'Plage valide : -30912 a 30927 pour chaque axe.')
			meta:set_string("valid", "false")
		end
		meta:set_string("door", fields.door_pos)
		for _,home in pairs(working_villages.homes) do
			if vector.equals(home.marker, pos) then
				for k, v in pairs(working_villages.home.update) do
					home.update[k] = v
				end
				-- hard update of home object
				home:get_bed()
				home:get_door()
			end
		end
	end
	meta:set_string("formspec",working_villages.buildings.get_formspec(meta))
end

minetest.register_node("working_villages:building_marker", {
	description = "marqueur de construction pour working_villages",
	drawtype = "nodebox",
	tiles = {"default_sign_wall_wood.png"},
	inventory_image = "default_sign_wood.png",
	wield_image = "default_sign_wood.png",
	paramtype = "light",
	paramtype2 = "wallmounted",
	sunlight_propagates = true,
	is_ground_content = false,
	walkable = false,
	node_box = {
		type = "wallmounted",
		wall_top    = {-0.4375, 0.4375, -0.3125, 0.4375, 0.5, 0.3125},
		wall_bottom = {-0.4375, -0.5, -0.3125, 0.4375, -0.4375, 0.3125},
		wall_side   = {-0.5, -0.3125, -0.4375, -0.4375, 0.3125, 0.4375},
	},
	groups = {choppy = 2, dig_immediate = 2, attached_node = 1},
	sounds = working_villages.voxelibre_compat.node_sound_defaults(),
	after_place_node = function(pos, placer)
		local meta = minetest.get_meta(pos)
		local owner = placer:get_player_name()
		meta:set_string("owner", owner)
	end,
	on_construct = function(pos)
		local meta = minetest.get_meta(pos)
		meta:set_string("valid","false")
		meta:set_string("state","unplanned")
		meta:set_string("formspec",working_villages.buildings.get_formspec(meta))
	end,
	on_receive_fields = on_receive_fields,
	can_dig = function(pos, player)
		local pname = player:get_player_name()
		if minetest.is_protected(pos, pname) then
			minetest.record_protection_violation(pos, pname)
			return false
		end
		local meta = minetest.get_meta(pos)
		local owner = meta:get_string("owner")
		return pname == owner or pname == minetest.setting_get("name")
	end,
})

-- get the home of a villager
function working_villages.get_home(self)
	return working_villages.homes[self.inventory_name]
end

-- check whether a villager has a home
function working_villages.is_valid_home(self)
	local home = working_villages.get_home(self)
	if home == nil then
		return false
	end
	return true
end

-- get the position of the home_marker
function working_villages.home:get_marker()
	return self.marker
end

function working_villages.home:get_marker_meta()
	local home_marker_pos = self:get_marker()
	if minetest.get_node(home_marker_pos).name == "ignore" then
		minetest.get_voxel_manip():read_from_map(home_marker_pos, home_marker_pos)
		--minetest.emerge_area(home_marker_pos, home_marker_pos) --Doesn't work
	end
	if minetest.get_node(home_marker_pos).name ~= "working_villages:building_marker" then
		if working_villages.debug_logging and not(vector.equals(home_marker_pos,{x=0,y=0,z=0})) then
			minetest.log("warning", "The position of an non existant home was requested.")
			minetest.log("warning", "Position de maison donnee : " .. minetest.pos_to_string(home_marker_pos))
		end
		return false
	end
	local meta = minetest.get_meta(home_marker_pos)
	if meta:get_string("valid")~="true" then
		local owner = meta:get_string("owner")
		if owner == "" then
			minetest.log("warning", "Donnees demandees pour une maison non configuree.")
			minetest.log("warning", "Position de maison donnee : " .. minetest.pos_to_string(home_marker_pos))
		else
			minetest.chat_send_player(owner, "Donnees demandees pour une maison non configuree.")
			minetest.chat_send_player(owner, "Position de maison donnee : " .. minetest.pos_to_string(home_marker_pos))
		end
		return false
	end
	return meta
end

-- get the position that marks "outside"
function working_villages.home:get_door()
	if self.door~=nil and self.update.door == false then
		return self.door
	end
	local meta = self:get_marker_meta()
	if not meta then
		return false
	end
	local door_pos = meta:get_string("door")
	if not door_pos then
		if working_villages.debug_logging then
			local home_marker_pos = self:get_marker()
			minetest.log("warning", "The position outside the house was not entered for the home at:" ..
				minetest.pos_to_string(home_marker_pos))
		end
		return false
	end
	-- do a update without changing door table pointer if possible
	local door = minetest.string_to_pos(door_pos)
	if not self.door then
		self.door = door
	else
		self.door.x = door.x
		self.door.y = door.y
		self.door.z = door.z
	end
	self.update.door = false
	return self.door
end

-- get the bed of a villager
function working_villages.home:get_bed()
	if self.bed~=nil and self.update.bed == false then
		return self.bed
	end
	local meta = self:get_marker_meta()
	if not meta then
		return false
	end
	local bed_pos = meta:get_string("bed")
	if not bed_pos then
		if working_villages.debug_logging then
			local home_marker_pos = self:get_marker()
			minetest.log("warning", "The position of the bed was not entered for the home at:" ..
				minetest.pos_to_string(home_marker_pos))
		end
		return false
	end
	-- do a update without changing bed table pointer if possible
	local bed = minetest.string_to_pos(bed_pos)
	if not self.bed then
		self.bed = bed
	else
		self.bed.x = bed.x
		self.bed.y = bed.y
		self.bed.z = bed.z
	end
	self.update.bed = false
	return self.bed
end

-- set the home of a villager
function working_villages.set_home(self, marker_pos)
	local home = working_villages.home:new{marker = marker_pos}
	working_villages.homes[self.inventory_name] = home
	-- connect to home
	self.pos_data.bed_pos = home:get_bed()
	self.pos_data.door_pos = home:get_door()
end

-- remove the home of villager
function working_villages.remove_home(self)
	working_villages.homes[self.inventory_name] = nil
end
