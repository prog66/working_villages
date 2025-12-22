
local func = working_villages.require("jobs/util")
local farming_compat = working_villages.require("farming_compat")
local blueprints = working_villages.blueprints
local compat = working_villages.voxelibre_compat

-- Use the compatibility layer for plant definitions
local farming_plants = farming_compat
local farming_demands = farming_compat.get_demands()
local farming_data = farming_compat.get_plants()
local seed_items = {}
for _, plant in pairs(farming_data) do
	for _, seed in ipairs(plant.replant or {}) do
		seed_items[seed] = true
	end
end

local function find_plant_node(pos)
	return farming_compat.is_plant_node(pos)
end

local function has_seed(name)
	return seed_items[name]
end

local function find_seed_in_inventory(self, preferred)
	local inv = self:get_inventory()
	if preferred then
		for _, stack in ipairs(inv:get_list("main")) do
			if not stack:is_empty() and stack:get_name() == preferred then
				return preferred
			end
		end
	end
	for _, stack in ipairs(inv:get_list("main")) do
		if not stack:is_empty() and has_seed(stack:get_name()) then
			return stack:get_name()
		end
	end
	return nil
end

local function ensure_farmer_tool(self)
	local tool_candidates = {
		compat.get_item("default:hoe_steel"),
		compat.get_item("default:hoe_stone"),
		compat.get_item("default:hoe_wood"),
	}
	local inv = self:get_inventory()
	local wield_name = self:get_wield_item_stack():get_name()

	for _, candidate in ipairs(tool_candidates) do
		if candidate and candidate ~= "" and minetest.registered_items[candidate] then
			if wield_name == candidate then
				return true
			end
			if self:move_main_to_wield(function(name) return name == candidate end) then
				return true
			end
			local leftover = inv:add_item("main", ItemStack(candidate))
			if leftover:is_empty() then
				self:move_main_to_wield(function(name) return name == candidate end)
				return true
			end
		end
	end
	return false
end

local function attempt_plant_seed(self, pos, seed_name)
	if not seed_name or seed_name == "" then
		return false
	end
	if not is_farmland(pos) then
		return false
	end
	self:set_state_info("Je replante des graines.")
	self:set_displayed_action("replante des graines")
	return self:place(seed_name, pos)
end

local function try_replant(self, target, seed_list)
	if not target then
		return false
	end
	if seed_list then
		for _, seed in ipairs(seed_list) do
			if seed and attempt_plant_seed(self, target, find_seed_in_inventory(self, seed)) then
				return true
			end
		end
	end
	local fallback = find_seed_in_inventory(self)
	return attempt_plant_seed(self, target, fallback)
end

local searching_range = {x = 10, y = 3, z = 10}
local seed_collection_range = {x = 2, y = 1, z = 2}

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
	if has_seed(item_name) then
		local inv = villager:get_inventory()
		if not inv:contains_item("main", ItemStack(item_name)) then
			return true
		end
	end
	return false
end

working_villages.register_job("working_villages:job_farmer", {
	description			= "fermier (working_villages)",
	long_description = "Je cherche des cultures a recolter et replanter. "..
		"Je peux aussi preparer de nouvelles terres et gagner de l'experience en recoltant. "..
		"Avec l'experience, j'apprends a faire de meilleures fermes.",
	inventory_image	= "default_paper.png^working_villages_farmer.png",
	jobfunc = function(self)
		self:handle_night()
		self:handle_chest(take_func, put_func)
		self:handle_job_pos()

		ensure_farmer_tool(self)
		self:collect_nearest_item_by_condition(
			function(item) return has_seed(item.name) end,
			searching_range
		)

		self:count_timer("farmer:search")
		self:count_timer("farmer:change_dir")
		self:count_timer("farmer:expand_farm")
		self:count_timer("farmer:announce")
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
				local plant_data = farming_plants.get_plant(minetest.get_node(target).name)
				self:dig(target,true)
				self:collect_nearest_item_by_condition(
					function(item) return has_seed(item.name) end,
					seed_collection_range
				)
				local replanted = try_replant(self, target, plant_data and plant_data.replant)
				if replanted then
					local inv_name = self:get_inventory_name()
					blueprints.add_experience(inv_name, 1)
					self:set_displayed_action("recolte des cultures")
					-- Announce farming activity periodically
					if self:timer_exceeded("farmer:announce", 120) then
						self:announce_action("Je recolte et replante les cultures.")
					end
				else
					self:set_state_info("Je cherche des graines pour replanter.")
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
						self:set_displayed_action("prepare les cultures")
						self:go_to(destination)
						-- In a future enhancement, could use a hoe to till the soil
						self:set_state_info("J'ai trouve un terrain a preparer.")
						self:announce_action("Je prepare de nouvelles terres cultivables.", 120)
					end
				end
			end
		elseif self:timer_exceeded("farmer:change_dir",50) then
			self:change_direction_randomly()
		end
	end,
})

working_villages.farming_plants = farming_plants
