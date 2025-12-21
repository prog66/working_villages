--[[
  AI Behavior System for villagers.
  
  This module provides an improved decision-making framework for villagers,
  allowing them to prioritize tasks based on various factors.
  
  Future enhancements will include:
  - Need-based decision making (hunger, rest, tools)
  - Task priority evaluation
  - Learning from experience
  - Memory of successful locations
]]--

local ai_behavior = {}

--[[
  Task priority system.
  
  Evaluates and selects the best task for a villager to perform
  based on current conditions and needs.
]]--
ai_behavior.task_priority = {}

-- Priority levels (higher = more urgent)
ai_behavior.PRIORITY = {
  CRITICAL = 100,  -- Must do immediately (e.g., danger response)
  URGENT = 75,     -- Should do soon (e.g., low health, broken tools)
  HIGH = 50,       -- Important tasks (e.g., job duties)
  NORMAL = 25,     -- Regular tasks
  LOW = 10,        -- Optional tasks (e.g., exploration)
}

--[[
  Task definition structure.
  
  A task is defined as:
  {
    name = "task_name",
    priority = number,  -- Base priority (can be modified by conditions)
    condition = function(self) -> boolean,  -- Can this task be performed?
    evaluate = function(self) -> number,    -- Calculate actual priority
    execute = function(self) -> boolean,    -- Perform the task
  }
]]--

--[[
  Evaluates a task's actual priority based on current conditions.
  
  @param self table - Villager object
  @param task table - Task definition
  @return number - Evaluated priority (0 if task cannot be performed)
]]--
function ai_behavior.task_priority.evaluate_task(self, task)
  -- Check if task can be performed
  if task.condition and not task.condition(self) then
    return 0
  end
  
  -- Get base priority
  local priority = task.priority or ai_behavior.PRIORITY.NORMAL
  
  -- Allow task to adjust its priority based on conditions
  if task.evaluate then
    priority = task.evaluate(self, priority)
  end
  
  return priority
end

--[[
  Selects the best task from a list of available tasks.
  
  @param self table - Villager object
  @param tasks table - List of task definitions
  @return table - Best task to perform, or nil if no valid tasks
]]--
function ai_behavior.task_priority.select_best_task(self, tasks)
  local best_task = nil
  local best_priority = 0
  
  for _, task in ipairs(tasks) do
    local priority = ai_behavior.task_priority.evaluate_task(self, task)
    if priority > best_priority then
      best_priority = priority
      best_task = task
    end
  end
  
  return best_task
end

--[[
  State machine for villager behavior.
  
  Manages transitions between different behavioral states.
]]--
ai_behavior.state_machine = {}

-- Common states
ai_behavior.STATES = {
  IDLE = "idle",
  WORKING = "working",
  TRAVELING = "traveling",
  RESTING = "resting",
  EMERGENCY = "emergency",
}

--[[
  Gets the current state of a villager.
  
  @param self table - Villager object
  @return string - Current state
]]--
function ai_behavior.state_machine.get_state(self)
  return self.ai_state or ai_behavior.STATES.IDLE
end

--[[
  Sets the state of a villager.
  
  @param self table - Villager object
  @param new_state string - New state
  @param data table - Optional state data
]]--
function ai_behavior.state_machine.set_state(self, new_state, data)
  local old_state = ai_behavior.state_machine.get_state(self)
  
  if old_state ~= new_state then
    -- Call exit handler for old state if it exists
    if self.on_exit_state then
      self:on_exit_state(old_state)
    end
    
    -- Update state
    self.ai_state = new_state
    self.ai_state_data = data or {}
    self.ai_state_time = os.clock()
    
    -- Call entry handler for new state if it exists
    if self.on_enter_state then
      self:on_enter_state(new_state)
    end
  end
end

--[[
  Gets how long the villager has been in the current state.
  
  @param self table - Villager object
  @return number - Time in seconds
]]--
function ai_behavior.state_machine.get_state_duration(self)
  if not self.ai_state_time then
    return 0
  end
  return os.clock() - self.ai_state_time
end

--[[
  Memory system for villagers.
  
  Allows villagers to remember useful information.
]]--
ai_behavior.memory = {}

--[[
  Remembers a location for a specific purpose.
  
  @param self table - Villager object
  @param category string - Category of location (e.g., "resource", "danger", "chest")
  @param pos table - Position to remember
  @param data table - Optional associated data
]]--
function ai_behavior.memory.remember_location(self, category, pos, data)
  if not self.memory then
    self.memory = {}
  end
  
  if not self.memory[category] then
    self.memory[category] = {}
  end
  
  local key = minetest.hash_node_position(pos)
  self.memory[category][key] = {
    pos = pos,
    data = data or {},
    time = os.clock(),
    visits = (self.memory[category][key] and self.memory[category][key].visits or 0) + 1,
  }
