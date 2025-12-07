-- Farming Compatibility Module
-- This module provides compatibility between farming mod (minetest_game) and mcl_farming (VoxeLibre)

local farming_compat = {}
local compat = working_villages.voxelibre_compat

-- Check if VoxeLibre farming is available
farming_compat.is_voxelibre = compat.is_voxelibre
farming_compat.has_farming = minetest.get_modpath("farming") ~= nil
farming_compat.has_mcl_farming = minetest.get_modpath("mcl_farming") ~= nil

-- Define plant configurations for minetest_game farming mod
local minetest_game_plants = {
	["farming:artichoke_5"]={replant={"farming:artichoke"}},
	["farming:barley_7"]={replant={"farming:seed_barley"}},
	["farming:beanpole_5"]={replant={"farming:beanpole","farming:beans"}},
	["farming:beetroot_5"]={replant={"farming:beetroot"}},
	["farming:blackberry_4"]={replant={"farming:blackberry"}},
	["farming:blueberry_4"]={replant={"farming:blueberries"}},
	["farming:cabbage_6"]={replant={"farming:cabbage"}},
	["farming:carrot_8"]={replant={"farming:carrot"}},
	["farming:chili_8"]={replant={"farming:chili_pepper"}},
	["farming:cocoa_4"]={replant={"farming:cocoa_beans"}},
	["farming:coffee_5"]={replant={"farming:coffee_beans"}},
	["farming:corn_8"]={replant={"farming:corn"}},
	["farming:cotton_8"]={replant={"farming:seed_cotton"}},
	["farming:cucumber_4"]={replant={"farming:cucumber"}},
	["farming:garlic_5"]={replant={"farming:garlic_clove"}},
	["farming:grapes_8"]={replant={"farming:trellis","farming:grapes"}},
	["farming:hemp_8"]={replant={"farming:seed_hemp"}},
	["farming:lettuce_5"]={replant={"farming:lettuce"}},
	["farming:melon_8"]={replant={"farming:melon_slice"}},
	["farming:mint_4"]={replant={"farming:seed_mint"}},
	["farming:oat_8"]={replant={"farming:seed_oat"}},
	["farming:onion_5"]={replant={"farming:onion"}},
	["farming:parsley_3"]={replant={"farming:parsley"}},
	["farming:pea_5"]={replant={"farming:pea_pod"}},
	["farming:pepper_7"]={replant={"farming:peppercorn"}},
	["farming:pineapple_8"]={replant={"farming:pineapple_top"}},
	["farming:potato_4"]={replant={"farming:potato"}},
	["farming:pumpkin_8"]={replant={"farming:pumpkin_slice"}},
	["farming:raspberry_4"]={replant={"farming:raspberries"}},
	["farming:rhubarb_3"]={replant={"farming:rhubarb"}},
	["farming:rice_8"]={replant={"farming:seed_rice"}},
	["farming:rye_8"]={replant={"farming:seed_rye"}},
	["farming:soy_7"]={replant={"farming:soy_pod"}},
	["farming:sunflower_8"]={replant={"farming:seed_sunflower"}},
	["farming:tomato_8"]={replant={"farming:tomato"}},
	["farming:vanilla_8"]={replant={"farming:vanilla"}},
	["farming:wheat_8"]={replant={"farming:seed_wheat"}},
}

local minetest_game_demands = {
	["farming:beanpole"] = 99,
	["farming:trellis"] = 99,
}

-- Define plant configurations for VoxeLibre mcl_farming
-- VoxeLibre uses different growth stages (0-7 for most crops)
local voxelibre_plants = {
	-- Wheat (7 growth stages)
	["mcl_farming:wheat_7"]={replant={"mcl_farming:wheat_seeds"}},
	-- Carrots (7 growth stages)
	["mcl_farming:carrot_7"]={replant={"mcl_farming:carrot_item"}},
	-- Potatoes (7 growth stages)  
	["mcl_farming:potato_7"]={replant={"mcl_farming:potato_item"}},
	-- Beetroot (7 growth stages)
	["mcl_farming:beetroot_7"]={replant={"mcl_farming:beetroot_seeds"}},
	-- Melon (stem growth)
	["mcl_farming:melon"]={replant={}}, -- Melons don't replant, just harvest
	-- Pumpkin (stem growth)
	["mcl_farming:pumpkin"]={replant={}}, -- Pumpkins don't replant, just harvest
}

local voxelibre_demands = {
	-- VoxeLibre doesn't typically use support structures like beanpoles
}

-- Get the active plant database based on the game
function farming_compat.get_plants()
	if farming_compat.is_voxelibre and farming_compat.has_mcl_farming then
		return voxelibre_plants
	elseif farming_compat.has_farming then
		return minetest_game_plants
	end
	return {}
end

-- Get the active demands database based on the game
function farming_compat.get_demands()
	if farming_compat.is_voxelibre and farming_compat.has_mcl_farming then
		return voxelibre_demands
	elseif farming_compat.has_farming then
		return minetest_game_demands
	end
	return {}
end

-- Get plant data for a specific item
function farming_compat.get_plant(item_name)
	local plants = farming_compat.get_plants()
	for key, value in pairs(plants) do
		if item_name == key then
			return value
		end
	end
	return nil
end

-- Check if an item is a farmable plant
function farming_compat.is_plant(item_name)
	local data = farming_compat.get_plant(item_name)
	return data ~= nil
end

-- Check if a node at a position is a farmable plant
function farming_compat.is_plant_node(pos)
	local node = minetest.get_node(pos)
	return farming_compat.is_plant(node.name)
end

return farming_compat
