-- Standalone regression tests for the autonomous bootstrap rendezvous.
-- Run from the repository root with:
--   lua5.1 working_villagers/tests/autonomous_bootstrap_wait_spec.lua working_villagers

local modpath = assert(arg and arg[1], "working_villages mod path is required")

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected)
			.. ", got " .. tostring(actual), 2)
	end
end

local function assert_true(value, message)
	if not value then error(message or "expected a truthy value", 2) end
end

local saved_working_villages = _G.working_villages
local saved_minetest = _G.minetest
local saved_vector = _G.vector

local function make_stack(name, count)
	return {
		name = name or "",
		count = math.max(0, math.floor(tonumber(count) or 0)),
		is_empty = function(self) return self.name == "" or self.count <= 0 end,
		get_name = function(self) return self.name end,
		get_count = function(self) return self.count end,
	}
end

local function make_inventory(items)
	local inv = {slots = {}}
	for index, entry in ipairs(items or {}) do
		inv.slots[index] = make_stack(entry[1], entry[2])
	end
	function inv:get_list(listname)
		assert_equal(listname, "main", "unexpected inventory list")
		return self.slots
	end
	return inv
end

local game_time = 0
local providers_enabled = true
local harvesting_enabled = false
local sent_messages = {}
local registered_job = nil

_G.vector = {
	round = function(pos)
		return {x = math.floor(pos.x + 0.5), y = math.floor(pos.y + 0.5),
			z = math.floor(pos.z + 0.5)}
	end,
	add = function(a, b) return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z} end,
	new = function(x, y, z)
		if type(x) == "table" then return {x = x.x, y = x.y, z = x.z} end
		return {x = x or 0, y = y or 0, z = z or 0}
	end,
	distance = function(a, b)
		local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
		return math.sqrt(dx * dx + dy * dy + dz * dz)
	end,
}

local provider = {
	inventory_name = "wood_provider",
	owner_name = "owner",
	inventory = make_inventory({{"test:tree", 8}}),
}
function provider:get_inventory() return self.inventory end

local communication = {
	list_loaded_villagers = function()
		return providers_enabled and {provider} or {}
	end,
	send_message = function(from, to, message_type, data)
		sent_messages[#sent_messages + 1] = {
			from = from, to = to, type = message_type, data = data,
		}
		return true
	end,
	find_nearby_villagers = function() return {} end,
	broadcast = function() return 0 end,
}

local fake_util = {
	search_surrounding = function()
		if harvesting_enabled then
			return {x = 2, y = 1, z = 0}
		end
		return nil
	end,
	find_adjacent_clear = function(pos) return pos end,
	find_ground_below = function(pos) return pos end,
	is_protected = function() return false end,
	walkable_pos = function() return true end,
	find_nearby_crafting_table = function() return nil end,
	find_nearby_furnace = function() return nil end,
	is_crafting_table = function() return false end,
	is_furnace = function() return false end,
}

local fake_compat = {
	is_voxelibre = false,
	get_chest_item_candidates = function() return {"test:chest"} end,
	get_crafting_table_item_candidates = function() return {"test:workbench"} end,
	get_furnace_item_candidates = function() return {"test:furnace"} end,
	get_tool_items = function() return {} end,
}

_G.minetest = {
	settings = {get = function() return nil end},
	registered_nodes = {},
	get_gametime = function() return game_time end,
	get_item_group = function(item_name, group)
		if item_name == "test:tree" and group == "tree" then
			return 1
		end
		if item_name == "test:axe_wood" and group == "axe" then
			return 1
		end
		return 0
	end,
	get_node_or_nil = function() return {name = "air"} end,
	get_node = function() return {name = "air"} end,
}

_G.working_villages = {
	communication = communication,
	blacksmith = {},
	voxelibre_compat = fake_compat,
	crafting = {ensure_any_item = function() return nil end},
	work_fallback = {equip_tool = function() return true end},
	animation_frames = {STAND = {x = 0, y = 0}},
	failed_pos_test = function() return false end,
	failed_pos_record = function() end,
	get_shared_storage_pos = function() return nil end,
	is_chest_pos = function() return false end,
	get_village_status = function() return {bootstrap_stage = "wood"} end,
	get_village_bootstrap_stage = function() return "wood" end,
	register_job = function(_, definition) registered_job = definition end,
}
function working_villages.require(name)
	if name == "jobs/util" then return fake_util end
	if name == "farming_compat" then
		return {
			is_plant_node = function() return false end,
			get_plant = function() return nil end,
		}
	end
	error("unexpected production dependency " .. tostring(name))
