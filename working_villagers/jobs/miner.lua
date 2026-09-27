-- Miner Job
-- A villager that mines stone and ores underground

local func = working_villages.require("jobs/util")
local compat = working_villages.voxelibre_compat
local blueprints = working_villages.blueprints
local torch_items = compat.get_torch_items()
local comm = working_villages.communication
local blacksmith = working_villages.blacksmith
local crafting = working_villages.crafting
local collab = working_villages.collaborative_tasks
local work_fallback = working_villages.work_fallback
local cardinal_dirs = {
	{x = 1, y = 0, z = 0},
	{x = -1, y = 0, z = 0},
	{x = 0, y = 0, z = 1},
	{x = 0, y = 0, z = -1},
}
local infrastructure_groups = {
	"bed", "chest", "container", "villager_chest", "door",
	"villager_door", "furnace", "crafting_table", "workbench",
}

-- Check if a node is mineable stone or ore
local function is_mineable(node_name)
	if type(node_name) == "table" then
		node_name = node_name.name
	end
	
	-- Check item groups
	local stone_group = minetest.get_item_group(node_name, "stone")
	local cracky_group = minetest.get_item_group(node_name, "cracky")
	local pickaxey_group = minetest.get_item_group(node_name, "pickaxey")
	
	if stone_group > 0 or cracky_group > 0 or pickaxey_group > 0 then
		-- Exclude nodes that shouldn't be mined
		if node_name:find("brick") or node_name:find("carved") or node_name:find("cobble") then
			return false
		end
		return true
	end
	
	return false
end

-- Check if a tool is a pickaxe
local function is_pickaxe(name)
	if type(name) == "table" then
		name = name.name or name:get_name()
	end
	return minetest.get_item_group(name, "pickaxe") > 0
end

local function get_pickaxe_candidates(cheapest_first)
	local iron = minetest.registered_items["mcl_tools:pick_iron"]
		and "mcl_tools:pick_iron" or compat.get_item("default:pick_steel")
	local stone = minetest.registered_items["mcl_tools:pick_stone"]
		and "mcl_tools:pick_stone" or compat.get_item("default:pick_stone")
	local wood = minetest.registered_items["mcl_tools:pick_wood"]
		and "mcl_tools:pick_wood" or compat.get_item("default:pick_wood")
	if cheapest_first then
		return {wood, stone, iron}
	end
	return {iron, stone, wood}
end

local function craft_basic_pickaxe(self)
	if not crafting then
		return false
	end
	-- Bootstrap from renewable wood before probing recipes which require stone
	-- or iron.  Strongest-first remains the policy for a known mining target.
	return crafting.ensure_any_item(self, get_pickaxe_candidates(true), 1, {
		use_shared_storage = true,
		fail_cooldown = 10,
		max_depth = 4,
	}) ~= nil
end

local function reserve_miner_target(self, pos, ttl)
	if not self.reserve_position then
		return true
	end
	return self:reserve_position("miner_target", pos, ttl or 15)
end

local function release_miner_target(self, pos)
	if self.release_reserved_position then
		self:release_reserved_position("miner_target", pos)
	end
end

local function get_mining_destination(target)
	local destination = func.find_adjacent_clear(target)
	if destination then
		destination = func.find_ground_below(destination) or destination
	end
	if destination == false then
		return nil
	end
	return destination
end

local function request_pickaxe(self)
	self.job_data = self.job_data or {}
	local task_id = self.job_data.collab_task
	if collab and not task_id then
		local started, value = collab.start_task("mining_tool_supply", self, {
			tool_group = "pickaxe",
			requester_id = self.inventory_name,
			info = "Le mineur a besoin d'une pioche",
		})
		if started then
			task_id = value
		end
	end

	local routed = false
	local smith = nil
	if blacksmith and blacksmith.enqueue_order then
		local targets = comm and comm.find_nearby_villagers(self.object:get_pos(), 25,
			"working_villages:job_blacksmith", self.owner_name) or {}
		smith = targets and targets[1]
	end
	if smith and blacksmith and blacksmith.enqueue_order then
		routed = blacksmith.enqueue_order(smith, "pick_iron", 1, self.owner_name or "",
			self.inventory_name, task_id) == true
	elseif blacksmith and blacksmith.enqueue_global_order then
		routed = blacksmith.enqueue_global_order("pick_iron", 1, self.owner_name or "",
			self.inventory_name, task_id) == true
	end
	if not routed and not task_id and comm then
		comm.broadcast(self, comm.list_loaded_villagers(), "help_needed", {
			tool_group = "pickaxe",
			requester_id = self.inventory_name,
		})
	end
	self.job_data.pick_request_time = minetest.get_gametime()
	self:set_state_info("Je demande une pioche.")
	return routed or task_id ~= nil
end

