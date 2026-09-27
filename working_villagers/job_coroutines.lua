local job_coroutines = {}

local commands = {
  ---command to suspend villagers job
  -- expected values after this:
  -- * reason #string
  --   * the reason for suspending to show in infotext
  pause = "mettre en pause le metier du villageois",
}
job_coroutines.commands = commands

local log = working_villages.require("log")
local MAX_JOB_RETRIES = 3
local BASE_RETRY_DELAY = 30
local HEALTHY_RESUMES_TO_RESET = 10

local function format_error(value)
  if type(value) == "string" then
    return value
  end
  return tostring(value)
end

local function call_on_start(self, job)
  if type(job.on_start) ~= "function" then
    return true
  end

  return xpcall(function()
    job.on_start(self)
  end, function(error_value)
    return debug.traceback(format_error(error_value), 2)
  end)
end

local function create_job_thread(self, job)
  local started, start_error = call_on_start(self, job)
  if not started then
    return nil, start_error, "on_start"
  end

  if type(job.on_step) == "function" then
    return coroutine.create(job.on_step)
  end
  if type(job.jobfunc) == "function" then
    return coroutine.create(job.jobfunc)
  end
  return nil, "aucune fonction on_step/jobfunc valide", "configuration"
end

local function reset_error_state(self, job_name)
  self.job_data = self.job_data or {}
  local state = self.job_data.job_error_state
  if state and state.job_name == job_name then
    self.job_data.job_error_state = nil
  end
end

local function get_error_state(self, job_name)
  self.job_data = self.job_data or {}
  local state = self.job_data.job_error_state
  if type(state) == "table" and state.job_name == job_name then
    return state
  end
  if state and state.job_name ~= job_name then
    self.job_data.job_error_state = nil
  end
  return {
    job_name = job_name,
    retries = 0,
    retry_at = 0,
    retry_remaining = 0,
    healthy_resumes = 0,
    exhausted = false,
  }
end

local function persist_error_state(self, error_state)
  self.job_data = self.job_data or {}
  self.job_data.job_error_state = error_state
end

local function retry_is_waiting(self, error_state, dtime, now)
  if (error_state.retries or 0) <= 0 then
    return false
  end

  local remaining = tonumber(error_state.retry_remaining)
  if remaining == nil then
    -- Migrate the former absolute game-time deadline. get_gametime() can have
    -- a different origin after a restart, so never carry more than the delay
    -- appropriate for the current retry count.
    local legacy_remaining = math.max(0, (tonumber(error_state.retry_at) or 0) - now)
    local maximum_delay = BASE_RETRY_DELAY * math.max(1, error_state.retries or 1)
    remaining = math.min(legacy_remaining, maximum_delay)
  end

  if remaining <= 0 then
    error_state.retry_remaining = 0
    error_state.retry_at = now
    persist_error_state(self, error_state)
    return false
  end

  local elapsed = tonumber(dtime) or 0
  if elapsed < 0 or elapsed ~= elapsed then
    elapsed = 0
  end
  remaining = math.max(0, remaining - elapsed)
  error_state.retry_remaining = remaining
  error_state.retry_at = now + remaining
  persist_error_state(self, error_state)
  return remaining > 0
end

local function notify_exhausted(self, job, job_name)
  if self.notify_owner then
    self:notify_owner("Metier bloque pour " .. tostring(job.description or job_name) .. ".")
  else
    minetest.chat_send_all("le villageois " .. tostring(self.inventory_name) ..
      " a rencontre une erreur dans " .. tostring(job.description or job_name))
  end
end

