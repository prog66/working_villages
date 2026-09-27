local access = {}
local log = working_villages.require("log")
local callback_warnings = {}

local function explicit_owner_name(self)
	if self and type(self.owner_name) == "string" and self.owner_name ~= "" then
		return self.owner_name
	end
	return nil
end

local function actor_name(self)
	return explicit_owner_name(self) or "working_villages"
end

function access.make_actor(self)
	-- Node inventory callbacks are specified to receive a PlayerRef. Use the
	-- real owner whenever that player is connected; this is important for game
	-- callbacks which award achievements or experience to that PlayerRef.
	local owner_name = explicit_owner_name(self)
	if owner_name and type(minetest.get_player_by_name) == "function" then
		local lookup_ok, player = pcall(minetest.get_player_by_name, owner_name)
		if lookup_ok and player and type(player.is_player) == "function" then
			local player_ok, is_player = pcall(player.is_player, player)
			if player_ok and is_player then
				return player, false
			end
		end
	end

	-- Dedicated servers can continue village work while the owner is offline.
	-- This deliberately implements only the small PlayerRef surface commonly
	-- used for access/protection callbacks. Post-transfer callbacks which need
	-- engine-owned player state are contained by notify_callback below.
	return {
		_working_villages_synthetic_actor = true,
		is_player = function()
			return true
		end,
		get_player_name = function()
			return actor_name(self)
		end,
		get_player_control = function()
			return {sneak = true}
		end,
		get_inventory = function()
			return self and self.get_inventory and self:get_inventory() or nil
		end,
		get_pos = function()
			if self and self.object and self.object.get_pos then
				return self.object:get_pos()
			end
			return {x = 0, y = 0, z = 0}
		end,
		get_look_dir = function()
			local yaw = self and self.object and self.object.get_yaw and self.object:get_yaw() or 0
			return minetest.yaw_to_dir and minetest.yaw_to_dir(yaw) or {x = 0, y = 0, z = 1}
		end,
		get_wielded_item = function()
			if self and self.get_wield_item_stack then
				return self:get_wield_item_stack()
			end
			return ItemStack("")
		end,
		set_wielded_item = function(_, stack)
			if self and self.set_wield_item_stack then
				self:set_wield_item_stack(stack)
				return true
			end
			return false
		end,
		get_wield_index = function()
			return 1
		end,
		get_wield_list = function()
			return "wield_item"
		end,
	}, true
end

local function is_protected(self, pos)
	local modules = working_villages.modules
	local util = type(modules) == "table" and modules["jobs/util"] or nil
	if util and type(util.is_protected) == "function" then
		local ok, protected = pcall(util.is_protected, self, pos)
		if not ok then
			log.error("container protection check failed at %s: %s",
				minetest.pos_to_string(pos), tostring(protected))
			return true
		end
		return protected == true
	end
	if type(minetest.is_protected) == "function" then
		local ok, protected = pcall(minetest.is_protected, pos, actor_name(self))
		return not ok or protected == true
	end
	return false
end

local function get_context(self, pos)
	if type(pos) ~= "table" or is_protected(self, pos) then
		return nil
	end
	local node
	if type(minetest.get_node_or_nil) == "function" then
		node = minetest.get_node_or_nil(pos)
	else
		node = minetest.get_node(pos)
	end
	if not node or type(node.name) ~= "string" then
		return nil
	end
	local def = minetest.registered_nodes[node.name]
	local meta = minetest.get_meta(pos)
	local inv = meta and meta:get_inventory() or nil
	if not def or not inv then
		return nil
	end
	return {
		node_name = node.name,
		def = def,
		meta = meta,
		inv = inv,
		actor = nil,
		synthetic_actor = false,
	}
end

function access.can_access(self, pos)
	return get_context(self, pos) ~= nil
end

local function normalize_count(value, maximum)
	local count = math.floor(tonumber(value) or 0)
	if count < 0 then
		return 0
	end
	if maximum and count > maximum then
		return maximum
	end
	return count
end

local function callback_error_summary(callback_error)
	local summary = tostring(callback_error):match("^[^\r\n]+") or tostring(callback_error)
	return summary:sub(1, 300)
end

local function report_callback_failure(context, callback_name, callback_error, after_transfer, pos)
	local summary = callback_error_summary(callback_error)
	if context.synthetic_actor then
		-- A synthetic actor cannot reproduce all engine-owned PlayerRef state
		-- (HUD caches are one real example in VoxeLibre). Report each distinct
		-- compatibility failure once instead of flooding a long-running server.
		local warning_key = table.concat({
			context.node_name,
			callback_name,
			after_transfer and "after" or "before",
			summary,
		}, "|")
		if not callback_warnings[warning_key] then
			callback_warnings[warning_key] = true
			log.warning(
				"%s callback could not use the offline villager actor for %s at %s; "
					.. "%s%s",
				callback_name,
				context.node_name,
				minetest.pos_to_string(pos),
				summary,
				after_transfer and "; the item transfer remains valid" or "; transfer refused"
			)
		end
		return
	end
	log.error("%s callback failed%s for %s at %s: %s",
		callback_name,
		after_transfer and " after transfer" or "",
		context.node_name,
		minetest.pos_to_string(pos),
		summary)
