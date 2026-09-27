-- Blueprint Construction Helper
-- This module helps villagers construct buildings from learned blueprints

local blueprint_construction = {}
local blueprints = working_villages.blueprints
local compat = working_villages.compat
local func = working_villages.require("jobs/util")
local construction_planner = working_villages.construction_planner
local site_min_radius = math.max(2,
	math.floor(tonumber(minetest.settings:get("working_villages_builder_site_min_radius")) or 6))
local site_max_radius = math.max(site_min_radius,
	math.floor(tonumber(minetest.settings:get("working_villages_builder_site_max_radius")) or 30))
local site_attempt_budget = math.max(8,
	math.floor(tonumber(minetest.settings:get("working_villages_builder_site_attempts")) or 96))

local function safe_node(name, fallback)
	if minetest.registered_nodes[name] then
		return name
	end
	return fallback
end

local function first_registered_node(candidates, fallback)
	for _, name in ipairs(candidates) do
		if name and minetest.registered_nodes[name] then
			return name
		end
	end
	return fallback
end

local function build_garden_nodes()
	local nodes = {}
	local grass = safe_node(compat.get_node("default:dirt_with_grass"), compat.get_node("default:dirt"))
	local cobble = safe_node(compat.get_node("default:cobble"), compat.get_node("default:stone"))
	local fence = safe_node(compat.get_node("default:fence_wood"), compat.get_node("default:wood"))

	for x = -2, 2 do
		for z = -2, 2 do
			local node_name = grass
			if x == 0 or z == 0 then
				node_name = cobble
			end
			if x == -2 or x == 2 or z == -2 or z == 2 then
				node_name = fence
			end
			table.insert(nodes, {
				pos = {x = x, y = 0, z = z},
				node = {name = node_name, param1 = 0, param2 = 0},
			})
		end
	end
	return nodes
end

local function build_farm_plot_nodes()
	local nodes = {}
	local field = safe_node(compat.get_node("default:dirt"), compat.get_node("default:dirt_with_grass"))
	local water = first_registered_node({
		compat.get_node("default:water_source"),
		"default:water_source",
		"mcl_core:water_source",
	}, field)
	local fence = safe_node(compat.get_node("default:fence_wood"), compat.get_node("default:wood"))

	for x = -3, 3 do
		for z = -3, 3 do
			local ground_name = field
			local top_name = nil
			if x == -3 or x == 3 or z == -3 or z == 3 then
				top_name = fence
			elseif x == 0 then
				ground_name = water
			end
			table.insert(nodes, {
				pos = {x = x, y = 0, z = z},
				node = {name = ground_name, param1 = 0, param2 = 0},
			})
			if top_name then
				table.insert(nodes, {
					pos = {x = x, y = 1, z = z},
					node = {name = top_name, param1 = 0, param2 = 0},
				})
			end
		end
	end
	return nodes
end

local function get_bounds(nodedata)
	local minp
	local maxp
	for _, entry in ipairs(nodedata or {}) do
		if entry.pos then
			local p = entry.pos
			if not minp then
				minp = vector.new(p)
				maxp = vector.new(p)
			else
				minp.x = math.min(minp.x, p.x)
				minp.y = math.min(minp.y, p.y)
				minp.z = math.min(minp.z, p.z)
				maxp.x = math.max(maxp.x, p.x)
				maxp.y = math.max(maxp.y, p.y)
				maxp.z = math.max(maxp.z, p.z)
			end
		end
	end
	return minp, maxp
end

local function area_has_building_marker(minp, maxp, padding)
	if not minp or not maxp then
		return false
	end
	local pad = padding or 2
	local search_min = vector.subtract(minp, pad)
	local search_max = vector.add(maxp, pad)
	local markers = minetest.find_nodes_in_area(search_min, search_max, {"working_villages:building_marker"})
	return #markers > 0
end

-- Check if a villager can build from a specific blueprint
function blueprint_construction.can_build(inv_name, blueprint_name)
	return blueprints.has_learned(inv_name, blueprint_name)
end

