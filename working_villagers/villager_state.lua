--[[
  Pauses or unpauses the villager's activity.
  
  When paused:
  - Villager stops moving (velocity set to 0)
  - Animation changes to STAND
  - Job execution is suspended
  
  @param state boolean - true to pause, false to unpause
  @usage villager:set_pause(true) -- Pause the villager
]]--
function working_villages.villager:set_pause(state)
  assert(type(state) == "boolean","pause state must be a boolean")
  self.pause = state
  if state then
    self.object:set_velocity{x = 0, y = 0, z = 0}
    --perhaps check what animation we are in
    self:set_animation(working_villages.animation_frames.STAND)
  end
end

--[[
  Sets the action text displayed to players when they look at the villager.
  
  The displayed text appears as "this villager is [action]"
  Examples: "working", "idle", "sleeping", "building"
  
  Only updates the infotext if the action has changed to avoid unnecessary updates.
  
  @param action string - Short description of current action (present tense)
  @usage villager:set_displayed_action("farming")
]]--
function working_villages.villager:set_displayed_action(action)
  assert(type(action) == "string","action info must be a string")
  if self.disp_action ~= action then
    self.disp_action = action
    self:update_infotext()
  end
end

--[[
  Sets detailed internal state information about what the villager is doing.
  
  This is used for debugging and detailed status displays (e.g., in the commanding sceptre interface).
  Can contain multi-line text and detailed explanations of the current state.
  
  Examples:
  - "I am currently looking for a building site nearby.\nHowever there wasn't one the last time I checked."
  - "Building completed! Gained construction experience."
  - "Searching for trees to cut in a 10 block radius."
  
  @param text string - Detailed description of current state/activity
  @usage villager:set_state_info("Harvesting crops and replanting seeds.")
]]--
function working_villages.villager:set_state_info(text)
  assert(type(text) == "string","state info must be a string")
  self.state_info = text
end
