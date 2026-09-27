-- Multi-run acceptance test for a production-spawned five-villager economy.
--
-- The harness creates terrain resources, never inventory items. All villagers,
-- professions, crafting, containers, furnace work, deliveries and construction
-- are driven by the production callbacks. Run the same disposable world twice:
-- phase one stops during a real minimal-shelter build; phase two verifies the
-- saved identities/site, injects only need/danger stimuli, and requires recovery.

local OWNER = "working_villages_village_runtime_test_owner"
local HOSTILE = "working_villages_village_runtime_test:hostile"
local STATE_KEY = "village_runtime_state_v1"
local STATE_VERSION = 2
-- Furnace outputs and short requester-to-supplier hand-offs can be produced
-- and removed within the old 0.5 s observation window.  A 0.1 s sampler is
-- still lightweight (terrain/topology scans stay on their separate caches),
-- but it reliably witnesses the real inventory transition instead of turning
-- a successful fast worker into a false negative.
local POLL_SECONDS = 0.1
local TOPOLOGY_REFRESH_SECONDS = 1.0
local HEAVY_REFRESH_SECONDS = 2.0
-- A public-server economy is intentionally physical: workers can cross the
-- arena several times for tools, first-storage deliveries and materials.  Give
-- each restart phase thirty real minutes so the harness measures recovery and
-- accounting rather than failing a healthy but deliberately unaccelerated
-- delivery chain at the old fifteen-minute cutoff.
local TIMEOUT_SECONDS = 1800
local AREA_MIN = {x = -28, y = -3, z = -28}
local AREA_MAX = {x = 28, y = 16, z = 28}
local QUARRY_XS = {-8, 8}
-- Keep enough exposed stone for both the first stone tools and the eight-block
-- furnace recipe.  The old seven-node face exposed exactly eight cobbles in
-- total, so valid tool crafting could exhaust the fixture before the furnace
-- bootstrap and produce a false autonomy failure.
local QUARRY_Z_MIN = -9
local QUARRY_Z_MAX = 9
-- Production spawn deliberately scans a tall column (and may use the game's
-- suggested mapgen level).  Clear that whole column once, while keeping the
-- frequent economy scans bounded to AREA_MAX above.
local PAD_CLEAR_MAX = {x = AREA_MAX.x, y = 192, z = AREA_MAX.z}
local profile = working_villages.game_profile.id
local compat = working_villages.compat
local farming = working_villages.farming_compat
local storage = minetest.get_mod_storage()
local finished = false
local started_at = minetest.get_us_time() / 1000000
local danger_runtime = nil
local furnace_runtime = {}
local voxelibre_growth_ids = nil
local area_kept_loaded = false
local observation_cache = {
	topology_at = -math.huge,
	world_at = -math.huge,
	growth_at = -math.huge,
	chests = {},
	furnaces = {},
	markers = {},
	world = nil,
}

minetest.register_entity(HOSTILE, {
	initial_properties = {
		physical = false,
		pointable = false,
		visual = "sprite",
		textures = {"blank.png"},
		static_save = false,
	},
	spawn_class = "hostile",
	type = "monster",
	attack_npcs = true,
})

local function fail(message)
	error("[working_villages_village_runtime_test] " .. tostring(message), 2)
end

local function assert_true(value, message)
	if not value then
		fail(message or "expected a truthy value")
	end
end

local function load_state()
	local encoded = storage:get_string(STATE_KEY)
	if encoded == "" then
		return {
			version = STATE_VERSION,
			phase = 1,
			milestones = {},
			roles_seen = {},
			dig_events = {
				tree = 0, ore = 0, quarry_stone = 0,
				mature_crop = 0, seed_source = 0,
			},
			harvest_events = {},
			delivery_observations = {},
		}
	end
	local ok, value = pcall(minetest.deserialize, encoded)
	assert_true(ok and type(value) == "table", "persisted harness state is invalid")
	assert_true(value.version == STATE_VERSION, "persisted harness state version mismatch")
	value.milestones = type(value.milestones) == "table" and value.milestones or {}
	value.roles_seen = type(value.roles_seen) == "table" and value.roles_seen or {}
	value.dig_events = type(value.dig_events) == "table" and value.dig_events or {}
	value.harvest_events = type(value.harvest_events) == "table" and value.harvest_events or {}
	value.delivery_observations = type(value.delivery_observations) == "table"
		and value.delivery_observations or {}
	return value
end

local state = load_state()

local function save_state()
	state.version = STATE_VERSION
	storage:set_string(STATE_KEY, minetest.serialize(state))
end

local function finish(ok, message)
	if finished then
		return
	end
	finished = true
	if not ok then
		minetest.log("error", "WORKING_VILLAGES_VILLAGE_RUNTIME_FAILED:" .. profile
			.. ":" .. tostring(message))
	end
	minetest.request_shutdown(
		ok and (message or "working_villages village runtime phase completed")
			or "working_villages village runtime test failed",
		false,
		0
	)
end

local function protected(callback)
	if finished then
		return
	end
	local ok, err = xpcall(callback, debug.traceback)
	if not ok then
		finish(false, err)
	end
end

local function schedule(delay, callback)
	minetest.after(delay, function()
		protected(callback)
	end)
end

local function mark(key, detail)
	if state.milestones[key] then
		return false
	end
	state.milestones[key] = {
		at = minetest.get_gametime(),
		detail = detail or "",
		phase = state.phase,
	}
	save_state()
	minetest.log("action", "VILLAGE_RUNTIME_" .. key .. "_OK:" .. profile
		.. (detail and detail ~= "" and (":" .. tostring(detail)) or ""))
	return true
end

local function choose_registered(candidates, predicate, label)
	for _, name in ipairs(candidates or {}) do
		if minetest.registered_nodes[name] and (not predicate or predicate(name)) then
			return name
		end
	end
	fail("active game exposes no " .. tostring(label))
end

local function drop_mentions_group(value, group, depth)
	depth = depth or 0
	if depth > 8 then
		return false
	end
	if type(value) == "string" then
		return minetest.get_item_group(ItemStack(value):get_name(), group) > 0
	end
	if type(value) ~= "table" then
		return false
	end
	for _, entry in pairs(value) do
		if drop_mentions_group(entry, group, depth + 1) then
			return true
		end
	end
	return false
end

local seed_items = {}
for _, plant in pairs(farming.get_plants() or {}) do
	for _, seed in ipairs(plant.replant or {}) do
		seed_items[seed] = true
	end
end

local function is_seed_item_name(name)
	return type(name) == "string" and name ~= "" and (
		seed_items[name] == true or minetest.get_item_group(name, "seed") > 0)
end

local function drop_mentions_seed(value, depth)
	depth = depth or 0
	if depth > 8 then
		return false
	end
	if type(value) == "string" then
		return is_seed_item_name(ItemStack(value):get_name())
	end
	if type(value) ~= "table" then
		return false
	end
	for _, entry in pairs(value) do
		if drop_mentions_seed(entry, depth + 1) then
			return true
		end
	end
	return false
end

local function choose_seed_source()
	local preferred = profile == "voxelibre" and {
		"mcl_flowers:tallgrass", "mcl_flowers:fern",
	} or {
		"default:grass_1", "default:grass_2", "default:grass_3",
		"default:grass_4", "default:grass_5", "default:junglegrass",
	}
	for _, name in ipairs(preferred) do
		local def = minetest.registered_nodes[name]
		if def and def.buildable_to and (drop_mentions_seed(def.drop)
				or minetest.get_item_group(name, "flora") > 0) then
			return name
		end
	end
	for name, def in pairs(minetest.registered_nodes or {}) do
		local lower = name:lower()
		local grass_like = (lower:find("grass", 1, true)
			or lower:find("fern", 1, true))
			and (def.buildable_to or minetest.get_item_group(name, "flora") > 0)
			and minetest.get_item_group(name, "soil") == 0
		if grass_like and (drop_mentions_seed(def.drop)
				or minetest.get_item_group(name, "flora") > 0)
				and not farming.is_plant(name) then
			return name
		end
	end
	fail("active game exposes no natural seed source")
end

local function choose_leaves()
	local preferred = profile == "voxelibre" and {
		"mcl_core:leaves", "mcl_core:leaves_oak",
	} or {"default:leaves"}
	for _, name in ipairs(preferred) do
		local def = minetest.registered_nodes[name]
		if def and minetest.get_item_group(name, "leaves") > 0
				and drop_mentions_group(def.drop, "sapling") then
			return name
		end
	end
	for name, def in pairs(minetest.registered_nodes or {}) do
		if minetest.get_item_group(name, "leaves") > 0
				and drop_mentions_group(def.drop, "sapling") then
			return name
		end
	end
	return nil
end

local function choose_water()
	for _, name in ipairs({"mcl_core:water_source", "default:water_source"}) do
		local def = minetest.registered_nodes[name]
		if def and minetest.get_item_group(name, "water") > 0 then
			return name
		end
	end
	return nil
end

