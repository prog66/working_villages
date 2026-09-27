-- Standalone fake-Luanti regression tests for resilient job coroutines.
-- Run from the repository root with:
--   lua5.1 working_villagers/tests/job_coroutines_spec.lua working_villagers

local modpath = (arg and arg[1]) or "working_villagers"
local gametime = 100
local log_messages = {}
local broadcasts = {}

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected) ..
      ", got " .. tostring(actual), 2)
  end
end

local fake_log = {
  error = function(message, ...)
    table.insert(log_messages, string.format(message, ...))
  end,
}

working_villages = {
  require = function(name)
    assert_equal(name, "log", "unexpected module request")
    return fake_log
  end,
}

minetest = {
  get_gametime = function()
    return gametime
  end,
  chat_send_all = function(message)
    table.insert(broadcasts, message)
  end,
}

local job_coroutines = dofile(modpath .. "/job_coroutines.lua")

local function make_villager(job)
  local villager = {
    inventory_name = "test_villager",
    job_data = {},
    job_thread = nil,
    pause_calls = 0,
    notifications = {},
  }

  function villager:get_job()
    return job
  end

  function villager:get_job_name()
    return "test_job"
  end

  function villager:set_pause(value)
    self.paused = value
    self.pause_calls = self.pause_calls + 1
  end

  function villager:set_displayed_action(value)
    self.displayed_action = value
  end

  function villager:set_state_info(value)
    self.state_info = value
  end

  function villager:set_timer(name, value)
    self.timers = self.timers or {}
    self.timers[name] = value
  end

  function villager:notify_owner(message)
    table.insert(self.notifications, message)
  end

  return villager
end

local function advance(villager, seconds)
  gametime = gametime + seconds
  job_coroutines.resume(villager, seconds)
end

-- Each new thread yields once and then fails. Successful yields must not erase
-- the previous retry, and the third repeated failure must block the job.
local starts = 0
local yielding_failure_job = {
  description = "metier instable",
  on_start = function()
    starts = starts + 1
  end,
  jobfunc = function()
    coroutine.yield("travail")
    error("echec apres yield")
  end,
}
local villager = make_villager(yielding_failure_job)

job_coroutines.resume(villager, 0)
assert_equal(starts, 1, "initial job start")
local first_thread = villager.job_thread
assert_equal(villager._last_resumed_job_thread, first_thread,
  "exact resumed coroutine receipt was not retained")
assert_equal(villager._recent_resumed_job_threads[1], first_thread,
  "bounded coroutine receipt history lost the first resume")
job_coroutines.resume(villager, 0)
assert_equal(villager.job_data.job_error_state.retries, 1, "first failure count")
assert_equal(villager._last_resumed_job_thread, first_thread,
  "completed/failed coroutine receipt was replaced before recovery inspection")
assert_equal(villager.job_data.job_error_state.retry_remaining, 30, "first retry delay")

advance(villager, 29)
assert_equal(starts, 1, "job restarted before first delay elapsed")
advance(villager, 1)
assert_equal(starts, 2, "job did not restart after first delay")
assert_equal(villager.job_data.job_error_state.retries, 1,
  "successful yield incorrectly reset failure count")
job_coroutines.resume(villager, 0)
assert_equal(villager.job_data.job_error_state.retries, 2, "second failure count")
assert_equal(villager.job_data.job_error_state.retry_remaining, 60, "second retry delay")

advance(villager, 60)
assert_equal(starts, 3, "job did not restart after second delay")
assert_equal(villager.job_data.job_error_state.retries, 2,
  "second successful yield incorrectly reset failure count")
job_coroutines.resume(villager, 0)
assert_equal(villager.job_data.job_error_state.retries, 3, "third failure count")
assert_equal(villager.job_data.job_error_state.exhausted, true, "retry exhaustion")
assert_equal(villager.paused, true, "exhausted job pause")
assert_equal(villager.job_data.pause_reason, "error", "exhausted pause reason")
assert_equal(villager.pause_calls, 1, "exhausted job pause count")
assert_equal(#villager.notifications, 1, "owner notification count")

advance(villager, 600)
assert_equal(starts, 3, "exhausted job restarted")
assert_equal(villager.pause_calls, 1, "exhausted job paused repeatedly")

-- on_start failures are caught and use the same bounded delayed retry path.
local start_attempts = 0
local start_failure_job = {
  description = "demarrage instable",
  on_start = function()
    start_attempts = start_attempts + 1
    error({reason = "start failed"})
  end,
  jobfunc = function()
    coroutine.yield()
  end,
}
local start_villager = make_villager(start_failure_job)
local protected_ok, protected_error = pcall(job_coroutines.resume, start_villager, 0)
assert_equal(protected_ok, true, "on_start error escaped resume: " .. tostring(protected_error))
assert_equal(start_attempts, 1, "first on_start attempt")
assert_equal(start_villager.job_data.job_error_state.retries, 1, "on_start failure count")

advance(start_villager, 30)
assert_equal(start_attempts, 2, "second on_start attempt")
assert_equal(start_villager.job_data.job_error_state.retries, 2, "second on_start failure count")
advance(start_villager, 60)
assert_equal(start_attempts, 3, "third on_start attempt")
assert_equal(start_villager.job_data.job_error_state.exhausted, true,
  "on_start retries were not exhausted")
assert_equal(start_villager.paused, true, "on_start exhaustion did not pause")

-- A sustained healthy run eventually forgives an old isolated failure.
local healthy_starts = 0
local fail_first_start = true
local recovering_job = {
  description = "metier retabli",
  on_start = function()
    healthy_starts = healthy_starts + 1
    if fail_first_start then
      fail_first_start = false
      error("temporary start failure")
    end
  end,
  jobfunc = function()
    while true do
      coroutine.yield("ok")
    end
  end,
}
local recovering_villager = make_villager(recovering_job)
job_coroutines.resume(recovering_villager, 0)
advance(recovering_villager, 30)
for _ = 1, 9 do
  job_coroutines.resume(recovering_villager, 0)
end
assert_equal(recovering_villager.job_data.job_error_state, nil,
  "sustained healthy execution did not clear old failure state")
assert_equal(healthy_starts, 2, "recovering job start count")

-- Legacy absolute deadlines are bounded when loaded with a new game-time
-- origin, instead of leaving the villager dormant for an arbitrary duration.
gametime = 1000
local migrated_starts = 0
local migrated_job = {
  description = "metier migre",
  on_start = function()
    migrated_starts = migrated_starts + 1
  end,
  jobfunc = function()
    while true do
      coroutine.yield("ok")
    end
  end,
}
local migrated_villager = make_villager(migrated_job)
migrated_villager.job_data.job_error_state = {
  job_name = "test_job",
  retries = 1,
  retry_at = 999999,
  exhausted = false,
}
job_coroutines.resume(migrated_villager, 29)
assert_equal(migrated_starts, 0, "legacy retry started before bounded delay")
job_coroutines.resume(migrated_villager, 1)
assert_equal(migrated_starts, 1, "legacy retry deadline was not migrated")

print("JOB_COROUTINES_SPEC_OK")
