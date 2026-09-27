local func = working_villages.require("jobs/util")
local blueprints = working_villages.blueprints
local compat = working_villages.voxelibre_compat
local comm = working_villages.communication
local blacksmith = working_villages.blacksmith
local crafting = working_villages.crafting
local work_fallback = working_villages.work_fallback

-- A new village cannot obtain its first axe when every woodcutter refuses to
-- touch a tree without one.  This is deliberately a small, one-shot bootstrap:
-- the engine's real hand capabilities must allow the node, every successful
-- dig is persisted and only a bounded number of trunks may be taken this way.
local HAND_BOOTSTRAP_LOG_LIMIT = 6
local HAND_BOOTSTRAP_RANGE = {x = 7, y = 5, z = 7, h = 3}
local AUTONOMOUS_JOB = "working_villages:job_autonome"
local workbench_item_candidates = compat.get_crafting_table_item_candidates()

local function reserve_tree_target(self, pos, ttl)
	if not self.reserve_position then
		return true
	end
	return self:reserve_position("tree_target", pos, ttl or 12)
end

local function release_tree_target(self, pos)
	if self.release_reserved_position then
		self:release_reserved_position("tree_target", pos)
	end
end

local function find_tree(self, p)
	local adj_node = minetest.get_node(p)
	if minetest.get_item_group(adj_node.name, "tree") > 0 then
		if self.is_position_reserved and self:is_position_reserved("tree_target", p) then return false end
		if func.is_protected(self, p) then return false end
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

local function is_axe(name)
	if type(name) == "table" then
		name = name.name or name:get_name()
	end
	return minetest.get_item_group(name, "axe") > 0
end

local function get_axe_candidates()
	return {
		minetest.registered_items["mcl_tools:axe_iron"] and "mcl_tools:axe_iron" or compat.get_item("default:axe_steel"),
		minetest.registered_items["mcl_tools:axe_stone"] and "mcl_tools:axe_stone" or compat.get_item("default:axe_stone"),
		minetest.registered_items["mcl_tools:axe_wood"] and "mcl_tools:axe_wood" or compat.get_item("default:axe_wood"),
	}
end

local function craft_basic_axe(self)
	if not crafting then
		return false
	end
	local candidates = get_axe_candidates()
	local crafted = crafting.ensure_any_item(self, candidates, 1, {
		use_shared_storage = false,
		-- A VoxeLibre axe first fails while the real 3x3 workbench is absent.
		-- Retry promptly after the bootstrap worker has legitimately placed it.
		fail_cooldown = 1,
		max_depth = 4,
	})
	if crafted then
		return true
	end
	local storage_pos = self.ensure_shared_storage_pos and self:ensure_shared_storage_pos()
	if not storage_pos then
		return false
	end
	return crafting.ensure_any_item(self, candidates, 1, {
		use_shared_storage = true,
		force = true,
		fail_cooldown = 1,
		max_depth = 4,
	}) ~= nil
end

local function get_hand_tool_capabilities()
	-- The shared resolver returns Minetest Game's empty hand or VoxeLibre's
	-- registered survival mesh-hand; both are authoritative engine items.
	local hand = working_villages.get_intrinsic_hand_stack
		and working_villages.get_intrinsic_hand_stack() or ItemStack("")
	local capabilities = hand:get_tool_capabilities()
	return capabilities and next(capabilities.groupcaps or {}) ~= nil
		and capabilities or nil
end

local function can_dig_tree_by_hand(self, pos)
	if not find_tree(self, pos) then
		return false
	end
	local node = minetest.get_node_or_nil(pos)
	local def = node and minetest.registered_nodes[node.name] or nil
	if not def or def.diggable == false then
		return false
	end
	local capabilities = get_hand_tool_capabilities()
	if not capabilities then
		return false
	end
	local params = minetest.get_dig_params(def.groups or {}, capabilities, 0)
	return params and params.diggable == true
end

local function stow_wield_for_bare_hands(self)
	local wield = self:get_wield_item_stack()
	if not wield or wield:is_empty() then
		return true
	end
	local inv = self:get_inventory()
	if not inv or not inv:room_for_item("main", wield) then
		return false
	end
	local leftover = inv:add_item("main", wield)
	if leftover and not leftover:is_empty() then
		local moved_count = wield:get_count() - leftover:get_count()
		if moved_count > 0 then
			local rollback = ItemStack(wield)
			rollback:set_count(moved_count)
			inv:remove_item("main", rollback)
		end
		return false
	end
	self:set_wield_item_stack(ItemStack(""))
	return true
