local func = working_villages.require("jobs/util")
local compat = working_villages.voxelibre_compat
local crafting = working_villages.crafting
local creative_test_mode = working_villages.gameplay_mode == "creative_test"
local inventory_access = working_villages.inventory_access or working_villages.require("inventory_access")

local searching_range = {x = 12, y = 3, z = 12}
local take_batch = 4
local furnace_check_interval = 20
local active_furnace_ttl = 20
local furnace_bootstrap_interval = 40
local furnace_interaction_range = 3.5
local furnace_item_candidates = compat.get_furnace_item_candidates()

local function same_pos(left, right)
	return left and right and left.x == right.x and left.y == right.y and left.z == right.z
end

local function clear_reserved_furnace(self)
	if self.job_data and self.job_data.cook_furnace_pos and self.release_reserved_position then
		self:release_reserved_position("active_furnace", self.job_data.cook_furnace_pos)
		self.job_data.cook_furnace_pos = nil
	end
end

local function clear_reserved_furnace_site(self)
	if self.job_data and self.job_data.cook_furnace_site and self.release_reserved_position then
		self:release_reserved_position("utility_furnace_site", self.job_data.cook_furnace_site)
	end
	if self.job_data then
		self.job_data.cook_furnace_site = nil
	end
end

local function get_reserved_furnace(self)
	local pos = self.job_data and self.job_data.cook_furnace_pos or nil
	if pos and func.is_furnace(pos) then
		return vector.round(pos)
	end
	clear_reserved_furnace(self)
	return nil
end

local function claim_furnace(self, furnace_pos)
	if not furnace_pos or not self.reserve_position then
		return furnace_pos ~= nil
	end
	self.job_data = self.job_data or {}
	furnace_pos = vector.round(furnace_pos)
	if self.job_data.cook_furnace_pos and not same_pos(self.job_data.cook_furnace_pos, furnace_pos) then
		clear_reserved_furnace(self)
	end
	local ok = self:reserve_position("active_furnace", furnace_pos, active_furnace_ttl)
	if ok then
		self.job_data.cook_furnace_pos = furnace_pos
	end
	return ok
end

local function can_place_furnace(self, pos)
	pos = vector.round(pos)
	if func.is_protected(self, pos) or working_villages.failed_pos_test(pos) then
		return false
	end
	if self.is_position_reserved and self:is_position_reserved("utility_furnace_site", pos) then
		return false
	end
	if func.is_furnace(pos) then
		return false
	end
	local node = minetest.get_node_or_nil(pos)
	local below = minetest.get_node_or_nil(vector.add(pos, {x = 0, y = -1, z = 0}))
	if not node or not below then
		return false
	end
	local node_def = minetest.registered_nodes[node.name]
	if not node_def or not node_def.buildable_to then
		return false
	end
	if minetest.get_item_group(below.name, "liquid") > 0 or not func.walkable_pos(vector.add(pos, {x = 0, y = -1, z = 0})) then
		return false
	end
	return func.find_adjacent_clear(pos) ~= false
end

local function find_furnace_site(self)
	local origin = vector.round(
		(self.pos_data and (self.pos_data.job_pos or self.pos_data.storage_pos or self.pos_data.home_pos))
		or self.object:get_pos()
	)
	return func.search_surrounding(origin, function(pos)
		return can_place_furnace(self, pos)
	end, {x = 4, y = 1, z = 4, h = 1})
end

local function ensure_furnace_workspace(self)
	local existing = func.find_nearby_furnace(self, self.object:get_pos(), searching_range, "active_furnace")
	if existing then
		clear_reserved_furnace_site(self)
		return existing, false
	end

	self.job_data = self.job_data or {}
	local wield_name = self:get_wield_item_stack():get_name()
	local has_furnace_item = false
	for _, candidate in ipairs(furnace_item_candidates) do
		if wield_name == candidate or self:has_item_in_main(function(name) return name == candidate end) then
			has_furnace_item = true
			break
		end
	end
	local pending_site = self.job_data.cook_furnace_site ~= nil
	self:count_timer("cook:furnace_bootstrap")
	if not pending_site and not has_furnace_item and not self:timer_exceeded("cook:furnace_bootstrap", furnace_bootstrap_interval) then
		return nil, false
	end
	if not crafting or #furnace_item_candidates == 0 then
		return nil, false
	end

	local furnace_item = nil
	for _, candidate in ipairs(furnace_item_candidates) do
		if wield_name == candidate or self:has_item_in_main(function(name) return name == candidate end) then
			furnace_item = candidate
			break
		end
	end
	if not furnace_item then
		furnace_item = crafting.ensure_any_item(self, furnace_item_candidates, 1, {
			use_shared_storage = true,
			fail_cooldown = 10,
			max_depth = 4,
		})
	end
	if not furnace_item then
		return nil, false
	end

	local site = self.job_data.cook_furnace_site and vector.round(self.job_data.cook_furnace_site) or find_furnace_site(self)
	if not site then
		return nil, false
	end
	if self.reserve_position and not self:reserve_position("utility_furnace_site", site, 20) then
		return nil, false
	end
	self.job_data.cook_furnace_site = vector.round(site)

	local destination = func.find_adjacent_clear(site)
	if destination then
		destination = func.find_ground_below(destination) or destination
	end
	if destination and vector.distance(self.object:get_pos(), destination) > 4 then
		self:set_displayed_action("installe un four")
		self:set_state_info("Je prepare un four pour cuisiner.")
		local reached = self:go_to(destination)
		if not reached then
			working_villages.failed_pos_record(site)
			clear_reserved_furnace_site(self)
			return nil, false
		end
		return nil, true
	end

	self:set_displayed_action("installe un four")
	self:set_state_info("J'installe un four pour le village.")
	local placed = self:place(furnace_item, site)
	clear_reserved_furnace_site(self)
	if placed and func.is_furnace(site) then
		return site, true
	end
	if not placed then
		working_villages.failed_pos_record(site)
	end
	return nil, placed or false
