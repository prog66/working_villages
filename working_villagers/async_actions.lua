local fail = working_villages.require("failures")
local log = working_villages.require("log")
local func = working_villages.require("jobs/util")
local pathfinder = working_villages.require("pathfinder")
local timers = working_villages.require("timers")
local inventory_access = working_villages.inventory_access or working_villages.require("inventory_access")
local coroutine_can_yield = working_villages.coroutine_can_yield

local DEFAULT_CHEST_COOLDOWN = 24
local EMPTY_CHEST_RETRY_COOLDOWN = 20
local MAX_EMPTY_CHEST_RETRY_COOLDOWN = 40
local BLOCKED_CHEST_RETRY_COOLDOWN = 40
local CHEST_TRANSFER_WAIT_STEPS = 2
local MAX_DOOR_CALLBACK_WARNINGS = 32
local door_callback_warnings = {}
local door_callback_warning_count = 0
local door_callback_warning_limit_reported = false
local contained_dig_callback_warnings = {}
local contained_place_callback_warnings = {}

local function intrinsic_hand_stack()
	-- Minetest Game defines the hand on the empty item. VoxeLibre gives real
	-- players a registered mesh-hand stack whose generated groupcaps are the
	-- authoritative survival hand. Resolve it at call time because VoxeLibre
	-- finalizes those capabilities in register_on_mods_loaded.
	local empty = ItemStack("")
	local empty_caps = empty:get_tool_capabilities()
	if empty_caps and next(empty_caps.groupcaps or {}) ~= nil then
		return empty
	end

	local preferred = minetest.registered_items["mcl_meshhand:hand_surv"]
	if preferred and type(preferred._mcl_diggroups) == "table"
			and preferred.tool_capabilities
			and next(preferred.tool_capabilities.groupcaps or {}) ~= nil then
		return ItemStack("mcl_meshhand:hand_surv")
	end

	local candidates = {}
	for name, def in pairs(minetest.registered_items or {}) do
		local groupcaps = def and def.tool_capabilities and def.tool_capabilities.groupcaps
		-- Filled maps also expose `_mcl_hand_id` so their mesh follows the
		-- player's skin, but they are not usable digging hands. VoxeLibre's
		-- harvest callback iterates `_mcl_diggroups` without a nil guard for the
		-- hidden `hand` list, so only expose an item which fulfils that contract.
		if def and def._mcl_hand_id and type(def._mcl_diggroups) == "table"
				and next(def._mcl_diggroups) ~= nil
				and groupcaps and next(groupcaps) ~= nil
				and groupcaps.creative_breakable == nil then
			candidates[#candidates + 1] = name
		end
	end
	table.sort(candidates)
	if candidates[1] then
		return ItemStack(candidates[1])
	end
	return empty
end

-- Public only so profession-specific bootstrap gates and runtime regressions
-- can ask the same question as dig(). It returns the game's registered hand;
-- the stack is never inserted into a villager inventory.
function working_villages.get_intrinsic_hand_stack()
	return ItemStack(intrinsic_hand_stack())
end

local function make_fake_player(self, facedir)
	local function effective_wielded_item()
		local wield = self:get_wield_item_stack()
		if wield and not wield:is_empty() then
			return wield
		end
		return intrinsic_hand_stack()
	end
	local inventory = self:get_inventory()
	local fake_inventory = setmetatable({}, {
		__index = function(_, key)
			if key == "get_stack" then
				return function(_, listname, index)
					if listname == "hand" and index == 1 then
						return intrinsic_hand_stack()
					end
					return inventory:get_stack(listname, index)
				end
			end
			local member = inventory[key]
			if type(member) == "function" then
				return function(_, ...)
					return member(inventory, ...)
				end
			end
			return member
		end,
	})
	return {
		is_player = function() return true end,
		get_player_name = function() return self.owner_name or "working_villages" end,
		get_player_control = function() return {sneak = true} end,
		get_pos = function()
			if self.object then
				return self.object:get_pos()
			end
			return {x = 0, y = 0, z = 0}
		end,
		get_look_dir = function()
			if facedir ~= nil and minetest.facedir_to_dir then
				return minetest.facedir_to_dir(facedir)
			end
			local yaw = self.object and self.object:get_yaw() or 0
			return minetest.yaw_to_dir(yaw)
		end,
		-- VoxeLibre's harvest callback reads the player's dedicated hidden
		-- `hand` inventory list rather than get_wielded_item(). Expose the same
		-- intrinsic stack through a read-compatible proxy while delegating all
		-- real cargo operations to the villager's detached inventory.
		get_inventory = function() return fake_inventory end,
		get_wielded_item = effective_wielded_item,
		set_wielded_item = function(_, stack)
			local current = self:get_wield_item_stack()
			local hand = intrinsic_hand_stack()
			-- node_dig writes its effective wielded stack back after applying
			-- wear. An intrinsic hand is not cargo, so keep the real slot empty.
			if current:is_empty() and stack:get_name() == hand:get_name() then
				return true
			end
			self:set_wield_item_stack(stack)
			return true
		end,
		get_wield_index = function() return 1 end,
		get_wield_list = function() return "wield_item" end,
	}
end

local function is_door_item(item)
	if type(item) ~= "table" or type(item.name) ~= "string" then
		return false
	end
	local compat = working_villages.voxelibre_compat
	local material_name = working_villages.buildings.get_registered_nodename(item.name)
	return compat.is_door(item.name) or compat.is_door(material_name)
end

local function placement_is_protected(self, item, pos)
	if func.is_protected(self, pos) then
		return true
	end
	if is_door_item(item) then
		return func.is_protected(self, vector.add(pos, {x = 0, y = 1, z = 0}))
	end
	return false
end

local function restore_nodes(nodes)
	for _, entry in ipairs(nodes) do
		minetest.set_node(entry.pos, entry.node)
	end
end

local function callback_error_summary(callback_error)
	local summary = tostring(callback_error):match("^[^\r\n]+") or tostring(callback_error)
	return summary:sub(1, 300)
end

local function warn_complete_synthetic_door_callback(material_name, pos, callback_error)
	local summary = callback_error_summary(callback_error)
	local key = material_name .. "|" .. summary
	if door_callback_warnings[key] then
		return
	end
	if door_callback_warning_count >= MAX_DOOR_CALLBACK_WARNINGS then
		if not door_callback_warning_limit_reported then
			door_callback_warning_limit_reported = true
			log.warning("additional distinct offline door callback incompatibilities are suppressed")
		end
		return
	end
	door_callback_warnings[key] = true
	door_callback_warning_count = door_callback_warning_count + 1
	-- Offline villagers cannot provide engine-owned PlayerRef state (for
	-- example VoxeLibre's per-player documentation cache). The craftitem still
	-- placed and validated both halves before this downstream callback failed;
	-- keeping the pair and consuming exactly one item matches the visible world.
	log.warning(
		"door %s was placed completely, but a callback rejected the offline "
			.. "synthetic player at %s: %s; identical warnings are suppressed",
		material_name,
		minetest.pos_to_string(pos),
		summary
	)
end

local function place_door_item(self, item, pos, stack, placer, pointed_thing)
	local material_name = working_villages.buildings.get_registered_nodename(item.name)
	local itemdef = minetest.registered_items[material_name]
	if not itemdef or type(itemdef.on_place) ~= "function" then
		return nil, fail.blocked
	end

	local top_pos = vector.add(pos, {x = 0, y = 1, z = 0})
	local before = {
		{pos = vector.new(pos), node = minetest.get_node(pos)},
		{pos = top_pos, node = minetest.get_node(top_pos)},
	}
	local original_stack = ItemStack(stack)
	local callback_ok, callback_result = pcall(
		itemdef.on_place,
		ItemStack(stack),
		placer,
		pointed_thing
	)
	local bottom = minetest.get_node(pos)
	local top = minetest.get_node(top_pos)
	local pair_ok = working_villages.buildings.door_pair_matches_item(
		item.name, bottom.name, top.name)
	if not pair_ok then
		if bottom.name ~= before[1].node.name or bottom.param2 ~= before[1].node.param2
				or top.name ~= before[2].node.name or top.param2 ~= before[2].node.param2 then
			restore_nodes(before)
		end
		if not callback_ok then
			-- This is a real failed world mutation, not the contained offline-
			-- actor case below: keep it visible as an error after rolling back.
			log.error("door on_place failed before completing the pair at %s: %s",
				minetest.pos_to_string(pos), tostring(callback_result))
		end
		return nil, fail.blocked
	end

	if not callback_ok then
		-- Some third-party registered_on_placenode callbacks assume a genuine
		-- PlayerRef and can reject an offline actor after the game has already
		-- placed both halves. The world mutation is complete, so consume exactly
		-- one item and contain the callback failure instead of duplicating it.
		warn_complete_synthetic_door_callback(material_name, pos, callback_result)
	end
	original_stack:take_item(1)
	return original_stack
end

local function normalize_destination(pos)
	local destination = vector.round(pos)
	if func.walkable_pos(destination) then
		destination = pathfinder.get_ground_level(vector.round(destination))
	end
	return destination
end

local function try_path_candidate(self, start_pos, candidate, seen)
	if not candidate or candidate == false then
		return nil, nil
	end
	candidate = vector.round(candidate)
	local key = minetest.hash_node_position(candidate)
	if seen[key] then
		return nil, nil
	end
	seen[key] = true
	if func.walkable_pos(candidate) then
		candidate = pathfinder.get_ground_level(candidate)
	elseif not func.clear_pos(candidate) then
		candidate = func.find_adjacent_clear(candidate)
		if candidate == false then
			return nil, nil
		end
		local ground = func.find_ground_below(candidate)
		if ground and ground ~= false then
			candidate = ground
		end
	end
	if not candidate then
		return nil, nil
	end
	local path = pathfinder.find_path(start_pos, candidate, self)
	if path then
		return candidate, path
	end
	return nil, nil
end

local function find_path_or_fallback(self, start_pos, destination)
	local target = normalize_destination(destination)
	local path = pathfinder.find_path(start_pos, target, self)
	if path then
		return target, path
	end

	local seen = {
		[minetest.hash_node_position(target)] = true,
	}
	local candidate, fallback = try_path_candidate(self, start_pos, func.find_adjacent_clear(target), seen)
	if fallback then
		return candidate, fallback
	end

	for radius = 1, 4 do
		for dx = -radius, radius do
			for dz = -radius, radius do
				if math.abs(dx) == radius or math.abs(dz) == radius then
					candidate, fallback = try_path_candidate(self, start_pos, {
						x = target.x + dx,
						y = target.y,
						z = target.z + dz,
					}, seen)
					if fallback then
						return candidate, fallback
					end
				end
			end
		end
	end

	return target, nil
end

-- Advance one pathfinding step from an engine callback without yielding.  The
-- state is separate from self.path/self.destination so an emergency retreat
-- cannot corrupt a suspended job coroutine that is already inside go_to().
function working_villages.villager:cancel_go_to_step(state_key, stop_motion)
	local states = self._step_navigations
	if type(states) ~= "table" or states[state_key] == nil then
		return false
	end
	states[state_key] = nil
	if next(states) == nil then
		self._step_navigations = nil
	end
	if stop_motion and self.object then
		self.object:set_velocity({x = 0, y = 0, z = 0})
		self:set_animation(working_villages.animation_frames.STAND)
	end
	return true
end

function working_villages.villager:go_to_step(pos, state_key)
	state_key = tostring(state_key or "engine_callback")
	local requested = vector.round(pos)
	local current = func.validate_pos(self.object:get_pos())
	if not current then
		return false, fail.no_path
	end

	self._step_navigations = self._step_navigations or {}
	local state = self._step_navigations[state_key]
	if not state or not vector.equals(state.requested, requested) then
		local destination, path = find_path_or_fallback(self, current, requested)
		state = {
			requested = requested,
			destination = destination,
			path = path,
			direct_fallback = path == nil,
			last_pos = vector.round(self.object:get_pos()),
			stuck = 0,
			repath_timer = 0,
			give_up = 0,
		}
		if state.path == nil then
			state.path = {state.destination}
		end
		self._step_navigations[state_key] = state
	end

	local logical_step = timers.increment(self)
	state.repath_timer = (state.repath_timer or 0) + logical_step
	current = vector.round(self.object:get_pos())
	if state.last_pos and vector.equals(current, state.last_pos) then
		state.stuck = (state.stuck or 0) + 1
	else
		state.last_pos = current
		state.stuck = 0
	end

	if state.stuck >= 10 then
		for _, obj in ipairs(minetest.get_objects_inside_radius(current, 1.2)) do
			if obj ~= self.object then
				local lua = obj:get_luaentity()
				if lua and working_villages.is_villager(lua.name) then
					self:change_direction_randomly()
					state.stuck = 0
					break
				end
			end
		end
	end
	if state.stuck == 20 then
		self:jump()
	end

	if state.stuck >= 40 or state.repath_timer >= 100 then
		state.stuck = 0
		state.repath_timer = 0
		local destination, path = find_path_or_fallback(self, current, state.requested)
		if path == nil then
			state.give_up = (state.give_up or 0) + logical_step
			if state.direct_fallback or state.give_up >= 3 then
				self:cancel_go_to_step(state_key, true)
				return false, fail.no_path
			end
			state.destination = destination
			state.path = {destination}
			state.direct_fallback = true
		else
			state.destination = destination
			state.path = path
			state.direct_fallback = false
			state.give_up = 0
		end
	end

	while state.path and state.path[1]
			and self:is_near({
				x = state.path[1].x,
				y = self.object:get_pos().y,
				z = state.path[1].z,
			}, 1) do
		table.remove(state.path, 1)
	end
	if not state.path or #state.path == 0 then
		self:cancel_go_to_step(state_key, true)
		return true
	end

	self:change_direction(state.path[1])
	self:handle_obstacles(true)
	self:set_animation(working_villages.animation_frames.WALK)
	return nil
end

local function clear_go_to_runtime(self)
	self.path = nil
	self._go_to_last_pos = nil
	self._go_to_stuck = nil
	self._go_to_direct_fallback = nil
	self._go_to_best_distance = nil
	self._go_to_last_progress_at = nil
	self._go_to_progress_repaths = nil
	self._go_to_started_at = nil
end

--TODO: add variable precision
function working_villages.villager:go_to(pos)
	-- Entity on_step and other engine callbacks run across a C boundary.  A
	-- multi-step path can only yield from a job-owned Lua coroutine.  Outside
	-- one, perform a safe steering step without touching the suspended job's
	-- path state; the next engine step will steer again.
	if not coroutine_can_yield() then
		return self:go_to_step(pos, "engine_callback")
	end

	self.destination=vector.round(pos)
	local val_pos = func.validate_pos(self.object:get_pos())
	self.destination, self.path = find_path_or_fallback(self, val_pos, self.destination)
	self:set_timer("go_to:find_path",0) -- find path interval
	self:set_timer("go_to:change_dir",0)
	self:set_timer("go_to:give_up",0)
	self._go_to_last_pos = vector.round(self.object:get_pos())
	self._go_to_stuck = 0
	self._go_to_direct_fallback = false
	self._go_to_best_distance = vector.distance(self.object:get_pos(), self.destination)
	self._go_to_last_progress_at = minetest.get_us_time() / 1000000
	self._go_to_progress_repaths = 0
	self._go_to_started_at = self._go_to_last_progress_at
	if self.path == nil then
		self.path = {self.destination}
		self._go_to_direct_fallback = true
	end
	--print("the first waypiont on his path:" .. minetest.pos_to_string(self.path[1]))
	self:change_direction(self.path[1])
	self:set_animation(working_villages.animation_frames.WALK)

	while #self.path ~= 0 do
		self:count_timer("go_to:find_path")
		self:count_timer("go_to:change_dir")
		local current_pos = vector.round(self.object:get_pos())
		local progress_now = minetest.get_us_time() / 1000000
		if progress_now - (self._go_to_started_at or progress_now) >= 45 then
			-- A path which only oscillates or crawls must not monopolize a worker.
			-- The caller records the target as failed and immediately gets a chance
			-- to select a different resource or fallback task.
			clear_go_to_runtime(self)
			self.object:set_velocity({x = 0, y = 0, z = 0})
			self:set_animation(working_villages.animation_frames.STAND)
			return false, fail.no_path
		end
		local remaining_distance = vector.distance(self.object:get_pos(), self.destination)
		if remaining_distance + 0.5 < (self._go_to_best_distance or math.huge) then
			self._go_to_best_distance = remaining_distance
			self._go_to_last_progress_at = progress_now
			self._go_to_progress_repaths = 0
		elseif progress_now - (self._go_to_last_progress_at or progress_now) >= 12 then
			-- Rounded-position checks miss villagers which oscillate across a node
			-- boundary without getting any closer. Repath once using monotonic real
			-- time, then abandon the target after a second no-progress window so the
			-- profession can select useful work elsewhere.
			if (self._go_to_progress_repaths or 0) >= 1 then
				clear_go_to_runtime(self)
				self.object:set_velocity({x = 0, y = 0, z = 0})
				self:set_animation(working_villages.animation_frames.STAND)
				return false, fail.no_path
			end
			val_pos = func.validate_pos(self.object:get_pos())
			local destination, path = find_path_or_fallback(self, val_pos, self.destination)
			self.destination = destination
			self.path = path or {destination}
			self._go_to_direct_fallback = path == nil
			self._go_to_best_distance = vector.distance(self.object:get_pos(), destination)
			self._go_to_last_progress_at = progress_now
			self._go_to_progress_repaths = 1
			self:change_direction(self.path[1])
		end
		if self._go_to_last_pos and vector.equals(current_pos, self._go_to_last_pos) then
			self._go_to_stuck = (self._go_to_stuck or 0) + 1
		else
			self._go_to_last_pos = current_pos
			self._go_to_stuck = 0
		end

		if self._go_to_stuck >= 10 then
			-- If another villager blocks the path, sidestep to avoid deadlock.
			local blockers = minetest.get_objects_inside_radius(current_pos, 1.2)
			for _, obj in ipairs(blockers) do
				if obj ~= self.object then
					local lua = obj:get_luaentity()
					if lua and working_villages.is_villager(lua.name) then
						self:change_direction_randomly()
						self:set_timer("go_to:change_dir", 0)
						self._go_to_stuck = 0
						break
					end
				end
			end
		end

		if self._go_to_stuck == 20 then
			self:jump()
		end
		if self._go_to_stuck >= 40 then
			self._go_to_stuck = 0
			val_pos = func.validate_pos(self.object:get_pos())
			local destination, path = find_path_or_fallback(self, val_pos, self.destination)
			if path == nil then
				if self._go_to_direct_fallback then
					clear_go_to_runtime(self)
					return false, fail.no_path
				end
				self:count_timer("go_to:give_up")
				if self:timer_exceeded("go_to:give_up",3) then
					print("villager is stuck on path to "..minetest.pos_to_string(val_pos))
					clear_go_to_runtime(self)
					return false, fail.no_path
				end
			else
				self.destination = destination
				self.path = path
				self._go_to_direct_fallback = false
				self:change_direction(self.path[1])
			end
		end
		if self:timer_exceeded("go_to:find_path",100) then
			val_pos = func.validate_pos(self.object:get_pos())
			local destination, path = find_path_or_fallback(self, val_pos, self.destination)
			if path == nil then
				if self._go_to_direct_fallback then
					clear_go_to_runtime(self)
					return false, fail.no_path
				end
				self:count_timer("go_to:give_up")
				if self:timer_exceeded("go_to:give_up",3) then
					print("villager can't find path to "..minetest.pos_to_string(val_pos))
					clear_go_to_runtime(self)
					return false, fail.no_path
				end
			else
				self.destination = destination
				self.path = path
				self._go_to_direct_fallback = false
			end
		end

		if self:timer_exceeded("go_to:change_dir",30) then
			self:change_direction(self.path[1])
		end

		-- follow path
		if self:is_near({x=self.path[1].x,y=self.object:get_pos().y,z=self.path[1].z}, 1) then
			table.remove(self.path, 1)

			if #self.path == 0 then -- end of path
				 --keep walking another step for good measure
				coroutine.yield()
				break
			else -- else next step, follow next path.
				self:set_timer("go_to:find_path",0)
				self:change_direction(self.path[1])
			end
		end
		-- if vilager is stopped by obstacles, the villager must jump.
		self:handle_obstacles(true)
		-- end step
		coroutine.yield()
	end
	-- stop
	self.object:set_velocity{x = 0, y = 0, z = 0}
	clear_go_to_runtime(self)
	self:set_animation(working_villages.animation_frames.STAND)
	return true
end

function working_villages.villager:collect_nearest_item_by_condition(cond, searching_range)
	local item = self:get_nearest_item_by_condition(cond, searching_range)
	if item == nil then
		return false
	end
	local pos = item:get_pos()
	--print("collecting item at:".. minetest.pos_to_string(pos))
	local inv=self:get_inventory()
	if inv:room_for_item("main", ItemStack(item:get_luaentity().itemstring)) then
		if coroutine_can_yield() then
			self:go_to(pos)
			self:pickup_item()
			return true
		else
			-- Avoid yielding from on_step (C callback)
			if self:is_near(pos, 2) then
				self:pickup_item()
				return true
			end
		end
	end
	return false
end

-- delay the async action by @step_count steps
function working_villages.villager:delay(step_count)
	if not coroutine_can_yield() then
		return false
	end
	for _=0,step_count do
		coroutine.yield()
	end
	return true
end

local drop_range = {x = 2, y = 10, z = 2}

function working_villages.villager:dig(pos,collect_drops,animation_steps)
	if func.is_protected(self, pos) then return false, fail.protected end
	local destnode = minetest.get_node(pos)
	local def_node = minetest.registered_nodes[destnode.name]
	if not def_node or def_node.diggable == false then
		return false, fail.dig_fail
	end

	local fake_player = make_fake_player(self)
	if def_node.can_dig and not def_node.can_dig(vector.copy(pos), fake_player) then
		return false, fail.dig_fail
	end

	-- node_dig assumes that the engine has already validated the tool. Villagers
	-- do not go through the engine's punch timer, so perform the same gate here.
	local wielded = fake_player:get_wielded_item()
	local tool_capabilities = wielded and wielded:get_tool_capabilities() or nil
	-- An empty ItemStack does not expose the game's hand capabilities through
	-- get_tool_capabilities(), although a real player can still dig leaves,
	-- grass, flowers and other hand-diggable nodes.  Without this fallback an
	-- unequipped villager could not even clear harmless vegetation and would
	-- retry the same construction/farming step forever.
	if (not wielded or wielded:is_empty()) and minetest.registered_items then
		local hand_definition = minetest.registered_items[""]
		tool_capabilities = hand_definition and hand_definition.tool_capabilities
			or tool_capabilities
	end
	local dig_params = minetest.get_dig_params(
		def_node.groups or {},
		tool_capabilities,
		wielded and wielded:get_wear() or 0)
	if not dig_params or not dig_params.diggable then
		return false, fail.dig_fail
	end

	self.object:set_velocity{x = 0, y = 0, z = 0}
	local dist = vector.subtract(pos, self.object:get_pos())
	if vector.length(dist) > 5 then
		self:set_animation(working_villages.animation_frames.STAND)
		return false, fail.too_far
	end
	self:set_animation(working_villages.animation_frames.MINE)
	self:set_yaw_by_direction(dist)
	if coroutine_can_yield() then
		local wait_steps = math.max(0, math.floor(tonumber(animation_steps) or 30))
		for _ = 1, wait_steps do coroutine.yield() end
	end

	-- The target can change while the coroutine is waiting. Never dig a newly
	-- placed block with the validation performed for the previous one.
	local current_node = minetest.get_node(pos)
	if current_node.name ~= destnode.name or func.is_protected(self, pos) then
		self:set_animation(working_villages.animation_frames.STAND)
		return false, fail.dig_fail
	end

	-- Protection and the node's can_dig callback were already evaluated above
	-- with the real owner identity. The object passed to post-dig hooks is an
	-- NPC, not an offline PlayerRef: exposing the owner's non-connected player
	-- name makes player-only hooks (notably VoxeLibre's documentation unlocker)
	-- index session data which cannot exist. Cargo and wield methods still
	-- delegate to the villager, so normal drops and wear remain authoritative.
	local callback_player = make_fake_player(self)
	local owner_name = callback_player.get_player_name()
	callback_player._working_villages_owner_name = owner_name
	callback_player.get_player_name = function() return "" end
	-- node_dig performs its own protection check with get_player_name().  The
	-- synthetic player must stay anonymous for player-only callbacks, but our
	-- village claim still needs to recognise this exact, already-authorised NPC
	-- operation. The API keeps an exact-position, one-shot frame on this job
	-- coroutine, so yields and nested villagers cannot leak or overwrite it.
	local ok, dug = working_villages.with_npc_claim_protection_context(
		owner_name,
		pos,
		minetest.node_dig,
		pos,
		current_node,
		callback_player
	)
	self:set_animation(working_villages.animation_frames.STAND)
	if not ok then
		-- Offline synthetic actors can reach player-only callbacks after the
		-- engine has already transferred drops and removed the node (VoxeLibre's
		-- documentation reveal hook is one example). The mutation is then
		-- complete and must not be retried or it would corrupt accounting.
		if minetest.get_node(pos).name ~= current_node.name then
			local summary = callback_error_summary(dug)
			local key = current_node.name .. "|" .. summary
			if not contained_dig_callback_warnings[key] then
				contained_dig_callback_warnings[key] = true
				log.warning(
					"dig of %s completed at %s, but a downstream offline-player "
						.. "callback failed: %s; identical warnings are suppressed",
					current_node.name,
					minetest.pos_to_string(pos),
					summary
				)
			end
			if collect_drops and self.pickup_item then
				self:pickup_item()
			end
			return true
		end
		log.error("villager dig callback failed at %s: %s",
			minetest.pos_to_string(pos), tostring(dug))
		return false, fail.dig_fail
	end
	if dug == false or minetest.get_node(pos).name == current_node.name then
		return false, fail.dig_fail
	end
	if collect_drops and self.pickup_item then
		-- node_dig has already routed normal drops to the villager inventory.
		-- This only collects close extra drops created by mod callbacks.
		self:pickup_item()
	end
	return true
end

function working_villages.villager:place(item,pos)
	if type(pos)~="table" then
		error("no target position given")
	end
	if placement_is_protected(self,item,pos) then return false, fail.protected end
	local dist = vector.subtract(pos, self.object:get_pos())
	if vector.length(dist) > 5 then
		return false, fail.too_far
	end
	local destnode = minetest.get_node(pos)
	local destdef = minetest.registered_nodes[destnode.name]
	if not destdef or not destdef.buildable_to then
	 return false, fail.blocked
	end
	local find_item = function(name)
		if type(item)=="string" then
			return name == working_villages.buildings.get_registered_nodename(item)
		elseif type(item)=="table" then
			return name == working_villages.buildings.get_registered_nodename(item.name)
		elseif type(item)=="function" then
			return item(name)
		else
			log.error("got %s instead of an item",item)
			error("no item to place given")
		end
	end
	local wield_stack = self:get_wield_item_stack()
	--move item to wield
	if not (find_item(wield_stack:get_name()) or self:move_main_to_wield(find_item)) then
	 return false, fail.not_in_inventory
	end
	--set animation
	if self.object:get_velocity().x==0 and self.object:get_velocity().z==0 then
		self:set_animation(working_villages.animation_frames.MINE)
	else
		self:set_animation(working_villages.animation_frames.WALK_MINE)
	end
	--turn to target
	self:set_yaw_by_direction(dist)
	-- Animate over several job steps when called from a coroutine.  Maintenance
	-- may also place a node directly from on_step; in that case all accounting
	-- and protection checks still run, but no illegal yield is attempted.
	local may_yield = coroutine_can_yield()
	if may_yield then
		for _=0,15 do coroutine.yield() end
	end
	-- The world and detached inventory can change while the animation yields.
	-- Revalidate both immediately before mutating the map so a newly protected
	-- or occupied node is never overwritten and a removed material cannot be
	-- replaced for free.
	if placement_is_protected(self, item, pos) then
		return false, fail.protected
	end
	local current_destnode = minetest.get_node(pos)
	local current_destdef = minetest.registered_nodes[current_destnode.name]
	if not current_destdef or not current_destdef.buildable_to then
		return false, fail.blocked
	end
	--get wielded item
	local stack = self:get_wield_item_stack()
	if stack:is_empty() or not find_item(stack:get_name()) then
		return false, fail.not_in_inventory
	end
	--create pointed_thing facing upward
	--TODO: support given pointed thing via function parameter
	local pointed_thing = {
		type = "node",
		above = pos,
		under = vector.add(pos, {x = 0, y = -1, z = 0}),
	}
	--TODO: try making a placer
	local itemname = stack:get_name()
	local placer = self
	if not (self.is_player and self:is_player()) then
		local facedir = type(item) == "table" and item.param2 or nil
		placer = make_fake_player(self, facedir)
	end
	--place item
	if type(item)=="table" then
		if is_door_item(item) then
			local placed_stack, place_error = place_door_item(
				self, item, pos, stack, placer, pointed_thing)
			if not placed_stack then
				return false, place_error
			end
			stack = placed_stack
		else
			local placed_node = {
				name = working_villages.buildings.get_registered_nodename(item.name),
				param1 = item.param1 or 0,
				param2 = item.param2 or 0,
			}
			local placed_def = minetest.registered_nodes[placed_node.name]
			if not placed_def then
				return false, fail.blocked
			end

			-- Engine versions and games disagree about the return value and callback
			-- behavior of minetest.place_node().  Construction accounting must use
			-- the world as the authority: place the explicit schematic node, run its
			-- initialization hooks, then consume exactly one item only if the node is
			-- still present.  This prevents a reported-success/air result from eating
			-- materials forever on a retried building step.
			minetest.set_node(pointed_thing.above, placed_node)
			if type(placed_def.on_construct) == "function" then
				local ok, err = pcall(placed_def.on_construct, pointed_thing.above)
				if not ok then
					log.error("node construction callback failed at %s: %s",
						minetest.pos_to_string(pointed_thing.above), tostring(err))
				end
			end
			if type(placed_def.after_place_node) == "function" then
				local ok, err = pcall(placed_def.after_place_node,
					pointed_thing.above, placer, ItemStack(stack), pointed_thing)
				if not ok then
					log.error("after-place callback failed at %s: %s",
						minetest.pos_to_string(pointed_thing.above), tostring(err))
				end
			end
			if minetest.get_node(pointed_thing.above).name ~= placed_node.name then
				return false, fail.blocked
			end
			stack:take_item(1)
		end
	else
		local before_node = minetest.get_node(pos)
		local before_count = stack:get_count()
		local itemdef = stack:get_definition()
		local callback_ok = true
		local callback_result = stack
		if itemdef.on_place then
			callback_ok, callback_result = pcall(
				itemdef.on_place, stack, placer, pointed_thing)
		elseif itemdef.type=="node" then
			callback_ok, callback_result = pcall(
				minetest.item_place_node, stack, placer, pointed_thing)
		end
		if callback_ok and callback_result ~= nil then
			stack = callback_result
		end
		local after_node = minetest.get_node(pos)
		-- if the node didn't change, then the callback failed
		if before_node.name == after_node.name then
			if not callback_ok then
				log.error("villager place callback failed at %s: %s",
					minetest.pos_to_string(pos), tostring(callback_result))
			end
			return false, fail.protected
		end
		if not callback_ok then
			-- Some games invoke PlayerRef-only hooks after the node is already in
			-- the map.  The visible placement is authoritative: contain that
			-- downstream failure and consume exactly one stack item so a retry
			-- cannot duplicate chests, workbenches, furnaces or other utilities.
			local summary = callback_error_summary(callback_result)
			local key = itemname .. "|" .. summary
			if not contained_place_callback_warnings[key] then
				contained_place_callback_warnings[key] = true
				log.warning(
					"placement of %s completed at %s, but a downstream offline-player "
						.. "callback failed: %s; identical warnings are suppressed",
					itemname,
					minetest.pos_to_string(pos),
					summary
				)
			end
		end
		-- if in creative mode, the callback may not reduce the stack
		if before_count == stack:get_count() then
			stack:take_item(1)
		end
	end
	--take item
	self:set_wield_item_stack(stack)
	if may_yield then
		coroutine.yield()
	end
	--handle sounds
	local sounds = minetest.registered_nodes[itemname]
	if sounds then
		if sounds.sounds then
			local sound = sounds.sounds.place
			if sound then
				minetest.sound_play(sound,{object=self.object, max_hear_distance = 10})
			end
		end
	end
	--reset animation
	if self.object:get_velocity().x==0 and self.object:get_velocity().z==0 then
		self:set_animation(working_villages.animation_frames.STAND)
	else
		self:set_animation(working_villages.animation_frames.WALK)
	end
	self._last_placed_node = {
		pos = vector.round(pos),
		node_name = minetest.get_node(pos).name,
		at_us = type(minetest.get_us_time) == "function" and minetest.get_us_time() or nil,
	}

	return true
end

function working_villages.villager:manipulate_chest(chest_pos, take_func, put_func, data)
	local result = {
		moved_any = false,
		put_candidates = 0,
		take_candidates = 0,
		blocked_put = 0,
		blocked_take = 0,
	}
	if func.is_chest(chest_pos) then
		self:use_node(chest_pos)
		local vil_inv = self:get_inventory()
		local function get_chest_inv(pos)
			return minetest.get_meta(pos or chest_pos):get_inventory()
		end
		local function wait_after_transfer()
			if not coroutine_can_yield() then
				return
			end
			for _ = 1, CHEST_TRANSFER_WAIT_STEPS do
				coroutine.yield()
			end
		end
		local function reserve_shared_storage(pos)
			if data and data.use_shared_storage and self.reserve_position then
				return self:reserve_position("shared_storage_chest", pos, 2)
			end
			return true
		end
		local function release_shared_storage(pos)
			if data and data.use_shared_storage and self.release_reserved_position then
				self:release_reserved_position("shared_storage_chest", pos)
			end
		end

		if put_func then
			local size = vil_inv:get_size("main")
			for index = 1, size do
				local stack = vil_inv:get_stack("main", index)
				if (not stack:is_empty()) and put_func(self, stack, data) then
					result.put_candidates = result.put_candidates + 1
					local target_pos = chest_pos
					if data and data.use_shared_storage and self.get_shared_storage_chest_for_item then
						target_pos = self:get_shared_storage_chest_for_item(stack:get_name(), true)
					end
					if target_pos and reserve_shared_storage(target_pos) then
						local moved = inventory_access.put_from_inventory(
							self, vil_inv, "main", index, target_pos, "main")
						if moved > 0 then
							result.moved_any = true
							wait_after_transfer()
						else
							result.blocked_put = result.blocked_put + 1
						end
						release_shared_storage(target_pos)
					else
						result.blocked_put = result.blocked_put + 1
					end
				end
			end
		end

		if take_func then
			local source_positions = {chest_pos}
			if data and data.use_shared_storage and self.get_shared_storage_chests then
				local shared_chests = self:get_shared_storage_chests()
				if #shared_chests > 0 then
					source_positions = shared_chests
				end
			end
			for _, source_pos in ipairs(source_positions) do
				if reserve_shared_storage(source_pos) then
					local chest_inv = get_chest_inv(source_pos)
					if chest_inv then
						local size = chest_inv:get_size("main")
						for index = 1, size do
							local stack = chest_inv:get_stack("main", index)
							if (not stack:is_empty()) and take_func(self, stack, data) then
								result.take_candidates = result.take_candidates + 1
								local moved = inventory_access.take_to_inventory(
									self, source_pos, "main", index, vil_inv, "main")
								if moved > 0 then
									result.moved_any = true
									wait_after_transfer()
								else
									result.blocked_take = result.blocked_take + 1
								end
							end
						end
					end
					release_shared_storage(source_pos)
				end
			end
		end
	else
		log.error("Villager %s can't find chest at position %s.", self.inventory_name, minetest.pos_to_string(chest_pos))
	end
	return result
end

function working_villages.villager.wait_until_dawn()
	local daytime = minetest.get_timeofday()
	while (daytime < 0.2 or daytime > 0.805) do
		coroutine.yield()
		daytime = minetest.get_timeofday()
	end
end

function working_villages.villager:sleep()
	log.action("villager %s is laying down",self.inventory_name)
	self.object:set_velocity{x = 0, y = 0, z = 0}
	local bed_pos = vector.new(self.pos_data.bed_pos)
	local bed_top = func.find_adjacent_pos(bed_pos,
		function(p) return string.find(minetest.get_node(p).name,"_top") end)
	local bed_bottom = func.find_adjacent_pos(bed_pos,
		function(p) return string.find(minetest.get_node(p).name,"_bottom") end)
	if bed_top and bed_bottom then
		self:set_yaw_by_direction(vector.subtract(bed_bottom, bed_top))
		bed_pos = vector.divide(vector.add(bed_top,bed_bottom),2)
	else
		log.info("villager %s found no bed", self.inventory_name)
	end
	self:set_animation(working_villages.animation_frames.LAY)
	self.object:setpos(bed_pos)
	self:set_state_info("Zzzzzzz...")
	self:set_displayed_action("dort")

	self.wait_until_dawn()

	local pos=self.object:get_pos()
	self.object:setpos({x=pos.x,y=pos.y+0.5,z=pos.z})
	log.action("villager %s gets up", self.inventory_name)
	self:set_animation(working_villages.animation_frames.STAND)
	self:set_state_info("Je commence une nouvelle journee.")
	self:set_displayed_action("actif")
end

function working_villages.villager:goto_bed()
	if self.pos_data.home_pos==nil then
		log.action("villager %s is waiting until dawn", self.inventory_name)
		self:set_state_info("J'attends l'aube.")
		self:set_displayed_action("en attente de l'aube")
		self:set_animation(working_villages.animation_frames.SIT)
		self.object:set_velocity{x = 0, y = 0, z = 0}
		self.wait_until_dawn()
		self:set_animation(working_villages.animation_frames.STAND)
		self:set_state_info("Je commence une nouvelle journee.")
		self:set_displayed_action("actif")
	else
		log.action("villager %s is going home", self.inventory_name)
		self:set_state_info("Je rentre a la maison, il se fait tard.")
		self:set_displayed_action("rentre a la maison")
		self:go_to(self.pos_data.home_pos)
		if (self.pos_data.bed_pos==nil) then
			log.warning("villager %s couldn't find his bed",self.inventory_name)
			--TODO: go home anyway
			self:set_state_info("Je vais me reposer bientot.\nJ'aimerais avoir un lit a la maison.")
			self:set_displayed_action("en attente du soir")
			local tod = minetest.get_timeofday()
			while (tod > 0.2 and tod < 0.805) do
				coroutine.yield()
				tod = minetest.get_timeofday()
			end
			self:set_state_info("J'attends l'aube.")
			self:set_displayed_action("en attente de l'aube")
			self:set_animation(working_villages.animation_frames.SIT)
			self.object:set_velocity{x = 0, y = 0, z = 0}
			self.wait_until_dawn()
		else
			log.info("villager %s bed is at: %s", self.inventory_name, minetest.pos_to_string(self.pos_data.bed_pos))
			self:set_state_info("Je vais me coucher, il se fait tard.")
			self:set_displayed_action("va se coucher")
			self:go_to(self.pos_data.bed_pos)
			self:set_state_info("Je vais dormir bientot.")
			self:set_displayed_action("en attente du soir")
			local tod = minetest.get_timeofday()
			while (tod > 0.2 and tod < 0.805) do
				coroutine.yield()
				tod = minetest.get_timeofday()
			end
			self:sleep()
			self:go_to(self.pos_data.home_pos)
		end
	end
	return true
end

function working_villages.villager:handle_night()
	local tod = minetest.get_timeofday()
	if	tod < 0.2 or tod > 0.76 then
		if (self.job_data.in_work == true) then
			self.job_data.in_work = false;
		end
		self:goto_bed()
		self.job_data.manipulated_chest = false;
	end
end

function working_villages.villager:goto_job()
	log.action("villager %s is going to work", self.inventory_name)
	if self.pos_data.job_pos==nil then
		log.warning("villager %s couldn't find his job position",self.inventory_name)
		self.job_data.in_work = true;
	else
		log.action("villager %s going to job position %s", self.inventory_name, minetest.pos_to_string(self.pos_data.job_pos))
		self:set_state_info("Je vais a mon poste de travail.")
		self:set_displayed_action("va au travail")
		-- Spawning, reloading or changing profession often places the villager
		-- directly on its job anchor. Starting a path coroutine to the current
		-- node wastes a full decision cycle and could leave a worker apparently
		-- idle when the pathfinder returns an empty route.
		if vector.distance(self.object:get_pos(), self.pos_data.job_pos) > 1.5 then
			self:go_to(self.pos_data.job_pos)
		else
			self.object:set_velocity({x = 0, y = 0, z = 0})
		end
		self.job_data.in_work = true;
	end
	self:set_state_info("Je travaille.")
	self:set_displayed_action("actif")
	return true
end

local function bounded_empty_chest_cooldown(base_cooldown, streak, maximum)
	local value = math.max(1, tonumber(base_cooldown) or EMPTY_CHEST_RETRY_COOLDOWN)
	local limit = math.max(value, tonumber(maximum) or MAX_EMPTY_CHEST_RETRY_COOLDOWN)
	for _ = 2, math.max(1, tonumber(streak) or 1) do
		if value >= limit / 2 then
			return limit
		end
		value = value * 2
	end
	return math.min(value, limit)
end

-- Checking inventories is much cheaper than sending an entity to a chest.  In
-- particular, an empty chest used to make every profession pathfind there on
-- each retry even though manipulate_chest could not possibly move anything.
local function chest_has_candidates(self, chest_pos, take_func, put_func, data)
	local villager_inventory = self:get_inventory()
	if put_func and villager_inventory then
		for index = 1, villager_inventory:get_size("main") do
			local stack = villager_inventory:get_stack("main", index)
			if not stack:is_empty() and put_func(self, stack, data) then
				return true
			end
		end
	end

	if not take_func then
		return false
	end
	local source_positions = {chest_pos}
	if data and data.use_shared_storage and self.get_shared_storage_chests then
		local shared_chests = self:get_shared_storage_chests()
		if #shared_chests > 0 then
			source_positions = shared_chests
		end
	end
	for _, source_pos in ipairs(source_positions) do
		if func.is_chest(source_pos) then
			local chest_inventory = minetest.get_meta(source_pos):get_inventory()
			if chest_inventory then
				for index = 1, chest_inventory:get_size("main") do
					local stack = chest_inventory:get_stack("main", index)
					if not stack:is_empty() and take_func(self, stack, data) then
						return true
					end
				end
			end
		end
	end
	return false
end

function working_villages.villager:handle_chest(take_func, put_func, data)
	self.job_data = self.job_data or {}
	local timer_id = (data and data.timer_id) or "handle_chest"
	local cooldown = (data and data.cooldown) or DEFAULT_CHEST_COOLDOWN
	local miss_cooldown = (data and data.miss_cooldown) or EMPTY_CHEST_RETRY_COOLDOWN
	local max_miss_cooldown = (data and data.max_miss_cooldown)
		or MAX_EMPTY_CHEST_RETRY_COOLDOWN
	local blocked_cooldown = (data and data.blocked_cooldown) or BLOCKED_CHEST_RETRY_COOLDOWN
	local cooldown_key = "chest_cooldown:" .. timer_id
	local empty_streak_key = "chest_empty_streak:" .. timer_id
	if self.job_data.manipulated_chest then
		local active_cooldown = tonumber(self.job_data[cooldown_key]) or cooldown
		self:count_timer(timer_id)
		if not self:timer_exceeded(timer_id, active_cooldown) then
			return
		end
		self.job_data.manipulated_chest = false
		self.job_data[cooldown_key] = nil
	end

	local prefer_personal_chest = data and data.prefer_personal_chest == true
	local chest_pos = nil
	local use_shared_storage = false
	if not prefer_personal_chest and self.ensure_shared_storage_pos then
		local shared_pos = self:ensure_shared_storage_pos()
		if shared_pos and func.is_chest(shared_pos) then
			chest_pos = shared_pos
			use_shared_storage = true
		end
	end
	if chest_pos == nil and self.pos_data then
		chest_pos = self.pos_data.chest_pos
	end
	if chest_pos ~= nil then
		local data_local = data or {}
		data_local.use_shared_storage = use_shared_storage
		if func.is_chest(chest_pos)
				and not chest_has_candidates(self, chest_pos, take_func, put_func, data_local) then
			local empty_streak = (tonumber(self.job_data[empty_streak_key]) or 0) + 1
			self.job_data[empty_streak_key] = empty_streak
			self.job_data[cooldown_key] = bounded_empty_chest_cooldown(
				miss_cooldown, empty_streak, max_miss_cooldown)
			self.job_data.manipulated_chest = true
			self:set_timer(timer_id, 0)
			return
		end
		if use_shared_storage then
			self:set_state_info("Je prends et range des objets dans le coffre commun.")
		else
			self:set_state_info("Je prends et range des objets dans mon coffre.")
		end
		self:set_displayed_action("actif")
		local destination = func.find_adjacent_clear(chest_pos)
		if destination then
			destination = func.find_ground_below(destination) or destination
		end
		if destination == false or destination == nil then
			local chest = minetest.get_node(chest_pos)
			local dir = minetest.facedir_to_dir(chest.param2)
			destination = vector.subtract(chest_pos, dir)
		end
		self:go_to(destination)
		local transfer = self:manipulate_chest(chest_pos, take_func, put_func, data_local)
		self:set_timer(timer_id, 0)
		if transfer.moved_any then
			self.job_data[empty_streak_key] = 0
			self.job_data[cooldown_key] = cooldown
			log.action("villager %s exchanged items at chest %s",
				self.inventory_name, minetest.pos_to_string(chest_pos))
		elseif transfer.blocked_put > 0 then
			self.job_data[empty_streak_key] = 0
			self.job_data[cooldown_key] = blocked_cooldown
			self:set_displayed_action("attend le coffre")
			self:set_state_info(use_shared_storage
				and "Le coffre commun est plein ou deja occupe."
				or "Le coffre est plein pour l'instant.")
		elseif transfer.blocked_take > 0 then
			self.job_data[empty_streak_key] = 0
			self.job_data[cooldown_key] = miss_cooldown
			self:set_displayed_action("range son inventaire")
			self:set_state_info("Je n'ai plus assez de place pour transporter.")
		elseif transfer.put_candidates > 0 or transfer.take_candidates > 0 then
			self.job_data[empty_streak_key] = 0
			self.job_data[cooldown_key] = miss_cooldown
			self:set_displayed_action("verifie le coffre")
			self:set_state_info(use_shared_storage
				and "Je n'ai rien pu echanger utilement dans le coffre commun."
				or "Je n'ai rien pu echanger utilement dans mon coffre.")
		else
			local empty_streak = (tonumber(self.job_data[empty_streak_key]) or 0) + 1
			self.job_data[empty_streak_key] = empty_streak
			self.job_data[cooldown_key] = bounded_empty_chest_cooldown(
				miss_cooldown, empty_streak, max_miss_cooldown)
			self:set_displayed_action("laisse le coffre tranquille")
			self:set_state_info(use_shared_storage
				and "Je n'ai rien a ranger ni a prendre dans le coffre commun."
				or "Je n'ai rien a ranger ni a prendre dans mon coffre.")
		end
		self.job_data.manipulated_chest = true
		return
	end
	self.job_data.manipulated_chest = false
end

function working_villages.villager:handle_job_pos()
	if (not self.job_data.in_work) then
		self:goto_job()
	end
end