local function pickaxe_can_dig_node(stack, node_name)
	if not stack or stack:is_empty() or not is_pickaxe(stack:get_name()) then
		return false
	end
	local def = minetest.registered_nodes[node_name]
	if not def or def.diggable == false then
		return false
	end
	local params = minetest.get_dig_params(
		def.groups or {}, stack:get_tool_capabilities(), stack:get_wear())
	if not params or params.diggable ~= true then
		return false
	end

	-- VoxeLibre deliberately lets an under-tier tool break some nodes while
	-- suppressing their useful drop.  `get_dig_params().diggable` therefore is
	-- not, by itself, a harvesting capability check there.  MTG has no separate
	-- harvest API and keeps the traditional dig-params behaviour.
	local autogroup = rawget(_G, "mcl_autogroup")
	if autogroup and type(autogroup.can_harvest) == "function" then
		local ok, harvestable = pcall(
			autogroup.can_harvest, node_name, stack:get_name(), nil)
		if not ok or harvestable ~= true then
			return false
		end
	end
	return true
end

local function get_capable_pickaxe_stack(self, node_name)
	local wield = self:get_wield_item_stack()
	if pickaxe_can_dig_node(wield, node_name) then
		return wield
	end
	for _, stack in ipairs(self:get_inventory():get_list("main") or {}) do
		if pickaxe_can_dig_node(stack, node_name) then
			return stack
		end
	end
	return nil

end

local function has_capable_pickaxe(self, node_name)
	return get_capable_pickaxe_stack(self, node_name) ~= nil
end

-- Never treat village infrastructure as disposable rock, even when a game
-- gives the node a pickaxe/cracky group.  This central predicate is shared by
-- normal target selection and emergency tunnel opening so a furnace or chest
-- cannot be repeatedly placed, mined, and rebuilt.
local function is_infrastructure_node(node_name)
	if type(node_name) ~= "string" or node_name == "" then
		return false
	end
	if node_name == "working_villages:building_marker" then
		return true
	end
	if (type(compat.is_furnace) == "function" and compat.is_furnace(node_name))
			or (type(compat.is_crafting_table) == "function"
				and compat.is_crafting_table(node_name))
			or (type(compat.is_chest) == "function" and compat.is_chest(node_name))
			or (type(compat.is_door) == "function" and compat.is_door(node_name)) then
		return true
	end
	for _, group in ipairs(infrastructure_groups) do
		if minetest.get_item_group(node_name, group) > 0 then
			return true
		end
	end
	if node_name:find("^mcl_beds:") or node_name:find("^beds:") then
		return true
	end

	-- Generic modded containers may have no common group. Inventory callbacks
	-- are a narrow, game-independent signal which natural stone and ore nodes
	-- do not expose.
	local def = minetest.registered_nodes[node_name]
	if not def then
		return false
	end
	return type(def.allow_metadata_inventory_put) == "function"
		or type(def.allow_metadata_inventory_take) == "function"
		or type(def.allow_metadata_inventory_move) == "function"
		or type(def.on_metadata_inventory_put) == "function"
		or type(def.on_metadata_inventory_take) == "function"
		or type(def.on_metadata_inventory_move) == "function"
end

local function equip_capable_pickaxe(self, node_name)
	if pickaxe_can_dig_node(self:get_wield_item_stack(), node_name) then
		return true
	end
	return self:move_main_to_wield(function(name)
		return pickaxe_can_dig_node(ItemStack(name), node_name)
	end) == true
end

