-- Deterministic regressions for frame-independent timers and missing-tool work.
-- Run from the repository root with:
--   lua5.1 working_villagers/tests/tool_fallback_spec.lua working_villagers

local modpath = (arg and arg[1]) or "working_villagers"
local gametime = 100

local groups = {
	["test:pick"] = {pickaxe = 1},
	["test:axe"] = {axe = 1},
	["test:stone"] = {},
}

minetest = {
	get_gametime = function() return gametime end,
	get_item_group = function(name, group)
		return groups[name] and groups[name][group] or 0
	end,
	settings = {
		get = function() return nil end,
	},
}

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) ..
			", got " .. tostring(actual), 2)
	end
end

local function stack(name)
	return {
		name = name or "",
		get_name = function(self) return self.name end,
		is_empty = function(self) return self.name == "" end,
	}
end

local function new_inventory(main, wield)
	local inv = {
		main = main or {},
		wield = wield or stack(),
	}
	function inv:get_list(name)
		return name == "main" and self.main or {}
	end
	return inv
end

local function new_villager(job_name, main, wield)
	local villager = {
		job_name = job_name,
		job_data = {},
		timers = {},
		inventory = new_inventory(main, wield),
		requests = 0,
		job_changes = 0,
		patrols = 0,
	}
	function villager:get_job_name() return self.job_name end
	function villager:get_inventory() return self.inventory end
	function villager:get_wield_item_stack() return self.inventory.wield end
	function villager:move_main_to_wield(predicate)
		for index, item in ipairs(self.inventory.main) do
			if predicate(item:get_name()) then
				local previous = self.inventory.wield
				self.inventory.wield = item
				table.remove(self.inventory.main, index)
				if not previous:is_empty() then
					table.insert(self.inventory.main, previous)
				end
				return true
			end
		end
		return false
	end
	function villager:set_timer(name, value) self.timers[name] = value end
	function villager:count_timer(name) self.timers[name] = (self.timers[name] or 0) + 1 end
	function villager:timer_exceeded(name, threshold)
		if (self.timers[name] or 0) >= threshold then
			self.timers[name] = 0
			return true
		end
		return false
	end
	function villager:set_displayed_action(action) self.action = action end
	function villager:set_state_info(info) self.info = info end
	function villager:change_direction_randomly() self.patrols = self.patrols + 1 end
	return villager
end

local timers = dofile(modpath .. "/timers.lua")
assert_equal(timers.increment({}, nil), 1, "legacy call outside on_step")
assert_equal(timers.increment({_timer_dtime = 0.1}), 1, "nominal frame increment")
assert_equal(timers.increment({_timer_dtime = 0.5}), 5, "slow frame normalization")
assert_equal(timers.increment({_timer_dtime = -1}), 0, "invalid negative dtime")
assert_equal(timers.seconds_to_steps(3), 30, "seconds conversion")

working_villages = {crafting = nil}
local fallback = dofile(modpath .. "/work_fallback.lua")

-- A wielded tool resumes immediately; a backpack tool is equipped before the
-- helper claims it is usable. Neither path may emit a request.
local wielded = new_villager("working_villages:job_miner", {}, stack("test:pick"))
local ready, source = fallback.ensure_tool(wielded, {
	key = "miner_pickaxe", tool_group = "pickaxe",
	request = function(v) v.requests = v.requests + 1 end,
})
assert_equal(ready, true, "wielded pickaxe readiness")
assert_equal(source, "inventory", "wielded pickaxe source")
assert_equal(wielded.requests, 0, "request with wielded pickaxe")

local backpack = new_villager("working_villages:job_miner", {stack("test:pick")}, stack("test:axe"))
ready = fallback.ensure_tool(backpack, {
	key = "miner_pickaxe", tool_group = "pickaxe",
	request = function(v) v.requests = v.requests + 1 end,
})
assert_equal(ready, true, "backpack pickaxe readiness")
assert_equal(backpack:get_wield_item_stack():get_name(), "test:pick", "backpack pickaxe was not equipped")
assert_equal(backpack.job_name, "working_villages:job_miner", "profession changed while equipping")
assert_equal(backpack.requests, 0, "request with backpack pickaxe")

