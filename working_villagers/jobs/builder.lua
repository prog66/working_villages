local func = working_villages.require("jobs/util")
local inventory_access = working_villages.inventory_access or working_villages.require("inventory_access")
local farming_compat = working_villages.require("farming_compat")
local co_command = working_villages.require("job_coroutines").commands
local blueprints = working_villages.blueprints
local compat = working_villages.compat
local permissions = working_villages.permissions
local comm = working_villages.communication
local collab = working_villages.collaborative_tasks
local blueprint_construction = working_villages.blueprint_construction
local crafting = working_villages.crafting
local work_fallback = working_villages.work_fallback
local gameplay_mode = working_villages.gameplay_mode
if type(gameplay_mode) ~= "string" or gameplay_mode == "" then
	gameplay_mode = minetest.settings:get("working_villages_gameplay_mode") or "survival"
end
local creative_test_mode = gameplay_mode == "creative_test"
local unlimited_materials = creative_test_mode
	and minetest.settings:get_bool("working_villages_builder_unlimited_materials", false)
local experiment_mode = creative_test_mode
	and minetest.settings:get_bool("working_villages_builder_experiment_mode", false)
local experiment_interval = tonumber(minetest.settings:get("working_villages_builder_experiment_interval")) or 1800
local build_step_interval = tonumber(minetest.settings:get("working_villages_builder_step_interval")) or 1
local builder_claim_ttl = tonumber(minetest.settings:get("working_villages_builder_claim_ttl")) or 30
local builder_idle_search_interval = tonumber(minetest.settings:get("working_villages_builder_idle_search_interval")) or 2
local builder_material_batch_size = tonumber(minetest.settings:get("working_villages_builder_material_batch_size")) or 4
local CONSTRUCTION_LEDGER_KEY = "working_villages_construction_ledger_v1"

local function read_construction_ledger(meta, node_count)
	local encoded = meta:get_string(CONSTRUCTION_LEDGER_KEY)
	local ledger = encoded ~= "" and minetest.deserialize(encoded) or nil
	if type(ledger) ~= "table" or ledger.version ~= 1 then
		ledger = {
			version = 1,
			blueprint = meta:get_string("schematic"),
			node_count = node_count or 0,
			steps = {},
			items = {},
			totals = {
				consumed = 0,
				synthetic = 0,
				structural = 0,
				cleared = 0,
				reused = 0,
				liquid_skipped = 0,
				unlimited = 0,
				mismatches = 0,
			},
		}
	end
	ledger.steps = type(ledger.steps) == "table" and ledger.steps or {}
	ledger.items = type(ledger.items) == "table" and ledger.items or {}
	ledger.totals = type(ledger.totals) == "table" and ledger.totals or {}
	ledger.node_count = math.max(tonumber(node_count) or tonumber(ledger.node_count) or 0, 0)
	return ledger
end

local function record_construction_step(meta, node_count, index, kind, item_name, inventory_delta)
	if not meta or not index or index < 1 then
		return false
	end
	local ledger = read_construction_ledger(meta, node_count)
	local key = tostring(index)
	if ledger.steps[key] then
		return true
	end
	local step = {
		kind = kind,
		item = item_name or "",
		inventory_delta = tonumber(inventory_delta) or 0,
	}
	ledger.steps[key] = step
	ledger.totals[kind] = (tonumber(ledger.totals[kind]) or 0) + 1
	if item_name and item_name ~= "" then
		ledger.items[item_name] = (tonumber(ledger.items[item_name]) or 0)
			+ (kind == "consumed" and 1 or 0)
	end
	local expected_delta = (kind == "consumed" or kind == "synthetic") and 1 or 0
	if kind ~= "unlimited" and kind ~= "liquid_skipped"
			and tonumber(inventory_delta) ~= expected_delta then
		step.mismatch = true
		ledger.totals.mismatches = (tonumber(ledger.totals.mismatches) or 0) + 1
	end
	meta:set_string(CONSTRUCTION_LEDGER_KEY, minetest.serialize(ledger))
	return true
end

local function count_builder_material(self, item_name)
	if not self or not item_name or item_name == "" then
		return 0
	end
	local inventory = self:get_inventory()
	if not inventory then
		return 0
	end
	local total = 0
	for _, list_name in ipairs({"main", "wield_item"}) do
		for _, stack in ipairs(inventory:get_list(list_name) or {}) do
			if not stack:is_empty() and stack:get_name() == item_name then
				total = total + stack:get_count()
			end
		end
	end
	return total
end

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

local function builder_log(message, level)
	minetest.log(level or "action", "[working_villages][builder] " .. message)
end

local function get_build_destination(target_pos, origin)
	-- A construction target is normally air.  find_adjacent_clear() therefore
	-- returns the target itself first, making the builder stand inside the node
	-- it is about to place.  Use the interaction helper, which prefers cardinal
	-- standing positions, and never accept the target as a fallback.
	local destination = func.find_interaction_pos
		and func.find_interaction_pos(target_pos, origin) or false
	if not destination or destination == false then
		return nil
	end
	if vector.equals(vector.round(destination), vector.round(target_pos)) then
		return nil
	end
	return destination
end

local function pause_for_inventory_space(self)
	self.job_data.manipulated_chest = false
	self:set_state_info("J'attends d'avoir de la place dans mon inventaire.")
	self:set_displayed_action("inventaire plein")
	return co_command.pause, "attente de place inventaire"
end

local function pause_for_blocked_step(self, pos, message)
	local blocked_pos = pos and vector.round(pos) or nil
	if blocked_pos then
		working_villages.failed_pos_record(blocked_pos)
		if self.owner_name and self.owner_name ~= "" then
			self:notify_owner_event(
				("Etape de chantier inaccessible a %s."):format(minetest.pos_to_string(blocked_pos)),
				"builder:blocked_step:" .. minetest.hash_node_position(blocked_pos),
				180,
				"detailed"
			)
		end
	end
	self.job_data.manipulated_chest = false
	self:set_state_info(message or "Cette etape du chantier est inaccessible pour l'instant.")
	self:set_displayed_action("chantier bloque")
	return co_command.pause, "chantier inaccessible"
end

local function has_tool_group(self, group)
	local wield = self:get_wield_item_stack()
	if wield and minetest.get_item_group(wield:get_name(), group) > 0 then
		return true
	end
	local inv = self:get_inventory()
	for _, stack in ipairs(inv:get_list("main")) do
		if minetest.get_item_group(stack:get_name(), group) > 0 then
			return true
		end
	end
	return false
end

local function pick_tool_tier(self)
	local inv = self:get_inventory()
	if inv:contains_item("main", compat.get_item("default:steel_ingot")) then
		return "iron"
	end
	if inv:contains_item("main", compat.get_item("default:cobble")) then
		return "stone"
	end
	return "wood"
end

local function find_nearby_blacksmith(self, radius)
	local pos = self.object:get_pos()
	local objects = minetest.get_objects_inside_radius(pos, radius or 20)
	for _, obj in ipairs(objects) do
		local lua = obj:get_luaentity()
		if lua and working_villages.is_villager(lua.name) then
			if lua.owner_name == self.owner_name then
				local job_name = lua.get_job_name and lua:get_job_name() or ""
				if job_name == "working_villages:job_blacksmith" then
					return lua
				end
			end
		end
	end
	return nil
end

