
local func = working_villages.require("jobs/util")
local farming_compat = working_villages.require("farming_compat")
local blueprints = working_villages.blueprints
local compat = working_villages.voxelibre_compat
local crafting = working_villages.crafting
local collab = working_villages.collaborative_tasks
local crop_planner = working_villages.crop_planner

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

local function is_seed_item_name(name)
	return type(name) == "string" and name ~= "" and (
		seed_items[name] == true or minetest.get_item_group(name, "seed") > 0)
end

local function drop_mentions_seed(value, depth)
	depth = depth or 0
	if depth > 8 then
		return false
	end
	if type(value) == "string" then
		return is_seed_item_name(ItemStack(value):get_name())
	end
	if type(value) ~= "table" then
		return false
	end
	for _, entry in pairs(value) do
		if drop_mentions_seed(entry, depth + 1) then
			return true
		end
	end
	return false
end

-- Build this list from registered drop definitions so add-on crops and both
-- supported games use their real seed sources. Grass/fern is a fallback for
-- games which implement the chance in an on_dig callback instead of `drop`.
local natural_seed_source_nodes = {}
for name, def in pairs(minetest.registered_nodes or {}) do
	local lower = name:lower()
	local grass_like = (lower:find("grass", 1, true) or lower:find("fern", 1, true))
		and ((def and def.buildable_to) or minetest.get_item_group(name, "flora") > 0)
		and minetest.get_item_group(name, "soil") == 0
	if not farming_compat.is_plant(name)
			and (drop_mentions_seed(def and def.drop) or grass_like) then
		natural_seed_source_nodes[name] = true
	end
end

local function reserve_crop_target(self, pos, ttl)
	if not self.reserve_position then
		return true
	end
	return self:reserve_position("crop_target", pos, ttl or 12)
end

local function release_crop_target(self, pos)
	if self.release_reserved_position then
		self:release_reserved_position("crop_target", pos)
	end
end

local function find_plant_node(self, pos)
	if self.is_position_reserved and self:is_position_reserved("crop_target", pos) then
		return false
	end
	return farming_compat.is_plant_node(pos)
end

local function has_seed(name)
	return is_seed_item_name(name)
end

local find_seed_in_inventory
local seed_search_interval = 20

local function find_natural_seed_source(self, pos)
	local node = minetest.get_node_or_nil(pos)
	if not node or not natural_seed_source_nodes[node.name] then
		return false
	end
	if self.is_position_reserved and self:is_position_reserved("seed_source_target", pos) then
		return false
	end
	return not func.is_protected(self, pos) and not working_villages.failed_pos_test(pos)
end

local function collect_seed_from_nature(self, center)
	local target = func.search_surrounding(center, function(pos)
		return find_natural_seed_source(self, pos)
	end, {x = 12, y = 3, z = 12})
	if not target then
		return false
	end
	if self.reserve_position and not self:reserve_position("seed_source_target", target, 15) then
		return false
	end
	local destination = func.find_adjacent_clear(target)
	if destination then
		destination = func.find_ground_below(destination) or destination
	else
		destination = target
	end
	self:set_displayed_action("cherche des graines")
	self:set_state_info("Je recolte des graines sauvages avant de preparer le champ.")
	local moved = self:go_to(destination)
	if not moved then
		if self.release_reserved_position then
			self:release_reserved_position("seed_source_target", target)
		end
		working_villages.failed_pos_record(target)
		return false
	end

	-- Bare hands are the portable, legitimate tool for grass. If another tool
	-- is equipped, put it safely in `main` before the yielding dig so a world
	-- save cannot lose a coroutine-local copy of it.
	local wielded = self:get_wield_item_stack()
	if wielded and not wielded:is_empty()
			and self:get_inventory():room_for_item("main", wielded) then
		local leftover = self:add_item_to_main(wielded)
		if leftover:is_empty() then
			self:set_wield_item_stack(ItemStack())
		end
	end
	local dug = self:dig(target, true)
	if self.release_reserved_position then
		self:release_reserved_position("seed_source_target", target)
	end
	if not dug then
		working_villages.failed_pos_record(target)
		return false
	end
	if find_seed_in_inventory and find_seed_in_inventory(self) then
		self:set_state_info("J'ai trouve des graines sauvages; je peux commencer les semis.")
	else
		self:set_state_info("Cette plante n'a rien donne; je poursuis la recherche de graines.")
		-- Natural seed sources are deliberately probabilistic (VoxeLibre tall
		-- grass only drops wheat seeds one time out of eight).  A successful dig
		-- with no drop is not a reason to wait through another complete decision
		-- interval: the next job cycle may try a different source immediately.
		self:set_timer("farmer:seed_search", seed_search_interval)
	end
	return true
