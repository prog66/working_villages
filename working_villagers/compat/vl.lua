-- Unified compatibility helpers for VoxeLibre / minetest_game
-- Centralizes node/item mappings and utility helpers for doors, beds, torches, farming, etc.

local compat = working_villages.require("voxelibre_compat")

-- Detect current game profile (can be called with an override mod table for tests)
local function has_mod(mods, name)
	if mods ~= nil then
		return mods[name] == true
	end
	return minetest.get_modpath(name) ~= nil
end

function compat.detect_profile(mods_override)
	local is_voxelibre = has_mod(mods_override, "mcl_core")
	local is_minetest_game = (not is_voxelibre) and has_mod(mods_override, "default")
	local profile_id = "unknown"
	if is_voxelibre then
		profile_id = "voxelibre"
	elseif is_minetest_game then
		profile_id = "minetest_game"
	end
	return {
		id = profile_id,
		is_voxelibre = is_voxelibre,
		is_minetest_game = is_minetest_game,
		supported = is_voxelibre or is_minetest_game,
		mods = {
			mcl_core = has_mod(mods_override, "mcl_core"),
			default = has_mod(mods_override, "default"),
			mcl_doors = has_mod(mods_override, "mcl_doors"),
			mcl_beds = has_mod(mods_override, "mcl_beds"),
			mcl_torches = has_mod(mods_override, "mcl_torches"),
			mcl_farming = has_mod(mods_override, "mcl_farming"),
		},
	}
end

compat.game_profile = compat.game_profile or compat.detect_profile()
compat.is_voxelibre = compat.game_profile.is_voxelibre

-- Generic node resolver with mapping + registration check
function compat.get_node(name)
	local mapped = compat.get_item(name)
	if minetest.registered_nodes[mapped] then
		return mapped
	end
	if minetest.registered_nodes[name] then
		return name
	end
	return mapped
end

-- Torch helpers (wall + floor variants)
function compat.get_torch_items()
	return {
		wall = compat.get_item("default:torch_wall"),
		floor = compat.get_item("default:torch"),
	}
end

function compat.is_torch(node_name)
	if not node_name then
		return false
	end
	local torch = compat.get_torch_items()
	return node_name == torch.wall or node_name == torch.floor
end

-- Bed helpers (explicit tables for both games)
function compat.get_bed_items()
	return {
		top = compat.get_bed_top_items(),
		bottom = compat.get_bed_bottom_items(),
	}
end

local function build_bed_pairs()
	local pairs = {}
	local beds = compat.get_bed_items()
	for idx, top in ipairs(beds.top) do
		local bottom = beds.bottom[idx] or beds.bottom[1]
		pairs[top] = {part = "top", top = top, bottom = bottom}
	end
	for idx, bottom in ipairs(beds.bottom) do
		local top = beds.top[idx] or beds.top[1]
		pairs[bottom] = {part = "bottom", top = top, bottom = bottom}
	end
	return pairs
end

local bed_pairs = build_bed_pairs()

function compat.bed_meta(node_name)
	return bed_pairs[node_name]
end

function compat.is_bed_top(node_name)
	local meta = compat.bed_meta(node_name)
	return meta ~= nil and meta.part == "top"
end

function compat.is_bed_bottom(node_name)
	local meta = compat.bed_meta(node_name)
	return meta ~= nil and meta.part == "bottom"
end

-- Farming helpers
function compat.is_tillable_dirt(node_name)
	if not node_name then
		return false
	end
	if compat.is_voxelibre then
		return node_name == "mcl_core:dirt"
			or node_name:find("mcl_core:dirt_with_grass", 1, true) ~= nil
	end
	return node_name == "default:dirt"
		or node_name:find("default:dirt_with_grass", 1, true) ~= nil
end

function compat.is_farmland_node(node_name)
	if not node_name then
		return false
	end
	-- Both supported games use soil=1 for ordinary dirt/grass and soil>=2
	-- for cultivated ground. Tillable dirt is an input to the hoe action, not
	-- farmland: treating it as already cultivated makes the farmer repeatedly
	-- attempt to place seeds on raw dirt and prevents the hoe branch from ever
	-- completing the field bootstrap.
	return minetest.get_item_group(node_name, "soil") >= 2
end

function compat.get_growth_stage(node)
	local node_name = type(node) == "table" and node.name or node
	if not node_name then
		return nil
	end
	local stage = node_name:match("_([0-9]+)$")
	return stage and tonumber(stage) or nil
end

-- Door helpers (existing compat.is_door kept)
function compat.get_door_item()
	-- Prefer a standard wood door in current game profile
	if compat.is_voxelibre then
		return compat.get_item("doors:door_wood_a") -- mapped to mcl_* via get_item
	end
	return "doors:door_wood_a"
end

-- Furnace helper
function compat.is_furnace(node_name)
	if not node_name then
		return false
	end
	if minetest.get_item_group(node_name, "furnace") > 0 then
		return true
	end
	if compat.is_voxelibre then
		return node_name:find("mcl_furnaces:") ~= nil
	end
	return node_name:find("default:furnace") ~= nil
end

-- Metal stock is not grouped consistently between the supported games.
-- VoxeLibre raw iron, for example, is a blast-furnace input without an `ore`
-- group. Resolve the real cooking output so the village economy can recognize
-- modded raw metals without scattering namespace checks across professions.
function compat.is_ore_item(item_name)
	if type(item_name) ~= "string" or item_name == "" then
		return false
	end
	if compat.is_metal_ingot(item_name) or compat.is_metal_smelting_input(item_name)
			or minetest.get_item_group(item_name, "ore") > 0 then
		return true
	end
	if item_name:find("_ore", 1, true)
			or item_name:find("lump", 1, true)
			or item_name:find("ingot", 1, true) then
		return true
	end
	return false
end

return compat