local function request_missing_tools(self)
	-- builder.lua is loaded before blacksmith.lua. Resolve the API at action
	-- time so a permanent nil captured during startup cannot suppress orders.
	local blacksmith = working_villages.blacksmith
	if not blacksmith or not blacksmith.enqueue_order then
		return
	end
	self.job_data = self.job_data or {}
	if self.job_data.tool_order_pending then
		local pending = self.job_data.tool_order_pending
		if (pending == "pick" and has_tool_group(self, "pickaxe"))
			or (pending == "axe" and has_tool_group(self, "axe"))
			or (pending == "shovel" and has_tool_group(self, "shovel")) then
			self.job_data.tool_order_pending = nil
		else
			return
		end
	end
	local missing
	if not has_tool_group(self, "pickaxe") then
		missing = "pick"
	elseif not has_tool_group(self, "axe") then
		missing = "axe"
	elseif not has_tool_group(self, "shovel") then
		missing = "shovel"
	end
	if not missing then
		return
	end
	local smith = find_nearby_blacksmith(self, 25)
	local tier = pick_tool_tier(self)
	local key = missing .. "_" .. tier
	if not smith then
		if blacksmith.enqueue_global_order then
			local ok = blacksmith.enqueue_global_order(key, 1, self.owner_name or "",
				self.inventory_name)
			if ok then
				self.job_data.tool_order_pending = missing
				self:set_state_info("J'ai demande un outil au forgeron (commande globale).")
			end
		end
		return
	end
	local ok = blacksmith.enqueue_order(smith, key, 1, self.owner_name or "",
		self.inventory_name)
	if ok then
		self.job_data.tool_order_pending = missing
		self:set_state_info("J'ai demande un outil au forgeron.")
	end
end

local function read_builder_claims(meta)
	local claims = minetest.deserialize(meta:get_string("builder_claims"))
	if type(claims) ~= "table" then
		return {}
	end
	return claims
end

local function write_builder_claims(meta, claims)
	if #claims == 0 then
		meta:set_string("builder_claims", "")
		return
	end
	meta:set_string("builder_claims", minetest.serialize(claims))
end

local function compact_builder_claims(claims, now, builder_id)
	local cleaned = {}
	local seen = {}
	for _, claim in ipairs(claims or {}) do
		if type(claim) == "table" then
			local claim_id = claim.id
			local claim_at = tonumber(claim.at) or 0
			if claim_id and claim_id ~= "" and not seen[claim_id] then
				if claim_id == builder_id or (now - claim_at) <= builder_claim_ttl then
					seen[claim_id] = true
					cleaned[#cleaned + 1] = {
						id = claim_id,
						at = claim_id == builder_id and now or claim_at,
					}
				end
			end
		end
	end
	return cleaned
end

local function can_claim_marker(self, marker)
	local meta = minetest.get_meta(marker)
	local claims = compact_builder_claims(read_builder_claims(meta), minetest.get_gametime(), self.inventory_name)
	for _, claim in ipairs(claims) do
		if claim.id == self.inventory_name then
			return true
		end
	end
	return #claims == 0
end

local function claim_marker(self, marker)
	if not marker or not find_building(marker) then
		return false
	end
	local meta = minetest.get_meta(marker)
	local now = minetest.get_gametime()
	local claims = compact_builder_claims(read_builder_claims(meta), now, self.inventory_name)
	for _, claim in ipairs(claims) do
		if claim.id == self.inventory_name then
			write_builder_claims(meta, claims)
			return true
		end
	end
	if #claims > 0 then
		write_builder_claims(meta, claims)
		return false
	end
	claims[#claims + 1] = {
		id = self.inventory_name,
		at = now,
	}
	write_builder_claims(meta, claims)
	return true
end