local function ensure_capable_pickaxe(self, node_name)
	if equip_capable_pickaxe(self, node_name) then
		return true
	end
	if not crafting then
		return false
	end
	local capable_candidates = {}
	for _, name in ipairs(get_pickaxe_candidates()) do
		if name and minetest.registered_items[name]
				and pickaxe_can_dig_node(ItemStack(name), node_name) then
			capable_candidates[#capable_candidates + 1] = name
		end
	end
	if #capable_candidates == 0 then
		return false
	end
	local crafted = crafting.ensure_any_item(self, capable_candidates, 1, {
		use_shared_storage = true,
		fail_cooldown = 5,
		max_depth = 4,
	})
	return crafted ~= nil and equip_capable_pickaxe(self, node_name)
end

local function is_ore_item(name)
	return compat.is_ore_item(name)
end

local function is_ore_node(node_name)
	if is_ore_item(node_name) or minetest.get_item_group(node_name, "ore") > 0 then
		return true
	end
	local def = minetest.registered_nodes[node_name]
	if def and type(def.drop) == "string" and def.drop ~= "" then
		return is_ore_item(ItemStack(def.drop):get_name())
	end
	-- MTG and several compatible games encode the mineral in the stone node
	-- name even when the node itself is not considered an ore inventory item.
	return node_name:find(":stone_with_", 1, true) ~= nil
		or node_name:find("_ore", 1, true) ~= nil
end

-- A real furnace recipe needs eight cobbles in both supported games.  The
-- shared chest is the durable source of truth: after a restart no transient
-- job counter is needed to decide whether this bootstrap work is still due.
local FURNACE_BOOTSTRAP_COBBLE_TARGET = 8
local bootstrap_utility_range = {x = 16, y = 8, z = 16}
local protected_anchor_fields = {
	"job_pos", "home_pos", "bed_pos", "door_pos", "storage_pos",
}

local function is_bootstrap_cobble_item(name)
	if type(name) ~= "string" or name == "" then
		return false
	end
	local canonical = compat.get_item and compat.get_item("default:cobble") or ""
	return name == canonical or minetest.get_item_group(name, "cobble") > 0
end

local function count_bootstrap_cobble(inv)
	if not inv then
		return 0
	end
	local count = 0
	for _, stack in ipairs(inv:get_list("main") or {}) do
		if not stack:is_empty() and is_bootstrap_cobble_item(stack:get_name()) then
			count = count + stack:get_count()
		end
	end
	return count
end

local function inventory_has_furnace_item(inv)
	if not inv then
		return false
	end
	for _, stack in ipairs(inv:get_list("main") or {}) do
		if not stack:is_empty() and compat.is_furnace(stack:get_name()) then
			return true
		end
	end
	return false
end

local function can_stand_at(pos)
	if not pos then
		return false
	end
	local body = minetest.get_node_or_nil(pos)
	local head = minetest.get_node_or_nil(vector.add(pos, {x = 0, y = 1, z = 0}))
	if not body or not head or body.name ~= "air" or head.name ~= "air" then
		return false
	end
	local below_pos = vector.add(pos, {x = 0, y = -1, z = 0})
	local below = minetest.get_node_or_nil(below_pos)
	return below and func.walkable_pos(below_pos)
		and minetest.get_item_group(below.name, "liquid") == 0
end

-- Derive the village's working surface from durable anchors instead of the
-- miner's current Y.  A miner which has already fallen into a hole must not
-- decide that the deeper foundation is a new source of furnace stone.
local function get_bootstrap_surface_y(self, storage_pos)
	local reference = self.pos_data and self.pos_data.job_pos
		or (self.object and self.object:get_pos())
	reference = vector.round(reference or storage_pos)
	if storage_pos then
		storage_pos = vector.round(storage_pos)
		local offsets = {0, 1, -1, 2, -2, 3, -3}
		for _, dy in ipairs(offsets) do
			for _, dir in ipairs(cardinal_dirs) do
				local candidate = {
					x = storage_pos.x + dir.x,
					y = reference.y + dy,
					z = storage_pos.z + dir.z,
				}
				if can_stand_at(candidate) then
					return candidate.y
				end
			end
		end
	end
	return reference.y
end

local function get_shared_storage_chests(self, storage_pos)
	local chests = self.get_shared_storage_chests and self:get_shared_storage_chests() or {}
	if #chests == 0 and storage_pos then
		chests = {storage_pos}
	end
	return chests
end

local function get_furnace_bootstrap_demand(self)
	if not working_villages.get_shared_storage_pos or not working_villages.is_chest_pos then
		return nil
	end
	local storage_pos = working_villages.get_shared_storage_pos(self.owner_name)
	if not working_villages.is_chest_pos(storage_pos) then
		return nil
	end
	if func.find_nearby_furnace
			and func.find_nearby_furnace(self, storage_pos, bootstrap_utility_range) then
		return nil
	end

	local shared_count = 0
	for _, chest_pos in ipairs(get_shared_storage_chests(self, storage_pos)) do
		local meta = minetest.get_meta(chest_pos)
		local inventory = meta and meta:get_inventory() or nil
		if inventory_has_furnace_item(inventory) then
			return nil
		end
		shared_count = shared_count + count_bootstrap_cobble(inventory)
	end
	-- Once any same-owner worker carries the crafted furnace, quarry work is
	-- complete even if placement is still in progress. Without this village-wide
	-- check the miner repeatedly spent another eight cobbles while the autonomous
	-- worker was walking to the selected site.
	if inventory_has_furnace_item(self:get_inventory()) then
		return nil
	end
	if comm and comm.list_loaded_villagers then
		for _, villager in ipairs(comm.list_loaded_villagers()) do
			if villager ~= self and villager.owner_name == self.owner_name
					and villager.get_inventory
					and inventory_has_furnace_item(villager:get_inventory()) then
				return nil
			end
		end
	end
	if shared_count >= FURNACE_BOOTSTRAP_COBBLE_TARGET then
		return nil
	end
	local carried_count = count_bootstrap_cobble(self:get_inventory())
	return {
		storage_pos = vector.round(storage_pos),
		surface_y = get_bootstrap_surface_y(self, storage_pos),
		shared_count = shared_count,
		carried_count = carried_count,
		mine_count = math.max(0,
			FURNACE_BOOTSTRAP_COBBLE_TARGET - shared_count - carried_count),
	}
end

local function node_drops_bootstrap_cobble(self, node_name)
	if is_ore_node(node_name) or type(minetest.get_node_drops) ~= "function" then
		return false
	end
	-- `equip_best_weapon` may temporarily leave a sword wielded while a capable
	-- pickaxe is carried in cargo.  Query the registered drop with the pickaxe
	-- which will actually be equipped before digging, not with that stale wield.
	local capable_pickaxe = get_capable_pickaxe_stack(self, node_name)
	if not capable_pickaxe then
		return false
	end
	local tool_name = capable_pickaxe:get_name()
	local ok, drops = pcall(minetest.get_node_drops, node_name, tool_name)
	if not ok then
		return false
	end
	for _, value in ipairs(drops or {}) do
		local stack = ItemStack(value)
		if not stack:is_empty() and is_bootstrap_cobble_item(stack:get_name()) then
			return true
		end
	end
	return false
end

local function get_safe_bootstrap_destination(self, target, demand)
	if not target or not demand or target.y < demand.surface_y then
		return nil
	end
	local destination = get_mining_destination(target)
	if not destination or destination.y < demand.surface_y
			or not can_stand_at(destination) then
		return nil
	end
	-- Reject the classic floor-mining destination: standing directly above the
	-- target and then removing the block which supports the miner.  Furnace
	-- bootstrap accepts a horizontally adjacent face only.
	if destination.x == target.x and destination.z == target.z then
		return nil
	end
	return destination
end

local function support_key(pos)
	pos = vector.round(pos)
	if minetest.hash_node_position then
		return minetest.hash_node_position(pos)
	end
	return table.concat({pos.x, pos.y, pos.z}, ":")
end

local function protect_support_area(result, anchor)
	if type(anchor) ~= "table" or type(anchor.x) ~= "number"
			or type(anchor.y) ~= "number" or type(anchor.z) ~= "number" then
		return
	end
	anchor = vector.round(anchor)
	for dx = -1, 1 do
		for dz = -1, 1 do
			result[support_key({x = anchor.x + dx, y = anchor.y - 1,
				z = anchor.z + dz})] = true
		end
	end
end

local function protect_villager_anchors(result, villager)
	if not villager then
		return
	end
	if villager.object and villager.object.get_pos then
		protect_support_area(result, villager.object:get_pos())
	end
	for _, field in ipairs(protected_anchor_fields) do
		protect_support_area(result, villager.pos_data and villager.pos_data[field])
	end
end

local function build_support_guard(self, storage_pos, include_workbenches)
	local result = {}
	for _, chest_pos in ipairs(get_shared_storage_chests(self, storage_pos)) do
		protect_support_area(result, chest_pos)
	end

	-- Protect every compatible workbench, including VoxeLibre nodes which do
	-- not necessarily expose the traditional crafting-table groups.
	if include_workbenches and storage_pos
			and type(minetest.find_nodes_in_area) == "function" then
		local names = {"group:crafting_table", "group:workbench"}
		if compat.get_crafting_table_items then
			for _, name in ipairs(compat.get_crafting_table_items()) do
				names[#names + 1] = name
			end
		end
		local minp = vector.subtract(storage_pos, bootstrap_utility_range)
		local maxp = vector.add(storage_pos, bootstrap_utility_range)
		for _, pos in ipairs(minetest.find_nodes_in_area(minp, maxp, names) or {}) do
			protect_support_area(result, pos)
		end
	end

	protect_villager_anchors(result, self)
	for _, lua in pairs(minetest.luaentities or {}) do
		if lua ~= self and (lua.owner_name or "") == (self.owner_name or "")
				and working_villages.is_villager
				and working_villages.is_villager(lua.name) then
			protect_villager_anchors(result, lua)
		end
	end
	return result
end

local function is_protected_support(guard, pos)
	return guard and guard[support_key(pos)] == true
end

local function is_loose_ground(node_name)
	if not node_name or node_name == "" then
		return false
	end
	if minetest.get_item_group(node_name, "soil") > 0 then
		return true
	end
	if minetest.get_item_group(node_name, "crumbly") > 0 then
		return true
	end
	if node_name:find("dirt", 1, true) or node_name:find("gravel", 1, true) or node_name:find("sand", 1, true) then
		return true
	end
	return false
end

local function is_tunnel_diggable(node_name)
	if not node_name or node_name == "" or node_name == "air" or node_name == "ignore" then
		return false
	end
	if minetest.get_item_group(node_name, "liquid") > 0 then
		return false
	end
	if is_infrastructure_node(node_name) then
		return false
	end
	if minetest.get_item_group(node_name, "wood") > 0 or minetest.get_item_group(node_name, "tree") > 0 then
		return false
	end
	local def = minetest.registered_nodes[node_name]
	if not def or def.diggable == false then
		return false
	end
	return is_mineable(node_name) or is_loose_ground(node_name)
end

local function dir_to_key(dir)
	if not dir then
		return nil
	end
	return (dir.x or 0) .. ":" .. (dir.z or 0)
end

local function key_to_dir(key)
	if type(key) ~= "string" then
		return nil
	end
	local x, z = key:match("^(-?%d+):(-?%d+)$")
	if not x or not z then
		return nil
	end
	x = tonumber(x) or 0
	z = tonumber(z) or 0
	if (x == 0 and z == 0) or (x ~= 0 and z ~= 0) then
		return nil
	end
	return {x = x, y = 0, z = z}
end

local function rotate_dir(dir)
	local key = dir_to_key(dir)
	for index, candidate in ipairs(cardinal_dirs) do
		if dir_to_key(candidate) == key then
			local next_index = (index % #cardinal_dirs) + 1
			return vector.new(cardinal_dirs[next_index])
		end
	end
	return vector.new(cardinal_dirs[1])
end

local function read_mine_dir(self)
	self.job_data = self.job_data or {}
	return key_to_dir(self.job_data.miner_tunnel_dir)
end

local function write_mine_dir(self, dir)
	self.job_data = self.job_data or {}
	self.job_data.miner_tunnel_dir = dir_to_key(dir)
	return dir
end

local function pick_surface_mine_site(self)
	self.job_data = self.job_data or {}
	local shared = working_villages.get_shared_storage_pos
		and working_villages.get_shared_storage_pos(self.owner_name) or nil
	local center = vector.round(shared or self.object:get_pos())
	local preferred = read_mine_dir(self)
	local dirs = {}
	if preferred then
		dirs[#dirs + 1] = preferred
	end
	for _, dir in ipairs(cardinal_dirs) do
		local duplicate = false
		for _, existing in ipairs(dirs) do
			if dir_to_key(existing) == dir_to_key(dir) then
				duplicate = true
				break
			end
		end
		if not duplicate then
			dirs[#dirs + 1] = dir
		end
	end
	for _, dir in ipairs(dirs) do
		for distance = 8, 14, 2 do
			local probe = {x = center.x + dir.x * distance, y = center.y + 4, z = center.z + dir.z * distance}
			local ground = func.find_ground_below(probe)
			if ground and not func.is_protected(self, ground) then
				write_mine_dir(self, dir)
				self.job_data.mine_surface_pos = vector.round(ground)
				return self.job_data.mine_surface_pos, dir
			end
		end
	end
	local fallback = func.find_ground_below(vector.add(center, {x = 0, y = 4, z = 8})) or vector.round(self.object:get_pos())
	local fallback_dir = preferred or vector.new(cardinal_dirs[3])
	write_mine_dir(self, fallback_dir)
	self.job_data.mine_surface_pos = vector.round(fallback)
	return self.job_data.mine_surface_pos, fallback_dir
end

local function find_mine_entrance_site(self, radius)
	local shared = working_villages.get_shared_storage_pos
		and working_villages.get_shared_storage_pos(self.owner_name) or self.object:get_pos()
	local minp = vector.subtract(vector.round(shared), radius or 40)
	local maxp = vector.add(vector.round(shared), radius or 40)
	local markers = minetest.find_nodes_in_area(minp, maxp, {"working_villages:building_marker"})
	local best_pos = nil
	local best_state = nil
	local best_dist = nil
	for _, marker in ipairs(markers) do
		local meta = minetest.get_meta(marker)
		if meta:get_string("owner") == (self.owner_name or "") then
			local schematic = working_villages.normalize_blueprint_name and working_villages.normalize_blueprint_name(meta:get_string("schematic")) or meta:get_string("schematic")
			local state = meta:get_string("state")
			if schematic == "mine_entrance" and state ~= "planned" then
				local build_pos = working_villages.buildings and working_villages.buildings.get_build_pos and working_villages.buildings.get_build_pos(meta) or nil
				if build_pos then
					local dist = vector.distance(self.object:get_pos(), build_pos)
					if not best_dist or dist < best_dist then
						best_dist = dist
						best_pos = vector.round(build_pos)
						best_state = state
					end
				end
			end
		end
	end
	return best_pos, best_state
end

local function get_mining_anchor(self)
	local build_pos, state = find_mine_entrance_site(self, 40)
	if build_pos then
		self.job_data = self.job_data or {}
		self.job_data.mine_surface_pos = nil
		write_mine_dir(self, vector.new(cardinal_dirs[3]))
		local staging = func.find_ground_below(vector.add(build_pos, {x = 2, y = 4, z = 4})) or vector.add(build_pos, {x = 2, y = 1, z = 4})
		return vector.round(staging), read_mine_dir(self), state == "built"
	end
	local surface_pos, dir = pick_surface_mine_site(self)
	return surface_pos, dir, false
end

local function try_open_mine(self)
	local anchor, dir, has_built_entrance = get_mining_anchor(self)
	if not anchor or not dir then
		return false
	end
	if vector.distance(self.object:get_pos(), anchor) > 4 then
		if has_built_entrance then
			self:set_state_info("Je rejoins l'entree de mine du village.")
			self:set_displayed_action("rejoint la mine")
		else
			self:set_state_info("Je cherche un bon endroit pour ouvrir une galerie.")
			self:set_displayed_action("cherche une zone de mine")
		end
		self:go_to(anchor)
		return true
	end

	local current = vector.round(self.object:get_pos())
	local head_target = {x = current.x + dir.x, y = current.y, z = current.z + dir.z}
	local body_target = {x = current.x + dir.x, y = current.y - 1, z = current.z + dir.z}
	local destination = body_target
	local head_node = minetest.get_node_or_nil(head_target)
	local body_node = minetest.get_node_or_nil(body_target)
	local below_target = vector.add(body_target, {x = 0, y = -1, z = 0})

	if func.is_protected(self, head_target) or func.is_protected(self, body_target) then
		return false
	end

	local dig_target = nil
	if head_node and head_node.name ~= "air" then
		if is_tunnel_diggable(head_node.name) then
			dig_target = head_target
		else
			write_mine_dir(self, rotate_dir(dir))
			return false
		end
	elseif body_node and body_node.name ~= "air" then
		if is_tunnel_diggable(body_node.name) then
			dig_target = body_target
		else
			write_mine_dir(self, rotate_dir(dir))
			return false
		end
	elseif not can_stand_at(destination) then
		local below_node = minetest.get_node_or_nil(below_target)
		if below_node and below_node.name ~= "air" and is_tunnel_diggable(below_node.name) then
			dig_target = below_target
		else
			write_mine_dir(self, rotate_dir(dir))
			return false
		end
	end

	if dig_target then
		if not reserve_miner_target(self, dig_target, 20) then
			write_mine_dir(self, rotate_dir(dir))
			return false
		end
		local stand = func.find_adjacent_clear(dig_target)
		if stand then
			stand = func.find_ground_below(stand) or stand
		end
		if stand == false then
			stand = current
		end
		self:set_state_info("J'ouvre une galerie pour atteindre les minerais.")
		self:set_displayed_action("creuse une galerie")
		local reached = self:go_to(stand)
		local dug = reached and self:dig(dig_target, true)
		release_miner_target(self, dig_target)
		if not reached or not dug then
			working_villages.failed_pos_record(dig_target)
			return false
		end
		if self:timer_exceeded("miner:announce", 120) then
			self:announce_action("J'ouvre une galerie de mine pour le village.")
		end
		return true
	end

	self:set_state_info("Je descends dans la galerie pour trouver du minerai.")
	self:set_displayed_action("descend dans la mine")
	self:go_to(destination)
	return true
end

local function notify_blacksmith(self, item_name)
	if not comm then
		return
	end
	local targets = comm.find_nearby_villagers(self.object:get_pos(), 30,
		"working_villages:job_blacksmith", self.owner_name)
	if #targets == 0 then
		return
	end
	comm.broadcast(self, targets, "resource_found", {
		resource = item_name,
		pos = self.object:get_pos(),
	})
end

-- Find a mineable block nearby
local function find_mineable_block(self, p, support_guard)
	local node = minetest.get_node(p)
	
	if is_infrastructure_node(node.name) or not is_mineable(node.name) then
		return false
	end
	if is_protected_support(support_guard, p) then
		return false
	end
	if self.is_position_reserved and self:is_position_reserved("miner_target", p) then
		return false
	end
	
	-- Don't mine protected areas
	if func.is_protected(self, p) then
		return false
	end
	
	-- Check if this position has failed before
	if working_villages.failed_pos_test(p) then
		return false
	end
	
	-- Prefer blocks that are not at surface level (y < 0 is underground)
	-- But also allow surface mining
	return true
end

-- Function to place torches in dark areas while mining
local function should_place_torch(pos)
	local light_level = minetest.get_node_light(pos)
	if not light_level then
		return false
	end
	return light_level < 8
end

local function put_func(_, stack, data)
	local name = stack:get_name()
	-- Keep pickaxes and torches
	if is_pickaxe(name) or name == torch_items.floor then
		return false
	end
	if data and data.furnace_bootstrap then
		-- Do one counted delivery once the durable chest + cargo total reaches
		-- eight.  Returning after every cobble made a busy village starve the
		-- quarry indefinitely.
		return data.furnace_bootstrap.mine_count <= 0
			and is_bootstrap_cobble_item(name)
	end
	return true
end

local function take_func(villager, stack, data)
	local name = stack:get_name()
	-- Take pickaxes if we don't have one, and torches if we're low
	if is_pickaxe(name) then
		local inv = villager:get_inventory()
		-- Check if we already have a pickaxe
		for i = 1, inv:get_size("main") do
			local itemstack = inv:get_stack("main", i)
			if is_pickaxe(itemstack:get_name()) then
				return false  -- Already have a pickaxe
			end
		end
		return true
	end
	
	if name == torch_items.floor then
		if data and data.furnace_bootstrap then
			return false
		end
		-- Take torches if we have less than 10
		local inv = villager:get_inventory()
		local torch_count = 0
		for i = 1, inv:get_size("main") do
			local itemstack = inv:get_stack("main", i)
			if itemstack:get_name() == torch_items.floor then
				torch_count = torch_count + itemstack:get_count()
			end
		end
		return torch_count < 10
	end
	
	return false
end

local searching_range = {x = 10, y = 10, z = 10}

working_villages.register_job("working_villages:job_miner", {
	description = "mineur (working_villages)",
	long_description = "Je mine la pierre et les minerais. "..
		"Je collecte des mineraux utiles et j'aide a creuser pour la construction. "..
		"J'ai besoin d'une pioche, j'ouvre une galerie si besoin et je pose des torches pour eclairer.",
	inventory_image = "default_paper.png^working_villages_miner.png",
	capabilities = {
		mining = true,
		ore_detection = true,
		torch_placement = true,
		auto_item_collection = true,
		underground_navigation = true,
	},
	on_start = function(self)
		-- Notify player about miner capabilities
		self:notify_job_feature(
			"Minage automatique",
			"Mine pierre et minerais, pose des torches, collecte automatiquement les items minés"
		)
	end,
	jobfunc = function(self)
		if self.equip_best_weapon then self:equip_best_weapon() end
		if self.equip_best_armor then self:equip_best_armor() end
		self:handle_night()
		local initial_furnace_demand = get_furnace_bootstrap_demand(self)
		self:handle_chest(take_func, put_func, initial_furnace_demand and {
			furnace_bootstrap = initial_furnace_demand,
			timer_id = "miner:furnace_bootstrap_chest",
			cooldown = 1,
			miss_cooldown = 1,
			max_miss_cooldown = 2,
			blocked_cooldown = 1,
		} or nil)
		self:handle_job_pos()
		
		self:count_timer("miner:search")
		self:count_timer("miner:change_dir")
		self:count_timer("miner:torch_check")
		self:count_timer("miner:announce")
		self:count_timer("miner:ore_alert")
		self:handle_obstacles()
		
		local inv = self:get_inventory()
		local has_pickaxe = work_fallback.ensure_tool(self, {
			key = "miner_pickaxe",
			tool_group = "pickaxe",
			tool_label = "une pioche",
			candidates = get_pickaxe_candidates(),
			craft = craft_basic_pickaxe,
			request = request_pickaxe,
			request_cooldown = 30,
			wait_info = "Il me manque une pioche. Je cherche ou demande l'outil et je ramasse des ressources en attendant.",
			announce = "Je cherche une pioche; en attendant, je rassemble ce qui peut servir au village.",
		})
		if not has_pickaxe then
			work_fallback.perform(self, {
				key = "miner_pickaxe",
				tool_group = "pickaxe",
				tool_label = "une pioche",
				activity_action = "ramasse des ressources",
				activity_info = "Je ramasse et transporte des ressources pendant que j'attends une pioche.",
				patrol_action = "cherche une pioche",
				patrol_info = "Je cherche des fournitures et je reverifie regulierement le coffre commun.",
			})
			return
		end
		
		if self:timer_exceeded("miner:search", 10) then
			local furnace_demand = get_furnace_bootstrap_demand(self)
			-- Collect any dropped items (from mining)
			local pos = self.object:get_pos()
			local objects = minetest.get_objects_inside_radius(pos, 5)
			for _, obj in ipairs(objects) do
				if obj:is_player() == false then
					local entity = obj:get_luaentity()
					if entity and entity.name == "__builtin:item" then
						local item = entity.itemstring
						if item then
							local itemstack = ItemStack(item)
							local useful_during_bootstrap = not furnace_demand
								or is_bootstrap_cobble_item(itemstack:get_name())
							if useful_during_bootstrap
									and inv:room_for_item("main", itemstack) then
								inv:add_item("main", itemstack)
								obj:remove()
								if is_ore_item(itemstack:get_name()) and self:timer_exceeded("miner:ore_alert", 120) then
									notify_blacksmith(self, itemstack:get_name())
								end
							end
						end
					end
				end
			end
			
			-- Prefer useful exposed ore over nearer generic stone.  Remember the
			-- first ore which needs a stronger pick while continuing the same scan:
			-- a farther harvestable vein wins without adding a third terrain scan.
			furnace_demand = get_furnace_bootstrap_demand(self)
			local target = nil
			local mining_furnace_cobble = false
			local bootstrap_destination = nil
			local blocked_ore = nil
			local blocked_ore_name = nil
			local support_guard = build_support_guard(
				self, furnace_demand and furnace_demand.storage_pos or
					(working_villages.get_shared_storage_pos
						and working_villages.get_shared_storage_pos(self.owner_name) or nil),
				furnace_demand ~= nil)

			if furnace_demand and furnace_demand.mine_count <= 0 then
				self:set_displayed_action("livre la pierre du four")
				self:set_state_info("J'ai les huit pierres du four; je les depose dans le coffre commun.")
				return
			elseif furnace_demand then
				-- Furnace bootstrap belongs to the village, not to the miner's
				-- current wandering position. Keep scanning around shared storage so
				-- a worker who drifted away can still return to a known quarry.
				local furnace_search_origin = furnace_demand.storage_pos
					or self.object:get_pos()
				target = func.search_surrounding(furnace_search_origin, function(candidate_pos)
					if not find_mineable_block(self, candidate_pos, support_guard) then
						return false
					end
					local node_name = minetest.get_node(candidate_pos).name
					if not node_drops_bootstrap_cobble(self, node_name) then
						return false
					end
					bootstrap_destination = get_safe_bootstrap_destination(
						self, candidate_pos, furnace_demand)
					return bootstrap_destination ~= nil
				end, searching_range)
				mining_furnace_cobble = target ~= nil
			end
			if furnace_demand and not target then
				self:set_displayed_action("cherche la pierre du four")
				self:set_state_info("Je ne trouve pas encore de pierre sure donnant du cobble pour le four commun.")
				return
			end

			if not target then
				target = func.search_surrounding(self.object:get_pos(), function(candidate_pos)
					if not find_mineable_block(self, candidate_pos, support_guard) then
						return false
					end
					local node_name = minetest.get_node(candidate_pos).name
					if not is_ore_node(node_name) then
						return false
					end
					if has_capable_pickaxe(self, node_name) then
						return true
					end
					if not blocked_ore then
						blocked_ore = {x = candidate_pos.x, y = candidate_pos.y, z = candidate_pos.z}
						blocked_ore_name = node_name
					end
					return false
				end, searching_range)
			end
			if not target and blocked_ore then
				if ensure_capable_pickaxe(self, blocked_ore_name) then
					target = blocked_ore
				else
					self:set_state_info("Il me faut une pioche plus solide pour ce filon; je mine de la pierre en attendant.")
				end
			end
			if not target then
				target = func.search_surrounding(self.object:get_pos(), function(candidate_pos)
					if not find_mineable_block(self, candidate_pos, support_guard) then
						return false
					end
					return has_capable_pickaxe(self, minetest.get_node(candidate_pos).name)
				end, searching_range)
			end
			if target then
				local target_name = minetest.get_node(target).name
				if not ensure_capable_pickaxe(self, target_name) then
					self:set_displayed_action("attend une pioche adaptee")
					return
				end
				if not reserve_miner_target(self, target, 20) then
					self:set_displayed_action("cherche un autre filon")
					return
				end
				local destination = mining_furnace_cobble
					and bootstrap_destination
					or get_mining_destination(target)
				if not destination then
					release_miner_target(self, target)
					working_villages.failed_pos_record(target)
					self:set_state_info("Ce filon est inaccessible, j'en cherche un autre.")
					self:set_displayed_action("filon inaccessible")
					return
				end
				
				self:set_displayed_action(mining_furnace_cobble
					and "mine la pierre du four" or "mine")
				local success = self:go_to(destination)
				if success then
					local dug = self:dig(target, true)
					release_miner_target(self, target)
					if not dug then
						working_villages.failed_pos_record(target)
						self:set_displayed_action("cherche un autre filon")
						return
					end
					
					-- Award experience for mining
					local inv_name = self:get_inventory_name()
					blueprints.add_experience(inv_name, 1)
					
					self:set_state_info(mining_furnace_cobble
						and "Je rassemble les huit pierres necessaires au four commun."
						or "Je mine des ressources utiles.")
					if self:timer_exceeded("miner:announce", 140) then
						self:announce_action("Je mine de la pierre et des minerais.")
					end
				else
					release_miner_target(self, target)
					working_villages.failed_pos_record(target)
					self:set_displayed_action("cherche un autre filon")
				end
			else
				if not try_open_mine(self) then
					self:set_state_info("Je cherche de la pierre ou du minerai.")
					self:set_displayed_action("cherche un filon")
				end
			end
		elseif self:timer_exceeded("miner:torch_check", 40) then
			-- Occasionally check if we should place a torch
			local pos = self.object:get_pos()
			if should_place_torch(pos) then
				local torch_name = compat.get_item("default:torch")
				if self:has_item_in_main(function(name) return name == torch_name end) then
					-- Try to place a torch on a nearby wall
					local dirs = {
						{x=1, y=0, z=0},
						{x=-1, y=0, z=0},
						{x=0, y=0, z=1},
						{x=0, y=0, z=-1},
					}
					for _, dir in ipairs(dirs) do
						local wall_pos = vector.add(pos, dir)
						local wall_node = minetest.get_node(wall_pos)
						if wall_node.name ~= "air" then
							local torch_pos = vector.subtract(wall_pos, dir)
							self:place(torch_name, torch_pos)
							self:set_displayed_action("pose une torche")
							self:announce_action("Je pose des torches pour eclairer les galeries.", 180)
							break
						end
					end
				end
			end
		elseif self:timer_exceeded("miner:change_dir", 25) then
			self:change_direction_randomly()
		end
	end,
})