-- Missing tools trigger one immediate request, remain deduplicated inside the
-- cooldown, and retry once at its exact boundary. A clock reset expires the
-- old timestamp instead of blocking the villager for hours.
local missing = new_villager("working_villages:job_miner")
missing.take_tool_from_shared_storage = function() return false end
local options = {
	key = "miner_pickaxe",
	tool_group = "pickaxe",
	tool_label = "une pioche",
	craft = function() return false end,
	request_cooldown = 30,
	request = function(v) v.requests = v.requests + 1 end,
}
ready = fallback.ensure_tool(missing, options)
assert_equal(ready, false, "missing pickaxe readiness")
assert_equal(missing.requests, 1, "first missing-tool request must be immediate")
for _ = 1, 100 do fallback.ensure_tool(missing, options) end
assert_equal(missing.requests, 1, "request spam at unchanged game time")
gametime = 129
fallback.ensure_tool(missing, options)
assert_equal(missing.requests, 1, "request before cooldown boundary")
gametime = 130
fallback.ensure_tool(missing, options)
assert_equal(missing.requests, 2, "request at cooldown boundary")
gametime = 50
fallback.ensure_tool(missing, options)
assert_equal(missing.requests, 3, "future persisted request timestamp was not invalidated")
assert_equal(missing.job_name, "working_villages:job_miner", "missing tool changed profession")
assert_equal(missing.job_changes, 0, "missing tool called change_job")

-- Shared storage transfers exactly one existing tool and equips it. No request
-- is sent and the total number of tools stays constant.
gametime = 200
local storage_count = 1
local from_storage = new_villager("working_villages:job_miner")
function from_storage:take_tool_from_shared_storage(group)
	if group ~= "pickaxe" or storage_count == 0 then return false end
	storage_count = storage_count - 1
	table.insert(self.inventory.main, stack("test:pick"))
	return true
end
ready, source = fallback.ensure_tool(from_storage, {
	key = "miner_pickaxe", tool_group = "pickaxe", craft = function() return false end,
	request = function(v) v.requests = v.requests + 1 end,
})
assert_equal(ready, true, "shared pickaxe readiness")
assert_equal(source, "shared_storage", "shared pickaxe source")
assert_equal(storage_count, 0, "shared storage source was not debited")
assert_equal(from_storage:get_wield_item_stack():get_name(), "test:pick", "shared pickaxe was not equipped")
assert_equal(from_storage.requests, 0, "request after shared transfer")
assert_equal(storage_count + (from_storage:get_wield_item_stack():get_name() == "test:pick" and 1 or 0),
	1, "shared transfer duplicated a tool")

-- Crafting remains real accounting delegated to the crafting callback.
local ingredients = 3
local crafted = new_villager("working_villages:job_woodcutter")
ready, source = fallback.ensure_tool(crafted, {
	key = "woodcutter_axe",
	tool_group = "axe",
	craft = function(v)
		if ingredients < 3 then return false end
		ingredients = ingredients - 3
		table.insert(v.inventory.main, stack("test:axe"))
		return true
	end,
	request = function(v) v.requests = v.requests + 1 end,
})
assert_equal(ready, true, "crafted axe readiness")
assert_equal(source, "crafted", "crafted axe source")
assert_equal(ingredients, 0, "craft ingredients were not consumed")
assert_equal(crafted:get_wield_item_stack():get_name(), "test:axe", "crafted axe was not equipped")
assert_equal(crafted.requests, 0, "request after successful craft")

-- Useful fallback collection moves a real dropped item. With no item it only
-- patrols; neither path changes profession or creates an item.
local dropped = 1
missing.collect_nearest_item_by_condition = function(self)
	if dropped == 0 then return false end
	dropped = dropped - 1
	table.insert(self.inventory.main, stack("test:stone"))
	return true
end
local before_total = dropped + #missing.inventory.main
local performed = fallback.perform(missing, options)
assert_equal(performed, true, "useful fallback collection")
assert_equal(dropped + #missing.inventory.main, before_total, "fallback collection created an item")
assert_equal(fallback.get_state(missing).useful_actions, 1, "useful fallback action count")
for _ = 1, 40 do fallback.perform(missing, options) end
assert(missing.patrols >= 1, "idle fallback never searched the surroundings")
assert_equal(missing.job_name, "working_villages:job_miner", "fallback patrol changed profession")

print("TOOL_FALLBACK_SPEC_OK")