end

local function is_cookable_food(stack)
	if stack:is_empty() then
		return false
	end
	local name = stack:get_name()
	if minetest.get_item_group(name, "food_raw") > 0 then
		return true
	end
	local cooked = minetest.get_craft_result({
		method = "cooking",
		width = 1,
		items = {stack},
	})
	if cooked and cooked.item and not cooked.item:is_empty() then
		return minetest.get_item_group(cooked.item:get_name(), "food") > 0
	end
	return false
end

local function is_fuel_item(name)
	if not name or name == "" then
		return false
	end
	local fuel = minetest.get_craft_result({
		method = "fuel",
		width = 1,
		items = {ItemStack(name)},
	})
	return fuel and fuel.time and fuel.time > 0
end

local function find_fuel_in_inventory(self)
	local inv = self:get_inventory()
	for i = 1, inv:get_size("main") do
		local stack = inv:get_stack("main", i)
		if not stack:is_empty() and is_fuel_item(stack:get_name()) then
			return i
		end
	end
	return nil
end

local function ensure_fuel_index(self)
	local index = find_fuel_in_inventory(self)
	if index then
		return index
	end
	if self.take_from_shared_storage_by_predicate then
		self:take_from_shared_storage_by_predicate(function(name)
			return is_fuel_item(name)
		end, 1)
		return find_fuel_in_inventory(self)
	end
	return nil
end

local function cook_one(self)
	local inv = self:get_inventory()
	for i = 1, inv:get_size("main") do
		local stack = inv:get_stack("main", i)
		if is_cookable_food(stack) then
			local cooked = minetest.get_craft_result({
				method = "cooking",
				width = 1,
				items = {stack},
			})
			if cooked and cooked.item and not cooked.item:is_empty() then
				stack:take_item(1)
				inv:set_stack("main", i, stack)
				return cooked.item
			end
		end
	end
	return nil
end

local function find_raw_in_inventory(self)
	local inv = self:get_inventory()
	for i = 1, inv:get_size("main") do
		local stack = inv:get_stack("main", i)
		if is_cookable_food(stack) then
			return i
		end
	end
	return nil
end

local function put_in_shared_storage(self, stack)
  if not stack or stack:is_empty() then
    return false, stack
  end
  local base_pos = self:ensure_shared_storage_pos()
  if not base_pos then
    return false, stack
  end
	local chest_pos = self:get_shared_storage_chest_for_item(stack:get_name(), true)
	if not chest_pos then
		return false, stack
	end
	if self.reserve_position and not self:reserve_position("shared_storage_chest", chest_pos, 2) then
		return false, stack
	end
	local leftover = inventory_access.put_stack(self, chest_pos, "main", stack)
	if self.release_reserved_position then
		self:release_reserved_position("shared_storage_chest", chest_pos)
	end
  if leftover:is_empty() then
    return true, leftover
  end
  return false, leftover
end

local function keep_or_drop(self, stack)
  if not stack or stack:is_empty() then
    return
  end
  local leftover = self:add_item_to_main(stack)
  if not leftover:is_empty() then
    minetest.add_item(self.object:get_pos(), leftover)
  end
end

