--TODO: replace with building_sign mod
local SCHEMS = {"simple_hut.we", "fancy_hut.we", "minimal_house.we", "minimal_shelter.we", "[custom house]"}
local DEFAULT_NODE = {name="air"}
local village_registry = working_villages.village_registry
local sync_home_registry
local home_bed_occupant

-- Exposed on working_villages so blueprints.lua (loaded after this file)
-- reuses the exact same parser instead of keeping its own byte-identical
-- copy that a future fix could update in only one place.
local function parse_schematic_content(content)
	local data = minetest.deserialize(content)
	if data then
		return data
	end
	local chunk, err = loadstring(content)
	if not chunk then
		return nil, err
	end
	local ok, result = pcall(chunk)
	if ok and type(result) == "table" then
		return result
	end
	return nil, err
end
working_villages.parse_schematic_content = parse_schematic_content

local function out_of_limit(pos)
	if (pos.x>30927 or pos.x<-30912
	or  pos.y>30927 or pos.y<-30912
	or  pos.z>30927 or pos.z<-30912) then
		return true
	end
	return false
end

local state_storage = minetest.get_mod_storage()
local BUILDING_STATE_KEY = "building_sites_v2"
local HOME_STATE_KEY = "homes_v2"

local function read_legacy_table(file_name)
	local file = io.open(file_name, "r")
	if not file then
		return nil
	end
	local data = file:read("*a")
	file:close()
	local decoded = minetest.deserialize(data)
	return type(decoded) == "table" and decoded or nil
end

local function load_state_table(storage_key, legacy_file)
	local stored = state_storage:get_string(storage_key)
	if stored ~= "" then
		local decoded = minetest.deserialize(stored)
		if type(decoded) == "table" then
			return decoded
		end
		minetest.log("error", "[working_villages] Etat persistant illisible: " .. storage_key)
	end
	local legacy = read_legacy_table(legacy_file)
	if legacy then
		state_storage:set_string(storage_key, minetest.serialize(legacy))
		return legacy
	end
	return {}
end

working_villages.building = load_state_table(
	BUILDING_STATE_KEY,
	minetest.get_worldpath() .. "/working_villages_building_sites"
)

function working_villages.save_building_state()
	state_storage:set_string(BUILDING_STATE_KEY, minetest.serialize(working_villages.building))
end

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
working_villages.homes = {}
for inventory_name, data in pairs(load_state_table(
	HOME_STATE_KEY,
	minetest.get_worldpath() .. "/working_villages_homes"
)) do
	if type(inventory_name) == "string" and type(data) == "table" and data.marker then
		working_villages.homes[inventory_name] = working_villages.home:new({marker = data.marker})
	end
end

function working_villages.save_home_state()
	local save_data = {}
	for inventory_name, home in pairs(working_villages.homes) do
		if type(home) == "table" and home.marker then
			save_data[inventory_name] = {marker = home.marker}
		end
	end
	state_storage:set_string(HOME_STATE_KEY, minetest.serialize(save_data))
end

minetest.register_on_shutdown(function()
	working_villages.save_building_state()
	working_villages.save_home_state()
end)

working_villages.buildings = {}

function working_villages.buildings.get(pos)
	if not pos then
		return {}
	end
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

-- Door schematics store the concrete bottom/top nodes, while both supported
-- games give the builder a craftitem which places the complete two-node door.
-- Keep that relationship explicit so a door created by the bottom step also
-- satisfies the following schematic step instead of consuming a second item.
function working_villages.buildings.door_nodes_share_item(left_name, right_name)
	if type(left_name) ~= "string" or type(right_name) ~= "string" then
		return false
	end
	if not working_villages.voxelibre_compat.is_door(left_name)
			or not working_villages.voxelibre_compat.is_door(right_name) then
		return false
	end
	return working_villages.buildings.get_registered_nodename(left_name)
		== working_villages.buildings.get_registered_nodename(right_name)
end

function working_villages.buildings.node_matches_schematic(expected_name, actual_name)
	if expected_name == actual_name then
		return true
	end
	return working_villages.buildings.door_nodes_share_item(expected_name, actual_name)
end

function working_villages.buildings.door_pair_matches_item(item_name, bottom_name, top_name)
	if not working_villages.buildings.door_nodes_share_item(item_name, bottom_name) then
		return false
	end
	-- minetest_game uses the shared doors:hidden node for the upper half.
	if top_name == "doors:hidden" then
		return true
	end
	return working_villages.buildings.door_nodes_share_item(bottom_name, top_name)
end

function working_villages.buildings.load_schematic(filename,pos)
	local meta = minetest.get_meta(pos)
	local input = io.open(working_villages.modpath.."/schems/"..filename, "r")
	if not input then
		minetest.log("warning","schematic \""..working_villages.modpath.."/schems/"..filename.."\" does not exist")
		return
	end
	local content = input:read("*a")
	io.close(input)
	local data = parse_schematic_content(content)
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
	working_villages.save_building_state()
end