local function setup_resource_pad()
	assert_true(profile == "voxelibre" or profile == "minetest_game",
		"unsupported game profile " .. tostring(profile))
	local stone = choose_registered({
		compat.get_item("default:stone"), "default:stone", "mcl_core:stone",
	}, nil, "stone")
	local cobble = choose_registered({
		compat.get_item("default:cobble"), "default:cobble", "mcl_core:cobble",
	}, nil, "cobblestone")
	local dirt = choose_registered({
		"mcl_core:dirt_with_grass", "default:dirt_with_grass",
		"mcl_core:dirt", "default:dirt",
	}, compat.is_tillable_dirt, "tillable ground")
	local tree = choose_registered({
		compat.get_item("default:tree"), "default:tree", "mcl_core:tree",
	}, function(name) return minetest.get_item_group(name, "tree") > 0 end, "tree trunk")
	local ore = choose_registered({
		compat.get_item("default:stone_with_iron"),
		"default:stone_with_iron", "mcl_core:stone_with_iron",
	}, nil, "iron ore")
	local seed_source = choose_seed_source()
	local leaves = choose_leaves()
	local water = choose_water()
	state.resources = {
		stone = stone,
		cobble = cobble,
		dirt = dirt,
		tree = tree,
		ore = ore,
		seed_source = seed_source,
		leaves = leaves,
		water = water,
	}

	minetest.load_area(AREA_MIN, PAD_CLEAR_MAX)
	local manip = VoxelManip()
	local emerged_min, emerged_max = manip:read_from_map(AREA_MIN, PAD_CLEAR_MAX)
	local voxel_area = VoxelArea:new({MinEdge = emerged_min, MaxEdge = emerged_max})
	local data = manip:get_data()
	local air_id = minetest.get_content_id("air")
	local stone_id = minetest.get_content_id(stone)
	local dirt_id = minetest.get_content_id(dirt)
	for x = AREA_MIN.x, AREA_MAX.x do
		for z = AREA_MIN.z, AREA_MAX.z do
			-- A thick foundation keeps a headless actor inside the forced block
			-- even if a rare long engine step loses one collision response.
			for y = AREA_MIN.y, -1 do
				data[voxel_area:index(x, y, z)] = stone_id
			end
			data[voxel_area:index(x, 0, z)] = dirt_id
			for y = 1, PAD_CLEAR_MAX.y do
				data[voxel_area:index(x, y, z)] = air_id
			end
		end
	end
	manip:set_data(data)
	manip:write_to_map()
	manip:update_map()

	-- Keep the headless actors inside the 16 force-loaded mapblocks. This is a
	-- test-arena boundary, not an injected economic resource: it is outside all
	-- farm/quarry/tree searches and uses bedrock where the active game exposes
	-- it. Zone unload/reload behavior has its own P1 scenario.
	local boundary = minetest.registered_nodes["mcl_core:bedrock"]
		and "mcl_core:bedrock" or stone
	for offset = -24, 24 do
		for y = 1, 3 do
			minetest.set_node({x = -24, y = y, z = offset}, {name = boundary})
			minetest.set_node({x = 24, y = y, z = offset}, {name = boundary})
			minetest.set_node({x = offset, y = y, z = -24}, {name = boundary})
			minetest.set_node({x = offset, y = y, z = 24}, {name = boundary})
		end
	end

	local water_sites = {
		{x = -4, z = -4}, {x = 4, z = -4},
		{x = -4, z = 4}, {x = 4, z = 4},
	}
	if water then
		for _, site in ipairs(water_sites) do
			minetest.set_node({x = site.x, y = 0, z = site.z}, {name = water})
		end
	end

	local tree_sites = {
		{x = -10, z = -8}, {x = -6, z = -10}, {x = -2, z = -10},
		{x = 2, z = -10}, {x = 6, z = -10}, {x = 10, z = -8},
		{x = -10, z = 8}, {x = -6, z = 10}, {x = -2, z = 10},
		{x = 2, z = 10}, {x = 6, z = 10}, {x = 10, z = 8},
		-- The complete economy consumes wood for storage, primitive tools,
		-- furnace fuel and the 27-node shelter.  A twelve-tree micro-grove made
		-- the result depend on a random sapling timer after every legitimate
		-- consumer had exhausted it.  This second ring remains ordinary world
		-- nodes which villagers must find, fell, replant and transport; it only
		-- gives the fresh-world scenario a forest-sized deterministic budget.
		{x = -16, z = -12}, {x = -12, z = -16}, {x = -7, z = -16},
		{x = -2, z = -16}, {x = 3, z = -16}, {x = 8, z = -16},
		{x = 13, z = -15}, {x = 16, z = -10}, {x = 16, z = 10},
		{x = 12, z = 16}, {x = 6, z = 16}, {x = -1, z = 16},
		{x = -8, z = 16}, {x = -14, z = 14}, {x = -16, z = 8},
		{x = -16, z = -4},
	}
	for _, site in ipairs(tree_sites) do
		for y = 1, 3 do
			minetest.set_node({x = site.x, y = y, z = site.z}, {name = tree})
		end
		if leaves then
			for x = site.x - 1, site.x + 1 do
				for z = site.z - 1, site.z + 1 do
					minetest.set_node({x = x, y = 4, z = z}, {name = leaves})
				end
			end
			minetest.set_node({x = site.x, y = 5, z = site.z}, {name = leaves})
		end
	end

	-- Two exposed, walkable quarry faces keep genuine ore near every possible
	-- production spawn point without placing ore items in an inventory.
	for _, x in ipairs(QUARRY_XS) do
		for z = QUARRY_Z_MIN, QUARRY_Z_MAX do
			local name = (z % 2 == 0) and ore or stone
			minetest.set_node({x = x, y = 1, z = z}, {name = name})
			minetest.set_node({x = x, y = 2, z = z}, {name = ore})
		end
	end

	local source_count = 0
	for x = -12, 12, 2 do
		for z = -12, 12, 2 do
			local central = math.abs(x) <= 3 and math.abs(z) <= 3
			local occupied = minetest.get_node({x = x, y = 1, z = z}).name ~= "air"
			if not central and not occupied then
				minetest.set_node({x = x, y = 1, z = z}, {name = seed_source})
				if minetest.get_node({x = x, y = 1, z = z}).name == seed_source then
					source_count = source_count + 1
				end
			end
		end
	end
	assert_true(source_count >= 80, "natural seed field is too small: " .. source_count)
	state.initial_world = {
		trees = #minetest.find_nodes_in_area(AREA_MIN, AREA_MAX, {"group:tree"}),
		ores = #minetest.find_nodes_in_area(AREA_MIN, AREA_MAX, {ore}),
		seed_sources = source_count,
		saplings = #minetest.find_nodes_in_area(AREA_MIN, AREA_MAX, {"group:sapling"}),
	}
	state.world_ready = true
	save_state()
	minetest.log("action", "VILLAGE_RUNTIME_FRESH_WORLD_OK:" .. profile
		.. ":trees=" .. state.initial_world.trees
		.. ":ore=" .. state.initial_world.ores
		.. ":seed_sources=" .. source_count)
end

local function keep_area_loaded()
	if area_kept_loaded then
		return
	end
	minetest.load_area(AREA_MIN, AREA_MAX)
	if minetest.forceload_block then
		-- The 57x57 pad spans exactly four mapblocks on each horizontal axis.
		-- Load both vertical layers crossed by the collision floor. A long engine
		-- step can otherwise move an entity from y=0 into the y=-1 mapblock and
		-- unload it before the next anti-embedding callback. The test profile raises
		-- max_forceloaded_blocks to 64; these 32 blocks remain test-arena state.
		for x = -32, 16, 16 do
			for z = -32, 16, 16 do
				for _, y in ipairs({-16, 0}) do
					assert_true(minetest.forceload_block({x = x, y = y, z = z}, true),
						("could not forceload village mapblock at %d,%d,%d"):format(x, y, z))
				end
			end
		end
	end
	area_kept_loaded = true
end

local function count_inventory_names(inv)
	local result = {}
	if not inv then return result end
	for _, list in pairs(inv:get_lists() or {}) do
		for _, stack in ipairs(list or {}) do
			if not stack:is_empty() then
				local name = stack:get_name()
				result[name] = (result[name] or 0) + stack:get_count()
			end
		end
	end
	return result
end

local function configured_cobble_name()
	local persisted = state.resources and state.resources.cobble
	if type(persisted) == "string" and persisted ~= "" then return persisted end
	return compat.get_item and compat.get_item("default:cobble") or ""
end

local function is_quarry_stone_position(pos)
	if not pos or pos.y ~= 1 or pos.z < QUARRY_Z_MIN or pos.z > QUARRY_Z_MAX
			or pos.z % 2 == 0 then
		return false
	end
	for _, x in ipairs(QUARRY_XS) do
		if pos.x == x then return true end
	end
	return false
end

local function count_remaining_quarry_stone()
	local stone = state.resources and state.resources.stone
	if type(stone) ~= "string" or stone == "" then return 0 end
	local count = 0
	for _, x in ipairs(QUARRY_XS) do
		for z = QUARRY_Z_MIN, QUARRY_Z_MAX do
			local pos = {x = x, y = 1, z = z}
			if is_quarry_stone_position(pos) and minetest.get_node(pos).name == stone then
				count = count + 1
			end
		end
	end
	return count
end

local function is_compatible_chest_name(name)
	if type(name) ~= "string" or name == "" then return false end
	if minetest.get_item_group(name, "chest") > 0
			or minetest.get_item_group(name, "villager_chest") > 0 then
		return true
	end
	return type(compat.is_chest) == "function" and compat.is_chest(name) == true
end

local function is_compatible_furnace_name(name)
	if type(name) ~= "string" or name == "" then return false end
	if minetest.get_item_group(name, "furnace") > 0 then return true end
	return type(compat.is_furnace) == "function" and compat.is_furnace(name) == true
end