end

local function bootstrap_state(self)
	self.job_data = self.job_data or {}
	local state = self.job_data.woodcutter_hand_bootstrap
	if type(state) ~= "table" then
		state = {
			logs_dug = 0,
			limit = HAND_BOOTSTRAP_LOG_LIMIT,
			started_at = minetest.get_gametime(),
		}
		self.job_data.woodcutter_hand_bootstrap = state
	end
	return state
end

local function has_nearby_workbench(self)
	if not func.find_nearby_crafting_table then
		return false
	end
	return func.find_nearby_crafting_table(
		self,
		self.object:get_pos(),
		{x = 12, y = 4, z = 12},
		"bootstrap_workbench_site"
	) ~= nil
end

local function get_carried_workbench(self)
	local wield_name = self:get_wield_item_stack():get_name()
	for _, name in ipairs(workbench_item_candidates) do
		if wield_name == name or self:has_item_in_main(function(candidate)
			return candidate == name
		end) then
			return name
		end
	end
	return nil
end

local function can_place_bootstrap_workbench(self, pos)
	if func.is_protected(self, pos) or working_villages.failed_pos_test(pos) then
		return false
	end
	if self.is_position_reserved
			and self:is_position_reserved("bootstrap_workbench_site", pos) then
		return false
	end
	local node = minetest.get_node_or_nil(pos)
	local above = minetest.get_node_or_nil(vector.add(pos, {x = 0, y = 1, z = 0}))
	local below_pos = vector.add(pos, {x = 0, y = -1, z = 0})
	local below = minetest.get_node_or_nil(below_pos)
	local node_def = node and minetest.registered_nodes[node.name] or nil
	local above_def = above and minetest.registered_nodes[above.name] or nil
	if not node_def or not node_def.buildable_to
			or not above_def or not above_def.buildable_to or not below then
		return false
	end
	if minetest.get_item_group(below.name, "liquid") > 0
			or not func.walkable_pos(below_pos) then
		return false
	end
	return func.find_adjacent_clear(pos) ~= false
end

local function place_bootstrap_workbench(self, item_name)
	-- The autonomous profession uses the same reservation scope.  Rechecking
	-- before and after travel prevents two villagers from consuming two tables
	-- for the same village utility.
	if has_nearby_workbench(self) then
		return false
	end
	local site = func.search_surrounding(self.object:get_pos(), function(pos)
		return can_place_bootstrap_workbench(self, pos)
	end, {x = 4, y = 1, z = 4, h = 1})
	if not site then
		return false
	end
	if self.reserve_position
			and not self:reserve_position("bootstrap_workbench_site", site, 20) then
		return false
	end
	local function release()
		if self.release_reserved_position then
			self:release_reserved_position("bootstrap_workbench_site", site)
		end
	end
	local destination = func.find_adjacent_clear(site)
	if destination then
		destination = func.find_ground_below(destination) or destination
	end
	if not destination then
		release()
		return false
	end
	self:set_displayed_action("installe l'etabli initial")
	self:set_state_info("Je transforme le bois recolte en un vrai etabli pour fabriquer ma premiere hache.")
	local reached = self:go_to(destination)
	if not reached or has_nearby_workbench(self) then
		release()
		return false
	end
	-- A crafting table is a plain registered node. Use the node placement path
	-- so offline player-only UI callbacks cannot turn a completed placement into
	-- an unconsumed stack; self:place still performs protection, occupancy and
	-- exact one-item accounting.
	local placed = self:place({name = item_name}, site)
	release()
	if not placed then
		working_villages.failed_pos_record(site)
	end
	return placed == true
end

local function autonomous_bootstrap_worker_nearby(self)
	if not comm or not comm.find_nearby_villagers then
		return false
	end
	local workers = comm.find_nearby_villagers(
		self.object:get_pos(),
		25,
		AUTONOMOUS_JOB,
		self.owner_name
	) or {}
	return workers[1] ~= nil
end

