-- Blacksmith Job
-- A villager that works with metal, repairs tools, and creates metal items

local func = working_villages.require("jobs/util")
local compat = working_villages.voxelibre_compat
local blueprints = working_villages.blueprints
local communication = working_villages.communication
local crafting = working_villages.crafting
local inventory_access = working_villages.inventory_access or working_villages.require("inventory_access")

local blacksmith = {}
local furnace_interaction_range = 3.5

local function is_metal_ore(item)
	return compat.is_metal_smelting_input(item)
end

local function is_metal_ingot(item)
	return compat.is_metal_ingot(item)
end

local forge_materials = {
	[compat.get_item("default:wood")] = true,
	[compat.get_item("default:cobble")] = true,
	[compat.get_item("default:steel_ingot")] = true,
	[compat.get_item("default:gold_ingot")] = true,
	[compat.get_item("default:diamond")] = true,
	[compat.get_item("default:stick")] = true,
}

local function is_forge_material(name)
	if type(name) == "table" then
		name = name.name or name:get_name()
	end
	return forge_materials[name] or false
end

local function pick_registered_item(candidates)
	for _, name in ipairs(candidates) do
		if minetest.registered_items[name] then
			return name
		end
	end
	return nil
end

local furnace_item_candidates = compat.get_furnace_item_candidates()
local active_furnace_ttl = 20

local function same_pos(left, right)
	return left and right and left.x == right.x and left.y == right.y and left.z == right.z
end

local function clear_reserved_furnace_site(self)
	if self.job_data and self.job_data.blacksmith_furnace_site and self.release_reserved_position then
		self:release_reserved_position("utility_furnace_site", self.job_data.blacksmith_furnace_site)
		self.job_data.blacksmith_furnace_site = nil
	end
end

local function clear_active_furnace_claim(self)
	if self.job_data and self.job_data.blacksmith_active_furnace and self.release_reserved_position then
		self:release_reserved_position("active_furnace", self.job_data.blacksmith_active_furnace)
		self.job_data.blacksmith_active_furnace = nil
	end
end

local function get_active_furnace_claim(self)
	local pos = self.job_data and self.job_data.blacksmith_active_furnace or nil
	if pos and func.is_furnace(pos) then
		return vector.round(pos)
	end
	clear_active_furnace_claim(self)
	return nil
end

local function claim_active_furnace(self, furnace_pos)
	if not furnace_pos or not self.reserve_position then
		return furnace_pos ~= nil
	end
	self.job_data = self.job_data or {}
	furnace_pos = vector.round(furnace_pos)
	if self.job_data.blacksmith_active_furnace
			and not same_pos(self.job_data.blacksmith_active_furnace, furnace_pos) then
		clear_active_furnace_claim(self)
	end
	local ok = self:reserve_position("active_furnace", furnace_pos, active_furnace_ttl)
	if ok then
		self.job_data.blacksmith_active_furnace = furnace_pos
	end
	return ok
end

local function can_place_furnace(self, pos)
	pos = vector.round(pos)
	if func.is_protected(self, pos) or working_villages.failed_pos_test(pos) then
		return false
	end
	if self.is_position_reserved and self:is_position_reserved("utility_furnace_site", pos) then
		return false
	end
	if func.is_furnace(pos) then
		return false
	end
	local node = minetest.get_node_or_nil(pos)
	local below = minetest.get_node_or_nil(vector.add(pos, {x = 0, y = -1, z = 0}))
	if not node or not below then
		return false
	end
	local node_def = minetest.registered_nodes[node.name]
	if not node_def or not node_def.buildable_to then
		return false
	end
	if minetest.get_item_group(below.name, "liquid") > 0 or not func.walkable_pos(vector.add(pos, {x = 0, y = -1, z = 0})) then
		return false
	end
	return func.find_adjacent_clear(pos) ~= false
end

local function find_furnace_site(self)
	local origin = vector.round(
		(self.pos_data and (self.pos_data.job_pos or self.pos_data.storage_pos or self.pos_data.home_pos))
		or self.object:get_pos()
	)
	return func.search_surrounding(origin, function(pos)
		return can_place_furnace(self, pos)
	end, {x = 4, y = 1, z = 4, h = 1})
end

