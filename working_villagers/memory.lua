-- Persistent memory helpers for villagers
-- Tracks resource locations, paths, danger zones, interactions.

local memory = {}

local CLOCK_KIND = "gametime_v1"

local function game_time()
	local now = tonumber(minetest.get_gametime()) or 0
	return math.max(0, now)
end

local function elapsed(entry, now)
	local timestamp = type(entry) == "table" and tonumber(entry.time) or nil
	if type(entry) ~= "table" or entry.time_clock ~= CLOCK_KIND or
			not timestamp or timestamp < 0 or timestamp > now then
		return nil
	end
	return now - timestamp
end

function memory.create_state()
	return {
		resource_locations = {},
		frequent_paths = {},
		danger_zones = {},
		interactions = {},
	}
end

function memory.ensure(self)
	if not self.memory then
		self.memory = memory.create_state()
	end
	return self.memory
end

local function hash_pos(pos)
	return minetest.hash_node_position(vector.round(pos))
end

function memory.remember_pos(self, category, pos, data)
	local mem = memory.ensure(self)
	mem[category] = mem[category] or {}
	mem[category][hash_pos(pos)] = {
		pos = vector.round(pos),
		data = data or {},
		time = game_time(),
		time_clock = CLOCK_KIND,
		visits = (mem[category][hash_pos(pos)] and mem[category][hash_pos(pos)].visits or 0) + 1,
	}
end

function memory.list(self, category)
	local mem = memory.ensure(self)
	return mem[category] or {}
end

function memory.forget_old(self, max_age)
	local mem = self.memory
	if not mem then
		return
	end
	local now = game_time()
	for cat, entries in pairs(mem) do
		for key, entry in pairs(entries) do
			local age = elapsed(entry, now)
			if not age or age > max_age then
				entries[key] = nil
			end
		end
	end
end

return memory
