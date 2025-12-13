
local func = working_villages.require("jobs/util")
local farming_compat = working_villages.require("farming_compat")
local blueprints = working_villages.blueprints
local compat = working_villages.voxelibre_compat

-- Use the compatibility layer for plant definitions
local farming_plants = farming_compat
local farming_demands = farming_compat.get_demands()

local function find_plant_node(pos)
	return farming_compat.is_plant_node(pos)
end

local searching_range = {x = 10, y = 3, z = 10}

-- Check if a position is suitable for farming (has soil below)
local function is_farmland(pos)
	local node_below = minetest.get_node(vector.add(pos, {x=0, y=-1, z=0}))
	return minetest.get_item_group(node_below.name, "soil") > 0
end

-- Find unfarmed but suitable land
local function find_tillable_soil(p)
	local node = minetest.get_node(p)
	if node.name ~= "air" then
		return false
	end
	
	local below = minetest.get_node(vector.add(p, {x=0, y=-1, z=0}))
	-- Check for dirt or grass that can be tilled
	if compat.is_voxelibre then
		return below.name == "mcl_core:dirt" or below.name:find("mcl_core:dirt_with_grass")
	else
		return below.name == "default:dirt" or below.name:find("default:dirt_with_grass")
	end
end

local function put_func(_,stack)
	if farming_demands[stack:get_name()] then
		return false
	end
	return true;
end
local function take_func(villager,stack)
	local item_name = stack:get_name()
	if farming_demands[item_name] then
		local inv = villager:get_inventory()
		local itemstack = ItemStack(item_name)
		itemstack:set_count(farming_demands[item_name])
		if (not inv:contains_item("main", itemstack)) then
			return true
		end
	end
	return false
end

working_villages.register_job("working_villages:job_farmer", {
	description			= "farmer (working_villages)",
	long_description = "I look for farming plants to collect and replant them. "..
		"I can also prepare new farmland and gain experience from successful harvests. "..
		"With experience, I can learn to build better farms and improve crop yields.",
	inventory_image	= "default_paper.png^working_villages_farmer.png",
	jobfunc = function(self)
		self:handle_night()
		self:handle_chest(take_func, put_func)
		self:handle_job_pos()

		self:count_timer("farmer:search")
		self:count_timer("farmer:change_dir")
		self:count_timer("farmer:expand_farm")
		self:handle_obstacles()
		if self:timer_exceeded("farmer:search",20) then
			self:collect_nearest_item_by_condition(farming_plants.is_plant, searching_range)
			local target = func.search_surrounding(self.object:get_pos(), find_plant_node, searching_range)
			if target ~= nil then
				local destination = func.find_adjacent_clear(target)
				if destination then
					destination = func.find_ground_below(destination)
				end
				if destination==false then
					print("failure: no adjacent walkable found")
					destination = target
				end
				self:go_to(destination)
				local plant_data = farming_plants.get_plant(minetest.get_node(target).name);
				self:dig(target,true)
				if plant_data and plant_data.replant then
					for index, value in ipairs(plant_data.replant) do
						self:place(value, vector.add(target, vector.new(0,index-1,0)))
					end
					-- Award experience for successful harvest and replant
					local inv_name = self:get_inventory_name()
					blueprints.add_experience(inv_name, 1)
					self:set_displayed_action("harvesting crops")
				end
			end
		elseif self:timer_exceeded("farmer:expand_farm", 100) then
			-- Occasionally try to expand farmland
			local tillable = func.search_surrounding(self.object:get_pos(), find_tillable_soil, searching_range)
			if tillable then
				local destination = func.find_adjacent_clear(tillable)
				if destination then
					destination = func.find_ground_below(destination)
					if destination ~= false then
						self:set_displayed_action("preparing farmland")
						self:go_to(destination)
						-- In a future enhancement, could use a hoe to till the soil
						self:set_state_info("Found potential farmland to expand.")
					end
				end
			end
		elseif self:timer_exceeded("farmer:change_dir",50) then
			self:change_direction_randomly()
		end
	end,
})

working_villages.farming_plants = farming_plants