local function ensure_furnace_workspace(self, searching_range)
	self.job_data = self.job_data or {}
	local existing = func.find_nearby_furnace(self, self.object:get_pos(), searching_range)
	if existing then
		clear_reserved_furnace_site(self)
		return existing, false
	end

	local wield_name = self:get_wield_item_stack():get_name()
	local has_furnace_item = false
	for _, candidate in ipairs(furnace_item_candidates) do
		if wield_name == candidate or self:has_item_in_main(function(name) return name == candidate end) then
			has_furnace_item = true
			break
		end
	end
	local pending_site = self.job_data.blacksmith_furnace_site ~= nil
	self:count_timer("blacksmith:furnace_bootstrap")
	if not pending_site and not has_furnace_item and not self:timer_exceeded("blacksmith:furnace_bootstrap", 40) then
		return nil, false
	end
	if not crafting or #furnace_item_candidates == 0 then
		return nil, false
	end

	local furnace_item = nil
	for _, candidate in ipairs(furnace_item_candidates) do
		if wield_name == candidate or self:has_item_in_main(function(name) return name == candidate end) then
			furnace_item = candidate
			break
		end
	end
	if not furnace_item then
		furnace_item = crafting.ensure_any_item(self, furnace_item_candidates, 1, {
			use_shared_storage = true,
			fail_cooldown = 10,
			max_depth = 4,
		})
	end
	if not furnace_item then
		return nil, false
	end

	local site = self.job_data.blacksmith_furnace_site and vector.round(self.job_data.blacksmith_furnace_site) or find_furnace_site(self)
	if not site then
		return nil, false
	end
	if not self:reserve_position("utility_furnace_site", site, 20) then
		return nil, false
	end
	self.job_data.blacksmith_furnace_site = vector.round(site)

	local destination = func.find_adjacent_clear(site)
	if destination then
		destination = func.find_ground_below(destination) or destination
	end
	if destination and vector.distance(self.object:get_pos(), destination) > 4 then
		self:set_displayed_action("installe un four")
		self:set_state_info("Je prepare un four pour travailler le metal.")
		local reached = self:go_to(destination)
		if not reached then
			working_villages.failed_pos_record(site)
			clear_reserved_furnace_site(self)
			return nil, false
		end
		return nil, true
	end

	self:set_displayed_action("installe un four")
	self:set_state_info("J'installe un four pour la forge.")
	local placed = self:place(furnace_item, site)
	clear_reserved_furnace_site(self)
	if placed and func.is_furnace(site) then
		return site, true
	end
	if not placed then
		working_villages.failed_pos_record(site)
	end
	return nil, placed or false
end

local function catalog_entries()
	local stick = compat.get_item("default:stick")
	local tiers = {
		{key = "wood", material = compat.get_item("default:wood"), label = "bois"},
		{key = "stone", material = compat.get_item("default:cobble"), label = "pierre"},
		{key = "iron", material = compat.get_item("default:steel_ingot"), label = "fer"},
		{key = "gold", material = compat.get_item("default:gold_ingot"), label = "or"},
		{key = "diamond", material = compat.get_item("default:diamond"), label = "diamant"},
	}

	local outputs = {
		{suf = "sword", label = "epee", mat = 2, stick = 1},
		{suf = "pick", label = "pioche", mat = 3, stick = 2},
		{suf = "axe", label = "hache", mat = 3, stick = 2},
		{suf = "shovel", label = "pelle", mat = 1, stick = 2},
		{suf = "hoe", label = "houe", mat = 2, stick = 2},
	}

	local armor_pieces = {
		{key = "helmet", label = "casque", mat = 5},
		{key = "chestplate", label = "plastron", mat = 8},
		{key = "leggings", label = "jambieres", mat = 7},
		{key = "boots", label = "bottes", mat = 4},
	}

	local armor_tiers = {
		{
			key = "iron",
			label = "fer",
			material = compat.get_item("default:steel_ingot"),
			items = {
				helm = compat.get_armor_items("helmet", "iron"),
				chest = compat.get_armor_items("chestplate", "iron"),
				legs = compat.get_armor_items("leggings", "iron"),
				feet = compat.get_armor_items("boots", "iron"),
			},
		},
		{
			key = "gold",
			label = "or",
			material = compat.get_item("default:gold_ingot"),
			items = {
				helm = compat.get_armor_items("helmet", "gold"),
				chest = compat.get_armor_items("chestplate", "gold"),
				legs = compat.get_armor_items("leggings", "gold"),
				feet = compat.get_armor_items("boots", "gold"),
			},
		},
		{
			key = "diamond",
			label = "diamant",
			material = compat.get_item("default:diamond"),
			items = {
				helm = compat.get_armor_items("helmet", "diamond"),
				chest = compat.get_armor_items("chestplate", "diamond"),
				legs = compat.get_armor_items("leggings", "diamond"),
				feet = compat.get_armor_items("boots", "diamond"),
			},
		},
	}

	local entries = {}
	for _, tier in ipairs(tiers) do
		for _, out in ipairs(outputs) do
			local item_name = compat.get_tool_item(out.suf, tier.key)
			if item_name then
				table.insert(entries, {
					key = ("%s_%s"):format(out.suf, tier.key),
					label = out.label .. " " .. tier.label,
					output = item_name,
					req = {
						[tier.material] = out.mat,
						[stick] = out.stick,
					},
				})
			end
		end
	end

	local shield_item = pick_registered_item(compat.get_shield_items())
	if shield_item then
		table.insert(entries, {
			key = "shield_iron",
			label = "bouclier",
			output = shield_item,
			req = {
				[compat.get_item("default:wood")] = 6,
				[compat.get_item("default:steel_ingot")] = 1,
			},
		})
	end

	for _, tier in ipairs(armor_tiers) do
		for _, piece in ipairs(armor_pieces) do
			local item_name = nil
			if piece.key == "helmet" then
				item_name = pick_registered_item(tier.items.helm)
			elseif piece.key == "chestplate" then
				item_name = pick_registered_item(tier.items.chest)
			elseif piece.key == "leggings" then
				item_name = pick_registered_item(tier.items.legs)
			elseif piece.key == "boots" then
				item_name = pick_registered_item(tier.items.feet)
			end
			if item_name then
				table.insert(entries, {
					key = ("%s_%s"):format(piece.key, tier.key),
					label = piece.label .. " " .. tier.label,
					output = item_name,
					req = {
						[tier.material] = piece.mat,
					},
				})
			end
		end
	end

	return entries
