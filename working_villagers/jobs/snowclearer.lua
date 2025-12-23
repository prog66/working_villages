local func = working_villages.require("jobs/util")
local snow_name = working_villages.voxelibre_compat.get_item("default:snow")
local function find_snow(p) return minetest.get_node(p).name == snow_name end
local searching_range = {x = 10, y = 3, z = 10}

working_villages.register_job("working_villages:job_snowclearer", {
	description      = "deneigeur (working_villages)",
	long_description = "Je degage la neige.\
Mon travail sert surtout aux tests, pas a recolter.\
Ce metier semble inutile.\
Je le fais quand meme.",
	inventory_image  = "default_paper.png^memorandum_letters.png",
	capabilities = {
		snow_removal = true,
		area_clearing = true,
		testing_utility = true,
	},
	on_start = function(self)
		-- Notify player about snow clearer capabilities
		self:notify_job_feature(
			"Déneigeur",
			"Dégage la neige automatiquement (métier de test)"
		)
	end,
	jobfunc = function(self)
		self:handle_night()
		self:handle_job_pos()

		self:count_timer("snowclearer:search")
		self:count_timer("snowclearer:change_dir")
		self:handle_obstacles()
		if self:timer_exceeded("snowclearer:search",20) then
			local target = func.search_surrounding(self.object:get_pos(), find_snow, searching_range)
			if target ~= nil then
				local destination = func.find_adjacent_clear(target)
				if destination==false then
					print("failure: no adjacent walkable found")
					destination = target
				end
				self:set_displayed_action("deneige")
				self:go_to(destination)
				self:dig(target,true)
			end
			self:set_displayed_action("cherche du travail")
		elseif self:timer_exceeded("snowclearer:change_dir",50) then
			self:count_timer("snowclearer:search")
			self:change_direction_randomly()
		end
	end,
})
