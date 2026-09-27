-- Trader job: mans the village's trading post.
--
-- Unlike other jobs this one does not gather, build or craft anything by
-- itself. Its whole purpose is the "Poste de troc" page registered in
-- talking.lua: talking to a trader opens a remote window onto the real
-- shared village chest, using Minetest's native list[]/listring[] transfer
-- widgets. The engine itself handles the actual item movement (exactly as
-- it does for any chest a player opens directly), so this job adds no new
-- inventory-mutation logic that could lose or duplicate items -- it is a
-- convenience so players do not have to walk to the chest to help restock
-- the village.

local function trader_jobfunc(self)
	self:handle_night()
	self:handle_obstacles()
	self:count_timer("trader:idle")
	if self:timer_exceeded("trader:idle", 120) then
		self:set_displayed_action("marchand")
		self:set_state_info(
			"J'attends pres du poste de troc. Parlez-moi pour consulter " ..
			"le coffre commun du village sans vous y rendre.")
		self:change_direction_randomly()
	end
end

working_villages.register_job("working_villages:job_trader", {
	description      = "marchand (working_villages)",
	long_description = "Je tiens le poste de troc du village.\
Parlez-moi pour consulter le coffre commun et y deposer des ressources\
sans avoir a vous y rendre. Je ne recolte ni ne construis rien moi-meme :\
mon travail est de faciliter les echanges entre vous et le village.",
	inventory_image  = "default_sign_wood.png",
	capabilities = {
		trading_post = true,
	},
	on_start = function(self)
		self:notify_job_feature(
			"Marchand",
			"Ouvre un acces rapide au coffre commun via son menu de discussion (\"Poste de troc\")."
		)
	end,
	jobfunc = trader_jobfunc,
})
