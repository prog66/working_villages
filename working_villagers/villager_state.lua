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
  else
    if self.job_data then
      -- A job that exhausted its retries pauses itself with reason "error"
      -- and job_coroutines.resume() then refuses to run it again forever,
      -- even after this pause is lifted (manually via the sceptre, or
      -- automatically by the generic 200-tick auto-resume timer since
      -- "error" is not "manual"). Clearing job_error_state here is what
      -- actually gives the job a fresh attempt instead of leaving the
      -- villager looking active while permanently stuck.
      if self.job_data.pause_reason == "error" then
        self.job_data.job_error_state = nil
      end
      self.job_data.pause_reason = nil
    end
    -- refresh attachments after une pause (évite l’équipement invisible)
    if self.refresh_equipment then
      self:refresh_equipment()
    end
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
  if self.state_info == text then
    return
  end
  self.state_info = text

  local control = self.get_village_control and self:get_village_control() or nil
  local notify_level = (control and control.notify_level) or "important"
  if notify_level == "silent" then
    return
  end

  -- Send a short status update to a player so actions are visible.
  local now = minetest.get_gametime()
  self.job_data = self.job_data or {}
  local last_time = self.job_data.last_state_chat_time or 0
  local min_interval = notify_level == "detailed" and 12 or 20
  if now - last_time < min_interval then
    return
  end

  local msg = self.nametag and self.nametag ~= "" and (self.nametag .. ": " .. text) or text
  -- Only take the owner-only path if the owner is actually online: chat_send_player
  -- silently drops the message otherwise, which made "detailed" less reliable than
  -- the nearest-player fallback used by every other notify level.
  if notify_level == "detailed" and self.owner_name and self.owner_name ~= ""
      and minetest.get_player_by_name(self.owner_name) then
    minetest.chat_send_player(self.owner_name, msg)
    self.job_data.last_state_chat_time = now
    return
  end

  local pos = self.object and self.object:get_pos() or nil
  if pos then
    local players = minetest.get_connected_players()
    local nearest
    local best = 9999
    for _, player in ipairs(players) do
      local ppos = player:get_pos()
      local dist = vector.distance(pos, ppos)
      if dist < best then
        best = dist
        nearest = player
      end
    end
    if nearest and best <= 20 then
      minetest.chat_send_player(nearest:get_player_name(), msg)
      self.job_data.last_state_chat_time = now
      return
    end
  end
end
