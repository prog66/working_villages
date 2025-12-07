-- add groups for some nodes to be managed by working_villagers

local compat = working_villages.require("voxelibre_compat")

local list_of_doors = compat.get_door_items()

for _,name in pairs(list_of_doors) do
	local item_def = minetest.registered_items[name]
	if (item_def~=nil) then
		local groups = table.copy(item_def.groups)
		groups.villager_door = 1
		minetest.override_item(name, {groups=groups})
	end
end

local list_of_chests = compat.get_chest_items()

for _,name in pairs(list_of_chests) do
	local item_def = minetest.registered_items[name]
	if (item_def~=nil) then
		local groups = table.copy(item_def.groups)
		groups.villager_chest = 1
		minetest.override_item(name, {groups=groups})
	end
end

local list_of_bed_top = compat.get_bed_top_items()
for _,name in pairs(list_of_bed_top) do
	local item_def = minetest.registered_items[name]
	if (item_def~=nil) then
		local groups = table.copy(item_def.groups)
		groups.villager_bed_top = 1
		minetest.override_item(name, {groups=groups})
	end
end

local list_of_bed_bottom = compat.get_bed_bottom_items()
for _,name in pairs(list_of_bed_bottom) do
	local item_def = minetest.registered_items[name]
	if (item_def~=nil) then
		local groups = table.copy(item_def.groups)
		groups.villager_bed_bottom = 1
		minetest.override_item(name, {groups=groups})
	end
end