end

local load_ok, load_error = pcall(dofile, modpath .. "/jobs/autonomous.lua")
assert_true(load_ok, "autonomous job did not load: " .. tostring(load_error))
assert_true(type(registered_job) == "table" and type(registered_job.jobfunc) == "function",
	"autonomous job definition was not registered")

local function make_autonomous(inventory_name, items)
	local entity = {
		inventory_name = inventory_name,
		owner_name = "owner",
		job_data = {},
		pos_data = {job_pos = {x = 0, y = 1, z = 0}},
		inventory = make_inventory(items),
		time_counters = {
			["autonome:bootstrap"] = 40,
			["autonome:search"] = 0,
			["autonome:supply"] = 0,
			["autonome:explore"] = 0,
			["autonome:change_dir"] = 0,
		},
		velocity = {x = 4, y = 0, z = 0},
		go_to_calls = 0,
		dig_calls = 0,
		place_calls = 0,
	}
	entity.object = {
		get_pos = function() return {x = 0, y = 1, z = 0} end,
		set_velocity = function(_, velocity) entity.velocity = velocity end,
	}
	function entity:get_inventory() return self.inventory end
	function entity:get_wield_item_stack() return make_stack() end
	function entity:has_item_in_main(predicate)
		for _, stack in ipairs(self.inventory:get_list("main")) do
			if not stack:is_empty() and predicate(stack:get_name()) then return true end
		end
		return false
	end
	function entity:handle_night() end
	function entity:handle_chest() end
	function entity:handle_obstacles() end
	function entity:count_timer(timer_id)
		self.time_counters[timer_id] = (self.time_counters[timer_id] or 0) + 1
	end
	function entity:timer_exceeded(timer_id, limit)
		if (self.time_counters[timer_id] or 0) < limit then return false end
		self.time_counters[timer_id] = 0
		return true
	end
	function entity:set_displayed_action(value) self.displayed_action = value end
	function entity:set_state_info(value) self.state_info = value end
	function entity:set_animation(value) self.animation = value end
	function entity:collect_nearest_item_by_condition() return false end
	function entity:reserve_position() return true end
	function entity:release_reserved_position() end
	function entity:go_to()
		self.go_to_calls = self.go_to_calls + 1
		return true
	end
	function entity:dig()
		self.dig_calls = self.dig_calls + 1
		return true
	end
	function entity:place()
		self.place_calls = self.place_calls + 1
		return true
	end
	function entity:change_direction_randomly() end
	function entity:say() end
	return entity
end

