-- Persistent collaborative task coordination.
--
-- Runtime entities are deliberately kept out of persisted task records. A task
-- only stores stable villager inventory names and resolves loaded entities when
-- it needs to update their transient job state.

local tasks = {}
local comm = working_villages.communication

local STATE_KEY = "_collaborative_tasks_v2"
local COUNTER_KEY = "_collaborative_task_counter_v2"
local STATE_VERSION = 2
local DEFAULT_TTL = 600
local DEFAULT_HISTORY_RETENTION = 3600
local CLEANUP_INTERVAL = 5

local terminal_states = {
	completed = true,
	failed = true,
	cancelled = true,
	expired = true,
}

tasks.registered = {}
tasks.records = {}
tasks.active = {}
tasks.counter = 0

local function log_warning(message)
	if minetest and type(minetest.log) == "function" then
		minetest.log("warning", "[working_villages] " .. message)
	end
end

local function get_gametime()
	if minetest and type(minetest.get_gametime) == "function" then
		local ok, value = pcall(minetest.get_gametime)
		if ok and type(value) == "number" then
			return value
		end
	end
	return 0
end

local function get_mod_storage()
	if not minetest or type(minetest.get_mod_storage) ~= "function" then
		return nil
	end
	local ok, result = pcall(minetest.get_mod_storage)
	if ok then
		return result
	end
	return nil
end

local storage = get_mod_storage()

local function storage_get_string(key)
	if not storage then
		return nil
	end
	if type(storage.get_string) == "function" then
		local ok, value = pcall(storage.get_string, storage, key)
		if ok then
			return value
		end
	elseif type(storage.get) == "function" then
		local ok, value = pcall(storage.get, storage, key)
		if ok then
			return value
		end
	end
	return nil
end

local function storage_set_string(key, value)
	if not storage then
		return false
	end
	if type(storage.set_string) == "function" then
		return pcall(storage.set_string, storage, key, value)
	elseif type(storage.set) == "function" then
		return pcall(storage.set, storage, key, value)
	end
	return false
end

local function storage_get_counter()
	if not storage then
		return 0
	end
	if type(storage.get_int) == "function" then
		local ok, value = pcall(storage.get_int, storage, COUNTER_KEY)
		if ok and type(value) == "number" then
			return math.max(0, math.floor(value))
		end
	end
	return tonumber(storage_get_string(COUNTER_KEY)) or 0
end

local function storage_set_counter(value)
	if not storage then
		return false
	end
	if type(storage.set_int) == "function" then
		return pcall(storage.set_int, storage, COUNTER_KEY, value)
	end
	return storage_set_string(COUNTER_KEY, tostring(value))
end

local function serializable_copy(value, seen, depth)
	local value_type = type(value)
	if value_type == "nil" or value_type == "boolean" or value_type == "string" then
		return value
	end
	if value_type == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return nil, "non-finite number"
		end
		return value
	end
	if value_type ~= "table" then
		return nil, "unsupported value type: " .. value_type
	end
	if depth >= 32 then
		return nil, "table nesting is too deep"
	end
	if seen[value] then
		return nil, "cyclic table"
	end

	seen[value] = true
	local result = {}
	for key, entry in pairs(value) do
		local key_type = type(key)
		if key_type ~= "string" and key_type ~= "number" and key_type ~= "boolean" then
			seen[value] = nil
			return nil, "unsupported table key type: " .. key_type
		end
		local copied, err = serializable_copy(entry, seen, depth + 1)
		if err then
			seen[value] = nil
			return nil, err
		end
		result[key] = copied
	end
	seen[value] = nil
	return result
end

local function copy_serializable(value)
	return serializable_copy(value, {}, 0)
end

local function copy_record(record)
	local copied = copy_serializable(record)
	return copied
end

local function persist_state()
	if not storage or not minetest or type(minetest.serialize) ~= "function" then
		return false
	end
	local snapshot = {
		version = STATE_VERSION,
		counter = tasks.counter,
		records = tasks.records,
	}
	local ok, encoded = pcall(minetest.serialize, snapshot)
	if not ok or encoded == nil then
		log_warning("unable to serialize collaborative task state")
		return false
	end
	local stored = storage_set_string(STATE_KEY, encoded)
	storage_set_counter(tasks.counter)
	if not stored then
		log_warning("unable to persist collaborative task state")
	end
	return stored
end

