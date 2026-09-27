-- Deterministic construction planning and public-server site validation.

local planner = {}

local function copy_pos(pos)
	return {x = pos.x, y = pos.y, z = pos.z}
end

local function copy_entry(entry)
	local result = {}
	for key, value in pairs(entry or {}) do
		result[key] = value
	end
	if entry and entry.pos then
		result.pos = copy_pos(entry.pos)
	end
	if entry and entry.node then
		result.node = {}
		for key, value in pairs(entry.node) do
			result.node[key] = value
		end
	end
	return result
end

local function position_key(pos)
	return table.concat({pos.x, pos.y, pos.z}, ":")
end

function planner.get_bounds(nodes)
	local minp
	local maxp
	for _, entry in ipairs(nodes or {}) do
		local pos = entry and entry.pos
		if pos then
			if not minp then
				minp = copy_pos(pos)
				maxp = copy_pos(pos)
			else
				minp.x = math.min(minp.x, pos.x)
				minp.y = math.min(minp.y, pos.y)
				minp.z = math.min(minp.z, pos.z)
				maxp.x = math.max(maxp.x, pos.x)
				maxp.y = math.max(maxp.y, pos.y)
				maxp.z = math.max(maxp.z, pos.z)
			end
		end
	end
	return minp, maxp
end

local function node_group(name, group)
	if minetest and type(minetest.get_item_group) == "function" then
		return tonumber(minetest.get_item_group(name, group)) or 0
	end
	return 0
end

local function construction_phase(name)
	if name == "air" then
		return 0
	end
	local lower = tostring(name or ""):lower()
	if node_group(name, "attached_node") > 0 or node_group(name, "torch") > 0
			or lower:find("torch", 1, true) or lower:find("door", 1, true)
			or lower:find("bed_top", 1, true) or lower:find("hidden", 1, true) then
		return 2
	end
	return 1
end

