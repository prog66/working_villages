local log = working_villages.require("log")
local co_command = working_villages.require("job_coroutines").commands
local func = working_villages.require("jobs/util")
local follower = working_villages.require("jobs/follow_player")

local default_mode = minetest.settings:get("working_villages_guard_default_mode") or "patrol"
local patrol_radius = tonumber(minetest.settings:get("working_villages_guard_patrol_radius")) or 12
local auto_weapon = minetest.settings:get_bool("working_villages_guard_auto_weapon", true)

local function pick_patrol_target(center, radius)
	radius = radius or patrol_radius
	local pos = {
		x = center.x + math.random(-radius, radius),
		y = center.y + 2,
		z = center.z + math.random(-radius, radius),
	}
	local ground = func.find_ground_below(pos)
	return ground or center
end

local function follow_target(self, target)
	local target_position = target:get_pos()
	local direction = vector.subtract(target_position, self.object:get_pos())
	if vector.length(direction) < 3 then
		follower.stop(self)
	else
		follower.walk_in_direction(self, direction)
	end
end

local function ensure_weapon(self)
	if not auto_weapon then
		return
	end
	local wield_name = self:get_wield_item_stack():get_name()
	if self:is_weapon(wield_name) then
		return
	end
	if self:has_item_in_main(function(name) return self:is_weapon(name) end) then
		self:equip_best_weapon()
		return
	end

	local candidates
	if working_villages.voxelibre_compat and working_villages.voxelibre_compat.is_voxelibre then
		candidates = {
			"mcl_tools:sword_iron",
			"mcl_tools:sword_stone",
			"mcl_tools:sword_wood",
			"mcl_tools:axe_iron",
			"mcl_tools:axe_stone",
			"mcl_tools:axe_wood",
		}
	else
		candidates = {
			"default:sword_steel",
			"default:sword_stone",
			"default:sword_wood",
			"default:axe_steel",
			"default:axe_stone",
			"default:axe_wood",
		}
	end

	for _, name in ipairs(candidates) do
		if minetest.registered_items[name] then
			self:add_item_to_main(ItemStack(name))
			self:equip_best_weapon()
			return
		end
	end
end

--modes: stationary,escort,patrol,wandering

working_villages.register_job("working_villages:job_guard", {
	description      = "garde (working_villages)",
	long_description = "Je monte la garde et je repousse les ennemis.",
	inventory_image  = "default_paper.png^memorandum_letters.png", --TODO: sword/bow/shield
	jobfunc = function(self)
		if self.pause then
			coroutine.yield()
			return
		end

		local guard_mode = self:get_job_data("mode")
		if guard_mode == nil or guard_mode == "" then
			guard_mode = default_mode
			self:set_job_data("mode", guard_mode)
		end

		local guard_pos = self:get_job_data("guard_target")
		if guard_mode == "escort" then
			if type(guard_pos) == "table" then
				guard_pos = nil
				self:set_job_data("guard_target", nil)
			end
		else
			if type(guard_pos) ~= "table" then
				guard_pos = self.object:get_pos()
				self:set_job_data("guard_target", guard_pos)
			end
		end

		ensure_weapon(self)

		local enemy = self:get_nearest_enemy(20)
		if enemy then
			self:atack(enemy)
			coroutine.yield()
			return
		end

		if guard_mode == "stationary" then
			self:go_to(guard_pos)
		elseif guard_mode == "escort" then
			local escort_target = self:get_job_data("guard_target")

			if escort_target == nil or escort_target == "" then
				escort_target = self.owner_name
			end

			local escort_object = escort_target and minetest.get_player_by_name(escort_target)
			if escort_object == nil then
				return co_command.pause, "cible d'escorte absente du serveur"
			end

			follow_target(self, escort_object)
		elseif guard_mode == "patrol" then
			log.verbose("%s patrouille", self.inventory_name)
			self:count_timer("guard:patrol")
			if self:timer_exceeded("guard:patrol", 40) or not self:get_job_data("patrol_target") then
				local custom_radius = self:get_job_data("patrol_radius")
				self:set_job_data("patrol_target", pick_patrol_target(guard_pos, custom_radius))
			end
			local patrol_target = self:get_job_data("patrol_target")
			if patrol_target then
				self:go_to(patrol_target)
				self:set_job_data("patrol_target", nil)
			end
		elseif guard_mode == "wandering" then
			log.verbose("%s se promene", self.inventory_name)
			self:count_timer("guard:wandering")
			if self:timer_exceeded("guard:wandering", 40) then
				self:change_direction_randomly()
			end
		end

		coroutine.yield()
	end,
})