end

local CATALOG = catalog_entries()

function blacksmith.get_catalog()
	return CATALOG
end

local save_global_orders

local function get_global_orders()
	local orders = working_villages.get_stored_table("_blacksmith_global_orders")
	if type(orders) ~= "table" then
		return {}
	end
	local migrated = false
	local by_owner = {}
	for key, value in pairs(orders) do
		if type(value) == "table" and value.count ~= nil then
			local owner_name = value.requester or "working_villages:self_employed"
			by_owner[owner_name] = by_owner[owner_name] or {}
			by_owner[owner_name][key] = value
			migrated = true
		else
			by_owner[key] = value
		end
	end
	if migrated then
		save_global_orders(by_owner)
	end
	return by_owner
end

save_global_orders = function(orders)
	working_villages.set_stored_table("_blacksmith_global_orders", orders)
	working_villages.clear_cached_table("_blacksmith_global_orders")
end

local function get_catalog_entry(key)
	for _, entry in ipairs(CATALOG) do
		if entry.key == key then
			return entry
		end
	end
	return nil
end

local function has_requirements(inv, req)
	for name, count in pairs(req) do
		if not inv:contains_item("main", ItemStack(name .. " " .. count)) then
			return false, name, count
		end
	end
	return true
end

local function parse_order_key(key)
	if not key then
		return nil, nil
	end
	local tool, tier = key:match("^([%w]+)_([%w]+)$")
	return tool, tier
end

local function order_tool_group(key)
	local tool = parse_order_key(key)
	local groups = {
		pick = "pickaxe",
		axe = "axe",
		shovel = "shovel",
		hoe = "hoe",
		sword = "sword",
		shield = "shield",
	}
	return groups[tool]
end

local tier_priority = {"diamond", "iron", "gold", "stone", "wood"}

local function find_best_entry_for_tool(tool_key)
	for _, tier in ipairs(tier_priority) do
		local entry = get_catalog_entry(("%s_%s"):format(tool_key, tier))
		if entry then
			return entry
		end
	end
	return nil
end

local function find_craftable_entry_for_tool(self, tool_key)
	local inv = self:get_inventory()
	for _, tier in ipairs(tier_priority) do
		local entry = get_catalog_entry(("%s_%s"):format(tool_key, tier))
		if entry then
			local ok = has_requirements(inv, entry.req)
			if not ok and self.take_from_shared_storage then
				self:take_from_shared_storage(entry.req)
				ok = has_requirements(inv, entry.req)
			end
			if ok then
				return entry
			end
		end
	end
	return nil
end

function blacksmith.enqueue_order(villager, key, count, requester, requester_id, task_id)
	if not villager then
		return false, "Villageois introuvable"
	end
	local entry = get_catalog_entry(key)
	if not entry then
		return false, "Objet introuvable"
	end
	local qty = tonumber(count or 1) or 1
	qty = math.max(1, math.min(16, qty))

	villager.job_data = villager.job_data or {}
	villager.job_data.blacksmith_orders = villager.job_data.blacksmith_orders or {}
	if requester_id or task_id then
		for _, pending in ipairs(villager.job_data.blacksmith_orders) do
			local same_requester = requester_id and pending.requester_id == requester_id
			local same_task = task_id and pending.task_id == task_id
			if pending.key == entry.key and (same_requester or same_task) then
				pending.count = math.max(tonumber(pending.count) or 1, qty)
				pending.requester = requester or pending.requester
				pending.requester_id = requester_id or pending.requester_id
				pending.task_id = task_id or pending.task_id
				return true, "Commande deja en attente : " .. entry.label
			end
		end
	end
	table.insert(villager.job_data.blacksmith_orders, {
		key = entry.key,
		count = qty,
		requester = requester,
		requester_id = requester_id,
		task_id = task_id,
	})
	villager:set_state_info("Commande recue : " .. entry.label)
	villager:set_displayed_action("forge une commande")
	return true, "Commande ajoutee : " .. entry.label .. " x" .. qty
end

