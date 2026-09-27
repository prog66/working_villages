-- Temporary useful work while a profession is waiting for a required tool.
-- This module never changes the villager's job and never creates an item: a
-- tool must already be carried, transferred from real storage, or crafted by
-- the normal accounting layer.

local fallback = {}

local DEFAULT_SUPPLY_INTERVAL = 10 -- logical steps (about one second)
local DEFAULT_ACTIVITY_INTERVAL = 10
local DEFAULT_PATROL_INTERVAL = 40
local DEFAULT_REQUEST_COOLDOWN = 30 -- real seconds
local DEFAULT_ITEM_RANGE = {x = 8, y = 3, z = 8}

local function now()
	if minetest and minetest.get_gametime then
		return tonumber(minetest.get_gametime()) or 0
	end
	return 0
end

local function timer_due(self, state, marker, timer_id, threshold)
	if not state[marker] then
		state[marker] = true
		if self.set_timer then
			self:set_timer(timer_id, 0)
		end
		return true
	end
	if not (self.count_timer and self.timer_exceeded) then
		return false
	end
	self:count_timer(timer_id)
	return self:timer_exceeded(timer_id, threshold)
end

local function state_for(self, options)
	self.job_data = self.job_data or {}
	local key = assert(options.key, "tool fallback requires a key")
	local state = self.job_data.work_fallback
	if type(state) ~= "table" or state.key ~= key then
		state = {
			key = key,
			reason = "missing_tool",
			tool_group = options.tool_group,
			tool_label = options.tool_label,
			profession = self.get_job_name and self:get_job_name() or nil,
			started_at = now(),
			request_count = 0,
			useful_actions = 0,
		}
		self.job_data.work_fallback = state
	end
	return state
end

function fallback.get_state(self)
	return self and self.job_data and self.job_data.work_fallback or nil
end

function fallback.clear(self, key)
	local state = fallback.get_state(self)
	if not state or (key and state.key ~= key) then
		return false
	end
	self.job_data.last_work_fallback = {
		key = state.key,
		profession = state.profession,
		resolved_at = now(),
		request_count = state.request_count or 0,
		useful_actions = state.useful_actions or 0,
	}
	self.job_data.work_fallback = nil
	return true
end

function fallback.has_tool(self, tool_group)
	if not self or not tool_group then
		return false
	end
	local wield = self.get_wield_item_stack and self:get_wield_item_stack() or nil
	if wield and minetest.get_item_group(wield:get_name(), tool_group) > 0 then
		return true
	end
	local inv = self.get_inventory and self:get_inventory() or nil
	if not inv then
		return false
	end
	for _, stack in ipairs(inv:get_list("main") or {}) do
		if not stack:is_empty() and minetest.get_item_group(stack:get_name(), tool_group) > 0 then
			return true
		end
	end
	return false
end

-- A tool in the backpack is not usable by node_dig.  Put it in the real wield
-- slot before reporting success.
function fallback.equip_tool(self, tool_group)
	if not fallback.has_tool(self, tool_group) then
		return false
	end
	local wield = self:get_wield_item_stack()
	if wield and minetest.get_item_group(wield:get_name(), tool_group) > 0 then
		return true
	end
	if self.move_main_to_wield then
		return self:move_main_to_wield(function(name)
			return minetest.get_item_group(name, tool_group) > 0
		end) == true
	end
	return false
end

local function craft_tool(self, options)
	if type(options.craft) == "function" then
		return options.craft(self) == true
	end
	local crafting = working_villages.crafting
	if not crafting or type(options.candidates) ~= "table" then
		return false
	end
	local item = crafting.ensure_any_item(self, options.candidates, 1, {
		use_shared_storage = true,
		fail_cooldown = options.craft_fail_cooldown or 10,
		max_depth = options.max_craft_depth or 4,
	})
	return item ~= nil
end

local function request_due(state, cooldown)
	local current = now()
	local previous = tonumber(state.requested_at)
	if previous == nil or current < previous or current - previous >= cooldown then
		state.requested_at = current
		state.request_count = (state.request_count or 0) + 1
		return true
	end
	return false
end

-- Acquire and equip a required tool.  Returns true only when the tool is in
-- the wield slot and can therefore be used by the engine's dig validation.
function fallback.ensure_tool(self, options)
	options = options or {}
	local key = assert(options.key, "tool fallback requires a key")
	local tool_group = assert(options.tool_group, "tool fallback requires a tool group")
	if fallback.equip_tool(self, tool_group) then
		fallback.clear(self, key)
		return true, "inventory"
	end

	local state = state_for(self, options)
	local supply_timer = "work_fallback:" .. key .. ":supply"
	if timer_due(self, state, "supply_started", supply_timer,
			options.supply_interval or DEFAULT_SUPPLY_INTERVAL) then
		if self.take_tool_from_shared_storage
				and self:take_tool_from_shared_storage(tool_group)
				and fallback.equip_tool(self, tool_group) then
			fallback.clear(self, key)
			return true, "shared_storage"
		end
		if craft_tool(self, options) and fallback.equip_tool(self, tool_group) then
			fallback.clear(self, key)
			return true, "crafted"
		end
	end

	local cooldown = tonumber(options.request_cooldown) or DEFAULT_REQUEST_COOLDOWN
	if type(options.request) == "function" and request_due(state, math.max(1, cooldown)) then
		options.request(self, state)
	end

	local label = options.tool_label or tool_group
	if self.set_displayed_action then
		self:set_displayed_action("cherche " .. label)
	end
	if self.set_state_info then
		self:set_state_info((options.wait_info or
			("Il me manque %s. Je cherche une solution et je reste utile en attendant."):format(label)))
	end
	if not state.announced and options.announce and self.announce_action then
		self:announce_action(options.announce, options.announce_interval or 90)
		state.announced = true
	end
	return false, state
end

-- Perform bounded, tool-free secondary work.  Collection transfers only real
-- dropped ItemStacks; patrol is a visible search when nothing is available.
function fallback.perform(self, options)
	options = options or {}
	local state = state_for(self, options)
	local action_timer = "work_fallback:" .. state.key .. ":activity"
	if timer_due(self, state, "activity_started", action_timer,
			options.activity_interval or DEFAULT_ACTIVITY_INTERVAL) then
		local performed = false
		if type(options.activity) == "function" then
			performed = options.activity(self, state) == true
		elseif self.collect_nearest_item_by_condition then
			local predicate = options.collect_predicate or function() return true end
			performed = self:collect_nearest_item_by_condition(
				predicate, options.item_range or DEFAULT_ITEM_RANGE) == true
		end
		if performed then
			state.useful_actions = (state.useful_actions or 0) + 1
			if self.set_displayed_action then
				self:set_displayed_action(options.activity_action or "ramasse des fournitures")
			end
			if self.set_state_info then
				self:set_state_info(options.activity_info or
					"Je rassemble des ressources utiles pendant que j'attends mon outil.")
			end
			return true
		end
	end

	local patrol_timer = "work_fallback:" .. state.key .. ":patrol"
	if timer_due(self, state, "patrol_started", patrol_timer,
			options.patrol_interval or DEFAULT_PATROL_INTERVAL) then
		if type(options.patrol) == "function" then
			options.patrol(self, state)
		elseif self.change_direction_randomly then
			self:change_direction_randomly()
		end
		if self.set_displayed_action then
			self:set_displayed_action(options.patrol_action or "cherche des fournitures")
		end
		if self.set_state_info then
			self:set_state_info(options.patrol_info or
				"Je cherche des ressources et surveille l'arrivee de mon outil.")
		end
		return true
	end
	return false
end

return fallback
