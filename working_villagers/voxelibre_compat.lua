-- VoxeLibre Compatibility Layer
-- This module provides compatibility between minetest_game and VoxeLibre
-- by mapping item names, detecting the active game, and providing helper functions

local voxelibre_compat = {}

-- Detect if VoxeLibre is loaded
voxelibre_compat.is_voxelibre = minetest.get_modpath("mcl_core") ~= nil

-- Item/block namespace mappings from minetest_game to VoxeLibre
voxelibre_compat.item_map = {
	-- Basic blocks
	["default:chest"] = "mcl_chests:chest",
	["default:torch"] = "mcl_torches:torch",
	["default:torch_wall"] = "mcl_torches:torch_wall",
	["default:wood"] = "mcl_core:wood",
	["default:paper"] = "mcl_core:paper",
	["default:obsidian"] = "mcl_core:obsidian",
	["default:snow"] = "mcl_core:snow",
	["default:apple"] = "mcl_core:apple",
	["default:cactus"] = "mcl_core:cactus",
	["default:papyrus"] = "mcl_core:reeds",
	["default:dry_shrub"] = "mcl_core:deadbush",
	
	-- Doors (simplified mapping, actual VoxeLibre doors are more complex)
	["doors:door_wood_a"] = "mcl_doors:wooden_door_b_1",
	["doors:door_wood_c"] = "mcl_doors:wooden_door_t_1",
	
	-- Beds (generic mapping, specific bed types need to be handled dynamically)
	["beds:bed_top"] = "mcl_beds:bed_red_top",
	["beds:bed_bottom"] = "mcl_beds:bed_red_bottom",
}

-- Reverse mapping for compatibility
voxelibre_compat.reverse_map = {}
for k, v in pairs(voxelibre_compat.item_map) do
	voxelibre_compat.reverse_map[v] = k
end

-- Convert item name based on current game
function voxelibre_compat.get_item(item_name)
	if not voxelibre_compat.is_voxelibre then
		return item_name
	end
	return voxelibre_compat.item_map[item_name] or item_name
end

-- Get multiple variants of an item (for detection purposes)
function voxelibre_compat.get_item_variants(base_name)
	local variants = {base_name}
	if voxelibre_compat.is_voxelibre then
		local mapped = voxelibre_compat.item_map[base_name]
		if mapped then
			table.insert(variants, mapped)
		end
	end
	return variants
end

-- Check if a node name matches a pattern (considering both game types)
function voxelibre_compat.node_matches(node_name, pattern)
	if string.find(node_name, pattern) then
		return true
	end
	-- Also check the reverse mapping
	local base_name = voxelibre_compat.reverse_map[node_name]
	if base_name and string.find(base_name, pattern) then
		return true
	end
	return false
end

-- Door detection for both games
function voxelibre_compat.is_door(node_name)
	if voxelibre_compat.is_voxelibre then
		return string.find(node_name, "mcl_doors:") ~= nil
	else
		return string.find(node_name, "doors:door") ~= nil
	end
end

-- Get door items for groups
function voxelibre_compat.get_door_items()
	if voxelibre_compat.is_voxelibre then
		return {
			"mcl_doors:wooden_door_b_1",
			"mcl_doors:wooden_door_t_1",
			"mcl_doors:wooden_door_b_2",
			"mcl_doors:wooden_door_t_2",
		}
	else
		return {
			"doors:door_wood_a",
			"doors:door_wood_c",
		}
	end
end

-- Get chest items for groups
function voxelibre_compat.get_chest_items()
	if voxelibre_compat.is_voxelibre then
		return {"mcl_chests:chest"}
	else
		return {"default:chest"}
	end
end

-- Get bed top items for groups
function voxelibre_compat.get_bed_top_items()
	if voxelibre_compat.is_voxelibre then
		-- VoxeLibre has multiple bed colors
		return {
			"mcl_beds:bed_red_top",
			"mcl_beds:bed_blue_top",
			"mcl_beds:bed_cyan_top",
			"mcl_beds:bed_grey_top",
			"mcl_beds:bed_silver_top",
			"mcl_beds:bed_black_top",
			"mcl_beds:bed_yellow_top",
			"mcl_beds:bed_green_top",
			"mcl_beds:bed_orange_top",
			"mcl_beds:bed_purple_top",
			"mcl_beds:bed_magenta_top",
			"mcl_beds:bed_pink_top",
			"mcl_beds:bed_white_top",
			"mcl_beds:bed_brown_top",
			"mcl_beds:bed_lime_top",
			"mcl_beds:bed_light_blue_top",
		}
	else
		return {"beds:bed_top"}
	end
end

