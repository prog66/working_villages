local func = working_villages.require("jobs/util")
local farming_compat = working_villages.require("farming_compat")
local comm = working_villages.communication
local blacksmith = working_villages.blacksmith
local compat = working_villages.voxelibre_compat
local crafting = working_villages.crafting
local work_fallback = working_villages.work_fallback
local set_action

local searching_range = {x = 12, y = 4, z = 12}
local item_range = {x = 6, y = 2, z = 6}
local explore_radius = tonumber(minetest.settings:get("working_villages_autonomous_explore_radius")) or 10

local storage_item_candidates = compat.get_chest_item_candidates()
local workbench_item_candidates = compat.get_crafting_table_item_candidates()
local furnace_item_candidates = compat.get_furnace_item_candidates()

local function get_candidate_item(self, candidates)
	local wield_name = self:get_wield_item_stack():get_name()
	for _, name in ipairs(candidates or {}) do
		if wield_name == name then
			return name
		end
		if self:has_item_in_main(function(item_name) return item_name == name end) then
			return name
		end
	end
	return nil
end

local function has_storage_item(self)
	return get_candidate_item(self, storage_item_candidates)
end

local function count_clear_sides(pos)
	local free_sides = 0
	for _, offset in ipairs({
		{x = 1, y = 0, z = 0},
		{x = -1, y = 0, z = 0},
		{x = 0, y = 0, z = 1},
		{x = 0, y = 0, z = -1},
	}) do
		local side_pos = vector.add(pos, offset)
		local node = minetest.get_node_or_nil(side_pos)
		local def = node and minetest.registered_nodes[node.name] or nil
		if def and def.buildable_to then
			free_sides = free_sides + 1
		end
	end
	return free_sides
end

local function has_storage_clearance(pos)
	return count_clear_sides(pos) >= 2
end

local function get_bootstrap_origin(self)
	return vector.round(
		(self.pos_data and (self.pos_data.storage_pos or self.pos_data.home_pos or self.pos_data.job_pos))
		or self.object:get_pos()
	)
end

local function can_place_bootstrap_utility(self, pos, reservation_scope, occupied_predicate, opts)
	opts = opts or {}
	pos = vector.round(pos)
	if func.is_protected(self, pos) or working_villages.failed_pos_test(pos) then
		return false
	end
	if reservation_scope and self.is_position_reserved and self:is_position_reserved(reservation_scope, pos) then
		return false
	end
	if occupied_predicate and occupied_predicate(pos) then
		return false
	end
	local node = minetest.get_node_or_nil(pos)
	local below = minetest.get_node_or_nil(vector.add(pos, {x = 0, y = -1, z = 0}))
	local above = minetest.get_node_or_nil(vector.add(pos, {x = 0, y = 1, z = 0}))
	if not node or not below then
		return false
	end
	local node_def = minetest.registered_nodes[node.name]
	if not node_def or not node_def.buildable_to then
		return false
	end
	if opts.require_headroom then
		local above_def = above and minetest.registered_nodes[above.name] or nil
		if not above_def or not above_def.buildable_to then
			return false
		end
	end
	if minetest.get_item_group(below.name, "liquid") > 0 or not func.walkable_pos(vector.add(pos, {x = 0, y = -1, z = 0})) then
		return false
	end
	if func.find_adjacent_clear(pos) == false then
		return false
	end
	if (opts.min_clear_sides or 0) > 0 and count_clear_sides(pos) < opts.min_clear_sides then
		return false
	end
	return true
end

local function find_bootstrap_utility_site(self, reservation_scope, occupied_predicate, opts)
	return func.search_surrounding(get_bootstrap_origin(self), function(pos)
		return can_place_bootstrap_utility(self, pos, reservation_scope, occupied_predicate, opts)
	end, (opts and opts.search_range) or {x = 4, y = 1, z = 4, h = 1})
end

local function clear_reserved_site(self, site_key, reservation_scope)
	if self.job_data and self.job_data[site_key] and self.release_reserved_position then
		self:release_reserved_position(reservation_scope, self.job_data[site_key])
	end
	if self.job_data then
		self.job_data[site_key] = nil
	end
end