end

--[[
  Retrieves remembered locations of a category.
  
  @param self table - Villager object
  @param category string - Category to retrieve
  @param max_age number - Optional maximum age in seconds (filters old memories)
  @return table - List of remembered locations
]]--
function ai_behavior.memory.recall_locations(self, category, max_age)
  if not self.memory or not self.memory[category] then
    return {}
  end
  
  local locations = {}
  local now = os.clock()
  
  for _, entry in pairs(self.memory[category]) do
    if not max_age or (now - entry.time) <= max_age then
      table.insert(locations, entry)
    end
  end
  
  return locations
end

--[[
  Forgets old memories to prevent memory bloat.
  
  @param self table - Villager object
  @param max_age number - Maximum age in seconds
]]--
function ai_behavior.memory.forget_old(self, max_age)
  if not self.memory then
    return
  end
  
  local now = os.clock()
  
  for category, entries in pairs(self.memory) do
    for key, entry in pairs(entries) do
      if (now - entry.time) > max_age then
        entries[key] = nil
      end
    end
  end
end

--[[
  Behavior patterns for common situations.
]]--
ai_behavior.patterns = {}

--[[
  Sustainable resource gathering pattern.
  
  Before gathering a resource, checks if there are enough resources in the area
  to sustain gathering without depleting the source.
  
  @param pos table - Position to check
  @param resource_func function - Function to identify resource nodes
  @param radius number - Radius to check
  @param min_count number - Minimum count required
  @return boolean - true if sustainable to gather
]]--
function ai_behavior.patterns.is_sustainable(pos, resource_func, radius, min_count)
  local count = 0
  
  for x = -radius, radius do
    for z = -radius, radius do
      for y = -2, 2 do
        local check_pos = vector.add(pos, {x=x, y=y, z=z})
        if resource_func(check_pos) then
          count = count + 1
          if count >= min_count then
            return true
          end
        end
      end
    end
  end
  
  return false
end

--[[
  Collaborative work detection.
  
  Finds other villagers working on similar tasks nearby.
  This can be used to coordinate efforts or avoid redundant work.
  
  @param self table - Villager object
  @param radius number - Search radius
  @param job_filter string - Optional job name to filter by
  @return table - List of nearby working villagers
]]--
function ai_behavior.patterns.find_nearby_workers(self, radius, job_filter)
  local pos = self.object:get_pos()
  local workers = {}
  
  local objects = minetest.get_objects_inside_radius(pos, radius)
  for _, obj in ipairs(objects) do
    local entity = obj:get_luaentity()
    if entity and working_villages.is_villager(entity.name) then
      -- Don't include self
      if entity ~= self then
        -- Filter by job if specified
        if not job_filter or entity:get_job_name() == job_filter then
          table.insert(workers, entity)
        end
      end
    end
  end
  
  return workers
end

--[[
  Example: Enhanced job function using AI behavior system.
  
  This shows how a job can be structured using the AI behavior system.
  Not meant to be used directly, but as a template.
]]--
function ai_behavior.example_enhanced_job()
  return function(self)
    -- Standard initialization
    self:handle_night()
    self:handle_obstacles()
    
    -- Define possible tasks
    local tasks = {
      {
        name = "return_home",
        priority = ai_behavior.PRIORITY.HIGH,
        condition = function(s)
          -- High priority at night or when tired
          local time = minetest.get_timeofday()
          return time > 0.8 or time < 0.2
        end,
        execute = function(s)
          -- Logic to return home
          return true
        end,
      },
      {
        name = "primary_work",
        priority = ai_behavior.PRIORITY.NORMAL,
        evaluate = function(s, base_priority)
          -- Increase priority if we have materials/tools
          -- Decrease if we don't
          return base_priority
        end,
        condition = function(s)
          -- Can we do our primary work?
          return true
        end,
        execute = function(s)
          -- Main job logic
          return true
        end,
      },
      {
        name = "gather_tools",
        priority = ai_behavior.PRIORITY.URGENT,
        condition = function(s)
          -- Need tools?
          return false
        end,
        execute = function(s)
          -- Get tools from chest
          return true
        end,
      },
    }
    
    -- Select and execute best task
    local task = ai_behavior.task_priority.select_best_task(self, tasks)
    if task then
      ai_behavior.state_machine.set_state(self, ai_behavior.STATES.WORKING)
      task.execute(self)
    else
      ai_behavior.state_machine.set_state(self, ai_behavior.STATES.IDLE)
    end
  end
end

--[[
  Periodic memory cleanup.
  
  Should be called periodically (e.g., in globalstep or job function)
  to prevent memory from growing unbounded.
]]--
function ai_behavior.cleanup_memory(self)
  -- Forget memories older than 1 hour (3600 seconds)
  ai_behavior.memory.forget_old(self, 3600)
end

return ai_behavior