function blacksmith.enqueue_global_order(key, count, requester, requester_id, task_id)
	local entry = get_catalog_entry(key)
	if not entry then
		return false, "Objet introuvable"
	end
	local qty = tonumber(count or 1) or 1
	qty = math.max(1, math.min(16, qty))

	local owner_name = requester and requester ~= "" and requester
		or "working_villages:self_employed"
	local orders = get_global_orders()
	orders[owner_name] = type(orders[owner_name]) == "table" and orders[owner_name] or {}
	local order_id = requester_id and (key .. "|" .. requester_id) or key
	local current = orders[owner_name][order_id] or {count = 0, key = key}
	if requester_id or task_id then
		current.count = math.max(tonumber(current.count) or 0, qty)
	else
		current.count = (tonumber(current.count) or 0) + qty
	end
	current.key = key
	current.requester = owner_name
	current.requester_id = requester_id or current.requester_id
	current.task_id = task_id or current.task_id
	orders[owner_name][order_id] = current
	save_global_orders(orders)
	return true, "Commande globale ajoutee : " .. entry.label .. " x" .. qty
end

function blacksmith.pop_global_order(owner_name)
	owner_name = owner_name and owner_name ~= "" and owner_name
		or "working_villages:self_employed"
	local orders = get_global_orders()
	local village_orders = type(orders[owner_name]) == "table" and orders[owner_name] or {}
	local best_id, best_key, best_count
	for order_id, entry in pairs(village_orders) do
		if entry and entry.count and entry.count > 0 then
			if not best_count or entry.count > best_count then
				best_id = order_id
				best_key = entry.key or order_id
				best_count = entry.count
			end
		end
	end
	if not best_id then
		return nil
	end
	local entry = village_orders[best_id]
	local qty = math.min(16, entry.count or 1)
	entry.count = (entry.count or 0) - qty
	if entry.count <= 0 then
		village_orders[best_id] = nil
	else
		village_orders[best_id] = entry
	end
	orders[owner_name] = next(village_orders) and village_orders or nil
	save_global_orders(orders)
	return {
		key = best_key,
		count = qty,
		requester = entry.requester,
		requester_id = entry.requester_id,
		task_id = entry.task_id,
	}
end

local function find_owned_blacksmith(player)
	if not player then
		return nil
	end
	local position = player:get_pos()
	local objects = minetest.get_objects_inside_radius(position, 12)
	for _, obj in ipairs(objects) do
		local lua = obj:get_luaentity()
		if lua and working_villages.is_villager(lua.name) then
			local job_name = lua.get_job_name and lua:get_job_name() or ""
			if job_name == "working_villages:job_blacksmith" then
				if lua.owner_name == player:get_player_name() then
					return lua
				end
			end
		end
	end
	return nil
end

local function get_output_chest_pos(self)
	if self.job_data and self.job_data.blacksmith_output_pos then
		return self.job_data.blacksmith_output_pos
	end
	return self.pos_data and self.pos_data.chest_pos or nil
end

local function deposit_output(self, stack)
	local chest_pos = get_output_chest_pos(self)
	if chest_pos and func.is_chest(chest_pos) then
		if inventory_access.can_put_stack(self, chest_pos, "main", stack) then
			local leftover, moved = inventory_access.put_stack(self, chest_pos, "main", stack)
			if leftover:is_empty() and moved == stack:get_count() then
				return true, moved
			end
			-- A preflight makes partial delivery impossible in normal execution.
			-- Keep any unexpected remainder so ownership stays exact. The caller
			-- receives `moved` and reduces the still-active order by that progress;
			-- it must never restore the original stack a second time.
			self:add_item_to_main(leftover)
			return false, moved
		end
	end
	self:add_item_to_main(stack)
	return false, 0
end

local function deposit_to_shared_storage(self, stack)
	if not stack or stack:is_empty() then
		return false, 0
	end
	if self.get_shared_storage_chest_for_item then
		local storage_pos = self:get_shared_storage_chest_for_item(stack:get_name(), true)
		if storage_pos and func.is_chest(storage_pos) and self:reserve_position("shared_storage_chest", storage_pos, 2) then
			if inventory_access.can_put_stack(self, storage_pos, "main", stack) then
				local leftover, moved = inventory_access.put_stack(self, storage_pos, "main", stack)
				self:release_reserved_position("shared_storage_chest", storage_pos)
				if leftover:is_empty() and moved == stack:get_count() then
					return true, moved
				end
				-- Keep the undelivered remainder under villager ownership. The order
				-- remains active and is reduced only by the quantity actually moved.
				self:add_item_to_main(leftover)
				return false, moved
			else
				self:release_reserved_position("shared_storage_chest", storage_pos)
			end
		end
	end
	return deposit_output(self, stack)
end

-- Single ownership contract for forged order output. `output` has already
-- been removed from the villager inventory. This function either transfers it
-- completely, or restores the undelivered remainder exactly once. A partial
-- transfer is recorded as order progress so the next attempt deposits only
-- the remainder instead of forging the moved quantity again.
function blacksmith.deliver_order_output(self, order, output)
	local delivered, moved = deposit_to_shared_storage(self, output)
	moved = math.max(0, math.min(tonumber(moved) or 0, output and output:get_count() or 0))
	if not delivered and moved > 0 and order then
		order.count = math.max(0, (tonumber(order.count) or 0) - moved)
	end
	return delivered == true, moved
end