local function ensure_bootstrap_workbench(self, state)
	if not compat.is_voxelibre or #workbench_item_candidates == 0
			or has_nearby_workbench(self) then
		return false
	end
	if autonomous_bootstrap_worker_nearby(self) then
		-- The autonomous worker owns the normal workbench/chest bootstrap. Keep
		-- harvesting legitimate logs for it, but never spend the same village's
		-- wood on a competing second workstation.
		if state and not state.workbench_deferred_to_autonomous then
			state.workbench_deferred_to_autonomous = true
			state.workbench_deferred_at = minetest.get_gametime()
		end
		return false
	end
	local item_name = get_carried_workbench(self)
	if not item_name and crafting then
		item_name = crafting.ensure_any_item(self, workbench_item_candidates, 1, {
			use_shared_storage = false,
			fail_cooldown = 1,
			max_depth = 4,
		})
	end
	if not item_name then
		return false
	end
	return place_bootstrap_workbench(self, item_name)
end

local function collect_bootstrap_log_by_hand(self, state)
	if state.completed or state.exhausted then
		return false
	end
	local dug_count = math.max(0, math.floor(tonumber(state.logs_dug) or 0))
	local limit = math.min(HAND_BOOTSTRAP_LOG_LIMIT,
		math.max(1, math.floor(tonumber(state.limit) or HAND_BOOTSTRAP_LOG_LIMIT)))
	state.limit = limit
	if dug_count >= limit then
		state.exhausted = true
		return false
	end
	if not stow_wield_for_bare_hands(self) then
		return false
	end
	local target = func.search_surrounding(self.object:get_pos(), function(pos)
		return can_dig_tree_by_hand(self, pos)
	end, HAND_BOOTSTRAP_RANGE)
	if not target or not reserve_tree_target(self, target, 20) then
		return false
	end
	local destination = func.find_adjacent_clear(target)
	if destination then
		destination = func.find_ground_below(destination) or destination
	end
	if not destination then
		release_tree_target(self, target)
		return false
	end
	self:set_displayed_action("recolte son bois initial a mains nues")
	self:set_state_info(("Je prends seulement les troncs necessaires a ma premiere hache (%d/%d)."):format(
		dug_count, limit))
	local reached = self:go_to(destination)
	if not reached then
		release_tree_target(self, target)
		working_villages.failed_pos_record(target)
		return false
	end
	-- self:dig repeats the engine's registered tool-capability and can_dig
	-- checks immediately before calling node_dig.  Keeping the wield slot empty
	-- means this is the real hand gate, not an exception to the general guard.
	local success = self:dig(target, true)
	release_tree_target(self, target)
	if not success then
		working_villages.failed_pos_record(target)
		return false
	end
	state.logs_dug = dug_count + 1
	state.last_log_pos = vector.round(target)
	state.last_log_at = minetest.get_gametime()
	if state.logs_dug >= limit then
		state.exhausted = true
	end
	return true
end

local function perform_hand_bootstrap(self)
	local state = bootstrap_state(self)
	if ensure_bootstrap_workbench(self, state) then
		state.workbench_placed = true
		return true
	end
	return collect_bootstrap_log_by_hand(self, state)
end

local function request_axe(self)
	self.job_data = self.job_data or {}
	local routed = false
	local smith = nil
	if blacksmith and blacksmith.enqueue_order then
		local targets = comm and comm.find_nearby_villagers(self.object:get_pos(), 25,
			"working_villages:job_blacksmith", self.owner_name) or {}
		smith = targets and targets[1]
	end
	if smith and blacksmith and blacksmith.enqueue_order then
		routed = blacksmith.enqueue_order(smith, "axe_iron", 1, self.owner_name or "",
			self.inventory_name) == true
	elseif blacksmith and blacksmith.enqueue_global_order then
		routed = blacksmith.enqueue_global_order("axe_iron", 1, self.owner_name or "",
			self.inventory_name) == true
	end
	if not routed and comm then
		comm.broadcast(self, comm.list_loaded_villagers(), "help_needed", {
			tool_group = "axe",
			requester_id = self.inventory_name,
		})
	end
	self.job_data.axe_request_time = minetest.get_gametime()
	self:set_state_info("Je demande une hache.")
	return routed
end