local function can_place_shared_storage(self, pos)
	pos = vector.round(pos)
	if func.is_protected(self, pos) or working_villages.failed_pos_test(pos) then
		return false
	end
	if self.is_position_reserved and self:is_position_reserved("bootstrap_storage_site", pos) then
		return false
	end
	if working_villages.is_chest_pos and working_villages.is_chest_pos(pos) then
		return false
	end
	local node = minetest.get_node_or_nil(pos)
	local above = minetest.get_node_or_nil(vector.add(pos, {x = 0, y = 1, z = 0}))
	local below = minetest.get_node_or_nil(vector.add(pos, {x = 0, y = -1, z = 0}))
	if not node or not above or not below then
		return false
	end
	local node_def = minetest.registered_nodes[node.name]
	local above_def = minetest.registered_nodes[above.name]
	if not node_def or not node_def.buildable_to or not above_def or not above_def.buildable_to then
		return false
	end
	if minetest.get_item_group(below.name, "liquid") > 0 or not func.walkable_pos(vector.add(pos, {x = 0, y = -1, z = 0})) then
		return false
	end
	if func.find_adjacent_clear(pos) == false then
		return false
	end
	return has_storage_clearance(pos)
end

local function find_shared_storage_site(self)
	return func.search_surrounding(get_bootstrap_origin(self), function(pos)
		return can_place_shared_storage(self, pos)
	end, {x = 6, y = 2, z = 6, h = 1})
end

local function clear_bootstrap_storage_site(self)
	clear_reserved_site(self, "bootstrap_storage_site", "bootstrap_storage_site")
end

local function is_bootstrap_wood(name)
	return type(name) == "string" and name ~= "" and (
		minetest.get_item_group(name, "tree") > 0
		or minetest.get_item_group(name, "wood") > 0
	)
end

local BOOTSTRAP_WOOD_WAIT_SECONDS = 30
local BOOTSTRAP_WOOD_RETRY_SECONDS = 30

local function count_item_in_main(self, item_name)
	if type(item_name) ~= "string" or item_name == "" or not self.get_inventory then
		return 0
	end
	local inv = self:get_inventory()
	local total = 0
	for _, stack in ipairs(inv and inv:get_list("main") or {}) do
		if not stack:is_empty() and stack:get_name() == item_name then
			total = total + stack:get_count()
		end
	end
	return total
end

local function clear_bootstrap_wood_wait(self, keep_retry)
	self._bootstrap_wood_wait_until = nil
	self._bootstrap_wood_wait_item = nil
	self._bootstrap_wood_wait_baseline = nil
	if not keep_retry then
		self._bootstrap_wood_retry_after = nil
	end
	if self.job_data then
		self.job_data.bootstrap_wood_provider = nil
	end
end

-- The rendezvous is deliberately transient. Persisting an absolute game-time
-- deadline would turn a normal 30-second wait into a very long wait after a
-- server restart resets get_gametime(). A restart therefore safely falls back
-- to local gathering instead of reviving a stale delivery rendezvous.
local function hold_for_bootstrap_wood(self)
	local wait_until = tonumber(self._bootstrap_wood_wait_until)
	if not wait_until then
		return false, false
	end
	local now = tonumber(minetest.get_gametime()) or 0
	local requested_item = self._bootstrap_wood_wait_item
	local baseline = math.max(0, math.floor(tonumber(self._bootstrap_wood_wait_baseline) or 0))
	if requested_item and count_item_in_main(self, requested_item) > baseline then
		clear_bootstrap_wood_wait(self, false)
		return false, true
	end
	if now >= wait_until then
		clear_bootstrap_wood_wait(self, true)
		self._bootstrap_wood_retry_after = now + BOOTSTRAP_WOOD_RETRY_SECONDS
		self:set_displayed_action("reprend la recolte")
		self:set_state_info("Le bois promis n'est pas arrive; je reprends la recolte avant de redemander de l'aide.")
		return false, true
	end

	if self.object and self.object.set_velocity then
		self.object:set_velocity({x = 0, y = 0, z = 0})
	end
	if self.set_animation and working_villages.animation_frames then
		self:set_animation(working_villages.animation_frames.STAND)
	end
	self:set_displayed_action("attend du bois")
	self:set_state_info("Je reste au point de rendez-vous pendant qu'un villageois apporte le bois du premier coffre.")
	return true, false
end

