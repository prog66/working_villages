-- Blueprint experiment system for .we schematics.
-- Provides stone-style suggestions and applies changes after approval.

local experiments = {}
local compat = working_villages.compat

local function get_override_path(filename)
	return minetest.get_worldpath() .. "/working_villages_schems/" .. filename
end

local function get_mod_path(filename)
	return working_villages.modpath .. "/schems/" .. filename
end

local function load_raw_schematic(filename)
	local path = get_override_path(filename)
	local input = io.open(path, "r")
	if not input then
		path = get_mod_path(filename)
		input = io.open(path, "r")
	end
	if not input then
		return nil, "Impossible de charger " .. filename
	end
	local data = minetest.deserialize(input:read("*a"))
	input:close()
	if not data then
		return nil, "Fichier schem corrompu : " .. filename
	end
	return data
end

local function save_raw_schematic(filename, data)
	local dir = minetest.get_worldpath() .. "/working_villages_schems"
	minetest.mkdir(dir)
	local path = get_override_path(filename)
	local output = io.open(path, "w")
	if not output then
		return false, "Impossible d'ecrire " .. filename
	end
	output:write(minetest.serialize(data))
	output:close()
	return true
end

local function resolve_node(preferred, fallback)
	if minetest.registered_nodes[preferred] then
		return preferred
	end
	return fallback
end

local function stone_style_replacement(name)
	if not name then
		return nil
	end
	local stone = compat.get_node("default:stone")
	local cobble = compat.get_node("default:cobble")
	local stair = resolve_node(compat.get_node("stairs:stair_cobble"), cobble)
	local slab = resolve_node(compat.get_node("stairs:slab_cobble"), cobble)

	if name:find("^stairs:stair_") then
		return stair
	end
	if name:find("^stairs:slab_") then
		return slab
	end
	if minetest.get_item_group(name, "wood") > 0 or name:find("wood") or name:find("tree") then
		return cobble
	end
	return nil
end

function experiments.propose_stone_style(blueprint)
	if working_villages.gameplay_mode ~= "creative_test" then
		return nil, "Les experiences de plans sont reservees au mode creative_test"
	end
	if not blueprint or not blueprint.schematic_file then
		return nil, "Ce plan n'a pas de fichier .we"
	end
	local raw, err = load_raw_schematic(blueprint.schematic_file)
	if not raw then
		return nil, err
	end
	local changes = {}
	for i, entry in ipairs(raw) do
		local repl = stone_style_replacement(entry.name)
		if repl and repl ~= entry.name then
			table.insert(changes, {
				index = i,
				from = entry.name,
				to = repl,
			})
		end
	end
	if #changes == 0 then
		return nil, "Aucune amelioration pierre proposee"
	end
	return {
		id = blueprint.schematic_file .. ":" .. os.time(),
		blueprint = blueprint,
		schematic_file = blueprint.schematic_file,
		changes = changes,
		created = os.time(),
		created_clock = "unix_v1",
		description = "Style pierre (remplacement bois -> pierre/cobble)",
	}
end

function experiments.apply_proposal(proposal)
	if working_villages.gameplay_mode ~= "creative_test" then
		return false, "Les experiences de plans sont reservees au mode creative_test"
	end
	local raw, err = load_raw_schematic(proposal.schematic_file)
	if not raw then
		return false, err
	end
	for _, change in ipairs(proposal.changes or {}) do
		if raw[change.index] and raw[change.index].name == change.from then
			raw[change.index].name = change.to
		end
	end
	return save_raw_schematic(proposal.schematic_file, raw)
end

function experiments.summary(proposal, limit)
	limit = limit or 3
	local parts = {}
	for i, change in ipairs(proposal.changes or {}) do
		table.insert(parts, change.from .. " -> " .. change.to)
		if i >= limit then
			break
		end
	end
	if #proposal.changes > limit then
		table.insert(parts, "...")
	end
	return table.concat(parts, ", ")
end

return experiments
