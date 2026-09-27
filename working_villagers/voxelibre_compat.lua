-- VoxeLibre Compatibility Layer
-- This module provides compatibility between minetest_game and VoxeLibre
-- by mapping item names, detecting the active game, and providing helper functions

local voxelibre_compat = {}

local function file_exists(path)
	local file = io.open(path, "rb")
	if file then
		file:close()
		return true
	end
	return false
end

local function mesh_available(mod_name, relative_path)
	local modpath = minetest.get_modpath(mod_name)
	if not modpath then
		return false
	end
	return file_exists(modpath .. "/" .. relative_path)
end

local function is_armor_mesh(mesh_name)
	-- Check if the mesh is a VoxeLibre armor mesh
	-- VoxeLibre uses mcl_armor_character meshes that have built-in armor texture layers
	return mesh_name == "mcl_armor_character.b3d" or
		mesh_name == "mcl_armor_character_female.b3d"
end

-- Detect if VoxeLibre is loaded
voxelibre_compat.is_voxelibre = minetest.get_modpath("mcl_core") ~= nil

-- Item/block namespace mappings from minetest_game to VoxeLibre
voxelibre_compat.item_map = {
	-- Basic blocks
	["default:chest"] = "mcl_chests:chest",
	["default:torch"] = "mcl_torches:torch",
	["default:torch_wall"] = "mcl_torches:torch_wall",
	["default:wood"] = "mcl_core:wood",
	["default:tree"] = "mcl_core:tree",
	["default:stone"] = "mcl_core:stone",
	["default:cobble"] = "mcl_core:cobble",
	["default:junglewood"] = "mcl_core:junglewood",
	["default:paper"] = "mcl_core:paper",
	["default:book"] = "mcl_books:book",
	["default:stick"] = "mcl_core:stick",
	["default:obsidian"] = "mcl_core:obsidian",
	["default:snow"] = "mcl_core:snow",
	["default:cactus"] = "mcl_core:cactus",
	["default:papyrus"] = "mcl_core:reeds",
	["default:dry_shrub"] = "mcl_core:deadbush",
	["default:apple"] = "mcl_core:apple",
	["default:fence_wood"] = "mcl_fences:fence",
	["default:furnace"] = "mcl_furnaces:furnace",
	["default:ladder_wood"] = "mcl_core:ladder",
	["flowers:mushroom_brown"] = "mcl_mushrooms:mushroom_brown",
	["flowers:mushroom_red"] = "mcl_mushrooms:mushroom_red",

	-- Tools whose VoxeLibre namespace differs from mcl_core.
	["default:hoe_wood"] = "mcl_farming:hoe_wood",
	["default:hoe_stone"] = "mcl_farming:hoe_stone",
	["default:hoe_steel"] = "mcl_farming:hoe_iron",
	["default:hoe_iron"] = "mcl_farming:hoe_iron",
	["default:hoe_gold"] = "mcl_farming:hoe_gold",
	["default:hoe_diamond"] = "mcl_farming:hoe_diamond",
	["default:pick_wood"] = "mcl_tools:pick_wood",
	["default:pick_stone"] = "mcl_tools:pick_stone",
	["default:pick_steel"] = "mcl_tools:pick_iron",
	["default:pick_iron"] = "mcl_tools:pick_iron",
	["default:pick_gold"] = "mcl_tools:pick_gold",
	["default:pick_diamond"] = "mcl_tools:pick_diamond",
	["default:shovel_wood"] = "mcl_tools:shovel_wood",
	["default:shovel_stone"] = "mcl_tools:shovel_stone",
	["default:shovel_steel"] = "mcl_tools:shovel_iron",
	["default:shovel_iron"] = "mcl_tools:shovel_iron",
	["default:shovel_gold"] = "mcl_tools:shovel_gold",
	["default:shovel_diamond"] = "mcl_tools:shovel_diamond",
	["default:axe_wood"] = "mcl_tools:axe_wood",
	["default:axe_stone"] = "mcl_tools:axe_stone",
	["default:axe_steel"] = "mcl_tools:axe_iron",
	["default:axe_iron"] = "mcl_tools:axe_iron",
	["default:axe_gold"] = "mcl_tools:axe_gold",
	["default:axe_diamond"] = "mcl_tools:axe_diamond",
	["default:sword_wood"] = "mcl_tools:sword_wood",
	["default:sword_stone"] = "mcl_tools:sword_stone",
	["default:sword_steel"] = "mcl_tools:sword_iron",
	["default:sword_iron"] = "mcl_tools:sword_iron",
	["default:sword_gold"] = "mcl_tools:sword_gold",
	["default:sword_diamond"] = "mcl_tools:sword_diamond",

	-- Ores and ingots
	["default:stone_with_iron"] = "mcl_core:stone_with_iron",
	["default:stone_with_gold"] = "mcl_core:stone_with_gold",
	["default:stone_with_copper"] = "mcl_copper:stone_with_copper",
	["default:steel_ingot"] = "mcl_core:iron_ingot",
	["default:gold_ingot"] = "mcl_core:gold_ingot",
	["default:copper_ingot"] = "mcl_copper:copper_ingot",
	
	-- Doors (simplified mapping, actual VoxeLibre doors are more complex)
	["doors:door_wood_a"] = "mcl_doors:wooden_door_b_1",
	["doors:door_wood_c"] = "mcl_doors:wooden_door_t_1",
	["doors:door_wood"] = "mcl_doors:wooden_door",
	
	-- Beds (generic mapping, specific bed types need to be handled dynamically)
	-- The autonomous straw-bed recipe intentionally produces the undyed bed.
	-- Keep schematic conversion aligned with that real craft output so a
	-- builder never needs a dye which the village economy cannot source.
	["beds:bed_top"] = "mcl_beds:bed_white_top",
	["beds:bed_bottom"] = "mcl_beds:bed_white_bottom",
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
	local mapped = voxelibre_compat.item_map[item_name]
	if mapped then
		return mapped
	end

	local alias = minetest.registered_aliases[item_name]
	if alias then
		return alias
	end

	if item_name:sub(1, 5) == "wool:" then
		local candidate = "mcl_wool:" .. item_name:sub(6)
		if minetest.registered_items[candidate] then
			return candidate
		end
	end

	if item_name:sub(1, 7) == "stairs:" then
		local candidate = "mcl_stairs:" .. item_name:sub(8)
		if minetest.registered_items[candidate] then
			return candidate
		end
	end

	local suffix = item_name:match("^default:(.+)$")
	if suffix then
		local candidate = "mcl_core:" .. suffix
		if minetest.registered_items[candidate] then
			return candidate
		end
	end

	return item_name
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
	if type(node_name) ~= "string" or node_name == "" then
		return false
	end
	-- VoxeLibre keeps doors and trapdoors in the same namespace.  Node
	-- groups are the authoritative distinction; the name guard also keeps
	-- this safe while loading schematics containing an unregistered alias.
	if minetest.get_item_group(node_name, "trapdoor") > 0
			or node_name:find("trapdoor", 1, true) then
		return false
	end
	if minetest.get_item_group(node_name, "door") > 0
			or minetest.get_item_group(node_name, "villager_door") > 0 then
		return true
	end
	-- Compatibility fallbacks for legacy schematics and door craftitems.
	-- They deliberately describe door state suffixes instead of accepting
	-- every item in mcl_doors:*.
	if node_name:match("_door_[bt]_[12]$") or node_name:match("_door$") then
		return true
	end
	return node_name:match("^doors:door_[%w_]+$") ~= nil
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

local function copy_list(source)
	local result = {}
	for _, value in ipairs(source or {}) do
		result[#result + 1] = value
	end
	return result
end

local function unique_list(source)
	local result = {}
	local seen = {}
	for _, value in ipairs(source or {}) do
		if type(value) == "string" and value ~= "" and not seen[value] then
			seen[value] = true
			result[#result + 1] = value
		end
	end
	return result
end

function voxelibre_compat.get_registered_items(candidates)
	local registered = minetest.registered_items or {}
	local result = {}
	for _, name in ipairs(unique_list(candidates)) do
		if registered[name] then
			result[#result + 1] = name
		end
	end
	return result
end

local CHEST_ITEMS = {
	voxelibre = {
		"mcl_chests:chest",
		"mcl_chests:chest_small",
		"mcl_chests:chest_left",
		"mcl_chests:chest_right",
		"mcl_chests:trapped_chest",
		"mcl_chests:trapped_chest_small",
		"mcl_chests:trapped_chest_left",
		"mcl_chests:trapped_chest_right",
		"mcl_chests:trapped_chest_on_small",
		"mcl_chests:trapped_chest_on_left",
		"mcl_chests:trapped_chest_on_right",
		-- Legacy MineClone namespace retained for existing worlds.
		"mcl_chest:chest",
		"mcl_chest:chest_left",
		"mcl_chest:chest_right",
	},
	minetest_game = {"default:chest"},
}

local FURNACE_ITEMS = {
	voxelibre = {"mcl_furnaces:furnace"},
	minetest_game = {"default:furnace"},
}

-- Furnace recipes, not ore node names, are the stable cross-game contract.
-- In particular, mining an ore node yields default:*_lump in Minetest Game
-- and mcl_raw_ores:raw_* / mcl_copper:raw_copper in VoxeLibre.  Keeping the
-- ingot side explicit prevents ordinary cookable items from being mistaken
-- for forge input while still accepting every registered input recipe which
-- produces one of these ingots (including optional-mod equivalents).
local METAL_INGOT_ITEMS = {
	voxelibre = {
		"mcl_core:iron_ingot",
		"mcl_core:gold_ingot",
		"mcl_copper:copper_ingot",
	},
	minetest_game = {
		"default:steel_ingot",
		"default:gold_ingot",
		"default:copper_ingot",
	},
}

local METAL_INGOT_GROUPS = {
	"villager_metal_ingot",
	"metal_ingot",
	"ingot",
}

local CRAFTING_TABLE_ITEMS = {
	voxelibre = {"mcl_crafting_table:crafting_table"},
	-- Minetest Game has no base crafting-table node. These optional names are
	-- retained for worlds that add a compatible workbench mod.
	minetest_game = {"crafting:workbench", "mcl_inventory:workbench"},
}

local function profile_items(catalog)
	local profile = voxelibre_compat.is_voxelibre and "voxelibre" or "minetest_game"
	return copy_list(catalog[profile])
end

-- All chest node states used for detection/group normalization.
function voxelibre_compat.get_chest_items()
	return profile_items(CHEST_ITEMS)
end

-- Search nodes include semantic groups first, then explicit compatibility
-- fallbacks for older games and transformed chest node states.
function voxelibre_compat.get_chest_search_nodes()
	local items = {"group:villager_chest", "group:chest"}
	for _, name in ipairs(voxelibre_compat.get_chest_items()) do
		items[#items + 1] = name
	end
	return unique_list(items)
end

-- Placeable/craftable chest item candidates deliberately exclude internal
-- small/left/right node states.
function voxelibre_compat.get_chest_item_candidates()
	local candidates = voxelibre_compat.is_voxelibre and {
		"mcl_chests:chest",
		"mcl_chest:chest",
	} or {"default:chest"}
	return voxelibre_compat.get_registered_items(candidates)
end

function voxelibre_compat.get_furnace_items()
	return profile_items(FURNACE_ITEMS)
end

function voxelibre_compat.get_furnace_item_candidates()
	return voxelibre_compat.get_registered_items(voxelibre_compat.get_furnace_items())
end

local function item_name(item)
	if type(item) == "string" then
		return item
	end
	if type(item) == "table" and type(item.name) == "string" then
		return item.name
	end
	if item ~= nil then
		local ok, name = pcall(function()
			return item:get_name()
		end)
		if ok and type(name) == "string" then
			return name
		end
	end
	return ""
end

function voxelibre_compat.get_metal_ingot_items()
	return voxelibre_compat.get_registered_items(profile_items(METAL_INGOT_ITEMS))
end

function voxelibre_compat.is_metal_ingot(item)
	local name = item_name(item)
	if name == "" then
		return false
	end
	for _, candidate in ipairs(voxelibre_compat.get_metal_ingot_items()) do
		if name == candidate then
			return true
		end
	end
	for _, group in ipairs(METAL_INGOT_GROUPS) do
		if minetest.get_item_group(name, group) > 0 then
			return true
		end
	end
	return false
end

-- Return the real cooking output for one unit of input when (and only when)
-- it is a recognized metal ingot. This accepts canonical ore drops without
-- depending on aliases or on the name of the node they came from.
function voxelibre_compat.get_metal_smelt_result(item)
	local name = item_name(item)
	if name == "" or not (minetest.registered_items or {})[name] then
		return nil
	end
	local input = ItemStack(name)
	input:set_count(1)
	local cooked = minetest.get_craft_result({
		method = "cooking",
		width = 1,
		items = {input},
	})
	if cooked and cooked.item and not cooked.item:is_empty()
			and voxelibre_compat.is_metal_ingot(cooked.item) then
		return cooked.item
	end
	return nil
end

function voxelibre_compat.is_metal_smelting_input(item)
	return voxelibre_compat.get_metal_smelt_result(item) ~= nil
end

-- Minetest Game uses specific food_* groups instead of the generic `food`
-- group used by VoxeLibre and by the villager economy.  Keep the verified
-- edible base-game items here so groups.lua can expose one cross-game
-- contract without mistaking wheat, flour, or the poisonous red mushroom for
-- ready-to-eat food.
function voxelibre_compat.get_food_items()
	if voxelibre_compat.is_voxelibre then
		return {}
	end
	return {
		"default:apple",
		"default:blueberries",
		"farming:bread",
		"flowers:mushroom_brown",
	}
end

-- is_furnace is defined in compat/vl.lua, which requires this module and is
-- always loaded afterward, so a definition here would only ever be a dead,
-- silently-shadowed copy. compat/vl.lua's version also matches
-- "default:furnace_active" (the lit furnace state in minetest_game), which
-- an exact-match version here would have missed.

function voxelibre_compat.get_crafting_table_items()
	return profile_items(CRAFTING_TABLE_ITEMS)
end

function voxelibre_compat.get_crafting_table_item_candidates()
	return voxelibre_compat.get_registered_items(voxelibre_compat.get_crafting_table_items())
end

local TOOL_NAMESPACES = {
	voxelibre = {
		pick = "mcl_tools",
		shovel = "mcl_tools",
		axe = "mcl_tools",
		sword = "mcl_tools",
		hoe = "mcl_farming",
	},
	minetest_game = {
		pick = "default",
		shovel = "default",
		axe = "default",
		sword = "default",
		hoe = "farming",
	},
}

local TOOL_TIERS = {
	voxelibre = {
		wood = "wood",
		stone = "stone",
		steel = "iron",
		iron = "iron",
		gold = "gold",
		diamond = "diamond",
	},
	minetest_game = {
		wood = "wood",
		stone = "stone",
		bronze = "bronze",
		steel = "steel",
		iron = "steel",
		mese = "mese",
		diamond = "diamond",
	},
}

function voxelibre_compat.get_tool_item(tool_kind, tier)
	if type(tool_kind) ~= "string" or type(tier) ~= "string" then
		return nil
	end
	-- Engine dig groups call a pick a "pickaxe", while both supported games
	-- name the concrete item "pick_*". Accept either vocabulary so job code can
	-- pass the required dig group directly.
	local item_kind = tool_kind == "pickaxe" and "pick" or tool_kind
	local profile = voxelibre_compat.is_voxelibre and "voxelibre" or "minetest_game"
	local namespace = TOOL_NAMESPACES[profile][item_kind]
	local suffix = TOOL_TIERS[profile][tier]
	if not namespace or not suffix then
		return nil
	end
	local name = ("%s:%s_%s"):format(namespace, item_kind, suffix)
	if not (minetest.registered_items or {})[name] then
		return nil
	end
	return name
end

function voxelibre_compat.get_tool_items(tool_kind, tiers)
	tiers = tiers or {"diamond", "mese", "iron", "gold", "bronze", "stone", "wood"}
	if type(tiers) == "string" then
		tiers = {tiers}
	end
	local candidates = {}
	for _, tier in ipairs(tiers) do
		candidates[#candidates + 1] = voxelibre_compat.get_tool_item(tool_kind, tier)
	end
	return unique_list(candidates)
end

local ARMOR_ITEMS = {
	iron = {
		helmet = {"mcl_armor:helmet_iron", "3d_armor:helmet_steel", "armor:helmet_iron", "armor:helmet_steel"},
		chestplate = {"mcl_armor:chestplate_iron", "3d_armor:chestplate_steel", "armor:chestplate_iron", "armor:chestplate_steel"},
		leggings = {"mcl_armor:leggings_iron", "3d_armor:leggings_steel", "armor:leggings_iron", "armor:leggings_steel"},
		boots = {"mcl_armor:boots_iron", "3d_armor:boots_steel", "armor:boots_iron", "armor:boots_steel"},
	},
	gold = {
		helmet = {"mcl_armor:helmet_gold", "3d_armor:helmet_gold", "armor:helmet_gold"},
		chestplate = {"mcl_armor:chestplate_gold", "3d_armor:chestplate_gold", "armor:chestplate_gold"},
		leggings = {"mcl_armor:leggings_gold", "3d_armor:leggings_gold", "armor:leggings_gold"},
		boots = {"mcl_armor:boots_gold", "3d_armor:boots_gold", "armor:boots_gold"},
	},
	diamond = {
		helmet = {"mcl_armor:helmet_diamond", "3d_armor:helmet_diamond", "armor:helmet_diamond"},
		chestplate = {"mcl_armor:chestplate_diamond", "3d_armor:chestplate_diamond", "armor:chestplate_diamond"},
		leggings = {"mcl_armor:leggings_diamond", "3d_armor:leggings_diamond", "armor:leggings_diamond"},
		boots = {"mcl_armor:boots_diamond", "3d_armor:boots_diamond", "armor:boots_diamond"},
	},
}

function voxelibre_compat.get_armor_items(piece, tier)
	local tier_items = ARMOR_ITEMS[tier]
	return voxelibre_compat.get_registered_items(tier_items and tier_items[piece] or {})
end

function voxelibre_compat.get_shield_items()
	return voxelibre_compat.get_registered_items({
		"mcl_shields:shield",
		"shields:shield_steel",
		"3d_armor:shield_steel",
		"armor:shield_steel",
	})
end

function voxelibre_compat.is_crafting_table(node_name)
	if not node_name or node_name == "" then
		return false
	end
	if minetest.get_item_group(node_name, "crafting_table") > 0
			or minetest.get_item_group(node_name, "workbench") > 0 then
		return true
	end
	if voxelibre_compat.is_voxelibre then
		return node_name == "mcl_crafting_table:crafting_table"
	end
	return node_name == "crafting:workbench" or node_name == "mcl_inventory:workbench"
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
		if string.find(node_name, "mcl_chests:") ~= nil and string.find(node_name, "chest") ~= nil then
			return true
		end
		return string.find(node_name, "mcl_chest:") ~= nil and string.find(node_name, "chest") ~= nil
	else
		return node_name == "default:chest"
	end
end

-- Get the appropriate player model mesh for the current game.
-- VoxeLibre typically uses the mcl_armor_character meshes, while minetest_game uses character.b3d.
-- Note: VoxeLibre's mcl_armor_character mesh has built-in armor texture layers (3 texture slots),
-- but this mod uses PNG armor display via dummy entities instead for cross-game compatibility.
function voxelibre_compat.get_player_mesh(slim_arms)
	if voxelibre_compat.is_voxelibre then
		if slim_arms and mesh_available("mcl_armor", "models/mcl_armor_character_female.b3d") then
			return "mcl_armor_character_female.b3d"
		end
		if mesh_available("mcl_armor", "models/mcl_armor_character.b3d") then
			return "mcl_armor_character.b3d"
		end
	end

	if mesh_available("player_api", "models/character.b3d") or
		mesh_available("default", "models/character.b3d") or
		mesh_available("mcl_player", "models/character.b3d") then
		return "character.b3d"
	end

	minetest.log("warning", "[working_villages] No known player mesh found; falling back to character.b3d.")
	return "character.b3d"
end

--[[
  Format textures array for the given mesh.
  
  VoxeLibre armor meshes expect 3 texture slots: base_texture, armor_texture, wielditem_texture.
  For PNG armor display compatibility, we fill unused slots with "blank.png".
  The actual armor is displayed via dummy entities attached to bones, not via mesh textures.
  
  @param mesh_name string - Name of the mesh file
  @param base_texture string - Base skin texture
  @return table - Properly formatted textures array
]]--
function voxelibre_compat.format_textures(mesh_name, base_texture)
	if is_armor_mesh(mesh_name) then
		return {base_texture, "blank.png", "blank.png"}
	end
	return {base_texture}
end

function voxelibre_compat.get_player_skin(player)
	if not voxelibre_compat.is_voxelibre or not player or not player:is_player() then
		return nil
	end

	if mcl_skins and mcl_skins.player_skins and mcl_skins.compile_skin then
		local skin = mcl_skins.player_skins[player]
		if skin then
			local slim_arms = skin.slim_arms
			if skin.simple_skins_id and mcl_skins.texture_to_simple_skin then
				local simple = mcl_skins.texture_to_simple_skin[skin.simple_skins_id]
				if simple then
					slim_arms = simple.slim_arms
				end
			end
			local texture = mcl_skins.compile_skin(skin)
			if type(texture) == "string" and texture ~= "" then
				return {texture = texture, slim_arms = slim_arms}
			end
		end
	end

	if mcl_player and mcl_player.player_get_skin then
		local texture = mcl_player.player_get_skin(player)
		if type(texture) == "string" and texture ~= "" then
			return {texture = texture}
		end
	end

	return nil
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
		if minetest.get_modpath("mcl_sounds") and mcl_sounds and mcl_sounds.node_sound_wood_defaults then
			return mcl_sounds.node_sound_wood_defaults()
		end
	end
	
	-- Try minetest_game default wood sounds for signs
	-- This also serves as fallback if VoxeLibre is detected but mcl_sounds is not loaded
	local has_default = minetest.get_modpath("default")
	if has_default and default and default.node_sound_wood_defaults then
		return default.node_sound_wood_defaults()
	end
	
	-- Final fallback to generic default sounds if wood sounds not available
	if has_default and default and default.node_sound_defaults then
		return default.node_sound_defaults()
	end
	
	-- Return empty table if no sound system available
	return {}
end

-- Get GUI formspec elements compatible with current game
-- Returns appropriate GUI styling strings or empty strings
function voxelibre_compat.get_gui_bg()
	if minetest.get_modpath("default") and default and default.gui_bg then
		return default.gui_bg
	end
	-- VoxeLibre doesn't require gui_bg, return empty string
	return ""
end

function voxelibre_compat.get_gui_bg_img()
	if minetest.get_modpath("default") and default and default.gui_bg_img then
		return default.gui_bg_img
	end
	-- VoxeLibre doesn't require gui_bg_img, return empty string
	return ""
end

function voxelibre_compat.get_gui_slots()
	if minetest.get_modpath("default") and default and default.gui_slots then
		return default.gui_slots
	end
	-- VoxeLibre doesn't require gui_slots, return empty string
	return ""
end

return voxelibre_compat
