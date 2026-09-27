-- Pure state helpers for the initial village spawn.
-- Keeping these decisions separate from the engine callbacks makes partial
-- spawn recovery deterministic and directly testable.

local spawn_state = {}

spawn_state.VERSION = 3

local function copy_slots(slots, slot_count)
	local result = {}
	for index = 1, slot_count do
		result[index] = slots and slots[index] == true or false
	end
	return result
end

local function copy_slot_ids(slot_ids, slot_count)
	local result = {}
	for index = 1, slot_count do
		local identity = slot_ids and slot_ids[index] or nil
		result[index] = type(identity) == "string" and identity ~= "" and identity or false
	end
	return result
end

local function copy_pos(pos)
	if type(pos) ~= "table" then
		return false
	end
	local x = tonumber(pos.x)
	local y = tonumber(pos.y)
	local z = tonumber(pos.z)
	if not x or not y or not z then
		return false
	end
	return {x = x, y = y, z = z}
end

local function copy_slot_positions(slot_positions, slot_count)
	local result = {}
	for index = 1, slot_count do
		result[index] = copy_pos(slot_positions and slot_positions[index])
	end
	return result
end

local function replace_state(state, normalized)
	state.version = normalized.version
	state.slot_count = normalized.slot_count
	state.slots = normalized.slots
	state.slot_ids = normalized.slot_ids
	state.slot_positions = normalized.slot_positions
	state.completed = normalized.completed
	state.owner_name = normalized.owner_name
	state.anchor_pos = normalized.anchor_pos
end

function spawn_state.create(slot_count, owner_name, anchor_pos)
	slot_count = math.max(1, math.floor(tonumber(slot_count) or 1))
	return {
		version = spawn_state.VERSION,
		slot_count = slot_count,
		slots = copy_slots(nil, slot_count),
		slot_ids = copy_slot_ids(nil, slot_count),
		slot_positions = copy_slot_positions(nil, slot_count),
		completed = false,
		owner_name = type(owner_name) == "string" and owner_name or "",
		anchor_pos = type(anchor_pos) == "table" and anchor_pos or nil,
	}
end

function spawn_state.normalize(data, slot_count, legacy_completed)
	slot_count = math.max(1, math.floor(tonumber(slot_count) or 1))
	local state = spawn_state.create(slot_count)

	if type(data) == "table" then
		state.slots = copy_slots(data.slots, slot_count)
		state.slot_ids = copy_slot_ids(data.slot_ids, slot_count)
		state.slot_positions = copy_slot_positions(data.slot_positions, slot_count)
		state.owner_name = type(data.owner_name) == "string" and data.owner_name or ""
		if type(data.anchor_pos) == "table" then
			state.anchor_pos = {
				x = tonumber(data.anchor_pos.x) or 0,
				y = tonumber(data.anchor_pos.y) or 0,
				z = tonumber(data.anchor_pos.z) or 0,
			}
		end
	elseif legacy_completed then
		for index = 1, slot_count do
			state.slots[index] = true
		end
	end

	local completed = true
	for index = 1, slot_count do
		if state.slots[index] ~= true then
			state.slot_ids[index] = false
			state.slot_positions[index] = false
			completed = false
		end
	end
	state.completed = completed
	return state
end

function spawn_state.mark_spawned(state, index, identity, pos)
	if type(state) ~= "table" or type(state.slots) ~= "table" then
		return false
	end
	index = math.floor(tonumber(index) or 0)
	if index < 1 or index > (state.slot_count or #state.slots) then
		return false
	end
	if type(identity) ~= "string" or identity == "" then
		return false
	end
	for other_index = 1, state.slot_count or #state.slots do
		if other_index ~= index and state.slot_ids and state.slot_ids[other_index] == identity then
			return false
		end
	end
	local previous_identity = state.slot_ids and state.slot_ids[index] or nil
	if previous_identity and previous_identity ~= false and previous_identity ~= identity then
		return false
	end
	state.slots[index] = true
	state.slot_ids = state.slot_ids or {}
	state.slot_positions = state.slot_positions or {}
	state.slot_ids[index] = identity
	local normalized_pos = copy_pos(pos)
	if normalized_pos then
		state.slot_positions[index] = normalized_pos
	end
	local normalized = spawn_state.normalize(state, state.slot_count or #state.slots, false)
	replace_state(state, normalized)
	return true
end

function spawn_state.touch_slot(state, index, identity, pos)
	if type(state) ~= "table" or type(state.slots) ~= "table" then
		return false
	end
	index = math.floor(tonumber(index) or 0)
	if index < 1 or index > (state.slot_count or #state.slots) then
		return false
	end
	if state.slots[index] ~= true or type(identity) ~= "string" or identity == "" then
		return false
	end
	if not state.slot_ids or state.slot_ids[index] ~= identity then
		return false
	end
	local normalized_pos = copy_pos(pos)
	if not normalized_pos then
		return false
	end
	state.slot_positions = state.slot_positions or {}
	state.slot_positions[index] = normalized_pos
	replace_state(state, spawn_state.normalize(state, state.slot_count or #state.slots, false))
	return true
end

function spawn_state.release_slot(state, index, identity)
	if type(state) ~= "table" or type(state.slots) ~= "table" then
		return false
	end
	index = math.floor(tonumber(index) or 0)
	if index < 1 or index > (state.slot_count or #state.slots) then
		return false
	end
	if type(identity) ~= "string" or identity == "" or
			not state.slot_ids or state.slot_ids[index] ~= identity then
		return false
	end
	state.slots[index] = false
	state.slot_ids[index] = false
	state.slot_positions = state.slot_positions or {}
	state.slot_positions[index] = false
	replace_state(state, spawn_state.normalize(state, state.slot_count or #state.slots, false))
	return true
end

function spawn_state.find_slot_by_id(state, identity)
	if type(state) ~= "table" or type(state.slots) ~= "table" or
			type(identity) ~= "string" or identity == "" then
		return nil
	end
	for index = 1, state.slot_count or #state.slots do
		if state.slots[index] == true and state.slot_ids and state.slot_ids[index] == identity then
			return index
		end
	end
	return nil
end

function spawn_state.count_spawned(state)
	local count = 0
	if type(state) ~= "table" or type(state.slots) ~= "table" then
		return count
	end
	for index = 1, state.slot_count or #state.slots do
		if state.slots[index] == true then
			count = count + 1
		end
	end
	return count
end

function spawn_state.available_population_slots(current_population, population_limit)
	current_population = math.max(0, math.floor(tonumber(current_population) or 0))
	population_limit = math.max(0, math.floor(tonumber(population_limit) or 0))
	return math.max(0, population_limit - current_population)
end

return spawn_state