local function record_job_failure(self, job, job_name, error_state, error_value, phase, now)
  local message = format_error(error_value)
  self.job_thread = nil
  error_state.retries = (error_state.retries or 0) + 1
  error_state.healthy_resumes = 0
  error_state.last_error = message
  error_state.last_error_phase = phase

  log.error("erreur dans le metier %s (%s): %s", tostring(job_name), tostring(phase), message)

  if error_state.retries < MAX_JOB_RETRIES then
    local retry_delay = BASE_RETRY_DELAY * error_state.retries
    error_state.retry_remaining = retry_delay
    error_state.retry_at = now + retry_delay
    error_state.exhausted = false
    persist_error_state(self, error_state)
    self.job_data.pause_reason = nil
    self.pause_auto = nil
    self:set_displayed_action("recupere")
    self:set_state_info("Je corrige un probleme dans mon metier.")
    return
  end

  error_state.retry_remaining = 0
  error_state.retry_at = now
  error_state.exhausted = true
  persist_error_state(self, error_state)
  self:set_pause(true)
  self.job_data.pause_reason = "error"
  self:set_displayed_action("erreur")
  self:set_state_info("Mon metier est bloque.")
  notify_exhausted(self, job, job_name)
end

local function record_healthy_resume(self, error_state, job_name)
  if (error_state.retries or 0) <= 0 then
    return
  end

  error_state.healthy_resumes = (error_state.healthy_resumes or 0) + 1
  if error_state.healthy_resumes >= HEALTHY_RESUMES_TO_RESET then
    reset_error_state(self, job_name)
  else
    persist_error_state(self, error_state)
  end
end

function job_coroutines.resume(self,dtime)
  local job = self:get_job()
  if not job then return end
  local job_name = self:get_job_name() or job.name or job.description or "metier inconnu"
  local error_state = get_error_state(self, job_name)
  local now = minetest.get_gametime()

  if error_state.exhausted then
    return
  end

  if not self.job_thread and retry_is_waiting(self, error_state, dtime, now) then
    return
  end

  if self.job_thread and coroutine.status(self.job_thread) == "dead" then
    self.job_thread = nil
    reset_error_state(self, job_name)
    error_state = get_error_state(self, job_name)
  end

  if not self.job_thread then
    local thread, create_error, create_phase = create_job_thread(self, job)
    self.job_thread = thread
    if not self.job_thread then
      record_job_failure(self, job, job_name, error_state,
        create_error or "metier invalide", create_phase or "demarrage", now)
      return
    end
  end

  if not self.job_thread then
    return
  end

  if coroutine.status(self.job_thread) == "suspended" then
    -- Retain a one-entry diagnostic receipt for interruption/recovery tests.
    -- A profession coroutine may legitimately finish immediately after its
    -- resumed action and be cleared below; recording the exact object before
    -- resume distinguishes that normal completion from replacing an
    -- interrupted task with a fresh coroutine.
    local resumed_thread = self.job_thread
    local ret = {coroutine.resume(resumed_thread, self, dtime)}
    self._last_resumed_job_thread = resumed_thread
    self._last_resumed_job_thread_at = now
    self._last_resumed_job_name = job_name
    self._recent_resumed_job_threads = type(self._recent_resumed_job_threads) == "table"
      and self._recent_resumed_job_threads or {}
    table.insert(self._recent_resumed_job_threads, resumed_thread)
    while #self._recent_resumed_job_threads > 8 do
      table.remove(self._recent_resumed_job_threads, 1)
    end
    if ret[1] then
      local completed = coroutine.status(self.job_thread) == "dead"
      if completed then
        reset_error_state(self, job_name)
        self.job_thread = nil
      else
        -- A single successful yield is not enough evidence that a repeatedly
        -- failing job recovered. Require a sustained healthy run instead.
        record_healthy_resume(self, error_state, job_name)
      end
      if ret[2] == commands.pause then
       self:set_pause(true)
       self.pause_auto = true
       self.job_data = self.job_data or {}
       self.job_data.pause_reason = "auto"
       self:set_timer("auto_resume", 0)
       self:set_displayed_action(ret[3])
      end
    else
      local traceback = debug.traceback(self.job_thread, format_error(ret[2]))
      record_job_failure(self, job, job_name, error_state, traceback,
        "coroutine", now)
    end
  end
end

return job_coroutines
