-- Villager communication system
-- Message routing + broadcast helpers.

local communication = {}

communication.MESSAGE_TYPES = {
	help_needed = true,
	resource_found = true,
	danger_alert = true,
	task_complete = true,
}

local function ensure_inbox(self)
	self.job_data = self.job_data or {}
	self.job_data.inbox = self.job_data.inbox or {}
	return self.job_data.inbox
end

function communication.send_message(from, to, message_type, data)
	if not to or not message_type then
		return false
	end
	if not communication.MESSAGE_TYPES[message_type] then
		return false
	end
	local from_owner = from and from.owner_name or ""
	local to_owner = to.owner_name or ""
	if from_owner ~= "" and to_owner ~= "" and from_owner ~= to_owner then
		return false
	end
	local inbox = ensure_inbox(to)
	table.insert(inbox, {
		from = from and (from.inventory_name or from.nametag or "villager") or "villager",
		owner_name = from_owner,
		type = message_type,
		data = data or {},
		time = tonumber(minetest.get_gametime()) or 0,
		time_clock = "gametime_v1",
	})
	return true
end

function communication.broadcast(from, targets, message_type, data)
	local count = 0
	for _, target in ipairs(targets or {}) do
		if communication.send_message(from, target, message_type, data) then
			count = count + 1
		end
	end
	return count
end

function communication.find_nearby_villagers(pos, radius, filter_job, owner_name)
	local results = {}
	local objects = minetest.get_objects_inside_radius(pos, radius)
	for _, obj in ipairs(objects) do
		local lua = obj:get_luaentity()
		if lua and working_villages.is_villager(lua.name) then
			if (not owner_name or owner_name == "" or lua.owner_name == owner_name)
					and (not filter_job or lua:get_job_name() == filter_job) then
				table.insert(results, lua)
			end
		end
	end
	return results
end

function communication.list_loaded_villagers()
	local results = {}
	for _, lua in pairs(minetest.luaentities or {}) do
		if lua and lua.name and working_villages.is_villager(lua.name) then
			table.insert(results, lua)
		end
	end
	return results
end

function communication.find_villager_by_inventory_name(inventory_name)
	if not inventory_name then
		return nil
	end
	for _, lua in pairs(minetest.luaentities or {}) do
		if lua and lua.inventory_name == inventory_name and lua.name and working_villages.is_villager(lua.name) then
			return lua
		end
	end
	return nil
end

function communication.get_shared_storage_pos(owner_name)
	if working_villages.get_shared_storage_pos then
		return working_villages.get_shared_storage_pos(owner_name)
	end
	local data = working_villages.get_stored_table("_shared_storage")
	local pos = data and data.pos
	if pos and type(pos) == "table" and pos.x and pos.y and pos.z then
		return pos
	end
	return nil
end

function communication.consume_messages(self)
	local inbox = ensure_inbox(self)
	local messages = {}
	for _, entry in ipairs(inbox) do
		table.insert(messages, entry)
	end
	self.job_data.inbox = {}
	return messages
end

return communication
