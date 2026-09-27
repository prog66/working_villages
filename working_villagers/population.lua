-- Persistent population index used for village caps and restart-safe identity.

local population = {}
local storage = minetest.get_mod_storage()
local STORAGE_KEY = "population_registry_v1"
local CHECKPOINT_INTERVAL = math.max(1, tonumber(minetest.settings and
	minetest.settings:get("working_villages_villager_checkpoint_interval")) or 5)
local village_registry = working_villages and working_villages.village_registry or nil
local village_radius = math.max(16,
	tonumber(minetest.settings and minetest.settings:get("working_villages_population_radius")) or 64)

local function copy_pos(pos)
	if type(pos) ~= "table" then
		return nil
	end
	return {
		x = tonumber(pos.x) or 0,
		y = tonumber(pos.y) or 0,
		z = tonumber(pos.z) or 0,
	}
end

local function load_records()
	local encoded = storage:get_string(STORAGE_KEY)
	if encoded == "" then
		return {}
	end
	local decoded = minetest.deserialize(encoded)
	return type(decoded) == "table" and decoded or {}
end

local records = load_records()

local function persist()
	storage:set_string(STORAGE_KEY, minetest.serialize(records))
end

local function warn_checkpoint(message)
	if minetest.log then
		minetest.log("warning", "[working_villages] Villager checkpoint: " .. tostring(message))
	end
end

local function entity_id(entity_or_id)
	if type(entity_or_id) == "string" then
		return entity_or_id
	end
	return entity_or_id and entity_or_id.inventory_name or nil
end

local function same_pos(left, right)
	if left == nil or right == nil then
		return left == right
	end
	return left.x == right.x and left.y == right.y and left.z == right.z
end

local function warn_registry(message)
	if minetest.log then
		minetest.log("warning", "[working_villages] Village registry sync failed: " .. tostring(message))
	end
end

local function sync_registry_resident(id, record)
	if not village_registry or not record or not record.owner_name or record.owner_name == "" then
		return
	end
	local village, ensure_error = village_registry.ensure(record.owner_name, {
		center = record.last_pos,
		radius = village_radius,
	})
	if not village then
		warn_registry(ensure_error)
		return
	end
	if not village.center and record.last_pos then
		village, ensure_error = village_registry.update(record.owner_name, {center = record.last_pos})
		if not village then
			warn_registry(ensure_error)
			return
		end
	end
	local previous = village.residents and village.residents[id] or nil
	if previous and previous.owner_name == record.owner_name
			and previous.product_name == record.product_name
			and previous.job_name == record.job_name
			and same_pos(previous.job_pos, record.job_pos)
			and same_pos(previous.last_pos, record.last_pos) then
		return
	end
	local residents = village.residents or {}
	residents[id] = {
		inventory_name = id,
		owner_name = record.owner_name,
		product_name = record.product_name,
		job_name = record.job_name,
		job_pos = copy_pos(record.job_pos),
		last_pos = copy_pos(record.last_pos),
	}
	local work_zones = village.work_zones or {}
	work_zones[id] = record.job_pos and {
		inventory_name = id,
		job_name = record.job_name,
		pos = copy_pos(record.job_pos),
	} or nil
	local updated, update_error = village_registry.update(record.owner_name, {
		residents = residents,
		work_zones = work_zones,
	})
	if not updated then
		warn_registry(update_error)
	end
end

local function remove_registry_resident(owner_name, id)
	if not village_registry or not owner_name or owner_name == "" then
		return
	end
	local village = village_registry.get(owner_name)
	if not village then
		return
	end
	local residents = village.residents or {}
	local work_zones = village.work_zones or {}
	if residents[id] == nil and work_zones[id] == nil then
		return
	end
	residents[id] = nil
	work_zones[id] = nil
	local updated, remove_error = village_registry.update(owner_name, {
		residents = residents,
		work_zones = work_zones,
	})
	if not updated then
		warn_registry(remove_error)
	end
end

local function capture_record(entity, pos)
	local id = entity_id(entity)
	local owner_name = entity and entity.owner_name or ""
	if not id or id == "" or not owner_name or owner_name == "" then
		return nil, nil, nil
	end
	local job_name = entity.get_job_name and entity:get_job_name() or ""
	if job_name == "" then
		job_name = entity.new_job or ""
	end
	local previous = records[id]
	local revision = math.max(
		math.floor(tonumber(previous and previous.checkpoint_revision) or 0),
		math.floor(tonumber(entity.persistence_revision) or 0)
	)
	local checkpoint_staticdata = previous and previous.checkpoint_staticdata or nil
	if type(entity._serialize_persistent_state) == "function" then
		revision = revision + 1
		entity.persistence_revision = revision
		local ok, encoded = pcall(entity._serialize_persistent_state, entity)
		if ok and encoded ~= nil then
			checkpoint_staticdata = encoded
		else
			warn_checkpoint(("could not serialize %s: %s"):format(id, tostring(encoded)))
			revision = math.floor(tonumber(previous and previous.checkpoint_revision) or 0)
		end
	end
	local record = {
		owner_name = owner_name,
		product_name = entity.product_name or entity.name or "",
		job_name = job_name,
		job_pos = copy_pos(entity.pos_data and entity.pos_data.job_pos),
		last_pos = copy_pos(pos or (entity.object and entity.object:get_pos())),
		checkpoint_revision = revision,
		checkpoint_staticdata = checkpoint_staticdata,
	}
	records[id] = record
	return id, record, checkpoint_staticdata, previous
