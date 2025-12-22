-- Blueprint Learning and Management System
-- This module allows villagers to learn blueprints and improve their construction skills

local blueprints = {}

local function load_nodes_from_schematic(filename)
	local nodes = {}
	if not filename then
		return nodes
	end
	local path = working_villages.modpath .. "/schems/" .. filename
	local input = io.open(path, "r")
	if not input then
		minetest.log("warning", "[blueprints] Impossible de charger " .. filename)
		return nodes
	end
	local data = minetest.deserialize(input:read("*a"))
	io.close(input)
	if not data then
		minetest.log("warning", "[blueprints] Fichier schem corrompu : " .. filename)
		return nodes
	end
	for _, entry in ipairs(data) do
		if entry.name and entry.x and entry.y and entry.z then
			local node_name = entry.name
			if working_villages.voxelibre_compat.is_voxelibre then
				node_name = working_villages.voxelibre_compat.get_item(node_name)
			end
			node_name = working_villages.buildings.get_registered_nodename(node_name)
			if node_name and node_name ~= "air" and minetest.registered_nodes[node_name] then
				table.insert(nodes, {
					pos = {x = entry.x, y = entry.y, z = entry.z},
					node = {
						name = node_name,
						param1 = entry.param1 or 0,
						param2 = entry.param2 or 0,
					},
				})
			end
		end
	end
	return nodes
end

-- Storage for learned blueprints per villager
-- Format: { [villager_inv_name] = { blueprints = {blueprint_name = level}, experience = num } }
blueprints.learned = {}

-- Blueprint registry
-- Format: { [blueprint_name] = { category, difficulty, nodes, description, ... } }
blueprints.registered = {}

-- Blueprint categories
blueprints.CATEGORY = {
	HOUSE = "house",
	FARM = "farm",
	WORKSHOP = "workshop",
	DECORATION = "decoration",
	INFRASTRUCTURE = "infrastructure",
}

-- Blueprint difficulty levels
blueprints.DIFFICULTY = {
	BEGINNER = 1,
	INTERMEDIATE = 2,
	ADVANCED = 3,
	EXPERT = 4,
	MASTER = 5,
}

-- Load learned blueprints from file
function blueprints.load_learned()
	local file_name = minetest.get_worldpath() .. "/working_villages_blueprints"
	local file = io.open(file_name, "r")
	if file ~= nil then
		local data = file:read("*a")
		file:close()
		blueprints.learned = minetest.deserialize(data) or {}
	end
	return blueprints.learned
end

-- Save learned blueprints to file
function blueprints.save_learned()
	local file_name = minetest.get_worldpath() .. "/working_villages_blueprints"
	local file = io.open(file_name, "w")
	if file then
		file:write(minetest.serialize(blueprints.learned))
		file:close()
	end
end

