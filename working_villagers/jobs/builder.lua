local func = working_villages.require("jobs/util")
local co_command = working_villages.require("job_coroutines").commands
local blueprints = working_villages.blueprints
local unlimited_materials = minetest.settings:get_bool("working_villages_builder_unlimited_materials", true)
local experiment_mode = minetest.settings:get_bool("working_villages_builder_experiment_mode", true)
local experiment_interval = tonumber(minetest.settings:get("working_villages_builder_experiment_interval")) or 1800

local function find_building(p)
	if minetest.get_node(p).name ~= "working_villages:building_marker" then
		return false
	end
	local meta = minetest.get_meta(p)
	if meta:get_string("state") ~= "begun" then
		return false
	end
	local build_pos = working_villages.buildings.get_build_pos(meta)
	if build_pos == nil then
		return false
	end
	if working_villages.buildings.get(build_pos)==nil then
		return false
	end
	return true
end
local function is_liquid(pos)
	local node = minetest.get_node(pos)
	return minetest.get_item_group(node.name, "liquid") > 0
end

local function can_place_blueprint(base, nodes)
	for _, entry in ipairs(nodes) do
		if entry.pos and entry.node and entry.node.name then
			local target = vector.add(base, entry.pos)
			if is_liquid(target) then
				return false
			end
		end
	end
	return true
end

local function place_blueprint_nodes(nodes, base)
	local placed = {}
	for _, entry in ipairs(nodes) do
		if entry.pos and entry.node and entry.node.name then
			local target = vector.add(base, entry.pos)
			local old = minetest.get_node(target)
			local params = {
				name = entry.node.name,
				param1 = entry.node.param1 or 0,
				param2 = entry.node.param2 or 0,
			}
			minetest.set_node(target, params)
			table.insert(placed, {pos = target, old = old})
		end
	end
	return placed
end