local function get_ore_smelt_result(stack)
	if not stack or stack:is_empty() then
		return nil
	end
	return compat.get_metal_smelt_result(stack)
end

local function is_fuel_item(name)
	if not name or name == "" then
		return false
	end
	local fuel = minetest.get_craft_result({
		method = "fuel",
		width = 1,
		items = {ItemStack(name)},
	})
	return fuel and fuel.time and fuel.time > 0
end

local function find_fuel_in_inventory(self)
	local inv = self:get_inventory()
	for i = 1, inv:get_size("main") do
		local stack = inv:get_stack("main", i)
		if not stack:is_empty() and is_fuel_item(stack:get_name()) then
			return i
		end
	end
	return nil
end

local function ensure_fuel_index(self)
	local index = find_fuel_in_inventory(self)
	if index then
		return index
	end
	if self.take_from_shared_storage_by_predicate then
		self:take_from_shared_storage_by_predicate(function(name)
			return is_fuel_item(name)
		end, 1)
		return find_fuel_in_inventory(self)
	end
	return nil
end

local function find_ore_in_inventory(self)
	local inv = self:get_inventory()
	for i = 1, inv:get_size("main") do
		local stack = inv:get_stack("main", i)
		if not stack:is_empty() and is_metal_ore(stack) then
			return i
		end
	end
	return nil
end

local function ensure_ore_index(self)
	local index = find_ore_in_inventory(self)
	if index then
		return index
	end
	if self.take_from_shared_storage_by_predicate then
		self:take_from_shared_storage_by_predicate(is_metal_ore, 1)
		return find_ore_in_inventory(self)
	end
	return nil
end

local function furnace_has_metal_work(furnace_pos)
	local meta = minetest.get_meta(furnace_pos)
	if not meta then
		return false
	end
	local inv = meta:get_inventory()
	if not inv then
		return false
	end
	local src = inv:get_stack("src", 1)
	local dst = inv:get_stack("dst", 1)
	if not dst:is_empty() and is_metal_ingot(dst) then
		return true
	end
	return not src:is_empty() and get_ore_smelt_result(src) ~= nil
end

local function use_furnace_inventory(self, furnace_pos)
	local node = minetest.get_node_or_nil(furnace_pos)
	if not node or not inventory_access.can_access(self, furnace_pos) then
		return false
	end
	local meta = minetest.get_meta(furnace_pos)
	if not meta then
		return false
	end
	local inv = meta:get_inventory()
	if not inv then
		return false
	end

	local src = inv:get_stack("src", 1)
	local fuel = inv:get_stack("fuel", 1)
	local dst = inv:get_stack("dst", 1)

	if not dst:is_empty() and is_metal_ingot(dst) then
		local taken, moved = inventory_access.take_stack(
			self, furnace_pos, "dst", 1, dst:get_count())
		if moved > 0 then
			deposit_to_shared_storage(self, taken)
			self:set_displayed_action("range les lingots")
			self:set_state_info("Je range les lingots dans le coffre commun.")
			return true
		end
		return false
	end

	if not src:is_empty() and not get_ore_smelt_result(src) then
		return false
	end

	if src:is_empty() then
		local ore_index = ensure_ore_index(self)
		if ore_index and inventory_access.put_from_inventory(
				self, self:get_inventory(), "main", ore_index,
				furnace_pos, "src", 1, 1) > 0 then
			self:set_state_info("Je charge le minerai dans le four.")
		end
		src = inv:get_stack("src", 1)
	end

	if src:is_empty() then
		return false
	end

	if fuel:is_empty() then
		local fuel_index = ensure_fuel_index(self)
		if fuel_index and inventory_access.put_from_inventory(
				self, self:get_inventory(), "main", fuel_index,
				furnace_pos, "fuel", 1, 1) > 0 then
			self:set_state_info("J'alimente la forge.")
		else
			if communication and self:timer_exceeded("blacksmith:request", 40) then
				communication.broadcast(self, communication.list_loaded_villagers(), "help_needed", {
					items = {[compat.get_item("default:wood")] = 4},
					requester_id = self.inventory_name,
				})
			end
			self:set_displayed_action("manque de combustible")
			self:set_state_info("Il me manque du combustible pour la forge.")
			return false
		end
	end

	self:set_displayed_action("travaille a la forge")
	self:set_state_info("Je fonds le minerai pour produire des lingots.")
	return true
end

local function ensure_output_from_recipes(self, item_name, count)
	if not crafting or not item_name or item_name == "" then
		return false, {missing_items = {[item_name] = count}, missing_specs = {}}
	end
	return crafting.ensure_item(self, item_name, count, {
		use_shared_storage = true,
		skip_storage_for = {[item_name] = true},
		fail_cooldown = 5,
		max_depth = 4,
	})
end

local function get_missing_material(details, fallback_req)
	if details and details.missing_items then
		local name, count = next(details.missing_items)
		if name then return name, count end
	end
	if fallback_req then
		local name, count = next(fallback_req)
		if name then return name, count end
	end
	return nil, nil
end