-- Produce one complete, stable plan. Missing cells inside the schematic bounds
-- become explicit air cells so site validation also protects the interior.
function planner.prepare_nodes(nodes, fill_air)
	local by_position = {}
	for _, entry in ipairs(nodes or {}) do
		if entry and entry.pos and entry.node and entry.node.name then
			by_position[position_key(entry.pos)] = copy_entry(entry)
		end
	end

	local compact = {}
	for _, entry in pairs(by_position) do
		compact[#compact + 1] = entry
	end
	local minp, maxp = planner.get_bounds(compact)
	if fill_air ~= false and minp and maxp then
		for x = minp.x, maxp.x do
			for y = minp.y, maxp.y do
				for z = minp.z, maxp.z do
					local pos = {x = x, y = y, z = z}
					local key = position_key(pos)
					if not by_position[key] then
						local entry = {pos = pos, node = {name = "air", param1 = 0, param2 = 0}}
						by_position[key] = entry
						compact[#compact + 1] = entry
					end
				end
			end
		end
	end

	table.sort(compact, function(left, right)
		local left_phase = construction_phase(left.node.name)
		local right_phase = construction_phase(right.node.name)
		if left_phase ~= right_phase then
			return left_phase < right_phase
		end
		if left.pos.y ~= right.pos.y then
			return left.pos.y < right.pos.y
		end
		if left.pos.z ~= right.pos.z then
			return left.pos.z < right.pos.z
		end
		if left.pos.x ~= right.pos.x then
			return left.pos.x < right.pos.x
		end
		return tostring(left.node.name) < tostring(right.node.name)
	end)
	return compact
end

function planner.candidate_offsets(min_radius, max_radius, step)
	min_radius = math.max(1, math.floor(tonumber(min_radius) or 6))
	max_radius = math.max(min_radius, math.floor(tonumber(max_radius) or 30))
	step = math.max(1, math.floor(tonumber(step) or 2))
	local result = {}
	local seen = {}
	local function add(x, z)
		local key = x .. ":" .. z
		if not seen[key] then
			seen[key] = true
			result[#result + 1] = {x = x, y = 0, z = z}
		end
	end
	for radius = min_radius, max_radius, step do
		for offset = -radius, radius, step do
			add(offset, -radius)
			add(radius, offset)
			add(-offset, radius)
			add(-radius, -offset)
		end
	end
	return result
end

local function get_node(pos)
	if type(minetest.get_node_or_nil) == "function" then
		return minetest.get_node_or_nil(pos)
	end
	return minetest.get_node(pos)
end

local function node_definition(name)
	return minetest.registered_nodes and minetest.registered_nodes[name] or nil
end

local function protected(pos, owner)
	return type(minetest.is_protected) == "function" and
		minetest.is_protected(pos, owner or "") == true
end

local function liquid(name)
	return node_group(name, "liquid") > 0 or
		(node_definition(name) and node_definition(name).liquidtype
			and node_definition(name).liquidtype ~= "none")
end

local function infrastructure(name)
	return node_group(name, "chest") > 0 or node_group(name, "door") > 0
		or node_group(name, "bed") > 0
end

local function clear_for_construction(name)
	if name == "air" then
		return true
	end
	local def = node_definition(name)
	if not def or liquid(name) or infrastructure(name) then
		return false
	end
	return def.buildable_to == true or node_group(name, "flora") > 0
		or node_group(name, "leaves") > 0 or node_group(name, "snow") > 0
end

local function solid_ground(name)
	local def = node_definition(name)
	return def ~= nil and def.walkable == true and not liquid(name)
		and not infrastructure(name)
end

local function clear_standing_column(pos)
	local feet = get_node(pos)
	local head = get_node({x = pos.x, y = pos.y + 1, z = pos.z})
	local ground = get_node({x = pos.x, y = pos.y - 1, z = pos.z})
	return feet and head and ground and clear_for_construction(feet.name)
		and clear_for_construction(head.name) and solid_ground(ground.name)
end

function planner.marker_position(nodes)
	local minp = planner.get_bounds(nodes)
	if not minp then
		return nil
	end
	return {x = minp.x - 2, y = minp.y, z = minp.z - 2}
end

-- The accepted site is deliberately strict: one flat support plane, no
-- liquids/infrastructure, a clear volume, full protection coverage and at
-- least one two-node-high approach. Builders search farther instead of
-- producing half-buried or floating public-server buildings.
function planner.validate_site(villager, nodes, marker_pos)
	local minp, maxp = planner.get_bounds(nodes)
	if not minp or not maxp then
		return false, "plan vide"
	end
	local owner = villager and villager.owner_name or ""
	for x = minp.x, maxp.x do
		for z = minp.z, maxp.z do
			local ground_pos = {x = x, y = minp.y - 1, z = z}
			local ground = get_node(ground_pos)
			if not ground or not solid_ground(ground.name) then
				return false, "terrain non plat ou fragile"
			end
			if protected(ground_pos, owner) then
				return false, "terrain protege"
			end
			for y = minp.y, maxp.y do
				local pos = {x = x, y = y, z = z}
				local node = get_node(pos)
				if not node or not clear_for_construction(node.name) then
					return false, liquid(node and node.name or "") and
						"eau ou lave dans le volume" or "volume occupe"
				end
				if protected(pos, owner) then
					return false, "volume protege"
				end
			end
		end
	end

	if marker_pos then
		local marker_node = get_node(marker_pos)
		if not marker_node or not clear_for_construction(marker_node.name)
				or not clear_standing_column(marker_pos)
				or protected(marker_pos, owner) then
			return false, "emplacement du marqueur indisponible"
		end
	end

	local approaches = 0
	for x = minp.x - 1, maxp.x + 1 do
		for _, z in ipairs({minp.z - 1, maxp.z + 1}) do
			if clear_standing_column({x = x, y = minp.y, z = z}) then
				approaches = approaches + 1
			end
		end
	end
	for z = minp.z, maxp.z do
		for _, x in ipairs({minp.x - 1, maxp.x + 1}) do
			if clear_standing_column({x = x, y = minp.y, z = z}) then
				approaches = approaches + 1
			end
		end
	end
	if approaches == 0 then
		return false, "aucun acces praticable"
	end
	return true, nil
end

return planner
