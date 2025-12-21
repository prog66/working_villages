--[[
  Common job patterns and utilities for villager jobs.
  
  This module provides reusable patterns that are common across multiple jobs,
  reducing code duplication and ensuring consistent behavior.
]]--

local job_patterns = {}

local func = working_villages.require("jobs/util")
local blueprints = working_villages.blueprints

--[[
  Standard chest interaction handlers.
  
  These functions can be used by most jobs that need to interact with chests
  to store collected items or retrieve tools/materials.
]]--
job_patterns.chest_handlers = {}

--[[
  Creates a standard put_func for chest interactions.
  
  Items matching the filter will NOT be stored in chests (kept in inventory).
  All other items will be stored.
  
  @param filter_groups table - List of item groups to keep (e.g., {"axe", "food"})
  @return function - put_func compatible with handle_chest
  
  @usage
  local put_func = job_patterns.chest_handlers.create_put_func({"axe", "pickaxe"})
]]--
function job_patterns.chest_handlers.create_put_func(filter_groups)
  return function(_, stack)
    local name = stack:get_name()
    for _, group in ipairs(filter_groups) do
      if minetest.get_item_group(name, group) ~= 0 then
        return false  -- Keep in inventory
      end
    end
    return true  -- Store in chest
  end
end

--[[
  Creates a standard take_func that is the inverse of put_func.
  
  @param filter_groups table - List of item groups to take from chests
  @return function - take_func compatible with handle_chest
]]--
function job_patterns.chest_handlers.create_take_func(filter_groups)
  local put_func = job_patterns.chest_handlers.create_put_func(filter_groups)
  return function(self, stack)
    return not put_func(self, stack)
  end
end

--[[
  Standard search and navigation pattern.
  
  This is the most common pattern: search for a target, navigate to it, perform action.
  Used by most gathering/working jobs.
]]--
job_patterns.search_and_act = {}

--[[
  Executes a standard search-navigate-act cycle.
  
  @param self table - Villager object
  @param options table - Configuration options:
    - timer_name: string - Name for the timer (e.g., "farmer:search")
    - timer_threshold: number - How often to search (in ticks, default 20)
    - find_func: function(pos) -> boolean - Function to find targets
    - search_range: table - {x, y, z} range to search
    - action_func: function(self, target_pos) - Action to perform at target
    - no_target_message: string - Message when no target found
    - working_message: string - Message when target found and working
  
  @return boolean - true if action was performed, false otherwise
  
  @usage
  job_patterns.search_and_act.execute(self, {
    timer_name = "miner:search",
    find_func = find_stone,
    search_range = {x=10, y=5, z=10},
    action_func = function(self, pos) self:mine_block(pos) end,
    no_target_message = "Looking for stone to mine.",
    working_message = "Mining stone."
  })
]]--
function job_patterns.search_and_act.execute(self, options)
  -- Set defaults
  options.timer_threshold = options.timer_threshold or 20
  
  -- Count timer
  self:count_timer(options.timer_name)
  
  -- Check if it's time to search
  if not self:timer_exceeded(options.timer_name, options.timer_threshold) then
    return false
  end
  
  -- Search for target
  local target = func.search_surrounding(
    self.object:get_pos(),
    options.find_func,
    options.search_range
  )
  
  if target == nil then
    if options.no_target_message then
      self:set_state_info(options.no_target_message)
    end
    return false
  end
  
  -- Target found
  if options.working_message then
    self:set_state_info(options.working_message)
  end
  
  -- Navigate to target
  local destination = func.find_adjacent_clear(target)
  if destination then
    destination = func.find_ground_below(destination)
    if destination then
      self:go_to(destination)
    end
  end
  
  -- Perform action if provided
  if options.action_func then
    options.action_func(self, target)
  end
  
  return true
end

--[[
  Experience gain helper.
  
  Awards experience to a villager and optionally displays a message.
]]--
job_patterns.experience = {}

--[[
  Awards experience and displays an optional message.
  
  @param self table - Villager object
  @param amount number - Amount of experience to award
  @param message string - Optional message to display
  
  @usage
  job_patterns.experience.award(self, 5, "Building completed!")
]]--
function job_patterns.experience.award(self, amount, message)
  local inv_name = self:get_inventory_name()
  blueprints.add_experience(inv_name, amount)
  
  if message then
    self:set_state_info(message)
  end