local function use_furnace_inventory(self, furnace_pos)
	local node = minetest.get_node_or_nil(furnace_pos)
	if not node or not inventory_access.can_access(self, furnace_pos) then
		return false
	end
	local meta = minetest.get_meta(furnace_pos)
	if not meta then
		return false
	end
	local inv = meta:get_inventory()
	if not inv then
		return false
	end

	local src = inv:get_stack("src", 1)
	local fuel = inv:get_stack("fuel", 1)
	local dst = inv:get_stack("dst", 1)

  if not dst:is_empty() then
		local taken, moved = inventory_access.take_stack(
			self, furnace_pos, "dst", 1, dst:get_count())
		if moved > 0 then
			local stored, leftover = put_in_shared_storage(self, taken)
			if not stored then
				keep_or_drop(self, leftover or taken)
			end
			return true
		end
		return false
  end

	if src:is_empty() then
		local raw_index = find_raw_in_inventory(self)
		if raw_index and inventory_access.put_from_inventory(
				self, self:get_inventory(), "main", raw_index,
				furnace_pos, "src", 1, 1) > 0 then
			self:set_state_info("Je mets les aliments a cuire.")
		end
	end

	if fuel:is_empty() then
		local fuel_index = ensure_fuel_index(self)
		if fuel_index and inventory_access.put_from_inventory(
				self, self:get_inventory(), "main", fuel_index,
				furnace_pos, "fuel", 1, 1) > 0 then
			self:set_state_info("J'alimente le four.")
		end
	end

	return true
end

working_villages.register_job("working_villages:job_cook", {
	description      = "cuisto (working_villages)",
	long_description = "Je cuisine les aliments crus et les depose dans le coffre partage.",
	inventory_image  = "default_paper.png^working_villages_farmer.png",
	capabilities = {
		cooking = true,
		furnace_use = true,
	},
	on_start = function(self)
		self:notify_job_feature(
			"Cuisine communautaire",
			"Recupere les aliments crus, les cuisine au four, puis les depose dans le coffre partage."
		)
	end,
  jobfunc = function(self)
		if self.pause then
			coroutine.yield()
			return
		end
		self:handle_night()
		self:handle_chest(function(_, stack) return is_cookable_food(stack) end, function(_, stack) return true end)

		local furnace_pos = get_reserved_furnace(self)
		if not furnace_pos then
			furnace_pos = func.find_nearby_furnace(self, self.object:get_pos(), searching_range, "active_furnace")
			if not furnace_pos then
				local bootstrap_furnace, furnace_action = ensure_furnace_workspace(self)
				if bootstrap_furnace then
					furnace_pos = bootstrap_furnace
				elseif furnace_action then
					clear_reserved_furnace(self)
					return
				end
			end
		end
		if furnace_pos and not claim_furnace(self, furnace_pos) then
			clear_reserved_furnace(self)
			furnace_pos = func.find_nearby_furnace(self, self.object:get_pos(), searching_range, "active_furnace")
			if furnace_pos and not claim_furnace(self, furnace_pos) then
				furnace_pos = nil
			end
		end
		if furnace_pos then
			local dest = func.find_interaction_pos(furnace_pos, self.object:get_pos())
			if dest and dest ~= false then
				if vector.distance(self.object:get_pos(), dest) > furnace_interaction_range then
					self:set_displayed_action("rejoint un four")
					self:set_state_info("Je rejoins un four libre pour cuisiner.")
					local reached = self:go_to(dest)
					if not reached then
						clear_reserved_furnace(self)
						self:set_displayed_action("cherche un autre acces au four")
						self:set_state_info("L'acces choisi est bloque; je libere le four et je cherche un autre passage.")
					end
					return
				end
				self.object:set_velocity({x = 0, y = 0, z = 0})
				self:set_animation(working_villages.animation_frames.STAND)
				self:use_node(furnace_pos)
			end
		else
			clear_reserved_furnace(self)
			self:set_state_info("Je cherche un four libre ou de quoi en monter un.")
		end

		if self.take_from_shared_storage_by_predicate then
			self:take_from_shared_storage_by_predicate(function(name)
				return is_cookable_food(ItemStack(name))
			end, take_batch)
		end

		self:count_timer("cook:work")
		if self:timer_exceeded("cook:work", furnace_check_interval) then
			if furnace_pos then
				use_furnace_inventory(self, furnace_pos)
				self:set_displayed_action("cuisine")
				clear_reserved_furnace(self)
				return
			end
			local cooked = creative_test_mode and cook_one(self) or nil
			if cooked then
				local stored, leftover = put_in_shared_storage(self, cooked)
				if not stored then
					keep_or_drop(self, leftover or cooked)
				end
				self:set_displayed_action("cuisine")
				self:set_state_info("Je cuisine pour le village.")
			elseif not furnace_pos then
				self:set_displayed_action("attend un four")
				self:set_state_info("Je ne peux pas cuisiner sans four alimente.")
			else
				self:set_displayed_action("attend")
				self:set_state_info("J'attends des aliments a cuisiner.")
			end
		end
	end,
})