local function consume_requirements(inv, req)
	for name, count in pairs(req) do
		inv:remove_item("main", ItemStack(name .. " " .. count))
	end
end

local function should_stock_tools(self)
	if not self.count_shared_storage_items then
		return true
	end
	local tool_groups = {"pickaxe", "axe", "shovel", "hoe", "sword", "shield"}
	for _, group in ipairs(tool_groups) do
		local count = self:count_shared_storage_items(function(name)
			return minetest.get_item_group(name, group) > 0
		end)
		if count < 2 then
			return true
		end
	end
	for _, group in ipairs({"armor_head", "armor_torso", "armor_legs", "armor_feet"}) do
		local count = self:count_shared_storage_items(function(name)
			return minetest.get_item_group(name, group) > 0
		end)
		if count < 1 then
			return true
		end
	end
	return false
end

local function stock_basic_tools(self)
	local tool_keys = {"pick", "axe", "shovel", "hoe", "sword", "shield"}
	for _, tool in ipairs(tool_keys) do
		for _, tier in ipairs(tier_priority) do
			local entry = get_catalog_entry(("%s_%s"):format(tool, tier))
			if entry then
				local ok = ensure_output_from_recipes(self, entry.output, 1)
				if ok then
					local stack = self:get_inventory():remove_item("main", ItemStack(entry.output .. " 1"))
					if not stack:is_empty() then
						deposit_to_shared_storage(self, stack)
						self:announce_action("Des outils sont prets dans le coffre partage.", 180)
						return true
					end
				end
			end
		end
	end
	for _, piece in ipairs({"helmet", "chestplate", "leggings", "boots"}) do
		for _, tier in ipairs({"iron", "gold", "diamond"}) do
			local entry = get_catalog_entry(("%s_%s"):format(piece, tier))
			if entry then
				local count = self:count_shared_storage_items(function(name)
					return name == entry.output
				end)
				if count < 1 then
					local ok = ensure_output_from_recipes(self, entry.output, 1)
					if ok then
						local stack = self:get_inventory():remove_item("main", ItemStack(entry.output .. " 1"))
						if not stack:is_empty() then
							deposit_to_shared_storage(self, stack)
							self:announce_action("Je prepare aussi de l'armure pour le village.", 180)
							return true
						end
					end
				end
			end
		end
	end
	return false
end

-- Check if a tool needs repair (damaged)
local function needs_repair(itemstack)
	if type(itemstack) == "string" then
		itemstack = ItemStack(itemstack)
	end
	
	local wear = itemstack:get_wear()
	-- Consider tools damaged if they have more than 20% wear
	return wear > 13107  -- 65535 * 0.2
end

-- Function to repair a tool (reduce wear)
local function repair_tool(self, itemstack)
	if not needs_repair(itemstack) then
		return false
	end
	
	local repair_material = nil
	for _, entry in ipairs(CATALOG) do
		if entry.output == itemstack:get_name() then
			for name in pairs(entry.req or {}) do
				if name ~= compat.get_item("default:stick") then
					repair_material = name
					break
				end
			end
			break
		end
	end
	if not repair_material then
		return false
	end
	local inv = self:get_inventory()
	local material_stack = ItemStack(repair_material .. " 1")
	if not inv:contains_item("main", material_stack) and self.take_from_shared_storage then
		self:take_from_shared_storage({[repair_material] = 1})
	end
	if not inv:contains_item("main", material_stack) then
		self:set_state_info("Il me manque " .. repair_material .. " pour reparer cet outil.")
		return false
	end
	inv:remove_item("main", material_stack)

	local current_wear = itemstack:get_wear()
	-- Repair 10% of the tool's durability
	local repair_amount = 6553  -- 65535 * 0.1
	local new_wear = math.max(0, current_wear - repair_amount)
	
	itemstack:set_wear(new_wear)
	
	-- Award experience for repairing
	local inv_name = self:get_inventory_name()
	blueprints.add_experience(inv_name, 1)
	
	return true
end

local function put_func(_, stack)
	local name = stack:get_name()
	-- Keep metal ingots and damaged tools
	if is_metal_ingot(name) or needs_repair(stack) or is_forge_material(name) then
		return false
	end
	return true
end

local function take_func(_, stack)
	return not put_func(_, stack)
end

local searching_range = {x = 15, y = 5, z = 15}

