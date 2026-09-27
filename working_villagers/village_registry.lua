-- Persistent village identity and shared village-level state.
--
-- The current gameplay model owns one village per player. The registry keeps
-- that model explicit while leaving the contained data independent from loaded
-- entities. Public APIs never expose the mutable persisted tables directly.

local registry = {}

registry.SCHEMA_VERSION = 1
registry.STORAGE_KEY = "village_registry_v1"
registry.DEFAULT_RADIUS = 32

local COLLECTION_PATHS = {
	chests = {"chests"},
	residents = {"residents"},
	homes = {"homes"},
	beds = {"beds"},
	work_zones = {"work_zones"},
	priorities = {"priorities"},
	resources = {"resources"},
	construction_sites = {"construction_sites"},
	allies = {"governance", "allies"},
	threats = {"danger", "threats"},
}

local UPDATABLE_FIELDS = {
	governance = true,
	center = true,
	radius = true,
	chests = true,
	residents = true,
	homes = true,
	beds = true,
	work_zones = true,
	priorities = true,
	resources = true,
	danger = true,
	construction_sites = true,
	metadata = true,
}

local IMMUTABLE_FIELDS = {
	schema_version = true,
	id = true,
	owner = true,
	revision = true,
}

local function log(level, message)
	if minetest and type(minetest.log) == "function" then
		minetest.log(level, "[working_villages:village_registry] " .. message)
	end
end

