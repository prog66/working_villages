local OWNER = "working_villages_village_runtime_test_owner"
local compat = assert(working_villages.compat or working_villages.voxelibre_compat)

local function inventory_names(inv)
	local result = {}
	for list_name, list in pairs(inv and inv:get_lists() or {}) do
		for _, stack in ipairs(list or {}) do
			if not stack:is_empty() then
				local key = list_name .. ":" .. stack:get_name()
				result[key] = (result[key] or 0) + stack:get_count()
			end
		end
	end
	return result
end

local function inspect()
	minetest.load_area({x = -28, y = -8, z = -28}, {x = 28, y = 16, z = 28})
	local villagers = {}
	local entity_count = 0
	for _, lua in pairs(minetest.luaentities or {}) do
		entity_count = entity_count + 1
		if lua and type(lua.get_inventory) == "function"
				and type(lua.get_job_name) == "function" then
			villagers[#villagers + 1] = lua
		end
	end
	table.sort(villagers, function(a, b)
		return tostring(a.inventory_name) < tostring(b.inventory_name)
	end)
	minetest.log("action", "VILLAGE_INSPECT_VILLAGERS:" .. #villagers
		.. ":all_luaentities=" .. entity_count)
	for _, villager in ipairs(villagers) do
		minetest.log("action", "VILLAGE_INSPECT_ENTITY:id="
			.. tostring(villager.inventory_name)
			.. ":owner=" .. tostring(villager.owner_name)
			.. ":entity_name=" .. tostring(villager.name)
			.. ":job=" .. tostring(villager.get_job_name and villager:get_job_name() or "")
			.. ":action=" .. tostring(villager.disp_action)
			.. ":pos=" .. minetest.pos_to_string(vector.round(villager.object:get_pos()), 0)
			.. ":inventory=" .. minetest.serialize(inventory_names(villager:get_inventory()))
			.. ":craft_failures=" .. minetest.serialize(
				villager.job_data and villager.job_data.crafting_failures or {}))
	end

	local chest = working_villages.get_shared_storage_pos(OWNER)
	minetest.log("action", "VILLAGE_INSPECT_CHEST:pos="
		.. tostring(chest and minetest.pos_to_string(chest, 0) or "none")
		.. ":node=" .. tostring(chest and minetest.get_node(chest).name or "none")
		.. ":inventory=" .. minetest.serialize(chest
			and inventory_names(minetest.get_meta(chest):get_inventory()) or {}))

	local quarry = {stone = 0, ore = 0, air = 0, other = {}}
	local stone_name = compat.get_item("default:stone")
	local ore_name = compat.get_item("default:stone_with_iron")
	for _, x in ipairs({-8, 8}) do
		for z = -3, 3 do
			for y = 1, 2 do
				local name = minetest.get_node({x = x, y = y, z = z}).name
				if name == stone_name then quarry.stone = quarry.stone + 1
				elseif name == ore_name then quarry.ore = quarry.ore + 1
				elseif name == "air" then quarry.air = quarry.air + 1
				else quarry.other[name] = (quarry.other[name] or 0) + 1 end
			end
		end
	end
	minetest.log("action", "VILLAGE_INSPECT_QUARRY:" .. minetest.serialize(quarry))
	local foundation = {air = 0, air_by_y = {}, non_stone = 0, examples = {}}
	for x = -23, 23 do
		for z = -23, 23 do
			for y = -8, -1 do
				local name = minetest.get_node({x = x, y = y, z = z}).name
				if name == "air" then
					foundation.air = foundation.air + 1
					foundation.air_by_y[y] = (foundation.air_by_y[y] or 0) + 1
					if #foundation.examples < 12 then
						foundation.examples[#foundation.examples + 1] = {x = x, y = y, z = z}
					end
				elseif name ~= stone_name then
					foundation.non_stone = foundation.non_stone + 1
				end
			end
		end
	end
	minetest.log("action", "VILLAGE_INSPECT_FOUNDATION:"
		.. minetest.serialize(foundation))
	if villagers[1] then
		local status = working_villages.get_village_status(villagers[1], 40)
		minetest.log("action", "VILLAGE_INSPECT_STATUS:" .. minetest.serialize(status))
	end
	minetest.request_shutdown("village inspection complete", false, 0)
end

minetest.register_on_mods_loaded(function()
	minetest.after(8, inspect)
end)