-- Get the construction data for a blueprint at a specific level
function blueprint_construction.get_construction_data(inv_name, blueprint_name, pos)
	local blueprint = blueprints.get(blueprint_name)
	if not blueprint then
		return nil, "Plan introuvable"
	end
	
	local level = blueprints.get_level(inv_name, blueprint_name)
	if level == 0 then
		return nil, "Plan non appris"
	end
	
	-- Get base node data
	local nodedata = blueprint.nodes or {}
	if #nodedata == 0 and blueprint_name == "garden" then
		nodedata = build_garden_nodes()
	elseif #nodedata == 0 and blueprint_name == "farm_plot" then
		nodedata = build_farm_plot_nodes()
	end
	if #nodedata == 0 then
		return nil, "Plan vide"
	end
	
	-- Apply improvements based on level
	if level > 1 then
		nodedata = blueprints.apply_improvements(blueprint_name, level, nodedata)
	end
	if construction_planner then
		nodedata = construction_planner.prepare_nodes(nodedata)
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
	if #nodedata == 0 and blueprint_name == "garden" then
		nodedata = build_garden_nodes()
	elseif #nodedata == 0 and blueprint_name == "farm_plot" then
		nodedata = build_farm_plot_nodes()
	end
	
	-- Apply improvements to get the full node list
	if level and level > 1 then
		nodedata = blueprints.apply_improvements(blueprint_name, level, nodedata)
	end
	if construction_planner then
		nodedata = construction_planner.prepare_nodes(nodedata)
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
		return false, "Plan pas encore appris"
	end
	
	-- Get construction data
	local level = blueprints.get_level(villager_inv_name, blueprint_name)
	local nodedata, err = blueprint_construction.get_construction_data(villager_inv_name, blueprint_name, pos)
	
	if not nodedata then
		return false, err or "Impossible d'obtenir les donnees de construction"
	end
	
	-- Create building data structure
	local building_data = {
		blueprint = blueprint_name,
		level = level,
		nodedata = nodedata,
		progress = 0,
		started_by = villager_inv_name,
	}
	
	return true, "Projet de construction demarre", building_data
end

function blueprint_construction.start_site(villager, blueprint_name)
	local pos = villager.object:get_pos()
	local base = vector.round(
		(villager.pos_data and (villager.pos_data.storage_pos
			or villager.pos_data.home_pos or villager.pos_data.job_pos)) or pos)
	local inv_name = villager:get_inventory_name()
	local build_pos
	local marker_pos
	local building
	local last_reason = "aucun candidat"
	local effective_attempt_budget = site_attempt_budget
	local offsets = construction_planner and
		construction_planner.candidate_offsets(site_min_radius, site_max_radius, 2)
		or {{x = 8, y = 0, z = 0}}
	for attempt, offset in ipairs(offsets) do
		if attempt > site_attempt_budget then
			break
		end
		local candidate = vector.add(base, offset)
		candidate.y = candidate.y + 4
		local ground = func.find_ground_below(candidate)
		if ground then
			local candidate_build_pos = vector.round(ground)
			local ok, msg, data = blueprint_construction.start_construction(
				inv_name, blueprint_name, candidate_build_pos)
			if not ok then
				return false, msg
			end
			-- A castle-sized plan must not multiply its full-volume validation by
			-- hundreds of candidates in one server step. Small homes may search
			-- broadly; large structures receive a proportional, bounded search.
			effective_attempt_budget = math.min(effective_attempt_budget,
				math.max(8, math.floor(24000 / math.max(1, #data.nodedata))))
			if attempt > effective_attempt_budget then
				last_reason = "budget de verification du terrain atteint"
				break
			end
			local candidate_marker = construction_planner and
				construction_planner.marker_position(data.nodedata)
				or vector.add(candidate_build_pos, {x = -2, y = 0, z = -2})
			local minp, maxp = get_bounds(data.nodedata)
			local site_ok, site_reason = true, nil
			if area_has_building_marker(minp, maxp, 3) then
				site_ok = false
				site_reason = "chantier voisin"
			elseif construction_planner then
				site_ok, site_reason = construction_planner.validate_site(
					villager, data.nodedata, candidate_marker)
			end
			if site_ok then
				build_pos = candidate_build_pos
				marker_pos = candidate_marker
				building = data
				break
			end
			last_reason = site_reason or last_reason
		end
	end

	if not build_pos or not building then
		return false, "Aucun terrain de construction fiable : " .. last_reason
	end

	minetest.set_node(marker_pos, {name = "working_villages:building_marker"})
	local meta = minetest.get_meta(marker_pos)
	meta:set_string("owner", villager.owner_name or "")
	meta:set_string("schematic", blueprint_name)
	meta:set_string("build_pos", minetest.pos_to_string(build_pos))
	meta:set_string("state", "begun")
	meta:set_int("index", 1)

	local building_on_pos = working_villages.buildings.get(build_pos)
	building_on_pos.nodedata = building.nodedata
	if working_villages.save_building_state then
		working_villages.save_building_state()
	end
	if working_villages.sync_construction_site_registry then
		working_villages.sync_construction_site_registry(marker_pos)
	end
	-- The builder that selected and opened this site owns the first work turn.
	-- Leaving it to the generic nearby-marker scan allowed bootstrap support
	-- (wood gathering, logistics) to pre-empt the freshly created construction
	-- before the same villager rediscovered it.
	if villager.set_job_data then
		villager:set_job_data("builder_marker", vector.round(marker_pos))
	else
		villager.job_data = villager.job_data or {}
		villager.job_data.builder_marker = vector.round(marker_pos)
	end

	return true, "Chantier lance pour " .. blueprint_name
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
			minetest.log("action", "[blueprint_construction] Villageois " .. inv_name .. " a appris automatiquement : " .. suggested_name)
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
			minetest.log("action", "[blueprint_construction] Villageois " .. inv_name .. " a ameliore : " .. chosen)
			return true, chosen
		end
	end
	
	return false, nil
end

return blueprint_construction