local test_ok, test_error = xpcall(function()
	-- A wooden tool is not raw construction material. The old name fallback
	-- selected this stack solely because its item name contained "wood",
	-- making the future chest builder wait while stripping a worker of its axe.
	local tool_only = make_autonomous("autonomous_tool_only", {})
	provider.owner_name = tool_only.owner_name
	provider.inventory = make_inventory({{"test:axe_wood", 1}})
	game_time = 0
	providers_enabled = true
	harvesting_enabled = true
	tool_only.time_counters["autonome:search"] = 10
	registered_job.jobfunc(tool_only)
	assert_equal(#sent_messages, 0,
		"wooden axe name was mistaken for bootstrap construction wood")
	assert_true(tool_only._bootstrap_wood_wait_until == nil,
		"wooden axe created a bogus bootstrap rendezvous")
	assert_equal(tool_only.dig_calls, 1,
		"rejecting a wooden tool did not resume local tree harvesting")

	-- A real tree-group stack remains eligible and is requested exactly.
	local autonomous = make_autonomous("autonomous_waiter", {})
	provider.owner_name = autonomous.owner_name
	provider.inventory = make_inventory({{"test:tree", 8}})
	game_time = 0
	providers_enabled = true
	harvesting_enabled = false
	registered_job.jobfunc(autonomous)
	assert_equal(#sent_messages, 1, "bootstrap wood request was not sent exactly once")
	local payload = sent_messages[1].data
	assert_true(payload.bootstrap_infrastructure == true,
		"bootstrap wood request lacks infrastructure priority")
	assert_equal(payload.requester_id, autonomous.inventory_name,
		"bootstrap wood request lost its requester")
	assert_equal(payload.items["test:tree"], 8,
		"tree-group material was not requested exactly")
	assert_true(payload.items["test:axe_wood"] == nil,
		"bootstrap payload included a wooden tool")
	assert_true(tonumber(autonomous._bootstrap_wood_wait_until) == 30,
		"bootstrap wait is not bounded to 30 seconds")
	assert_equal(autonomous.velocity.x, 0, "waiting autonomous kept moving")
	assert_equal(autonomous.animation, working_villages.animation_frames.STAND,
		"waiting autonomous did not use STAND animation")
	assert_equal(autonomous.go_to_calls, 0, "waiting autonomous explored immediately")

	game_time = 10
	autonomous.velocity = {x = 3, y = 0, z = 0}
	registered_job.jobfunc(autonomous)
	assert_equal(#sent_messages, 1, "active rendezvous sent a duplicate request")
	assert_equal(autonomous.velocity.x, 0, "active rendezvous did not stop motion")
	assert_equal(autonomous.go_to_calls, 0, "active rendezvous allowed exploration")

	-- Expiration starts a separate retry backoff and immediately releases the
	-- worker to harvest instead of reopening the same 30-second wait.
	game_time = 31
	harvesting_enabled = true
	autonomous.time_counters["autonome:bootstrap"] = 40
	autonomous.time_counters["autonome:search"] = 10
	registered_job.jobfunc(autonomous)
	assert_equal(#sent_messages, 1, "expired wait relaunched a request immediately")
	assert_equal(autonomous.dig_calls, 1, "expired wait did not resume local harvesting")
	assert_true(tonumber(autonomous._bootstrap_wood_retry_after) == 61,
		"post-expiration request backoff is not bounded")
	assert_true(autonomous._bootstrap_wood_wait_until == nil,
		"expired rendezvous remained active")

	game_time = 32
	autonomous.time_counters["autonome:bootstrap"] = 40
	autonomous.time_counters["autonome:search"] = 10
	registered_job.jobfunc(autonomous)
	assert_equal(#sent_messages, 1, "retry backoff allowed an immediate duplicate request")
	assert_equal(autonomous.dig_calls, 2, "retry backoff prevented autonomous harvesting")

	-- If nobody can actually supply wood, no rendezvous is created and local
	-- harvesting remains available in the same decision.
	local alone = make_autonomous("autonomous_alone", {})
	providers_enabled = false
	game_time = 100
	harvesting_enabled = true
	alone.time_counters["autonome:search"] = 10
	registered_job.jobfunc(alone)
	assert_true(alone._bootstrap_wood_wait_until == nil,
		"autonomous worker waited despite having no supplier")
	assert_equal(alone.dig_calls, 1, "supplier absence blocked local harvesting")

	-- VoxeLibre's generalist owns the first workbench.  If nobody can deliver
	-- wood, it now performs a small, persisted hand-harvest allowance before the
	-- axe/workbench dependency cycle can strand the whole village.
	local hand_bootstrap = make_autonomous("autonomous_hand_bootstrap", {})
	fake_compat.is_voxelibre = true
	providers_enabled = false
	harvesting_enabled = true
	game_time = 150
	registered_job.jobfunc(hand_bootstrap)
	assert_equal(hand_bootstrap.dig_calls, 1,
		"VoxeLibre generalist did not hand-harvest its first workbench log")
	assert_equal(hand_bootstrap.displayed_action,
		"recolte du bois initial a mains nues",
		"hand bootstrap did not expose its bounded fallback action")
	assert_true(type(hand_bootstrap.job_data.autonomous_hand_bootstrap) == "table"
		and hand_bootstrap.job_data.autonomous_hand_bootstrap.logs_dug == 1,
		"hand bootstrap progress was not persisted")
	fake_compat.is_voxelibre = false

	-- Receiving the required chest item clears every transient wait/backoff
	-- field, so installation can proceed on the next available site.
	local supplied = make_autonomous("autonomous_supplied", {})
	providers_enabled = true
	game_time = 200
	harvesting_enabled = false
	registered_job.jobfunc(supplied)
	assert_true(supplied._bootstrap_wood_wait_until ~= nil,
		"second bootstrap rendezvous was not created")
	supplied.inventory.slots[1] = make_stack("test:chest", 1)
	game_time = 205
	registered_job.jobfunc(supplied)
	assert_true(supplied._bootstrap_wood_wait_until == nil
		and supplied._bootstrap_wood_retry_after == nil,
		"received chest item did not clear bootstrap wait state")
	assert_true(supplied.job_data.bootstrap_wood_provider == nil,
		"received chest item retained a stale provider")

	-- Utility crafting failures must remain visible and stable between retries.
	-- Missing stone is a local diagnostic, never a fabricated delivery command.
	local utility_waiter = make_autonomous("autonomous_utility_waiter", {})
	working_villages.get_shared_storage_pos = function() return {x = 0, y = 1, z = 0} end
	working_villages.is_chest_pos = function(pos) return pos ~= nil end
	working_villages.get_village_status = function() return {bootstrap_stage = "food"} end
	working_villages.get_village_bootstrap_stage = function() return "food" end
	local utility_craft_calls = 0
	working_villages.crafting.ensure_any_item = function()
		utility_craft_calls = utility_craft_calls + 1
		return nil, {
			missing_items = {},
			missing_specs = {["group:stone"] = 8},
			workstation_required = false,
		}
	end
	utility_waiter.time_counters["autonome:furnace_bootstrap"] = 40
	local messages_before_utility_wait = #sent_messages
	registered_job.jobfunc(utility_waiter)
	assert_equal(utility_waiter.displayed_action, "attend des pierres pour le four",
		"missing furnace stone did not surface as a useful action")
	assert_equal(utility_waiter.state_info,
		"Il me manque des pierres pour fabriquer le four du village.",
		"missing furnace stone did not surface as useful state information")
	assert_equal(#sent_messages, messages_before_utility_wait,
		"utility diagnostic emitted a false resource command")
	assert_equal(#utility_waiter.inventory:get_list("main"), 0,
		"utility diagnostic injected a resource")

	utility_waiter.displayed_action = "overwritten"
	registered_job.jobfunc(utility_waiter)
	assert_equal(utility_craft_calls, 1,
		"stable utility wait ignored the crafting retry cadence")
	assert_equal(utility_waiter.displayed_action, "attend des pierres pour le four",
		"utility wait action was overwritten between crafting attempts")
	assert_equal(#sent_messages, messages_before_utility_wait,
		"stable utility wait emitted a delayed false resource command")

	-- The cached diagnostic must not monopolize the worker. When ordinary
	-- stage work becomes available during the same cooldown, execution flows
	-- past the utility check and performs that fallback without recrafting.
	harvesting_enabled = true
	utility_waiter.time_counters["autonome:search"] = 10
	registered_job.jobfunc(utility_waiter)
	assert_equal(utility_craft_calls, 1,
		"fallback activity bypassed the utility crafting cooldown")
	assert_equal(utility_waiter.dig_calls, 1,
		"cached utility diagnostic blocked autonomous fallback work")
	local cached_wait = utility_waiter.job_data.bootstrap_furnace_site_craft_wait
	assert_true(type(cached_wait) == "table",
		"fallback activity discarded the cached utility diagnostic")
	assert_equal(cached_wait.info,
		"Il me manque des pierres pour fabriquer le four du village.",
		"fallback activity corrupted the cached utility diagnostic")
	assert_equal(#sent_messages, messages_before_utility_wait,
		"fallback after utility wait emitted a false resource command")
	assert_equal(#utility_waiter.inventory:get_list("main"), 0,
		"fallback after utility wait injected a resource")

	-- A utility already carried is a pending physical action, even if the
	-- economy stage changes before a failed placement path is retried.
	local carried_furnace = make_autonomous("autonomous_carried_furnace", {
		{"test:furnace", 1},
	})
	working_villages.get_village_status = function() return {bootstrap_stage = "wood"} end
	working_villages.get_village_bootstrap_stage = function() return "wood" end
	harvesting_enabled = true
	registered_job.jobfunc(carried_furnace)
	assert_equal(carried_furnace.place_calls, 1,
		"carried furnace was abandoned after an economy-stage transition")
	assert_equal(carried_furnace.dig_calls, 0,
		"carried furnace lost priority to fallback harvesting")
	assert_equal(carried_furnace.displayed_action, "installe un four",
		"carried furnace retry did not remain visible")
end, debug.traceback)

_G.working_villages = saved_working_villages
_G.minetest = saved_minetest
_G.vector = saved_vector

if not test_ok then error(test_error, 0) end
print("AUTONOMOUS_BOOTSTRAP_WAIT_SPEC_OK")
return true