working_villages.register_job("working_villages:job_blacksmith", {
	description = "forgeron (working_villages)",
	long_description = "Je travaille le metal et le feu. Je collecte des minerais, je les fond en lingots, "..
		"je repare les outils abimes et j'aide a construire en metal. "..
		"J'ai besoin d'un four pour bien travailler.",
	inventory_image = "default_paper.png^working_villages_blacksmith.png",
	capabilities = {
		metalworking = true,
		tool_repair = true,
		ore_smelting = true,
		furnace_operation = true,
		metal_crafting = true,
	},
	on_start = function(self)
		-- Notify player about blacksmith capabilities
		self:notify_job_feature(
			"Travail du métal",
			"Répare les outils, fond les minerais en lingots, travaille avec les fours"
		)
	end,
	jobfunc = function(self)
		if self.equip_best_weapon then self:equip_best_weapon() end
		if self.equip_best_armor then self:equip_best_armor() end
		self:handle_night()
		self:handle_chest(take_func, put_func)
		self:handle_job_pos()
		
		self:count_timer("blacksmith:search")
		self:count_timer("blacksmith:change_dir")
		self:count_timer("blacksmith:announce")
		self:count_timer("blacksmith:request")
		self:count_timer("blacksmith:stock")
		self:handle_obstacles()
		
		if self:timer_exceeded("blacksmith:search", 10) then
			self.job_data = self.job_data or {}
			if not self.job_data.blacksmith_orders or #self.job_data.blacksmith_orders == 0 then
				local global_order = blacksmith.pop_global_order(self.owner_name)
				if global_order then
					self.job_data.blacksmith_orders = {global_order}
				end
			end
			if self.job_data and self.job_data.blacksmith_orders
				and #self.job_data.blacksmith_orders > 0 then
				local order = self.job_data.blacksmith_orders[1]
				local entry = get_catalog_entry(order.key)
				if entry then
					local candidates = {}
					local seen = {}
					local function push_candidate(candidate)
						if candidate and candidate.output and not seen[candidate.output] then
							seen[candidate.output] = true
							table.insert(candidates, candidate)
						end
					end
					push_candidate(entry)
					local tool_key = parse_order_key(order.key)
					if tool_key then
						for _, tier in ipairs(tier_priority) do
							push_candidate(get_catalog_entry(("%s_%s"):format(tool_key, tier)))
						end
					end

					local crafted_entry = nil
					local craft_details = nil
					for _, candidate in ipairs(candidates) do
						local ok, details = ensure_output_from_recipes(self, candidate.output, order.count)
						if ok then
							crafted_entry = candidate
							break
						end
						craft_details = details
					end

					if crafted_entry then
						local queued_delivery = false
						if order.requester_id and self.queue_physical_delivery then
							local tool_group = order_tool_group(order.key)
							local delivery = {
								count = order.count,
								task_id = order.task_id,
							}
							if tool_group then
								delivery.tool_group = tool_group
							else
								delivery.items = {[crafted_entry.output] = order.count}
							end
							queued_delivery = self:queue_physical_delivery(order.requester_id, delivery)
						end

						if queued_delivery then
							blueprints.add_experience(self:get_inventory_name(), 1)
							self:set_state_info("Commande prete : livraison de " .. crafted_entry.label)
							self:set_displayed_action("prepare une livraison")
							if order.requester and order.requester ~= "" then
								self:notify_player_event(
									order.requester,
									"Commande forgeron prete, livraison en cours : " .. crafted_entry.label,
									"blacksmith:order_ready:" .. (order.key or crafted_entry.label),
									30,
									"important"
								)
							end
							table.remove(self.job_data.blacksmith_orders, 1)
							self:delay(40)
							return
						end

						local output = self:get_inventory():remove_item(
							"main", ItemStack(crafted_entry.output .. " " .. order.count))
						if not output:is_empty() then
							local delivered = blacksmith.deliver_order_output(self, order, output)
							if not delivered then
								self:set_displayed_action("attend un coffre libre")
								self:set_state_info("L'outil est pret, mais je ne peux pas le livrer au coffre commun.")
								return
							end
							blueprints.add_experience(self:get_inventory_name(), 1)
							self:set_state_info("Commande terminee : " .. crafted_entry.label)
							self:set_displayed_action("forge une commande")
							if order.requester and order.requester ~= "" then
								self:notify_player_event(
									order.requester,
									"Commande forgeron terminee : " .. crafted_entry.label,
									"blacksmith:order_done:" .. (order.key or crafted_entry.label),
									30,
									"important"
								)
							end
							table.remove(self.job_data.blacksmith_orders, 1)
							self:delay(40)
							return
						end
					end

					local missing_name, missing_count = get_missing_material(craft_details, entry.req)
					if communication and missing_name and self:timer_exceeded("blacksmith:request", 40) then
						local targets = communication.list_loaded_villagers()
						communication.broadcast(self, targets, "help_needed", {
							items = {[missing_name] = missing_count or 1},
							requester_id = self.inventory_name,
						})
						self:announce_action("J'ai besoin de " .. (missing_count or 1) .. "x " .. missing_name .. ".")
					end
					self:set_state_info("Il me manque " .. (missing_count or 1) .. "x " .. (missing_name or "materiau"))
					self:set_displayed_action("manque de materiaux")
				else
					table.remove(self.job_data.blacksmith_orders, 1)
				end
			end

			if self:timer_exceeded("blacksmith:stock", 60) then
				if should_stock_tools(self) then
					if stock_basic_tools(self) then
						return
					end
				end
			end

			-- Check for damaged tools in inventory and repair them
			local inv = self:get_inventory()
			local main_inv = inv:get_list("main")
			local repaired_something = false
			
			for i, stack in ipairs(main_inv) do
				if not stack:is_empty() and needs_repair(stack) then
					if repair_tool(self, stack) then
						inv:set_stack("main", i, stack)
						self:set_state_info("Repare : " .. stack:get_name())
						self:set_displayed_action("repare des outils")
						self:delay(50)
						repaired_something = true
						if self:timer_exceeded("blacksmith:announce", 160) then
							self:announce_action("Je repare les outils uses pour qu'ils durent plus longtemps.")
						end
						break
					end
				end
			end
			
			if not repaired_something then
				-- Collect metal ores
				self:collect_nearest_item_by_condition(is_metal_ore, searching_range)
				
				-- Try to find and collect metal ingots
				self:collect_nearest_item_by_condition(is_metal_ingot, searching_range)
				
				-- Look for a furnace to work at, or build one if the village still lacks it
				local furnace_pos, furnace_action = ensure_furnace_workspace(self, searching_range)
				if furnace_action and not furnace_pos then
					clear_active_furnace_claim(self)
					return
				end
				if furnace_pos then
					local has_metal_work = self:has_item_in_main(is_metal_ore)
						or furnace_has_metal_work(furnace_pos)
					if not has_metal_work and ensure_ore_index(self) then
						has_metal_work = true
						self:set_state_info("Je recupere le minerai brut dans le coffre commun.")
					end
					if has_metal_work then
						local claimed = get_active_furnace_claim(self)
						if claimed and not same_pos(claimed, furnace_pos) then
							clear_active_furnace_claim(self)
						end
						if not claim_active_furnace(self, furnace_pos) then
							furnace_pos = func.find_nearby_furnace(self, self.object:get_pos(), searching_range, "active_furnace")
							if not furnace_pos or not claim_active_furnace(self, furnace_pos) then
								self:set_displayed_action("attend un four")
								self:set_state_info("J'attends qu'un four se libere pour fondre le minerai.")
								return
							end
						end
						local destination = func.find_interaction_pos(
							furnace_pos, self.object:get_pos())
						if destination then
							self:set_displayed_action("travaille a la forge")
							if vector.distance(self.object:get_pos(), destination) > furnace_interaction_range then
								self:set_state_info("Je rejoins un four libre pour fondre le minerai.")
								local reached = self:go_to(destination)
								if not reached then
									clear_active_furnace_claim(self)
									self:set_displayed_action("cherche un autre acces au four")
									self:set_state_info("L'acces choisi est bloque; je libere le four et je cherche un autre passage.")
								end
								return
							end
							self.object:set_velocity({x = 0, y = 0, z = 0})
							self:set_animation(working_villages.animation_frames.STAND)
							if use_furnace_inventory(self, furnace_pos) then
								self:delay(60)
								if self:timer_exceeded("blacksmith:announce", 160) then
									self:announce_action("Je fond le minerai pour creer des lingots de metal.")
								end
								return
							end
							clear_active_furnace_claim(self)
						end
					else
						clear_active_furnace_claim(self)
						self:set_state_info("Je cherche du minerai ou des outils a reparer.")
					end
				else
					clear_active_furnace_claim(self)
					self:set_state_info("Je cherche un four.")
					if self:timer_exceeded("blacksmith:announce", 200) then
						self:announce_action("J'ai besoin d'un four pour travailler le metal.")
					end
				end
			end
		elseif self:timer_exceeded("blacksmith:change_dir", 25) then
			self:change_direction_randomly()
		end
	end,
})

