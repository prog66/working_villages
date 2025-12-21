local func = working_villages.require("jobs/util")
local log = working_villages.require("log")

-- Track if initial spawn has been done
local spawn_storage = minetest.get_mod_storage()
local INITIAL_SPAWN_KEY = "initial_spawn_done"
local INITIAL_SPAWN_DELAY = 5  -- seconds to wait after server start

local function spawner(initial_job)
    return function(pos, _, _, active_object_count_wider)
               --  (pos, node, active_object_count, active_object_count_wider)
        if active_object_count_wider > 1 then return end
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
                local entity = new_villager:get_luaentity()
                entity.new_job = initial_job
                entity.owner_name = "working_villages:self_employed"
                entity:update_infotext()
                return
            end
        end
    end
end

-- Spawn a single villager at a specific position
local function spawn_villager_at(pos, job_name)
    local gender = {
        "working_villages:villager_male",
        "working_villages:villager_female",
    }
    local new_villager = minetest.add_entity(pos, gender[math.random(2)], "")
    if new_villager then
        local entity = new_villager:get_luaentity()
        if entity then
            entity.new_job = job_name or ""
            entity.owner_name = "working_villages:self_employed"
            entity:update_infotext()
            log.action("Spawned villager with job %s at %s", job_name or "none", minetest.pos_to_string(pos, 0))
            return true
        end
    end
    return false
end

-- Initial spawn of 5 NPCs at world spawn
-- This function spawns a group of 5 villagers near the world spawn point
local function initial_spawn_group()
    -- Double-check that spawning is enabled (spawn.lua is only loaded if enabled)
    if not working_villages.setting_enabled("spawn", false) then
        log.action("Initial villager spawn disabled by setting, skipping")
        return
    end
    
    -- Check if we've already done the initial spawn
    if spawn_storage:get(INITIAL_SPAWN_KEY) == "true" then
        log.action("Initial villager spawn already completed, skipping")
        return
    end

    -- Get the server's configured spawn point, or default to (0,0,0)
    local spawn_point = {x=0, y=0, z=0}
    local spawn_setting = minetest.settings:get("static_spawnpoint")
    if spawn_setting then
        local spawn_coords = minetest.string_to_pos(spawn_setting)
        if spawn_coords then
            spawn_point = spawn_coords
            log.action("Using configured spawn point: %s", minetest.pos_to_string(spawn_point, 0))
        end
    end
    
    -- Try to find a better spawn point on the ground
    -- Look for ground level near spawn
    local found_ground = false
    for y = spawn_point.y + 10, spawn_point.y - 10, -1 do
        local check_pos = {x=spawn_point.x, y=y, z=spawn_point.z}
        local node = minetest.get_node(check_pos)
        local node_below = minetest.get_node({x=spawn_point.x, y=y-1, z=spawn_point.z})
        local def_below = minetest.registered_nodes[node_below.name]
        
        if node.name == "air" and def_below and 
           (def_below.groups.soil or def_below.groups.stone or 
            def_below.walkable) then
            spawn_point = check_pos
            found_ground = true
            log.action("Found ground for initial spawn at y=%d", y)
            break
        end
    end
    
    if not found_ground then
        log.warning("Could not find suitable ground near spawn, will spawn at configured spawn point")
    end

    -- Define jobs for the initial group of 5 villagers
    local initial_jobs = {
        "working_villages:job_woodcutter",
        "working_villages:job_farmer",
        "working_villages:job_herbcollector",
        "working_villages:job_builder",
        "", -- One villager without a job initially
    }

    local spawned_count = 0
    
    -- Spawn 5 villagers in a small area around spawn point
    for i = 1, 5 do
        -- Create positions in a circle pattern around spawn
        local angle = (i - 1) * (2 * math.pi / 5)
        local radius = 3
        local offset_x = math.cos(angle) * radius
        local offset_z = math.sin(angle) * radius
        
        local spawn_pos = {
            x = spawn_point.x + offset_x,
            y = spawn_point.y,
            z = spawn_point.z + offset_z
        }
        
        -- Try to spawn at this position
        if spawn_villager_at(spawn_pos, initial_jobs[i]) then
            spawned_count = spawned_count + 1
        else
            log.warning("Failed to spawn villager %d at %s", i, minetest.pos_to_string(spawn_pos, 0))
        end
    end
    
    -- Mark initial spawn as complete
    spawn_storage:set_string(INITIAL_SPAWN_KEY, "true")
    log.action("Initial villager spawn completed: %d/%d villagers spawned", spawned_count, 5)
end

-- Schedule the initial spawn after a short delay to ensure world is loaded
minetest.after(INITIAL_SPAWN_DELAY, function()
    initial_spawn_group()
end)

working_villages.require("jobs/plant_collector")

local herb_names = {}
for name,_ in pairs(working_villages.herbs.names) do
    herb_names[#herb_names + 1] = name
end
for name,_ in pairs(working_villages.herbs.groups) do
    herb_names[#herb_names + 1] = "group:"..name
end

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