-- Some supported-game furnaces (notably mcl_furnaces:furnace) expose no
-- `furnace` group. Build one exact-name query from the registered nodes and run
-- a single area search, rather than performing a second expensive world scan.
local topology_queries = {"working_villages:building_marker"}
for name in pairs(minetest.registered_nodes or {}) do
	if is_compatible_chest_name(name) or is_compatible_furnace_name(name) then
		topology_queries[#topology_queries + 1] = name
	end
end
table.sort(topology_queries)

local function cache_position_less(left, right)
	if left.x ~= right.x then return left.x < right.x end
	if left.y ~= right.y then return left.y < right.y end
	return left.z < right.z
end

local function node_matches_cache_kind(name, kind)
	if kind == "chests" then
		return is_compatible_chest_name(name)
	elseif kind == "furnaces" then
		return is_compatible_furnace_name(name)
	end
	return name == "working_villages:building_marker"
end

local topology_node_names_logged = {}

local function log_topology_node_name(kind, name)
	local key = kind .. "|" .. name
	if topology_node_names_logged[key] then return end
	topology_node_names_logged[key] = true
	minetest.log("action", "VILLAGE_RUNTIME_TOPOLOGY_NODE_OBSERVED:" .. profile
		.. ":" .. kind .. "=" .. name)
end

local function refresh_topology(force)
	local now = minetest.get_us_time() / 1000000
	if not force and now - observation_cache.topology_at < TOPOLOGY_REFRESH_SECONDS then
		return false
	end
	local fresh = {chests = {}, furnaces = {}, markers = {}}
	for _, pos in ipairs(minetest.find_nodes_in_area(AREA_MIN, AREA_MAX, topology_queries)) do
		local rounded = vector.round(pos)
		local name = minetest.get_node(rounded).name
		if node_matches_cache_kind(name, "chests") then
			fresh.chests[#fresh.chests + 1] = rounded
			log_topology_node_name("chest", name)
		end
		if node_matches_cache_kind(name, "furnaces") then
			fresh.furnaces[#fresh.furnaces + 1] = rounded
			log_topology_node_name("furnace", name)
		end
		if node_matches_cache_kind(name, "markers") then
			fresh.markers[#fresh.markers + 1] = rounded
		end
	end
	for _, kind in ipairs({"chests", "furnaces", "markers"}) do
		table.sort(fresh[kind], cache_position_less)
		observation_cache[kind] = fresh[kind]
	end
	observation_cache.topology_at = minetest.get_us_time() / 1000000
	return true
end

local function cached_positions(kind, force_discovery)
	refresh_topology(force_discovery == true)
	local valid = {}
	for _, pos in ipairs(observation_cache[kind] or {}) do
		if node_matches_cache_kind(minetest.get_node(pos).name, kind) then
			valid[#valid + 1] = pos
		end
	end
	observation_cache[kind] = valid
	return valid
end

local function find_harvester_id(pos)
	local best_id, best_distance = nil, math.huge
	for _, lua in pairs(minetest.luaentities or {}) do
		if lua and lua.name and working_villages.is_villager(lua.name)
				and lua.owner_name == OWNER and lua.inventory_name
				and lua.get_job_name and lua:get_job_name() == "working_villages:job_farmer"
				and lua.object and lua.object:get_pos() then
			local distance = vector.distance(lua.object:get_pos(), pos)
			if distance < best_distance then
				best_id, best_distance = lua.inventory_name, distance
			end
		end
	end
	return best_distance <= 6 and best_id or nil
end

local harvest_probe = {
	node_dig = minetest.node_dig,
	pickup_item = working_villages.villager.pickup_item,
	put_from_inventory = working_villages.inventory_access.put_from_inventory,
	association_seconds = 30,
}

assert_true(type(harvest_probe.node_dig) == "function", "node_dig instrumentation target missing")
assert_true(type(harvest_probe.pickup_item) == "function", "pickup_item instrumentation target missing")
assert_true(type(harvest_probe.put_from_inventory) == "function",
	"put_from_inventory instrumentation target missing")

function harvest_probe.positive_delta(before, after)
	local delta = {}
	for name, count in pairs(after or {}) do
		local gained = count - ((before or {})[name] or 0)
		if gained > 0 then delta[name] = gained end
	end
	return delta
end

function harvest_probe.merge_counts(target, added)
	for name, count in pairs(added or {}) do
		if count > 0 then target[name] = (target[name] or 0) + count end
	end
end

function harvest_probe.copy_counts(source)
	local copy = {}
	harvest_probe.merge_counts(copy, source)
	return copy
end

function harvest_probe.products_from_gains(gains)
	local products = {}
	for name, count in pairs(gains or {}) do
		if count > 0 and not is_seed_item_name(name) then products[name] = count end
	end
	if next(products) == nil then
		-- Root crops use their edible product as their own seed. Reserve one real
		-- acquired unit for replanting and require every remaining unit in storage.
		for name, count in pairs(gains or {}) do
			if is_seed_item_name(name) and count > 1 then products[name] = count - 1 end
		end
	end
	return products
end

function harvest_probe.count_list(inv, listname)
	local counts = {}
	if not inv or type(inv.get_list) ~= "function" then return counts end
	for _, stack in ipairs(inv:get_list(listname) or {}) do
		if not stack:is_empty() then
			local name = stack:get_name()
			counts[name] = (counts[name] or 0) + stack:get_count()
		end
	end
	return counts
end

function harvest_probe.is_farmer(villager)
	return villager and villager.owner_name == OWNER and villager.inventory_name
		and type(villager.get_job_name) == "function"
		and villager:get_job_name() == "working_villages:job_farmer"
end

function harvest_probe.recent_event(villager)
	if not harvest_probe.is_farmer(villager) then return nil end
	local now = minetest.get_gametime()
	local villager_pos = villager.object and villager.object:get_pos() or nil
	for index = #(state.harvest_events or {}), 1, -1 do
		local event = state.harvest_events[index]
		local age = now - (tonumber(event.at) or now)
		-- A negative age means the engine gametime restarted while this persistent
		-- event and its dropped item entity survived. Exact farmer and position
		-- matching keep that restart recovery bounded.
		local recent = age < 0 or age <= harvest_probe.association_seconds
		local near = villager_pos and event.pos
			and vector.distance(villager_pos, event.pos) <= 6
		if not event.complete and event.pickup_pending ~= false
				and event.harvester_id == villager.inventory_name and recent and near then
			return event, index
		end
	end
	return nil
end

function harvest_probe.record_pickup(villager, before, after)
	local gains = harvest_probe.positive_delta(before, after)
	if next(gains) == nil then return end
	local event, index = harvest_probe.recent_event(villager)
	if not event then return end
	event.gains = type(event.gains) == "table" and event.gains or {}
	event.pickup_gains = type(event.pickup_gains) == "table" and event.pickup_gains or {}
	harvest_probe.merge_counts(event.gains, gains)
	harvest_probe.merge_counts(event.pickup_gains, gains)
	event.products = harvest_probe.products_from_gains(event.gains)
	event.pickup_observed = true
	event.pickup_pending = false
	event.acquired_at = minetest.get_gametime()
	save_state()
	minetest.log("action", "VILLAGE_RUNTIME_HARVEST_PICKUP_OBSERVED:" .. profile
		.. ":event=" .. index .. ":farmer=" .. villager.inventory_name
		.. ":gains=" .. minetest.serialize(gains)
		.. ":products=" .. minetest.serialize(event.products))
end

function harvest_probe.record_exact_deposit(villager, item_name, moved, removed, added, pos, node_name)
	local remaining, credited = moved, 0
	for index, event in ipairs(state.harvest_events or {}) do
		local required = event.products and tonumber(event.products[item_name]) or 0
		local already = event.deposited and tonumber(event.deposited[item_name]) or 0
		if remaining > 0 and not event.complete and event.harvester_id == villager.inventory_name
				and required > already then
			local amount = math.min(remaining, required - already)
			event.deposited = type(event.deposited) == "table" and event.deposited or {}
			event.deposit_transfers = type(event.deposit_transfers) == "table"
				and event.deposit_transfers or {}
			event.deposited[item_name] = already + amount
			event.deposit_transfers[#event.deposit_transfers + 1] = {
				name = item_name,
				credited = amount,
				call_moved = moved,
				source_removed = removed,
				chest_added = added,
				chest_pos = vector.round(pos),
				chest_node = node_name,
				at = minetest.get_gametime(),
				exact = true,
			}
			remaining = remaining - amount
			credited = credited + amount
			minetest.log("action", "VILLAGE_RUNTIME_HARVEST_DEPOSIT_OBSERVED:" .. profile
				.. ":event=" .. index .. ":farmer=" .. villager.inventory_name
				.. ":item=" .. item_name .. ":credited=" .. amount
				.. ":moved=" .. moved .. ":source_removed=" .. removed
				.. ":chest_added=" .. added .. ":chest=" .. node_name)
		end
	end
	if credited > 0 then save_state() end
	return credited
end

minetest.node_dig = function(pos, node, digger)
	local old_name = node and node.name or minetest.get_node(pos).name
	local mature_crop = farming.is_plant(old_name)
	local digger_inv = digger and type(digger.get_inventory) == "function"
		and digger:get_inventory() or nil
	local before_inventory = mature_crop and count_inventory_names(digger_inv) or nil
	local ok, result = pcall(harvest_probe.node_dig, pos, node, digger)
	local owner = digger and digger._working_villages_owner_name or ""
	if owner == "" and digger and type(digger.get_player_name) == "function" then
		local player_ok, value = pcall(digger.get_player_name, digger)
		owner = player_ok and value or ""
	end
	if owner == OWNER and old_name and minetest.get_node(pos).name ~= old_name then
		if minetest.get_item_group(old_name, "tree") > 0 then
			state.dig_events.tree = (tonumber(state.dig_events.tree) or 0) + 1
		elseif state.resources and old_name == state.resources.ore then
			state.dig_events.ore = (tonumber(state.dig_events.ore) or 0) + 1
		elseif state.resources and old_name == state.resources.stone
				and is_quarry_stone_position(pos) then
			state.dig_events.quarry_stone =
				(tonumber(state.dig_events.quarry_stone) or 0) + 1
			minetest.log("action", "VILLAGE_RUNTIME_QUARRY_STONE_DUG:" .. profile
				.. ":count=" .. state.dig_events.quarry_stone
				.. ":node=" .. old_name
				.. ":pos=" .. minetest.pos_to_string(vector.round(pos), 0))
		elseif state.resources and old_name == state.resources.seed_source then
			state.dig_events.seed_source = (tonumber(state.dig_events.seed_source) or 0) + 1
		end
		if mature_crop then
			state.dig_events.mature_crop = (tonumber(state.dig_events.mature_crop) or 0) + 1
			local after_inventory = count_inventory_names(digger_inv)
			local gains = harvest_probe.positive_delta(before_inventory, after_inventory)
			state.harvest_events[#state.harvest_events + 1] = {
				pos = vector.round(pos),
				plant = old_name,
				harvester_id = find_harvester_id(pos),
				gains = gains,
				direct_gains = harvest_probe.copy_counts(gains),
				pickup_gains = {},
				products = harvest_probe.products_from_gains(gains),
				deposited = {},
				deposit_transfers = {},
				pickup_pending = true,
				acquired_at = next(gains) and minetest.get_gametime() or nil,
				at = minetest.get_gametime(),
			}
		end
		save_state()
	end
	if not ok then
		error(result, 0)
	end
	return result
end

working_villages.villager.pickup_item = function(self, ...)
	local observe = harvest_probe.is_farmer(self)
	local before = observe and count_inventory_names(self:get_inventory()) or nil
	local result = harvest_probe.pickup_item(self, ...)
	if observe then
		harvest_probe.record_pickup(self, before, count_inventory_names(self:get_inventory()))
	end
	return result
end

working_villages.inventory_access.put_from_inventory = function(
		self, source, source_list, source_index, pos, listname, preferred_index, maximum)
	local valid_source = source and type(source.get_stack) == "function"
		and type(source.get_size) == "function" and type(source_list) == "string"
		and type(source_index) == "number" and source_index >= 1
		and source_index <= source:get_size(source_list)
	local source_stack = valid_source and source:get_stack(source_list, source_index) or ItemStack()
	local item_name = source_stack:get_name()
	local node_name = pos and minetest.get_node(pos).name or ""
	local observe = harvest_probe.is_farmer(self) and source_list == "main"
		and listname == "main" and item_name ~= "" and is_compatible_chest_name(node_name)
	local target = observe and minetest.get_meta(pos):get_inventory() or nil
	local source_before = observe and harvest_probe.count_list(source, source_list) or nil
	local chest_before = observe and harvest_probe.count_list(target, listname) or nil
	local moved = harvest_probe.put_from_inventory(
		self, source, source_list, source_index, pos, listname, preferred_index, maximum)
	if observe and tonumber(moved) and moved > 0 then
		local source_after = harvest_probe.count_list(source, source_list)
		local chest_after = harvest_probe.count_list(target, listname)
		local removed = (source_before[item_name] or 0) - (source_after[item_name] or 0)
		local added = (chest_after[item_name] or 0) - (chest_before[item_name] or 0)
		if removed ~= moved or added ~= moved then
			state.harvest_accounting_error = "non-exact chest transfer for " .. item_name
				.. ": moved=" .. moved .. ", source_removed=" .. removed
				.. ", chest_added=" .. added .. ", chest=" .. node_name
			save_state()
			finish(false, state.harvest_accounting_error)
		else
			harvest_probe.record_exact_deposit(
				self, item_name, moved, removed, added, pos, node_name)
		end
	end
	return moved
end

local function loaded_villagers()
	local result = {}
	local duplicate = {}
	for _, lua in pairs(minetest.luaentities or {}) do
		if lua and lua.name and working_villages.is_villager(lua.name)
				and lua.owner_name == OWNER and lua.inventory_name then
			assert_true(not duplicate[lua.inventory_name],
				"duplicate loaded identity " .. lua.inventory_name)
			duplicate[lua.inventory_name] = true
			result[#result + 1] = lua
		end
	end
	table.sort(result, function(a, b) return a.inventory_name < b.inventory_name end)
	return result
end

local function same_array(left, right)
	if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then
		return false
	end
	for index, value in ipairs(left) do
		if right[index] ~= value then
			return false
		end
	end
	return true
end

local function deep_equal(left, right, seen)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	seen = seen or {}
	if seen[left] == right then return true end
	seen[left] = right
	for key, value in pairs(left) do
		if not deep_equal(value, right[key], seen) then return false end
	end
	for key in pairs(right) do
		if left[key] == nil then return false end
	end
	return true
end

local function clone_serializable(value, label)
	local encoded = minetest.serialize(value)
	assert_true(type(encoded) == "string", tostring(label) .. " is not serializable")
	local decoded = minetest.deserialize(encoded)
	assert_true(type(decoded) == type(value), tostring(label) .. " did not round-trip")
	return decoded
end

local persistent_job_keys = {
	"builder_marker", "collab_task", "collab_context", "pending_resource_message",
	"physical_delivery_state", "work_fallback", "blacksmith_orders",
	"blacksmith_order_index", "blacksmith_active_furnace", "blacksmith_furnace_site",
	"cook_furnace_pos", "cook_furnace_site", "mine_surface_pos", "miner_tunnel_dir",
	"woodcutter_hand_bootstrap", "auto_job_previous", "auto_job_target",
	"auto_job_reason", "tool_order_pending", "resting", "rest_pos",
}

local function exact_villager_snapshot(villagers)
	local result = {identities = {}, inventories = {}, job_states = {}}
	for _, villager in ipairs(villagers) do
		local id = villager.inventory_name
		result.identities[#result.identities + 1] = {
			id, villager.name or "", villager.owner_name or "", villager.nametag or "",
			villager.product_name or "", villager.manufacturing_number or "",
		}
		local lists = {}
		for list_name, list in pairs(villager:get_inventory():get_lists() or {}) do
			lists[list_name] = {}
			for index, stack in ipairs(list or {}) do
				lists[list_name][index] = stack:to_string()
			end
		end
		result.inventories[id] = lists
		local stable_job_data = {}
		for _, key in ipairs(persistent_job_keys) do
			local value = villager.job_data and villager.job_data[key]
			if value ~= nil then stable_job_data[key] = value end
		end
		result.job_states[id] = {
			job_name = villager:get_job_name(),
			data = clone_serializable(stable_job_data, "job state for " .. id),
		}
	end
	return clone_serializable(result, "five-villager restart snapshot")
end

local function inventory_counts(villagers)
	local snapshot = {
		by_name = {}, food = 0, raw_food = 0, wood = 0, ore = 0,
		ingots = 0, tools = 0, axe = 0, pickaxe = 0, hoe = 0,
		iron_tools = 0, flatbread = 0, straw = 0, beds = 0, dropped = 0,
		cobble = 0, furnace_items = 0,
		chest = {by_name = {}, food = 0, raw_food = 0, wood = 0, ore = 0,
			ingots = 0, tools = 0, flatbread = 0, cobble = 0, furnace_items = 0},
		carried = {by_name = {}, cobble = 0, furnace_items = 0},
	}
	local seen_inventories = {}

	local function classify(target, name, count)
		if not name or name == "" or count <= 0 then return end
		target.by_name[name] = (target.by_name[name] or 0) + count
		if minetest.get_item_group(name, "food") > 0 then
			target.food = (target.food or 0) + count
		end
		local cooking = minetest.get_craft_result({
			method = "cooking", width = 1, items = {ItemStack(name)},
		})
		if minetest.get_item_group(name, "food_raw") > 0
				or (cooking and cooking.item and not cooking.item:is_empty()
					and minetest.get_item_group(cooking.item:get_name(), "food") > 0) then
			target.raw_food = (target.raw_food or 0) + count
		end
		if minetest.get_item_group(name, "wood") > 0
				or minetest.get_item_group(name, "tree") > 0 then
			target.wood = (target.wood or 0) + count
		end
		if compat.is_metal_smelting_input(ItemStack(name)) then
			target.ore = (target.ore or 0) + count
		end
		if compat.is_metal_ingot(ItemStack(name)) then
			target.ingots = (target.ingots or 0) + count
		end
		if name == configured_cobble_name() then
			target.cobble = (target.cobble or 0) + count
		end
		if is_compatible_furnace_name(name) then
			target.furnace_items = (target.furnace_items or 0) + count
		end
		local is_tool = false
		for _, group in ipairs({"axe", "pickaxe", "hoe", "shovel", "sword"}) do
			if minetest.get_item_group(name, group) > 0 then
				is_tool = true
				target[group] = (target[group] or 0) + count
			end
		end
		if is_tool then target.tools = (target.tools or 0) + count end
		for _, tool_kind in ipairs({"axe", "pickaxe", "hoe", "shovel", "sword"}) do
			for _, candidate in ipairs(compat.get_tool_items(tool_kind, {"iron"}) or {}) do
				if name == candidate then
					target.iron_tools = (target.iron_tools or 0) + count
				end
			end
		end
		if name == "working_villages:flatbread" then
			target.flatbread = (target.flatbread or 0) + count
		elseif name == "working_villages:straw_bundle" then
			target.straw = (target.straw or 0) + count
		end
		if minetest.get_item_group(name, "bed") > 0
				or minetest.get_item_group(name, "villager_bed_bottom") > 0 then
			target.beds = (target.beds or 0) + count
		end
	end

	local function add_inventory(inv, target)
		if not inv then return end
		local key = tostring(inv)
		if seen_inventories[key] then return end
		seen_inventories[key] = true
		for _, list in pairs(inv:get_lists() or {}) do
			for _, stack in ipairs(list or {}) do
				if not stack:is_empty() then
					classify(target, stack:get_name(), stack:get_count())
					if target ~= snapshot then
						classify(snapshot, stack:get_name(), stack:get_count())
					end
				end
			end
		end
	end

	for _, villager in ipairs(villagers) do
		add_inventory(villager:get_inventory(), snapshot.carried)
	end
	for _, pos in ipairs(cached_positions("chests")) do
		add_inventory(minetest.get_meta(pos):get_inventory(), snapshot.chest)
	end
	for _, pos in ipairs(cached_positions("furnaces")) do
		add_inventory(minetest.get_meta(pos):get_inventory(), snapshot)
	end
	for _, object in ipairs(minetest.get_objects_inside_radius({x = 0, y = 1, z = 0}, 45)) do
		local lua = object:get_luaentity()
		if lua and lua.name == "__builtin:item" then
			local stack = ItemStack(lua.itemstring or "")
			if not stack:is_empty() then
				classify(snapshot, stack:get_name(), stack:get_count())
				snapshot.dropped = snapshot.dropped + stack:get_count()
			end
		end
	end
	return snapshot
end

local function world_snapshot(force)
	local now = minetest.get_us_time() / 1000000
	refresh_topology(force == true)
	if not force and observation_cache.world
			and now - observation_cache.world_at < HEAVY_REFRESH_SECONDS then
		return observation_cache.world
	end
	local result = {
		trees = 0, saplings = 0,
		chests = #cached_positions("chests"),
		furnaces = #cached_positions("furnaces"),
		quarry_stone_remaining = count_remaining_quarry_stone(),
		beds = 0,
		farmland = 0, crops = 0, mature = 0,
	}
	-- One combined native scan replaces the former independent tree, sapling and
	-- bed scans. Chests/furnaces come from the topology cache refreshed above.
	for _, pos in ipairs(minetest.find_nodes_in_area(AREA_MIN, AREA_MAX, {
			"group:tree", "group:sapling", "group:villager_bed_bottom",
		})) do
		local name = minetest.get_node(pos).name
		if minetest.get_item_group(name, "tree") > 0 then
			result.trees = result.trees + 1
		end
		if minetest.get_item_group(name, "sapling") > 0 then
			result.saplings = result.saplings + 1
		end
		if minetest.get_item_group(name, "villager_bed_bottom") > 0 then
			result.beds = result.beds + 1
		end
	end
	for x = -16, 16 do
		for z = -16, 16 do
			local soil = minetest.get_node({x = x, y = 0, z = z}).name
			if soil ~= (state.resources and state.resources.dirt)
					and not compat.is_tillable_dirt(soil)
					and (minetest.get_item_group(soil, "soil") > 0
						or soil:find("farmland", 1, true) or soil:find("soil", 1, true)) then
				result.farmland = result.farmland + 1
			end
			local crop = minetest.get_node({x = x, y = 1, z = z}).name
			if farming.is_plant(crop) then
				result.crops = result.crops + 1
				result.mature = result.mature + 1
			elseif compat.get_growth_stage(crop) ~= nil then
				result.crops = result.crops + 1
			end
		end
	end
	observation_cache.world = result
	observation_cache.world_at = minetest.get_us_time() / 1000000
	return result
end

local function villager_by_id(villagers, id)
	for _, villager in ipairs(villagers) do
		if villager.inventory_name == id then return villager end
	end
	return nil
end

local function observe_harvest_cycles(villagers, items)
	assert_true(not state.harvest_accounting_error, state.harvest_accounting_error)
	for index, event in ipairs(state.harvest_events or {}) do
		if not event.complete and event.harvester_id then
			local node_name = minetest.get_node(event.pos).name
			local stage = compat.get_growth_stage(node_name)
			if not event.replant and stage ~= nil and not farming.is_plant(node_name) then
				event.replant = {node = node_name, stage = stage, at = minetest.get_gametime()}
				save_state()
				minetest.log("action", "VILLAGE_RUNTIME_HARVEST_REPLANT_OBSERVED:" .. profile
					.. ":event=" .. index .. ":farmer=" .. event.harvester_id
					.. ":plant=" .. event.plant .. ":replant=" .. node_name
					.. ":stage=" .. stage)
			end
			event.deposited = type(event.deposited) == "table" and event.deposited or {}
			local products = type(event.products) == "table" and event.products or {}
			local deposited = next(products) ~= nil and event.acquired_at ~= nil
			for name, required in pairs(products) do
				-- Credits are capped per harvest event and are created only by an
				-- atomic transfer whose source removal and chest addition both exactly
				-- equal the production function's returned quantity.
				if (event.deposited[name] or 0) ~= required then deposited = false end
			end
			if event.replant and deposited then
				event.complete = true
				event.completed_at = minetest.get_gametime()
				save_state()
				mark("HARVEST_REPLANT_DEPOSIT", "event=" .. index
					.. ":plant=" .. event.plant .. ":replant=" .. event.replant.node
					.. ":acquired=" .. minetest.serialize(event.gains)
					.. ":pickup=" .. minetest.serialize(event.pickup_gains)
					.. ":products=" .. minetest.serialize(products)
					.. ":deposited=" .. minetest.serialize(event.deposited)
					.. ":transfers=" .. minetest.serialize(event.deposit_transfers))
				mark("FARM_DEPOSIT", minetest.serialize(event.products))
				return
			end
		end
	end
end

local function furnace_stack(inv, list_name)
	local stack = inv and inv:get_stack(list_name, 1) or ItemStack()
	return {name = stack:get_name(), count = stack:get_count()}
end

local function furnace_observation(pos)
	local meta = minetest.get_meta(pos)
	local inv = meta and meta:get_inventory() or nil
	return {
		pos = vector.round(pos), src = furnace_stack(inv, "src"),
		fuel = furnace_stack(inv, "fuel"), dst = furnace_stack(inv, "dst"),
		fuel_time = math.max(meta:get_float("fuel_time"), meta:get_float("src_time")),
		fuel_total = math.max(meta:get_float("fuel_totaltime"), meta:get_float("src_totaltime")),
	}
end

local function cooking_output(input_name)
	if not input_name or input_name == "" then return nil end
	local result = minetest.get_craft_result({
		method = "cooking", width = 1, items = {ItemStack(input_name)},
	})
	if not result or not result.item or result.item:is_empty() then return nil end
	return result.item:get_name(), result.item:get_count()
end

local function furnace_flow_kind(input_name, output_name)
	if compat.is_metal_smelting_input(ItemStack(input_name))
			and compat.is_metal_ingot(ItemStack(output_name)) then
		return "FORGE"
	end
	if minetest.get_item_group(output_name, "food") > 0
			or output_name == "working_villages:flatbread" then
		return "COOK"
	end
	return nil
end

local function observe_furnace_chains(items)
	-- Furnace contents still get sampled every 0.5 s. Only node discovery is
	-- cached, so src/fuel/dst transitions retain their original resolution.
	for _, pos in ipairs(cached_positions("furnaces")) do
		local key = minetest.pos_to_string(vector.round(pos), 0)
		local current = furnace_observation(pos)
		local runtime = furnace_runtime[key] or {flows = {}}
		local previous = runtime.previous
		local output_name, output_count = cooking_output(current.src.name)
		local kind = output_name and furnace_flow_kind(current.src.name, output_name) or nil
		if kind then
			local flow = runtime.flows[kind]
			if not flow then
				flow = {
					input = current.src.name, output = output_name,
					output_per_input = output_count, chest_before = items.chest.by_name[output_name] or 0,
					consumed = 0, produced = 0, removed = 0,
				}
				runtime.flows[kind] = flow
			end
			if flow.input == current.src.name then
				flow.src_seen = true
				if current.fuel.count > 0 or current.fuel_time > 0 or current.fuel_total > 0 then
					flow.fuel_seen = true
				end
			end
		end

		if previous and previous.src.name ~= "" then
			local expected_name, expected_count = cooking_output(previous.src.name)
			local previous_kind = expected_name
				and furnace_flow_kind(previous.src.name, expected_name) or nil
			local flow = previous_kind and runtime.flows[previous_kind] or nil
			if flow and flow.input == previous.src.name then
				local source_now = current.src.name == previous.src.name and current.src.count or 0
				local consumed = math.max(0, previous.src.count - source_now)
				local dst_before = previous.dst.name == expected_name and previous.dst.count or 0
				local dst_now = current.dst.name == expected_name and current.dst.count or 0
				local produced = math.max(0, dst_now - dst_before)
				if consumed > 0 then flow.consumed = flow.consumed + consumed end
				if produced > 0 then
					flow.produced = flow.produced + produced
					flow.dst_seen = true
				end
				if consumed > 0 and produced > 0 then
					assert_true(produced == consumed * expected_count,
						previous_kind .. " furnace duplicated or lost output in an observed cook step")
					flow.exact_cook_step = true
				end
			end
		end

		for flow_kind, flow in pairs(runtime.flows) do
			if previous and previous.dst.name == flow.output then
				local dst_now = current.dst.name == flow.output and current.dst.count or 0
				local removed = math.max(0, previous.dst.count - dst_now)
				if removed > 0 then flow.removed = flow.removed + removed end
			end
			local chest_delta = (items.chest.by_name[flow.output] or 0) - flow.chest_before
			if flow.src_seen and flow.fuel_seen and flow.dst_seen and flow.exact_cook_step
					and flow.removed > 0 and chest_delta >= flow.removed then
				flow.deposited = chest_delta
				mark(flow_kind .. "_FURNACE_SEQUENCE", key .. ":" .. flow.input .. ">"
					.. flow.output .. ":consumed=" .. flow.consumed
					.. ":produced=" .. flow.produced .. ":deposited=" .. chest_delta)
			end
		end
		runtime.previous = current
		furnace_runtime[key] = runtime
	end
	if state.milestones.COOK_FURNACE_SEQUENCE and state.milestones.FORGE_FURNACE_SEQUENCE then
		mark("FURNACE_ANTI_DUPLICATION", "exact observed src consumption equals dst production")
	end
end

local function accelerate_native_crop_timers(force)
	local now = minetest.get_us_time() / 1000000
	if not force and now - observation_cache.growth_at < HEAVY_REFRESH_SECONDS then
		return false
	end
	if voxelibre_growth_ids == nil then
		voxelibre_growth_ids = {}
		if type(mcl_farming) == "table" and type(mcl_farming.plant_lists) == "table" then
			for identifier, info in pairs(mcl_farming.plant_lists) do
				for _, name in ipairs(info.names or {}) do
					voxelibre_growth_ids[name] = identifier
				end
			end
		end
	end
	for x = -16, 16 do
		for z = -16, 16 do
			local pos = {x = x, y = 1, z = z}
			local node = minetest.get_node(pos)
			local growth_id = voxelibre_growth_ids[node.name]
			if growth_id and type(mcl_farming.grow_plant) == "function" then
				-- Use VoxeLibre's own moisture/light/probability implementation;
				-- only the cadence is compressed for the headless acceptance run.
				mcl_farming:grow_plant(growth_id, pos, node, 1, false)
			elseif compat.get_growth_stage(node) ~= nil then
				local def = minetest.registered_nodes[node.name]
				if def and type(def.on_timer) == "function" then
					local timer = minetest.get_node_timer(pos)
					if not timer:is_started() or timer:get_timeout() > 2 then
						timer:start(1)
					end
				end
			end
		end
	end
	observation_cache.growth_at = minetest.get_us_time() / 1000000
	return true
end

local function active_marker(force_discovery)
	local best = nil
	for _, pos in ipairs(cached_positions("markers", force_discovery)) do
		local meta = minetest.get_meta(pos)
		if meta:get_string("owner") == OWNER then
			local build_pos = working_villages.buildings.get_build_pos(meta)
			local building = build_pos and working_villages.buildings.get(build_pos) or nil
			local candidate = {
				pos = vector.round(pos), meta = meta, state = meta:get_string("state"),
				index = meta:get_int("index"), build_pos = build_pos,
				nodes = building and building.nodedata or nil,
				schematic = meta:get_string("schematic"),
			}
			if candidate.schematic == "minimal_shelter" or not best then best = candidate end
		end
	end
	return best
end

local function exact_observations(villagers)
	-- Terminal decisions never use a time-cached topology or world snapshot.
	-- world_snapshot(true) refreshes every discoverable position first; the item
	-- and marker reads below then operate on that same exact topology.
	local world = world_snapshot(true)
	local items = inventory_counts(villagers)
	local marker = active_marker(false)
	return items, world, marker
end

local function observe_roles(villagers)
	local changed = false
	for _, villager in ipairs(villagers) do
		local id = villager.inventory_name
		local job = villager:get_job_name()
		state.roles_seen[id] = type(state.roles_seen[id]) == "table" and state.roles_seen[id] or {}
		if not state.roles_seen[id][job] then
			state.roles_seen[id][job] = true
			changed = true
			minetest.log("action", "VILLAGE_RUNTIME_ROLE_OBSERVED:" .. profile .. ":" .. id .. ":" .. job)
		end
	end
	if changed then save_state() end
end

local function role_was_seen(job)
	for _, roles in pairs(state.roles_seen) do
		if roles[job] then return true end
	end
	return false
end

local function task_has_participant(record, inventory_name)
	for _, id in ipairs((record and record.participants) or {}) do
		if id == inventory_name then return true end
	end
	return false
end

local function requested_counts_are_available(villager, requested)
	local counts = count_inventory_names(villager:get_inventory())
	for name, count in pairs(requested or {}) do
		if (counts[name] or 0) < count then return false end
	end
	return next(requested or {}) ~= nil, counts
end

local function observe_physical_deliveries(villagers, items)
	local collab = working_villages.collaborative_tasks
	assert_true(collab and collab.get, "collaborative task inspection API is unavailable")
	for _, supplier in ipairs(villagers) do
		local runtime = supplier.job_data and supplier.job_data.physical_delivery_state
		local task_id = runtime and runtime.task_id
		local record = task_id and collab.get(task_id) or nil
		if runtime and runtime.target_kind == "requester" and record
				and record.state == "active" and record.name == "resource_delivery"
				and type(record.data) == "table" and type(record.data.items) == "table" then
			local requester_id = record.data.requester_id
			local requester = villager_by_id(villagers, requester_id)
			local enough, supplier_counts = requested_counts_are_available(supplier, record.data.items)
			if requester and requester ~= supplier and enough
					and record.initiator == requester_id
					and task_has_participant(record, requester_id)
					and task_has_participant(record, supplier.inventory_name)
					and not state.delivery_observations[task_id] then
				local requested = clone_serializable(record.data.items, "delivery request")
				local requester_counts = count_inventory_names(requester:get_inventory())
				local global_counts = {}
				for name in pairs(requested) do global_counts[name] = items.by_name[name] or 0 end
				state.delivery_observations[task_id] = {
					task_id = task_id, requester_id = requester_id,
					supplier_id = supplier.inventory_name, requested = requested,
					supplier_before = supplier_counts, requester_before = requester_counts,
					global_before = global_counts, travelled_before = runtime.travelled or 0,
				}
				save_state()
				minetest.log("action", "VILLAGE_RUNTIME_PHYSICAL_DELIVERY_OBSERVING:"
					.. profile .. ":" .. task_id .. ":" .. minetest.serialize(requested))
			end
		end
	end

	for task_id, observation in pairs(state.delivery_observations) do
		if not observation.complete then
			local supplier = villager_by_id(villagers, observation.supplier_id)
			local requester = villager_by_id(villagers, observation.requester_id)
			local last = supplier and supplier.job_data and supplier.job_data.last_physical_delivery
			local record = collab.get(task_id)
			if supplier and requester and last and last.task_id == task_id
					and record and record.state == "completed" then
				assert_true(last.success == true, "completed delivery reports supplier failure")
				assert_true(last.target_kind == "requester",
					"collaborative delivery fell back to non-requester target")
				assert_true((tonumber(last.travelled) or 0) >= 0.5,
					"collaborative delivery completed without observable travel")
				assert_true(record.initiator == observation.requester_id,
					"completed delivery requester is not the task initiator")
				assert_true(task_has_participant(record, observation.requester_id)
					and task_has_participant(record, observation.supplier_id),
					"completed delivery lost a physical participant")
				local delivered = record.result and record.result.delivered_items or nil
				assert_true(deep_equal(delivered, observation.requested),
					"completed delivery quantity differs from the exact request")
				assert_true(last.summary and deep_equal(last.summary.items, observation.requested),
					"supplier delivery summary differs from the exact request")
				local supplier_after = count_inventory_names(supplier:get_inventory())
				local requester_after = count_inventory_names(requester:get_inventory())
				for name, count in pairs(observation.requested) do
					assert_true((observation.supplier_before[name] or 0)
						- (supplier_after[name] or 0) == count,
						"supplier cargo delta is not exact for " .. name)
					assert_true((requester_after[name] or 0)
						- (observation.requester_before[name] or 0) == count,
						"requester receipt delta is not exact for " .. name)
					assert_true((items.by_name[name] or 0)
						== (observation.global_before[name] or 0),
						"delivery duplicated or lost " .. name)
				end
				observation.complete = true
				observation.completed_at = minetest.get_gametime()
				save_state()
				mark("PHYSICAL_DELIVERY", task_id .. ":supplier="
					.. observation.supplier_id .. ":requester=" .. observation.requester_id
					.. ":travel=" .. string.format("%.2f", last.travelled))
				return
			end
		end
	end

	-- A short final hand-off can move the stack and complete its task inside one
	-- server step.  In that case there is no legitimate "before" frame for the
	-- sampler, but production persists both the travelled delivery receipt and
	-- the collaborative ledger credited from the quantity actually moved.  Use
	-- those two independent records as the fallback proof; the dedicated moving
	-- delivery harness remains responsible for the full before/after global
	-- conservation assertion.
	if not state.milestones.PHYSICAL_DELIVERY then
		for _, supplier in ipairs(villagers) do
			local last = supplier.job_data and supplier.job_data.last_physical_delivery
			local record = last and last.task_id and collab.get(last.task_id) or nil
			local requested = record and record.data and record.data.items or nil
			local delivered = record and record.result and record.result.delivered_items or nil
			local progress = record and record.data and record.data.delivery_progress
				and record.data.delivery_progress.items or nil
			if last and last.success == true and last.target_kind == "requester"
					and (tonumber(last.travelled) or 0) >= 0.5
					and record and record.state == "completed"
					and record.name == "resource_delivery"
					and type(requested) == "table" and next(requested) ~= nil
					and deep_equal(last.summary and last.summary.items, requested)
					and deep_equal(delivered, requested)
					and deep_equal(progress, requested)
					and record.initiator ~= supplier.inventory_name
					and task_has_participant(record, record.initiator)
					and task_has_participant(record, supplier.inventory_name) then
				mark("PHYSICAL_DELIVERY", record.id .. ":supplier="
					.. supplier.inventory_name .. ":requester=" .. record.initiator
					.. ":travel=" .. string.format("%.2f", last.travelled)
					.. ":persisted_receipt=true")
				return
			end
		end
	end
end

local function observe_milestones(villagers, items, world)
	if (state.dig_events.tree or 0) > 0 then mark("WOOD_HARVEST", state.dig_events.tree) end
	if world.saplings > ((state.initial_world and state.initial_world.saplings) or 0) then
		mark("WOOD_REPLANT", world.saplings)
	end
	local shared = working_villages.get_shared_storage_pos(OWNER)
	if shared and working_villages.is_chest_pos(shared) then
		mark("STORAGE", minetest.pos_to_string(shared, 0))
	end
	if items.axe > 0 then mark("AXE", items.axe) end
	if items.pickaxe > 0 then mark("PICKAXE", items.pickaxe) end
	if items.hoe > 0 then mark("HOE", items.hoe) end
	if (state.dig_events.seed_source or 0) > 0 then mark("NATURAL_SEED", state.dig_events.seed_source) end
	if world.farmland > 0 then mark("FARMLAND", world.farmland) end
	if world.crops > 0 then mark("SOW", world.crops) end
	if (state.dig_events.mature_crop or 0) > 0 then mark("HARVEST", state.dig_events.mature_crop) end
	if (state.dig_events.ore or 0) > 0 then mark("MINE", state.dig_events.ore) end
	if items.chest.ore > 0 then mark("ORE_DEPOSIT", items.chest.ore) end
	if world.furnaces > 0 then mark("FURNACE", world.furnaces) end
	if role_was_seen("working_villages:job_cook") and items.flatbread > 0
			and state.milestones.COOK_FURNACE_SEQUENCE then
		mark("COOK", items.flatbread)
	end
	if role_was_seen("working_villages:job_blacksmith")
			and (items.ingots > 0 or items.iron_tools > 0)
			and state.milestones.FORGE_FURNACE_SEQUENCE then
		mark("FORGE", "ingots=" .. items.ingots .. ",iron_tools=" .. items.iron_tools)
	end
	if role_was_seen("working_villages:job_cook")
			and role_was_seen("working_villages:job_blacksmith") then
		mark("ROLE_ROTATION", "cook+blacksmith")
	end
end

local function required_before_checkpoint()
	-- The restart checkpoint must be taken while construction is genuinely in
	-- progress, not after every later economy proof has finished.  In a healthy
	-- village the builder can otherwise complete the 27-node shelter while the
	-- cook/blacksmith/delivery observations are still running.  Require the
	-- complete resource bootstrap up to the real furnace here; phase two keeps
	-- running the same world and still requires the exact cooking, forging and
	-- physical-delivery milestones before the final success marker.
	for _, key in ipairs({"WOOD_HARVEST", "WOOD_REPLANT", "STORAGE", "AXE", "PICKAXE", "HOE",
		"NATURAL_SEED", "FARMLAND", "SOW", "HARVEST", "HARVEST_REPLANT_DEPOSIT",
		"FARM_DEPOSIT",
		"MINE", "ORE_DEPOSIT", "FURNACE"}) do
		if not state.milestones[key] then return false, key end
	end
	return true
end

local function validate_completed_build(marker)
	assert_true(marker and marker.state == "built", "minimal shelter is not built")
	assert_true(marker.schematic == "minimal_shelter", "wrong completed blueprint")
	assert_true(type(marker.nodes) == "table" and #marker.nodes > 0,
		"completed shelter lost its node list")
	for index, entry in ipairs(marker.nodes) do
		local actual = minetest.get_node(entry.pos).name
		assert_true(working_villages.buildings.node_matches_schematic(entry.node.name, actual)
			or working_villages.buildings.get_registered_nodename(entry.node.name) == actual,
			("completed shelter node %d mismatch: expected %s, got %s"):format(
				index, entry.node.name, actual))
	end
	local encoded = marker.meta:get_string("working_villages_construction_ledger_v1")
	local ledger = encoded ~= "" and minetest.deserialize(encoded) or nil
	assert_true(type(ledger) == "table" and ledger.version == 1,
		"completed shelter has no exact construction ledger")
	local totals = ledger.totals or {}
	local accounted = (totals.consumed or 0) + (totals.synthetic or 0)
		+ (totals.structural or 0) + (totals.cleared or 0) + (totals.reused or 0)
		+ (totals.liquid_skipped or 0) + (totals.unlimited or 0)
	assert_true(accounted == #marker.nodes,
		("construction ledger accounts for %d/%d steps"):format(accounted, #marker.nodes))
	assert_true((totals.mismatches or 0) == 0, "construction inventory consumption mismatch")
	assert_true((totals.liquid_skipped or 0) == 0, "construction skipped a submerged step")
	assert_true((totals.unlimited or 0) == 0, "survival construction used unlimited materials")
	assert_true((totals.synthetic or 0) == 1,
		"minimal shelter must synthesize exactly one bed top")
	assert_true(marker.meta:get_string("valid") == "true",
		"completed shelter did not validate its real bed and door")
	mark("CONSTRUCTION", "minimal_shelter:consumed=" .. tostring(totals.consumed)
		.. ":synthetic=" .. tostring(totals.synthetic)
		.. ":structural=" .. tostring(totals.structural)
		.. ":reused=" .. tostring(totals.reused))
end

local function start_danger_test(villagers, marker)
	local builder = nil
	for _, villager in ipairs(villagers) do
		if villager:get_job_name() == "working_villages:job_builder" then
			builder = villager
			break
		end
	end
	if not builder or not marker or marker.state ~= "begun"
			or marker.index < 2 or marker.index >= #(marker.nodes or {}) then
		return false
	end
	-- Only interrupt work that can actually be resumed. There is a short,
	-- legitimate window after a builder coroutine has completed where the
	-- object is still referenced until the next scheduler tick. Capturing that
	-- dead thread would test creation of the next work unit, not resumption of
	-- the interrupted one.
	if not builder.job_thread or coroutine.status(builder.job_thread) ~= "suspended" then
		return false
	end
	local pos = builder.object:get_pos()
	local hostile = minetest.add_entity(vector.add(pos, {x = 4, y = 0, z = 0}), HOSTILE)
	assert_true(hostile and builder:is_enemy(hostile), "test danger is not recognized as hostile")
	builder.job_data.danger_ticks = 30
	danger_runtime = {
		builder = builder,
		builder_id = builder.inventory_name,
		job = builder:get_job_name(),
		thread = builder.job_thread,
		marker_pos = vector.round(marker.pos),
		index = marker.index,
		hostile = hostile,
		retreat_seen = false,
	}
	minetest.log("action", "VILLAGE_RUNTIME_DANGER_STIMULUS:" .. profile .. ":index=" .. marker.index)
	return true
end

local function advance_danger_test()
	if not danger_runtime then return false end
	local d = danger_runtime
	local meta = minetest.get_meta(d.marker_pos)
	local index = meta:get_int("index")
	assert_true(d.builder.object and d.builder.object:get_pos(), "builder vanished during danger test")
	assert_true(d.builder:get_job_name() == d.job, "builder changed task during danger retreat")
	if not d.retreat_seen then
		if d.builder.disp_action == "fuite" then
			assert_true(index == d.index, "construction advanced while builder was fleeing")
			assert_true(d.builder.job_thread == d.thread,
				"danger retreat replaced the interrupted construction coroutine")
			d.retreat_seen = true
			d.hostile:remove()
			d.builder.job_data.danger_ticks = 0
			minetest.log("action", "VILLAGE_RUNTIME_DANGER_RETREAT_OBSERVED:" .. profile)
		end
		return true
	end
	if index > d.index then
		local receipt_seen = d.builder._last_resumed_job_thread == d.thread
		for _, resumed in ipairs(d.builder._recent_resumed_job_threads or {}) do
			if resumed == d.thread then receipt_seen = true break end
		end
		-- Builder coroutines intentionally represent one bounded work unit. A
		-- unit may finish while the emergency state is being entered, in which
		-- case the next coroutine resumes from the persisted construction marker.
		-- The player-visible exactness contract is therefore the durable task
		-- checkpoint: no progress while fleeing, then one and only one ledger
		-- step, under the same profession.
		assert_true(index == d.index + 1,
			("construction resume skipped steps: %d -> %d"):format(d.index, index))
		local resume_mode = (d.builder.job_thread == d.thread or receipt_seen)
			and "coroutine" or "checkpoint"
		mark("DANGER_RESUME", "index=" .. d.index .. "->" .. index
			.. ":mode=" .. resume_mode)
		danger_runtime = nil
		return false
	end
	return true
end

local function find_home_villager(villagers)
	for _, villager in ipairs(villagers) do
		if villager.has_home and villager:has_home() then return villager end
	end
	return nil
end

local function advance_needs_test(villagers)
	state.needs_test = type(state.needs_test) == "table" and state.needs_test or {stage = "start"}
	local test = state.needs_test
	local villager = nil
	if test.villager_id then
		for _, candidate in ipairs(villagers) do
			if candidate.inventory_name == test.villager_id then villager = candidate break end
		end
	else
		villager = find_home_villager(villagers)
	end
	if not villager then return false end

	if test.stage == "start" then
		test.villager_id = villager.inventory_name
		test.job = villager:get_job_name()
		working_villages.needs.set(villager, "hunger", 5)
		test.stage = "hunger"
		save_state()
		minetest.log("action", "VILLAGE_RUNTIME_HUNGER_STIMULUS:" .. profile .. ":" .. villager.inventory_name)
		return false
	end
	assert_true(villager:get_job_name() == test.job,
		"villager changed profession while satisfying a need")
	if test.stage == "hunger" then
		local hunger = working_villages.needs.get(villager, "hunger") or 0
		if hunger >= 29 and villager.job_data and villager.job_data.eating_item_name then
			mark("HUNGER_EAT", villager.job_data.eating_item_name)
			working_villages.needs.set(villager, "energy", 5)
			test.stage = "fatigue_rest"
			test.rest_started = false
			save_state()
		end
		return false
	end
	if test.stage == "fatigue_rest" then
		if villager.job_data and villager.job_data.resting then test.rest_started = true end
		local energy = working_villages.needs.get(villager, "energy") or 0
		if test.rest_started and not (villager.job_data and villager.job_data.resting)
				and energy >= 39 then
			mark("FATIGUE_REST", villager.inventory_name .. ":energy=" .. string.format("%.2f", energy))
			test.stage = "night"
			test.night_sleep_seen = false
			test.night_job = villager:get_job_name()
			minetest.set_timeofday(0.80)
			save_state()
		end
		return false
	end
	if test.stage == "night" then
		local tod = minetest.get_timeofday()
		if villager.disp_action == "dort" then
			assert_true(tod < 0.2 or tod > 0.76, "villager reported sleep outside the night window")
			assert_true(not (villager.job_data and villager.job_data.resting),
				"night sleep was confused with low-energy rest")
			local bed_pos = villager.pos_data and villager.pos_data.bed_pos
			assert_true(bed_pos and vector.distance(villager.object:get_pos(), bed_pos) <= 2,
				"night sleep did not occur at the assigned bed")
			test.night_sleep_seen = true
			mark("NIGHT_SLEEP", villager.inventory_name .. ":bed="
				.. minetest.pos_to_string(vector.round(bed_pos), 0))
			minetest.set_timeofday(0.23)
			test.stage = "dawn_resume"
			save_state()
		end
		return false
	end
	if test.stage == "dawn_resume" then
		local sleeping_action = villager.disp_action == "dort"
			or villager.disp_action == "va se coucher"
			or villager.disp_action == "en attente du soir"
			or villager.disp_action == "en attente de l'aube"
		assert_true(villager:get_job_name() == test.night_job,
			"villager did not resume the same profession after dawn")
		if test.night_sleep_seen and not sleeping_action and villager.disp_action ~= "actif" then
			mark("DAWN_JOB_RESUME", villager.inventory_name .. ":action="
				.. tostring(villager.disp_action))
			minetest.set_timeofday(0.5)
			test.stage = "complete"
			save_state()
		end
		return false
	end
	return test.stage == "complete"
end

local last_diagnostic = 0
-- If a later phase-two assertion stops the disposable server, keep the exact
-- restart proof already persisted by mark().  Re-running the same checkpoint
-- world must not compare a legitimately advanced construction index with the
-- original pre-resume index a second time.
local restart_checked = state.milestones.RESTART ~= nil
local missing_villagers_since = nil
local stable_villager_samples = 0
local function poll()
	keep_area_loaded()
	-- A single combined discovery scan runs at most once per second. Cached
	-- furnaces are still observed on every 0.5 s poll below.
	refresh_topology(false)
	accelerate_native_crop_timers()
	local villagers = loaded_villagers()
	local ids = {}
	for _, villager in ipairs(villagers) do ids[#ids + 1] = villager.inventory_name end
	if #villagers == 5 then
		if not state.initial_ids then
			state.initial_ids = ids
			save_state()
			mark("SPAWN", "5")
		else
			assert_true(same_array(state.initial_ids, ids), "villager identities changed or duplicated")
		end
		missing_villagers_since = nil
		stable_villager_samples = stable_villager_samples + 1
		observe_roles(villagers)
	elseif state.initial_ids then
		missing_villagers_since = missing_villagers_since
			or (minetest.get_us_time() / 1000000)
		if (minetest.get_us_time() / 1000000) - missing_villagers_since >= 10 then
			local loaded = {}
			for _, id in ipairs(ids) do loaded[id] = true end
			local missing = {}
			for _, id in ipairs(state.initial_ids) do
				if not loaded[id] then missing[#missing + 1] = id end
			end
			fail("five-villager set was not loaded for 10 seconds; loaded="
				.. table.concat(ids, ",") .. "; missing=" .. table.concat(missing, ","))
		end
	end

	local items = inventory_counts(villagers)
	local world = world_snapshot()
	observe_harvest_cycles(villagers, items)
	observe_physical_deliveries(villagers, items)
	observe_furnace_chains(items)
	observe_milestones(villagers, items, world)
	local marker = active_marker()

	if state.phase == 1 and #villagers == 5 then
		local ready, missing = required_before_checkpoint()
		local checkpoint_candidate = ready and marker and marker.state == "begun"
			and marker.schematic == "minimal_shelter"
			and marker.index >= 3 and marker.index < #(marker.nodes or {})
		if checkpoint_candidate then
			items, world, marker = exact_observations(villagers)
			ready, missing = required_before_checkpoint()
		end
		if ready and marker and marker.state == "begun" and marker.schematic == "minimal_shelter"
				and marker.index >= 3 and marker.index < #(marker.nodes or {}) then
			local ledger = marker.meta:get_string("working_villages_construction_ledger_v1")
			assert_true(ledger ~= "", "mid-build checkpoint has no construction ledger")
			state.checkpoint = {
				marker_pos = vector.round(marker.pos), build_pos = vector.round(marker.build_pos),
				index = marker.index, node_count = #marker.nodes,
				marker_state = marker.state, ledger = ledger,
				villagers = exact_villager_snapshot(villagers),
			}
			state.phase = 2
			save_state()
			minetest.log("action", "VILLAGE_RUNTIME_CONSTRUCTION_CHECKPOINT_OK:" .. profile
				.. ":index=" .. marker.index .. "/" .. #marker.nodes)
			finish(true, "village runtime phase one complete; restart the same world")
			return
		elseif marker and marker.state == "built" then
			fail("shelter completed before restart checkpoint; missing milestone " .. tostring(missing))
		end
	elseif state.phase == 2 and #villagers == 5 then
		if not restart_checked then
			assert_true(state.checkpoint and state.checkpoint.marker_pos,
				"phase two has no persisted construction checkpoint")
			local checkpoint_meta = minetest.get_meta(state.checkpoint.marker_pos)
			assert_true(checkpoint_meta:get_string("schematic") == "minimal_shelter",
				"construction marker changed across restart")
			assert_true(checkpoint_meta:get_string("state") == state.checkpoint.marker_state,
				"construction state changed before restart validation")
			assert_true(checkpoint_meta:get_int("index") == state.checkpoint.index,
				"construction index was not restored exactly")
			assert_true(checkpoint_meta:get_string("working_villages_construction_ledger_v1")
				== state.checkpoint.ledger, "construction ledger was not restored exactly")
			local restored = exact_villager_snapshot(villagers)
			assert_true(deep_equal(restored.identities, state.checkpoint.villagers.identities),
				"one of the five exact identity tuples changed across restart")
			mark("RESTART_IDENTITIES", "5 exact tuples")
			assert_true(deep_equal(restored.inventories, state.checkpoint.villagers.inventories),
				"per-identity inventory contents changed across restart")
			mark("RESTART_INVENTORIES", "5 exact inventories")
			assert_true(deep_equal(restored.job_states, state.checkpoint.villagers.job_states),
				"persistent profession state changed across restart")
			mark("RESTART_JOB_STATES", "5 exact stable job states")
			mark("RESTART_LEDGER", "index=" .. checkpoint_meta:get_int("index"))
			restart_checked = true
			mark("RESTART", "5:index=" .. checkpoint_meta:get_int("index"))
		end
		if not state.milestones.DANGER_RESUME then
			if danger_runtime then
				advance_danger_test()
			elseif marker and marker.state == "begun" then
				start_danger_test(villagers, marker)
			elseif marker and marker.state == "built" then
				fail("construction completed before danger interruption/recovery test")
			end
		end
		if marker and marker.state == "built" and state.milestones.DANGER_RESUME then
			if not state.milestones.CONSTRUCTION then
				validate_completed_build(marker)
			end
			if state.milestones.COOK and state.milestones.FORGE
					and state.milestones.PHYSICAL_DELIVERY
					and advance_needs_test(villagers) then
				local exact_items, _world, exact_marker = exact_observations(villagers)
				items, marker = exact_items, exact_marker
				validate_completed_build(marker)
				state.final_items = items.by_name
				save_state()
				minetest.log("action", "VILLAGE_RUNTIME_BALANCE_OK:" .. profile
					.. ":digs=" .. minetest.serialize(state.dig_events)
					.. ":construction=" .. marker.meta:get_string("working_villages_construction_ledger_v1"))
				minetest.log("action", "VILLAGE_RUNTIME_FIVE_LOADED_STABLE_OK:" .. profile
					.. ":samples=" .. stable_villager_samples)
				minetest.log("action", "WORKING_VILLAGES_VILLAGE_RUNTIME_OK:" .. profile)
				finish(true, "working_villages complete village runtime test completed")
				return
			end
		end
	end

	local elapsed = minetest.get_us_time() / 1000000 - started_at
	if elapsed - last_diagnostic >= 30 then
		last_diagnostic = elapsed
		local jobs = {}
		for _, villager in ipairs(villagers) do
			local carried_furnaces = 0
			local villager_inventory = villager:get_inventory()
			for _, list in pairs(villager_inventory and villager_inventory:get_lists() or {}) do
				for _, stack in ipairs(list or {}) do
					if not stack:is_empty() and is_compatible_furnace_name(stack:get_name()) then
						carried_furnaces = carried_furnaces + stack:get_count()
					end
				end
			end
			local pending_site = villager.job_data and (
				villager.job_data.bootstrap_furnace_site
				or villager.job_data.blacksmith_furnace_site
				or villager.job_data.cook_furnace_site)
			jobs[#jobs + 1] = villager:get_job_name() .. "=" .. tostring(villager.disp_action)
				.. "@" .. minetest.pos_to_string(vector.round(villager.object:get_pos()), 0)
				.. (pending_site and ("#site=" .. minetest.pos_to_string(
					vector.round(pending_site), 0)) or "")
				.. (carried_furnaces > 0 and ("#furnace=" .. carried_furnaces) or "")
		end
		minetest.log("action", "VILLAGE_RUNTIME_PROGRESS:" .. profile
			.. ":phase=" .. state.phase .. ":elapsed=" .. math.floor(elapsed)
			.. ":villagers=" .. #villagers
			.. ":trees_dug=" .. tostring(state.dig_events.tree or 0)
			.. ":ore_dug=" .. tostring(state.dig_events.ore or 0)
			.. ":harvests=" .. tostring(state.dig_events.mature_crop or 0)
			.. ":farmland=" .. world.farmland .. ":crops=" .. world.crops
			.. ":mature=" .. world.mature
			.. ":wood=" .. items.wood .. ":chest_wood=" .. items.chest.wood
			.. ":ore_stock=" .. items.ore .. ":chest_ore=" .. items.chest.ore
			.. ":cobble_global=" .. items.cobble
			.. ":cobble_chest=" .. items.chest.cobble
			.. ":cobble_carried=" .. items.carried.cobble
			.. ":furnace_item_carried=" .. items.carried.furnace_items
			.. ":quarry_stone_remaining=" .. world.quarry_stone_remaining
			.. ":quarry_stone_dug=" .. tostring(state.dig_events.quarry_stone or 0)
			.. ":food=" .. items.food .. ":raw=" .. items.raw_food
			.. ":dropped=" .. items.dropped
			.. ":tools=" .. items.tools
			.. ":marker=" .. (marker and (marker.state .. "/" .. marker.index
				.. "/" .. #(marker.nodes or {})) or "none")
			.. ":jobs=" .. table.concat(jobs, ","))
	end
	if elapsed >= TIMEOUT_SECONDS then
		fail("timeout in phase " .. state.phase .. "; milestones="
			.. minetest.serialize(state.milestones))
	end
	schedule(POLL_SECONDS, poll)
end

local function start_runtime_polling()
	keep_area_loaded()
	minetest.log("action", "VILLAGE_RUNTIME_NATIVE_GROWTH_ACCELERATION:" .. profile
		.. ":native_growth_scan=" .. string.format("%.1fs", HEAVY_REFRESH_SECONDS)
		.. ":native_callbacks_only")
	schedule(POLL_SECONDS, poll)
end

schedule(0, function()
	minetest.set_timeofday(0.5)
	if state.world_ready then
		assert_true(type(state.resources) == "table", "persisted resource profile is missing")
		start_runtime_polling()
		return
	end
	assert_true(#loaded_villagers() == 0, "fresh harness world already contains owned villagers")
	local setup_started = false
	minetest.emerge_area(AREA_MIN, PAD_CLEAR_MAX, function(_, _, calls_remaining)
		if calls_remaining ~= 0 or setup_started then
			return
		end
		setup_started = true
		schedule(0, function()
			setup_resource_pad()
			start_runtime_polling()
		end)
	end)
end)