-- Before the first chest exists, the village stock is spread across detached
-- villager inventories. Ask one actual carrier to walk the wood to the
-- bootstrap worker; counting village-wide wood alone does not make it
-- craftable by this entity.
local function request_bootstrap_wood(self, requested_count)
	if not comm or not comm.list_loaded_villagers or not comm.send_message then
		return false
	end
	self.job_data = self.job_data or {}
	local now = tonumber(minetest.get_gametime()) or 0
	local retry_after = tonumber(self._bootstrap_wood_retry_after)
	if retry_after and now < retry_after then
		return false
	elseif retry_after then
		self._bootstrap_wood_retry_after = nil
	end
	local last = tonumber(self.job_data.bootstrap_wood_request_time)
	if last and now >= last and now - last < 10 then
		return false
	end

	local best, best_name, best_count = nil, nil, 0
	for _, candidate in ipairs(comm.list_loaded_villagers()) do
		if candidate ~= self and (candidate.owner_name or "") == (self.owner_name or "")
				and candidate.get_inventory then
			local inv = candidate:get_inventory()
			for _, stack in ipairs(inv and inv:get_list("main") or {}) do
				if not stack:is_empty() and is_bootstrap_wood(stack:get_name())
						and stack:get_count() > best_count then
					best = candidate
					best_name = stack:get_name()
					best_count = stack:get_count()
				end
			end
		end
	end

	if not best or not best_name or best_count <= 0 then
		return false
	end
	local count = math.min(math.max(1, math.floor(tonumber(requested_count) or 8)), best_count)
	local baseline = count_item_in_main(self, best_name)
	local sent = comm.send_message(self, best, "help_needed", {
		items = {[best_name] = count},
		requester_id = self.inventory_name,
		bootstrap_infrastructure = true,
		info = "Bois necessaire pour fabriquer le premier coffre commun",
	})
	if sent then
		self.job_data.bootstrap_wood_request_time = now
		self.job_data.bootstrap_wood_provider = best.inventory_name
		self._bootstrap_wood_wait_until = now + BOOTSTRAP_WOOD_WAIT_SECONDS
		self._bootstrap_wood_wait_item = best_name
		self._bootstrap_wood_wait_baseline = baseline
		self._bootstrap_wood_retry_after = nil
		self:set_displayed_action("attend du bois")
		self:set_state_info("Un autre villageois m'apporte physiquement le bois du premier coffre.")
	end
	return sent
end

local function utility_resource_phrase(raw_name)
	local name = tostring(raw_name or ""):lower()
	if name:find("stone", 1, true) or name:find("cobble", 1, true)
			or name:find("rock", 1, true) then
		return "des pierres"
	end
	if name:find("wood", 1, true) or name:find("tree", 1, true)
			or name:find("log", 1, true) or name:find("plank", 1, true) then
		return "du bois"
	end
	if name:find("sand", 1, true) then
		return "du sable"
	end
	if name:find("clay", 1, true) then
		return "de l'argile"
	end
	return nil
end