local function release_marker(self, marker)
	if not marker then
		return
	end
	local node = minetest.get_node_or_nil(marker)
	if not node or node.name ~= "working_villages:building_marker" then
		return
	end
	local meta = minetest.get_meta(marker)
	local claims = read_builder_claims(meta)
	local kept = {}
	for _, claim in ipairs(claims) do
		if type(claim) == "table" and claim.id ~= self.inventory_name then
			kept[#kept + 1] = claim
		end
	end
	write_builder_claims(meta, kept)
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

local house_blueprints = {
	minimal_shelter = true,
	minimal_house = true,
	simple_house = true,
	fancy_house = true,
}

local function ensure_starter_blueprint(self)
	local inv_name = self:get_inventory_name()
	local data = blueprints.get_villager_data(inv_name)
	if next(data.blueprints or {}) ~= nil then
		return
	end
	blueprints.force_teach(inv_name, "minimal_shelter")
	self.job_data = self.job_data or {}
	self.job_data.learning_note = "Plan de depart appris: minimal_shelter"
end

local function learn_blueprint_for_autonomy(self, blueprint_name)
	local inv_name = self:get_inventory_name()
	if blueprints.get_level(inv_name, blueprint_name) > 0 then
		return true
	end
	local ok, message = blueprints.teach(inv_name, blueprint_name)
	if ok then
		self.job_data = self.job_data or {}
		self.job_data.learning_note = "Plan appris avec experience: " .. blueprint_name
		return true
	end
	return false, message
end

local function count_blueprint_sites(village, blueprint_name)
	if not village or not village.buildings then
		return 0
	end
	return village.buildings[blueprint_name] or 0
end

local function choose_house_blueprint(village)
	local population = math.max(village.population or 0, 1)
	local wood = village.available_wood or village.wood or 0
	local food = (village.available_food or village.food or 0) + (village.available_raw_food or village.raw_food or 0)
	if wood >= 80 and food >= math.max(36, population * 4) then
		return "fancy_house"
	end
	if wood >= 40 and food >= math.max(20, population * 3) then
		return "simple_house"
	end
	if wood >= 24 and food >= math.max(12, population * 2) then
		return "minimal_house"
	end
	return "minimal_shelter"
end

local function count_material_in_inventory(self, item_name)
	if not item_name or item_name == "" then
		return 0
	end
	local total = 0
	local wield = self:get_wield_item_stack()
	if wield and wield:get_name() == item_name then
		total = total + wield:get_count()
	end
	for _, stack in ipairs(self:get_inventory():get_list("main") or {}) do
		if not stack:is_empty() and stack:get_name() == item_name then
			total = total + stack:get_count()
		end
	end
	return total
end

local function ensure_builder_material_stock(self, item_name, desired_count)
	if unlimited_materials or not item_name or item_name == "" then
		return count_material_in_inventory(self, item_name) > 0
	end
	desired_count = math.max(1, desired_count or builder_material_batch_size)
	-- Batch common wall/floor materials, but never manufacture four unique
	-- utilities for a schematic step which consumes exactly one.  The old
	-- generic batch made the first shelter wait for four beds (24 wheat and
	-- eight planks), then left three unused beds in village storage.
	if minetest.get_item_group(item_name, "bed") > 0
			or minetest.get_item_group(item_name, "villager_bed_bottom") > 0
			or minetest.get_item_group(item_name, "door") > 0
			or minetest.get_item_group(item_name, "chest") > 0
			or minetest.get_item_group(item_name, "furnace") > 0
			or compat.is_bed_bottom(item_name)
			or compat.is_door(item_name)
			or compat.is_chest(item_name)
			or compat.is_furnace(item_name) then
		desired_count = 1
	end
	local current = count_material_in_inventory(self, item_name)
	if current >= desired_count then
		return true
	end
	local missing = desired_count - current
	if self.take_from_shared_storage then
		self:take_from_shared_storage({[item_name] = missing})
	end
	current = count_material_in_inventory(self, item_name)
	if current >= desired_count then
		return true
	end
	if crafting then
		crafting.ensure_item(self, item_name, desired_count, {
			use_shared_storage = true,
			fail_cooldown = 8,
			max_depth = 5,
		})
		current = count_material_in_inventory(self, item_name)
	end
	return current > 0
end

local function get_builder_auto_site_interval(village)
	if not village then
		return 120
	end
	if (village.recent_danger or 0) > 0 then
		return 30
	end
	if (village.homeless or 0) > 0 then
		return 45
	end
	return 120
end

local function choose_autonomous_blueprint(self)
	local village = working_villages.get_village_status and working_villages.get_village_status(self, 50)
	if not village then
		return nil, nil, nil
	end

	if village.active_sites > 0 then
		return nil, nil, village
	end

	local counts = village.counts or {}
	local control = village.control or {}
	local focus = control.focus or "balanced"
	local bootstrap_stage = village.bootstrap_stage or working_villages.get_village_bootstrap_stage(village)
	local population = math.max(village.population or 0, 1)
	local available_wood = village.available_wood or village.wood or 0
	local available_food = (village.available_food or village.food or 0) + (village.available_raw_food or village.raw_food or 0)
	local available_raw_food = village.available_raw_food or village.raw_food or 0
	local available_ore = village.available_ore or village.ore or 0
	local available_tools = village.available_tools or village.tools or 0
	local guards = counts["working_villages:job_guard"] or 0
	local farmers = counts["working_villages:job_farmer"] or 0
	local blacksmiths = counts["working_villages:job_blacksmith"] or 0
	local miners = counts["working_villages:job_miner"] or 0
	local cooks = counts["working_villages:job_cook"] or 0
	local farms = count_blueprint_sites(village, "farm_plot") + count_blueprint_sites(village, "garden")
	local mine_entrances = count_blueprint_sites(village, "mine_entrance")
	local watchtowers = count_blueprint_sites(village, "watchtower")
	local workshops = count_blueprint_sites(village, "workshop")
	local forges = count_blueprint_sites(village, "blacksmith_forge")
	local target_houses = math.max(1, population)
	local growth_enabled = working_villages.setting_enabled("population_growth", true)
	local population_limit = math.max(5,
		tonumber(minetest.settings:get("working_villages_population_limit")) or 20)
	if growth_enabled and population < population_limit
			and available_food >= math.max(40, population * 10)
			and available_wood >= math.max(40, population * 8) then
		target_houses = target_houses + 1
	end
	local homeless = village.homeless or 0
	local low_food = available_food < math.max(24, population * 6)
	local low_cooked_food = available_raw_food < math.max(6, population * 2)
	local forced_blueprint = working_villages.normalize_blueprint_name(control.next_build or "")

	if forced_blueprint ~= "" then
		if blueprints.get(forced_blueprint) then
			return forced_blueprint, "ordre direct du joueur", village, true
		end
		if self.set_village_control then
			self:set_village_control({next_build = ""})
		end
	end

	if bootstrap_stage ~= "build" then
		return nil, "phase " .. working_villages.describe_bootstrap_stage(bootstrap_stage), village
	end

	if village.recent_danger > 0 and homeless > 0 and available_wood >= 12 then
		return "minimal_shelter", "mise a l'abri d'urgence", village
	end
	if village.recent_danger > 0 and (village.houses or 0) < target_houses
			and available_wood >= 24 and available_food >= math.max(8, population) then
		return choose_house_blueprint(village), "mise a l'abri du village", village
	end
	if village.recent_danger > 0 and watchtowers == 0 and available_wood >= 45 and (guards > 0 or population >= 4) then
		return "watchtower", "defense du village", village
	end
	if focus == "defense" and watchtowers == 0 and available_wood >= 35 and population >= 3 then
		return "watchtower", "priorite defense", village
	end
	if focus == "food" and farms < math.max(1, math.ceil(population / 3)) and available_wood >= 18 then
		return "farm_plot", "priorite nourriture", village
	end
	if focus == "housing" and ((village.homeless or 0) > 0 or (village.houses or 0) < target_houses)
			and available_wood >= 24 and available_food >= math.max(12, population * 2) then
		return choose_house_blueprint(village), "priorite logement", village
	end
	if focus == "industry" and miners > 0 and mine_entrances == 0 and available_wood >= 28 then
		return "mine_entrance", "priorite extraction", village
	end
	if focus == "industry" and blacksmiths > 0 and forges == 0 and available_wood >= 45 and available_ore >= math.max(8, population * 2) then
		return "blacksmith_forge", "priorite forge", village
	end
	if focus == "industry" and workshops == 0 and available_wood >= 45 and population >= 4 then
		return "workshop", "priorite artisanat", village
	end
	if farms < math.max(1, math.ceil(population / 4)) and available_wood >= 18 and (low_food or (farmers > 0 and low_cooked_food)) then
		return "farm_plot", "production de nourriture", village
	end
	if homeless > 0 then
		return choose_house_blueprint(village), "logement pour les sans-abri", village
	end
	if miners > 0 and mine_entrances == 0 and available_wood >= 26
			and (available_ore < math.max(14, population * 4) or population >= 4) then
		return "mine_entrance", "ouverture de la mine", village
	end
	if blacksmiths > 0 and forges == 0 and available_wood >= 45 and available_ore >= math.max(8, population * 2) then
		return "blacksmith_forge", "atelier de forge", village
	end
	if workshops == 0 and available_wood >= 50 then
		if cooks > 0 and (available_tools < math.max(6, population) or available_raw_food >= math.max(8, population * 2)) then
			return "workshop", "atelier pour l'artisanat", village
		end
		if population >= 5 and available_tools < math.max(6, population) then
			return "workshop", "stockage et outils", village
		end
	end
	if (village.houses or 0) < target_houses and available_wood >= 25 and available_food >= math.max(18, population * 3) then
		return choose_house_blueprint(village), "croissance du village", village
	end
	if watchtowers == 0 and guards > 0 and population >= 6 and available_wood >= 55 then
		return "watchtower", "surveillance preventive", village
	end

	return nil, nil, village
end

local function maybe_start_autonomous_site(self)
	if not blueprint_construction or not blueprint_construction.start_site then
		return false
	end
	if self.owner_name ~= "working_villages:self_employed" then
		if not (permissions and permissions.should_auto_accept and permissions.should_auto_accept(self)) then
			return false
		end
	end
	ensure_starter_blueprint(self)
	local blueprint_name, reason, village, forced_by_player = choose_autonomous_blueprint(self)
	if not blueprint_name then
		return false
	end
	local learned, learn_error = learn_blueprint_for_autonomy(self, blueprint_name)
	if not learned and not forced_by_player and village and (village.homeless or 0) > 0
			and blueprints.get_level(self:get_inventory_name(), "minimal_shelter") > 0 then
		blueprint_name = "minimal_shelter"
		reason = "apprentissage et logement de base"
		learned = true
	end
	if not learned then
		self.job_data = self.job_data or {}
		self.job_data.learning_note = "Plan bloque: " .. blueprint_name .. " (" ..
			(learn_error or "experience insuffisante") .. ")"
		self:set_state_info("Je dois gagner de l'experience avant de construire " .. blueprint_name .. ".")
		self:set_displayed_action("apprend un plan")
		return false
	end
	local ok, site_message = blueprint_construction.start_site(self, blueprint_name)
	if not ok then
		self.job_data = self.job_data or {}
		self.job_data.builder_site_failure = site_message or "terrain inadapte"
		self:set_displayed_action("cherche un terrain fiable")
		self:set_state_info("Je reporte le chantier : " .. self.job_data.builder_site_failure .. ".")
		return false
	end
	self.job_data.builder_site_failure = nil
	self.job_data = self.job_data or {}
	if house_blueprints[blueprint_name] then
		self.job_data.learning_note = "Chantier autonome: " .. blueprint_name .. " (maison)"
	else
		self.job_data.learning_note = "Chantier autonome: " .. blueprint_name
	end
	if forced_by_player and self.set_village_control then
		self:set_village_control({next_build = ""})
	end
	self:set_state_info("J'ouvre un nouveau chantier pour le village: " .. (reason or blueprint_name) .. ".")
	self:set_displayed_action("ouvre un chantier")
	self:announce_action("Je lance un nouveau chantier: " .. (reason or blueprint_name) .. ".", 180)
	self:notify_owner_event(
		("Nouveau chantier: %s."):format(reason or blueprint_name),
		"builder:new_site:" .. blueprint_name,
		180,
		"important"
	)
	return true
end

local function notify_owner_of_experiment(self, blueprint_name, blueprint_desc)
	local msg = ("Je viens de tester une version experimentale de %s. Vois mes creations et utilise /villager_experiment accept ou /villager_experiment reject"):format(blueprint_desc or blueprint_name)
	self:notify_owner_event(msg, "builder:experiment:" .. blueprint_name, 300, "important")
end

local function attempt_experiment(self, force)
	if not experiment_mode then
		return false
	end

	local approved_key
	local pending_key
	if self.job_data and self.job_data.permission_requests then
		for key, req in pairs(self.job_data.permission_requests) do
			if key:sub(1, 17) == "experiment_start:" then
				if req.status == "approved" then
					approved_key = key
					break
				elseif req.status == "pending" then
					pending_key = key
				end
			end
		end
	end

	if pending_key then
		self:set_state_info("J'attends l'autorisation pour experimenter.")
		self:set_displayed_action("attente d'autorisation")
		return false
	end

	if not approved_key and not force then
		self:count_timer("builder:experiment")
		if not self:seconds_exceeded("builder:experiment", experiment_interval) then
			return false
		end
	end

	local blueprint_name
	local blueprint
	local target_level
	local permission_key

	if approved_key then
		blueprint_name = approved_key:sub(18)
		blueprint = blueprints.get(blueprint_name)
		if not blueprint then
			return false
		end
		local current_level = blueprints.get_level(self:get_inventory_name(), blueprint_name)
		if current_level >= (blueprint.max_level or 1) then
			return false
		end
		target_level = current_level + 1
		permission_key = approved_key
	else
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
		blueprint_name = choice.name
		blueprint = choice.data.blueprint
		target_level = choice.data.current_level + 1
		permission_key = "experiment_start:" .. blueprint_name
		local request_msg = ("Puis-je demarrer une experimentation sur %s ?"):format(
			blueprint.description or blueprint_name)
		if not permissions.request(self, permission_key, request_msg, { blueprint = blueprint_name }) then
			self:set_state_info("J'attends l'autorisation pour experimenter.")
			self:set_displayed_action("attente d'autorisation")
			return false
		end
	end

	if self.job_data and self.job_data.permission_requests then
		self.job_data.permission_requests[permission_key] = nil
	end
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

local search_radius = tonumber(minetest.settings:get("working_villages_builder_search_radius")) or 30
local searching_range = {x = search_radius, y = 6, z = search_radius}
local builder_item_range = {x = 6, y = 2, z = 6}

local function get_pending_builder_material(self)
	local marker = self:get_job_data("builder_marker")
	if not marker or not find_building(marker) then
		return nil
	end
	local meta = minetest.get_meta(marker)
	local build_pos = working_villages.buildings.get_build_pos(meta)
	local building = build_pos and working_villages.buildings.get(build_pos) or nil
	local index = meta:get_int("index")
	local entry = building and building.nodedata and building.nodedata[index] or nil
	local node = entry and entry.node or nil
	if not node or not node.name then
		return nil
	end
	local name = working_villages.buildings.get_registered_nodename(node.name)
	if name == "air" or compat.is_bed_top(name) then
		return nil
	end
	local torch_items = compat.get_torch_items()
	if name == torch_items.wall then
		return torch_items.floor
	end
	return name
end

local function builder_take_from_chest(self, stack)
	if stack == nil or stack:is_empty() then
		return false
	end
	-- The old broad predicate took every registered node from shared storage,
	-- including the miner's furnace cobble, even while no construction existed.
	-- Construction already knows its exact next material and can also fetch it
	-- through ensure_builder_material_stock; chest visits must follow that same
	-- demand instead of turning the builder into a general storage vacuum.
	local required = get_pending_builder_material(self)
	return required ~= nil
		and stack:get_name() == required
		and count_material_in_inventory(self, required) < builder_material_batch_size
end

local function builder_put_to_chest(self, stack)
	-- Store building materials (registered nodes) in the chest to free up inventory space
	-- The builder will take what it needs when needed
	if stack == nil or stack:is_empty() then
		return false
	end
	local required = get_pending_builder_material(self)
	if required and stack:get_name() == required
			and count_material_in_inventory(self, required) <= builder_material_batch_size then
		return false
	end
	-- Only store items that are registered nodes (building materials)
	local def = minetest.registered_nodes[stack:get_name()]
	return def ~= nil
end

working_villages.builder_material_handling = {
	get_pending_material = get_pending_builder_material,
	should_take_from_chest = builder_take_from_chest,
	should_put_in_chest = builder_put_to_chest,
}

local function is_clearable_node(name)
	if name == "air" or name == "ignore" then
		return false
	end
	if name == "working_villages:building_marker" then
		return false
	end
	if minetest.get_item_group(name, "chest") > 0 then
		return false
	end
	if minetest.get_item_group(name, "bed") > 0 then
		return false
	end
	if minetest.get_item_group(name, "door") > 0 then
		return false
	end
	return true
end

local function required_tool_group(node_name)
	local def = minetest.registered_nodes[node_name]
	if not def or not def.groups then
		return nil
	end
	-- VoxeLibre uses its native *y dig groups; Minetest Game uses the legacy
	-- cracky/choppy/crumbly families. Keep the profession-facing tool names
	-- stable because inventories and blacksmith orders use those groups.
	if (def.groups.pickaxey or 0) > 0 or (def.groups.cracky or 0) > 0 then
		return "pickaxe"
	end
	if (def.groups.axey or 0) > 0 or (def.groups.choppy or 0) > 0 then
		return "axe"
	end
	if (def.groups.shovely or 0) > 0 or (def.groups.crumbly or 0) > 0 then
		return "shovel"
	end
	return nil
end

local function stack_can_dig_node(stack, node_name, tool_group)
	if not stack or stack:is_empty() then
		return false
	end
	if tool_group and minetest.get_item_group(stack:get_name(), tool_group) <= 0 then
		return false
	end
	local def = minetest.registered_nodes[node_name]
	if not def or def.diggable == false then
		return false
	end
	local capabilities = stack:get_tool_capabilities()
	if not capabilities then
		return false
	end
	local params = minetest.get_dig_params(
		def.groups or {}, capabilities, stack:get_wear())
	return params ~= nil and params.diggable == true
end

local function effective_wield_stack(self)
	local wield = self:get_wield_item_stack()
	if wield and not wield:is_empty() then
		return wield
	end
	if working_villages.get_intrinsic_hand_stack then
		return working_villages.get_intrinsic_hand_stack()
	end
	return wield
end

-- Select by the engine's real dig result, not merely by an item group. This
-- prevents a carried but under-tier tool from being wielded forever while
-- self:dig() rejects it on every construction step.
local function equip_capable_tool(self, node_name, tool_group)
	if stack_can_dig_node(effective_wield_stack(self), node_name, tool_group) then
		return true
	end
	local inv = self:get_inventory()
	local capable_names = {}
	for _, stack in ipairs(inv:get_list("main") or {}) do
		if stack_can_dig_node(stack, node_name, tool_group) then
			capable_names[stack:get_name()] = true
		end
	end
	if not next(capable_names) or not self.move_main_to_wield then
		return false
	end
	local moved = self:move_main_to_wield(function(name)
		return capable_names[name] == true
	end)
	return moved == true
		and stack_can_dig_node(effective_wield_stack(self), node_name, tool_group)
end

local function minimum_capable_tool_tier(node_name, tool_group)
	for _, tier in ipairs({"wood", "stone", "iron", "gold", "diamond"}) do
		local item_name = compat.get_tool_item(tool_group, tier)
		if item_name and stack_can_dig_node(ItemStack(item_name), node_name, tool_group) then
			return tier
		end
	end
	return nil
end

local function capability_request_due(self, tool_group, node_name)
	if not node_name then
		return true
	end
	self.job_data = self.job_data or {}
	local now = tonumber(minetest.get_gametime()) or 0
	local key = tool_group .. "|" .. node_name
	local previous = self.job_data.builder_capable_tool_request
	if type(previous) == "table" and previous.key == key then
		local requested_at = tonumber(previous.at)
		if requested_at and now >= requested_at and now - requested_at < 30 then
			return false
		end
	end
	self.job_data.builder_capable_tool_request = {key = key, at = now}
	return true
end

local function request_tool_group(self, tool_group, node_name)
	if not tool_group then
		return false
	end
	if node_name and equip_capable_tool(self, node_name) then
		self.job_data.builder_capable_tool_request = nil
		return true
	end
	if not node_name and has_tool_group(self, tool_group) then
		return true
	end
	self.job_data = self.job_data or {}
	if not capability_request_due(self, tool_group, node_name) then
		return false
	end
	local key_map = {pickaxe = "pick", axe = "axe", shovel = "shovel"}
	local key = key_map[tool_group]
	if not key then
		return false
	end
	local tier = node_name and minimum_capable_tool_tier(node_name, tool_group)
		or pick_tool_tier(self)
	tier = tier or pick_tool_tier(self)
	local smith = find_nearby_blacksmith(self, 25)
	local blacksmith = working_villages.blacksmith
	local ordered = false
	if smith and blacksmith and blacksmith.enqueue_order then
		ordered = blacksmith.enqueue_order(smith, key .. "_" .. tier, 1,
			self.owner_name or "", self.inventory_name) == true
	end
	if (not ordered) and blacksmith and blacksmith.enqueue_global_order then
		ordered = blacksmith.enqueue_global_order(key .. "_" .. tier, 1,
			self.owner_name or "", self.inventory_name) == true
	end
	if not ordered and comm then
		comm.broadcast(self, comm.list_loaded_villagers(), "help_needed", {
			tool_group = tool_group,
			requester_id = self.inventory_name,
		})
	end
	self.job_data.tool_order_pending = key
	return ordered
end

working_villages.builder_tool_selection = {
	required_tool_group = required_tool_group,
	stack_can_dig_node = stack_can_dig_node,
	equip_capable_tool = equip_capable_tool,
	minimum_capable_tool_tier = minimum_capable_tool_tier,
}

local function is_food_item(name)
	return minetest.get_item_group(name, "food") > 0
end

local function is_wood_item(name)
	if not name or name == "" then
		return false
	end
	if minetest.get_item_group(name, "tree") > 0 then
		return true
	end
	if minetest.get_item_group(name, "wood") > 0 then
		return true
	end
	return name:find("wood", 1, true) ~= nil
		or name:find("tree", 1, true) ~= nil
		or name:find("log", 1, true) ~= nil
end

local function is_ore_item(name)
	return compat.is_ore_item(name)
end

local function is_raw_food_item(name)
	if not name or name == "" then
		return false
	end
	if minetest.get_item_group(name, "food_raw") > 0 then
		return true
	end
	local cooked = minetest.get_craft_result({
		method = "cooking",
		width = 1,
		items = {ItemStack(name)},
	})
	return cooked and cooked.item and not cooked.item:is_empty()
		and minetest.get_item_group(cooked.item:get_name(), "food") > 0
end

local function get_builder_bootstrap_stage(self)
	if not working_villages.get_village_status then
		return "build"
	end
	local village = working_villages.get_village_status(self, 40)
	if not village then
		return "build"
	end
	return village.bootstrap_stage or working_villages.get_village_bootstrap_stage(village)
end

local function matches_bootstrap_supply(stage, name)
	if stage == "wood" or stage == "storage" then
		return is_wood_item(name)
	end
	if stage == "food" then
		return is_food_item(name) or is_raw_food_item(name)
	end
	if stage == "tools" or stage == "defense" then
		return is_wood_item(name) or is_food_item(name) or is_raw_food_item(name) or is_ore_item(name)
	end
	return false
end

local function get_bootstrap_storage_access(self)
	local storage_pos = working_villages.get_shared_storage_pos
		and working_villages.get_shared_storage_pos(self.owner_name) or nil
	if (not storage_pos or not func.is_chest(storage_pos)) and self.pos_data then
		storage_pos = self.pos_data.storage_pos
	end
	if not storage_pos or not func.is_chest(storage_pos) then
		return nil, nil, nil
	end
	local meta = minetest.get_meta(storage_pos)
	local chest_inv = meta and meta:get_inventory() or nil
	if not chest_inv then
		return nil, nil, nil
	end
	local access_pos = func.find_adjacent_clear(storage_pos)
	if not access_pos then
		return nil, nil, nil
	end
	access_pos = func.find_ground_below(access_pos) or access_pos
	return vector.round(storage_pos), access_pos, chest_inv
end

local function deposit_bootstrap_supplies(self, stage)
	local storage_pos, access_pos, chest_inv = get_bootstrap_storage_access(self)
	if not storage_pos or not chest_inv then
		return false
	end

	local inv = self:get_inventory()
	local slots = {}
	for i = 1, inv:get_size("main") do
		local stack = inv:get_stack("main", i)
		if not stack:is_empty() and matches_bootstrap_supply(stage, stack:get_name()) then
			table.insert(slots, i)
		end
	end
	if #slots == 0 then
		return false
	end

	if access_pos and not self:is_near(access_pos, 2) then
		self:set_displayed_action("ravitaille le coffre")
		self:set_state_info("Je rapporte des ressources utiles au coffre commun.")
		self:go_to(access_pos)
		return true
	end

	local moved = 0
	for _, index in ipairs(slots) do
		local stack = inv:get_stack("main", index)
		if not stack:is_empty() then
			local transferred = inventory_access.put_from_inventory(
				self, inv, "main", index, storage_pos, "main", nil, 20 - moved)
			if transferred > 0 then
				moved = moved + transferred
				if moved >= 20 then
					break
				end
			end
		end
	end

	if moved > 0 then
		self:set_displayed_action("ravitaille le coffre")
		self:set_state_info("Je depose des ressources pour accelerer le bootstrap du village.")
		return true
	end

	return false
end

local function find_bootstrap_tree(self, pos)
	local node = minetest.get_node(pos)
	if minetest.get_item_group(node.name, "tree") <= 0 then
		return false
	end
	if func.is_protected(self, pos) then
		return false
	end
	if working_villages.failed_pos_test(pos) then
		return false
	end
	return true
end

local function find_bootstrap_crop(self, pos)
	if not farming_compat.is_plant_node(pos) then
		return false
	end
	if func.is_protected(self, pos) then
		return false
	end
	if working_villages.failed_pos_test(pos) then
		return false
	end
	return true
end

local function harvest_bootstrap_crop(self, target)
	local destination = func.find_adjacent_clear(target)
	if destination then
		destination = func.find_ground_below(destination)
	end
	if destination == false then
		destination = target
	end
	self:set_displayed_action("recolte des provisions")
	self:set_state_info("Je recolte de quoi nourrir le village avant le premier chantier.")
	local success = self:go_to(destination)
	if not success then
		working_villages.failed_pos_record(target)
		return false
	end
	local plant_name = minetest.get_node(target).name
	local plant_data = farming_compat.get_plant(plant_name)
	success = self:dig(target, true)
	if not success then
		working_villages.failed_pos_record(target)
		return false
	end
	if plant_data and plant_data.replant then
		for index, value in ipairs(plant_data.replant) do
			self:place(value, vector.add(target, vector.new(0, index - 1, 0)))
		end
	end
	return true
end

local function chop_bootstrap_tree(self, target)
	local destination = func.find_adjacent_clear(target)
	if destination then
		destination = func.find_ground_below(destination)
	end
	if destination == false then
		destination = target
	end
	self:set_displayed_action("coupe du bois")
	self:set_state_info("Je prepare du bois pour le coffre commun.")
	local success = self:go_to(destination)
	if not success then
		working_villages.failed_pos_record(target)
		return false
	end
	success = self:dig(target, true)
	if not success then
		working_villages.failed_pos_record(target)
		return false
	end
	return true
end

local function collect_bootstrap_drop(self, stage)
	if not self:collect_nearest_item_by_condition(function(item)
		return matches_bootstrap_supply(stage, item and item.name or "")
	end, builder_item_range) then
		return false
	end
	local label = working_villages.describe_bootstrap_stage and working_villages.describe_bootstrap_stage(stage) or stage
	self:set_displayed_action("ramasse des fournitures")
	self:set_state_info(("Je recupere des ressources utiles pour la phase %s."):format(label))
	return true
end

local function assist_bootstrap_phase(self, stage)
	if stage == "build" then
		return false
	end

	if deposit_bootstrap_supplies(self, stage) then
		return true
	end

	local target
	if stage == "food" then
		target = func.search_surrounding(
			self.object:get_pos(),
			function(pos) return find_bootstrap_crop(self, pos) end,
			searching_range
		)
		if target and harvest_bootstrap_crop(self, target) then
			return true
		end
		if collect_bootstrap_drop(self, stage) then
			return true
		end
		target = func.search_surrounding(
			self.object:get_pos(),
			function(pos) return find_bootstrap_tree(self, pos) end,
			searching_range
		)
		if target and chop_bootstrap_tree(self, target) then
			return true
		end
		return false
	end

	if not has_tool_group(self, "axe") then
		request_tool_group(self, "axe")
	end

	target = func.search_surrounding(
		self.object:get_pos(),
		function(pos) return find_bootstrap_tree(self, pos) end,
		searching_range
	)
	if target and chop_bootstrap_tree(self, target) then
		return true
	end

	if collect_bootstrap_drop(self, stage) then
		return true
	end

	target = func.search_surrounding(
		self.object:get_pos(),
		function(pos) return find_bootstrap_crop(self, pos) end,
		searching_range
	)
	if target and harvest_bootstrap_crop(self, target) then
		return true
	end

	return false
end

local function get_active_marker(self)
	local marker = self:get_job_data("builder_marker")
	if marker and find_building(marker) then
		if claim_marker(self, marker) then
			return marker
		end
	end
	if marker then
		release_marker(self, marker)
		self:set_job_data("builder_marker", nil)
	end

	self.job_data = self.job_data or {}
	local now = minetest.get_gametime()
	local next_search_at = tonumber(self.job_data.builder_next_search_at) or 0
	if now < next_search_at then
		return nil
	end
	self.job_data.builder_next_search_at = now + builder_idle_search_interval

	marker = func.search_surrounding(self.object:get_pos(), function(pos)
		return find_building(pos) and can_claim_marker(self, pos)
	end, searching_range)
	if marker and claim_marker(self, marker) then
		self:set_job_data("builder_marker", marker)
		return marker
	end
	return nil
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
		ensure_starter_blueprint(self)
		-- Notify player about builder capabilities
		self:notify_job_feature(
			"Construction et apprentissage",
			"Construit selon les plans, gagne de l'expérience, apprend de nouveaux plans"
		)
	end,
	jobfunc = function(self)
		if self.equip_best_weapon then self:equip_best_weapon() end
		if self.equip_best_armor then self:equip_best_armor() end
		self:handle_night()
		self:handle_job_pos()
		if not unlimited_materials then
			self:handle_chest(builder_take_from_chest, builder_put_to_chest)
		end

	if self.job_data.experiment_state == nil then
		local force = self.job_data.force_experiment
		if force then
			self.job_data.force_experiment = nil
		end
		if attempt_experiment(self, force) then
			return
		end
	end

		self:count_timer("builder:search")
		self:count_timer("builder:announce")
		self:count_timer("builder:error_msg")
		self:count_timer("builder:tool_request")
		local builder_search_interval = build_step_interval
		if self:get_job_data("builder_marker") then
			builder_search_interval = math.max(0.2, math.min(build_step_interval, 2))
		end
		if self:timer_exceeded("builder:tool_request", 80) then
			request_missing_tools(self)
		end
		if self:seconds_exceeded("builder:search", builder_search_interval) then
			-- Reset chest interaction flag so builder can get materials again
			self.job_data.manipulated_chest = false
			local marker = get_active_marker(self)
			if marker == nil then
				local village_status = working_villages.get_village_status and working_villages.get_village_status(self, 40) or nil
				local bootstrap_stage = get_builder_bootstrap_stage(self)
				if bootstrap_stage ~= "build" and assist_bootstrap_phase(self, bootstrap_stage) then
					return
				end
				if bootstrap_stage ~= "build" then
					self:set_displayed_action("soutien logistique")
					self:set_state_info(("Je soutiens le village pendant la phase %s avant d'ouvrir un nouveau chantier.")
						:format(working_villages.describe_bootstrap_stage(bootstrap_stage)))
				else
					self:set_state_info("Je cherche un chantier proche.\nJe n'en ai pas trouve la derniere fois.")
				end
				self:count_timer("builder:auto_site")
				if bootstrap_stage == "build" and self:timer_exceeded("builder:auto_site", get_builder_auto_site_interval(village_status)) then
					if maybe_start_autonomous_site(self) then
						return
					end
				end
			else
				local meta = minetest.get_meta(marker)
				local build_pos = working_villages.buildings.get_build_pos(meta)
        local building_on_pos = working_villages.buildings.get(build_pos)
				local node_count = building_on_pos.nodedata and #building_on_pos.nodedata or 0
				if node_count == 0 then
					self:set_state_info("Le plan est vide ou invalide, je ne peux pas construire.")
					self:set_displayed_action("plan invalide")
					release_marker(self, marker)
					self:set_job_data("builder_marker", nil)
					local build_hash = minetest.hash_node_position(build_pos)
					if self.job_data.invalid_plan_hash ~= build_hash then
						self.job_data.invalid_plan_hash = build_hash
						if self.owner_name and self.owner_name ~= "" then
							self:notify_owner_event(
								("Plan vide ou invalide au chantier %s."):format(minetest.pos_to_string(build_pos)),
								"builder:invalid_plan:" .. build_hash,
								0,
								"important"
							)
						else
							builder_log("Constructeur bloque par un plan vide ou invalide a " .. minetest.pos_to_string(build_pos), "warning")
						end
					end
					return
				end
				if meta:get_int("index") > node_count then
				  self:set_state_info("Je termine un batiment.")
					local destination = get_build_destination(marker, self.object:get_pos())
					if destination then
						self:go_to(destination)
					end
					meta:set_string("state","built")
					meta:set_string("house_label", "house " .. minetest.pos_to_string(marker))
					meta:set_string("infotext", meta:get_string("house_label"))
					local has_bed, has_door = false, false
					if working_villages.buildings and working_villages.buildings.autofill_home_metadata then
						has_bed, has_door = working_villages.buildings.autofill_home_metadata(meta, marker)
					end
					if working_villages.sync_construction_site_registry then
						working_villages.sync_construction_site_registry(marker)
					end
					if has_bed and has_door and working_villages.assign_home_to_nearest_homeless then
						working_villages.assign_home_to_nearest_homeless(self.owner_name, marker)
					end
					meta:set_string("formspec",working_villages.buildings.get_formspec(meta))
					
					-- Award experience for completing a building
					local inv_name = self:get_inventory_name()
					blueprints.add_experience(inv_name, 5)
					if blueprint_construction and blueprint_construction.auto_learn_if_ready then
						blueprint_construction.auto_learn_if_ready(inv_name)
					end
					self:set_state_info("Construction terminee ! Experience gagnee.")
					if collab and self.job_data and self.job_data.collab_task then
						local record = collab.get(self.job_data.collab_task)
						if record and record.state == "active" and record.name == "large_building" then
							collab.complete(record.id, {
								build_pos = build_pos,
								marker_pos = vector.round(marker),
							})
						end
					end
					release_marker(self, marker)
					self:set_job_data("builder_marker", nil)
					self:announce_action("J'ai termine la construction d'un batiment !", 30)
					self:notify_owner_event(
						(has_bed and has_door)
							and "Construction terminee ! Maison configuree avec lit et acces."
							or "Construction terminee ! Verifiez le lit ou l'acces du marqueur de maison.",
						"builder:construction_complete",
						30,
						"important"
					)
					return
				end
				self:set_state_info("Je travaille sur un batiment.")
				if self:timer_exceeded("builder:announce", 180) then
					self:announce_action("Je construis un batiment petit a petit.")
				end
				self:count_timer("builder:collab")
				if collab and self:timer_exceeded("builder:collab", 300) then
					local size = building_on_pos.nodedata and #building_on_pos.nodedata or 0
					if size >= 200 then
						collab.start_task("large_building", self, {
							build_pos = build_pos,
							size = size,
						})
					end
				end
				local index = meta:get_int("index")
				local nnode = building_on_pos.nodedata and building_on_pos.nodedata[index]
				local cleared_air = 0
				while nnode and nnode.node do
					local planned_name = working_villages.buildings.get_registered_nodename(
						nnode.node.name)
					if planned_name ~= "air" or func.is_protected(self, nnode.pos)
							or minetest.get_node(nnode.pos).name ~= "air" then
						break
					end
					record_construction_step(meta, node_count, index, "cleared", "air", 0)
					index = index + 1
					meta:set_int("index", index)
					nnode = building_on_pos.nodedata[index]
					cleared_air = cleared_air + 1
					if cleared_air >= 50 then
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
				if func.is_protected(self, npos) then
					self:set_displayed_action("chantier protege")
					self:set_state_info("Cette etape est dans une zone protegee, je ne la modifierai pas.")
					if self.owner_name and self:timer_exceeded("builder:protected_notice", 120) then
						self:notify_owner_event(
							"Le chantier traverse une zone protegee et reste en attente.",
							"builder:protected_site",
							120,
							"important"
						)
					end
					return co_command.pause, "zone protegee"
				end
				local current_node = minetest.get_node(npos)
				local current_def = minetest.registered_nodes[current_node.name]
				if nname == "air" then
					if current_node.name == "air" then
						record_construction_step(meta, node_count, index, "cleared", "air", 0)
						meta:set_int("index", index + 1)
						return
					end
					if current_def and current_def.buildable_to and not is_liquid(npos) then
						local destination = get_build_destination(npos, self.object:get_pos())
						if not destination then
							return pause_for_blocked_step(self, npos,
								"Je ne trouve pas d'acces pour degager l'interieur du chantier.")
						end
						self:set_displayed_action("degage le chantier")
						self:set_state_info("Je degage le volume interieur avant de construire.")
						if vector.distance(self.object:get_pos(), destination) > 5 then
							self:go_to(destination)
							return
						end
						-- Grass and flowers should not make an entire construction turn
						-- wait through the full hard-block mining animation.
						local dug = self:dig(npos, true, 0)
						if dug and minetest.get_node(npos).name == "air" then
							record_construction_step(meta, node_count, index, "cleared", current_node.name, 0)
							meta:set_int("index", index + 1)
						end
						return
					end
					return pause_for_blocked_step(self, npos,
						"Le volume interieur du chantier est occupe; je refuse de l'emmurer.")
				end
				if is_liquid(npos) then
					self:set_state_info("Le chantier a ete envahi par un liquide; je le mets en attente.")
					return pause_for_blocked_step(self, npos,
						"Un liquide bloque cette etape du chantier.")
				end
				local current_canon = working_villages.buildings.get_registered_nodename(current_node.name)
				local already_placed = current_node.name == nname or current_canon == nname
					or working_villages.buildings.node_matches_schematic(nnode.name, current_node.name)
				if not already_placed and current_def then
					already_placed = (minetest.get_item_group(current_node.name, "chest") > 0
							and minetest.get_item_group(nname, "chest") > 0)
						or (minetest.get_item_group(current_node.name, "fence") > 0
							and minetest.get_item_group(nname, "fence") > 0)
				end
				if already_placed then
					record_construction_step(meta, node_count, index, "reused", nname, 0)
					meta:set_int("index", meta:get_int("index") + 1)
					return
				end
				if current_def and not current_def.buildable_to and current_node.name ~= nname then
					if is_clearable_node(current_node.name) or (current_def and current_def.diggable ~= false) then
						local tool_group = required_tool_group(current_node.name)
						if not equip_capable_tool(self, current_node.name) then
							if not tool_group then
								return pause_for_blocked_step(self, npos,
									"Aucun de mes outils ne peut enlever cet obstacle de chantier.")
							end
							local tool_labels = {
								pickaxe = "une pioche",
								axe = "une hache",
								shovel = "une pelle",
							}
							local fallback_key = "builder_" .. tool_group
							local ready = work_fallback.ensure_tool(self, {
								key = fallback_key,
								tool_group = tool_group,
								tool_label = tool_labels[tool_group] or "un outil",
								candidates = compat.get_tool_items(tool_group, {"iron", "stone", "wood"}),
								request = function(villager)
									return request_tool_group(villager, tool_group, current_node.name)
								end,
								request_cooldown = 30,
								wait_info = "Il me faut " .. (tool_labels[tool_group] or "un outil") ..
									" pour preparer ce terrain. Je collecte des fournitures en attendant.",
							})
							ready = ready and equip_capable_tool(self, current_node.name)
							if not ready then
								-- A same-family tool may still be too weak for this exact
								-- node. Order the cheapest registered tier whose real engine
								-- capabilities pass get_dig_params().
								request_tool_group(self, tool_group, current_node.name)
								local performed = work_fallback.perform(self, {
									key = fallback_key,
									tool_group = tool_group,
									tool_label = tool_labels[tool_group] or "un outil",
									activity_action = "ramasse des materiaux",
									activity_info = "Je rassemble des materiaux sans abandonner mon chantier.",
									patrol_action = "inspecte le chantier",
									patrol_info = "J'inspecte le chantier et reverifie l'arrivee de mon outil.",
								})
								if not performed then
									self:set_displayed_action("attend un outil adapte")
									self:set_state_info("Mon outil actuel ne peut pas enlever cet obstacle; j'attends un outil adapte.")
								end
								return
							end
						end
						self.job_data.builder_capable_tool_request = nil
						local destination = get_build_destination(npos, self.object:get_pos())
						if not destination then
							return pause_for_blocked_step(self, npos, "Je n'arrive pas a atteindre cette etape pour preparer le terrain.")
						end
						self:set_state_info("Je prepare le terrain.")
						self:go_to(destination)
						self:dig(npos, true)
						return
					end
				end
				local function is_material(name)
					return name == nname
				end
				local wield_stack = self:get_wield_item_stack()
				-- A bed item represents both structural halves. The schematic places
				-- them as two nodes, so synthesize at most one non-inventory top half
				-- after the bottom has consumed the real bed item. Never add another
				-- copy on a blocked/retried construction step.
				if compat.is_bed_top(nname)
						and not is_material(wield_stack:get_name())
						and not self:has_item_in_main(is_material) then
					local inv = self:get_inventory()
					if inv:room_for_item("main", ItemStack(nname)) then
						inv:add_item("main", ItemStack(nname))
					else
						if self.owner_name and self.owner_name ~= "" then
							self:notify_owner_event(
								"Inventaire plein, impossible de preparer la pose du chantier.",
								"builder:inventory_full",
								120,
								"detailed"
							)
						end
						return pause_for_inventory_space(self)
					end
				end
				local torch_items = compat.get_torch_items()
				if nname == torch_items.wall then
					if not unlimited_materials then
						ensure_builder_material_stock(self, torch_items.floor, builder_material_batch_size)
					end
					if unlimited_materials and not self:has_item_in_main(function (name) return name == torch_items.floor end) then
						self:add_item_to_main(ItemStack(torch_items.floor))
					end
					if self:has_item_in_main(function (name) return name == torch_items.floor end) then
					  local inv = self:get_inventory()
					  if inv:room_for_item("main", ItemStack(nname)) then
						  self:replace_item_from_main(ItemStack(torch_items.floor), ItemStack(nname))
					  else
						if self.owner_name and self.owner_name ~= "" then
						  self:notify_owner_event(
						    "Inventaire plein, impossible de convertir une torche murale pour la pose.",
						    "builder:inventory_full",
						    120,
						    "detailed"
						  )
						end
	            return pause_for_inventory_space(self)
				    end
					end
				end
				local has_material = is_material(wield_stack:get_name()) or self:has_item_in_main(is_material)
				if not has_material and (not unlimited_materials) then
					ensure_builder_material_stock(self, nname, builder_material_batch_size)
					has_material = is_material(self:get_wield_item_stack():get_name()) or self:has_item_in_main(is_material)
				end
				if not has_material and unlimited_materials then
					local destination = get_build_destination(npos, self.object:get_pos())
					if not destination then
						return pause_for_blocked_step(self, npos, "Cette etape du chantier est inaccessible, je la retenterai plus tard.")
					end
					if vector.distance(self.object:get_pos(), destination) > 5 then
						self:set_state_info("Je construis.")
						self:go_to(destination)
						return
					end
					self:set_state_info("Je construis.")
					minetest.set_node(npos, {
						name = nname,
						param1 = nnode.param1 or 0,
						param2 = nnode.param2 or 0,
					})
					record_construction_step(meta, node_count, index, "unlimited", nname, 0)
					meta:set_int("index", meta:get_int("index") + 1)
					self.job_data.manipulated_chest = false
					return
				end
				if has_material then
					local destination = get_build_destination(npos, self.object:get_pos())
					if not destination then
						return pause_for_blocked_step(self, npos, "Cette etape du chantier est inaccessible, je la retenterai plus tard.")
					end
					self:set_state_info("Je construis.")
					self:go_to(destination)
					local material_before = count_builder_material(self, nname)
					local place_result = self:place(nnode,npos)
					local material_after = count_builder_material(self, nname)
					local material_delta = material_before - material_after
					local placed = minetest.get_node(npos).name
					local placed_canon = working_villages.buildings.get_registered_nodename(placed)
					local chest_ok = (minetest.get_item_group(placed, "chest") > 0 and
						minetest.get_item_group(nname, "chest") > 0)
					local fence_ok = (minetest.get_item_group(placed, "fence") > 0 and
						minetest.get_item_group(nname, "fence") > 0)
					if chest_ok or fence_ok or placed_canon == nname or placed == nname or placed == nnode.name then
						local ledger_kind = compat.is_bed_top(nname) and "synthetic" or "consumed"
						record_construction_step(meta, node_count, index, ledger_kind, nname, material_delta)
						meta:set_int("index",meta:get_int("index")+1)
					else
						builder_log(("placement failed expected=%s actual=%s target=%s destination=%s actor=%s result=%s material_delta=%d")
							:format(nname, placed, minetest.pos_to_string(npos, 1),
								minetest.pos_to_string(destination, 1),
								minetest.pos_to_string(self.object:get_pos(), 1),
								tostring(place_result), material_delta), "warning")
						-- Reset chest flag to allow getting materials from chest on next iteration
						self.job_data.manipulated_chest = false
						self:set_state_info(("La pose de %s a echoue, je vais reessayer."):format(nname))
						self:set_displayed_action("pose en attente")
						if self.owner_name then
							self:notify_owner_event(
								("Difficulte de construction avec %s, chantier en attente."):format(nname),
								"builder:placement_issue:" .. nname,
								180,
								"detailed"
							)
						end
						return co_command.pause, "pose echouee"
					end
				else
					-- Reset chest flag to allow getting materials from chest
					self.job_data.manipulated_chest = false
					self:count_timer("builder:help_alert")
					if comm and self:timer_exceeded("builder:help_alert", 40) then
						local request = {
							items = {[nname] = 1},
							info = "Besoin de materiaux pour construire",
							requester_id = self.inventory_name,
							build_pos = build_pos,
						}
						if collab and not self.job_data.collab_task and minetest.get_item_group(nname, "wood") > 0 then
							collab.start_task_or_broadcast(
								"resource_delivery", self, request,
								function() return comm.list_loaded_villagers() end)
						else
							comm.broadcast(self, comm.list_loaded_villagers(), "help_needed", request)
						end
					end
					-- Only send error message occasionally to avoid spam
					if self:timer_exceeded("builder:error_msg", 60) then
						if self.owner_name and self.owner_name ~= "" then
							self:notify_owner_event(
								("Il manque %s pour continuer le chantier."):format(nname),
								"builder:missing_material:" .. nname,
								60,
								"important"
							)
						end
					end
					self:set_displayed_action("attend materiaux")
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
		if not creative_test_mode then
			return false, "Commande reservee au mode creative_test"
		end
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
				villager.job_data.learning_note = "Experiment validee : " .. (state.description or state.blueprint)
			else
				minetest.chat_send_player(name, "Impossible d'ameliorer ce plan.")
				return false, "Impossible d'ameliorer ce plan"
			end
		else
			revert_experiment_state(state)
			minetest.chat_send_player(name, "Experimentation annulee, la creation a ete remise a l'etat precedent.")
			villager.job_data.learning_note = "Experiment refusee : " .. (state.description or state.blueprint)
		end

		villager.job_data.experiment_state = nil
		return true, "Merci pour votre retour."
	end,
})
