local func = working_villages.require("jobs/util")
local blueprints = working_villages.blueprints

local function find_tree(p)
	local adj_node = minetest.get_node(p)
	if minetest.get_item_group(adj_node.name, "tree") > 0 then
		-- FIXME: need a player name if villagers can own a protected area
		if minetest.is_protected(p, "") then return false end
		if working_villages.failed_pos_test(p) then return false end
		return true
	end
	return false
end

local function is_sapling(n)
	local name
	if type(n) == "table" then
		name = n.name
	else
		name = n
	end
	if minetest.get_item_group(name, "sapling") > 0 then
		return true
	end
	return false
end

local function is_sapling_spot(pos)
	-- FIXME: need a player name if villagers can own a protected area
	if minetest.is_protected(pos, "") then return false end
	if working_villages.failed_pos_test(pos) then return false end
	local lpos = vector.add(pos, {x = 0, y = -1, z = 0})
	local lnode = minetest.get_node(lpos)
	if minetest.get_item_group(lnode.name, "soil") == 0 then return false end
	local light_level = minetest.get_node_light(pos)
	if light_level <= 12 then return false end
	-- A sapling needs room to grow. Require a volume of air around the spot.
	for x = -1,1 do
		for z = -1,1 do
			for y = 0,2 do
				lpos = vector.add(pos, {x=x, y=y, z=z})
				lnode = minetest.get_node(lpos)
				if lnode.name ~= "air" then return false end
			end
		end
	end
	return true
end

-- Count trees in the area (for sustainable forestry)
local function count_nearby_trees(pos, radius)
	local count = 0
	for x = -radius, radius do
		for z = -radius, radius do
			for y = -2, 2 do
				local check_pos = vector.add(pos, {x=x, y=y, z=z})
				local node = minetest.get_node(check_pos)
				if minetest.get_item_group(node.name, "tree") > 0 then
					count = count + 1
				end
			end
		end
	end
	return count
end

local function put_func(_,stack)
  local name = stack:get_name();
  if (minetest.get_item_group(name, "axe")~=0)
      or (minetest.get_item_group(name, "food")~=0) then
    return false;
  end
  return true;
end
local function take_func(self,stack,data)
  return not put_func(self,stack,data);
end

local searching_range = {x = 10, y = 10, z = 10, h = 5}

working_villages.register_job("working_villages:job_woodcutter", {
	description      = "bucheron (working_villages)",
	long_description = "Je cherche des troncs d'arbres et je les coupe.\
Je peux aussi couper une maison par erreur, ne m'en veux pas.\
Quand je trouve un jeune arbre, je le plante pres d'un endroit lumineux. "..
"Je pratique une coupe durable et je gagne de l'experience.",
	inventory_image  = "default_paper.png^working_villages_woodcutter.png",
	capabilities = {
		tree_cutting = true,
		auto_replanting = true,
		sustainable_forestry = true,
		experience_gain = true,
		sapling_detection = true,
	},
	on_start = function(self)
		-- Notify player about woodcutter capabilities
		self:notify_job_feature(
			"Foresterie durable",
			"Coupe les arbres et replante automatiquement. Gagne de l'expérience."
		)
	end,
	jobfunc = function(self)
		self:handle_night()
		self:handle_chest(take_func, put_func)
		self:handle_job_pos()

		self:count_timer("woodcutter:search")
		self:count_timer("woodcutter:change_dir")
		self:count_timer("woodcutter:reforest")
		self:count_timer("woodcutter:announce")
		self:handle_obstacles()
		if self:timer_exceeded("woodcutter:search",20) then
			self:collect_nearest_item_by_condition(is_sapling, searching_range)
			local wield_stack = self:get_wield_item_stack()
			if is_sapling(wield_stack:get_name()) or self:has_item_in_main(is_sapling) then
				local target = func.search_surrounding(self.object:get_pos(), is_sapling_spot, searching_range)
				if target ~= nil then
					local destination = func.find_adjacent_clear(target)
					if destination==false then
						print("failure: no adjacent walkable found")
						destination = target
					end
					self:set_displayed_action("plante un arbre")
					self:go_to(destination)
					local success, ret = self:place(is_sapling, target)
					if not success then
						working_villages.failed_pos_record(target)
						self:set_displayed_action("confus, la plantation a echoue")
						self:delay(100)
					else
						-- Award experience for planting trees (reforestation)
						local inv_name = self:get_inventory_name()
						blueprints.add_experience(inv_name, 1)
						if self:timer_exceeded("woodcutter:announce", 150) then
							self:announce_action("Je plante des jeunes arbres pour renouveler la foret.")
						end
					end
				end
			end
			local target = func.search_surrounding(self.object:get_pos(), find_tree, searching_range)
			if target ~= nil then
				-- Check tree density for sustainable forestry
				local tree_count = count_nearby_trees(target, 5)
				if tree_count < 3 then
					-- Too few trees nearby, skip cutting and plant more
					self:set_state_info("Je preserve la foret : pas assez d'arbres. Je vais planter.")
					self:set_displayed_action("forestier responsable")
					self:announce_action("Je protege la foret en plantant plus d'arbres.", 180)
				else
					local destination = func.find_adjacent_clear(target)
					destination = func.find_ground_below(destination)
					if destination==false then
						print("failure: no adjacent walkable found")
						destination = target
					end
					self:set_displayed_action("coupe un arbre")
					-- We may not be able to reach the log
					local success, ret = self:go_to(destination)
					if not success then
						working_villages.failed_pos_record(target)
						self:set_displayed_action("regarde un tronc inaccessible")
						self:delay(100)
					else
						success, ret = self:dig(target,true)
						if not success then
							working_villages.failed_pos_record(target)
							self:set_displayed_action("confus, la coupe a echoue")
							self:delay(100)
						else
							-- Award experience for cutting trees
							local inv_name = self:get_inventory_name()
							blueprints.add_experience(inv_name, 1)
							if self:timer_exceeded("woodcutter:announce", 150) then
								self:announce_action("Je coupe des arbres pour le bois de construction.")
							end
						end
					end
				end
			end
			self:set_displayed_action("cherche du travail")
		elseif self:timer_exceeded("woodcutter:reforest", 200) then
			-- Periodically focus on reforestation
			if self:has_item_in_main(is_sapling) then
				local target = func.search_surrounding(self.object:get_pos(), is_sapling_spot, searching_range)
				if target then
					self:set_displayed_action("reboise la zone")
					self:set_state_info("Je plante des arbres pour garder la foret.")
				end
			end
		elseif self:timer_exceeded("woodcutter:change_dir",50) then
			self:change_direction_randomly()
		end
	end,
})