end

local function get_farmer_tool_candidates()
	-- The MTG hoes live in the `farming` namespace, not `default`. Using the
	-- profile-aware resolver also preserves the VoxeLibre `mcl_farming` names
	-- and filters out tools which the active game did not register.
	return compat.get_tool_items("hoe", {"iron", "stone", "wood"})
end

find_seed_in_inventory = function(self, preferred)
	local inv = self:get_inventory()
	local wield_stack = self:get_wield_item_stack()
	if preferred then
		if not wield_stack:is_empty() and wield_stack:get_name() == preferred then
			return preferred
		end
		for _, stack in ipairs(inv:get_list("main")) do
			if not stack:is_empty() and stack:get_name() == preferred then
				return preferred
			end
		end
	end
	if not wield_stack:is_empty() and has_seed(wield_stack:get_name()) then
		return wield_stack:get_name()
	end
	for _, stack in ipairs(inv:get_list("main")) do
		if not stack:is_empty() and has_seed(stack:get_name()) then
			return stack:get_name()
		end
	end
	return nil
end

local function available_seed_names(self)
	local found = {}
	local names = {}
	local function add(stack)
		local name = stack and stack:get_name() or ""
		if has_seed(name) and not found[name] then
			found[name] = true
			names[#names + 1] = name
		end
	end
	add(self:get_wield_item_stack())
	for _, stack in ipairs(self:get_inventory():get_list("main") or {}) do
		add(stack)
	end
	table.sort(names)
	return names
end

local function ensure_farmer_tool(self)
	local tool_candidates = get_farmer_tool_candidates()
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
		end
	end
	return false
end

local function craft_basic_hoe(self)
	if not crafting then
		return false
	end
	return crafting.ensure_any_item(self, get_farmer_tool_candidates(), 1, {
		use_shared_storage = true,
		fail_cooldown = 10,
		max_depth = 4,
	}) ~= nil
end

local function try_request_hoe(self)
	self.job_data = self.job_data or {}
	local now = minetest.get_gametime()
	local last = tonumber(self.job_data.hoe_request_time)
	if last and now >= last and now - last < 30 then
		return false
	end
	if working_villages.communication then
		working_villages.communication.broadcast(self,
			working_villages.communication.list_loaded_villagers(), "help_needed", {
				tool_group = "hoe",
				requester_id = self.inventory_name,
			})
	end
	self.job_data.hoe_request_time = now
	self:set_state_info("Je demande une houe et je continue les recoltes deja accessibles.")
	return true
end

local function coordinate_food_shortage(self)
	if not collab or not self.count_shared_storage_items then
		return false
	end
	self:count_timer("farmer:food_support")
	if not self:timer_exceeded("farmer:food_support", 300) then
		return false
	end
	local available = self:count_shared_storage_items(function(name)
		return minetest.get_item_group(name, "food") > 0
	end)
	if available >= 8 or (self.job_data and self.job_data.collab_task) then
		return false
	end
	local ok = collab.start_task("food_support", self, {
		resource = "food",
		count = 8 - available,
		delivery_target = "shared_storage",
		requester_id = self.inventory_name,
		info = "Le stock alimentaire du village est insuffisant",
	})
	if ok then
		self:set_displayed_action("coordonne les provisions")
		self:set_state_info("Je signale la penurie au cuisinier.")
		return true
	end
	return false
end

local function try_till_soil(self, pos)
	if not pos then
		return false
	end
	local soil_pos = vector.add(pos, {x = 0, y = -1, z = 0})
	if not ensure_farmer_tool(self) then
		if self.take_tool_from_shared_storage and self:take_tool_from_shared_storage("hoe") then
			ensure_farmer_tool(self)
		elseif craft_basic_hoe(self) then
			ensure_farmer_tool(self)
		else
			try_request_hoe(self)
			return false
		end
	end
	self:set_state_info("Je prepare la terre.")
	self:set_displayed_action("prepare les cultures")
	return self:use_wield_on_node(soil_pos, pos)
end

local function is_farmland(pos)
	local node_below = minetest.get_node(vector.add(pos, {x=0, y=-1, z=0}))
	return compat.is_farmland_node(node_below.name)
end

local function is_empty_farmland(self, pos)
	if self.is_position_reserved and self:is_position_reserved("crop_target", pos) then
		return false
	end
	return minetest.get_node(pos).name == "air" and is_farmland(pos)
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

local function try_replant(self, target, seed_list, farm_center)
	if not target then
		return false
	end
	if seed_list and #seed_list > 0 then
		for _, seed in ipairs(seed_list) do
			local available = seed and find_seed_in_inventory(self, seed)
			if available and attempt_plant_seed(self, target, available) then
				if crop_planner then
					crop_planner.remember(self, available, target, farm_center)
				end
				return true, available
			end
		end
		-- Never replace a harvested crop with whichever unrelated seed happened
		-- to be picked up first. The empty cell keeps its crop plan and will be
		-- replanted when the matching seed returns.
		if crop_planner then
			crop_planner.remember(self, seed_list[1], target, farm_center)
		end
		return false
	end
	return false
end

local searching_range = {x = 10, y = 3, z = 10}
local seed_collection_range = {x = 2, y = 1, z = 2}
local max_harvest_per_cycle = 2
local farm_anchor_radius = 12

local function reach_crop(self, target, destination)
	-- Farming actions already have a five-node engine interaction limit.  Avoid
	-- starting a path search when the crop is inside that real reach: short
	-- routes between adjacent field cells can otherwise oscillate around young
	-- crops and waste several decision cycles before sowing the next row.
	local current = self.object:get_pos()
	local dx = (current.x or 0) - (target.x or 0)
	local dy = (current.y or 0) - (target.y or 0)
	local dz = (current.z or 0) - (target.z or 0)
	if math.sqrt(dx * dx + dy * dy + dz * dz) <= 4.5 then
		return true
	end
	return self:go_to(destination)
end

local function try_plant_empty_farmland(self, farm_center)
	local target = func.search_surrounding(farm_center, function(pos)
		return is_empty_farmland(self, pos)
	end, searching_range)
	if not target then
		return false
	end
	local seed_name = crop_planner and crop_planner.choose(
		self, available_seed_names(self), target, farm_center)
		or find_seed_in_inventory(self)
	if not seed_name then
		self:set_state_info("Je conserve le plan de culture et cherche la graine correspondante.")
		return false
	end
	if not reserve_crop_target(self, target, 15) then
		return false
	end

	local destination = func.find_adjacent_clear(target)
	if destination then
		destination = func.find_ground_below(destination)
	end
	if not destination then
		destination = target
	end
	local moved = reach_crop(self, target, destination)
	if not moved then
		release_crop_target(self, target)
		working_villages.failed_pos_record(target)
		return false
	end

	-- place() validates the real wield/main inventory stack and consumes one
	-- item only after the seed callback has actually changed the node.
	local planted = attempt_plant_seed(self, target, seed_name)
	release_crop_target(self, target)
	if not planted then
		working_villages.failed_pos_record(target)
	elseif crop_planner then
		crop_planner.remember(self, seed_name, target, farm_center)
	end
	return planted
end

local function get_farm_center(self)
	if self.pos_data and self.pos_data.job_pos then
		return vector.round(self.pos_data.job_pos)
	end
	return self.object:get_pos()
end

-- Find unfarmed but suitable land
local function find_tillable_soil(p)
	local node = minetest.get_node(p)
	if node.name ~= "air" then
		return false
	end
	
	local below = minetest.get_node(vector.add(p, {x=0, y=-1, z=0}))
	-- Check for dirt or grass that can be tilled
	return compat.is_tillable_dirt(below.name)
end

local function put_func(_,stack)
	local name = stack:get_name()
	if farming_demands[name] then
		return false
	end
	if minetest.get_item_group(name, "hoe") > 0 then
		return false
	end
	-- Dedicated seed items must stay with the farmer.  Depositing them only to
	-- take them back in the same chest visit creates needless traffic and lets a
	-- bootstrap farm oscillate between the chest and an empty field.  Edible
	-- root crops remain depositable: take_func can retrieve one stack when the
	-- farmer needs that crop itself for replanting.
	if has_seed(name) and minetest.get_item_group(name, "food") == 0 then
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
		local preferred = crop_planner and crop_planner.get_primary(villager) or nil
		if preferred and item_name ~= preferred then
			return false
		end
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
	capabilities = {
		farming = true,
		auto_replanting = true,
		farmland_preparation = true,
		auto_harvest = true,
		crop_recognition = true,
	},
	on_start = function(self)
		-- Notify player about farmer capabilities
		self:notify_job_feature(
			"Agriculture automatique",
			"Récolte et replante automatiquement. Prépare les terres. Gagne de l'expérience."
		)
	end,
	jobfunc = function(self)
		if self.equip_best_weapon then self:equip_best_weapon() end
		if self.equip_best_armor then self:equip_best_armor() end
		self:handle_night()
		self:handle_chest(take_func, put_func)
		self:handle_job_pos()

		local farm_center = get_farm_center(self)
		if self.pos_data and self.pos_data.job_pos then
			if vector.distance(self.object:get_pos(), farm_center) > farm_anchor_radius then
				self:set_state_info("Je vais a mon champ.")
				self:set_displayed_action("va au champ")
				self:go_to(farm_center)
				return
			end
		end

		ensure_farmer_tool(self)
		self:collect_nearest_item_by_condition(
			function(item) return has_seed(item.name) end,
			searching_range
		)

		self:count_timer("farmer:search")
		self:count_timer("farmer:seed_search")
		self:count_timer("farmer:change_dir")
		self:count_timer("farmer:expand_farm")
		self:count_timer("farmer:announce")
		coordinate_food_shortage(self)
		self:handle_obstacles()
		local crop_search_due = self:timer_exceeded("farmer:search",10)
		local mature_crop_found = false
		if crop_search_due then
			self:collect_nearest_item_by_condition(farming_plants.is_plant, searching_range)
			for _ = 1, max_harvest_per_cycle do
				local target = func.search_surrounding(farm_center, function(pos)
					return find_plant_node(self, pos)
				end, searching_range)
				if not target then
					break
				end
				mature_crop_found = true
				if not reserve_crop_target(self, target, 15) then
					break
				end
				local destination = func.find_adjacent_clear(target)
				if destination then
					destination = func.find_ground_below(destination)
				end
				if destination == false then
					destination = target
				end
				local moved = reach_crop(self, target, destination)
				if not moved then
					release_crop_target(self, target)
					working_villages.failed_pos_record(target)
					break
				end
				local plant_data = farming_plants.get_plant(minetest.get_node(target).name)
				local dug = self:dig(target,true)
				if not dug then
					release_crop_target(self, target)
					working_villages.failed_pos_record(target)
					break
				end
				self:collect_nearest_item_by_condition(
					function(item) return has_seed(item.name) end,
					seed_collection_range
				)
				local replanted = try_replant(self, target,
					plant_data and plant_data.replant, farm_center)
				release_crop_target(self, target)
				if replanted then
					local inv_name = self:get_inventory_name()
					blueprints.add_experience(inv_name, 1)
					self:set_displayed_action("recolte des cultures")
					-- Announce farming activity periodically
					if self:timer_exceeded("farmer:announce", 90) then
						self:announce_action("Je recolte et replante les cultures.")
					end
				else
					self:set_state_info("Je cherche des graines pour replanter.")
				end
			end
			try_plant_empty_farmland(self, farm_center)
		end
		-- A mature crop can provide its own replant seed and must therefore win
		-- over bootstrap seed hunting. If the scheduled crop scan found nothing,
		-- natural collection still runs in this same decision without another
		-- terrain scan.
		if not mature_crop_found and not find_seed_in_inventory(self)
				and self:timer_exceeded("farmer:seed_search", seed_search_interval)
				and collect_seed_from_nature(self, farm_center) then
			return
		end
		if not crop_search_due and find_seed_in_inventory(self)
				and self:timer_exceeded("farmer:expand_farm", 30) then
			-- Only prepare soil once it can be planted. Empty farmland can regress
			-- to dirt or be trampled while the farmer is still waiting on a random
			-- natural seed drop, which wastes both time and hoe durability.
			local tillable = func.search_surrounding(farm_center, find_tillable_soil, searching_range)
			if tillable then
				local planned_seed = crop_planner and crop_planner.choose(
					self, available_seed_names(self), tillable, farm_center)
					or find_seed_in_inventory(self)
				if not planned_seed then
					self:set_state_info("Je cherche la graine prevue avant de labourer une nouvelle parcelle.")
					return
				end
				local destination = func.find_adjacent_clear(tillable)
				if destination then
					destination = func.find_ground_below(destination)
					if destination ~= false then
						self:go_to(destination)
						if try_till_soil(self, tillable) then
							local planted = attempt_plant_seed(self, tillable, planned_seed)
							if planted then
								if crop_planner then
									crop_planner.remember(self, planned_seed, tillable, farm_center)
								end
								self:announce_action("Je prepare et je seme de nouvelles terres cultivables.", 120)
							else
								self:announce_action("Je prepare de nouvelles terres cultivables.", 120)
							end
						end
					end
				end
			end
		elseif not crop_search_due and self:timer_exceeded("farmer:change_dir",18) then
			self:change_direction_randomly()
		end
	end,
})

working_villages.farming_plants = farming_plants