local function is_sapling_spot(self, pos)
	if func.is_protected(self, pos) then return false end
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
		if self.equip_best_weapon then self:equip_best_weapon() end
		if self.equip_best_armor then self:equip_best_armor() end
		self:handle_night()
		self:handle_chest(take_func, put_func)
		self:handle_job_pos()

		self:count_timer("woodcutter:search")
		self:count_timer("woodcutter:change_dir")
		self:count_timer("woodcutter:reforest")
		self:count_timer("woodcutter:announce")
		self:handle_obstacles()
		local has_axe = work_fallback.ensure_tool(self, {
			key = "woodcutter_axe",
			tool_group = "axe",
			tool_label = "une hache",
			candidates = get_axe_candidates(),
			craft = craft_basic_axe,
			request = request_axe,
			request_cooldown = 30,
			wait_info = "Il me manque une hache. Je cherche ou demande l'outil et je ramasse des ressources en attendant.",
			announce = "Je cherche une hache; en attendant, je rassemble les objets utiles au village.",
		})
		if not has_axe then
			work_fallback.perform(self, {
				key = "woodcutter_axe",
				tool_group = "axe",
				tool_label = "une hache",
				activity = perform_hand_bootstrap,
				collect_predicate = is_sapling,
				activity_action = "prepare sa premiere hache",
				activity_info = "Je recolte un peu de bois autorise a mains nues pour fabriquer ma premiere hache.",
				patrol_action = "cherche une hache",
				patrol_info = "Je cherche un tronc que le moteur autorise reellement a couper a mains nues.",
			})
			return
		end
		local hand_bootstrap = self.job_data and self.job_data.woodcutter_hand_bootstrap
		if hand_bootstrap and not hand_bootstrap.completed then
			hand_bootstrap.completed = true
			hand_bootstrap.completed_at = minetest.get_gametime()
		end

		if self:timer_exceeded("woodcutter:search",10) then
			self:collect_nearest_item_by_condition(is_sapling, searching_range)
			local wield_stack = self:get_wield_item_stack()
			if is_sapling(wield_stack:get_name()) or self:has_item_in_main(is_sapling) then
				local target = func.search_surrounding(self.object:get_pos(), function(pos)
					return is_sapling_spot(self, pos)
				end, searching_range)
				if target ~= nil then
					local destination = func.find_adjacent_clear(target)
					if destination==false then
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
			local target = func.search_surrounding(self.object:get_pos(), function(pos)
				return find_tree(self, pos)
			end, searching_range)
			if target ~= nil then
				if not reserve_tree_target(self, target, 15) then
					self:set_displayed_action("cherche un autre arbre")
					return
				end
				-- Check tree density for sustainable forestry
				local tree_count = count_nearby_trees(target, 5)
				if tree_count < 3 then
					-- Too few trees nearby, skip cutting and plant more
					release_tree_target(self, target)
					self:set_state_info("Je preserve la foret : pas assez d'arbres. Je vais planter.")
					self:set_displayed_action("forestier responsable")
					self:announce_action("Je protege la foret en plantant plus d'arbres.", 180)
				else
					local destination = func.find_adjacent_clear(target)
					destination = func.find_ground_below(destination)
					if destination==false then
						destination = target
					end
					self:set_displayed_action("coupe un arbre")
					-- We may not be able to reach the log
					local success, ret = self:go_to(destination)
					if not success then
						release_tree_target(self, target)
						working_villages.failed_pos_record(target)
						self:set_displayed_action("regarde un tronc inaccessible")
						self:delay(100)
					else
						success, ret = self:dig(target,true)
						if not success then
							release_tree_target(self, target)
							working_villages.failed_pos_record(target)
							self:set_displayed_action("confus, la coupe a echoue")
							self:delay(100)
						else
							release_tree_target(self, target)
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
		elseif self:timer_exceeded("woodcutter:reforest", 80) then
			-- Periodically focus on reforestation
			if self:has_item_in_main(is_sapling) then
				local target = func.search_surrounding(self.object:get_pos(), function(pos)
					return is_sapling_spot(self, pos)
				end, searching_range)
				if target then
					self:set_displayed_action("reboise la zone")
					self:set_state_info("Je plante des arbres pour garder la foret.")
				end
			end
		elseif self:timer_exceeded("woodcutter:change_dir",25) then
			self:change_direction_randomly()
		end
	end,
})