end

local function prepare_actor(context, self)
	local actor, synthetic = access.make_actor(self)
	context.actor = actor
	context.synthetic_actor = synthetic == true
	return actor
end

local function allowed_count(context, self, callback, callback_name, args, requested, pos)
	if type(callback) ~= "function" then
		return requested
	end
	local actor = prepare_actor(context, self)
	args[#args + 1] = actor
	local ok, allowed = pcall(callback, unpack(args))
	if not ok then
		report_callback_failure(context, callback_name, allowed, false, pos)
		return 0
	end
	return normalize_count(allowed, requested)
end

local function notify_callback(context, self, callback, callback_name, args, pos)
	if type(callback) ~= "function" then
		return true
	end
	local actor = prepare_actor(context, self)
	args[#args + 1] = actor
	local ok, callback_error = pcall(callback, unpack(args))
	if not ok then
		report_callback_failure(context, callback_name, callback_error, true, pos)
		return false
	end
	return true
end

local function read_xp(context)
	if not context.meta or type(context.meta.get_int) ~= "function" then
		return nil
	end
	local ok, value = pcall(context.meta.get_int, context.meta, "xp")
	if not ok then
		return nil
	end
	return math.max(0, math.floor(tonumber(value) or 0))
end

local function restore_xp_after_failed_callback(context, previous_xp)
	if not previous_xp or previous_xp <= 0 or not context.meta
			or type(context.meta.set_int) ~= "function" then
		return
	end
	local current_xp = read_xp(context)
	if current_xp ~= nil and current_xp < previous_xp then
		-- VoxeLibre normally grants all accumulated furnace XP from its take
		-- callback. If an offline synthetic actor is not accepted, retain that
		-- XP in node metadata exactly as automated hopper extraction does.
		pcall(context.meta.set_int, context.meta, "xp", previous_xp)
	end
end

local function notify_take_callback(context, self, args, pos)
	local previous_xp = read_xp(context)
	local notified = notify_callback(
		context,
		self,
		context.def.on_metadata_inventory_take,
		"on_metadata_inventory_take",
		args,
		pos
	)
	if not notified and context.synthetic_actor then
		restore_xp_after_failed_callback(context, previous_xp)
	end
	return notified
end

local function copy_with_count(stack, count)
	local result = ItemStack(stack)
	result:set_count(count)
	return result
end

local function max_room_for(inv, listname, stack, maximum)
	maximum = normalize_count(maximum, stack:get_count())
	if maximum <= 0 then
		return 0
	end
	local probe = copy_with_count(stack, maximum)
	if inv:room_for_item(listname, probe) then
		return maximum
	end
	local low = 0
	local high = maximum - 1
	while low < high do
		local middle = math.floor((low + high + 1) / 2)
		probe:set_count(middle)
		if middle > 0 and inv:room_for_item(listname, probe) then
			low = middle
		else
			high = middle - 1
		end
	end
	return low
end

function access.put_capacity(self, pos, listname, stack, preferred_index)
	local remaining = ItemStack(stack or "")
	if remaining:is_empty() then
		return 0
	end
	local context = get_context(self, pos)
	if not context then
		return 0
	end
	local size = context.inv:get_size(listname)
	if size <= 0 then
		return 0
	end
	local indexes = {}
	if preferred_index then
		local index = normalize_count(preferred_index, size)
		if index >= 1 then
			indexes[1] = index
		end
	else
		for index = 1, size do
			indexes[#indexes + 1] = index
		end
	end
	local capacity = 0
	for _, index in ipairs(indexes) do
		if remaining:is_empty() then
			break
		end
		local requested = remaining:get_count()
		local probe = copy_with_count(remaining, requested)
		local allowed = allowed_count(
			context,
			self,
			context.def.allow_metadata_inventory_put,
			"allow_metadata_inventory_put",
			{pos, listname, index, probe},
			requested,
			pos
		)
		if allowed > 0 then
			local target = context.inv:get_stack(listname, index)
			local simulated = ItemStack(target)
			local candidate = copy_with_count(remaining, allowed)
			local leftover = simulated:add_item(candidate)
			local fits = allowed - leftover:get_count()
			if fits > 0 then
				remaining:take_item(fits)
				capacity = capacity + fits
			end
		end
	end
	return capacity
end

function access.can_put_stack(self, pos, listname, stack, preferred_index)
	local candidate = ItemStack(stack or "")
	return candidate:is_empty()
		or access.put_capacity(self, pos, listname, candidate, preferred_index) >= candidate:get_count()
end

-- Insert an owned stack into a node inventory. The caller keeps the returned
-- remainder, so refused or partial transfers never destroy an item.
function access.put_stack(self, pos, listname, stack, preferred_index)
	local remaining = ItemStack(stack or "")
	local original_count = remaining:get_count()
	if remaining:is_empty() then
		return remaining, 0
	end

	local first_context = get_context(self, pos)
	if not first_context then
		return remaining, 0
	end
	local size = first_context.inv:get_size(listname)
	if size <= 0 then
		return remaining, 0
	end
	local indexes = {}
	if preferred_index then
		local index = normalize_count(preferred_index, size)
		if index >= 1 then
			indexes[1] = index
		end
	else
		for index = 1, size do
			indexes[#indexes + 1] = index
		end
	end

	for _, index in ipairs(indexes) do
		if remaining:is_empty() then
			break
		end
		local context = get_context(self, pos)
		if not context or context.node_name ~= first_context.node_name then
			break
		end
		local requested = remaining:get_count()
		local probe = copy_with_count(remaining, requested)
		local allowed = allowed_count(
			context,
			self,
			context.def.allow_metadata_inventory_put,
			"allow_metadata_inventory_put",
			{pos, listname, index, probe},
			requested,
			pos
		)
		if allowed > 0 then
			local target = context.inv:get_stack(listname, index)
			local updated = ItemStack(target)
			local insertion = copy_with_count(remaining, allowed)
			local leftover = updated:add_item(insertion)
			local moved = allowed - leftover:get_count()
			if moved > 0 and not is_protected(self, pos) then
				local moved_stack = remaining:take_item(moved)
				context.inv:set_stack(listname, index, updated)
				notify_callback(
					context,
					self,
					context.def.on_metadata_inventory_put,
					"on_metadata_inventory_put",
					{pos, listname, index, moved_stack},
					pos
				)
			end
		end
	end
	return remaining, original_count - remaining:get_count()
end

-- Remove a stack from a node inventory after the node-specific allow callback.
-- Ownership of the returned stack passes to the caller.
function access.take_stack(self, pos, listname, index, maximum)
	local context = get_context(self, pos)
	if not context or index < 1 or index > context.inv:get_size(listname) then
		return ItemStack(""), 0
	end
	local source = context.inv:get_stack(listname, index)
	if source:is_empty() then
		return ItemStack(""), 0
	end
	local requested = normalize_count(maximum or source:get_count(), source:get_count())
	if requested <= 0 then
		return ItemStack(""), 0
	end
	local probe = copy_with_count(source, requested)
	local allowed = allowed_count(
		context,
		self,
		context.def.allow_metadata_inventory_take,
		"allow_metadata_inventory_take",
		{pos, listname, index, probe},
		requested,
		pos
	)
	if allowed <= 0 or is_protected(self, pos) then
		return ItemStack(""), 0
	end
	local taken = source:take_item(allowed)
	context.inv:set_stack(listname, index, source)
	notify_take_callback(context, self, {pos, listname, index, taken}, pos)
	return taken, taken:get_count()
end

-- Move as much as possible from a node slot to an ordinary inventory. The
-- capacity is calculated before mutation, and the take callback receives only
-- the quantity that reached the destination.
function access.take_to_inventory(self, pos, listname, index, destination, destination_list, maximum)
	local context = get_context(self, pos)
	if not context or not destination or index < 1 or index > context.inv:get_size(listname) then
		return 0
	end
	local source = context.inv:get_stack(listname, index)
	if source:is_empty() then
		return 0
	end
	local requested = normalize_count(maximum or source:get_count(), source:get_count())
	if requested <= 0 then
		return 0
	end
	local probe = copy_with_count(source, requested)
	local allowed = allowed_count(
		context,
		self,
		context.def.allow_metadata_inventory_take,
		"allow_metadata_inventory_take",
		{pos, listname, index, probe},
		requested,
		pos
	)
	allowed = max_room_for(destination, destination_list, source, allowed)
	if allowed <= 0 or is_protected(self, pos) then
		return 0
	end
	local taken = source:take_item(allowed)
	local leftover = destination:add_item(destination_list, taken)
	local moved = allowed - leftover:get_count()
	if not leftover:is_empty() then
		source:add_item(leftover)
	end
	if moved <= 0 then
		return 0
	end
	context.inv:set_stack(listname, index, source)
	local moved_stack = copy_with_count(taken, moved)
	notify_take_callback(context, self, {pos, listname, index, moved_stack}, pos)
	return moved
end

-- Move items from an ordinary inventory into a node inventory without taking
-- them from the source unless the node accepted them.
function access.put_from_inventory(self, source, source_list, source_index, pos, listname, preferred_index, maximum)
	if not source or source_index < 1 or source_index > source:get_size(source_list) then
		return 0
	end
	local stack = source:get_stack(source_list, source_index)
	if stack:is_empty() then
		return 0
	end
	local requested = normalize_count(maximum or stack:get_count(), stack:get_count())
	if requested <= 0 then
		return 0
	end
	local candidate = copy_with_count(stack, requested)
	local _, moved = access.put_stack(self, pos, listname, candidate, preferred_index)
	if moved > 0 then
		stack:take_item(moved)
		source:set_stack(source_list, source_index, stack)
	end
	return moved
end

return access