end

--[[
  Standard night handling patterns.
  
  Most jobs need villagers to return home at night.
]]--
job_patterns.time_management = {}

--[[
  Standard job initialization (handles common patterns at start of jobfunc).
  
  @param self table - Villager object
  @param options table - Options:
    - use_chest: boolean - Whether to handle chest interactions (default true)
    - put_func: function - Custom put function for chests
    - take_func: function - Custom take function for chests
    - use_job_pos: boolean - Whether to handle job position (default true)
  
  @usage
  job_patterns.time_management.standard_init(self, {
    put_func = my_put_func,
    take_func = my_take_func
  })
]]--
function job_patterns.time_management.standard_init(self, options)
  options = options or {}
  
  -- Always handle night
  self:handle_night()
  
  -- Handle chest if requested
  if options.use_chest ~= false then
    if options.put_func and options.take_func then
      self:handle_chest(options.take_func, options.put_func)
    end
  end
  
  -- Handle job position if requested
  if options.use_job_pos ~= false then
    self:handle_job_pos()
  end
  
  -- Handle obstacles
  self:handle_obstacles()
end

--[[
  Protection and safety checks.
]]--
job_patterns.safety = {}

--[[
  Checks if a position is safe to interact with.
  
  Checks:
  - Not in a protected area
  - Not in the failed position list
  - Optionally: custom safety checks
  
  @param pos table - Position to check
  @param extra_checks function - Optional extra safety checks function(pos) -> boolean
  @return boolean - true if safe, false otherwise
  
  @usage
  if job_patterns.safety.is_safe(pos) then
    -- Perform action
  end
]]--
function job_patterns.safety.is_safe(pos, extra_checks)
  -- Check protection
  if minetest.is_protected(pos, "") then
    return false
  end
  
  -- Check failed positions
  if working_villages.failed_pos_test(pos) then
    return false
  end
  
  -- Custom checks
  if extra_checks and not extra_checks(pos) then
    return false
  end
  
  return true
end

--[[
  Item collection helpers.
]]--
job_patterns.collection = {}

--[[
  Collects items around the villager matching a condition.
  
  @param self table - Villager object
  @param condition function - Function to check if item should be collected
  @param range table - Search range {x, y, z}
  @param options table - Optional configuration:
    - timer_name: string - Timer name
    - timer_threshold: number - Timer threshold (default: 20)
  
  @return boolean - true if items were collected
  
  @usage
  job_patterns.collection.collect_items(self, 
    function(item) return item:get_name():find("ore") end,
    {x=5, y=2, z=5},
    {timer_name = "collect", timer_threshold = 15}
  )
]]--
function job_patterns.collection.collect_items(self, condition, range, options)
  options = options or {}
  
  if options.timer_name then
    self:count_timer(options.timer_name)
    if not self:timer_exceeded(options.timer_name, options.timer_threshold or 20) then
      return false
    end
  end
  
  return self:collect_nearest_item_by_condition(condition, range)
end

--[[
  Tool management helpers.
]]--
job_patterns.tools = {}

--[[
  Checks if villager has a tool from a specific group.
  
  @param self table - Villager object
  @param tool_group string - Tool group name (e.g., "pickaxe", "axe")
  @return boolean - true if tool is in inventory
  
  @usage
  if not job_patterns.tools.has_tool(self, "pickaxe") then
    -- Request pickaxe
  end
]]--
function job_patterns.tools.has_tool(self, tool_group)
  local inv = self:get_inventory()
  local list = inv:get_list("main")
  
  for _, stack in ipairs(list) do
    if not stack:is_empty() then
      local name = stack:get_name()
      if minetest.get_item_group(name, tool_group) > 0 then
        return true
      end
    end
  end
  
  return false
end

--[[
  Finds a tool in the villager's inventory.
  
  @param self table - Villager object
  @param tool_group string - Tool group name
  @return ItemStack, number - Tool stack and index, or nil if not found
]]--
function job_patterns.tools.find_tool(self, tool_group)
  local inv = self:get_inventory()
  local list = inv:get_list("main")
  
  for i, stack in ipairs(list) do
    if not stack:is_empty() then
      local name = stack:get_name()
      if minetest.get_item_group(name, tool_group) > 0 then
        return stack, i
      end
    end
  end
  
  return nil, nil
end

return job_patterns