local function normalize_string_list(value)
	local result = {}
	local seen = {}
	if type(value) ~= "table" then
		return result
	end
	for _, entry in ipairs(value) do
		if type(entry) == "string" and entry ~= "" and not seen[entry] then
			seen[entry] = true
			result[#result + 1] = entry
		end
	end
	return result
end

local function record_has_participant(record, inventory_name)
	for _, participant in ipairs((record and record.participants) or {}) do
		if participant == inventory_name then
			return true
		end
	end
	return false
end

local function normalize_record(task_id, raw)
	if type(task_id) ~= "string" or task_id == "" or type(raw) ~= "table" then
		return nil
	end
	local state = raw.state
	if state ~= "active" and not terminal_states[state] then
		return nil
	end
	if type(raw.name) ~= "string" or raw.name == "" then
		return nil
	end

	local data = copy_serializable(raw.data or {})
	if type(data) ~= "table" then
		data = {}
	end
	local assignments = copy_serializable(raw.assignments or {})
	if type(assignments) ~= "table" then
		assignments = {}
	end

	local created_at = tonumber(raw.created_at) or get_gametime()
	local expires_at = tonumber(raw.expires_at)
	if state == "active" and not expires_at then
		expires_at = created_at + DEFAULT_TTL
	end
	local record = {
		id = task_id,
		name = raw.name,
		state = state,
		owner_name = type(raw.owner_name) == "string" and raw.owner_name or "",
		initiator = type(raw.initiator) == "string" and raw.initiator or "",
		participants = normalize_string_list(raw.participants),
		assignments = assignments,
		data = data,
		created_at = created_at,
		updated_at = tonumber(raw.updated_at) or created_at,
		expires_at = expires_at,
		completed_at = tonumber(raw.completed_at),
		failed_at = tonumber(raw.failed_at),
		cancelled_at = tonumber(raw.cancelled_at),
		expired_at = tonumber(raw.expired_at),
		reason = type(raw.reason) == "string" and raw.reason or nil,
	}
	if raw.result ~= nil then
		local result = copy_serializable(raw.result)
		record.result = result
	end
	if raw.progress ~= nil then
		local progress = copy_serializable(raw.progress)
		record.progress = progress
	end
	return record
end

local function restore_state()
	tasks.records = {}
	tasks.active = {}
	tasks.counter = storage_get_counter()

	local encoded = storage_get_string(STATE_KEY)
	if encoded == nil or encoded == "" or not minetest or type(minetest.deserialize) ~= "function" then
		return false
	end
	local ok, decoded = pcall(minetest.deserialize, encoded)
	if not ok or type(decoded) ~= "table" then
		log_warning("ignoring invalid collaborative task storage")
		return false
	end

	tasks.counter = math.max(tasks.counter, math.floor(tonumber(decoded.counter) or 0))
	local records = type(decoded.records) == "table" and decoded.records or decoded.active
	for task_id, raw in pairs(type(records) == "table" and records or {}) do
		local record = normalize_record(task_id, raw)
		if record then
			tasks.records[task_id] = record
			if record.state == "active" then
				tasks.active[task_id] = record
			end
			local suffix = tonumber(task_id:match(":(%d+)$"))
			if suffix and suffix > tasks.counter then
				tasks.counter = suffix
			end
		end
	end
	return true
end

local function get_loaded_villager(inventory_name)
	if type(inventory_name) ~= "string" or inventory_name == "" then
		return nil
	end
	if comm and type(comm.find_villager_by_inventory_name) == "function" then
		local ok, villager = pcall(comm.find_villager_by_inventory_name, inventory_name)
		if ok and villager then
			return villager
		end
	end
	for _, villager in pairs((minetest and minetest.luaentities) or {}) do
		if villager and villager.inventory_name == inventory_name then
			return villager
		end
	end
	return nil
end

local function clear_loaded_assignment(record)
	local cleared = 0
	for _, inventory_name in ipairs(record.participants or {}) do
		local villager = get_loaded_villager(inventory_name)
		if villager and villager.job_data and villager.job_data.collab_task == record.id then
			villager.job_data.collab_task = nil
			cleared = cleared + 1
		end
	end
	return cleared
end

local function reconcile_loaded_assignments()
	local reconciled = 0
	for _, villager in pairs((minetest and minetest.luaentities) or {}) do
		if villager and type(villager.inventory_name) == "string" then
			villager.job_data = villager.job_data or {}
			local task_id = villager.job_data.collab_task
			local record = task_id and tasks.records[task_id] or nil
			if task_id and (not record or record.state ~= "active"
					or not record_has_participant(record, villager.inventory_name)) then
				villager.job_data.collab_task = nil
				reconciled = reconciled + 1
			end
		end
	end
	for task_id, record in pairs(tasks.active) do
		for _, inventory_name in ipairs(record.participants or {}) do
			local villager = get_loaded_villager(inventory_name)
			if villager then
				villager.job_data = villager.job_data or {}
				local assigned = villager.job_data.collab_task
				if not assigned or not tasks.active[assigned] then
					villager.job_data.collab_task = task_id
					reconciled = reconciled + 1
				end
			end
		end
	end
	return reconciled
end

local function send_terminal_message(record)
	if not comm or type(comm.send_message) ~= "function" then
		return
	end
	local initiator = get_loaded_villager(record.initiator)
	for _, inventory_name in ipairs(record.participants or {}) do
		local villager = get_loaded_villager(inventory_name)
		if villager then
			pcall(comm.send_message, initiator, villager, "task_complete", {
				task = record.name,
				task_id = record.id,
				status = record.state,
				ok = record.state == "completed",
				reason = record.reason,
			})
		end
	end
end

local function transition(task_id, state, value, now, defer_persist)
	local record = tasks.records[task_id]
	if not record then
		return false, "Task introuvable"
	end
	if record.state ~= "active" then
		return false, "Task deja terminee"
	end
	if not terminal_states[state] then
		return false, "Etat de tache invalide"
	end

	now = tonumber(now) or get_gametime()
	if state == "completed" and value ~= nil then
		local result, err = copy_serializable(value)
		if err then
			return false, "Resultat non serialisable: " .. err
		end
		record.result = result
	end
	record.state = state
	record.updated_at = now
	if state == "completed" then
		record.completed_at = now
	elseif state == "failed" then
		record.failed_at = now
		record.reason = tostring(value or "Echec de la tache")
	elseif state == "cancelled" then
		record.cancelled_at = now
		record.reason = tostring(value or "Tache annulee")
	elseif state == "expired" then
		record.expired_at = now
		record.reason = tostring(value or "Tache expiree")
	end

	tasks.active[task_id] = nil
	clear_loaded_assignment(record)
	send_terminal_message(record)
	if not defer_persist then
		persist_state()
	end
	return true, copy_record(record)
end

local function next_task_id(name)
	repeat
		tasks.counter = tasks.counter + 1
	until tasks.records[name .. ":" .. tostring(tasks.counter)] == nil
	storage_set_counter(tasks.counter)
	return name .. ":" .. tostring(tasks.counter)
end

local function copy_definition(definition)
	local copy = {}
	for key, value in pairs(definition) do
		if key == "required_jobs" then
			copy.required_jobs = {}
			for _, job in ipairs(value) do
				copy.required_jobs[#copy.required_jobs + 1] = job
			end
		else
			copy[key] = value
		end
	end
	return copy
end

function tasks.register_task(name, definition)
	if type(name) ~= "string" or name == "" or type(definition) ~= "table" then
		return false
	end
	if type(definition.required_jobs) ~= "table" or #definition.required_jobs == 0 then
		return false
	end
	for _, job in ipairs(definition.required_jobs) do
		if type(job) ~= "string" or job == "" then
			return false
		end
	end
	local minimum = tonumber(definition.min_villagers)
	if not minimum or minimum < 1 then
		return false
	end
	if definition.task_logic ~= nil and type(definition.task_logic) ~= "function" then
		return false
	end

	local copied = copy_definition(definition)
	copied.min_villagers = math.max(1, math.floor(minimum))
	copied.radius = math.max(1, tonumber(definition.radius) or 20)
	copied.timeout = math.max(1, tonumber(definition.timeout or definition.ttl) or DEFAULT_TTL)
	tasks.registered[name] = copied
	return true
end

local function candidate_identifier(villager)
	return villager and type(villager.inventory_name) == "string" and villager.inventory_name or nil
end

local function candidate_is_available(villager, owner_name)
	local identifier = candidate_identifier(villager)
	if not identifier or identifier == "" or (villager.owner_name or "") ~= owner_name then
		return false
	end
	villager.job_data = villager.job_data or {}
	local current_task = villager.job_data.collab_task
	local current_record = current_task and tasks.active[current_task] or nil
	if current_record and record_has_participant(current_record, identifier) then
		return false
	end
	if current_task then
		villager.job_data.collab_task = nil
	end
	return true
end

local function get_role_candidates(origin, radius, job, initiator, owner_name)
	local candidates = {}
	local seen = {}
	local function add(villager, prefer)
		local identifier = candidate_identifier(villager)
		if identifier and not seen[identifier] and candidate_is_available(villager, owner_name) then
			seen[identifier] = true
			candidates[#candidates + 1] = {villager = villager, prefer = prefer == true}
		end
	end

	if initiator and type(initiator.get_job_name) == "function" and initiator:get_job_name() == job then
		add(initiator, true)
	end
	if comm and type(comm.find_nearby_villagers) == "function" then
		local ok, nearby = pcall(comm.find_nearby_villagers, origin, radius, job, owner_name)
		if ok and type(nearby) == "table" then
			for _, villager in ipairs(nearby) do
				add(villager, villager == initiator)
			end
		end
	end

	table.sort(candidates, function(left, right)
		if left.prefer ~= right.prefer then
			return left.prefer
		end
		return left.villager.inventory_name < right.villager.inventory_name
	end)
	local result = {}
	for _, candidate in ipairs(candidates) do
		result[#result + 1] = candidate.villager
	end
	return result
end

local function select_participants(origin, definition, initiator)
	local owner_name = initiator.owner_name or ""
	local selected = {}
	local selected_by_id = {}
	local assignments = {}
	local candidates_by_role = {}
	local role_order = {}
	local seen_roles = {}

	for _, job in ipairs(definition.required_jobs) do
		if not seen_roles[job] then
			seen_roles[job] = true
			role_order[#role_order + 1] = job
			candidates_by_role[job] = get_role_candidates(origin, definition.radius, job, initiator, owner_name)
		end
	end

	-- Reserve one distinct participant for every required role first.
	for _, job in ipairs(role_order) do
		local chosen = nil
		for _, candidate in ipairs(candidates_by_role[job]) do
			local identifier = candidate_identifier(candidate)
			if not selected_by_id[identifier] then
				chosen = candidate
				break
			end
		end
		if not chosen then
			return nil, nil, "Metier requis indisponible: " .. job
		end
		local identifier = candidate_identifier(chosen)
		selected_by_id[identifier] = true
		selected[#selected + 1] = chosen
		assignments[#assignments + 1] = {job = job, participant = identifier}
	end

	-- If min_villagers is larger than the number of roles, fill with other
	-- eligible workers from those roles, without duplicating an entity.
	if #selected < definition.min_villagers then
		for _, job in ipairs(role_order) do
			for _, candidate in ipairs(candidates_by_role[job]) do
				local identifier = candidate_identifier(candidate)
				if not selected_by_id[identifier] then
					selected_by_id[identifier] = true
					selected[#selected + 1] = candidate
					assignments[#assignments + 1] = {job = job, participant = identifier}
					if #selected >= definition.min_villagers then
						break
					end
				end
			end
			if #selected >= definition.min_villagers then
				break
			end
		end
	end

	if #selected < definition.min_villagers then
		return nil, nil, "Pas assez de villageois disponibles"
	end
	return selected, assignments
end

function tasks.start_task(name, initiator, data)
	local definition = tasks.registered[name]
	if not definition or not initiator or not initiator.object or type(initiator.object.get_pos) ~= "function" then
		return false, "Task introuvable"
	end
	if not candidate_identifier(initiator) then
		return false, "Initiateur invalide"
	end

	tasks.cleanup(get_gametime())
	local copied_data, data_err = copy_serializable(data or {})
	if data_err then
		return false, "Donnees non serialisables: " .. data_err
	end
	local origin = initiator.object:get_pos()
	if not origin then
		return false, "Position de l'initiateur indisponible"
	end
	local participants, assignments, selection_err = select_participants(origin, definition, initiator)
	if not participants then
		return false, selection_err
	end

	local now = get_gametime()
	local task_id = next_task_id(name)
	local participant_ids = {}
	for _, villager in ipairs(participants) do
		participant_ids[#participant_ids + 1] = villager.inventory_name
	end
	local record = {
		id = task_id,
		name = name,
		state = "active",
		owner_name = initiator.owner_name or "",
		initiator = initiator.inventory_name,
		participants = participant_ids,
		assignments = assignments,
		data = copied_data,
		created_at = now,
		updated_at = now,
		expires_at = now + definition.timeout,
	}
	tasks.records[task_id] = record
	tasks.active[task_id] = record

	for _, villager in ipairs(participants) do
		villager.job_data = villager.job_data or {}
		villager.job_data.collab_task = task_id
		if comm and type(comm.send_message) == "function" then
			local payload = {
				task = name,
				task_id = task_id,
				info = definition.description or "Tache collaborative",
			}
			for key, value in pairs(copied_data) do
				if payload[key] == nil then
					payload[key] = value
				end
			end
			pcall(comm.send_message, initiator, villager, "help_needed", payload)
		end
	end
	persist_state()

	if definition.task_logic then
		local ok, logic_err = pcall(definition.task_logic, initiator, participants, copied_data)
		if not ok then
			transition(task_id, "failed", "Erreur de logique: " .. tostring(logic_err), get_gametime())
			return false, "Erreur de logique de tache: " .. tostring(logic_err)
		end
	end
	return true, task_id
end

-- Start a coordinated task when all required roles are available. The
-- fallback broadcast is deliberately exclusive: start_task already sends a
-- help_needed message to every selected participant on success.
function tasks.start_task_or_broadcast(name, initiator, data, fallback_targets)
	local started, value = tasks.start_task(name, initiator, data)
	if started then
		return true, value, 0
	end

	if not comm or type(comm.broadcast) ~= "function" then
		return false, value, 0
	end
	local targets = fallback_targets
	if type(targets) == "function" then
		local ok, resolved = pcall(targets)
		if not ok then
			return false, value, 0
		end
		targets = resolved
	end
	if type(targets) ~= "table" then
		targets = {}
	end
	local ok, sent = pcall(comm.broadcast, initiator, targets, "help_needed", data or {})
	if not ok then
		return false, value, 0
	end
	return false, value, math.max(0, math.floor(tonumber(sent) or 0))
end

function tasks.get(task_id)
	local record = tasks.records[task_id]
	if record and record.state == "active" and record.expires_at and record.expires_at <= get_gametime() then
		transition(task_id, "expired", "Tache expiree", get_gametime())
		record = tasks.records[task_id]
	end
	return record and copy_record(record) or nil
end

function tasks.list(owner_name, state)
	local result = {}
	for _, record in pairs(tasks.records) do
		if (not owner_name or owner_name == "" or record.owner_name == owner_name)
				and (not state or record.state == state) then
			result[#result + 1] = copy_record(record)
		end
	end
	table.sort(result, function(a, b)
		if a.created_at == b.created_at then
			return a.id < b.id
		end
		return a.created_at < b.created_at
	end)
	return result
end

function tasks.update(task_id, updates)
	local record = tasks.records[task_id]
	if not record then
		return false, "Task introuvable"
	end
	if record.state ~= "active" then
		return false, "Task deja terminee"
	end
	if type(updates) ~= "table" then
		return false, "Mise a jour invalide"
	end

	local protected = {
		id = true,
		name = true,
		state = true,
		owner_name = true,
		initiator = true,
		participants = true,
		assignments = true,
		created_at = true,
		completed_at = true,
		failed_at = true,
		cancelled_at = true,
		expired_at = true,
	}
	local copied, err = copy_serializable(updates)
	if err then
		return false, "Mise a jour non serialisable: " .. err
	end
	if copied.expires_at ~= nil and type(copied.expires_at) ~= "number" then
		return false, "expires_at doit etre un nombre"
	end
	for key in pairs(copied) do
		if type(key) ~= "string" then
			return false, "Les champs de mise a jour doivent etre nommes"
		end
	end
	for key, value in pairs(copied) do
		if not protected[key] then
			record[key] = value
		end
	end
	record.updated_at = get_gametime()
	persist_state()
	return true, copy_record(record)
end

-- Credit only food that a participant has actually deposited into the shared
-- village stock. Personal hunger requests intentionally do not use this path.
function tasks.record_food_deposit(task_id, contributor, count)
	local record = tasks.records[task_id]
	if not record then
		return false, "Task introuvable"
	end
	if record.state ~= "active" then
		return false, "Task deja terminee"
	end
	if record.name ~= "food_support" or type(record.data) ~= "table"
			or record.data.delivery_target ~= "shared_storage" then
		return false, "La tache ne cible pas le stock partage"
	end

	local contributor_id = contributor
	if type(contributor) == "table" then
		contributor_id = candidate_identifier(contributor)
	end
	if type(contributor_id) ~= "string" or contributor_id == ""
			or not record_has_participant(record, contributor_id) then
		return false, "Contributeur non autorise"
	end
	if type(count) ~= "number" or count ~= count or count == math.huge
			or count == -math.huge or count <= 0 or count ~= math.floor(count) then
		return false, "Quantite deposee invalide"
	end

	local progress = record.data.delivery_progress
	if type(progress) ~= "table" then
		progress = {}
		record.data.delivery_progress = progress
	end
	local previous = tonumber(progress.food) or 0
	if previous ~= previous or previous < 0 then
		previous = 0
	end
	progress.food = math.floor(previous) + count
	record.updated_at = get_gametime()

	local required = math.max(1, math.floor(tonumber(record.data.count) or 1))
	if progress.food >= required then
		return transition(task_id, "completed", {
			delivered_resource = "food",
			delivered_count = progress.food,
			delivery_target = "shared_storage",
		}, record.updated_at)
	end
	persist_state()
	return true, copy_record(record)
end

function tasks.complete(task_id, result)
	return transition(task_id, "completed", result, get_gametime())
end

function tasks.fail(task_id, reason)
	return transition(task_id, "failed", reason, get_gametime())
end

function tasks.cancel(task_id, reason)
	return transition(task_id, "cancelled", reason, get_gametime())
end

function tasks.participant_unavailable(inventory_name, reason)
	if type(inventory_name) ~= "string" or inventory_name == "" then
		return 0
	end
	local affected = {}
	for task_id, record in pairs(tasks.active) do
		if record_has_participant(record, inventory_name) then
			affected[#affected + 1] = task_id
		end
	end
	for _, task_id in ipairs(affected) do
		transition(task_id, "failed", reason or "Participant indisponible", get_gametime(), true)
	end
	if #affected > 0 then
		persist_state()
	end
	return #affected
end

function tasks.cleanup(now, options)
	now = tonumber(now) or get_gametime()
	options = type(options) == "table" and options or {}
	local retention = tonumber(options.terminal_retention)
	if retention == nil then
		retention = DEFAULT_HISTORY_RETENTION
	end
	retention = math.max(0, retention)
	local expired = 0
	local removed = 0
	local changed = false

	local expiring = {}
	local invalid = {}
	for task_id, record in pairs(tasks.active) do
		if record.expires_at and record.expires_at <= now then
			expiring[#expiring + 1] = task_id
		else
			for _, assignment in ipairs(record.assignments or {}) do
				local villager = get_loaded_villager(assignment.participant)
				if villager and ((villager.owner_name or "") ~= record.owner_name or
						(type(villager.get_job_name) == "function" and
						villager:get_job_name() ~= assignment.job)) then
					invalid[task_id] = "Participant change de village ou de metier"
					break
				end
			end
		end
	end
	for _, task_id in ipairs(expiring) do
		local ok = transition(task_id, "expired", "Tache expiree", now, true)
		if ok then
			expired = expired + 1
			changed = true
		end
	end
	for task_id, reason in pairs(invalid) do
		local ok = transition(task_id, "failed", reason, now, true)
		if ok then
			changed = true
		end
	end

	for task_id, record in pairs(tasks.records) do
		if terminal_states[record.state] then
			local terminal_at = record.completed_at or record.failed_at or record.cancelled_at or record.expired_at or record.updated_at
			if terminal_at and now - terminal_at >= retention then
				tasks.records[task_id] = nil
				tasks.active[task_id] = nil
				removed = removed + 1
				changed = true
			end
		end
	end

	local reconciled = reconcile_loaded_assignments()
	if changed then
		persist_state()
	end
	return {
		expired = expired,
		removed = removed,
		reconciled = reconciled,
	}
end

function tasks.restore()
	local restored = restore_state()
	tasks.cleanup(get_gametime())
	return restored
end

restore_state()
tasks.cleanup(get_gametime())

if minetest and type(minetest.register_globalstep) == "function" then
	local elapsed = 0
	minetest.register_globalstep(function(dtime)
		elapsed = elapsed + (tonumber(dtime) or 0)
		if elapsed >= CLEANUP_INTERVAL then
			elapsed = 0
			tasks.cleanup(get_gametime())
		end
	end)
end

return tasks
