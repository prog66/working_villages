local func = working_villages.require("jobs/util")
local snow_name = working_villages.voxelibre_compat.get_item("default:snow")

local function reserve_snow_target(self, pos, ttl)
	if not self.reserve_position then
		return true
	end
	return self:reserve_position("snow_target", pos, ttl or 12)
end

local function release_snow_target(self, pos)
	if self.release_reserved_position then
		self:release_reserved_position("snow_target", pos)
	end
end

local function find_snow(self, p)
	if self.is_position_reserved and self:is_position_reserved("snow_target", p) then
		return false
	end
	if func.is_protected(self, p) or working_villages.failed_pos_test(p) then
		return false
	end
	return minetest.get_node(p).name == snow_name
end

local function put_func()
	return true
end

local function is_snow_item(name)
	return name == snow_name
end

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
			if self.equip_best_weapon then self:equip_best_weapon() end
			if self.equip_best_armor then self:equip_best_armor() end
		self:handle_night()
			self:handle_chest(nil, put_func)
		self:handle_job_pos()

		self:count_timer("snowclearer:search")
		self:count_timer("snowclearer:change_dir")
			self:count_timer("snowclearer:announce")
		self:handle_obstacles()
		if self:timer_exceeded("snowclearer:search",10) then
				self:collect_nearest_item_by_condition(is_snow_item, {x = 3, y = 1, z = 3})
				local target = func.search_surrounding(self.object:get_pos(), function(pos)
					return find_snow(self, pos)
				end, searching_range)
			if target ~= nil then
					if not reserve_snow_target(self, target, 15) then
						self:set_displayed_action("cherche une autre plaque")
						return
					end
				local destination = func.find_adjacent_clear(target)
					if destination then
						destination = func.find_ground_below(destination)
					end
					if destination==false then
					destination = target
				end
				self:set_displayed_action("deneige")
					self:set_state_info("Je degage la neige.")
					local moved = self:go_to(destination)
					if not moved then
						release_snow_target(self, target)
						working_villages.failed_pos_record(target)
						self:set_displayed_action("neige inaccessible")
						return
					end
					local dug = self:dig(target,true)
					release_snow_target(self, target)
					if not dug then
						working_villages.failed_pos_record(target)
						self:set_displayed_action("deneigement rate")
						return
					end
					if self:timer_exceeded("snowclearer:announce", 150) then
						self:announce_action("Je degage la neige pour garder les chemins praticables.")
					end
				else
					self:set_state_info("Je cherche de la neige a degager.")
			end
			self:set_displayed_action("cherche du travail")
		elseif self:timer_exceeded("snowclearer:change_dir",25) then
			self:count_timer("snowclearer:search")
			self:change_direction_randomly()
		end
	end,
})
