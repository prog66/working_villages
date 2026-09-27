local func = working_villages.require("jobs/util")
local log = working_villages.require("log")
local spawn_state = working_villages.require("spawn_state")
local compat = working_villages.compat
working_villages.spawn_state = spawn_state

-- Track if initial spawn has been done
local spawn_storage = minetest.get_mod_storage()
local INITIAL_SPAWN_KEY = "initial_spawn_done"
local INITIAL_SPAWN_STATE_KEY = "initial_spawn_state_v3"
local INITIAL_SPAWN_LEGACY_STATE_KEY = "initial_spawn_state_v2"
local INITIAL_SPAWN_DELAY = 5  -- seconds to wait after server start
local INITIAL_SPAWN_RETRY_DELAY = 10
local INITIAL_SPAWN_MAX_RETRIES = 6
local INITIAL_SPAWN_REPAIR_DELAY = 2
local INITIAL_RECONCILE_SETTLE_DELAY = 0.75
local INITIAL_RECONCILE_PASSES = 3
local JOIN_SPAWN_DELAY = 2
local MANUAL_SPAWN_COOLDOWN = 30
local SPAWN_RADIUS = 3  -- radius in blocks for circular spawn pattern
local SPAWN_SEARCH_DEPTH = 160  -- max depth/height scan for a valid surface spawn
local SPAWN_SEARCH_RADIUS = 2  -- horizontal radius to search around each target column
local SPAWN_HEADROOM = 2
local spawn_enabled = working_villages.setting_enabled("spawn", true)
local passive_spawn_enabled = working_villages.setting_enabled("passive_spawn", false)
local population_growth_enabled = working_villages.setting_enabled("population_growth", true)
local population_limit = math.max(5, tonumber(minetest.settings:get("working_villages_population_limit")) or 20)
local population_radius = math.max(16, tonumber(minetest.settings:get("working_villages_population_radius")) or 64)
local population_growth_interval = math.max(60,
    tonumber(minetest.settings:get("working_villages_population_growth_interval")) or 600)
local population_growth_food_cost = math.max(1,
    tonumber(minetest.settings:get("working_villages_population_growth_food_cost")) or 16)
local initial_spawn_in_progress = false
local initial_spawn_retry_scheduled = false
local initial_spawn_retry_count = 0
local initial_spawn_anchor = nil
local manual_spawn_cooldowns = {}
local initial_spawn_reconcile_in_progress = false
local request_initial_spawn

local INITIAL_JOBS = {
    "working_villages:job_woodcutter",
    "working_villages:job_farmer",
    "working_villages:job_autonome",
    "working_villages:job_miner",
    "working_villages:job_builder",
}

