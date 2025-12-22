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

function job_coroutines.resume(self,dtime)
  local job = self:get_job()
  if not job then return end
  if not self.job_thread then
    if job.on_step then
      job.on_start(self)
      self.job_thread = coroutine.create(job.on_step)
    elseif job.jobfunc then
      self.job_thread = coroutine.create(job.jobfunc)
    else
      log.error("le villageois %s a un metier invalide",self.inventory_name)
    end
  end
  if coroutine.status(self.job_thread) == "dead" then
    if job.jobfunc then
      self.job_thread = coroutine.create(job.jobfunc)
    else
      self.job_thread = coroutine.create(job.on_step)
    end
  end
  if coroutine.status(self.job_thread) == "suspended" then
    local ret = {coroutine.resume(self.job_thread, self, dtime)}
    if ret[1] then
      if ret[2] == commands.pause then
       self:set_pause(true)
       self.pause_auto = true
       self:set_timer("auto_resume", 0)
       self:set_displayed_action(ret[3])
      end
    else
      log.error("erreur dans job_thread " .. ret[2]..": "..debug.traceback(self.job_thread))
      minetest.chat_send_all("le villageois " .. self.inventory_name .. " a rencontre une erreur dans " .. job.description)
      self:set_pause(true)
      self:set_displayed_action("J'ai rencontre une erreur dans mon metier.")
    end
  end
end

return job_coroutines
