local log = working_villages.require("log")
local co_command = working_villages.require("job_coroutines").commands
local func = working_villages.require("jobs/util")
local follower = working_villages.require("jobs/follow_player")
local comm = working_villages.communication
local collab = working_villages.collaborative_tasks
local blacksmith = working_villages.blacksmith

local default_mode = minetest.settings:get("working_villages_guard_default_mode") or "patrol"
local patrol_radius = tonumber(minetest.settings:get("working_villages_guard_patrol_radius")) or 12
local auto_weapon = minetest.settings:get_bool("working_villages_guard_auto_weapon", true)
local gameplay_mode = working_villages.gameplay_mode
if type(gameplay_mode) ~= "string" or gameplay_mode == "" then
	gameplay_mode = minetest.settings:get("working_villages_gameplay_mode") or "survival"
end
local creative_test_mode = gameplay_mode == "creative_test"

local function pick_registered_item(candidates)
	for _, name in ipairs(candidates) do
		if minetest.registered_items[name] then
			return name
		end
	end
	return nil
end

local guard_armor_levels = {
	{
		label = "cuir",
		items = {
			head = {"mcl_armor:helmet_leather", "3d_armor:helmet_leather", "armor:helmet_leather"},
			torso = {"mcl_armor:chestplate_leather", "3d_armor:chestplate_leather", "armor:chestplate_leather"},
			legs = {"mcl_armor:leggings_leather", "3d_armor:leggings_leather", "armor:leggings_leather"},
			feet = {"mcl_armor:boots_leather", "3d_armor:boots_leather", "armor:boots_leather"},
		},
	},
	{
		label = "maille",
		items = {
			head = {"mcl_armor:helmet_chain", "3d_armor:helmet_chain", "armor:helmet_chain"},
			torso = {"mcl_armor:chestplate_chain", "3d_armor:chestplate_chain", "armor:chestplate_chain"},
			legs = {"mcl_armor:leggings_chain", "3d_armor:leggings_chain", "armor:leggings_chain"},
			feet = {"mcl_armor:boots_chain", "3d_armor:boots_chain", "armor:boots_chain"},
		},
	},
	{
		label = "or",
		items = {
			head = {"mcl_armor:helmet_gold", "3d_armor:helmet_gold", "armor:helmet_gold"},
			torso = {"mcl_armor:chestplate_gold", "3d_armor:chestplate_gold", "armor:chestplate_gold"},
			legs = {"mcl_armor:leggings_gold", "3d_armor:leggings_gold", "armor:leggings_gold"},
			feet = {"mcl_armor:boots_gold", "3d_armor:boots_gold", "armor:boots_gold"},
		},
	},
	{
		label = "fer",
		items = {
			head = {"mcl_armor:helmet_iron", "3d_armor:helmet_steel", "armor:helmet_iron", "armor:helmet_steel"},
			torso = {"mcl_armor:chestplate_iron", "3d_armor:chestplate_steel", "armor:chestplate_iron", "armor:chestplate_steel"},
			legs = {"mcl_armor:leggings_iron", "3d_armor:leggings_steel", "armor:leggings_iron", "armor:leggings_steel"},
			feet = {"mcl_armor:boots_iron", "3d_armor:boots_steel", "armor:boots_iron", "armor:boots_steel"},
		},
	},
}

local function ensure_guard_armor_for_level(self, level)
	if not creative_test_mode then
		return false, nil
	end
	local tier = guard_armor_levels[level]
	if not tier then
		return false, nil
	end
	local added = false
	for _, slot in ipairs({"head", "torso", "legs", "feet"}) do
		local item_name = pick_registered_item(tier.items[slot])
		if item_name and not self:has_item_in_main(function(name) return name == item_name end) then
			self:add_item_to_main(ItemStack(item_name))
			added = true
		end
	end
	if added and self.equip_best_armor then
		self:equip_best_armor()
	end
	return added, tier.label
end