-- Get bed bottom items for groups
function voxelibre_compat.get_bed_bottom_items()
	if voxelibre_compat.is_voxelibre then
		-- VoxeLibre has multiple bed colors
		return {
			"mcl_beds:bed_red_bottom",
			"mcl_beds:bed_blue_bottom",
			"mcl_beds:bed_cyan_bottom",
			"mcl_beds:bed_grey_bottom",
			"mcl_beds:bed_silver_bottom",
			"mcl_beds:bed_black_bottom",
			"mcl_beds:bed_yellow_bottom",
			"mcl_beds:bed_green_bottom",
			"mcl_beds:bed_orange_bottom",
			"mcl_beds:bed_purple_bottom",
			"mcl_beds:bed_magenta_bottom",
			"mcl_beds:bed_pink_bottom",
			"mcl_beds:bed_white_bottom",
			"mcl_beds:bed_brown_bottom",
			"mcl_beds:bed_lime_bottom",
			"mcl_beds:bed_light_blue_bottom",
		}
	else
		return {"beds:bed_bottom"}
	end
end

-- Check if node is a chest using groups or name
function voxelibre_compat.is_chest(node)
	local node_name = type(node) == "string" and node or node.name
	if minetest.get_item_group(node_name, "villager_chest") > 0 then
		return true
	end
	-- Fallback to direct name check
	if voxelibre_compat.is_voxelibre then
		return string.find(node_name, "mcl_chests:chest") ~= nil
	else
		return node_name == "default:chest"
	end
end

-- Get the appropriate player model mesh for the current game
-- Both minetest_game and VoxeLibre use character.b3d
-- The model is provided by the base game mods (default or mcl_player)
function voxelibre_compat.get_player_mesh()
	-- Both games use the same character.b3d model file
	-- minetest_game: provided by default mod
	-- VoxeLibre: provided by mcl_player mod
	
	-- Check if the required mods are loaded that provide character.b3d
	local has_model_provider = false
	if voxelibre_compat.is_voxelibre then
		has_model_provider = minetest.get_modpath("mcl_player") ~= nil
	else
		has_model_provider = minetest.get_modpath("default") ~= nil
	end
	
	-- Log a warning if the model provider is not available
	if not has_model_provider then
		minetest.log("warning", "[working_villages] character.b3d model provider not found. " ..
			"For VoxeLibre, install mcl_player mod. For minetest_game, install default mod. " ..
			"Villagers may not display correctly. " ..
			"See working_villages/models/README.md for more information.")
	end
	
	return "character.b3d"
end

-- Get the appropriate skin texture information for villagers
-- Returns format details and compatibility notes for each game
function voxelibre_compat.get_skin_info()
	if voxelibre_compat.is_voxelibre then
		return {
			format = "64x64 or 64x32", -- VoxeLibre accepts both formats
			note = "Compatible with Minecraft/VoxeLibre 64x64 format or 64x32 format"
		}
	else
		return {
			format = "64x32", -- minetest_game traditionally uses 64x32
			note = "Compatible with minetest_game character skin format"
		}
	end
end

-- Get default node sound table compatible with current game
-- Returns an empty table if neither game's sound module is available
-- Note: This function has intentional fallback logic:
-- 1. If VoxeLibre is detected, try mcl_sounds first (wood sounds for signs)
-- 2. Fall back to minetest_game default sounds if available
-- 3. Return empty table if no sound system is available
-- This allows the mod to work in both games and gracefully handle missing sound modules
function voxelibre_compat.node_sound_defaults()
	-- Try VoxeLibre sounds first if VoxeLibre is detected
	-- Signs traditionally use wood sounds in both games
	if voxelibre_compat.is_voxelibre then
		if mcl_sounds and mcl_sounds.node_sound_wood_defaults then
			return mcl_sounds.node_sound_wood_defaults()
		end
	end
	
	-- Try minetest_game default wood sounds for signs
	-- This also serves as fallback if VoxeLibre is detected but mcl_sounds is not loaded
	if default and default.node_sound_wood_defaults then
		return default.node_sound_wood_defaults()
	end
	
	-- Final fallback to generic default sounds if wood sounds not available
	if default and default.node_sound_defaults then
		return default.node_sound_defaults()
	end
	
	-- Return empty table if no sound system available
	return {}
end

-- Get GUI formspec elements compatible with current game
-- Returns appropriate GUI styling strings or empty strings
function voxelibre_compat.get_gui_bg()
	if default and default.gui_bg then
		return default.gui_bg
	end
	-- VoxeLibre doesn't require gui_bg, return empty string
	return ""
end

function voxelibre_compat.get_gui_bg_img()
	if default and default.gui_bg_img then
		return default.gui_bg_img
	end
	-- VoxeLibre doesn't require gui_bg_img, return empty string
	return ""
end

function voxelibre_compat.get_gui_slots()
	if default and default.gui_slots then
		return default.gui_slots
	end
	-- VoxeLibre doesn't require gui_slots, return empty string
	return ""
end

return voxelibre_compat