local function finite_number(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function serializable_copy(value, seen, depth)
	local value_type = type(value)
	if value_type == "nil" or value_type == "string" or value_type == "boolean" then
		return value
	end
	if value_type == "number" then
		if not finite_number(value) then
			return nil, "non-finite numbers cannot be persisted"
		end
		return value
	end
	if value_type ~= "table" then
		return nil, "unsupported persisted value type: " .. value_type
	end

	depth = depth or 0
	if depth >= 64 then
		return nil, "persisted value is nested too deeply"
	end
	seen = seen or {}
	if seen[value] then
		return nil, "cyclic tables cannot be persisted"
	end
	seen[value] = true

	local result = {}
	for key, entry in pairs(value) do
		local key_type = type(key)
		if key_type ~= "string" and key_type ~= "number" then
			seen[value] = nil
			return nil, "persisted table keys must be strings or numbers"
		end
		if key_type == "number" and not finite_number(key) then
			seen[value] = nil
			return nil, "persisted table keys must be finite"
		end
		local entry_copy, copy_error = serializable_copy(entry, seen, depth + 1)
		if copy_error then
			seen[value] = nil
			return nil, copy_error
		end
		result[key] = entry_copy
	end
	seen[value] = nil
	return result
end

local function deep_equal(left, right, seen)
	if type(left) ~= type(right) then
		return false
	end
	if type(left) ~= "table" then
		return left == right
	end
	seen = seen or {}
	seen[left] = seen[left] or {}
	if seen[left][right] then
		return true
	end
	seen[left][right] = true
	for key, value in pairs(left) do
		if not deep_equal(value, right[key], seen) then
			return false
		end
	end
	for key in pairs(right) do
		if left[key] == nil then
			return false
		end
	end
	return true
end

local function normalize_owner(owner)
	if type(owner) ~= "string" or owner == "" then
		return nil, "village owner must be a non-empty string"
	end
	return owner
end

local function owner_hex(owner)
	local encoded = {}
	for index = 1, #owner do
		encoded[#encoded + 1] = string.format("%02x", string.byte(owner, index))
	end
	return table.concat(encoded)
end

local function stable_id(owner)
	return "working_villages:village:" .. owner_hex(owner)
end

function registry.id_for_owner(owner)
	local valid_owner, owner_error = normalize_owner(owner)
	if not valid_owner then
		return nil, owner_error
	end
	return stable_id(valid_owner)
end

local function normalize_pos(pos)
	if type(pos) ~= "table" or not finite_number(pos.x) or
			not finite_number(pos.y) or not finite_number(pos.z) then
		return nil, "village center must contain finite numeric x, y and z coordinates"
	end
	return {x = pos.x, y = pos.y, z = pos.z}
end

local function blank_state()
	return {
		schema_version = registry.SCHEMA_VERSION,
		villages = {},
		owners = {},
	}
end

local function default_village(owner)
	return {
		schema_version = registry.SCHEMA_VERSION,
		id = stable_id(owner),
		owner = owner,
		revision = 1,
		governance = {
			public = false,
			allies = {},
		},
		radius = registry.DEFAULT_RADIUS,
		chests = {},
		residents = {},
		homes = {},
		beds = {},
		work_zones = {},
		priorities = {},
		resources = {},
		danger = {
			active = false,
			level = 0,
			threats = {},
		},
		construction_sites = {},
		metadata = {},
	}
end

local function normalize_village(record, owner_hint)
	if type(record) ~= "table" then
		return nil, "village record must be a table"
	end
	local copy, copy_error = serializable_copy(record)
	if copy_error then
		return nil, copy_error
	end
	local owner, owner_error = normalize_owner(copy.owner or owner_hint)
	if not owner then
		return nil, owner_error
	end

	local normalized = copy
	normalized.schema_version = registry.SCHEMA_VERSION
	normalized.id = stable_id(owner)
	normalized.owner = owner
	normalized.revision = math.max(1, math.floor(tonumber(normalized.revision) or 1))

	if type(normalized.governance) ~= "table" then
		normalized.governance = {}
	end
	normalized.governance.public = normalized.governance.public == true
	if type(normalized.governance.allies) ~= "table" then
		normalized.governance.allies = {}
	end

	if normalized.center ~= nil then
		local center = normalize_pos(normalized.center)
		normalized.center = center
	end
	if not finite_number(normalized.radius) or normalized.radius <= 0 then
		normalized.radius = registry.DEFAULT_RADIUS
	end

	for name, path in pairs(COLLECTION_PATHS) do
		if #path == 1 and name ~= "allies" and name ~= "threats" and
				type(normalized[path[1]]) ~= "table" then
			normalized[path[1]] = {}
		end
	end

	if type(normalized.danger) ~= "table" then
		normalized.danger = {}
	end
	normalized.danger.active = normalized.danger.active == true
	if not finite_number(normalized.danger.level) or normalized.danger.level < 0 then
		normalized.danger.level = 0
	end
	if type(normalized.danger.threats) ~= "table" then
		normalized.danger.threats = {}
	end
	if type(normalized.metadata) ~= "table" then
		normalized.metadata = {}
	end

	return normalized
end

local function reverse_owner_hint(owners, village_id)
	if type(owners) ~= "table" then
		return nil
	end
	for owner, referenced_id in pairs(owners) do
		if referenced_id == village_id and type(owner) == "string" and owner ~= "" then
			return owner
		end
	end
	return nil
end

local function migrate_state(decoded)
	if type(decoded) ~= "table" then
		return nil, "stored village registry is not a table"
	end
	local version = math.floor(tonumber(decoded.schema_version) or 0)
	if version > registry.SCHEMA_VERSION then
		return nil, "stored village registry uses unsupported schema version " .. tostring(version)
	end
	if decoded.villages ~= nil and type(decoded.villages) ~= "table" then
		return nil, "stored village collection is not a table"
	end
	if decoded.villages == nil and next(decoded) ~= nil then
		return nil, "unversioned village registry has no villages collection"
	end

	local migrated, copy_error = serializable_copy(decoded)
	if copy_error then
		return nil, copy_error
	end
	migrated.schema_version = registry.SCHEMA_VERSION
	migrated.villages = {}
	migrated.owners = {}

	for previous_id, record in pairs(decoded.villages or {}) do
		local owner_hint = reverse_owner_hint(decoded.owners, previous_id)
		if not owner_hint and version == 0 and type(previous_id) == "string" then
			owner_hint = previous_id
		end
		local village, village_error = normalize_village(record, owner_hint)
		if not village then
			return nil, "cannot migrate village " .. tostring(previous_id) .. ": " .. village_error
		end
		if migrated.villages[village.id] then
			return nil, "multiple stored villages claim owner " .. village.owner
		end
		migrated.villages[village.id] = village
		migrated.owners[village.owner] = village.id
	end

	return migrated, not deep_equal(migrated, decoded)
end

local function get_storage()
	if not minetest or type(minetest.get_mod_storage) ~= "function" then
		return nil, "ModStorage API is unavailable"
	end
	local ok, result = pcall(minetest.get_mod_storage)
	if not ok or not result then
		return nil, "ModStorage could not be opened"
	end
	return result
end

local storage, storage_error = get_storage()

local function write_state(candidate)
	if not storage then
		return false, storage_error or "ModStorage is unavailable"
	end
	if not minetest or type(minetest.serialize) ~= "function" then
		return false, "serialization API is unavailable"
	end
	local snapshot, copy_error = serializable_copy(candidate)
	if copy_error then
		return false, copy_error
	end
	local encoded_ok, encoded = pcall(minetest.serialize, snapshot)
	if not encoded_ok or encoded == nil then
		return false, "village registry serialization failed"
	end
	local write_ok, write_error = pcall(storage.set_string, storage, registry.STORAGE_KEY, encoded)
	if not write_ok then
		return false, "village registry persistence failed: " .. tostring(write_error)
	end
	return true
end

local state = blank_state()
local read_only_error = storage_error

local function load_state()
	if not storage then
		return
	end
	local read_ok, encoded = pcall(storage.get_string, storage, registry.STORAGE_KEY)
	if not read_ok then
		read_only_error = "village registry could not be read"
		return
	end
	if encoded == nil or encoded == "" then
		return
	end
	if not minetest or type(minetest.deserialize) ~= "function" then
		read_only_error = "deserialization API is unavailable"
		return
	end
	local decode_ok, decoded = pcall(minetest.deserialize, encoded)
	if not decode_ok or type(decoded) ~= "table" then
		read_only_error = "stored village registry is unreadable; it was left untouched"
		log("error", read_only_error)
		return
	end
	local migrated, changed_or_error = migrate_state(decoded)
	if not migrated then
		read_only_error = changed_or_error .. "; stored data was left untouched"
		log("error", read_only_error)
		return
	end
	state = migrated
	if changed_or_error then
		local written, migration_error = write_state(state)
		if not written then
			read_only_error = "village registry migration could not be persisted: " .. migration_error
			log("error", read_only_error)
		else
			log("action", "village registry migrated to schema " .. registry.SCHEMA_VERSION)
		end
	end
end

load_state()

local function commit(candidate)
	if read_only_error then
		return false, read_only_error
	end
	local written, write_error = write_state(candidate)
	if not written then
		return false, write_error
	end
	state = candidate
	return true
end

local function resolve_id(reference)
	if type(reference) ~= "string" or reference == "" then
		return nil, "village reference must be a non-empty owner or village ID"
	end
	if state.villages[reference] then
		return reference
	end
	local village_id = state.owners[reference]
	if village_id and state.villages[village_id] then
		return village_id
	end
	return nil, "village not found"
end

local function copy_result(value)
	local copy, copy_error = serializable_copy(value)
	if copy_error then
		return nil, copy_error
	end
	return copy
end

local function merge_table(target, patch)
	if type(patch) ~= "table" then
		return nil, "nested village update must be a table"
	end
	for key, value in pairs(patch) do
		target[key] = value
	end
	return true
end

local function apply_patch(record, patch)
	if type(patch) ~= "table" then
		return false, "village update must be a table"
	end
	local safe_patch, copy_error = serializable_copy(patch)
	if copy_error then
		return false, copy_error
	end

	for field, value in pairs(safe_patch) do
		if IMMUTABLE_FIELDS[field] then
			return false, "village field is immutable: " .. field
		end
		if not UPDATABLE_FIELDS[field] then
			return false, "unknown village field: " .. tostring(field)
		end
		if field == "center" then
			if value == false then
				record.center = nil
			else
				local center, center_error = normalize_pos(value)
				if not center then
					return false, center_error
				end
				record.center = center
			end
		elseif field == "radius" then
			if not finite_number(value) or value <= 0 then
				return false, "village radius must be a positive finite number"
			end
			record.radius = value
		elseif field == "governance" then
			if type(value) ~= "table" then
				return false, "village governance must be a table"
			end
			if value.public ~= nil and type(value.public) ~= "boolean" then
				return false, "governance.public must be a boolean"
			end
			if value.allies ~= nil and type(value.allies) ~= "table" then
				return false, "governance.allies must be a table"
			end
			local merged, merge_error = merge_table(record.governance, value)
			if not merged then
				return false, merge_error
			end
		elseif field == "danger" then
			if type(value) ~= "table" then
				return false, "village danger state must be a table"
			end
			if value.active ~= nil and type(value.active) ~= "boolean" then
				return false, "danger.active must be a boolean"
			end
			if value.level ~= nil and (not finite_number(value.level) or value.level < 0) then
				return false, "danger.level must be a non-negative finite number"
			end
			if value.threats ~= nil and type(value.threats) ~= "table" then
				return false, "danger.threats must be a table"
			end
			local merged, merge_error = merge_table(record.danger, value)
			if not merged then
				return false, merge_error
			end
		else
			if type(value) ~= "table" then
				return false, "village field " .. field .. " must be a table"
			end
			record[field] = value
		end
	end
	return true
end

function registry.ensure(owner, initial)
	if read_only_error then
		return nil, read_only_error
	end
	local valid_owner, owner_error = normalize_owner(owner)
	if not valid_owner then
		return nil, owner_error
	end
	local existing_id = state.owners[valid_owner]
	if existing_id and state.villages[existing_id] then
		return copy_result(state.villages[existing_id]), false
	end

	local village = default_village(valid_owner)
	if initial ~= nil then
		local applied, apply_error = apply_patch(village, initial)
		if not applied then
			return nil, apply_error
		end
	end
	local candidate, copy_error = serializable_copy(state)
	if copy_error then
		return nil, copy_error
	end
	if candidate.villages[village.id] then
		return nil, "stable village ID is already owned by another record"
	end
	candidate.villages[village.id] = village
	candidate.owners[valid_owner] = village.id
	local committed, commit_error = commit(candidate)
	if not committed then
		return nil, commit_error
	end
	return copy_result(village), true
end

function registry.get(reference)
	local village_id, resolve_error = resolve_id(reference)
	if not village_id then
		return nil, resolve_error
	end
	return copy_result(state.villages[village_id])
end

-- Village governance only: owner, declared allies and public access. Global
-- administrators and temporary/visitor grants remain the responsibility of
-- access.lua, whose checks should be composed by the eventual caller.
function registry.can_access(reference, player_name)
	if type(player_name) ~= "string" or player_name == "" then
		return false, "invalid_player"
	end
	local village_id, resolve_error = resolve_id(reference)
	if not village_id then
		return false, resolve_error
	end
	local village = state.villages[village_id]
	if village.owner == player_name then
		return true, "owner"
	end
	local ally = village.governance.allies[player_name]
	if ally == true or ally == player_name or
			(type(ally) == "table" and ally.enabled ~= false) then
		return true, "ally"
	end
	if village.governance.public then
		return true, "public"
	end
	return false, "private"
end

function registry.update(reference, patch)
	if read_only_error then
		return nil, read_only_error
	end
	local village_id, resolve_error = resolve_id(reference)
	if not village_id then
		return nil, resolve_error
	end
	local candidate, copy_error = serializable_copy(state)
	if copy_error then
		return nil, copy_error
	end
	local village = candidate.villages[village_id]
	local applied, apply_error = apply_patch(village, patch)
	if not applied then
		return nil, apply_error
	end
	village.revision = village.revision + 1
	local committed, commit_error = commit(candidate)
	if not committed then
		return nil, commit_error
	end
	return copy_result(village)
end

local function collection_for(village, collection_name)
	local path = COLLECTION_PATHS[collection_name]
	if not path then
		return nil, "unknown village collection: " .. tostring(collection_name)
	end
	local collection = village
	for _, field in ipairs(path) do
		if type(collection[field]) ~= "table" then
			collection[field] = {}
		end
		collection = collection[field]
	end
	return collection
end

local function position_key(value)
	local pos = value
	if type(value) == "table" and type(value.pos) == "table" then
		pos = value.pos
	end
	if type(pos) ~= "table" or not finite_number(pos.x) or
			not finite_number(pos.y) or not finite_number(pos.z) then
		return nil
	end
	return ("pos:%.17g,%.17g,%.17g"):format(pos.x, pos.y, pos.z)
end

local function next_numeric_key(collection)
	local maximum = 0
	for key in pairs(collection) do
		if type(key) == "number" and finite_number(key) and key > maximum then
			maximum = math.floor(key)
		end
	end
	return maximum + 1
end

local function derive_entry_key(collection, value, explicit_key)
	if explicit_key ~= nil then
		if type(explicit_key) ~= "string" and type(explicit_key) ~= "number" then
			return nil, "village collection key must be a string or number"
		end
		if type(explicit_key) == "number" and not finite_number(explicit_key) then
			return nil, "village collection key must be finite"
		end
		if explicit_key == "" then
			return nil, "village collection key must not be empty"
		end
		return explicit_key
	end
	if type(value) == "string" or type(value) == "number" then
		return value
	end
	if type(value) == "table" then
		for _, field in ipairs({"id", "inventory_name", "owner", "name", "key"}) do
			local candidate = value[field]
			if (type(candidate) == "string" and candidate ~= "") or
					(type(candidate) == "number" and finite_number(candidate)) then
				return candidate
			end
		end
		local pos_key = position_key(value)
		if pos_key then
			return pos_key
		end
	end
	return next_numeric_key(collection)
end

function registry.add(reference, collection_name, value, explicit_key)
	if read_only_error then
		return nil, read_only_error
	end
	if value == nil then
		return nil, "cannot add nil to a village collection"
	end
	local village_id, resolve_error = resolve_id(reference)
	if not village_id then
		return nil, resolve_error
	end
	local safe_value, value_error = serializable_copy(value)
	if value_error then
		return nil, value_error
	end
	local candidate, copy_error = serializable_copy(state)
	if copy_error then
		return nil, copy_error
	end
	local village = candidate.villages[village_id]
	local collection, collection_error = collection_for(village, collection_name)
	if not collection then
		return nil, collection_error
	end
	local key, key_error = derive_entry_key(collection, safe_value, explicit_key)
	if key_error then
		return nil, key_error
	end
	if collection[key] ~= nil then
		if deep_equal(collection[key], safe_value) then
			return copy_result(village), key, false
		end
		return nil, "village collection key already exists: " .. tostring(key)
	end
	collection[key] = safe_value
	village.revision = village.revision + 1
	local committed, commit_error = commit(candidate)
	if not committed then
		return nil, commit_error
	end
	return copy_result(village), key, true
end

function registry.remove(reference, collection_name, key_or_value)
	if read_only_error then
		return nil, read_only_error
	end
	local village_id, resolve_error = resolve_id(reference)
	if not village_id then
		return nil, resolve_error
	end
	local candidate, copy_error = serializable_copy(state)
	if copy_error then
		return nil, copy_error
	end
	local village = candidate.villages[village_id]
	local collection, collection_error = collection_for(village, collection_name)
	if not collection then
		return nil, collection_error
	end

	local key = nil
	if (type(key_or_value) == "string" or type(key_or_value) == "number") and
			collection[key_or_value] ~= nil then
		key = key_or_value
	else
		local safe_value, value_error = serializable_copy(key_or_value)
		if value_error then
			return nil, value_error
		end
		for candidate_key, entry in pairs(collection) do
			if deep_equal(entry, safe_value) then
				key = candidate_key
				break
			end
		end
	end
	if key == nil then
		return copy_result(village), false
	end
	collection[key] = nil
	village.revision = village.revision + 1
	local committed, commit_error = commit(candidate)
	if not committed then
		return nil, commit_error
	end
	return copy_result(village), true
end

return registry