local function attempt_experiment(self)
	if not experiment_mode then
		return false
	end
	self:count_timer("builder:experiment")
	if not self:timer_exceeded("builder:experiment", experiment_interval) then
		return false
	end

	local inv_name = self:get_inventory_name()
	local available = blueprints.get_available_to_improve(inv_name)
	local candidates = {}
	for name, improvement in pairs(available) do
		table.insert(candidates, {name = name, data = improvement})
	end
	if #candidates == 0 then
		return false
	end

	local choice = candidates[math.random(#candidates)]
	local blueprint_name = choice.name
	local blueprint = choice.data.blueprint
	local target_level = choice.data.current_level + 1
	local nodes = blueprints.apply_improvements(blueprint_name, target_level, blueprint.nodes or {})
	if #nodes == 0 then
		return false
	end

	local base = vector.round(self.object:get_pos())
	local ground = func.find_ground_below(base)
	if ground then
		base.y = ground.y
	end

	if not can_place_blueprint(base, nodes) then
		self:set_state_info("L'espace est trop humide ou dangereux pour une experience.")
		return false
	end

	local placed = place_blueprint_nodes(nodes, base)
	if not placed or #placed == 0 then
		return false
	end

	self.job_data.experiment_state = {
		blueprint = blueprint_name,
		level = target_level,
		nodes = placed,
		description = blueprint.description,
	}
	self:set_state_info("Je teste une version experimentale du plan " .. (blueprint.description or blueprint_name) .. ".")
	notify_owner_of_experiment(self, blueprint_name, blueprint.description)
	return true
end

local function notify_owner_of_experiment(self, blueprint_name, blueprint_desc)
	local msg = ("Je viens de tester une version experimentale de %s. Vois mes creations et utilise /villager_experiment accept ou /villager_experiment reject"):format(blueprint_desc or blueprint_name)
	self:notify_owner(msg)
end
local search_radius = tonumber(minetest.settings:get("working_villages_builder_search_radius")) or 30
local searching_range = {x = search_radius, y = 6, z = search_radius}

local function builder_take_from_chest(self, stack)
	if stack == nil or stack:is_empty() then
		return false
	end
	local def = minetest.registered_nodes[stack:get_name()]
	return def ~= nil
end

local function builder_put_to_chest(self, stack)
	-- Store building materials (registered nodes) in the chest to free up inventory space
	-- The builder will take what it needs when needed
	if stack == nil or stack:is_empty() then
		return false
	end
	-- Only store items that are registered nodes (building materials)
	local def = minetest.registered_nodes[stack:get_name()]
	return def ~= nil
end

local function get_active_marker(self)
	local marker = self:get_job_data("builder_marker")
	if marker and find_building(marker) then
		return marker
	end
	if marker then
		self:set_job_data("builder_marker", nil)
	end

	marker = func.search_surrounding(self.object:get_pos(), find_building, searching_range)
	if marker then
		self:set_job_data("builder_marker", marker)
	end
	return marker
end

working_villages.register_job("working_villages:job_builder", {
	description      = "constructeur (working_villages)",
	long_description = "Je cherche le marqueur de construction le plus proche avec un chantier demarre. "..
"La-bas j'aide a construire, si j'ai les materiaux. "..
"Je cherche aussi dans un rayon configurable. "..
"J'ignore les chantiers en pause.",
	inventory_image  = "default_paper.png^working_villages_builder.png",
	capabilities = {
		construction = true,
		blueprint_reading = true,
		material_management = true,
		experience_gain = true,
		blueprint_learning = true,
	},
	on_start = function(self)
		-- Notify player about builder capabilities
		self:notify_job_feature(
			"Construction et apprentissage",
			"Construit selon les plans, gagne de l'expérience, apprend de nouveaux plans"
		)
	end,
	jobfunc = function(self)
		self:handle_night()
		self:handle_job_pos()
		self:handle_chest(builder_take_from_chest, builder_put_to_chest)

		if self.job_data.experiment_state == nil and attempt_experiment(self) then
			return
		end

		self:count_timer("builder:search")
		self:count_timer("builder:announce")
		self:count_timer("builder:error_msg")
		if self:timer_exceeded("builder:search",20) then
			-- Reset chest interaction flag so builder can get materials again
			self.job_data.manipulated_chest = false
			local marker = get_active_marker(self)
			if marker == nil then
			 self:set_state_info("Je cherche un chantier proche.\nJe n'en ai pas trouve la derniere fois.")
			else
				local meta = minetest.get_meta(marker)
				local build_pos = working_villages.buildings.get_build_pos(meta)
        local building_on_pos = working_villages.buildings.get(build_pos)
				if building_on_pos.nodedata and (meta:get_int("index") > #building_on_pos.nodedata) then
				  self:set_state_info("Je termine un batiment.")
					local destination = func.find_adjacent_clear(marker)
					destination = func.find_ground_below(destination)
					if destination==false then
						print("failure: no adjacent walkable found")
						destination = marker
					end
					self:go_to(destination)
					meta:set_string("state","built")
					meta:set_string("house_label", "house " .. minetest.pos_to_string(marker))
					--TODO: save beds
					meta:set_string("formspec",working_villages.buildings.get_formspec(meta))
					
					-- Award experience for completing a building
					local inv_name = self:get_inventory_name()
					blueprints.add_experience(inv_name, 5)
					self:set_state_info("Construction terminee ! Experience gagnee.")
					self:set_job_data("builder_marker", nil)
					self:announce_action("J'ai termine la construction d'un batiment !", 30)
					-- Notify owner via HUD
					self:notify_owner("Construction terminee ! Votre constructeur a termine un batiment.")
					return
				end
				self:set_state_info("Je travaille sur un batiment.")
				if self:timer_exceeded("builder:announce", 180) then
					self:announce_action("Je construis un batiment petit a petit.")
				end
				local index = meta:get_int("index")
				local nnode = building_on_pos.nodedata and building_on_pos.nodedata[index]
				local skipped = 0
				while nnode and nnode.node do
					local candidate = working_villages.buildings.get_registered_nodename(nnode.node.name)
					if candidate ~= "air" then
						break
					end
					index = index + 1
					meta:set_int("index", index)
					nnode = building_on_pos.nodedata[index]
					skipped = skipped + 1
					if skipped >= 50 then
						return
					end
				end
				if nnode == nil then
					meta:set_int("index", meta:get_int("index") + 1)
					return
				end
				local npos = nnode.pos
				nnode = nnode.node
				local nname = working_villages.buildings.get_registered_nodename(nnode.name)
				if is_liquid(npos) then
					self:set_state_info("Le chantier est partiellement sous l'eau, je passe cette etape.")
					meta:set_int("index", meta:get_int("index") + 1)
					return
				end
				if nname == "air" then
					meta:set_int("index",meta:get_int("index")+1)
					return
				end
				local function is_material(name)
					return name == nname
				end
				local wield_stack = self:get_wield_item_stack()
				if (nname:find("beds:") or nname:find("mcl_beds:")) and nname:find("_top") then
					local inv = self:get_inventory()
					if inv:room_for_item("main", ItemStack(nname)) then
						inv:add_item("main", ItemStack(nname))
					else
						local msg = "constructeur a " .. minetest.pos_to_string(self.object:get_pos()) ..
							" n'a pas assez de place dans l'inventaire"
						if self.owner_name then
							minetest.chat_send_player(self.owner_name,msg)
						else
							print(msg)
						end
						-- Reset chest interaction to allow storing items in the chest
						self.job_data.manipulated_chest = false
						self:set_state_info("J'attends d'avoir de la place dans mon inventaire.")
						return co_command.pause, "attente de place inventaire"
					end
				end
				local torch_wall = working_villages.voxelibre_compat.get_item("default:torch_wall")
				local torch = working_villages.voxelibre_compat.get_item("default:torch")
				if nname==torch_wall then
					if unlimited_materials and not self:has_item_in_main(function (name) return name == torch end) then
						self:add_item_to_main(ItemStack(torch))
					end
					if self:has_item_in_main(function (name) return name == torch end) then
					  local inv = self:get_inventory()
					  if inv:room_for_item("main", ItemStack(nname)) then
						  self:replace_item_from_main(ItemStack(torch),ItemStack(nname))
					  else
              local msg = "constructeur a " .. minetest.pos_to_string(self.object:get_pos()) ..
                " n'a pas assez de place dans l'inventaire"
              if self.owner_name then
                minetest.chat_send_player(self.owner_name,msg)
              else
               print(msg)
              end
              -- Reset chest interaction to allow storing items in the chest
              self.job_data.manipulated_chest = false
              self:set_state_info("J'attends d'avoir de la place dans mon inventaire.")
              return co_command.pause, "attente de place inventaire"
				    end
					end
				end
				local has_material = is_material(wield_stack:get_name()) or self:has_item_in_main(is_material)
				if not has_material and unlimited_materials then
					local leftover = self:add_item_to_main(ItemStack(nname))
					if leftover:is_empty() then
						has_material = true
					else
						self:set_state_info("Je n'ai plus de place dans mon inventaire.")
						-- Reset chest interaction to allow storing items in the chest
						self.job_data.manipulated_chest = false
						return co_command.pause, "inventaire plein"
					end
				end
				if has_material then
					local destination = func.find_adjacent_clear(npos)
					--FIXME: check if the ground is actually below (get_reachable)
					destination = func.find_ground_below(destination)
					if destination==false then
						print("failure: no adjacent walkable found")
						destination = npos
					end
					self:set_state_info("Je construis.")
					self:go_to(destination)
					self:place(nnode,npos)
					local placed = minetest.get_node(npos).name
					local placed_canon = working_villages.buildings.get_registered_nodename(placed)
					local chest_ok = (minetest.get_item_group(placed, "chest") > 0 and
						minetest.get_item_group(nname, "chest") > 0)
					if chest_ok or placed_canon == nname or placed == nname or placed == nnode.name then
						meta:set_int("index",meta:get_int("index")+1)
					else
						-- Reset chest flag to allow getting materials from chest on next iteration
						self.job_data.manipulated_chest = false
						local msg = ("constructeur a %s a eu des difficultés avec %s, il reste en attente"):format(
							minetest.pos_to_string(self.object:get_pos()), nname)
						if self.owner_name then
							minetest.chat_send_player(self.owner_name, msg)
						else
							print(msg)
						end
					end
				else
					-- Reset chest flag to allow getting materials from chest
					self.job_data.manipulated_chest = false
					-- Only send error message occasionally to avoid spam
					if self:timer_exceeded("builder:error_msg", 60) then
						local msg = "constructeur a " .. minetest.pos_to_string(self.object:get_pos()) .. " n'a pas " .. nname
						if self.owner_name then
							minetest.chat_send_player(self.owner_name,msg)
						else
							print(msg)
						end
					end
					self:set_state_info(("J'attends que quelqu'un me donne %s."):format(nname))
					if self:timer_exceeded("builder:announce", 200) then
						self:announce_action(("J'ai besoin de %s pour continuer la construction."):format(nname))
					end
					coroutine.yield(co_command.pause,"attente de materiaux")
				end
			end
		end
	end,
})

local function find_owned_villager(player)
	local position = player:get_pos()
	local objects = minetest.get_objects_inside_radius(position, 12)
	for _, obj in ipairs(objects) do
		local lua = obj:get_luaentity()
		if lua and working_villages.is_villager(lua.name) and lua.owner_name == player:get_player_name() then
			return lua
		end
	end
	return nil
end

local function revert_experiment_state(state)
	if not state then
		return
	end
	for _, entry in ipairs(state.nodes or {}) do
		if entry.pos and entry.old then
			minetest.set_node(entry.pos, entry.old)
		end
	end
end

minetest.register_chatcommand("villager_experiment", {
	params = "<accept|reject>",
	description = "Accepte ou rejette la derniere creation experimentale du villageois proche",
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false, "Joueur introuvable"
		end

		local action = param:match("^%s*(%S+)")
		if not action or (action ~= "accept" and action ~= "reject") then
			return false, "Usage : /villager_experiment accept|reject"
		end

		local villager = find_owned_villager(player)
		if not villager then
			return false, "Aucun villageois a proximite qui est a vous"
		end

		local state = villager.job_data and villager.job_data.experiment_state
		if not state then
			return false, "Ce villageois n'a rien d'experimental en cours"
		end

		if action == "accept" then
			local inv_name = villager:get_inventory_name()
			local success = blueprints.force_improve(inv_name, state.blueprint)
			if success then
				blueprints.add_experience(inv_name, (state.level or 1) * 5)
				minetest.chat_send_player(name, "Plan approuve ! L'experience a ete enregistree.")
			else
				minetest.chat_send_player(name, "Impossible d'ameliorer ce plan.")
				return false, "Impossible d'ameliorer ce plan"
			end
		else
			revert_experiment_state(state)
			minetest.chat_send_player(name, "Experimentation annulee, la creation a ete remise a l'etat precedent.")
		end

		villager.job_data.experiment_state = nil
		return true, "Merci pour votre retour."
	end,
})
