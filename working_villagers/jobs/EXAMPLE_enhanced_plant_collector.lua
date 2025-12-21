--[[
  Example: Enhanced Plant Collector Job using AI Behavior System
  
  This file demonstrates how to use the new ai_behavior and job_patterns
  modules to create more intelligent and maintainable villager jobs.
  
  This is an example/template file showing best practices.
  It's not meant to replace the existing plant_collector job immediately,
  but to serve as a reference for future job development and refactoring.
]]--

local func = working_villages.require("jobs/util")
local job_patterns = working_villages.job_patterns
local ai_behavior = working_villages.ai_behavior
local compat = working_villages.voxelibre_compat

--[[
  Configuration for the enhanced plant collector job.
]]--
local config = {
  searching_range = {x = 10, y = 5, z = 10},
  search_timer_threshold = 20,
  memory_max_age = 600,  -- 10 minutes
}

--[[
  Plant identification function.
  
  Uses compatibility layer to identify collectible plants.
]]--
local function is_collectible_plant(pos)
  local node = minetest.get_node(pos)
  local name = node.name
  
  -- Check protection and failed positions
  if not job_patterns.safety.is_safe(pos) then
    return false
  end
  
  -- Check if it's a plant using compatibility layer
  -- For now, check common plant groups
  if minetest.get_item_group(name, "flora") > 0 then
    return true
  end
  if minetest.get_item_group(name, "flower") > 0 then
    return true
  end
  if name:find("grass") and name ~= "default:grass_1" then
    return true
  end
  
  return false
end

--[[
  Chest interaction configuration.
  
  Keep tools, store collected plants.
]]--
local put_func = job_patterns.chest_handlers.create_put_func({"hoe"})
local take_func = job_patterns.chest_handlers.create_take_func({"hoe"})