local function describe_utility_crafting_wait(result, candidates)
	if type(result) ~= "table" then
		return nil
	end
	local candidate_set = {}
	for _, name in ipairs(candidates or {}) do
		candidate_set[name] = true
	end
	local specs = {}
	for raw, _ in pairs(result.missing_specs or {}) do
		specs[#specs + 1] = raw
	end
	table.sort(specs)
	for _, raw in ipairs(specs) do
		local phrase = utility_resource_phrase(raw)
		if phrase then
			return phrase
		end
	end
	local items = {}
	for name, _ in pairs(result.missing_items or {}) do
		if not candidate_set[name] then
			items[#items + 1] = name
		end
	end
	table.sort(items)
	for _, name in ipairs(items) do
		local phrase = utility_resource_phrase(name)
		if phrase then
			return phrase
		end
	end
	if #specs > 0 or #items > 0 then
		return "des materiaux"
	end
	if result.workstation_required == true then
		return "un etabli"
	end
	return nil
end

local function ensure_world_utility(self, config)
	self.job_data = self.job_data or {}
	local wait_key = config.site_key .. "_craft_wait"
	if config.find_existing and config.find_existing(self) then
		self.job_data[wait_key] = nil
		clear_reserved_site(self, config.site_key, config.reservation_scope)
		return false
	end

	local pending_site = self.job_data[config.site_key] ~= nil
	local item_name = get_candidate_item(self, config.candidates)
	if item_name then
		self.job_data[wait_key] = nil
	end
	self:count_timer(config.timer_id)
	if not pending_site and not item_name and not self:timer_exceeded(config.timer_id, config.interval or 40) then
		local waiting = self.job_data[wait_key]
		if waiting then
			set_action(self, waiting.action, waiting.info, nil)
			-- Keep the useful diagnostic visible without reserving the whole
			-- decision: ordinary gathering can still satisfy the missing recipe.
			return false
		end
		return false
	end

	local crafting_result = nil
	if not item_name and crafting and config.candidates and #config.candidates > 0 then
		item_name, crafting_result = crafting.ensure_any_item(self, config.candidates, 1, {
			use_shared_storage = config.use_shared_storage ~= false,
			fail_cooldown = config.fail_cooldown or 12,
			max_depth = config.max_depth or 4,
		})
	end
	if not item_name then
		local phrase = describe_utility_crafting_wait(crafting_result, config.candidates)
		if phrase then
			self.job_data[wait_key] = {
				action = "attend " .. phrase .. " pour " .. config.wait_target,
				info = "Il me manque " .. phrase .. " pour fabriquer "
					.. config.wait_target .. " du village.",
			}
		end
		local waiting = self.job_data[wait_key]
		if waiting then
			set_action(self, waiting.action, waiting.info, nil)
			-- A failed craft is information, not an exclusive activity. Let the
			-- autonomous worker continue with its stage-specific fallback work.
			return false
		end
		return false
	end
	self.job_data[wait_key] = nil

	local site = self.job_data[config.site_key] and vector.round(self.job_data[config.site_key])
		or find_bootstrap_utility_site(self, config.reservation_scope, config.is_present, config.site_opts)
	if not site then
		return false
	end
	if self.reserve_position and not self:reserve_position(config.reservation_scope, site, config.ttl or 20) then
		return false
	end
	self.job_data[config.site_key] = vector.round(site)

	local destination = func.find_adjacent_clear(site)
	if destination then
		destination = func.find_ground_below(destination) or destination
	end
	if destination and vector.distance(self.object:get_pos(), destination) > 4 then
		set_action(self, config.action, config.search_info, config.search_say)
		local reached = self:go_to(destination)
		if not reached then
			working_villages.failed_pos_record(site)
			clear_reserved_site(self, config.site_key, config.reservation_scope)
			return false
		end
		return true
	end

	set_action(self, config.action, config.place_info, config.place_say)
	local ok = self:place(item_name, site)
	clear_reserved_site(self, config.site_key, config.reservation_scope)
	if ok and (not config.is_present or config.is_present(site)) then
		if config.on_placed then
			config.on_placed(self, site)
		end
		return true
	end
	if not ok then
		working_villages.failed_pos_record(site)
	end
	return ok or false
end

local function ensure_shared_storage_bootstrap(self)
	self.job_data = self.job_data or {}
	if working_villages.get_shared_storage_pos and working_villages.is_chest_pos then
		local current = working_villages.get_shared_storage_pos(self.owner_name)
		if working_villages.is_chest_pos(current) then
			clear_bootstrap_wood_wait(self, false)
			clear_bootstrap_storage_site(self)
			return false
		end
	end

	local chest_item = has_storage_item(self)
	if chest_item then
		clear_bootstrap_wood_wait(self, false)
	end
	local waiting_for_wood, wait_released = hold_for_bootstrap_wood(self)
	if waiting_for_wood then
		return true
	end
	local pending_site = self.job_data.bootstrap_storage_site ~= nil
	self:count_timer("autonome:bootstrap")
	if not pending_site and not chest_item and not wait_released
			and not self:timer_exceeded("autonome:bootstrap", 40) then
		return false
	end

	if not chest_item and crafting then
		chest_item = crafting.ensure_any_item(self, storage_item_candidates, 1, {
			use_shared_storage = false,
			fail_cooldown = 20,
			max_depth = 3,
		})
	end
	if chest_item then
		clear_bootstrap_wood_wait(self, false)
	end
	if not chest_item then
		if request_bootstrap_wood(self, 8) then
			hold_for_bootstrap_wood(self)
			return true
		end
		return false
	end

	local storage_pos = self.job_data.bootstrap_storage_site and vector.round(self.job_data.bootstrap_storage_site) or find_shared_storage_site(self)
	if not storage_pos then
		return false
	end
	if not self:reserve_position("bootstrap_storage_site", storage_pos, 20) then
		return false
	end
	self.job_data.bootstrap_storage_site = vector.round(storage_pos)

	local destination = func.find_adjacent_clear(storage_pos)
	if destination then
		destination = func.find_ground_below(destination) or destination
	end
	if destination and vector.distance(self.object:get_pos(), destination) > 4 then
		set_action(self, "installe un coffre commun", "Je cherche un bon endroit pour le coffre commun.", "Je vais installer le premier coffre du village.")
		local reached = self:go_to(destination)
		if not reached then
			working_villages.failed_pos_record(storage_pos)
			clear_bootstrap_storage_site(self)
			return false
		end
		return true
	end

	set_action(self, "installe un coffre commun", "J'installe le coffre commun du village.", "J'installe le coffre commun du village.")
	local ok = self:place(chest_item, storage_pos)
	clear_bootstrap_storage_site(self)
	if ok and working_villages.is_chest_pos and working_villages.is_chest_pos(storage_pos) and working_villages.set_shared_storage_pos then
		if working_villages.set_shared_storage_pos(storage_pos, self.owner_name, self) then
			if self.announce_action then
				self:announce_action("Le coffre commun et le claim du village sont prets.", 180)
			end
			return true
		end
	end
	if not ok then
		working_villages.failed_pos_record(storage_pos)
	end
	return ok or false
end

local function ensure_crafting_table_bootstrap(self)
	if #workbench_item_candidates == 0 or not func.find_nearby_crafting_table then
		return false
	end
	return ensure_world_utility(self, {
		find_existing = function(villager)
			return func.find_nearby_crafting_table(villager, get_bootstrap_origin(villager), searching_range, "bootstrap_workbench_site")
		end,
		is_present = func.is_crafting_table,
		candidates = workbench_item_candidates,
		timer_id = "autonome:workbench_bootstrap",
		site_key = "bootstrap_workbench_site",
		reservation_scope = "bootstrap_workbench_site",
		action = "installe un etabli",
		wait_target = "l'etabli",
		search_info = "Je cherche un endroit pour poser l'etabli du village.",
		search_say = "Je vais poser un etabli pour l'artisanat du village.",
		place_info = "J'installe l'etabli du village.",
		place_say = "J'installe l'etabli du village.",
		site_opts = {
			min_clear_sides = 1,
			require_headroom = true,
			search_range = {x = 5, y = 1, z = 5, h = 1},
		},
	})
end

local function ensure_furnace_bootstrap(self)
	if #furnace_item_candidates == 0 then
		return false
	end
	return ensure_world_utility(self, {
		find_existing = function(villager)
			return func.find_nearby_furnace(villager, get_bootstrap_origin(villager), searching_range, "bootstrap_furnace_site")
		end,
		is_present = func.is_furnace,
		candidates = furnace_item_candidates,
		timer_id = "autonome:furnace_bootstrap",
		site_key = "bootstrap_furnace_site",
		reservation_scope = "bootstrap_furnace_site",
		action = "installe un four",
		wait_target = "le four",
		search_info = "Je cherche un endroit pour poser un four commun.",
		search_say = "Je vais installer un four pour le village.",
		place_info = "J'installe un four pour le village.",
		place_say = "J'installe un four pour le village.",
		site_opts = {
			min_clear_sides = 1,
			require_headroom = true,
			search_range = {x = 5, y = 1, z = 5, h = 1},
		},
	})
end

local function ensure_bootstrap_utilities(self, stage)
	if not working_villages.get_shared_storage_pos or not working_villages.is_chest_pos then
		return false
	end
	local shared_pos = working_villages.get_shared_storage_pos(self.owner_name)
	if not working_villages.is_chest_pos(shared_pos) then
		return false
	end
	-- Once infrastructure is already carried (or its placement site is
	-- persisted), finishing that physical action outranks the current economy
	-- stage. Otherwise a stage transition after a failed path can leave a real
	-- furnace/workbench in the worker's inventory while it goes exploring.
	self.job_data = self.job_data or {}
	if self.job_data.bootstrap_workbench_site
			or get_candidate_item(self, workbench_item_candidates) then
		if ensure_crafting_table_bootstrap(self) then
			return true
		end
	end
	if self.job_data.bootstrap_furnace_site
			or get_candidate_item(self, furnace_item_candidates) then
		if ensure_furnace_bootstrap(self) then
			return true
		end
	end
	if stage == "food" then
		return ensure_furnace_bootstrap(self)
	end
	if stage == "tools" or stage == "defense" or stage == "build" then
		if ensure_crafting_table_bootstrap(self) then
			return true
		end
		if ensure_furnace_bootstrap(self) then
			return true
		end
	end
	return false
end

local function is_keep_item(name)
	if minetest.get_item_group(name, "axe") > 0 then return true end
	if minetest.get_item_group(name, "pickaxe") > 0 then return true end
	if minetest.get_item_group(name, "hoe") > 0 then return true end
	if minetest.get_item_group(name, "sword") > 0 then return true end
	if minetest.get_item_group(name, "shield") > 0 then return true end
	for _, candidate in ipairs(storage_item_candidates) do
		if name == candidate then return true end
	end
	for _, candidate in ipairs(workbench_item_candidates) do
		if name == candidate then return true end
	end
	for _, candidate in ipairs(furnace_item_candidates) do
		if name == candidate then return true end
	end
	if minetest.get_item_group(name, "sapling") > 0 then return true end
	if minetest.get_item_group(name, "seed") > 0 then return true end
	if minetest.get_item_group(name, "food") > 0 then return true end
	return false
end

local function has_tool_group(self, group)
	return work_fallback.equip_tool(self, group)
end

local function get_axe_candidates()
	return compat.get_tool_items("axe", {"iron", "stone", "wood"})
end

local function get_hoe_candidates()
	return compat.get_tool_items("hoe", {"iron", "stone", "wood"})
end

local function get_weapon_candidates()
	return compat.get_tool_items("sword", {"iron", "stone", "wood"})
end

local function craft_supply(self, candidates)
	if not crafting or not candidates or #candidates == 0 then
		return false
	end
	return crafting.ensure_any_item(self, candidates, 1, {
		use_shared_storage = true,
		fail_cooldown = 8,
		max_depth = 4,
	}) ~= nil
end

local function reserve_target(self, scope, pos, ttl)
	if not self.reserve_position then
		return true
	end
	return self:reserve_position(scope, pos, ttl or 12)
end

local function release_target(self, scope, pos)
	if self.release_reserved_position then
		self:release_reserved_position(scope, pos)
	end
end

local AUTONOMOUS_HAND_LOG_LIMIT = 4
local AUTONOMOUS_HAND_LOG_RANGE = {x = 14, y = 5, z = 14}

local function autonomous_has_workbench(self)
	return func.find_nearby_crafting_table
		and func.find_nearby_crafting_table(
			self, self.object:get_pos(), {x = 14, y = 5, z = 14},
			"bootstrap_workbench_site") ~= nil
end

local function autonomous_stow_wield_for_hand(self)
	local wield = self:get_wield_item_stack()
	if not wield or wield:is_empty() then return true end
	local inv = self:get_inventory()
	if not inv or not inv:room_for_item("main", wield) then return false end
	local leftover = inv:add_item("main", wield)
	if leftover and not leftover:is_empty() then
		local moved = wield:get_count() - leftover:get_count()
		if moved > 0 then
			local rollback = ItemStack(wield)
			rollback:set_count(moved)
			inv:remove_item("main", rollback)
		end
		return false
	end
	self:set_wield_item_stack(ItemStack(""))
	return true
end

local function autonomous_tree_is_hand_diggable(self, pos)
	local node = minetest.get_node_or_nil(pos)
	local def = node and minetest.registered_nodes[node.name] or nil
	if not def or def.diggable == false
			or minetest.get_item_group(node.name, "tree") <= 0
			or func.is_protected(self, pos)
			or working_villages.failed_pos_test(pos)
			or (self.is_position_reserved and self:is_position_reserved("tree_target", pos)) then
		return false
	end
	local hand = working_villages.get_intrinsic_hand_stack
		and working_villages.get_intrinsic_hand_stack() or ItemStack("")
	local capabilities = hand:get_tool_capabilities()
	if not capabilities or next(capabilities.groupcaps or {}) == nil then return false end
	local params = minetest.get_dig_params(def.groups or {}, capabilities, 0)
	return params and params.diggable == true
end

-- The generalist owns the first workbench/chest bootstrap.  If a physical wood
-- delivery is delayed or its supplier disappears, it must not wait forever for
-- an axe that itself requires that workbench.  Collect only a small, persisted
-- allowance of engine-authorized hand-diggable logs, then return to the normal
-- recipe path.  This is real node_dig with the registered survival hand, not a
-- free inventory shortcut.
local function perform_autonomous_hand_bootstrap(self)
	if not compat.is_voxelibre or autonomous_has_workbench(self) then return false end
	self.job_data = self.job_data or {}
	local state = self.job_data.autonomous_hand_bootstrap
	if type(state) ~= "table" then
		state = {logs_dug = 0, limit = AUTONOMOUS_HAND_LOG_LIMIT}
		self.job_data.autonomous_hand_bootstrap = state
	end
	local dug = math.max(0, math.floor(tonumber(state.logs_dug) or 0))
	local limit = math.min(AUTONOMOUS_HAND_LOG_LIMIT,
		math.max(1, math.floor(tonumber(state.limit) or AUTONOMOUS_HAND_LOG_LIMIT)))
	state.limit = limit
	if state.completed or dug >= limit or not autonomous_stow_wield_for_hand(self) then
		state.completed = dug >= limit or state.completed == true
		return false
	end
	local target = func.search_surrounding(self.object:get_pos(), function(pos)
		return autonomous_tree_is_hand_diggable(self, pos)
	end, AUTONOMOUS_HAND_LOG_RANGE)
	if not target or not reserve_target(self, "tree_target", target, 20) then return false end
	local destination = func.find_adjacent_clear(target)
	if destination then destination = func.find_ground_below(destination) or destination end
	if not destination then
		release_target(self, "tree_target", target)
		return false
	end
	set_action(self, "recolte du bois initial a mains nues",
		("Je collecte le bois de mon premier etabli (%d/%d)."):format(dug, limit),
		"Je vais chercher moi-meme le bois du premier etabli.")
	local reached = self:go_to(destination)
	if not reached then
		release_target(self, "tree_target", target)
		working_villages.failed_pos_record(target)
		return false
	end
	local success = self:dig(target, true)
	release_target(self, "tree_target", target)
	if not success then
		working_villages.failed_pos_record(target)
		return false
	end
	state.logs_dug = dug + 1
	state.last_log_pos = vector.round(target)
	state.last_log_at = minetest.get_gametime()
	return true
end

local function find_nearby_blacksmith(self, radius)
	local villagers = comm and comm.find_nearby_villagers(self.object:get_pos(), radius or 25,
		"working_villages:job_blacksmith", self.owner_name) or {}
	for _, villager in ipairs(villagers) do
		if villager.owner_name == self.owner_name then
			return villager
		end
	end
	return nil
end

local function request_supply(self, order_key, tool_group, label, state_key)
	self.job_data = self.job_data or {}
	local now = minetest.get_gametime()
	local last = tonumber(self.job_data[state_key])
	if last and now >= last and now - last < 30 then
		return false
	end

	local ordered = false
	local smith = find_nearby_blacksmith(self, 25)
	if smith and blacksmith and blacksmith.enqueue_order then
		ordered = select(1, blacksmith.enqueue_order(smith, order_key, 1,
			self.owner_name or "", self.inventory_name))
	end
	if (not ordered) and blacksmith and blacksmith.enqueue_global_order then
		ordered = select(1, blacksmith.enqueue_global_order(order_key, 1,
			self.owner_name or "", self.inventory_name))
	end
	if not ordered and comm then
		comm.broadcast(self, comm.list_loaded_villagers(), "help_needed", {
			tool_group = tool_group,
			requester_id = self.inventory_name,
		})
	end
	if ordered or comm then
		self.job_data[state_key] = now
		self:set_state_info(ordered and ("Je demande " .. label .. ".") or ("Je cherche " .. label .. "."))
	end
	return ordered
end

local function ensure_autonomous_supplies(self)
	if not has_tool_group(self, "axe") then
		if self.take_tool_from_shared_storage and self:take_tool_from_shared_storage("axe") then
			return true
		end
		if craft_supply(self, get_axe_candidates()) then
			return true
		end
		request_supply(self, "axe_iron", "axe", "une hache", "autonome_axe_request_time")
		return false
	end
	if not has_tool_group(self, "hoe") then
		if self.take_tool_from_shared_storage and self:take_tool_from_shared_storage("hoe") then
			return true
		end
		if craft_supply(self, get_hoe_candidates()) then
			return true
		end
		request_supply(self, "hoe_iron", "hoe", "une houe", "autonome_hoe_request_time")
		return false
	end

	local danger_ticks = self.job_data and tonumber(self.job_data.danger_ticks) or 0
	if danger_ticks > 0 and self.is_weapon then
		local wield_name = self:get_wield_item_stack():get_name()
		if self:is_weapon(wield_name) then
			return true
		end
		if self:has_item_in_main(function(name) return self:is_weapon(name) end) then
			if self.equip_best_weapon then
				self:equip_best_weapon()
			end
			return true
		end
		if self.take_from_shared_storage_by_predicate then
			if self:take_from_shared_storage_by_predicate(function(name) return self:is_weapon(name) end, 1) then
				if self.equip_best_weapon then
					self:equip_best_weapon()
				end
				return true
			end
		end
		if craft_supply(self, get_weapon_candidates()) then
			if self.equip_best_weapon then
				self:equip_best_weapon()
			end
			return true
		end
		request_supply(self, "sword_iron", "sword", "une arme", "autonome_weapon_request_time")
	end

	return false
end

local function get_bootstrap_stage(self)
	if not working_villages.get_village_status then
		return "build"
	end
	local village = working_villages.get_village_status(self, 40)
	if not village then
		return "build"
	end
	return village.bootstrap_stage or working_villages.get_village_bootstrap_stage(village)
end

local function collect_any_drop(self, action, info, say_msg)
	if self:collect_nearest_item_by_condition(function() return true end, item_range) then
		set_action(self, action, info, say_msg)
		return true
	end
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
	if self.is_position_reserved and self:is_position_reserved("tree_target", pos) then
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
	if self.is_position_reserved and self:is_position_reserved("crop_target", pos) then
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

set_action = function(self, action, info, say_msg)
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
	if not reserve_target(self, "crop_target", target, 15) then
		return false
	end
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
		release_target(self, "crop_target", target)
		working_villages.failed_pos_record(target)
		return false
	end
	local plant_name = minetest.get_node(target).name
	local plant_data = farming_compat.get_plant(plant_name)
	success = self:dig(target, true)
	if not success then
		release_target(self, "crop_target", target)
		working_villages.failed_pos_record(target)
		return false
	end
	if plant_data and plant_data.replant then
		for index, value in ipairs(plant_data.replant) do
			self:place(value, vector.add(target, vector.new(0, index - 1, 0)))
		end
	end
	release_target(self, "crop_target", target)
	return true
end

local function chop_tree(self, target)
	if not work_fallback.equip_tool(self, "axe") then
		request_supply(self, "axe_iron", "axe", "une hache", "autonome_axe_request_time")
		return false
	end
	if not reserve_target(self, "tree_target", target, 15) then
		return false
	end
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
		release_target(self, "tree_target", target)
		working_villages.failed_pos_record(target)
		return false
	end
	success = self:dig(target, true)
	if not success then
		release_target(self, "tree_target", target)
		working_villages.failed_pos_record(target)
		return false
	end
	release_target(self, "tree_target", target)
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
	capabilities = {
		multi_tasking = true,
		autonomous_harvesting = true,
		tree_cutting = true,
		item_collection = true,
		exploration = true,
		self_sufficiency = true,
	},
	on_start = function(self)
		-- Notify player about autonomous capabilities
		self:notify_job_feature(
			"Travailleur polyvalent",
			"Récolte, coupe du bois, explore et ramasse des objets de façon autonome"
		)
	end,
	jobfunc = function(self)
		local danger_ticks = self.job_data and tonumber(self.job_data.danger_ticks) or 0
		if danger_ticks > 0 and self.equip_best_weapon then
			self:equip_best_weapon()
		end
		self:handle_night()
		self:handle_chest(take_func, put_func)
		self:handle_obstacles()

		self:count_timer("autonome:search")
		self:count_timer("autonome:supply")
		self:count_timer("autonome:explore")
		self:count_timer("autonome:change_dir")

		if compat.is_voxelibre then
			local shared_pos = working_villages.get_shared_storage_pos and
				working_villages.get_shared_storage_pos(self.owner_name) or nil
			if not (working_villages.is_chest_pos and working_villages.is_chest_pos(shared_pos)) then
				if ensure_crafting_table_bootstrap(self) then return end
				if perform_autonomous_hand_bootstrap(self) then return end
			end
		end

		if ensure_shared_storage_bootstrap(self) then
			return
		end

		local stage = get_bootstrap_stage(self)
		if ensure_bootstrap_utilities(self, stage) then
			return
		end

		if self:timer_exceeded("autonome:supply", 40) then
			ensure_autonomous_supplies(self)
		end

		if self:timer_exceeded("autonome:search", 10) then
			local target

			if stage == "wood" or stage == "storage" then
				target = func.search_surrounding(
					self.object:get_pos(),
					function(pos) return find_tree(self, pos) end,
					searching_range
				)
				if target and chop_tree(self, target) then
					return
				end
				if collect_any_drop(self, "ramasse des ressources", "Je rassemble des ressources pour le coffre commun.", "Je rassemble des ressources pour le village.") then
					return
				end
				target = func.search_surrounding(
					self.object:get_pos(),
					function(pos) return find_crop(self, pos) end,
					searching_range
				)
				if target and harvest_crop(self, target) then
					return
				end
			elseif stage == "food" then
				target = func.search_surrounding(
					self.object:get_pos(),
					function(pos) return find_crop(self, pos) end,
					searching_range
				)
				if target and harvest_crop(self, target) then
					return
				end
				if collect_any_drop(self, "ramasse de la nourriture", "Je cherche de quoi nourrir le village.", "Je cherche de quoi nourrir le village.") then
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
			elseif stage == "tools" or stage == "defense" then
				if collect_any_drop(self, "ramasse des fournitures", "Je cherche du materiel utile pour le village.", "Je cherche du materiel utile pour le village.") then
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
				target = func.search_surrounding(
					self.object:get_pos(),
					function(pos) return find_crop(self, pos) end,
					searching_range
				)
				if target and harvest_crop(self, target) then
					return
				end
			else
				target = func.search_surrounding(
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

				if collect_any_drop(self, "ramasse des objets", "Je ramasse ce que je trouve.", "Je ramasse ce que je trouve.") then
					return
				end
			end
		end

		if self:timer_exceeded("autonome:explore", 30) then
			local destination = pick_explore_target(self)
			set_action(self, "explore", "J'explore les alentours.", "J'explore les alentours.")
			self:go_to(destination)
			return
		end

		if self:timer_exceeded("autonome:change_dir", 25) then
			set_action(self, "cherche quelque chose a faire", "Je cherche quelque chose a faire.", nil)
			self:change_direction_randomly()
		end
	end,
})
