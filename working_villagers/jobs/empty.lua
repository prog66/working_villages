-- Empty job definition
-- When a villager has this job, they should enter learning mode
local function empty_jobfunc(self)
	-- Check if learning mode is enabled
	local learning_enabled = minetest.settings:get_bool("working_villages_enable_learning_mode")
	if learning_enabled == nil then
		learning_enabled = true  -- Default to enabled
	end
	
	if learning_enabled then
		-- Try to switch to learner job if villager has been idle for a while
		self:count_timer("empty:check_learning")
		
		if self:timer_exceeded("empty:check_learning", 50) then
			-- Check if learner job is available
			if working_villages.registered_jobs["working_villages:job_apprenant"] then
				-- Get the villager's inventory
				local inv = self:get_inventory()
				if inv then
					-- Note: Direct inventory manipulation is the standard way to change jobs
					-- The villager system will detect the new job on the next step
					local learner_item = ItemStack("working_villages:job_apprenant")
					local old_stack = inv:get_stack("job", 1)
					
					-- Only transition if we still have an empty job (safety check)
					if old_stack:get_name() == "working_villages:job_empty" then
						inv:set_stack("job", 1, learner_item)
						-- Clear the timer
						self:set_timer("empty:check_learning", 0)
						-- Announce the transition
						self:set_state_info("Je vais maintenant apprendre de nouvelles choses !")
						return
					end
				end
			end
		end
	end
	
	-- If learning mode is disabled or not available, just idle
	self:handle_night()
	self:handle_obstacles()
	
	self:count_timer("empty:idle")
	if self:timer_exceeded("empty:idle", 100) then
		self:set_displayed_action("inactif")
		self:set_state_info("Je n'ai pas de métier. Donnez-moi un travail à faire.")
		self:change_direction_randomly()
	end
end

working_villages.register_job("working_villages:job_empty", {
	description      = "vide (working_villages)",
	inventory_image  = "default_paper.png",
	jobfunc          = empty_jobfunc,
})

-- only a recipe of the empty job is registered.
-- other job is created by writing on the empty job.
minetest.register_craft{
	output = "working_villages:job_empty",
	recipe = {
		{working_villages.voxelibre_compat.get_item("default:paper"), working_villages.voxelibre_compat.get_item("default:obsidian")},
	},
}