end

function population.register(entity, pos)
	local id, record, _, previous = capture_record(entity, pos)
	if not id then
		return false
	end
	if previous and previous.owner_name ~= record.owner_name then
		remove_registry_resident(previous.owner_name, id)
	end
	persist()
	sync_registry_resident(id, record)
	return true
end

function population.checkpoint(entity, pos)
	local id, record, staticdata = capture_record(entity, pos)
	if not id then
		return nil
	end
	persist()
	sync_registry_resident(id, record)
	return staticdata
end

function population.recover_data(id, current_data)
	local record = type(id) == "string" and records[id] or nil
	if not record or type(current_data) ~= "table" then
		return current_data, false, nil
	end

	local current_revision = math.floor(tonumber(current_data.persistence_revision) or 0)
	local checkpoint_revision = math.floor(tonumber(record.checkpoint_revision) or 0)
	if record.checkpoint_staticdata ~= nil and checkpoint_revision > current_revision then
		local ok, checkpoint = pcall(minetest.deserialize, record.checkpoint_staticdata)
		if ok and type(checkpoint) == "table" then
			return checkpoint, true, "checkpoint"
		end
		warn_checkpoint(("ignored invalid checkpoint for %s"):format(id))
	end

	-- Worlds created before checkpoints can still contain the exact initial
	-- static object after a process kill. Its identity is valid, but owner, job
	-- and work position predate the assignments made just after add_entity().
	-- Only repair this unmistakable empty-owner baseline; a deliberately
	-- unemployed villager with a valid owner must remain unemployed.
	if (current_data.owner_name == nil or current_data.owner_name == "") and
			type(record.owner_name) == "string" and record.owner_name ~= "" then
		current_data.owner_name = record.owner_name
		current_data.product_name = record.product_name ~= "" and
			record.product_name or current_data.product_name
		current_data.pos_data = type(current_data.pos_data) == "table" and
			current_data.pos_data or {}
		if record.job_pos then
			current_data.pos_data.job_pos = copy_pos(record.job_pos)
		end
		current_data.inventory = type(current_data.inventory) == "table" and
			current_data.inventory or {}
		local saved_job = current_data.inventory.job and current_data.inventory.job[1] or ""
		if (saved_job == nil or saved_job == "") and record.job_name and
				record.job_name ~= "" then
			current_data.inventory.job = {record.job_name}
		end
		return current_data, true, "registry_metadata"
	end
	return current_data, false, nil
end

function population.unregister(entity_or_id)
	local id = entity_id(entity_or_id)
	if not id or records[id] == nil then
		return false
	end
	local owner_name = records[id].owner_name
	records[id] = nil
	persist()
	remove_registry_resident(owner_name, id)
	return true
end

local function inside_radius(pos, center, radius)
	if not center or not radius then
		return true
	end
	if not pos then
		-- Old records without a position are counted conservatively until the
		-- entity is loaded and refreshes its registry entry.
		return true
	end
	local dx = pos.x - center.x
	local dy = pos.y - center.y
	local dz = pos.z - center.z
	return (dx * dx + dy * dy + dz * dz) <= (radius * radius)
end

function population.count(owner_name, center, radius)
	local count = 0
	for _, record in pairs(records) do
		if (not owner_name or owner_name == "" or record.owner_name == owner_name)
				and inside_radius(record.last_pos, center, radius) then
			count = count + 1
		end
	end
	return count
end

function population.contains(entity_or_id)
	local id = entity_id(entity_or_id)
	return id ~= nil and records[id] ~= nil
end

function population.snapshot()
	local result = {}
	for id, record in pairs(records) do
		result[id] = {
			owner_name = record.owner_name,
			product_name = record.product_name,
			job_name = record.job_name,
			job_pos = copy_pos(record.job_pos),
			last_pos = copy_pos(record.last_pos),
		}
	end
	return result
end

if minetest.register_globalstep then
	local checkpoint_elapsed = 0
	minetest.register_globalstep(function(dtime)
		checkpoint_elapsed = checkpoint_elapsed + (tonumber(dtime) or 0)
		if checkpoint_elapsed < CHECKPOINT_INTERVAL then
			return
		end
		checkpoint_elapsed = checkpoint_elapsed % CHECKPOINT_INTERVAL
		local changed = false
		for _, entity in pairs(minetest.luaentities or {}) do
			if type(entity) == "table" and type(entity._serialize_persistent_state) == "function" then
				local id, record = capture_record(entity)
				if id then
					changed = true
					sync_registry_resident(id, record)
				end
			end
		end
		if changed then
			persist()
		end
	end)
end

return population