--[[
  Enhanced plant collector job using AI behavior system.
]]--
working_villages.register_job("working_villages:job_plant_collector_enhanced", {
  description = "enhanced plant collector (working_villages)",
  long_description = "I collect various plants and flowers to produce dyes and materials. "..
    "I use intelligent decision-making to prioritize tasks and remember productive locations. "..
    "I work sustainably and avoid over-harvesting areas.",
  inventory_image = "default_paper.png^working_villages_plant_collector.png",
  
  jobfunc = function(self)
    -- Standard initialization using job patterns
    job_patterns.time_management.standard_init(self, {
      put_func = put_func,
      take_func = take_func,
    })
    
    -- Periodic memory cleanup
    if math.random(1, 100) == 1 then  -- 1% chance each tick
      ai_behavior.cleanup_memory(self)
    end
    
    -- Define available tasks with priorities
    local tasks = {
      -- Task 1: Return home at night (high priority)
      {
        name = "return_home",
        priority = ai_behavior.PRIORITY.HIGH,
        condition = function(s)
          local time = minetest.get_timeofday()
          return (time > 0.8 or time < 0.2) and s.home_pos ~= nil
        end,
        execute = function(s)
          s:set_state_info("Returning home for the night.")
          s:go_to(s.home_pos)
          return true
        end,
      },
      
      -- Task 2: Collect items on the ground
      {
        name = "collect_items",
        priority = ai_behavior.PRIORITY.NORMAL,
        condition = function(s)
          -- Always can attempt to collect
          return true
        end,
        execute = function(s)
          local collected = job_patterns.collection.collect_items(
            s,
            function(item)
              local name = item:get_name()
              -- Cache group lookups for efficiency
              local flora = minetest.get_item_group(name, "flora")
              local flower = minetest.get_item_group(name, "flower")
              return flora > 0 or flower > 0
            end,
            config.searching_range,
            {timer_name = "plant_collector:collect", timer_threshold = 10}
          )
          if collected then
            s:set_state_info("Collecting dropped plants.")
          end
          return collected
        end,
      },
      
      -- Task 3: Search for and harvest plants
      {
        name = "harvest_plants",
        priority = ai_behavior.PRIORITY.NORMAL,
        evaluate = function(s, base_priority)
          -- Increase priority if inventory has space
          local inv = s:get_inventory()
          local main_list = inv:get_list("main")
          local empty_slots = 0
          for _, stack in ipairs(main_list) do
            if stack:is_empty() then
              empty_slots = empty_slots + 1
            end
          end
          
          -- Higher priority with more space
          return base_priority + (empty_slots * 2)
        end,
        condition = function(s)
          -- Can always search for plants
          return true
        end,
        execute = function(s)
          -- Use the search_and_act pattern
          local success = job_patterns.search_and_act.execute(s, {
            timer_name = "plant_collector:search",
            timer_threshold = config.search_timer_threshold,
            find_func = is_collectible_plant,
            search_range = config.searching_range,
            no_target_message = "Looking for plants to collect nearby.",
            working_message = "Found plants to collect.",
            action_func = function(self, target_pos)
              -- Collect the plant
              local node = minetest.get_node(target_pos)
              minetest.node_dig(target_pos, node, self.object)
              
              -- Remember this location as productive
              ai_behavior.memory.remember_location(
                self,
                "plant_locations",
                target_pos,
                {plant_type = node.name}
              )
              
              -- Small experience gain
              job_patterns.experience.award(self, 1)
            end,
          })
          
          return success
        end,
      },
      
      -- Task 4: Revisit known productive locations
      {
        name = "check_memory",
        priority = ai_behavior.PRIORITY.LOW,
        condition = function(s)
          local remembered = ai_behavior.memory.recall_locations(
            s,
            "plant_locations",
            config.memory_max_age
          )
          return #remembered > 0
        end,
        evaluate = function(s, base_priority)
          -- Increase priority if we haven't found plants recently
          local state_duration = ai_behavior.state_machine.get_state_duration(s)
          if state_duration > 60 then  -- 60 seconds without finding plants
            return base_priority + 30
          end
          return base_priority
        end,
        execute = function(s)
          local remembered = ai_behavior.memory.recall_locations(
            s,
            "plant_locations",
            config.memory_max_age
          )
          
          if #remembered > 0 then
            -- Visit a random remembered location
            local location = remembered[math.random(1, #remembered)]
            s:set_state_info("Checking a previously productive location.")
            
            local destination = func.find_adjacent_clear(location.pos)
            if destination then
              destination = func.find_ground_below(destination)
              if destination then
                s:go_to(destination)
              end
            end
            
            return true
          end
          
          return false
        end,
      },
      
      -- Task 5: Store collected items in chest
      {
        name = "store_items",
        priority = ai_behavior.PRIORITY.NORMAL,
        evaluate = function(s, base_priority)
          -- Higher priority if inventory is full
          local inv = s:get_inventory()
          local main_list = inv:get_list("main")
          local full_slots = 0
          for _, stack in ipairs(main_list) do
            if not stack:is_empty() then
              full_slots = full_slots + 1
            end
          end
          
          -- Increase priority significantly when inventory is nearly full
          if full_slots >= 12 then  -- 12 out of 16 slots
            return ai_behavior.PRIORITY.HIGH
          end
          
          return base_priority
        end,
        condition = function(s)
          -- Timer-based chest access
          s:count_timer("plant_collector:chest")
          return s:timer_exceeded("plant_collector:chest", 40)
        end,
        execute = function(s)
          s:set_state_info("Looking for a chest to store items.")
          -- Chest handling is done in standard_init
          return true
        end,
      },
    }
    
    -- Select the best task based on current conditions
    local best_task = ai_behavior.task_priority.select_best_task(self, tasks)
    
    if best_task then
      -- Update state machine
      ai_behavior.state_machine.set_state(self, ai_behavior.STATES.WORKING)
      
      -- Execute the selected task
      best_task.execute(self)
    else
      -- No valid tasks available - idle
      ai_behavior.state_machine.set_state(self, ai_behavior.STATES.IDLE)
      self:set_state_info("Waiting for something to do.")
    end
    
    -- Optional: Debug state info
    if working_villages.setting_enabled("debug_ai", false) then
      local state = ai_behavior.state_machine.get_state(self)
      local duration = ai_behavior.state_machine.get_state_duration(self)
      minetest.chat_send_all(string.format(
        "[%s] State: %s (%.1fs), Task: %s",
        self.inventory_name,
        state,
        duration,
        best_task and best_task.name or "none"
      ))
    end
  end
})

--[[
  Benefits of this approach:
  
  1. Clear task separation: Each task is well-defined and independent
  2. Priority-based decision making: Villager intelligently chooses what to do
  3. Dynamic priority adjustment: Priorities change based on conditions
  4. Memory system: Remembers productive locations
  5. Reusable patterns: Uses job_patterns for common code
  6. Easy to extend: Add new tasks by adding to the tasks table
  7. Better maintainability: Logic is organized and documented
  8. State tracking: Can track what state the villager is in
  
  Future enhancements could include:
  - Collaborative plant collection with other villagers
  - Learning which areas are most productive
  - Seasonal behavior changes
  - Communication with other villagers about good locations
]]--
