-- Blueprint Construction Helper
-- This module helps villagers construct buildings from learned blueprints

local blueprint_construction = {}
local blueprints = working_villages.blueprints

-- Check if a villager can build from a specific blueprint
function blueprint_construction.can_build(inv_name, blueprint_name)
	return blueprints.has_learned(inv_name, blueprint_name)
end

-- Get the construction data for a blueprint at a specific level
function blueprint_construction.get_construction_data(inv_name, blueprint_name, pos)
	local blueprint = blueprints.get(blueprint_name)
	if not blueprint then
		return nil, "Blueprint not found"
	end
	
	local level = blueprints.get_level(inv_name, blueprint_name)
	if level == 0 then
		return nil, "Blueprint not learned"
	end
	
	-- Get base node data
	local nodedata = blueprint.nodes or {}
	
	-- Apply improvements based on level
	if level > 1 then
		nodedata = blueprints.apply_improvements(blueprint_name, level, nodedata)
	end
	
	-- Adjust positions relative to the build position
	local positioned_data = {}
	for i, entry in ipairs(nodedata) do
		local new_entry = table.copy(entry)
		if entry.pos then
			new_entry.pos = vector.add(pos, entry.pos)
		end
		table.insert(positioned_data, new_entry)
	end
	
	return positioned_data, nil
end

-- Calculate material requirements for a blueprint
function blueprint_construction.get_materials_needed(blueprint_name, level)
	local blueprint = blueprints.get(blueprint_name)
	if not blueprint then
		return {}
	end
	
	local nodedata = blueprint.nodes or {}
	
	-- Apply improvements to get the full node list
	if level and level > 1 then
		nodedata = blueprints.apply_improvements(blueprint_name, level, nodedata)
	end
	
	-- Count materials
	local materials = {}
	for _, entry in ipairs(nodedata) do
		if entry.node and entry.node.name and entry.node.name ~= "air" then
			local name = entry.node.name
			materials[name] = (materials[name] or 0) + 1
		end
	end
	
	return materials
end

-- Check if a villager has the materials needed for a blueprint
function blueprint_construction.has_materials(villager, blueprint_name, level)
	local materials = blueprint_construction.get_materials_needed(blueprint_name, level)
	local inv = villager:get_inventory()
	
	for material, count in pairs(materials) do
		if not inv:contains_item("main", ItemStack(material .. " " .. count)) then
			return false, material
		end
	end
	
	return true, nil
end

-- Start a blueprint-based construction project
-- Returns: success, message, building_data
function blueprint_construction.start_construction(villager_inv_name, blueprint_name, pos)
	-- Check if blueprint is learned
	if not blueprints.has_learned(villager_inv_name, blueprint_name) then
		return false, "Blueprint not learned yet"
	end
	
	-- Get construction data
	local level = blueprints.get_level(villager_inv_name, blueprint_name)
	local nodedata, err = blueprint_construction.get_construction_data(villager_inv_name, blueprint_name, pos)
	
	if not nodedata then
		return false, err or "Failed to get construction data"
	end
	
	-- Create building data structure
	local building_data = {
		blueprint = blueprint_name,
		level = level,
		nodedata = nodedata,
		progress = 0,
		started_by = villager_inv_name,
	}
	
	return true, "Construction project started", building_data
end

-- Suggest a blueprint for a villager to learn based on their experience
function blueprint_construction.suggest_next_blueprint(inv_name)
	local data = blueprints.get_villager_data(inv_name)
	local available = blueprints.get_available_to_learn(inv_name)
	
	-- Prefer blueprints that match construction experience
	local suggestions = {}
	
	for name, blueprint in pairs(available) do
		local score = 0
		
		-- Prefer lower difficulty for less experienced villagers
		if data.construction_count < 5 then
			score = score + (6 - blueprint.difficulty)
		else
			-- More experienced villagers can handle higher difficulty
			score = score + blueprint.difficulty
		end
		
		-- Prefer house blueprints for new builders
		if blueprint.category == blueprints.CATEGORY.HOUSE and data.construction_count < 3 then
			score = score + 5
		end
		
		table.insert(suggestions, {
			name = name,
			blueprint = blueprint,
			score = score,
		})
	end
	
	-- Sort by score
	table.sort(suggestions, function(a, b) return a.score > b.score end)
	
	if #suggestions > 0 then
		return suggestions[1].name, suggestions[1].blueprint
	end
	
	return nil, nil
end

-- Auto-teach a blueprint to a villager if they have enough experience
function blueprint_construction.auto_learn_if_ready(inv_name)
	local suggested_name, suggested_blueprint = blueprint_construction.suggest_next_blueprint(inv_name)
	
	if suggested_name then
		local success, msg = blueprints.teach(inv_name, suggested_name)
		if success then
			minetest.log("action", "[blueprint_construction] Villager " .. inv_name .. " auto-learned: " .. suggested_name)
			return true, suggested_name
		end
	end
	
	return false, nil
end

-- Try to improve a random learned blueprint if possible
function blueprint_construction.auto_improve_random(inv_name)
	local available = blueprints.get_available_to_improve(inv_name)
	
	local improvable = {}
	for name, data in pairs(available) do
		table.insert(improvable, name)
	end
	
	if #improvable > 0 then
		-- Pick a random blueprint to improve
		local chosen = improvable[math.random(#improvable)]
		local success, msg = blueprints.improve(inv_name, chosen)
		if success then
			minetest.log("action", "[blueprint_construction] Villager " .. inv_name .. " improved: " .. chosen)
			return true, chosen
		end
	end
	
	return false, nil
end

return blueprint_construction