local function guard_award_xp(self, amount)
	self.job_data = self.job_data or {}
	local xp = self.job_data.guard_xp or 0
	local level = self.job_data.guard_level or 0
	xp = xp + amount
	self.job_data.guard_xp = xp
	local new_level = math.min(xp, #guard_armor_levels)
	if new_level > level then
		self.job_data.guard_level = new_level
		local added, label = ensure_guard_armor_for_level(self, new_level)
		if added and label then
			self:set_state_info("Je progresse : armure " .. label .. ".")
			if self.notify_owner_event then
				self:notify_owner_event(
					"Garde niveau " .. new_level .. " : armure " .. label .. ".",
					"guard:level_up:" .. new_level,
					60,
					"important"
				)
			end
		end
	end
end

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

local function weapon_candidates()
	if working_villages.voxelibre_compat and working_villages.voxelibre_compat.is_voxelibre then
		return {
			"mcl_tools:sword_diamond",
			"mcl_tools:sword_iron",
			"mcl_tools:sword_gold",
			"mcl_tools:sword_stone",
			"mcl_tools:sword_wood",
			"mcl_tools:axe_diamond",
			"mcl_tools:axe_iron",
			"mcl_tools:axe_gold",
			"mcl_tools:axe_stone",
			"mcl_tools:axe_wood",
		}
	end
	return {
		"default:sword_mese",
		"default:sword_diamond",
		"default:sword_steel",
		"default:sword_bronze",
		"default:sword_stone",
		"default:sword_wood",
		"default:axe_mese",
		"default:axe_diamond",
		"default:axe_steel",
		"default:axe_bronze",
		"default:axe_stone",
		"default:axe_wood",
	}
end

local function shield_candidates()
	return {
		"mcl_shields:shield",
		"mcl_shields:shield_enchanted",
		"shields:shield_steel",
		"3d_armor:shield_steel",
		"armor:shield_steel",
	}
end

local function find_nearby_blacksmith(self, radius)
	local villagers = comm and comm.find_nearby_villagers(self.object:get_pos(), radius or 25,
		"working_villages:job_blacksmith", self.owner_name) or {}
	for _, villager in ipairs(villagers) do
		if villager.owner_name == self.owner_name then
			return villager
		end
	end
	return nil
end

local function mark_wait_start(self, key)
	self.job_data = self.job_data or {}
	if not self.job_data[key] then
		self.job_data[key] = minetest.get_gametime()
	end
end

local function clear_wait_start(self, key)
	if self.job_data then
		self.job_data[key] = nil
	end
end

local function request_guard_supply(self, key, tool_group, label, state_key)
	self.job_data = self.job_data or {}
	local now = minetest.get_gametime()
	local last = tonumber(self.job_data[state_key])
	if last and now >= last and now - last < 120 then
		return false
	end

	local ordered = false
	local smith = find_nearby_blacksmith(self, 25)
	if smith and blacksmith and blacksmith.enqueue_order then
		ordered = select(1, blacksmith.enqueue_order(smith, key, 1,
			self.owner_name or "", self.inventory_name))
	end
	if (not ordered) and blacksmith and blacksmith.enqueue_global_order then
		ordered = select(1, blacksmith.enqueue_global_order(key, 1,
			self.owner_name or "", self.inventory_name))
	end
	if not ordered and comm then
		comm.broadcast(self, comm.list_loaded_villagers(), "help_needed", {
			tool_group = tool_group,
			requester_id = self.inventory_name,
		})
	end
	self.job_data[state_key] = now
	self:set_state_info(ordered and ("Je demande " .. label .. ".")
		or ("Je signale qu'il me faut " .. label .. "."))
	return ordered
end

local function maybe_emergency_supply(self, wait_key, candidates, equip_func)
	if not creative_test_mode then
		return false
	end
	local since = self.job_data and tonumber(self.job_data[wait_key]) or 0
	if since == 0 or (minetest.get_gametime() - since) < 600 then
		return false
	end
	local item_name = pick_registered_item(candidates)
	if not item_name then
		return false
	end
	self:add_item_to_main(ItemStack(item_name))
	equip_func(item_name)
	return true
end

local function ensure_weapon(self, allow_supply_search)
	if not auto_weapon then
		return
	end
	local wield_name = self:get_wield_item_stack():get_name()
	if self:is_weapon(wield_name) then
		clear_wait_start(self, "guard_weapon_wait_since")
		return
	end
	if self:has_item_in_main(function(name) return self:is_weapon(name) end) then
		self:equip_best_weapon()
		clear_wait_start(self, "guard_weapon_wait_since")
		return
	end
	if not allow_supply_search then
		return
	end
	if self.take_from_shared_storage_by_predicate then
		if self:take_from_shared_storage_by_predicate(function(name) return self:is_weapon(name) end, 1) then
			self:equip_best_weapon()
			clear_wait_start(self, "guard_weapon_wait_since")
			return
		end
	end
	mark_wait_start(self, "guard_weapon_wait_since")
	request_guard_supply(self, "sword_iron", "sword", "une arme", "guard_weapon_request_time")
	maybe_emergency_supply(self, "guard_weapon_wait_since", weapon_candidates(), function()
		self:equip_best_weapon()
		clear_wait_start(self, "guard_weapon_wait_since")
	end)
end

local function ensure_shield(self, allow_supply_search)
	local offhand = self.get_offhand_item_stack and self:get_offhand_item_stack() or nil
	if offhand and minetest.get_item_group(offhand:get_name(), "shield") > 0 then
		clear_wait_start(self, "guard_shield_wait_since")
		return
	end
	local wield = self:get_wield_item_stack()
	if wield and minetest.get_item_group(wield:get_name(), "shield") > 0 then
		self:set_offhand_item_stack(wield)
		self:set_wield_item_stack(ItemStack())
		clear_wait_start(self, "guard_shield_wait_since")
		return
	end
	if self:has_item_in_main(function(name) return minetest.get_item_group(name, "shield") > 0 end) then
		if self.move_main_to_offhand then
			self:move_main_to_offhand(function(name) return minetest.get_item_group(name, "shield") > 0 end)
		end
		clear_wait_start(self, "guard_shield_wait_since")
		return
	end
	if not allow_supply_search then
		return
	end
	if self.take_tool_from_shared_storage and self:take_tool_from_shared_storage("shield") then
		if self.move_main_to_offhand then
			self:move_main_to_offhand(function(name) return minetest.get_item_group(name, "shield") > 0 end)
		end
		clear_wait_start(self, "guard_shield_wait_since")
		return
	end
	mark_wait_start(self, "guard_shield_wait_since")
	request_guard_supply(self, "shield_iron", "shield", "un bouclier", "guard_shield_request_time")
	maybe_emergency_supply(self, "guard_shield_wait_since", shield_candidates(), function(item_name)
		if self.move_main_to_offhand then
			self:move_main_to_offhand(function(item) return item == item_name end)
		end
		clear_wait_start(self, "guard_shield_wait_since")
	end)
end

local function ensure_armor(self, allow_supply_search)
	if not self.get_armor_stack then
		return
	end
	for _, request in ipairs({
		{slot = "head", group = "armor_head", order = "helmet_iron", label = "un casque", wait = "guard_armor_head_wait_since", state = "guard_armor_head_request_time"},
		{slot = "torso", group = "armor_torso", order = "chestplate_iron", label = "un plastron", wait = "guard_armor_torso_wait_since", state = "guard_armor_torso_request_time"},
		{slot = "legs", group = "armor_legs", order = "leggings_iron", label = "des jambieres", wait = "guard_armor_legs_wait_since", state = "guard_armor_legs_request_time"},
		{slot = "feet", group = "armor_feet", order = "boots_iron", label = "des bottes", wait = "guard_armor_feet_wait_since", state = "guard_armor_feet_request_time"},
	}) do
		local stack = self:get_armor_stack(request.slot)
		if stack and not stack:is_empty() then
			clear_wait_start(self, request.wait)
		else
			if not allow_supply_search then
				return
			end
			if self.take_from_shared_storage_by_predicate then
				if self:take_from_shared_storage_by_predicate(function(name)
					return minetest.get_item_group(name, request.group) > 0
				end, 1) then
					if self.equip_best_armor then
						self:equip_best_armor()
					end
					clear_wait_start(self, request.wait)
					return
				end
			end
			mark_wait_start(self, request.wait)
			request_guard_supply(self, request.order, request.group, request.label, request.state)
			return
		end
	end
end

--modes: stationary,escort,patrol,wandering

working_villages.register_job("working_villages:job_guard", {
	description      = "garde (working_villages)",
	long_description = "Je monte la garde et je repousse les ennemis.",
	inventory_image  = "default_paper.png^memorandum_letters.png", --TODO: sword/bow/shield
	capabilities = {
		combat = true,
		auto_equip_weapon = true,
		patrol_modes = {"stationary", "escort", "patrol", "wandering"},
		threat_detection_range = 20,
	},
	on_start = function(self)
		-- Notify player about guard capabilities
		self:notify_job_feature(
			"Modes de garde",
			"Stationnaire, escorte, patrouille ou errant. Détection automatique d'ennemis à 20 blocs."
		)
	end,
	jobfunc = function(self)
		if self.pause then
			coroutine.yield()
			return
		end
		-- auto-equip dès le tick de job (armes + armures visibles)
		if self.equip_best_weapon then
			self:equip_best_weapon()
		end
		if self.equip_best_armor then
			self:equip_best_armor()
		end
		-- refresh visuals even si aucun changement d'inventaire
		if self.refresh_equipment then
			self:refresh_equipment()
		end

		local guard_mode = self:get_job_data("mode")
		if guard_mode == nil or guard_mode == "" then
			guard_mode = default_mode
			self:set_job_data("mode", guard_mode)
		end

		local guard_pos = self:get_job_data("guard_target")
		if guard_mode == "patrol" and type(guard_pos) == "string" and guard_pos ~= "" then
			guard_mode = "escort"
			self:set_job_data("mode", guard_mode)
		end
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

		self:count_timer("guard:equipment")
		local allow_supply_search = self:timer_exceeded("guard:equipment", 40)
		ensure_weapon(self, allow_supply_search)
		ensure_shield(self, allow_supply_search)
		ensure_armor(self, allow_supply_search)

		local enemy = self:get_nearest_enemy(20)
		if enemy then
			local enemy_pos = enemy.get_pos and enemy:get_pos() or self.object:get_pos()
			if working_villages.record_village_threat then
				working_villages.record_village_threat(self.owner_name, enemy_pos, "guard_contact")
			end
			self:count_timer("guard:alert")
			if comm and self:timer_exceeded("guard:alert", 60) then
				local targets = comm.find_nearby_villagers(self.object:get_pos(), 40, nil, self.owner_name)
				comm.broadcast(self, targets, "danger_alert", {
					pos = self.object:get_pos(),
					info = "Ennemi detecte",
				})
			end
			self:count_timer("guard:collab")
			if collab and self:timer_exceeded("guard:collab", 120) then
				collab.start_task("danger_response", self, { pos = self.object:get_pos() })
			end
			local before_hp = enemy:get_hp()
			self:atack(enemy)
			if before_hp and before_hp > 0 then
				local after_hp = enemy:get_hp()
				if after_hp and after_hp <= 0 then
					if working_villages.resolve_village_threat then
						working_villages.resolve_village_threat(self.owner_name, enemy_pos)
					end
					guard_award_xp(self, 1)
					if collab and self.job_data and self.job_data.collab_task then
						local record = collab.get(self.job_data.collab_task)
						if record and record.state == "active" and record.name == "danger_response" then
							collab.complete(record.id, {resolved_by = self.inventory_name})
						end
					end
				end
			end
			coroutine.yield()
			return
		end

		if collab and self.job_data and self.job_data.collab_task then
			local record = collab.get(self.job_data.collab_task)
			local danger_pos = record and record.state == "active" and record.name == "danger_response"
				and record.data and record.data.pos or nil
			if danger_pos then
				if vector.distance(self.object:get_pos(), danger_pos) > 3 then
					self:set_displayed_action("rejoint l'alerte")
					self:set_state_info("Je rejoins les autres gardes sur la zone dangereuse.")
					self:go_to(danger_pos)
					return
				end
				local progress = type(record.progress) == "table" and record.progress or {}
				progress.arrived = type(progress.arrived) == "table" and progress.arrived or {}
				progress.arrived[self.inventory_name] = true
				local arrived = 0
				for _ in pairs(progress.arrived) do
					arrived = arrived + 1
				end
				collab.update(record.id, {progress = progress})
				if arrived >= #(record.participants or {}) then
					collab.complete(record.id, {secured_pos = vector.round(danger_pos)})
				end
				self:set_displayed_action("securise la zone")
				self:set_state_info("Je verifie la zone de l'alerte avec les autres gardes.")
				return
			end
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
