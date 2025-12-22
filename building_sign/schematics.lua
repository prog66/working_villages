--TODO: cleanup

local DEFAULT_NODE = building_sign.DEFAULT_NODE

local function resolve_alias(name)
	local alias = minetest.registered_aliases[name]
	if alias then
		return alias
	end
	return name
end

function building_sign.get_registered_nodename(name)
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

function building_sign.load_schematic(modpath,filename,pos)
	local meta = minetest.get_meta(pos)
	local input = io.open(modpath.."/schems/"..filename, "r")
	if not input then
		minetest.log("warning","schematic \""..modpath.."/schems/"..filename.."\" does not exist")
		return
	end
	local data = minetest.deserialize(input:read('*all'))
	io.close(input)
	if not data then
		minetest.log("warning","schematic \""..modpath.."/schems/"..filename.."\" is broken")
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

function building_sign.get_materials(nodelist)
	local materials = ""
	for _,el in pairs(nodelist) do
		materials = materials .. el.node.name .. ","
	end
	return materials:sub(1,#materials-1)
end

function building_sign.find_beds(nodedata) --TODO: save beds and use them
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