function working_villages.buildings.get_materials(nodelist)
	local materials = ""
	for _,el in pairs(nodelist) do
		materials = materials .. el.node.name .. ","
	end
	return materials:sub(1,#materials-1)
end

local function node_is_walkable(pos)
	local node = minetest.get_node_or_nil(pos)
	if not node then
		return false
	end
	local def = minetest.registered_nodes[node.name]
	return def and def.walkable == true or false
end

local function clear_pos(pos)
	local node = minetest.get_node_or_nil(pos)
	local above = minetest.get_node_or_nil(vector.add(pos, {x = 0, y = 1, z = 0}))
	if not node or not above then
		return false
	end
	local node_def = minetest.registered_nodes[node.name]
	local above_def = minetest.registered_nodes[above.name]
	return not ((node_def and node_def.walkable) or (above_def and above_def.walkable))
end

local function find_ground_below(position)
	local pos = vector.round(position)
	for _ = 1, 10 do
		pos.y = pos.y - 1
		if node_is_walkable(pos) then
			pos.y = pos.y + 1
			return pos
		end
	end
	return false
end

local function insert_unique_pos(list, seen, pos)
	if not pos then
		return
	end
	pos = vector.round(pos)
	local hash = minetest.hash_node_position(pos)
	if seen[hash] then
		return
	end
	seen[hash] = true
	table.insert(list, pos)
end

local function get_node_param2(entry)
	if entry.param2 ~= nil then
		return entry.param2
	end
	if entry.node and entry.node.param2 ~= nil then
		return entry.node.param2
	end
	return 0
end

local function bed_part(name)
	if type(name) ~= "string" or name == "" then
		return nil, nil
	end
	local compat = working_villages.voxelibre_compat
	local meta = compat.bed_meta and compat.bed_meta(name) or nil
	if meta and (meta.part == "top" or meta.part == "bottom") then
		return meta.part, meta
	end
	-- Custom beds must opt in explicitly.  A suffix alone is intentionally
	-- insufficient: flowers and many two-node decorations also end in
	-- _top/_bottom.
	local top_group = minetest.get_item_group(name, "villager_bed_top")
	local bottom_group = minetest.get_item_group(name, "villager_bed_bottom")
	if top_group > 0 and bottom_group == 0 then
		return "top", nil
	end
	if bottom_group > 0 and top_group == 0 then
		return "bottom", nil
	end
	return nil, nil
end

local function is_bed_top_node(name)
	return bed_part(name) == "top"
end

local function is_bed_bottom_node(name)
	return bed_part(name) == "bottom"
end

local function is_door_bottom_node(name)
	if not name or not working_villages.voxelibre_compat.is_door(name) then
		return false
	end
	if string.find(name, "hidden", 1, true) then
		return false
	end
	if string.find(name, "_t_", 1, true) or string.find(name, "_t$", 1) then
		return false
	end
	return true
end

local function bed_pair_at(pos)
	if type(pos) ~= "table" or pos.x == nil or pos.y == nil or pos.z == nil then
		return nil
	end
	local rounded = vector.round(pos)
	local node = rounded and minetest.get_node_or_nil(rounded) or nil
	if not node then
		return nil
	end
	local part = bed_part(node.name)
	if not part then
		return nil
	end
	local dir = minetest.facedir_to_dir(node.param2 or 0)
	if not dir or dir.y ~= 0 or (dir.x == 0 and dir.z == 0) then
		return nil
	end
	local bottom_pos = part == "bottom" and rounded or vector.subtract(rounded, dir)
	local top_pos = vector.add(bottom_pos, dir)
	local bottom_node = minetest.get_node_or_nil(bottom_pos)
	local top_node = minetest.get_node_or_nil(top_pos)
	if not bottom_node or not top_node then
		return nil
	end
	local bottom_part, bottom_meta = bed_part(bottom_node.name)
	local top_part, top_meta = bed_part(top_node.name)
	if bottom_part ~= "bottom" or top_part ~= "top"
			or (bottom_node.param2 or 0) ~= (top_node.param2 or 0) then
		return nil
	end
	-- Known game beds must also be a matching colour/type pair.  Explicitly
	-- grouped third-party beds remain supported when no pair metadata exists.
	if bottom_meta and bottom_meta.top and bottom_meta.top ~= top_node.name then
		return nil
	end
	if top_meta and top_meta.bottom and top_meta.bottom ~= bottom_node.name then
		return nil
	end
	return {
		bottom = vector.round(bottom_pos),
		top = vector.round(top_pos),
	}
end

local function canonical_bed_pos(pos)
	local pair = bed_pair_at(pos)
	return pair and pair.bottom or nil
end

local function door_exists_near(pos)
	if not pos then
		return false
	end
	pos = vector.round(pos)
	for dy = -1, 1 do
		for dx = -2, 2 do
			for dz = -2, 2 do
				local probe = {x = pos.x + dx, y = pos.y + dy, z = pos.z + dz}
				local node = minetest.get_node_or_nil(probe)
				if node and is_door_bottom_node(node.name) then
					return true
				end
			end
		end
	end
	return false
end

local function valid_home_access_pos(pos)
	if type(pos) ~= "table" or pos.x == nil or pos.y == nil or pos.z == nil
			or not clear_pos(pos) then
		return false
	end
	local below = vector.add(vector.round(pos), {x = 0, y = -1, z = 0})
	return node_is_walkable(below) and door_exists_near(pos)
end

local cardinal_offsets = {
	{x = 1, y = 0, z = 0},
	{x = -1, y = 0, z = 0},
	{x = 0, y = 0, z = 1},
	{x = 0, y = 0, z = -1},
}

local HOME_PATH_RADIUS = 64
local HOME_PATH_MAX_STEPS = 96
local HOME_PATH_MAX_VISITS = 8192
local HOME_VALIDATION_CACHE_SECONDS = 5

local function path_body_node_is_clear(node)
	if not node then
		return false
	end
	local def = minetest.registered_nodes[node.name]
	if not def then
		return false
	end
	if def.walkable ~= true then
		return true
	end
	-- Closed full-height doors are traversable by villagers because their
	-- movement code can operate doors.  Trapdoors are rejected by is_door.
	return working_villages.voxelibre_compat.is_door(node.name)
end

local function path_standable(pos)
	local foot = minetest.get_node_or_nil(pos)
	local head = minetest.get_node_or_nil(vector.add(pos, {x = 0, y = 1, z = 0}))
	local below = vector.add(pos, {x = 0, y = -1, z = 0})
	return path_body_node_is_clear(foot)
		and path_body_node_is_clear(head)
		and node_is_walkable(below)
end

local function path_crosses_door(pos)
	local foot = minetest.get_node_or_nil(pos)
	local head = minetest.get_node_or_nil(vector.add(pos, {x = 0, y = 1, z = 0}))
	return (foot and working_villages.voxelibre_compat.is_door(foot.name))
		or (head and working_villages.voxelibre_compat.is_door(head.name))
end

local function heap_push(heap, entry)
	local index = #heap + 1
	heap[index] = entry
	while index > 1 do
		local parent = math.floor(index / 2)
		if heap[parent].score <= entry.score then
			break
		end
		heap[index] = heap[parent]
		index = parent
		heap[index] = entry
	end
end

local function heap_pop(heap)
	local root = heap[1]
	local last = table.remove(heap)
	if #heap == 0 then
		return root
	end
	local index = 1
	heap[1] = last
	while true do
		local left = index * 2
		if left > #heap then
			break
		end
		local right = left + 1
		local child = right <= #heap and heap[right].score < heap[left].score and right or left
		if heap[index].score <= heap[child].score then
			break
		end
		heap[index], heap[child] = heap[child], heap[index]
		index = child
	end
	return root
end

local function home_path_exists(access_pos, bed_pos)
	local start = access_pos and vector.round(access_pos) or nil
	local pair = bed_pair_at(bed_pos)
	if not start or not pair or not path_standable(start)
			or vector.distance(start, pair.bottom) > HOME_PATH_RADIUS then
		return false
	end
	local goals = {}
	local goal_positions = {}
	for _, bed_half in ipairs({pair.bottom, pair.top}) do
		for _, offset in ipairs(cardinal_offsets) do
			local candidate = vector.add(bed_half, offset)
			if path_standable(candidate) then
				local hash = minetest.hash_node_position(candidate)
				if not goals[hash] then
					goals[hash] = true
					table.insert(goal_positions, candidate)
				end
			end
		end
	end
	if #goal_positions == 0 then
		return false
	end

	local function heuristic(pos)
		local best = math.huge
		for _, goal in ipairs(goal_positions) do
			local distance = math.abs(pos.x - goal.x) + math.abs(pos.y - goal.y)
				+ math.abs(pos.z - goal.z)
			best = math.min(best, distance)
		end
		return best
	end
	local function state_key(pos, crossed_door)
		-- tostring(hash_node_position()) switches to rounded scientific notation
		-- for large hashes and can collapse adjacent positions into one key.
		return pos.x .. "," .. pos.y .. "," .. pos.z .. (crossed_door and ":1" or ":0")
	end

	local open = {}
	local best_cost = {}
	local start_crossed = path_crosses_door(start) == true
	best_cost[state_key(start, start_crossed)] = 0
	heap_push(open, {
		pos = start,
		cost = 0,
		crossed_door = start_crossed,
		score = heuristic(start),
	})
	local min_y = math.min(start.y, pair.bottom.y) - 3
	local max_y = math.max(start.y, pair.bottom.y) + 3
	local visits = 0
	while #open > 0 and visits < HOME_PATH_MAX_VISITS do
		local current = heap_pop(open)
		visits = visits + 1
		local current_key = state_key(current.pos, current.crossed_door)
		if current.cost == best_cost[current_key] then
			if current.crossed_door and goals[minetest.hash_node_position(current.pos)] then
				return true
			end
			if current.cost < HOME_PATH_MAX_STEPS then
				for _, offset in ipairs(cardinal_offsets) do
					for _, dy in ipairs({0, 1, -1}) do
						local next_pos = {
							x = current.pos.x + offset.x,
							y = current.pos.y + dy,
							z = current.pos.z + offset.z,
						}
						if math.abs(next_pos.x - start.x) <= HOME_PATH_RADIUS
								and math.abs(next_pos.z - start.z) <= HOME_PATH_RADIUS
								and next_pos.y >= min_y and next_pos.y <= max_y
								and path_standable(next_pos) then
							local crossed = current.crossed_door or path_crosses_door(next_pos) == true
							local next_cost = current.cost + 1
							local key = state_key(next_pos, crossed)
							if best_cost[key] == nil or next_cost < best_cost[key] then
								best_cost[key] = next_cost
								heap_push(open, {
									pos = next_pos,
									cost = next_cost,
									crossed_door = crossed,
									score = next_cost + heuristic(next_pos),
								})
							end
						end
					end
				end
			end
		end
	end
	return false
end

local function validate_home_nodes(bed_pos, access_pos)
	local canonical = canonical_bed_pos(bed_pos)
	if not canonical then
		return false, "invalid_bed"
	end
	if not valid_home_access_pos(access_pos) then
		return false, "invalid_access"
	end
	if not home_path_exists(access_pos, canonical) then
		return false, "unreachable_bed"
	end
	return true, nil, canonical
end

working_villages.buildings.validate_home_nodes = validate_home_nodes

local function validate_home_cached(home)
	local bed_pos = home:get_bed()
	local access_pos = home:get_door()
	local function pos_key(pos)
		if type(pos) ~= "table" or pos.x == nil or pos.y == nil or pos.z == nil then
			return "nil"
		end
		return pos.x .. "," .. pos.y .. "," .. pos.z
	end
	local key = pos_key(bed_pos) .. ":" .. pos_key(access_pos)
	local now = minetest.get_gametime()
	local cached = home._node_validation_cache
	if cached and cached.key == key and now >= cached.checked_at
			and now - cached.checked_at <= HOME_VALIDATION_CACHE_SECONDS then
		return cached.valid, cached.reason, cached.bed_pos
	end
	local valid, reason, canonical = validate_home_nodes(bed_pos, access_pos)
	home._node_validation_cache = {
		key = key,
		checked_at = now,
		valid = valid,
		reason = reason,
		bed_pos = canonical,
	}
	return valid, reason, canonical
end

local function pick_best_access_pos(node_pos, reference_pos)
	local best_pos = nil
	local best_distance = nil
	for _, offset in ipairs(cardinal_offsets) do
		local probe = vector.add(node_pos, offset)
		if clear_pos(probe) then
			local access_pos = find_ground_below(probe) or probe
			if access_pos and access_pos ~= false and clear_pos(access_pos) then
				local distance = reference_pos and vector.distance(reference_pos, access_pos) or 0
				if not best_distance or distance < best_distance then
					best_distance = distance
					best_pos = access_pos
				end
			end
		end
	end
	return best_pos
end

function working_villages.buildings.find_beds(nodedata)
	local bedlist = {}
	local seen = {}
	for _, el in pairs(nodedata or {}) do
		local name = el.node and el.node.name or nil
		if is_bed_bottom_node(name) then
			insert_unique_pos(bedlist, seen, el.pos)
		end
	end
	if #bedlist > 0 then
		return bedlist
	end
	for _, el in pairs(nodedata or {}) do
		local name = el.node and el.node.name or nil
		if is_bed_top_node(name) then
			local dir = minetest.facedir_to_dir(get_node_param2(el))
			insert_unique_pos(bedlist, seen, vector.subtract(el.pos, dir))
		end
	end
	return bedlist
end

function working_villages.buildings.find_door_pos(nodedata, reference_pos)
	local best_pos = nil
	local best_distance = nil
	for _, el in pairs(nodedata or {}) do
		local name = el.node and el.node.name or nil
		local world_node = el.pos and minetest.get_node_or_nil(el.pos) or nil
		if is_door_bottom_node(name) and world_node and is_door_bottom_node(world_node.name) then
			local access_pos = pick_best_access_pos(el.pos, reference_pos)
			if access_pos then
				local distance = reference_pos and vector.distance(reference_pos, access_pos) or 0
				if not best_distance or distance < best_distance then
					best_distance = distance
					best_pos = vector.round(access_pos)
				end
			end
		end
	end
	return best_pos
end

local function refresh_home_cache(marker_pos)
	if not marker_pos then
		return
	end
	for _, home in pairs(working_villages.homes) do
		if vector.equals(home.marker, marker_pos) then
			home._node_validation_cache = nil
			for k, v in pairs(working_villages.home.update) do
				home.update[k] = v
			end
			home:get_bed()
			home:get_door()
		end
	end
end

function working_villages.buildings.autofill_home_metadata(meta, marker_pos)
	local build_pos = working_villages.buildings.get_build_pos(meta)
	local building = build_pos and working_villages.buildings.get(build_pos) or nil
	local nodedata = building and building.nodedata or nil
	if not nodedata then
		meta:set_string("bed", "")
		meta:set_string("door", "")
		meta:set_string("valid", "false")
		return false, false
	end

	local door_pos = working_villages.buildings.find_door_pos(nodedata, marker_pos or build_pos)
	if door_pos and not valid_home_access_pos(door_pos) then
		door_pos = nil
	end
	local bed_pos = nil
	if door_pos then
		for _, candidate in ipairs(working_villages.buildings.find_beds(nodedata)) do
			local valid, _, canonical = validate_home_nodes(candidate, door_pos)
			if valid then
				bed_pos = canonical
				break
			end
		end
	end

	meta:set_string("bed", bed_pos and minetest.pos_to_string(vector.round(bed_pos)) or "")
	meta:set_string("door", door_pos and minetest.pos_to_string(vector.round(door_pos)) or "")
	meta:set_string("valid", (bed_pos and door_pos) and "true" or "false")
	refresh_home_cache(marker_pos)
	return bed_pos ~= nil, door_pos ~= nil
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
	local total_nodes = math.max(#nodelist, 1)
	local completed = math.max(0, math.min(index - 1, #nodelist))
	local formspec = "size[8,10]"
		.."label[3.0,0.0;Projet : "..title.."]"
		.."label[3.0,1.0;"..math.ceil((completed / total_nodes) * 100).."% termine]"
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

local function sync_construction_site_registry(pos, remove)
	if not village_registry or not pos then
		return false
	end
	local meta = minetest.get_meta(pos)
	local owner_name = meta:get_string("owner")
	if owner_name == "" then
		return false
	end
	local village, ensure_error = village_registry.ensure(owner_name, {center = vector.round(pos)})
	if not village then
		minetest.log("warning", "[working_villages] Construction registry creation failed: " .. tostring(ensure_error))
		return false
	end
	local sites = village.construction_sites or {}
	local rounded_pos = vector.round(pos)
	local key = ("marker:%d:%d:%d"):format(rounded_pos.x, rounded_pos.y, rounded_pos.z)
	local state = meta:get_string("state")
	local entry = nil
	if not remove and state ~= "" and state ~= "unplanned" then
		entry = {
			id = key,
			marker = rounded_pos,
			build_pos = minetest.string_to_pos(meta:get_string("build_pos")),
			blueprint = working_villages.normalize_blueprint_name
				and working_villages.normalize_blueprint_name(meta:get_string("schematic"))
				or meta:get_string("schematic"),
			state = state,
			index = meta:get_int("index"),
		}
	end
	local migrated = false
	for previous_key, previous in pairs(sites) do
		local previous_pos = type(previous) == "table" and previous.marker or nil
		if previous_key ~= key and type(previous_pos) == "table" and
				previous_pos.x ~= nil and previous_pos.y ~= nil and previous_pos.z ~= nil and
				vector.equals(vector.round(previous_pos), rounded_pos) then
			sites[previous_key] = nil
			migrated = true
		end
	end
	if entry and not migrated and sites[key] and
			minetest.serialize(sites[key]) == minetest.serialize(entry) then
		return true
	end
	if not entry and not migrated and sites[key] == nil then
		return true
	end
	sites[key] = entry
	local updated, update_error = village_registry.update(owner_name, {construction_sites = sites})
	if not updated then
		minetest.log("warning", "[working_villages] Construction registry update failed: " .. tostring(update_error))
		return false
	end
	return true
end

working_villages.sync_construction_site_registry = sync_construction_site_registry

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
		local cancelled_build_pos = working_villages.buildings.get_build_pos(meta)
		if cancelled_build_pos then
			working_villages.buildings.get(cancelled_build_pos).nodedata = nil
		end
		working_villages.save_building_state()
		meta:set_string("schematic","")
		meta:set_int("index",0)
		meta:set_string("valid","false")
		meta:set_string("state","unplanned")
	elseif fields.build_start then
		local build_pos = working_villages.buildings.get_build_pos(meta)
		local building = build_pos and working_villages.buildings.get(build_pos) or nil
		local nodelist = building and building.nodedata or nil
		if not nodelist or #nodelist == 0 then
			minetest.chat_send_player(sender_name, "Impossible de demarrer : le plan du chantier est absent ou vide.")
			meta:set_string("state", "unplanned")
			meta:set_int("index", 0)
			meta:set_string("formspec", working_villages.buildings.get_formspec(meta))
			sync_construction_site_registry(pos)
			return
		end
		-- The builder clears obstructing nodes one by one through async_actions:dig.
		-- That path applies protection, tool, wear, drop and callback rules.
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
		local bed_pos = minetest.string_to_pos(fields.bed_pos or "")
		local access_pos = minetest.string_to_pos(fields.door_pos or "")
		local invalid_reason = nil
		local normalized_bed_pos = nil
		if not bed_pos or out_of_limit(bed_pos) then
			invalid_reason = "Coordonnees du lit invalides ou hors limites."
		elseif not access_pos or out_of_limit(access_pos) then
			invalid_reason = "Coordonnees de sortie invalides ou hors limites."
		elseif vector.distance(pos, bed_pos) > 64 or vector.distance(pos, access_pos) > 64 then
			invalid_reason = "Le lit et la sortie doivent rester a moins de 64 blocs du marqueur."
		elseif minetest.is_protected(bed_pos, sender_name) or minetest.is_protected(access_pos, sender_name) then
			invalid_reason = "Le lit ou la sortie se trouve dans une zone protegee."
		else
			local valid_nodes, validation_reason, canonical = validate_home_nodes(bed_pos, access_pos)
			normalized_bed_pos = canonical
			if not valid_nodes then
				if validation_reason == "invalid_bed" then
					invalid_reason = "Aucun lit complet et reel n'existe a la position indiquee."
				elseif validation_reason == "invalid_access" then
					invalid_reason = "La sortie doit etre libre, sur un sol praticable et proche d'une porte reelle."
				else
					invalid_reason = "Aucun chemin praticable passant par la porte ne relie la sortie au lit."
				end
			end
		end
		if invalid_reason then
			meta:set_string("valid", "false")
			minetest.chat_send_player(sender_name, invalid_reason)
			meta:set_string("formspec", working_villages.buildings.get_formspec(meta))
			sync_construction_site_registry(pos)
			return
		end
		local house_label = fields.name or ""
		if house_label == "" then
			house_label = "house " .. minetest.pos_to_string(pos)
		end
		meta:set_string("house_label", house_label)
		meta:set_string("infotext", house_label)
		meta:set_string("bed", minetest.pos_to_string(normalized_bed_pos))
		meta:set_string("door", minetest.pos_to_string(vector.round(access_pos)))
		meta:set_string("valid", "true")
		refresh_home_cache(pos)
	end
	meta:set_string("formspec",working_villages.buildings.get_formspec(meta))
	sync_construction_site_registry(pos)
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
		local owner = placer and placer.get_player_name and placer:get_player_name() or ""
		meta:set_string("owner", owner)
		sync_construction_site_registry(pos)
	end,
	on_destruct = function(pos)
		sync_construction_site_registry(pos, true)
	end,
	on_construct = function(pos)
		local meta = minetest.get_meta(pos)
		meta:set_string("valid","false")
		meta:set_string("state","unplanned")
		meta:set_string("formspec",working_villages.buildings.get_formspec(meta))
	end,
	on_receive_fields = on_receive_fields,
	can_dig = function(pos, player)
		local pname = player and player.get_player_name and player:get_player_name() or ""
		if pname == "" then
			return false
		end
		if minetest.is_protected(pos, pname) then
			minetest.record_protection_violation(pos, pname)
			return false
		end
		local meta = minetest.get_meta(pos)
		local owner = meta:get_string("owner")
		return working_villages.can_manage_owner(owner, player) == true
	end,
})

-- Construction sites created before the persistent village registry existed
-- have no registry entry until their mapblock is loaded.  Re-indexing on every
-- load also repairs metadata changed by an older release; the synchronizer is
-- idempotent and avoids a storage write when the entry is already current.
minetest.register_lbm({
	name = "working_villages:index_construction_markers_v1",
	nodenames = {"working_villages:building_marker"},
	run_at_every_load = true,
	action = function(pos)
		sync_construction_site_registry(pos)
	end,
})

local function is_invalid_site(meta, build_pos)
	if not meta then
		return false
	end
	local state = meta:get_string("state")
	if state ~= "planned" and state ~= "paused" and state ~= "begun" then
		return false
	end
	if not build_pos then
		return true
	end
	local building = working_villages.buildings.get(build_pos)
	local nodedata = building and building.nodedata or nil
	return (not nodedata) or (#nodedata == 0)
end

local function reset_site(meta, build_pos, marker_pos)
	if not meta then
		return
	end
	if build_pos then
		local building = working_villages.buildings.get(build_pos)
		if building then
			building.nodedata = nil
		end
	end
	working_villages.save_building_state()
	meta:set_string("schematic", "")
	meta:set_string("build_pos", "")
	meta:set_int("index", 0)
	meta:set_string("valid", "false")
	meta:set_string("state", "unplanned")
	meta:set_string("formspec", working_villages.buildings.get_formspec(meta))
	if marker_pos then
		sync_construction_site_registry(marker_pos)
	end
end

minetest.register_chatcommand("wv_building_cleanup", {
	params = "<radius> [apply]",
	description = "Liste ou reset les chantiers invalides autour de vous",
	privs = {server = true},
	func = function(name, param)
		local radius_str, apply_str = param:match("^%s*(%S+)%s*(%S*)")
		local radius = tonumber(radius_str or "")
		if not radius then
			return false, "Usage: /wv_building_cleanup <radius> [apply]"
		end
		local player = minetest.get_player_by_name(name)
		if not player then
			return false, "Joueur introuvable"
		end
		local apply = (apply_str == "apply")
		local center = vector.round(player:get_pos())
		local minp = vector.subtract(center, radius)
		local maxp = vector.add(center, radius)
		local markers = minetest.find_nodes_in_area(minp, maxp, {"working_villages:building_marker"})
		local invalid = {}
		for _, pos in ipairs(markers) do
			local meta = minetest.get_meta(pos)
			local build_pos = minetest.string_to_pos(meta:get_string("build_pos"))
			if is_invalid_site(meta, build_pos) then
				table.insert(invalid, {pos = pos, build_pos = build_pos})
				if apply then
					reset_site(meta, build_pos, pos)
				end
			end
		end
		if #invalid == 0 then
			return true, "Aucun chantier invalide trouve"
		end
		if apply then
			return true, "Chantiers invalides reinitialises: " .. #invalid
		end
		return true, "Chantiers invalides trouves: " .. #invalid .. " (relance avec 'apply' pour reset)"
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
	local meta = home:get_marker_meta()
	if not meta then
		return false
	end
	if self.owner_name and self.owner_name ~= "" and meta:get_string("owner") ~= self.owner_name then
		return false
	end
	local valid, _, bed_pos = validate_home_cached(home)
	if valid and home_bed_occupant
			and home_bed_occupant(bed_pos, self.inventory_name) then
		valid = false
	end
	if valid and sync_home_registry then
		local marker_hash = minetest.hash_node_position(home:get_marker())
		if self._village_registry_home_hash ~= marker_hash then
			sync_home_registry(self, home:get_marker())
			self._village_registry_home_hash = marker_hash
		end
	end
	return valid
end

-- get the position of the home_marker
function working_villages.home:get_marker()
	return self.marker
end

function working_villages.home:get_marker_meta()
	local home_marker_pos = self:get_marker()
	if type(home_marker_pos) ~= "table" or home_marker_pos.x == nil or
			home_marker_pos.y == nil or home_marker_pos.z == nil then
		return false
	end
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
		if working_villages.debug_logging then
			minetest.log("warning", "Donnees demandees pour une maison non configuree.")
			minetest.log("warning", "Position de maison donnee : " .. minetest.pos_to_string(home_marker_pos))
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
	if not door_pos or door_pos == "" then
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
	if not bed_pos or bed_pos == "" then
		if working_villages.debug_logging then
			local home_marker_pos = self:get_marker()
			minetest.log("warning", "The position of the bed was not entered for the home at:" ..
				minetest.pos_to_string(home_marker_pos))
		end
		return false
	end
	-- do a update without changing bed table pointer if possible
	local bed = canonical_bed_pos(minetest.string_to_pos(bed_pos))
	if not bed then
		return false
	end
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

local function home_occupant(marker_pos, except_inventory_name)
	for inventory_name, home in pairs(working_villages.homes) do
		if inventory_name ~= except_inventory_name and home.marker and vector.equals(home.marker, marker_pos) then
			return inventory_name
		end
	end
	return nil
end

home_bed_occupant = function(bed_pos, except_inventory_name)
	local canonical = canonical_bed_pos(bed_pos)
	if not canonical then
		return nil
	end
	for inventory_name, home in pairs(working_villages.homes) do
		if inventory_name ~= except_inventory_name and home and home.marker then
			local other_bed = canonical_bed_pos(home:get_bed())
			if other_bed and vector.equals(other_bed, canonical) then
				return inventory_name
			end
		end
	end
	return nil
end

function working_villages.is_home_available(marker_pos, owner_name, except_inventory_name)
	if not marker_pos or minetest.get_node(marker_pos).name ~= "working_villages:building_marker" then
		return false, "missing_marker"
	end
	local meta = minetest.get_meta(marker_pos)
	if meta:get_string("valid") ~= "true" then
		return false, "invalid_home"
	end
	if owner_name and owner_name ~= "" and meta:get_string("owner") ~= owner_name then
		return false, "wrong_owner"
	end
	local bed_pos = canonical_bed_pos(minetest.string_to_pos(meta:get_string("bed")))
	local door_pos = minetest.string_to_pos(meta:get_string("door"))
	local valid_nodes, validation_reason, canonical = validate_home_nodes(bed_pos, door_pos)
	if not valid_nodes then
		return false, validation_reason == "unreachable_bed" and "unreachable_bed" or "invalid_home_nodes"
	end
	if home_bed_occupant(canonical, except_inventory_name) then
		return false, "bed_occupied"
	end
	if home_occupant(marker_pos, except_inventory_name) then
		return false, "occupied"
	end
	return true
end

sync_home_registry = function(self, marker_pos)
	if not village_registry or not self or not self.inventory_name or not marker_pos then
		return false
	end
	local owner_name = self.owner_name or ""
	if owner_name == "" then
		return false
	end
	local meta = minetest.get_meta(marker_pos)
	local bed_pos = canonical_bed_pos(minetest.string_to_pos(meta:get_string("bed")))
	local door_pos = minetest.string_to_pos(meta:get_string("door"))
	local village, ensure_error = village_registry.ensure(owner_name, {center = vector.round(marker_pos)})
	if not village then
		minetest.log("warning", "[working_villages] Home registry creation failed: " .. tostring(ensure_error))
		return false
	end
	local home_entry = {
		inventory_name = self.inventory_name,
		marker = vector.round(marker_pos),
		bed = bed_pos and vector.round(bed_pos) or nil,
		door = door_pos and vector.round(door_pos) or nil,
	}
	local previous = village.homes and village.homes[self.inventory_name] or nil
	if previous and minetest.serialize(previous) == minetest.serialize(home_entry) then
		return true
	end
	local homes = village.homes or {}
	local beds = village.beds or {}
	homes[self.inventory_name] = home_entry
	beds[self.inventory_name] = home_entry.bed
	local updated, update_error = village_registry.update(owner_name, {homes = homes, beds = beds})
	if not updated then
		minetest.log("warning", "[working_villages] Home registry update failed: " .. tostring(update_error))
		return false
	end
	return true
end

working_villages.sync_home_registry = sync_home_registry

-- Set a real, unoccupied home belonging to the same village.
function working_villages.set_home(self, marker_pos)
	if not self or type(self.inventory_name) ~= "string" or self.inventory_name == "" then
		return false, "invalid_villager"
	end
	marker_pos = marker_pos and vector.round(marker_pos) or nil
	local available, reason = working_villages.is_home_available(
		marker_pos,
		self.owner_name or "",
		self.inventory_name
	)
	if not available then
		return false, reason
	end
	local home = working_villages.home:new({marker = marker_pos})
	working_villages.homes[self.inventory_name] = home
	self.pos_data = self.pos_data or {}
	self.pos_data.home_pos = home:get_door()
	self.pos_data.door_pos = self.pos_data.home_pos
	self.pos_data.bed_pos = home:get_bed()
	working_villages.save_home_state()
	sync_home_registry(self, marker_pos)
	self._village_registry_home_hash = minetest.hash_node_position(marker_pos)
	return true
end

-- remove the home of villager
function working_villages.remove_home(self)
	local inventory_name = self.inventory_name
	local owner_name = self.owner_name or ""
	working_villages.homes[self.inventory_name] = nil
	if self.pos_data then
		self.pos_data.home_pos = nil
		self.pos_data.door_pos = nil
		self.pos_data.bed_pos = nil
	end
	working_villages.save_home_state()
	self._village_registry_home_hash = nil
	if village_registry and owner_name ~= "" then
		local village = village_registry.get(owner_name)
		if village and ((village.homes and village.homes[inventory_name])
				or (village.beds and village.beds[inventory_name])) then
			local homes = village.homes or {}
			local beds = village.beds or {}
			homes[inventory_name] = nil
			beds[inventory_name] = nil
			local updated, update_error = village_registry.update(owner_name, {homes = homes, beds = beds})
			if not updated then
				minetest.log("warning", "[working_villages] Home registry removal failed: " .. tostring(update_error))
			end
		end
	end
end

function working_villages.claim_nearest_available_home(self, radius)
	if not self or not self.object or self:has_home() then
		return false
	end
	local center = self.object:get_pos()
	if not center then
		return false
	end
	local range = math.max(8, tonumber(radius) or 48)
	local markers = minetest.find_nodes_in_area(
		vector.subtract(center, range),
		vector.add(center, range),
		{"working_villages:building_marker"}
	)
	table.sort(markers, function(a, b)
		return vector.distance(center, a) < vector.distance(center, b)
	end)
	for _, marker_pos in ipairs(markers) do
		local available = working_villages.is_home_available(
			marker_pos,
			self.owner_name or "",
			self.inventory_name
		)
		if available then
			local ok = working_villages.set_home(self, marker_pos)
			if ok then
				self:set_state_info("J'ai trouve un logement libre.")
				self:set_displayed_action("s'installe")
				return true
			end
		end
	end
	return false
end

function working_villages.assign_home_to_nearest_homeless(owner_name, marker_pos)
	local candidates = {}
	for _, villager in pairs(minetest.luaentities or {}) do
		if villager and villager.name and working_villages.is_villager(villager.name)
				and (villager.owner_name or "") == (owner_name or "")
				and villager.object and villager.object:get_pos()
				and not villager:has_home() then
			table.insert(candidates, villager)
		end
	end
	table.sort(candidates, function(a, b)
		return vector.distance(a.object:get_pos(), marker_pos) < vector.distance(b.object:get_pos(), marker_pos)
	end)
	for _, villager in ipairs(candidates) do
		local ok = working_villages.set_home(villager, marker_pos)
		if ok then
			villager:set_state_info("Une nouvelle maison m'a ete attribuee.")
			villager:set_displayed_action("s'installe")
			return villager.inventory_name
		end
	end
	return nil
end