local function load_initial_spawn_state()
    local serialized = spawn_storage:get_string(INITIAL_SPAWN_STATE_KEY)
    if serialized == "" then
        serialized = spawn_storage:get_string(INITIAL_SPAWN_LEGACY_STATE_KEY)
    end
    local data = serialized ~= "" and minetest.deserialize(serialized) or nil
    local legacy_completed = spawn_storage:get_string(INITIAL_SPAWN_KEY) == "true"
    return spawn_state.normalize(data, #INITIAL_JOBS, legacy_completed)
end

working_villages._initial_spawn_state_snapshot = function()
    return load_initial_spawn_state()
end

local function save_initial_spawn_state(state)
    state = spawn_state.normalize(state, #INITIAL_JOBS, false)
    spawn_storage:set_string(INITIAL_SPAWN_STATE_KEY, minetest.serialize(state))
    if state.completed then
        spawn_storage:set_string(INITIAL_SPAWN_KEY, "true")
    end
    return state
end

local function initial_spawn_completed()
    return load_initial_spawn_state().completed
end

local function count_loaded_villagers(origin, radius, owner_name)
    if not origin then
        return 0
    end
    local count = 0
    for _, object in ipairs(minetest.get_objects_inside_radius(origin, radius or population_radius)) do
        local entity = object and object:get_luaentity() or nil
        if entity and entity.name and working_villages.is_villager(entity.name) then
            if not owner_name or owner_name == "" or entity.owner_name == owner_name then
                count = count + 1
            end
        end
    end
    return count
end

local function count_village_population(origin, owner_name)
	local persistent = working_villages.population
		and working_villages.population.count(owner_name, origin, population_radius) or 0
	return math.max(persistent, count_loaded_villagers(origin, population_radius, owner_name))
end

working_villages.count_loaded_villagers = count_loaded_villagers

local function get_storage_chest_search_list()
    return compat.get_chest_search_nodes()
end

local function find_nearest_storage_chest(origin, radius)
    local minp = vector.subtract(origin, radius)
    local maxp = vector.add(origin, radius)
    local nodes = minetest.find_nodes_in_area(minp, maxp, get_storage_chest_search_list())
    local best_pos = nil
    local best_distance = nil
    for _, pos in ipairs(nodes) do
        local rounded = vector.round(pos)
        if working_villages.is_chest_pos and working_villages.is_chest_pos(rounded) then
            local distance = vector.distance(origin, rounded)
            if not best_distance or distance < best_distance then
                best_distance = distance
                best_pos = rounded
            end
        end
    end
    return best_pos
end

local function spawner(initial_job)
    return function(pos, _, _, active_object_count_wider)
               --  (pos, node, active_object_count, active_object_count_wider)
        if active_object_count_wider > 1 then return end
        if count_village_population(pos, "working_villages:self_employed") >= population_limit then
            return
        end
        if func.is_protected_owner("working_villages:self_employed",pos) then
            return
        end

        local pos1 = {x=pos.x-4,y=pos.y-8,z=pos.z-4}
        local pos2 = {x=pos.x+4,y=pos.y+1,z=pos.z+4}
        for _,p in ipairs(minetest.find_nodes_in_area_under_air(
                pos1,pos2,"group:soil")) do
            local above = minetest.get_node({x=p.x,y=p.y+2,z=p.z})
            local above_def = minetest.registered_nodes[above.name]
            if above_def and not above_def.groups.walkable then
                log.action("Spawning a %s at %s", initial_job, minetest.pos_to_string(p,0))
                local gender = {
                    "working_villages:villager_male",
                    "working_villages:villager_female",
                }
                local new_villager = minetest.add_entity(
                    {x=p.x,y=p.y+1,z=p.z},gender[math.random(2)], ""
                )
                if not new_villager then
                    return
                end
                local entity = new_villager:get_luaentity()
                if not entity then
                    new_villager:remove()
                    return
                end
                entity.new_job = initial_job
                entity.owner_name = "working_villages:self_employed"
                entity:update_infotext()
                if entity.apply_owner_visuals then
                    entity:apply_owner_visuals()
                end
				if working_villages.population then
					working_villages.population.register(entity, p)
				end
                return
            end
        end
    end
end

-- Spawn a single villager at a specific position
local function spawn_villager_at(pos, job_name, owner_name, initial_slot)
    if not pos then
        return false
    end
    local gender = {
        "working_villages:villager_male",
        "working_villages:villager_female",
    }
    local new_villager = minetest.add_entity(pos, gender[math.random(2)], "")
    if new_villager then
        local entity = new_villager:get_luaentity()
        if entity then
            entity.new_job = job_name or ""
            entity.owner_name = owner_name or "working_villages:self_employed"
            -- A newly generated village has no job-site marker yet.  Keep a
            -- stable work anchor at the real spawn point so profession
            -- fallbacks do not immediately wander without a destination.
            entity.pos_data = entity.pos_data or {}
            entity.pos_data.job_pos = vector.round(pos)
            if initial_slot then
                entity.initial_spawn_slot = math.floor(tonumber(initial_slot) or 0)
            end
            entity:update_infotext()
            if entity.apply_owner_visuals then
                entity:apply_owner_visuals()
            end
            if working_villages.population then
                working_villages.population.register(entity, pos)
            end
            log.action("Spawned villager with job %s at %s", job_name or "none", minetest.pos_to_string(pos, 0))
            return true, entity
        end
        new_villager:remove()
    end
    return false
end

local function round_pos(pos)
    return {
        x = math.floor((pos.x or 0) + 0.5),
        y = math.floor((pos.y or 0) + 0.5),
        z = math.floor((pos.z or 0) + 0.5),
    }
end

local function remember_initial_spawn_anchor(pos, reason)
    if not pos then
        return
    end
    initial_spawn_anchor = round_pos(pos)
    log.action(
        "Initial villager spawn anchor set from %s: %s",
        reason or "unknown",
        minetest.pos_to_string(initial_spawn_anchor, 0)
    )
end

local function get_connected_player_spawn_anchor()
    for _, player in ipairs(minetest.get_connected_players()) do
        if player and player:is_player() then
            local pos = player:get_pos()
            if pos then
                return round_pos(pos)
            end
        end
    end
    return nil
end

local function initial_entity_id(entity)
    local identity = entity and entity.inventory_name or nil
    return type(identity) == "string" and identity ~= "" and identity or nil
end

local function valid_initial_slot(value)
    local index = math.floor(tonumber(value) or 0)
    if index < 1 or index > #INITIAL_JOBS then
        return nil
    end
    return index
end

local function entity_job_name(entity)
    local job_name = entity and entity.get_job_name and entity:get_job_name() or ""
    if job_name == "" and entity then
        job_name = entity.new_job or ""
    end
    return job_name
end

local function entity_matches_legacy_slot(entity, state, index)
    return entity and state and entity.owner_name == state.owner_name
        and entity_job_name(entity) == INITIAL_JOBS[index]
end

local function bind_initial_entity(state, index, entity)
    local identity = initial_entity_id(entity)
    if not identity or not valid_initial_slot(index) then
        return false
    end
    local position = entity.object and entity.object:get_pos() or nil
    local stored_identity = state.slot_ids and state.slot_ids[index] or false
    if state.slots[index] == true and stored_identity == identity then
        entity.initial_spawn_slot = index
        spawn_state.touch_slot(state, index, identity, position)
        return true
    end
    if stored_identity and stored_identity ~= false then
        return false
    end
    if not entity_matches_legacy_slot(entity, state, index) then
        return false
    end
    if not spawn_state.mark_spawned(state, index, identity, position) then
        return false
    end
    entity.initial_spawn_slot = index
    return true
end

working_villages._initial_spawn_entity_activated = function(entity)
    local identity = initial_entity_id(entity)
    if not identity then
        return false
    end
    local state = load_initial_spawn_state()
    local index = spawn_state.find_slot_by_id(state, identity)
    if not index then
        local tagged_index = valid_initial_slot(entity.initial_spawn_slot)
        if tagged_index and bind_initial_entity(state, tagged_index, entity) then
            save_initial_spawn_state(state)
            return true
        end
        for candidate = 1, #INITIAL_JOBS do
            if state.slots[candidate] == true
                    and (not state.slot_ids[candidate] or state.slot_ids[candidate] == false)
                    and entity_matches_legacy_slot(entity, state, candidate)
                    and bind_initial_entity(state, candidate, entity) then
                save_initial_spawn_state(state)
                return true
            end
        end
        return false
    end
    bind_initial_entity(state, index, entity)
    save_initial_spawn_state(state)
    return true
end

working_villages._initial_spawn_entity_saved = function(entity)
    local identity = initial_entity_id(entity)
    if not identity then
        return false
    end
    local state = load_initial_spawn_state()
    local index = spawn_state.find_slot_by_id(state, identity)
    if not index then
        return false
    end
    entity.initial_spawn_slot = index
    if spawn_state.touch_slot(
            state,
            index,
            identity,
            entity.object and entity.object:get_pos() or nil
        ) then
        save_initial_spawn_state(state)
        return true
    end
    return false
end

working_villages._initial_spawn_entity_removed = function(entity)
    local identity = initial_entity_id(entity)
    if not identity then
        return false
    end
    local state = load_initial_spawn_state()
    local index = spawn_state.find_slot_by_id(state, identity)
    if not index or not spawn_state.release_slot(state, index, identity) then
        return false
    end
    save_initial_spawn_state(state)
    entity.initial_spawn_slot = nil
    log.action("Initial villager slot %d released after real removal of %s", index, identity)
    minetest.after(INITIAL_SPAWN_REPAIR_DELAY, function()
        if request_initial_spawn then
            request_initial_spawn({announce = false}, 0, "initial villager removal")
        end
    end)
    return true
end

local function get_connected_player_name()
    for _, player in ipairs(minetest.get_connected_players()) do
        if player and player:is_player() then
            local name = player:get_player_name()
            if name and name ~= "" then
                return name
            end
        end
    end
    return nil
end

local function resolve_initial_spawn_owner(opts, state)
    opts = opts or {}
    if not opts.force and state and state.owner_name and state.owner_name ~= "" then
        return state.owner_name
    end
    -- A forced manual spawn belongs to the administrator/player who requested
    -- it. For the normal initial spawn, the documented configured owner must
    -- take precedence over the joining player supplied by on_joinplayer.
    if opts.force and opts.owner_name and opts.owner_name ~= "" then
        return opts.owner_name
    end
    local configured_initial_owner =
        minetest.settings:get("working_villages_initial_village_owner") or ""
    if configured_initial_owner ~= "" then
        return configured_initial_owner
    end
    if opts.owner_name and opts.owner_name ~= "" then
        return opts.owner_name
    end
    local connected_name = get_connected_player_name()
    if connected_name then
        return connected_name
    end
    if minetest.settings:get_bool("working_villages_self_employed_public", false) then
        return "working_villages:self_employed"
    end
    return nil
end

-- Kept internal, but exposed for engine regression tests so the published
-- setting key and the owner-resolution precedence can be verified directly.
working_villages._resolve_initial_spawn_owner = resolve_initial_spawn_owner

local function resolve_initial_spawn_origin(opts)
    opts = opts or {}

    if opts.anchor_pos then
        return round_pos(opts.anchor_pos), "requested anchor"
    end

    local spawn_setting = minetest.settings:get("static_spawnpoint")
    if spawn_setting then
        local spawn_coords = minetest.string_to_pos(spawn_setting)
        if spawn_coords then
            return round_pos(spawn_coords), "static_spawnpoint"
        end
        log.warning("Invalid static_spawnpoint format: %s", spawn_setting)
    end

    if initial_spawn_anchor then
        return round_pos(initial_spawn_anchor), "first player spawn"
    end

    local player_anchor = get_connected_player_spawn_anchor()
    if player_anchor then
        return player_anchor, "connected player position"
    end

    return nil, "no spawn anchor available"
end

local function player_has_commanding_sceptre(player)
    if not player or not player:is_player() then
        return false
    end
    local inv = player:get_inventory()
    return inv and inv:contains_item("main", "working_villages:commanding_sceptre") or false
end

local function player_can_force_manual_spawn(player_name)
    if not player_name or player_name == "" then
        return false
    end
    if minetest.check_player_privs and minetest.check_player_privs(player_name, {server = true}) then
        return true
    end
    if working_villages.gameplay_mode ~= "creative_test" then
        return false
    end
    return player_has_commanding_sceptre(minetest.get_player_by_name(player_name))
end

local function get_manual_spawn_cooldown_remaining(player_name)
    if not player_name or player_name == "" then
        return 0
    end
    if minetest.check_player_privs and minetest.check_player_privs(player_name, {server = true}) then
        return 0
    end
    local remaining = (manual_spawn_cooldowns[player_name] or 0) - minetest.get_gametime()
    return math.max(0, remaining)
end

local function record_manual_spawn_use(player_name)
    if not player_name or player_name == "" then
        return
    end
    if minetest.check_player_privs and minetest.check_player_privs(player_name, {server = true}) then
        return
    end
    manual_spawn_cooldowns[player_name] = minetest.get_gametime() + MANUAL_SPAWN_COOLDOWN
end

local function get_node_safe(pos)
    return minetest.get_node_or_nil(pos) or minetest.get_node(pos)
end

local function is_clear_spawn_node(pos)
    local node = get_node_safe(pos)
    if not node or node.name == "ignore" then
        return false
    end
    if minetest.get_item_group(node.name, "liquid") > 0 then
        return false
    end
    local def = minetest.registered_nodes[node.name]
    if not def then
        return false
    end
    return (not def.walkable) or def.buildable_to
end

local function has_spawn_headroom(pos)
    for offset = 0, SPAWN_HEADROOM - 1 do
        if not is_clear_spawn_node({x = pos.x, y = pos.y + offset, z = pos.z}) then
            return false
        end
    end
    return true
end

local function is_solid_ground(pos)
    local node = get_node_safe(pos)
    if not node or node.name == "ignore" then
        return false
    end
    if minetest.get_item_group(node.name, "liquid") > 0 then
        return false
    end
    local def = minetest.registered_nodes[node.name]
    if not def or def.walkable ~= true then
        return false
    end
    local groups = def.groups or {}
    if groups.tree or groups.leaves or groups.fence or groups.wall or groups.door then
        return false
    end
    return true
end

local function get_surface_search_top(origin)
    local top_y = origin.y + SPAWN_SEARCH_DEPTH
    if minetest.get_spawn_level then
        local suggested = minetest.get_spawn_level(origin.x, origin.z)
        if type(suggested) == "number" then
            top_y = math.max(top_y, math.floor(suggested + (SPAWN_SEARCH_DEPTH / 2)))
        end
    end
    return top_y
end

local function load_spawn_area(origin, top_y)
    if not minetest.load_area then
        return
    end
    minetest.load_area(
        {
            x = origin.x - SPAWN_SEARCH_RADIUS,
            y = origin.y - SPAWN_SEARCH_DEPTH - 1,
            z = origin.z - SPAWN_SEARCH_RADIUS,
        },
        {
            x = origin.x + SPAWN_SEARCH_RADIUS,
            y = top_y + SPAWN_HEADROOM,
            z = origin.z + SPAWN_SEARCH_RADIUS,
        }
    )
end

local function find_surface_pos(base_pos)
    local origin = round_pos(base_pos)
    local top_y = get_surface_search_top(origin)
    local min_y = origin.y - SPAWN_SEARCH_DEPTH

    load_spawn_area(origin, top_y)

    for radius = 0, SPAWN_SEARCH_RADIUS do
        for dx = -radius, radius do
            for dz = -radius, radius do
                if radius == 0 or math.abs(dx) == radius or math.abs(dz) == radius then
                    local x = origin.x + dx
                    local z = origin.z + dz
                    for y = top_y, min_y, -1 do
                        local check_pos = {x = x, y = y, z = z}
                        if has_spawn_headroom(check_pos)
                            and is_solid_ground({x = x, y = y - 1, z = z}) then
                            return check_pos
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function adopt_population_slot_identities(state, snapshot)
    local changed = false
    for index = 1, #INITIAL_JOBS do
        if state.slots[index] == true
                and (not state.slot_ids[index] or state.slot_ids[index] == false) then
            local candidate_id = nil
            local candidate_record = nil
            local ambiguous = false
            for identity, record in pairs(snapshot or {}) do
                if record.owner_name == state.owner_name and record.job_name == INITIAL_JOBS[index] then
                    if candidate_id then
                        ambiguous = true
                        break
                    end
                    candidate_id = identity
                    candidate_record = record
                end
            end
            if candidate_id and not ambiguous and spawn_state.mark_spawned(
                    state,
                    index,
                    candidate_id,
                    candidate_record and candidate_record.last_pos or nil
                ) then
                changed = true
            end
        end
    end
    return changed
end

local function reconcile_loaded_initial_entities(state)
    local loaded = {}
    local entities = {}
    for _, entity in pairs(minetest.luaentities or {}) do
        local identity = initial_entity_id(entity)
        if identity and entity.name and working_villages.is_villager(entity.name) then
            loaded[identity] = true
            entities[#entities + 1] = entity
        end
    end

    for _, entity in ipairs(entities) do
        local index = spawn_state.find_slot_by_id(state, initial_entity_id(entity))
        if index then
            bind_initial_entity(state, index, entity)
        end
    end

    for _, entity in ipairs(entities) do
        local index = valid_initial_slot(entity.initial_spawn_slot)
        if index and not spawn_state.find_slot_by_id(state, initial_entity_id(entity)) then
            bind_initial_entity(state, index, entity)
        end
    end

    for index = 1, #INITIAL_JOBS do
        if state.slots[index] == true
                and (not state.slot_ids[index] or state.slot_ids[index] == false) then
            local candidate = nil
            local ambiguous = false
            for _, entity in ipairs(entities) do
                if entity_matches_legacy_slot(entity, state, index) then
                    if candidate then
                        ambiguous = true
                        break
                    end
                    candidate = entity
                end
            end
            if candidate and not ambiguous then
                bind_initial_entity(state, index, candidate)
            end
        end
    end
    return loaded
end

local function collect_initial_reconcile_targets(state, snapshot)
    local targets = {}
    local seen = {}
    local verifiable_slots = {}
    local function add_target(pos, slot_index)
        if type(pos) ~= "table" or type(pos.x) ~= "number"
                or type(pos.y) ~= "number" or type(pos.z) ~= "number" then
            return
        end
        local rounded = round_pos(pos)
        local key = rounded.x .. ":" .. rounded.y .. ":" .. rounded.z
        if not seen[key] then
            seen[key] = true
            targets[#targets + 1] = rounded
        end
        if slot_index then
            verifiable_slots[slot_index] = true
        end
    end

    add_target(state.anchor_pos)
    for index = 1, #INITIAL_JOBS do
        if state.slots[index] == true then
            add_target(state.slot_positions and state.slot_positions[index], index)
            local identity = state.slot_ids and state.slot_ids[index] or nil
            local record = identity and snapshot and snapshot[identity] or nil
            add_target(record and record.last_pos or nil, index)
            if not identity or identity == false then
                for _, legacy_record in pairs(snapshot or {}) do
                    if legacy_record.owner_name == state.owner_name
                            and legacy_record.job_name == INITIAL_JOBS[index] then
                        add_target(legacy_record.last_pos, index)
                    end
                end
            end
        end
    end
    return targets, verifiable_slots
end

local function emerge_initial_reconcile_targets(targets, callback)
    if #targets == 0 then
        callback(false)
        return
    end
    local pending = #targets
    local failed = false
    local completion_scheduled = false
    local forced_targets = {}
    local function release_forceloads()
        if not minetest.forceload_free_block then
            return
        end
        for _, target in ipairs(forced_targets) do
            minetest.forceload_free_block(target, true)
        end
        forced_targets = {}
    end
    local function finish_emergence()
        if completion_scheduled then
            return
        end
        completion_scheduled = true
        if not minetest.forceload_block then
            failed = true
        else
            for _, target in ipairs(targets) do
                local ok, held = pcall(minetest.forceload_block, target, true)
                if not ok or held == false then
                    failed = true
                    break
                end
                forced_targets[#forced_targets + 1] = target
            end
        end
        minetest.after(INITIAL_RECONCILE_SETTLE_DELAY, function()
            callback(not failed, release_forceloads)
        end)
    end

    if not minetest.emerge_area then
        for _, target in ipairs(targets) do
            local ok = pcall(minetest.load_area, target, target)
            failed = failed or not ok
        end
        finish_emergence()
        return
    end

    for _, target in ipairs(targets) do
        local completed = false
        local ok = pcall(minetest.emerge_area, target, target, function(_, action, remaining)
            if action == minetest.EMERGE_CANCELLED or action == minetest.EMERGE_ERRORED then
                failed = true
            end
            if not completed and (tonumber(remaining) or 0) == 0 then
                completed = true
                pending = pending - 1
                if pending == 0 then
                    finish_emergence()
                end
            end
        end)
        if not ok and not completed then
            failed = true
            completed = true
            pending = pending - 1
        end
    end
    if pending == 0 then
        finish_emergence()
    end
end

local function reconcile_initial_spawn_state(callback)
    if initial_spawn_reconcile_in_progress then
        callback(false)
        return
    end
    local state = load_initial_spawn_state()
    if spawn_state.count_spawned(state) == 0 then
        callback(true)
        return
    end
    initial_spawn_reconcile_in_progress = true
    local snapshot = working_villages.population and working_villages.population.snapshot() or {}
    if adopt_population_slot_identities(state, snapshot) then
        state = save_initial_spawn_state(state)
    end
    local targets, verifiable_slots = collect_initial_reconcile_targets(state, snapshot)
    emerge_initial_reconcile_targets(targets, function(emerged, release_forceloads)
        local finished = false
        local function finish(result)
            if finished then
                return
            end
            finished = true
            if release_forceloads then
                release_forceloads()
            end
            initial_spawn_reconcile_in_progress = false
            callback(result)
        end
        if not emerged then
            log.warning("Initial villager reconciliation postponed: emergence failed")
            finish(false)
            return
        end
        local function inspect_pass(attempt)
            local current = load_initial_spawn_state()
            local current_snapshot = working_villages.population
                and working_villages.population.snapshot() or {}
            adopt_population_slot_identities(current, current_snapshot)
            local loaded = reconcile_loaded_initial_entities(current)
            save_initial_spawn_state(current)
            local missing = {}
            for index = 1, #INITIAL_JOBS do
                local identity = current.slot_ids[index]
                if current.slots[index] == true and type(identity) == "string"
                        and identity ~= "" and not loaded[identity] then
                    missing[#missing + 1] = index
                end
            end
            if #missing == 0 then
                finish(true)
                return
            end
            if attempt < INITIAL_RECONCILE_PASSES then
                minetest.after(INITIAL_RECONCILE_SETTLE_DELAY, function()
                    inspect_pass(attempt + 1)
                end)
                return
            end

            local released = 0
            local unresolved = 0
            for _, index in ipairs(missing) do
                local identity = current.slot_ids[index]
                if verifiable_slots[index]
                        and spawn_state.release_slot(current, index, identity) then
                    released = released + 1
                    if working_villages.population then
                        working_villages.population.unregister(identity)
                    end
                    log.action(
                        "Initial villager slot %d reconciled as deleted after emergence: %s",
                        index,
                        identity
                    )
                else
                    unresolved = unresolved + 1
                end
            end
            save_initial_spawn_state(current)
            if unresolved > 0 then
                log.warning(
                    "Initial villager reconciliation kept %d unverified slot(s) occupied",
                    unresolved
                )
            end
            finish(released > 0 or unresolved == 0)
        end
        inspect_pass(1)
    end)
end

-- Initial spawn of 5 NPCs at world spawn
-- This function spawns a group of 5 villagers near the world spawn point
local function initial_spawn_group(opts)
    opts = opts or {}
    local force = opts.force == true
    local announce = opts.announce == true

    if not force and not spawn_enabled then
        log.action("Initial villager spawn disabled by setting, skipping")
        return false
    end
    
    -- Check if we've already done the initial spawn
    if not force and initial_spawn_completed() then
        log.action("Initial villager spawn already completed, skipping")
        return false
    end

    local state = force and spawn_state.create(#INITIAL_JOBS) or load_initial_spawn_state()
    local owner_name = resolve_initial_spawn_owner(opts, state)
    if not owner_name then
        log.action("Initial villager spawn postponed: no village owner is available")
        return false
    end

    local spawn_opts = opts
    if not force and state.anchor_pos then
        spawn_opts = {}
        for key, value in pairs(opts) do
            spawn_opts[key] = value
        end
        spawn_opts.anchor_pos = state.anchor_pos
    end

    local spawn_point, spawn_origin = resolve_initial_spawn_origin(spawn_opts)
    if not spawn_point then
        log.action("Initial villager spawn postponed: %s", spawn_origin or "spawn origin unresolved")
        return false
    end
    log.action("Using initial spawn origin from %s: %s", spawn_origin or "unknown", minetest.pos_to_string(spawn_point, 0))

    local ground_pos = find_surface_pos(spawn_point)
    if ground_pos then
        spawn_point = ground_pos
        log.action("Found ground for initial spawn at y=%d", spawn_point.y)
    else
        log.warning("Could not find suitable surface near spawn, aborting initial villager spawn")
        return false
    end

    if working_villages.village_registry then
        local village, registry_error = working_villages.village_registry.ensure(owner_name, {
            center = round_pos(spawn_point),
            radius = population_radius,
        })
        if not village then
            log.warning("Village registry could not be initialized for %s: %s",
                owner_name, tostring(registry_error))
        end
    end

    if not force then
        state.owner_name = owner_name
        state.anchor_pos = round_pos(spawn_point)
        state = save_initial_spawn_state(state)
    end
    local current_population = count_village_population(spawn_point, owner_name)
    local available_slots = spawn_state.available_population_slots(current_population, population_limit)
    local required_slots = force and #INITIAL_JOBS or (#INITIAL_JOBS - spawn_state.count_spawned(state))
    if available_slots < required_slots then
        log.warning(
            "Villager spawn blocked by population limit: current=%d limit=%d required=%d",
            current_population,
            population_limit,
            required_slots
        )
        return false
    end

    local spawned_count = 0
    
    -- Spawn 5 villagers in a small area around spawn point
    for i = 1, 5 do
        if force or not state.slots[i] then
            -- Create positions in a circle pattern around spawn
            local angle = (i - 1) * (2 * math.pi / 5)
            local offset_x = math.cos(angle) * SPAWN_RADIUS
            local offset_z = math.sin(angle) * SPAWN_RADIUS

            local target_pos = {
                x = spawn_point.x + offset_x,
                y = spawn_point.y,
                z = spawn_point.z + offset_z
            }
            local spawn_pos = find_surface_pos(target_pos)

            -- Try to spawn at this position
            local spawned, entity = false, nil
            if spawn_pos then
                spawned, entity = spawn_villager_at(
                    spawn_pos,
                    INITIAL_JOBS[i],
                    owner_name,
                    not force and i or nil
                )
            end
            if spawned and entity then
                local recorded = force or spawn_state.mark_spawned(
                    state,
                    i,
                    entity.inventory_name,
                    entity.object and entity.object:get_pos() or spawn_pos
                )
                if recorded then
                    spawned_count = spawned_count + 1
                    if not force then
                        state = save_initial_spawn_state(state)
                    end
                else
                    log.warning("Refusing untracked initial villager for slot %d", i)
                    if entity.object then
                        entity.object:remove()
                    end
                end
            else
                log.warning("Failed to spawn villager %d near %s", i, minetest.pos_to_string(target_pos, 0))
            end
        end
    end
    
    if spawned_count > 0 and working_villages.activate_village_coordination then
        local result = working_villages.activate_village_coordination(owner_name)
        if result then
            log.action(
                "Spawn village coordination activated: focus=%s stage=%s nudged=%d",
                result.control and result.control.focus or "balanced",
                result.stage or "build",
                result.nudged or 0
            )
        end
    end

    if not force then
        state = save_initial_spawn_state(state)
    end
    local total_spawned = force and spawned_count or spawn_state.count_spawned(state)
    local completed = force and spawned_count == #INITIAL_JOBS or state.completed
    log.action("Initial villager spawn progress: %d/%d slots completed", total_spawned, #INITIAL_JOBS)
    if announce and spawned_count > 0 then
        minetest.chat_send_all(("[working_villages] %d/%d villageois ont spawn au spawn."):format(spawned_count, 5))
    end
    return completed
end

local function attempt_initial_spawn(opts, source)
    opts = opts or {}
    if initial_spawn_in_progress then
        return nil
    end
    if not opts.force then
        if not spawn_enabled or initial_spawn_completed() then
            return nil
        end
    end

    initial_spawn_in_progress = true
    local ok = initial_spawn_group(opts)
    initial_spawn_in_progress = false

    if ok then
        initial_spawn_retry_count = 0
        initial_spawn_retry_scheduled = false
        return true
    end

    if not opts.force and spawn_enabled and not initial_spawn_completed() then
        log.action("Initial villager spawn attempt did not succeed yet (%s).", source or "unknown")
    end
    return false
end

local function schedule_initial_spawn_retry(delay, source, allow_completed)
    if initial_spawn_retry_scheduled or not spawn_enabled
            or (not allow_completed and initial_spawn_completed()) then
        return
    end
    if initial_spawn_retry_count >= INITIAL_SPAWN_MAX_RETRIES then
        return
    end
    initial_spawn_retry_scheduled = true
    minetest.after(delay or INITIAL_SPAWN_RETRY_DELAY, function()
        initial_spawn_retry_scheduled = false
        if not spawn_enabled or (not allow_completed and initial_spawn_completed()) then
            return
        end
        initial_spawn_retry_count = initial_spawn_retry_count + 1
        log.action(
            "Retrying initial villager spawn (%d/%d) after %s",
            initial_spawn_retry_count,
            INITIAL_SPAWN_MAX_RETRIES,
            source or "previous failure"
        )
        if request_initial_spawn then
            request_initial_spawn({announce = false}, 0, "retry")
        end
    end)
end

request_initial_spawn = function(opts, delay, source)
    minetest.after(delay or 0, function()
        local function run_attempt()
            local ok = attempt_initial_spawn(opts, source)
            if ok == false and not (opts and opts.force) and not initial_spawn_completed() then
                schedule_initial_spawn_retry(INITIAL_SPAWN_RETRY_DELAY, source, false)
            end
        end
        if opts and opts.force then
            run_attempt()
            return
        end
        reconcile_initial_spawn_state(function(safe_to_spawn)
            if not safe_to_spawn then
                schedule_initial_spawn_retry(INITIAL_SPAWN_RETRY_DELAY, source, true)
                return
            end
            run_attempt()
        end)
    end)
end

-- Schedule the initial spawn after a short delay to ensure world is loaded
request_initial_spawn({announce = true}, INITIAL_SPAWN_DELAY, "server start")

minetest.register_on_joinplayer(function(player)
    if not player or not player:is_player() then
        return
    end
    local join_pos = player:get_pos()
    if join_pos and not initial_spawn_completed() then
        remember_initial_spawn_anchor(join_pos, "player join")
    end
    if not spawn_enabled or initial_spawn_completed() then
        return
    end
    request_initial_spawn({
        announce = true,
        anchor_pos = join_pos,
        owner_name = player:get_player_name(),
    }, JOIN_SPAWN_DELAY, "player join")
end)

working_villages.require("jobs/plant_collector")

local herb_names = {}
for name,_ in pairs(working_villages.herbs.names) do
    herb_names[#herb_names + 1] = name
end
for name,_ in pairs(working_villages.herbs.groups) do
    herb_names[#herb_names + 1] = "group:"..name
end

if spawn_enabled and passive_spawn_enabled then
    minetest.register_abm({
        label = "Spawn herb collector",
        nodenames = herb_names,
        neighbors = "air",
        interval = 60,
        chance = 2048,
        catch_up = false,
        action = spawner("working_villages:job_herbcollector"),
    })

    minetest.register_abm({
        label = "Spawn woodcutter",
        nodenames = "group:tree",
        neighbors = "air",
        interval = 60,
        chance = 2048,
        catch_up = false,
        action = spawner("working_villages:job_woodcutter"),
    })
end

minetest.register_chatcommand("wv_spawn5", {
    description = "Force le spawn manuel de 5 villageois pres de vous.",
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if not player then
            return false, "Joueur introuvable."
        end
        if not player_can_force_manual_spawn(name) then
            return false, "Il faut porter un sceptre de commande pour utiliser cette commande."
        end
        local remaining = get_manual_spawn_cooldown_remaining(name)
        if remaining > 0 then
            return false, ("Patiente %ds avant de relancer le spawn."):format(math.ceil(remaining))
        end
        local anchor_pos = player and player:get_pos() or nil
        local ok = attempt_initial_spawn({
            force = true,
            announce = true,
            anchor_pos = anchor_pos,
            owner_name = name,
        }, "chat command")
        if ok then
            record_manual_spawn_use(name)
            return true, "Spawn manuel lance pres de vous."
        end
        return false, "Echec du spawn (verifie l'espace libre autour de vous)."
    end,
})

minetest.register_chatcommand("wv_storage_show", {
	description = "Affiche la position du coffre partage.",
	func = function(name)
		local pos = working_villages.communication and working_villages.communication.get_shared_storage_pos and
			working_villages.communication.get_shared_storage_pos(name) or nil
		if not pos then
			return false, "Aucun coffre partage defini."
		end
		return true, "Coffre partage: " .. minetest.pos_to_string(pos, 0)
	end,
})

local function player_has_owned_loaded_villager(name)
    for _, lua in pairs(minetest.luaentities or {}) do
        if lua and lua.name and working_villages.is_villager(lua.name)
                and lua.owner_name == name then
            return true
        end
    end
    return false
end

local POPULATION_GROWTH_KEY = "population_growth_v1"

local function load_population_growth_state()
    local encoded = spawn_storage:get_string(POPULATION_GROWTH_KEY)
    local decoded = encoded ~= "" and minetest.deserialize(encoded) or nil
    return type(decoded) == "table" and decoded or {}
end

local population_growth_state = load_population_growth_state()

local function save_population_growth_state()
    spawn_storage:set_string(POPULATION_GROWTH_KEY, minetest.serialize(population_growth_state))
end

local function count_food(inv)
    local total = 0
    if not inv then
        return total
    end
    for _, stack in ipairs(inv:get_list("main") or {}) do
        if not stack:is_empty() and minetest.get_item_group(stack:get_name(), "food") > 0 then
            total = total + stack:get_count()
        end
    end
    return total
end

local function consume_food(inv, requested)
    if count_food(inv) < requested then
        return false
    end
    local remaining = requested
    for index, stack in ipairs(inv:get_list("main") or {}) do
        if remaining <= 0 then
            break
        end
        if not stack:is_empty() and minetest.get_item_group(stack:get_name(), "food") > 0 then
            local amount = math.min(remaining, stack:get_count())
            stack:take_item(amount)
            inv:set_stack("main", index, stack)
            remaining = remaining - amount
        end
    end
    return remaining == 0
end

local function find_free_home(owner_name, center)
    local minp = vector.subtract(center, population_radius)
    local maxp = vector.add(center, population_radius)
    local markers = minetest.find_nodes_in_area(minp, maxp, {"working_villages:building_marker"})
    table.sort(markers, function(a, b)
        return vector.distance(center, a) < vector.distance(center, b)
    end)
    for _, marker_pos in ipairs(markers) do
        if working_villages.is_home_available and
                working_villages.is_home_available(marker_pos, owner_name, nil) then
            return marker_pos
        end
    end
    return nil
end

local function attempt_population_growth(owner_name, anchor)
    if not population_growth_enabled or not owner_name or owner_name == "" or not anchor then
        return false
    end
    local now = os.time()
    local last = tonumber(population_growth_state[owner_name]) or 0
    if now - last < population_growth_interval then
        return false
    end
    local center = working_villages.get_shared_storage_pos and
        working_villages.get_shared_storage_pos(owner_name) or anchor
    if not center or count_village_population(center, owner_name) >= population_limit then
        return false
    end
    local storage_pos = working_villages.get_shared_storage_pos and
        working_villages.get_shared_storage_pos(owner_name) or nil
    if not (storage_pos and working_villages.is_chest_pos and working_villages.is_chest_pos(storage_pos)) then
        return false
    end
    local chest_inv = minetest.get_meta(storage_pos):get_inventory()
    if count_food(chest_inv) < population_growth_food_cost then
        return false
    end
    local home_marker = find_free_home(owner_name, center)
    if not home_marker then
        return false
    end
    local home_meta = minetest.get_meta(home_marker)
    local access_pos = minetest.string_to_pos(home_meta:get_string("door"))
    if not access_pos then
        return false
    end
    local spawn_pos = find_surface_pos(access_pos) or vector.round(access_pos)
    local spawned, entity = spawn_villager_at(
        spawn_pos,
        working_villages.LEARNER_JOB_NAME or "working_villages:job_apprenant",
        owner_name
    )
    if not spawned or not entity then
        return false
    end
    local assigned = entity.set_home and entity:set_home(home_marker)
    if not assigned or not consume_food(chest_inv, population_growth_food_cost) then
        if entity.remove_home then
            entity:remove_home()
        end
        if entity.object then
            entity.object:remove()
        end
        return false
    end
    population_growth_state[owner_name] = now
    save_population_growth_state()
    entity:set_state_info("J'arrive comme apprenti dans un village qui peut m'accueillir.")
    entity:set_displayed_action("decouvre le village")
    if entity.notify_owner_event then
        entity:notify_owner_event(
            ("Un nouvel apprenti rejoint le village (%d nourriture consommee)."):format(population_growth_food_cost),
            "population:growth",
            population_growth_interval,
            "important"
        )
    end
    return true
end

if population_growth_enabled then
    local growth_elapsed = 0
    minetest.register_globalstep(function(dtime)
        growth_elapsed = growth_elapsed + (tonumber(dtime) or 0)
        if growth_elapsed < 30 then
            return
        end
        growth_elapsed = 0
        local owners = {}
        for _, lua in pairs(minetest.luaentities or {}) do
            if lua and lua.name and working_villages.is_villager(lua.name)
                    and lua.owner_name and lua.owner_name ~= ""
                    and lua.object and lua.object:get_pos() and not owners[lua.owner_name] then
                owners[lua.owner_name] = lua.object:get_pos()
            end
        end
        for owner_name, anchor in pairs(owners) do
            attempt_population_growth(owner_name, anchor)
        end
    end)
end

local function player_can_configure_storage(name)
    if minetest.check_player_privs(name, {server = true})
            or minetest.check_player_privs(name, {protection_bypass = true}) then
        return true
    end
    if working_villages.get_shared_storage_owner
            and working_villages.get_shared_storage_owner(name) == name then
        return true
    end
    return player_has_owned_loaded_villager(name)
end

minetest.register_chatcommand("wv_storage_set", {
    params = "[x,y,z|here|clear]",
    description = "Redefinit le coffre partage (par defaut: coffre le plus proche de vous).",
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then
            return false, "Joueur introuvable."
        end
		if not player_can_configure_storage(name) then
			return false, "Vous devez posseder un villageois charge pour configurer son coffre commun."
		end

        param = (param or ""):match("^%s*(.-)%s*$")
        if param == "clear" then
            if not working_villages.clear_shared_storage_pos then
                return false, "API de coffre partage indisponible."
            end
            if not working_villages.clear_shared_storage_pos(name) then
				return false, "Aucun coffre commun ne vous appartient."
			end
            return true, "Coffre partage reinitialise."
        end

        local pos
        if param == "" or param == "here" then
            pos = find_nearest_storage_chest(vector.round(player:get_pos()), 8)
            if not pos then
                return false, "Aucun coffre valide trouve a proximite. Approchez-vous du coffre cible ou utilisez /wv_storage_set x,y,z"
            end
        else
            pos = minetest.string_to_pos(param)
            if not pos then
                return false, "Usage: /wv_storage_set [x,y,z|here]"
            end
            pos = vector.round(pos)
        end

        if not (working_villages.is_chest_pos and working_villages.is_chest_pos(pos)) then
            return false, "La position cible n'est pas un coffre valide."
        end
		if minetest.is_protected(pos, name) then
			return false, "Ce coffre est protege contre vos modifications."
		end

        if not working_villages.set_shared_storage_pos then
            return false, "API de coffre partage indisponible."
        end

		if not working_villages.set_shared_storage_pos(pos, name, player) then
			return false, "Ce coffre appartient deja a un autre village."
		end
        return true, "Nouveau coffre partage: " .. minetest.pos_to_string(pos, 0)
    end,
})

minetest.register_chatcommand("wv_storage_clear", {
    description = "Reinitialise le coffre partage courant.",
    func = function(name)
        if not working_villages.clear_shared_storage_pos then
            return false, "API de coffre partage indisponible."
        end
		if not player_can_configure_storage(name) then
			return false, "Vous ne pouvez pas reinitialiser ce coffre commun."
		end
		if not working_villages.clear_shared_storage_pos(name) then
			return false, "Aucun coffre commun ne vous appartient."
		end
        return true, "Coffre partage reinitialise."
    end,
})