-- Register a new blueprint
-- definition = {
--   category = CATEGORY.*,
--   difficulty = DIFFICULTY.*,
--   description = "...",
--   nodes = {...},  -- List of node data from schematic
--   schematic_file = "filename.we",  -- Optional schematic file
--   improvements = {...},  -- Optional list of improvement definitions
-- }
function blueprints.register(name, definition)
	if not definition.category or not definition.difficulty then
		minetest.log("error", "[blueprints] Plan " .. name .. " manque des champs requis")
		return false
	end
	local nodes = definition.nodes or {}
	if (#nodes == 0) and definition.schematic_file then
		nodes = load_nodes_from_schematic(definition.schematic_file)
	end

	blueprints.registered[name] = {
		category = definition.category,
		difficulty = definition.difficulty,
		description = definition.description or "Un plan",
		nodes = nodes,
		schematic_file = definition.schematic_file,
		improvements = definition.improvements or {},
		max_level = #(definition.improvements or {}) + 1,
	}
	
	minetest.log("action", "[blueprints] Plan enregistre : " .. name)
	return true
end

-- Get blueprint definition
function blueprints.get(name)
	return blueprints.registered[name]
end

-- Get all registered blueprints
function blueprints.get_all()
	return blueprints.registered
end

-- Get blueprints by category
function blueprints.get_by_category(category)
	local result = {}
	for name, def in pairs(blueprints.registered) do
		if def.category == category then
			result[name] = def
		end
	end
	return result
end

-- Initialize villager blueprint data
function blueprints.init_villager(inv_name)
	if not blueprints.learned[inv_name] then
		blueprints.learned[inv_name] = {
			blueprints = {},
			experience = 0,
			construction_count = 0,
		}
	end
	return blueprints.learned[inv_name]
end

-- Get villager blueprint data
function blueprints.get_villager_data(inv_name)
	return blueprints.learned[inv_name] or blueprints.init_villager(inv_name)
end

-- Check if villager has learned a blueprint
function blueprints.has_learned(inv_name, blueprint_name)
	local data = blueprints.get_villager_data(inv_name)
	return data.blueprints[blueprint_name] ~= nil
end

-- Get the level of a learned blueprint
function blueprints.get_level(inv_name, blueprint_name)
	local data = blueprints.get_villager_data(inv_name)
	return data.blueprints[blueprint_name] or 0
end

-- Teach a blueprint to a villager
-- Returns: success (bool), message (string)
function blueprints.teach(inv_name, blueprint_name)
	local blueprint = blueprints.get(blueprint_name)
	if not blueprint then
		return false, "Plan introuvable : " .. blueprint_name
	end
	
	local data = blueprints.get_villager_data(inv_name)
	
	-- Check if already learned
	if blueprints.has_learned(inv_name, blueprint_name) then
		return false, "Plan deja appris"
	end
	
	-- Check if villager has enough experience for this difficulty
	local required_exp = blueprint.difficulty * 10
	if data.experience < required_exp then
		return false, "Pas assez d'experience (besoin de " .. required_exp .. ", vous avez " .. data.experience .. ")"
	end
	
	-- Teach the blueprint
	data.blueprints[blueprint_name] = 1  -- Start at level 1
	blueprints.save_learned()
	
	minetest.log("action", "[blueprints] Villageois " .. inv_name .. " a appris le plan : " .. blueprint_name)
	return true, "Plan appris : " .. blueprint_name
end

-- Improve a learned blueprint (level up)
-- Returns: success (bool), message (string)
function blueprints.improve(inv_name, blueprint_name)
	local blueprint = blueprints.get(blueprint_name)
	if not blueprint then
		return false, "Plan introuvable"
	end
	
	local data = blueprints.get_villager_data(inv_name)
	local current_level = data.blueprints[blueprint_name]
	
	if not current_level then
		return false, "Plan pas encore appris"
	end
	
	if current_level >= blueprint.max_level then
		return false, "Plan deja au niveau maximum"
	end
	
	-- Check if villager has enough experience to improve
	local required_exp = current_level * blueprint.difficulty * 20
	if data.experience < required_exp then
		return false, "Pas assez d'experience pour ameliorer"
	end
	
	-- Improve the blueprint
	data.blueprints[blueprint_name] = current_level + 1
	data.experience = data.experience - required_exp
	blueprints.save_learned()
	
	minetest.log("action", "[blueprints] Villageois " .. inv_name .. " a ameliore le plan " .. blueprint_name .. " au niveau " .. (current_level + 1))
	return true, "Plan ameliore au niveau " .. (current_level + 1)
end

function blueprints.force_improve(inv_name, blueprint_name)
	local blueprint = blueprints.get(blueprint_name)
	if not blueprint then
		return false, "Plan introuvable"
	end
	local data = blueprints.get_villager_data(inv_name)
	local current_level = data.blueprints[blueprint_name] or 0
	if current_level >= blueprint.max_level then
		return false, "Plan deja maximal"
	end
	data.blueprints[blueprint_name] = current_level + 1
	blueprints.save_learned()
	return true, "Plan forcement ameliore"
end

-- Award experience to a villager
function blueprints.add_experience(inv_name, amount)
	local data = blueprints.get_villager_data(inv_name)
	data.experience = data.experience + amount
	data.construction_count = data.construction_count + 1
	blueprints.save_learned()
	return data.experience
end

-- Get list of blueprints a villager can learn
function blueprints.get_available_to_learn(inv_name)
	local available = {}
	local data = blueprints.get_villager_data(inv_name)
	
	for name, blueprint in pairs(blueprints.registered) do
		local required_exp = blueprint.difficulty * 10
		if not data.blueprints[name] and data.experience >= required_exp then
			available[name] = blueprint
		end
	end
	
	return available
end

-- Get list of blueprints a villager can improve
function blueprints.get_available_to_improve(inv_name)
	local available = {}
	local data = blueprints.get_villager_data(inv_name)
	
	for name, level in pairs(data.blueprints) do
		local blueprint = blueprints.registered[name]
		if blueprint and level < blueprint.max_level then
			local required_exp = level * blueprint.difficulty * 20
			if data.experience >= required_exp then
				available[name] = {
					blueprint = blueprint,
					current_level = level,
					required_exp = required_exp,
				}
			end
		end
	end
	
	return available
end

-- Get blueprint improvements for a specific level
function blueprints.get_improvements(blueprint_name, level)
	local blueprint = blueprints.get(blueprint_name)
	if not blueprint or not blueprint.improvements then
		return {}
	end
	
	local improvements = {}
	for i = 1, math.min(level - 1, #blueprint.improvements) do
		table.insert(improvements, blueprint.improvements[i])
	end
	
	return improvements
end

-- Apply improvements to a node list based on blueprint level
function blueprints.apply_improvements(blueprint_name, level, nodedata)
	local improvements = blueprints.get_improvements(blueprint_name, level)
	local improved_data = table.copy(nodedata)
	
	for _, improvement in ipairs(improvements) do
		if improvement.type == "add_nodes" then
			-- Add additional nodes
			for _, node_entry in ipairs(improvement.nodes) do
				table.insert(improved_data, node_entry)
			end
		elseif improvement.type == "replace_nodes" then
			-- Replace specific nodes with better materials
			for i, node_entry in ipairs(improved_data) do
				if improvement.from == node_entry.node.name then
					improved_data[i].node.name = improvement.to
				end
			end
		elseif improvement.type == "add_decoration" then
			-- Add decorative elements
			for _, node_entry in ipairs(improvement.nodes) do
				table.insert(improved_data, node_entry)
			end
		end
	end
	
	return improved_data
end

-- Initialize on server startup
minetest.register_on_mods_loaded(function()
	blueprints.load_learned()
end)

-- Save on server shutdown
minetest.register_on_shutdown(function()
	blueprints.save_learned()
end)

-- Auto-save periodically
local auto_save_timer = 0
minetest.register_globalstep(function(dtime)
	auto_save_timer = auto_save_timer + dtime
	if auto_save_timer >= 300 then  -- Save every 5 minutes
		blueprints.save_learned()
		auto_save_timer = 0
	end
end)

return blueprints
