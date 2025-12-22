local func = working_villages.require("jobs/util")
local farming_compat = working_villages.require("farming_compat")

local searching_range = {x = 12, y = 4, z = 12}
local item_range = {x = 6, y = 2, z = 6}
local explore_radius = tonumber(minetest.settings:get("working_villages_autonomous_explore_radius")) or 10

local function is_keep_item(name)
	if minetest.get_item_group(name, "axe") > 0 then return true end
	if minetest.get_item_group(name, "pickaxe") > 0 then return true end
	if minetest.get_item_group(name, "hoe") > 0 then return true end
	if minetest.get_item_group(name, "sapling") > 0 then return true end
	if minetest.get_item_group(name, "seed") > 0 then return true end
	if minetest.get_item_group(name, "food") > 0 then return true end
	return false
end

local function put_func(_, stack)
	return not is_keep_item(stack:get_name())
end

local function take_func(self, stack)
	local name = stack:get_name()
	if not is_keep_item(name) then
		return false
	end
	local inv = self:get_inventory()
	return not inv:contains_item("main", ItemStack(name))
end

local function find_tree(self, pos)
	local node = minetest.get_node(pos)
	if minetest.get_item_group(node.name, "tree") <= 0 then
		return false
	end
	if func.is_protected(self, pos) then
		return false
	end
	if working_villages.failed_pos_test(pos) then
		return false
	end
	return true
end

local function find_crop(self, pos)
	if not farming_compat.is_plant_node(pos) then
		return false
	end
	if func.is_protected(self, pos) then
		return false
	end
	if working_villages.failed_pos_test(pos) then
		return false
	end
	return true
end

local function set_action(self, action, info, say_msg)
	if action then
		self:set_displayed_action(action)
	end
	if info then
		self:set_state_info(info)
	end
	if say_msg and self.autonomous_action ~= action then
		self.autonomous_action = action
		self:say(say_msg)
	end
end

local function harvest_crop(self, target)
	local destination = func.find_adjacent_clear(target)
	if destination then
		destination = func.find_ground_below(destination)
	end
	if destination == false then
		destination = target
	end
	set_action(self, "recolte des cultures", "Je recolte des cultures.", "Je recolte des cultures.")
	local success = self:go_to(destination)
	if not success then
		working_villages.failed_pos_record(target)
		return false
	end
	local plant_name = minetest.get_node(target).name
	local plant_data = farming_compat.get_plant(plant_name)
	success = self:dig(target, true)
	if not success then
		working_villages.failed_pos_record(target)
		return false
	end
	if plant_data and plant_data.replant then
		for index, value in ipairs(plant_data.replant) do
			self:place(value, vector.add(target, vector.new(0, index - 1, 0)))
		end
	end
	return true
end

local function chop_tree(self, target)
	local destination = func.find_adjacent_clear(target)
	if destination then
		destination = func.find_ground_below(destination)
	end
	if destination == false then
		destination = target
	end
	set_action(self, "coupe du bois", "Je coupe du bois.", "Je coupe du bois.")
	local success = self:go_to(destination)
	if not success then
		working_villages.failed_pos_record(target)
		return false
	end
	success = self:dig(target, true)
	if not success then
		working_villages.failed_pos_record(target)
		return false
	end
	return true
end

local function pick_explore_target(self)
	local base = vector.round(self.object:get_pos())
	local dx = math.random(-explore_radius, explore_radius)
	local dz = math.random(-explore_radius, explore_radius)
	local pos = {x = base.x + dx, y = base.y + 2, z = base.z + dz}
	local ground = func.find_ground_below(pos)
	return ground or base
end

working_villages.register_job("working_villages:job_autonome", {
	description      = "autonome (working_villages)",
	long_description = "Je fais un peu de tout : j'explore, je recolte, je coupe du bois et je ramasse ce qui traine. " ..
		"Je travaille seul et je m'arrete pour discuter, sans spam.",
	inventory_image  = "default_paper.png^working_villages_builder.png",
	jobfunc = function(self)
		self:handle_night()
		self:handle_chest(take_func, put_func)
		self:handle_obstacles()

		self:count_timer("autonome:search")
		self:count_timer("autonome:explore")
		self:count_timer("autonome:change_dir")

		if self:timer_exceeded("autonome:search", 20) then
			local target = func.search_surrounding(
				self.object:get_pos(),
				function(pos) return find_crop(self, pos) end,
				searching_range
			)
			if target and harvest_crop(self, target) then
				return
			end

			target = func.search_surrounding(
				self.object:get_pos(),
				function(pos) return find_tree(self, pos) end,
				searching_range
			)
			if target and chop_tree(self, target) then
				return
			end

			if self:collect_nearest_item_by_condition(function() return true end, item_range) then
				set_action(self, "ramasse des objets", "Je ramasse ce que je trouve.", "Je ramasse ce que je trouve.")
				return
			end
		end

		if self:timer_exceeded("autonome:explore", 80) then
			local destination = pick_explore_target(self)
			set_action(self, "explore", "J'explore les alentours.", "J'explore les alentours.")
			self:go_to(destination)
			return
		end

		if self:timer_exceeded("autonome:change_dir", 50) then
			set_action(self, "cherche quelque chose a faire", "Je cherche quelque chose a faire.", nil)
			self:change_direction_randomly()
		end
	end,
})
