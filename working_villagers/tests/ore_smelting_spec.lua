-- Engine-backed regression for canonical ore drops and real cooking recipes.
-- Run in a disposable world after working_villages has loaded with:
--   dofile(minetest.get_modpath("working_villages").."/tests/ore_smelting_spec.lua").run()

local compat = working_villages.compat or working_villages.voxelibre_compat

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": got " .. tostring(actual)
			.. ", expected " .. tostring(expected), 2)
	end
end

local function assert_smelt(input_name, output_name)
	assert(minetest.registered_items[input_name], "missing registered input " .. input_name)
	assert(minetest.registered_items[output_name], "missing registered output " .. output_name)
	assert(compat.is_metal_smelting_input(input_name), input_name .. " was not recognized as metal ore")
	-- Exercise the ItemStack path too: production furnace code passes userdata,
	-- not only item-name strings.
	assert(compat.is_metal_smelting_input(ItemStack(input_name)),
		input_name .. " ItemStack was not recognized as metal ore")
	local output = compat.get_metal_smelt_result(ItemStack(input_name .. " 4"))
	assert(output and not output:is_empty(), input_name .. " has no accepted cooking result")
	assert_equal(output:get_name(), output_name, input_name .. " cooking output")
	assert_equal(output:get_count(), 1, input_name .. " must be tested one unit at a time")
	assert(compat.is_metal_ingot(output), output_name .. " was not recognized as an ingot")
end

local function run()
	assert(type(compat.get_metal_smelt_result) == "function", "metal recipe helper is missing")
	assert(type(compat.is_metal_smelting_input) == "function", "metal input helper is missing")
	assert(type(compat.is_metal_ingot) == "function", "metal ingot helper is missing")

	local profile = compat.game_profile and compat.game_profile.id
	if profile == "voxelibre" then
		assert_smelt("mcl_raw_ores:raw_iron", "mcl_core:iron_ingot")
		assert_smelt("mcl_raw_ores:raw_gold", "mcl_core:gold_ingot")
		assert_smelt("mcl_copper:raw_copper", "mcl_copper:copper_ingot")
	elseif profile == "minetest_game" then
		assert_smelt("default:iron_lump", "default:steel_ingot")
		assert_smelt("default:gold_lump", "default:gold_ingot")
		assert_smelt("default:copper_lump", "default:copper_ingot")
	else
		error("unsupported test profile " .. tostring(profile))
	end

	local stone = compat.get_item("default:stone")
	assert_equal(compat.is_metal_smelting_input(stone), false,
		"ordinary stone was mistaken for furnace metal input")
	assert_equal(compat.is_metal_ingot(stone), false,
		"ordinary stone was mistaken for an ingot")

	minetest.log("action", "ORE_SMELTING_RECIPES_OK:" .. profile)
end

return {run = run}