minetest.register_chatcommand("wv_blacksmith_order", {
	params = "<objet> [quantite]",
	description = "Passe une commande au forgeron proche (ex: sword_iron 1)",
	func = function(name, param)
		local key, count = param:match("^%s*(%S+)%s*(%S*)")
		if not key then
			return false, "Usage: /wv_blacksmith_order <objet> [quantite]"
		end
		local player = minetest.get_player_by_name(name)
		if not player then
			return false, "Joueur introuvable"
		end
		local villager = find_owned_blacksmith(player)
		if not villager then
			return false, "Aucun forgeron a proximite qui est a vous"
		end
		return blacksmith.enqueue_order(villager, key, count, name)
	end,
})

minetest.register_chatcommand("wv_blacksmith_output", {
	params = "<x,y,z|clear>",
	description = "Definit le coffre de sortie du forgeron proche",
	privs = {server = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false, "Joueur introuvable"
		end
		local villager = find_owned_blacksmith(player)
		if not villager then
			return false, "Aucun forgeron a proximite qui est a vous"
		end
		if param:match("^%s*clear%s*$") then
			villager.job_data = villager.job_data or {}
			villager.job_data.blacksmith_output_pos = nil
			return true, "Coffre de sortie reinitialise"
		end
		local pos = minetest.string_to_pos(param)
		if not pos then
			return false, "Usage: /wv_blacksmith_output <x,y,z|clear>"
		end
		villager.job_data = villager.job_data or {}
		villager.job_data.blacksmith_output_pos = pos
		return true, "Coffre de sortie defini"
	end,
})

working_villages.blacksmith = blacksmith
