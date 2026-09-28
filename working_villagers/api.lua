--[[
  Core API for working_villages mod.
  
  This file contains the core API for villagers, including:
  - Animation frame definitions
  - Villager registration tables
  - Failed position tracking system
  - Base villager methods and properties

  This remains the compatibility-heavy entry point for villagers.
  New behavior should prefer dedicated modules when possible.
]]--

local log = working_villages.require("log")
local timers = working_villages.require("timers")

-- Luanti enters entity callbacks from C.  Lua 5.1/LuaJIT cannot yield across
-- that boundary, so async helpers must be able to distinguish a real job
-- coroutine from the engine's main callback before calling coroutine.yield().
local function coroutine_can_yield()
  if type(coroutine.isyieldable) == "function" then
    return coroutine.isyieldable() == true
  end
  local running, is_main = coroutine.running()
  if is_main ~= nil then
    return running ~= nil and is_main ~= true
  end
  return running ~= nil
end
working_villages.coroutine_can_yield = coroutine_can_yield

local function normalize_registered_name(name)
  if type(name) ~= "string" then
    error("registered name must be a string", 3)
  end

  local current_modname = minetest.get_current_modname and minetest.get_current_modname() or "working_villages"
  if name:sub(1, 1) == ":" then
    name = current_modname .. name
  elseif not name:find(":", 1, true) then
    name = current_modname .. ":" .. name
  end

  local prefix, identifier = name:match("^([a-z0-9_]+):([a-z0-9_]+)$")
  if not prefix or not identifier then
    error("invalid registered name " .. string.format("%q", name), 3)
  end
  return prefix .. ":" .. identifier
end

local cmnp = normalize_registered_name
local ai_behavior = working_villages.ai_behavior
local compat = working_villages.voxelibre_compat
local func = working_villages.require("jobs/util")
local village_registry = working_villages.village_registry
local inventory_access = working_villages.inventory_access or working_villages.require("inventory_access")

--[[
  Animation frames for villager entities.
  
  Each frame range corresponds to specific animations in the villager model.
  Used with villager:set_animation() to change villager appearance.
]]--
working_villages.animation_frames = {
  STAND     = { x=  0, y= 79, },  -- Standing still
  LAY       = { x=162, y=166, },  -- Lying down (sleeping)
  WALK      = { x=168, y=187, },  -- Walking animation
  MINE      = { x=189, y=198, },  -- Mining/working animation
  WALK_MINE = { x=200, y=219, },  -- Walking while carrying something
  SIT       = { x= 81, y=160, },  -- Sitting animation
}

-- Registry tables for mod entities
working_villages.registered_villagers = {}  -- All villager types
working_villages.registered_jobs = {}       -- All available jobs
working_villages.registered_eggs = {}       -- Spawn eggs

--[[
  Failed Position Tracking System

  Prevents villagers from repeatedly attempting actions at positions where
  they have previously failed. This improves performance and prevents
  stuck behaviors.

  Positions are marked as failed for 3 minutes, then automatically cleaned up.
]]--

-- Internal storage: key=hash(pos), val=expiry_time
local failed_pos_data = {}
local failed_pos_time = 0
local reserved_pos_data = {}
local reserved_pos_time = 0

local function runtime_seconds()
  if type(minetest.get_us_time) == "function" then
    return minetest.get_us_time() / 1000000
  end
  return minetest.get_gametime()
end

local function reservation_scope_name(scope)
  if scope == nil or scope == "" then
    return "generic"
  end
  return tostring(scope)
end

local function reservation_key(scope, pos)
  if not pos then
    return nil
  end
  return reservation_scope_name(scope) .. ":" .. minetest.hash_node_position(vector.round(pos))
end

local function reservation_cleanup()
  local discard_tab = {}
  local now = runtime_seconds()
  for key, reservation in pairs(reserved_pos_data) do
    if (not reservation) or now >= (reservation.expires_at or 0) then
      discard_tab[key] = true
    end
  end
  for key, _ in pairs(discard_tab) do
    reserved_pos_data[key] = nil
  end
end

--[[
  Cleans up expired failed positions.

  Called periodically to prevent memory bloat.
]]--
local function failed_pos_cleanup()
	-- build a list of all items to discard
	local discard_tab = {}
	local now = runtime_seconds()
	for key, val in pairs(failed_pos_data) do
		if now >= val then
			discard_tab[key] = true
		end
	end
	-- discard the old entries
	for key, _ in pairs(discard_tab) do
		failed_pos_data[key] = nil
	end
end

--[[
  Records a position as failed for 3 minutes.

  Villagers will skip this position when searching for targets.

  @param pos table - Position vector {x, y, z}
  @usage working_villages.failed_pos_record(failed_build_pos)
]]--
function working_villages.failed_pos_record(pos)
	local key = minetest.hash_node_position(pos)
	local now = runtime_seconds()
	failed_pos_data[key] = now + 180 -- mark for 3 real-time minutes

	-- cleanup if more than 1 minute has passed since the last cleanup
	if now > failed_pos_time then
		failed_pos_time = now + 60
		failed_pos_cleanup()
	end
end

--[[
  Checks if a position is marked as failed and hasn't expired.

  @param pos table - Position vector {x, y, z}
  @return boolean - true if position is currently marked as failed
  @usage if not working_villages.failed_pos_test(pos) then attempt_action(pos) end
]]--
function working_villages.failed_pos_test(pos)
	local key = minetest.hash_node_position(pos)
	local exp = failed_pos_data[key]
	return exp ~= nil and exp >= runtime_seconds()
end

function working_villages.reserve_pos(scope, pos, holder, ttl)
  local key = reservation_key(scope, pos)
  if not key then
    return false, nil
  end

  local now = runtime_seconds()
  if now > reserved_pos_time then
    reserved_pos_time = now + 30
    reservation_cleanup()
  end

  local reservation = reserved_pos_data[key]
  if reservation and reservation.expires_at >= now and reservation.holder ~= (holder or "") then
    return false, reservation
  end

  reservation = {
    scope = reservation_scope_name(scope),
    holder = holder or "",
    pos = vector.round(pos),
    expires_at = now + math.max(0.25, tonumber(ttl) or 6),
  }
  reserved_pos_data[key] = reservation
  return true, reservation
end

function working_villages.is_pos_reserved(scope, pos, holder)
  local key = reservation_key(scope, pos)
  if not key then
    return false, nil
  end
  local reservation = reserved_pos_data[key]
  local now = runtime_seconds()
  if (not reservation) or reservation.expires_at < now then
    reserved_pos_data[key] = nil
    return false, nil
  end
  if holder and holder ~= "" and reservation.holder == holder then
    return false, reservation
  end
  return true, reservation
end

function working_villages.release_pos(scope, pos, holder)
  local key = reservation_key(scope, pos)
  if not key then
    return false
  end
  local reservation = reserved_pos_data[key]
  if not reservation then
    return false
  end
  if holder and holder ~= "" and reservation.holder ~= holder then
    return false
  end
  reserved_pos_data[key] = nil
  return true
end

--[[
  Checks if an item name corresponds to a registered job.

  @param item_name string - Name of the item to check
  @return boolean - true if item is a job item
  @usage if working_villages.is_job(stack:get_name()) then ... end
]]--
function working_villages.is_job(item_name)
  if working_villages.registered_jobs[item_name] then
    return true
  end
  return false
end

--[[
  Checks if a name corresponds to a registered villager type.

  @param name string - Entity name to check
  @return boolean - true if name is a villager entity
  @usage if working_villages.is_villager(entity.name) then ... end
]]--
function working_villages.is_villager(name)
  if working_villages.registered_villagers[name] then
    return true
  end
  return false
end

---------------------------------------------------------------------
-- Villager Base Class
---------------------------------------------------------------------

--[[
  working_villages.villager - Base class for all villagers

  This table contains common methods for all villager objects.
  It is used as the metatable.__index for villager self tables.

  All methods in this table are available on villager instances via self:method()
]]--
working_villages.villager = {}

local shared_storage_marker_key = "working_villages_shared_storage"
local shared_storage_owner_marker_key = "working_villages_shared_storage_owner"

local function is_chest_pos(pos)
  if not pos then
    return false
  end
  local node = minetest.get_node_or_nil(pos)
  if not node then
    return false
  end
  local chest_node = working_villages.voxelibre_compat.is_chest(node)
    or minetest.get_item_group(node.name, "villager_chest") > 0
    or minetest.get_item_group(node.name, "chest") > 0
  if not chest_node then
    return false
  end
  -- The economy directly uses a node-local `main` inventory. Personal or
  -- virtual containers (for example VoxeLibre Ender Chests) deliberately do
  -- not expose one and must never become village storage.
  local meta = minetest.get_meta(pos)
  local inv = meta and meta:get_inventory() or nil
  return inv ~= nil and inv:get_size("main") > 0
end

local function get_chest_inventory(pos)
  if not pos then
    return nil
  end
  local meta = minetest.get_meta(pos)
  if not meta then
    return nil
  end
  return meta:get_inventory()
end

local function get_shared_storage_owner_marker(pos)
  if not is_chest_pos(pos) then
    return ""
  end
  local meta = minetest.get_meta(pos)
  if not meta then
    return ""
  end
  return meta:get_string(shared_storage_owner_marker_key) or ""
end

local function is_shared_storage_marker_pos(pos, owner_name)
  if not is_chest_pos(pos) then
    return false
  end
  local meta = minetest.get_meta(pos)
  if not meta or meta:get_int(shared_storage_marker_key) ~= 1 then
    return false
  end
  local marked_owner = meta:get_string(shared_storage_owner_marker_key) or ""
  if owner_name and owner_name ~= "" then
    return marked_owner == owner_name
  end
  return marked_owner ~= ""
end

local function mark_shared_storage_pos(pos, owner_name)
  if not is_chest_pos(pos) or not owner_name or owner_name == "" then
    return false
  end
  local meta = minetest.get_meta(pos)
  if not meta then
    return false
  end
  meta:set_int(shared_storage_marker_key, 1)
  meta:set_string(shared_storage_owner_marker_key, owner_name)
  return true
end

local function clear_shared_storage_marker(pos, owner_name)
  if not is_chest_pos(pos) then
    return false
  end
  local meta = minetest.get_meta(pos)
  if not meta then
    return false
  end
  local marked_owner = meta:get_string(shared_storage_owner_marker_key) or ""
  if owner_name and owner_name ~= "" and marked_owner ~= "" and marked_owner ~= owner_name then
    return false
  end
  meta:set_int(shared_storage_marker_key, 0)
  meta:set_string(shared_storage_owner_marker_key, "")
  return true
end

local function get_chest_search_list()
  return compat.get_chest_search_nodes()
end

local function find_chests_in_area(minp, maxp)
  local nodes = minetest.find_nodes_in_area(minp, maxp, get_chest_search_list())
  local results = {}
  local by_hash = {}
  for _, pos in ipairs(nodes) do
    local key = minetest.hash_node_position(pos)
    if not by_hash[key] and is_chest_pos(pos) then
      by_hash[key] = true
      table.insert(results, pos)
    end
  end
  return results
end

local function count_items_in_inventory(inv, predicate)
  if not inv then
    return 0
  end
  local total = 0
  local size = inv:get_size("main")
  for i = 1, size do
    local stack = inv:get_stack("main", i)
    if not stack:is_empty() and predicate(stack:get_name()) then
      total = total + stack:get_count()
    end
  end
  return total
end

local function find_tool_stack_by_group(inv, group)
  if not inv then
    return nil, nil
  end
  local size = inv:get_size("main")
  for i = 1, size do
    local stack = inv:get_stack("main", i)
    if not stack:is_empty() and minetest.get_item_group(stack:get_name(), group) > 0 then
      return stack, i
    end
  end
  return nil, nil
end

local function is_food_item(name)
  return minetest.get_item_group(name, "food") > 0
end

local function is_wood_item(name)
  if minetest.get_item_group(name, "tree") > 0 then
    return true
  end
  if minetest.get_item_group(name, "wood") > 0 then
    return true
  end
  if name:find("wood", 1, true) or name:find("tree", 1, true) or name:find("log", 1, true) then
    return true
  end
  return false
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

local function is_tool_item(name)
  if not name or name == "" then
    return false
  end
  local tool_groups = {"pickaxe", "axe", "shovel", "hoe", "sword", "shield"}
  for _, group in ipairs(tool_groups) do
    if minetest.get_item_group(name, group) > 0 then
      return true
    end
  end
  local vl_compat = working_villages.voxelibre_compat
  if vl_compat then
    if vl_compat.is_furnace and vl_compat.is_furnace(name) then
      return true
    end
    if vl_compat.is_crafting_table and vl_compat.is_crafting_table(name) then
      return true
    end
  end
  return false
end

function working_villages.is_forged_tool_item(name)
  if not name or name == "" or not compat or not compat.get_tool_item then
    return false
  end
  if working_villages._forged_tool_items == nil then
    working_villages._forged_tool_items = {}
    for _, kind in ipairs({"pickaxe", "axe", "shovel", "hoe", "sword"}) do
      for _, tier in ipairs({"iron", "steel", "bronze", "gold", "mese", "diamond"}) do
        local candidate = compat.get_tool_item(kind, tier)
        if candidate then working_villages._forged_tool_items[candidate] = true end
      end
    end
  end
  return working_villages._forged_tool_items[name] == true
end

local function is_material_item(name)
  if not name or name == "" or name == "air" or name == "ignore" then
    return false
  end
  -- Builders consume registered node items. Counting the same category here
  -- keeps the material gauge tied to stock that can actually be placed.
  return minetest.registered_nodes and minetest.registered_nodes[name] ~= nil
end

local blueprint_name_aliases = {
  ["simple_hut.we"] = "simple_house",
  ["fancy_hut.we"] = "fancy_house",
  ["minimal_house.we"] = "minimal_house",
  ["minimal_shelter.we"] = "minimal_shelter",
  ["[custom house]"] = "custom_house",
}

local house_blueprint_names = {
  simple_house = true,
  fancy_house = true,
  minimal_house = true,
  minimal_shelter = true,
  custom_house = true,
}

local village_focus_descriptions = {
  balanced = "equilibre",
  food = "survie alimentaire",
  defense = "defense du village",
  housing = "logement",
  industry = "production d'outils",
	exploration = "exploration",
}

local village_notification_levels = {
  silent = 0,
  important = 1,
  detailed = 2,
}

local default_village_control = {
  focus = "balanced",
  notify_level = "important",
  next_build = "",
}

local shared_storage_summary_cache = {}
local village_status_cache = {}
local shared_storage_cache_ttl = tonumber(minetest.settings:get("working_villages_storage_cache_ttl")) or 2
local village_status_cache_ttl = tonumber(minetest.settings:get("working_villages_village_status_cache_ttl")) or 2
local construction_site_registry_warmed = {}
local construction_site_stats_metrics = {
  legacy_scans = 0,
  registry_fast_paths = 0,
  registry_entries_checked = 0,
}

local function village_control_key(owner_name)
  return "_village_control_" .. owner_name
end

local function normalize_village_control(data)
  local control = {
    focus = default_village_control.focus,
    notify_level = default_village_control.notify_level,
    next_build = default_village_control.next_build,
  }

  if type(data) ~= "table" then
    return control
  end

  if type(data.focus) == "string" and village_focus_descriptions[data.focus] then
    control.focus = data.focus
  end
  if type(data.notify_level) == "string" and village_notification_levels[data.notify_level] ~= nil then
    control.notify_level = data.notify_level
  end
  if type(data.next_build) == "string" and data.next_build ~= "" then
    control.next_build = working_villages.normalize_blueprint_name(data.next_build)
  end

  return control
end

function working_villages.describe_village_focus(focus)
  return village_focus_descriptions[focus] or village_focus_descriptions.balanced
end

function working_villages.describe_notification_level(level)
  if level == "detailed" then
    return "detaillees"
  end
  if level == "silent" then
    return "silence"
  end
  return "importantes"
end

function working_villages.get_owner_village_control(owner_name)
  if not owner_name or owner_name == "" then
    return normalize_village_control(nil)
  end
  local key = village_control_key(owner_name)
  return normalize_village_control(working_villages.get_stored_table(key))
end

function working_villages.set_owner_village_control(owner_name, updates)
  if not owner_name or owner_name == "" then
    return normalize_village_control(nil)
  end

  local control = working_villages.get_owner_village_control(owner_name)
  if type(updates) == "table" then
    for key, value in pairs(updates) do
      control[key] = value
    end
  end
  control = normalize_village_control(control)

  local key = village_control_key(owner_name)
  working_villages.set_stored_table(key, control)
  working_villages.clear_cached_table(key)
  if village_registry then
    local village, ensure_error = village_registry.ensure(owner_name)
    if village then
      local updated, update_error = village_registry.update(owner_name, {priorities = control})
      if not updated then
        log.warning("Village priority registry sync failed for %s: %s", owner_name, tostring(update_error))
      end
    else
      log.warning("Village priority registry creation failed for %s: %s", owner_name, tostring(ensure_error))
    end
  end
  return control
end

local village_coordination_timer_ids = {
  "shared_storage_scan",
  "auto_job",
  "equip_refresh",
  "danger_scan",
  "resource_requests",
  "needs_resources",
  "maintenance",
  "ai_decision",
  "hunger_search",
  "hunger_help",
  "combat:repath",
  "autonome:bootstrap",
  "autonome:search",
  "autonome:supply",
  "autonome:explore",
  "builder:search",
  "builder:tool_request",
  "builder:auto_site",
  "blacksmith:search",
  "blacksmith:request",
  "blacksmith:stock",
  "farmer:search",
	"farmer:seed_search",
  "farmer:hoe_request",
  "farmer:expand_farm",
  "woodcutter:search",
  "woodcutter:axe_request",
  "woodcutter:reforest",
  "miner:search",
  "miner:pick_request",
  "miner:torch_check",
  "guard:equipment",
  "guard:patrol",
  "cook:work",
  "empty:check_learning",
  "learner:think",
  "learner:experiment",
}

local function list_loaded_owner_villagers(owner_name)
  local results = {}
  if not owner_name or owner_name == "" then
    return results
  end
  for _, lua in pairs(minetest.luaentities or {}) do
    if lua and lua.name and working_villages.is_villager(lua.name) then
      if (lua.owner_name or "") == owner_name then
        table.insert(results, lua)
      end
    end
  end
  return results
end

local function get_owner_anchor_villager(owner_name)
  local villagers = list_loaded_owner_villagers(owner_name)
  return villagers[1]
end

local function nudge_villager_coordination(villager, message)
  if not villager then
    return false
  end
  villager.job_data = villager.job_data or {}

  if villager.pause and villager.pause_auto then
    villager:set_pause(false)
    villager.pause_auto = nil
  end
  if villager.job_data.pause_reason == "auto" then
    villager.job_data.pause_reason = nil
  end

  if villager.clear_timers then
    villager:clear_timers()
  end
  if villager.set_timer then
    for _, timer_id in ipairs(village_coordination_timer_ids) do
      villager:set_timer(timer_id, 9999)
    end
  end

  if villager.equip_best_weapon then
    villager:equip_best_weapon()
  end
  if villager.equip_best_armor then
    villager:equip_best_armor()
  end
  if villager.maybe_auto_assign_job and (not villager.get_job_name or villager:get_job_name() == "") then
    villager:maybe_auto_assign_job()
  end

  villager:set_displayed_action("se recoordonne")
  villager:set_state_info(message or "Je revois mes priorites pour aider le village.")
  return true
end

function working_villages.get_recommended_village_control(village)
  village = village or {}
  local counts = village.counts or {}
  local population = math.max(village.population or 0, 1)
  local total_food = (village.available_food or village.food or 0)
    + (village.available_raw_food or village.raw_food or 0)
  local wood = village.available_wood or village.wood or 0
  local ore = village.available_ore or village.ore or 0
  local tools = village.available_tools or village.tools or 0
  local stage = village.bootstrap_stage or working_villages.get_village_bootstrap_stage(village)
  local focus = "balanced"
  local next_build = ""
  local reason = "equilibre general"

  if stage == "wood" or stage == "storage" or stage == "food" then
    focus = "food"
    reason = "bootstrap " .. working_villages.describe_bootstrap_stage(stage)
  elseif stage == "tools" then
    focus = "industry"
    reason = "outils et artisanat"
  elseif stage == "defense" then
    focus = "defense"
    reason = "defense du village"
  else
    if (village.recent_danger or 0) > 0 then
      focus = "defense"
      next_build = "watchtower"
      reason = "danger recent"
    elseif (village.homeless or 0) > 0 then
      focus = "housing"
      next_build = "simple_house"
      reason = "logement"
    elseif total_food < math.max(24, population * 6) then
      focus = "food"
      next_build = wood >= 18 and "farm_plot" or ""
      reason = "stocks de nourriture bas"
    elseif tools < math.max(4, population) then
      focus = "industry"
      if (counts["working_villages:job_blacksmith"] or 0) > 0 and wood >= 45 and ore >= math.max(8, population * 2) then
        next_build = "blacksmith_forge"
      elseif wood >= 45 then
        next_build = "workshop"
      end
      reason = "outils insuffisants"
    end
  end

  if stage ~= "build" or (village.active_sites or 0) > 0 then
    next_build = ""
  end

  return {
    focus = focus,
    notify_level = "detailed",
    next_build = next_build,
  }, stage, reason
end

function working_villages.activate_village_coordination(target, opts)
  opts = opts or {}
  local owner_name = type(target) == "table" and target.owner_name or target
  if not owner_name or owner_name == "" then
    return nil
  end

  local anchor = type(target) == "table" and target or get_owner_anchor_villager(owner_name)
  local village = nil
  if anchor and working_villages.get_village_status then
    village = working_villages.get_village_status(anchor, opts.radius or 50)
  end

  local updates, stage, reason = working_villages.get_recommended_village_control(village or {})
  local current = working_villages.get_owner_village_control(owner_name)
  if current.next_build ~= "" and not opts.force_next_build then
    updates.next_build = current.next_build
  end
  if type(opts.updates) == "table" then
    for key, value in pairs(opts.updates) do
      updates[key] = value
    end
  end

  local control = working_villages.set_owner_village_control(owner_name, updates)
  local stage_label = working_villages.describe_bootstrap_stage(stage)
  local focus_label = working_villages.describe_village_focus(control.focus)
  local message = string.format("Je revois mes priorites: %s (phase %s).", focus_label, stage_label)
  local nudged = 0
  for _, villager in ipairs(list_loaded_owner_villagers(owner_name)) do
    if nudge_villager_coordination(villager, message) then
      nudged = nudged + 1
    end
  end

  return {
    owner_name = owner_name,
    control = control,
    stage = stage,
    stage_label = stage_label,
    reason = reason,
    nudged = nudged,
  }
end

local function empty_storage_summary()
  return {
    food = 0,
    raw_food = 0,
    wood = 0,
    ore = 0,
    tools = 0,
    forged_tools = 0,
    ingots = 0,
    materials = 0,
  }
end

local function storage_summary_cache_key(base_pos)
  if not base_pos then
    return nil
  end
  return minetest.hash_node_position(vector.round(base_pos))
end

local function summarize_inventory_categories(inv, summary)
  if not inv then
    return
  end
  -- Chests expose only "main"; villager inventories also keep usable tools in
  -- wield/offhand, which must count as real stock rather than disappearing from
  -- the gauge while equipped.
  for _, listname in ipairs({"main", "wield_item", "offhand"}) do
    local size = inv:get_size(listname) or 0
    for i = 1, size do
      local stack = inv:get_stack(listname, i)
      if not stack:is_empty() then
        local name = stack:get_name()
        local count = stack:get_count()
        if is_food_item(name) then
          summary.food = summary.food + count
        end
        if is_raw_food_item(name) then
          summary.raw_food = summary.raw_food + count
        end
        if is_wood_item(name) then
          summary.wood = summary.wood + count
        end
        if is_ore_item(name) then
          summary.ore = summary.ore + count
        end
        if is_tool_item(name) then
          summary.tools = summary.tools + count
        end
        if working_villages.is_forged_tool_item(name) then
          summary.forged_tools = summary.forged_tools + count
        end
        if compat.is_metal_ingot and compat.is_metal_ingot(name) then
          summary.ingots = summary.ingots + count
        end
        if is_material_item(name) then
          summary.materials = summary.materials + count
        end
      end
    end
  end
end

local get_shared_storage_chests

local function get_shared_storage_summary(base_pos)
  local summary = empty_storage_summary()
  if not is_chest_pos(base_pos) then
    return summary
  end

  local now = minetest.get_gametime()
  local cache_key = storage_summary_cache_key(base_pos)
  local cached = cache_key and shared_storage_summary_cache[cache_key] or nil
  if cached and (now - cached.at) <= shared_storage_cache_ttl then
    return cached.summary
  end

  local chests = get_shared_storage_chests(base_pos)
  if #chests == 0 then
    chests = {base_pos}
  end
  for _, pos in ipairs(chests) do
    summarize_inventory_categories(get_chest_inventory(pos), summary)
  end

  if cache_key then
    shared_storage_summary_cache[cache_key] = {
      at = now,
      summary = summary,
    }
  end

  return summary
end

local function collect_owned_supply_summary(owner_name)
  local summary = empty_storage_summary()
  local owner = owner_name or ""

  for _, lua in pairs(minetest.luaentities or {}) do
    if lua and lua.name and working_villages.is_villager(lua.name) then
      if (lua.owner_name or "") == owner and lua.get_inventory then
        summarize_inventory_categories(lua:get_inventory(), summary)
      end
    end
  end

  return summary
end

function working_villages.describe_bootstrap_stage(stage)
  local labels = {
    wood = "bois",
    storage = "coffre commun",
    food = "nourriture",
    tools = "outils et artisanat",
    defense = "defense",
    build = "premier chantier",
  }
  return labels[stage] or "developpement"
end

function working_villages.get_village_bootstrap_stage(village)
  return working_villages.needs.choose_bootstrap_stage(village)
end

local function make_village_status_cache_key(owner_name, center, radius)
  local rounded = center and vector.round(center) or {x = 0, y = 0, z = 0}
  return ("%s:%d:%d:%d:%d"):format(
    owner_name or "",
    radius or 0,
    rounded.x or 0,
    rounded.y or 0,
    rounded.z or 0
  )
end

function working_villages.normalize_blueprint_name(name)
  if not name or name == "" then
    return ""
  end
  if blueprint_name_aliases[name] then
    return blueprint_name_aliases[name]
  end
  return name:gsub("%.we$", "")
end

local function scan_owned_villagers(owner_name)
  local counts = {}
  local total = 0
  local homeless = 0
  local recent_danger = 0
  local owner = owner_name or ""
  local loaded_ids = {}

  for _, lua in pairs(minetest.luaentities or {}) do
    if lua and lua.name and working_villages.is_villager(lua.name) then
      if (lua.owner_name or "") == owner then
        total = total + 1
        if lua.inventory_name then
          loaded_ids[lua.inventory_name] = true
        end
        local job_name = lua.get_job_name and lua:get_job_name() or ""
        counts[job_name] = (counts[job_name] or 0) + 1
        if lua.has_home and not lua:has_home() then
          homeless = homeless + 1
        end
        local danger_ticks = lua.job_data and tonumber(lua.job_data.danger_ticks) or 0
        if danger_ticks > recent_danger then
          recent_danger = danger_ticks
        end
      end
    end
  end

  if working_villages.population and working_villages.population.snapshot then
    for inventory_name, record in pairs(working_villages.population.snapshot()) do
      if record.owner_name == owner and not loaded_ids[inventory_name] then
        total = total + 1
        if type(record.job_name) == "string" and record.job_name ~= "" then
          counts[record.job_name] = (counts[record.job_name] or 0) + 1
        end
        if not (working_villages.homes and working_villages.homes[inventory_name]) then
          homeless = homeless + 1
        end
      end
    end
  end

  return counts, total, homeless, recent_danger
end

local function count_owned_villagers_by_job(owner_name)
  local counts, total = scan_owned_villagers(owner_name)
  return counts, total
end

local function empty_building_site_stats()
  return {
    active_sites = 0,
    built_sites = 0,
    buildings = {},
    active_buildings = {},
    built_buildings = {},
    houses = 0,
    active_houses = 0,
    built_houses = 0,
  }
end

local function scan_building_markers(center, radius)
  construction_site_stats_metrics.legacy_scans =
    construction_site_stats_metrics.legacy_scans + 1
  local minp = vector.subtract(center, radius)
  local maxp = vector.add(center, radius)
  return minetest.find_nodes_in_area(minp, maxp, {"working_villages:building_marker"})
end

local function marker_position(entry)
  local pos = type(entry) == "table" and entry.marker or nil
  if type(pos) ~= "table" or type(pos.x) ~= "number" or
      type(pos.y) ~= "number" or type(pos.z) ~= "number" then
    return nil
  end
  return vector.round(pos)
end

local function marker_is_in_cube(pos, center, radius)
  return math.abs(pos.x - center.x) <= radius and
    math.abs(pos.y - center.y) <= radius and
    math.abs(pos.z - center.z) <= radius
end

local function marker_coordinate_key(pos)
  return ("%d:%d:%d"):format(pos.x, pos.y, pos.z)
end

local function loaded_building_marker(pos)
  local node = type(minetest.get_node_or_nil) == "function"
    and minetest.get_node_or_nil(pos) or minetest.get_node(pos)
  return node and node.name == "working_villages:building_marker"
end

local function tally_building_marker(stats, pos, owner)
  local meta = minetest.get_meta(pos)
  if owner ~= "" and meta:get_string("owner") ~= owner then
    return
  end
  local state = meta:get_string("state")
  local blueprint_name = working_villages.normalize_blueprint_name(meta:get_string("schematic"))
  local is_house = house_blueprint_names[blueprint_name] == true

  if state == "planned" or state == "paused" or state == "begun" then
    stats.active_sites = stats.active_sites + 1
    if blueprint_name ~= "" then
      stats.buildings[blueprint_name] = (stats.buildings[blueprint_name] or 0) + 1
      stats.active_buildings[blueprint_name] =
        (stats.active_buildings[blueprint_name] or 0) + 1
      if is_house then
        stats.active_houses = stats.active_houses + 1
        stats.houses = stats.houses + 1
      end
    end
  elseif state == "built" then
    stats.built_sites = stats.built_sites + 1
    if blueprint_name ~= "" then
      stats.buildings[blueprint_name] = (stats.buildings[blueprint_name] or 0) + 1
      stats.built_buildings[blueprint_name] =
        (stats.built_buildings[blueprint_name] or 0) + 1
      if is_house then
        stats.built_houses = stats.built_houses + 1
        stats.houses = stats.houses + 1
      end
    end
  end
end

local function warm_construction_site_registry(center, radius, owner)
  if construction_site_registry_warmed[owner] then
    return nil, true
  end

  -- The LBM in building.lua is the durable migration path. This one-time
  -- bounded scan closes the startup race for the first status request and also
  -- covers a mixed village containing indexed and pre-registry markers.
  local village = village_registry.ensure(owner, {center = center})
  local markers = scan_building_markers(center, radius)
  if not village or type(working_villages.sync_construction_site_registry) ~= "function" then
    return markers, false
  end

  local complete = true
  for _, pos in ipairs(markers) do
    if minetest.get_meta(pos):get_string("owner") == owner and
        not working_villages.sync_construction_site_registry(pos) then
      complete = false
    end
  end
  if complete then
    construction_site_registry_warmed[owner] = true
  end
  return markers, complete
end

local function collect_building_site_stats(center, radius, owner_name)
  local stats = empty_building_site_stats()
  if not center then
    return stats
  end

  local rounded_center = vector.round(center)
  local effective_radius = radius or 40
  local owner = owner_name or ""
  local migration_markers = nil
  local migration_complete
  local seen = {}

  if owner ~= "" and village_registry then
    migration_markers, migration_complete =
      warm_construction_site_registry(rounded_center, effective_radius, owner)
    local village = village_registry.get(owner)
    if village then
      for _, entry in pairs(village.construction_sites or {}) do
        construction_site_stats_metrics.registry_entries_checked =
          construction_site_stats_metrics.registry_entries_checked + 1
        local pos = marker_position(entry)
        if pos and marker_is_in_cube(pos, rounded_center, effective_radius) and
            loaded_building_marker(pos) then
          local key = marker_coordinate_key(pos)
          if not seen[key] then
            seen[key] = true
            tally_building_marker(stats, pos, owner)
          end
        end
      end
      if migration_complete then
        construction_site_stats_metrics.registry_fast_paths =
          construction_site_stats_metrics.registry_fast_paths + 1
        return stats
      end
    end
  end

  -- Empty-owner callers retain the historical all-owner behavior. A registry
  -- failure also falls back to the exact legacy scan instead of losing sites.
  local markers = migration_markers or scan_building_markers(rounded_center, effective_radius)
  for _, pos in ipairs(markers) do
    local key = marker_coordinate_key(vector.round(pos))
    if not seen[key] then
      seen[key] = true
      tally_building_marker(stats, pos, owner)
    end
  end

  return stats
end

if type(minetest.get_modpath) == "function" and minetest.get_modpath("working_villages_test") then
  working_villages._test_collect_building_site_stats = collect_building_site_stats
  working_villages._test_construction_site_stats_metrics = function()
    return {
      legacy_scans = construction_site_stats_metrics.legacy_scans,
      registry_fast_paths = construction_site_stats_metrics.registry_fast_paths,
      registry_entries_checked = construction_site_stats_metrics.registry_entries_checked,
    }
  end
end

local function registry_values_equal(left, right, seen)
  if type(left) ~= type(right) then
    return false
  end
  if type(left) ~= "table" then
    return left == right
  end
  seen = seen or {}
  seen[left] = seen[left] or {}
  if seen[left][right] then
    return true
  end
  seen[left][right] = true
  for key, value in pairs(left) do
    if not registry_values_equal(value, right[key], seen) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

function working_villages.record_village_threat(owner_name, pos, kind)
  if not village_registry or not owner_name or owner_name == "" or not pos then
    return false
  end
  pos = vector.round(pos)
  local village = village_registry.ensure(owner_name, {center = pos})
  if not village then
    return false
  end
  local danger = type(village.danger) == "table" and village.danger or {}
  local threats = type(danger.threats) == "table" and danger.threats or {}
  local key = "threat:" .. tostring(minetest.hash_node_position(pos))
  local now = minetest.get_gametime()
  local previous = threats[key]
  if previous and now - (tonumber(previous.last_seen) or 0) < 20 then
    return true
  end
  threats[key] = {
    id = key,
    kind = kind or "enemy",
    pos = pos,
    last_seen = now,
    expires_at = now + 200,
  }
  danger.active = true
  danger.level = math.max(1, tonumber(danger.level) or 0)
  danger.threats = threats
  return village_registry.update(owner_name, {danger = danger}) ~= nil
end

function working_villages.resolve_village_threat(owner_name, pos)
  if not village_registry or not owner_name or owner_name == "" or not pos then
    return false
  end
  local village = village_registry.get(owner_name)
  if not village or type(village.danger) ~= "table" then
    return false
  end
  local danger = village.danger
  local threats = type(danger.threats) == "table" and danger.threats or {}
  local key = "threat:" .. tostring(minetest.hash_node_position(vector.round(pos)))
  if threats[key] == nil then
    return false
  end
  threats[key] = nil
  danger.threats = threats
  danger.active = next(threats) ~= nil
  if not danger.active then
    danger.level = 0
  end
  return village_registry.update(owner_name, {danger = danger}) ~= nil
end

local function sync_village_registry_status(owner_name, status)
  if not village_registry or not owner_name or owner_name == "" or not status then
    return
  end
  local radius = math.max(16,
    tonumber(minetest.settings:get("working_villages_population_radius")) or 64)
  local initial = {radius = radius}
  if status.center then
    initial.center = vector.round(status.center)
  end
  local village, ensure_error = village_registry.ensure(owner_name, initial)
  if not village then
    log.warning("Village status registry creation failed for %s: %s", owner_name, tostring(ensure_error))
    return
  end

  local resources = {
    food = status.available_food or 0,
    raw_food = status.available_raw_food or 0,
    wood = status.available_wood or 0,
    ore = status.available_ore or 0,
    tools = status.available_tools or 0,
    materials = status.available_materials or 0,
  }
  local threats = {}
  local now = minetest.get_gametime()
  for key, threat in pairs(type(village.danger) == "table" and village.danger.threats or {}) do
    if type(threat) == "table" and (tonumber(threat.expires_at) or 0) > now then
      threats[key] = threat
    end
  end
  local danger = {
    active = (status.recent_danger or 0) > 0 or next(threats) ~= nil,
    level = math.max(next(threats) and 1 or 0, tonumber(status.recent_danger) or 0),
    threats = threats,
  }
  local metadata = type(village.metadata) == "table" and village.metadata or {}
  metadata.status = {
    gameplay_mode = working_villages.gameplay_mode,
    population = status.population or 0,
    homeless = status.homeless or 0,
    roles = status.counts or {},
    bootstrap_stage = status.bootstrap_stage or "build",
    active_sites = status.active_sites or 0,
    built_sites = status.built_sites or 0,
  }

  local patch = {}
  if status.center and not registry_values_equal(village.center, vector.round(status.center)) then
    patch.center = vector.round(status.center)
  end
  if village.radius ~= radius then
    patch.radius = radius
  end
  if not registry_values_equal(village.resources or {}, resources) then
    patch.resources = resources
  end
  if not registry_values_equal(village.priorities or {}, status.control or {}) then
    patch.priorities = status.control or {}
  end
  if not registry_values_equal(village.danger or {}, danger) then
    patch.danger = danger
  end
  if not registry_values_equal(village.metadata or {}, metadata) then
    patch.metadata = metadata
  end
  if next(patch) then
    local updated, update_error = village_registry.update(owner_name, patch)
    if not updated then
      log.warning("Village status registry sync failed for %s: %s", owner_name, tostring(update_error))
    end
  end
end

function working_villages.get_village_status(self, radius)
  local shared_storage_pos = self:ensure_shared_storage_pos()
  local center = shared_storage_pos
    or (self.pos_data and (self.pos_data.home_pos or self.pos_data.job_pos or self.pos_data.storage_pos))
    or self.object:get_pos()
  local now = minetest.get_gametime()
  local cache_key = make_village_status_cache_key(self.owner_name, center, radius or 50)
  local cached = village_status_cache[cache_key]
  if cached and (now - cached.at) <= village_status_cache_ttl then
    return cached.value
  end

  local counts, population, homeless, recent_danger = scan_owned_villagers(self.owner_name)
  local site_stats = collect_building_site_stats(center, radius or 50, self.owner_name)
  local control = working_villages.get_owner_village_control(self.owner_name)
  local shared_storage_ready = is_chest_pos(shared_storage_pos)
  local storage_summary = get_shared_storage_summary(shared_storage_pos)
  local carried_summary = collect_owned_supply_summary(self.owner_name)

  local status = {
    center = center,
    shared_storage_ready = shared_storage_ready,
    shared_storage_pos = shared_storage_ready and vector.round(shared_storage_pos) or nil,
    counts = counts,
    population = population,
    homeless = homeless,
    recent_danger = recent_danger,
    control = control,
    food = storage_summary.food,
    raw_food = storage_summary.raw_food,
    wood = storage_summary.wood,
    ore = storage_summary.ore,
    tools = storage_summary.tools,
    forged_tools = storage_summary.forged_tools,
    ingots = storage_summary.ingots,
    materials = storage_summary.materials,
    active_sites = site_stats.active_sites,
    built_sites = site_stats.built_sites,
    buildings = site_stats.buildings,
    active_buildings = site_stats.active_buildings,
    built_buildings = site_stats.built_buildings,
    houses = site_stats.houses,
    active_houses = site_stats.active_houses,
    built_houses = site_stats.built_houses,
    carried_food = carried_summary.food,
    carried_raw_food = carried_summary.raw_food,
    carried_wood = carried_summary.wood,
    carried_ore = carried_summary.ore,
    carried_tools = carried_summary.tools,
    carried_forged_tools = carried_summary.forged_tools,
    carried_ingots = carried_summary.ingots,
    carried_materials = carried_summary.materials,
    available_food = storage_summary.food + carried_summary.food,
    available_raw_food = storage_summary.raw_food + carried_summary.raw_food,
    available_wood = storage_summary.wood + carried_summary.wood,
    available_ore = storage_summary.ore + carried_summary.ore,
    available_tools = storage_summary.tools + carried_summary.tools,
    available_forged_tools = storage_summary.forged_tools + carried_summary.forged_tools,
    available_ingots = storage_summary.ingots + carried_summary.ingots,
    available_materials = storage_summary.materials + carried_summary.materials,
  }

  status.bootstrap_stage = working_villages.get_village_bootstrap_stage(status)
  sync_village_registry_status(self.owner_name, status)

  village_status_cache[cache_key] = {
    at = now,
    value = status,
  }

  return status
end

local function count_active_building_sites(center, radius)
  local stats = collect_building_site_stats(center, radius)
  return stats.active_sites
end

local shared_storage_registry_key = "_shared_storages_v2"
local shared_storage_migration_key = "_shared_storages_v2_migration"

local function read_shared_storage_registry()
  local registry = working_villages.get_stored_table(shared_storage_registry_key)
  if type(registry) ~= "table" then
    registry = {}
  end

  -- One-time migration from the historical global record. The marker avoids
  -- resurrecting a legacy chest after its owner intentionally clears it.
  local migration = working_villages.get_stored_table(shared_storage_migration_key)
  if migration.done ~= true then
    local legacy = working_villages.get_stored_table("_shared_storage")
    local legacy_owner = type(legacy) == "table" and legacy.owner_name or nil
    local legacy_pos = type(legacy) == "table" and legacy.pos or nil
    if type(legacy_owner) == "string" and legacy_owner ~= ""
        and type(legacy_pos) == "table" and registry[legacy_owner] == nil then
      registry[legacy_owner] = {pos = vector.round(legacy_pos), owner_name = legacy_owner}
      working_villages.set_stored_table(shared_storage_registry_key, registry)
      working_villages.clear_cached_table(shared_storage_registry_key)
    end
    working_villages.set_stored_table(shared_storage_migration_key, {done = true})
    working_villages.clear_cached_table(shared_storage_migration_key)
  end
  return registry
end

local function write_shared_storage_registry(registry)
  working_villages.set_stored_table(shared_storage_registry_key, registry)
  working_villages.clear_cached_table(shared_storage_registry_key)
end

local function get_shared_storage_record(owner_name)
  local registry = read_shared_storage_registry()
  if type(owner_name) == "string" and owner_name ~= "" then
    return registry[owner_name]
  end

  -- Legacy callers are only unambiguous while a world has one village.
  local only_record = nil
  for _, record in pairs(registry) do
    if only_record ~= nil then
      return nil
    end
    only_record = record
  end
  return only_record
end

local function get_shared_storage_pos(owner_name)
  local data = get_shared_storage_record(owner_name)
  local pos = data and data.pos
  if pos and type(pos) == "table" and pos.x and pos.y and pos.z then
    local recorded_owner = type(data.owner_name) == "string" and data.owner_name or owner_name or ""
    if is_shared_storage_marker_pos(pos, recorded_owner) then
      return vector.round(pos)
    end
  end
  return nil
end

local function get_shared_storage_owner(owner_name)
  local data = get_shared_storage_record(owner_name)
  return data and type(data.owner_name) == "string" and data.owner_name or ""
end

local function refresh_loaded_villager_storage_cache(owner_name, pos)
  for _, lua in pairs(minetest.luaentities or {}) do
    if lua and lua.name and working_villages.is_villager(lua.name)
        and (not owner_name or owner_name == "" or lua.owner_name == owner_name) then
      lua.pos_data = lua.pos_data or {}
      lua.pos_data.storage_pos = pos and vector.round(pos) or nil
    end
  end
end

local village_claim_storage_key = "_village_claims"
local village_claim_enabled = minetest.settings:get_bool("working_villages_enable_village_claim", true)
local village_claim_radius = tonumber(minetest.settings:get("working_villages_claim_radius")) or 12
local village_claim_height = tonumber(minetest.settings:get("working_villages_claim_height")) or 8
local protection_context_runtime = {
  main_key = {},
  stacks = setmetatable({}, {__mode = "k"}),
  unpack_results = table.unpack or unpack,
}

function protection_context_runtime.key()
  local running, is_main = coroutine.running()
  if running == nil or is_main == true then
    return protection_context_runtime.main_key
  end
  return running
end

function protection_context_runtime.normalize_pos(pos)
  if type(pos) ~= "table" or pos.x == nil or pos.y == nil or pos.z == nil then
    return nil
  end
  local ok, rounded = pcall(vector.round, pos)
  if not ok or type(rounded) ~= "table" then
    return nil
  end
  return {x = rounded.x, y = rounded.y, z = rounded.z}
end

function protection_context_runtime.pos_to_string(pos)
  if type(minetest.pos_to_string) == "function" then
    local ok, value = pcall(minetest.pos_to_string, pos)
    if ok then
      return value
    end
  end
  return tostring(pos)
end

function protection_context_runtime.matches_pos(context, pos)
  local rounded = protection_context_runtime.normalize_pos(pos)
  local expected = type(context) == "table" and context.pos or nil
  return rounded ~= nil and expected ~= nil
    and rounded.x == expected.x and rounded.y == expected.y and rounded.z == expected.z
end

function protection_context_runtime.get_stack(key, create)
  local stack = protection_context_runtime.stacks[key]
  if not stack and create then
    stack = {}
    protection_context_runtime.stacks[key] = stack
  end
  return stack
end

function protection_context_runtime.push(kind, pos, owner_name)
  local rounded = protection_context_runtime.normalize_pos(pos)
  if not rounded then
    return nil, "invalid protection context position"
  end
  local key = protection_context_runtime.key()
  local stack = protection_context_runtime.get_stack(key, true)
  local context = {
    kind = kind,
    pos = rounded,
    owner_name = owner_name,
    consumed = false,
  }
  stack[#stack + 1] = context
  return {key = key, context = context}
end

function protection_context_runtime.pop(token)
  local stack = token and protection_context_runtime.stacks[token.key] or nil
  if not stack then
    return false, "protection context stack disappeared"
  end
  if stack[#stack] ~= token.context then
    -- Remove only our own frame. Never clobber a newer nested frame if a
    -- third-party callback returned in an unexpected order.
    for index = #stack, 1, -1 do
      if stack[index] == token.context then
        table.remove(stack, index)
        if #stack == 0 then
          protection_context_runtime.stacks[token.key] = nil
        end
        return false, "protection context stack restored out of order"
      end
    end
    return false, "protection context frame disappeared"
  end
  stack[#stack] = nil
  if #stack == 0 then
    protection_context_runtime.stacks[token.key] = nil
  end
  return true
end

function protection_context_runtime.find(pos)
  local stack = protection_context_runtime.get_stack(protection_context_runtime.key(), false)
  if not stack then
    return nil
  end
  for index = #stack, 1, -1 do
    if protection_context_runtime.matches_pos(stack[index], pos) then
      return stack[index]
    end
  end
  return nil
end

function protection_context_runtime.pack(...)
  return {n = select("#", ...), ...}
end

function protection_context_runtime.call(kind, pos, owner_name, callback, ...)
  if type(callback) ~= "function" then
    return false, "protection context callback is not callable"
  end
  local token, context_error = protection_context_runtime.push(kind, pos, owner_name)
  if not token then
    return false, context_error
  end
  -- LuaJIT permits yielding across pcall. The frame therefore lives on the
  -- calling coroutine's own stack until it resumes, without becoming visible
  -- to another villager or to the engine's main callback.
  local results = protection_context_runtime.pack(pcall(callback, ...))
  local restored, restore_error = protection_context_runtime.pop(token)
  if not restored then
    return false, restore_error
  end
  return protection_context_runtime.unpack_results(results, 1, results.n)
end

function working_villages.with_npc_claim_protection_context(owner_name, pos, callback, ...)
  if type(owner_name) ~= "string" or owner_name == "" then
    return false, "NPC claim protection context requires an owner"
  end
  return protection_context_runtime.call("npc_claim", pos, owner_name, callback, ...)
end

-- Read-only diagnostic used by real-engine regressions. Passing a coroutine
-- allows a test to verify that a completed job did not retain a suspended
-- protection frame.
function working_villages._protection_context_depth(thread)
  local key
  if thread == nil then
    key = protection_context_runtime.key()
  elseif type(thread) == "thread" then
    key = thread
  else
    return 0
  end
  local stack = protection_context_runtime.stacks[key]
  return stack and #stack or 0
end

function working_villages.is_externally_protected(pos, name)
  local current_is_protected = minetest.is_protected
  if type(current_is_protected) ~= "function" then
    return true
  end
  -- Call the current function dynamically so protection wrappers installed
  -- after working_villages are included. The matching external-only frame
  -- tells our own wrapper to omit just the village claim; every other wrapper
  -- still receives the original (anonymous by default) actor name.
  local ok, protected = protection_context_runtime.call(
    "external_only",
    pos,
    nil,
    current_is_protected,
    pos,
    name or ""
  )
  if not ok then
    log.error("external protection check failed closed at %s: %s",
      protection_context_runtime.pos_to_string(pos), tostring(protected))
    return true
  end
  return protected and true or false
end

-- This block (village claims: ownership, allies-via-claim, protection-chain
-- wiring) is wrapped in do/end purely to satisfy Lua's 200-local-per-chunk
-- limit on this file's top level: every name declared inside is verified
-- (by exhaustive grep across the whole file) to be referenced only within
-- this same span, so closing the block here frees those slots for reuse by
-- everything declared later without changing a single call site's syntax.
do

local function player_has_commanding_sceptre_by_name(player_name)
  if not player_name or player_name == "" then
    return false
  end
  local player = minetest.get_player_by_name(player_name)
  if not player then
    return false
  end
  local inv = player:get_inventory()
  return inv and inv:contains_item("main", "working_villages:commanding_sceptre") or false
end

local function get_claim_owner_alias(owner_name)
  if not owner_name or owner_name == "" then
    return nil
  end
  local owner_protection = minetest.settings:get("working_villages_owner_protection")
  local owner_protection_lc = owner_protection and string.lower(owner_protection) or nil
  if not owner_protection or owner_protection_lc == "false" or owner_protection_lc == "true" or owner_protection_lc == "ignore" then
    return nil
  end
  return owner_protection .. ":" .. owner_name
end

local function get_village_claims()
  local claims = working_villages.get_stored_table(village_claim_storage_key)
  if type(claims) ~= "table" then
    return {}
  end
  return claims
end

local function write_village_claims(claims)
  working_villages.set_stored_table(village_claim_storage_key, claims)
  working_villages.clear_cached_table(village_claim_storage_key)
end

local function normalize_village_claim(owner_name, claim)
  if not owner_name or owner_name == "" or type(claim) ~= "table" then
    return nil
  end
  local center = claim.center or claim.pos or claim.storage_pos
  if type(center) ~= "table" or center.x == nil or center.y == nil or center.z == nil then
    return nil
  end
  local storage_pos = claim.storage_pos
  if type(storage_pos) ~= "table" or storage_pos.x == nil or storage_pos.y == nil or storage_pos.z == nil then
    storage_pos = center
  end
  return {
    owner_name = owner_name,
    center = vector.round(center),
    storage_pos = vector.round(storage_pos),
    radius = math.max(1, tonumber(claim.radius) or village_claim_radius),
    height = math.max(1, tonumber(claim.height) or village_claim_height),
    created_at = tonumber(claim.created_at) or minetest.get_gametime(),
  }
end

local function get_owner_village_claim(owner_name)
  local claims = get_village_claims()
  return normalize_village_claim(owner_name, claims[owner_name])
end

local function set_owner_village_claim(owner_name, pos, opts)
  if not village_claim_enabled or not owner_name or owner_name == "" or not pos then
    return nil
  end
  local claims = get_village_claims()
  local previous = normalize_village_claim(owner_name, claims[owner_name])
  local claim = normalize_village_claim(owner_name, {
    center = pos,
    storage_pos = opts and opts.storage_pos or pos,
    radius = opts and opts.radius,
    height = opts and opts.height,
    created_at = previous and previous.created_at or minetest.get_gametime(),
  })
  claims[owner_name] = claim
  write_village_claims(claims)
  return claim
end

local function clear_owner_village_claim(owner_name)
  if not owner_name or owner_name == "" then
    return false
  end
  local claims = get_village_claims()
  if claims[owner_name] == nil then
    return false
  end
  claims[owner_name] = nil
  write_village_claims(claims)
  return true
end

local function is_pos_in_village_claim(pos, claim)
  if not pos or not claim then
    return false
  end
  pos = vector.round(pos)
  local dx = math.abs(pos.x - claim.center.x)
  local dy = math.abs(pos.y - claim.center.y)
  local dz = math.abs(pos.z - claim.center.z)
  return dx <= claim.radius and dz <= claim.radius and dy <= claim.height
end

local function village_claim_allows_name(claim, name)
  if not claim then
    return true
  end
  if name and name ~= "" then
    if name == claim.owner_name then
      return true
    end
    local alias = get_claim_owner_alias(claim.owner_name)
    if alias and name == alias then
      return true
    end
    if working_villages.access and type(working_villages.access.can_manage_owner) == "function" then
      local allowed = working_villages.access.can_manage_owner(claim.owner_name, name)
      if allowed then
        return true
      end
    end
    if minetest.check_player_privs and minetest.check_player_privs(name, {protection_bypass = true}) then
      return true
    end
    if minetest.check_player_privs and minetest.check_player_privs(name, {server = true}) then
      return true
    end
    if claim.owner_name == "working_villages:self_employed"
        and minetest.settings:get_bool("working_villages_self_employed_public", false)
        and player_has_commanding_sceptre_by_name(name) then
      return true
    end
  end
  return false
end

local function get_village_claims_at(pos)
  if not village_claim_enabled or not pos then
    return {}
  end
  local matches = {}
  for owner_name, raw_claim in pairs(get_village_claims()) do
    local claim = normalize_village_claim(owner_name, raw_claim)
    if claim and is_pos_in_village_claim(pos, claim) then
      matches[#matches + 1] = claim
    end
  end
  table.sort(matches, function(left, right)
    return left.owner_name < right.owner_name
  end)
  return matches
end

local function get_village_claim_at(pos)
  return get_village_claims_at(pos)[1]
end

local function village_claims_allow_name(pos, name)
  for _, claim in ipairs(get_village_claims_at(pos)) do
    if not village_claim_allows_name(claim, name) then
      return false, claim
    end
  end
  return true, nil
end

local function infer_shared_storage_owner(pos)
  local best_owner = nil
  local best_distance = nil
  for _, lua in pairs(minetest.luaentities or {}) do
    if lua and lua.name and working_villages.is_villager and working_villages.is_villager(lua.name)
        and lua.object and lua.object.get_pos then
      local owner_name = lua.owner_name or ""
      local villager_pos = lua.object:get_pos()
      if owner_name ~= "" and villager_pos then
        local distance = vector.distance(villager_pos, pos)
        if distance <= 24 and (not best_distance or distance < best_distance) then
          best_owner = owner_name
          best_distance = distance
        end
      end
    end
  end
  return best_owner
end

local function sync_registry_shared_storage(owner_name, pos)
  if not village_registry or not owner_name or owner_name == "" then
    return
  end
  local village, registry_error
  if pos then
    village, registry_error = village_registry.ensure(owner_name, {
      center = vector.round(pos),
      radius = math.max(16,
        tonumber(minetest.settings:get("working_villages_population_radius")) or 64),
    })
  else
    village, registry_error = village_registry.get(owner_name)
  end
  if not village then
    if pos then
      log.warning("Shared storage village registry sync failed for %s: %s", owner_name, tostring(registry_error))
    end
    return
  end
  local patch = {chests = {}}
  if pos then
    patch.center = vector.round(pos)
    patch.chests.primary = {
      id = "primary",
      kind = "shared",
      pos = vector.round(pos),
    }
  end
  local updated, update_error = village_registry.update(owner_name, patch)
  if not updated then
    log.warning("Shared storage village registry update failed for %s: %s", owner_name, tostring(update_error))
  end
end

local function player_can_use_storage_node(pos, player)
  if not player or not player.is_player or not player:is_player() then
    return false
  end
  local player_name = player:get_player_name()
  if not player_name or player_name == "" or minetest.is_protected(pos, player_name) then
    return false
  end
  local node = minetest.get_node(pos)
  local node_def = minetest.registered_nodes[node.name]
  local inv = get_chest_inventory(pos)
  if not node_def or not inv or inv:get_size("main") <= 0 then
    return false
  end

  local meta = minetest.get_meta(pos)
  local privileged = minetest.check_player_privs and (
    minetest.check_player_privs(player_name, {protection_bypass = true})
    or minetest.check_player_privs(player_name, {server = true})
  )
  for _, key in ipairs({"owner", "owner_name", "locked_by", "player_name"}) do
    local recorded_owner = meta:get_string(key)
    if recorded_owner ~= "" and recorded_owner ~= player_name and not privileged then
      return false
    end
  end

  -- Honour container-specific access callbacks before the mod starts using
  -- the inventory directly. A harmless probe is checked but never inserted.
  local probe_name = working_villages.compat.get_item("default:stick")
  local probe = ItemStack(probe_name .. " 1")
  if probe:is_empty() then
    return false
  end
  if type(node_def.allow_metadata_inventory_put) == "function" then
    local ok, allowed = pcall(
      node_def.allow_metadata_inventory_put,
      pos,
      "main",
      1,
      probe,
      player
    )
    if not ok or (tonumber(allowed) or 0) < 1 then
      return false
    end
  end
  for index = 1, inv:get_size("main") do
    local stack = inv:get_stack("main", index)
    if not stack:is_empty() and type(node_def.allow_metadata_inventory_take) == "function" then
      local ok, allowed = pcall(
        node_def.allow_metadata_inventory_take,
        pos,
        "main",
        index,
        stack,
        player
      )
      if not ok or (tonumber(allowed) or 0) < 1 then
        return false
      end
      break
    end
  end
  return true
end

local function villager_can_register_new_storage(pos, owner_name, villager)
  if not villager or villager.owner_name ~= owner_name or not villager.object
      or type(villager.object.get_pos) ~= "function" then
    return false
  end
  local villager_pos = villager.object:get_pos()
  if not villager_pos or vector.distance(villager_pos, pos) > 6 then
    return false
  end
  local placement = villager._last_placed_node
  if type(placement) ~= "table" or type(placement.pos) ~= "table"
      or minetest.hash_node_position(vector.round(placement.pos)) ~= minetest.hash_node_position(pos)
      or placement.node_name ~= minetest.get_node(pos).name then
    return false
  end
  if type(minetest.get_us_time) == "function" then
    local placed_at = tonumber(placement.at_us)
    if not placed_at or minetest.get_us_time() - placed_at > 5000000 then
      return false
    end
  end
  return not minetest.is_protected(pos, owner_name)
end

local function set_shared_storage_pos(pos, owner_name, authority)
  if not pos then
    return false
  end
  pos = vector.round(pos)
  if not is_chest_pos(pos) then
    return false
  end
  owner_name = type(owner_name) == "string" and owner_name or ""
  if owner_name == "" then
    owner_name = infer_shared_storage_owner(pos) or ""
  end
  if owner_name == "" then
    return false
  end

  local authority_ok
  if authority and authority.is_player and authority:is_player() then
    authority_ok = authority:get_player_name() == owner_name
      and player_can_use_storage_node(pos, authority)
  else
    authority_ok = villager_can_register_new_storage(pos, owner_name, authority)
  end
  if not authority_ok then
    return false
  end

  local marked_owner = get_shared_storage_owner_marker(pos)
  if marked_owner ~= "" and marked_owner ~= owner_name then
    return false
  end

  local registry = read_shared_storage_registry()
  local current = registry[owner_name] or {}
  local previous_pos = type(current.pos) == "table" and current.pos or nil
  if previous_pos and minetest.hash_node_position(previous_pos) ~= minetest.hash_node_position(pos) then
    clear_shared_storage_marker(previous_pos, owner_name)
  end
  registry[owner_name] = {
    pos = pos,
    owner_name = owner_name,
  }
  write_shared_storage_registry(registry)
  shared_storage_summary_cache = {}
  refresh_loaded_villager_storage_cache(owner_name, pos)
  mark_shared_storage_pos(pos, owner_name)
  set_owner_village_claim(owner_name, pos, {storage_pos = pos})
  sync_registry_shared_storage(owner_name, pos)
  if authority and not (authority.is_player and authority:is_player()) then
    authority._last_placed_node = nil
  end
  local message = "[working_villages] Coffre partage defini a " .. minetest.pos_to_string(pos, 0)
  if village_claim_enabled then
    message = message .. " ; claim du village actif"
  end
  minetest.chat_send_all(message)
  return true
end

local function clear_shared_storage_pos(owner_name)
  owner_name = type(owner_name) == "string" and owner_name or ""
  if owner_name == "" then
    owner_name = get_shared_storage_owner()
  end
  if owner_name == "" then
    return false
  end
  local registry = read_shared_storage_registry()
  local current = registry[owner_name]
  if type(current) ~= "table" then
    return false
  end
  local current_pos = type(current.pos) == "table" and current.pos or nil
  registry[owner_name] = nil
  write_shared_storage_registry(registry)
  shared_storage_summary_cache = {}
  refresh_loaded_villager_storage_cache(owner_name, nil)
  if current_pos then
    clear_shared_storage_marker(current_pos, owner_name)
  end
  clear_owner_village_claim(owner_name)
  sync_registry_shared_storage(owner_name, nil)
  local message = "[working_villages] Coffre partage reinitialise."
  if village_claim_enabled then
    message = message .. " Claim retire."
  end
  minetest.chat_send_all(message)
  return true
end

working_villages.get_shared_storage_pos = get_shared_storage_pos
working_villages.get_shared_storage_owner = get_shared_storage_owner
working_villages.set_shared_storage_pos = set_shared_storage_pos
working_villages.clear_shared_storage_pos = clear_shared_storage_pos
working_villages.is_chest_pos = is_chest_pos
working_villages.get_owner_village_claim = get_owner_village_claim
working_villages.set_owner_village_claim = set_owner_village_claim
working_villages.clear_owner_village_claim = clear_owner_village_claim
working_villages.get_village_claim_at = get_village_claim_at
working_villages.get_village_claims_at = get_village_claims_at
working_villages.village_claims_allow_name = village_claims_allow_name

minetest.register_on_mods_loaded(function()
  for owner_name, record in pairs(read_shared_storage_registry()) do
    local pos = type(record) == "table" and record.pos or nil
    if pos and is_shared_storage_marker_pos(pos, owner_name) then
      sync_registry_shared_storage(owner_name, pos)
    end
  end
  if working_villages._claim_protection_installed or not village_claim_enabled then
    return
  end
  local base_is_protected = minetest.is_protected
  if type(base_is_protected) ~= "function" then
    return
  end
  working_villages._claim_protection_installed = true
  -- luacheck: ignore 122 -- intentional protection-chain wrapper
  minetest.is_protected = function(pos, name)
    local context = protection_context_runtime.find(pos)
    local external_only = context and context.kind == "external_only" or false
    local claim_context_owner = nil
    if context and context.kind == "npc_claim"
        and not context.consumed and (name == nil or name == "") then
      -- Consume before entering third-party protection code. Re-entrant or
      -- post-dig checks can therefore never reuse the owner's claim identity.
      context.consumed = true
      claim_context_owner = context.owner_name
    end

    local external_ok, externally_protected = pcall(base_is_protected, pos, name or "")
    if not external_ok then
      log.error("base protection check failed closed at %s: %s",
        protection_context_runtime.pos_to_string(pos), tostring(externally_protected))
      return true
    end
    if externally_protected then
      return true
    end
    if external_only then
      return false
    end

    local claim_name = name
    if (not claim_name or claim_name == "")
        and claim_context_owner and claim_context_owner ~= "" then
      -- Only the working_villages claim sees the NPC owner. Third-party
      -- protection above already received the original anonymous name.
      claim_name = claim_context_owner
    end
    local allowed = village_claims_allow_name(pos, claim_name)
    if not allowed then
      return true
    end
    return false
  end
end)

end -- closes the village-claims do-block opened above player_has_commanding_sceptre_by_name

get_shared_storage_chests = function(base_pos)
  if not is_chest_pos(base_pos) then
    return {}
  end

  local owner_name = get_shared_storage_owner_marker(base_pos)
  if owner_name == "" then
    return {vector.round(base_pos)}
  end

  local minp = vector.subtract(base_pos, 6)
  local maxp = vector.add(base_pos, 6)
  local candidates = {}
  local seen = {}

  local function add_candidate(pos)
    if not is_chest_pos(pos) then
      return
    end
    local rounded = vector.round(pos)
    local hash = minetest.hash_node_position(rounded)
    if seen[hash] then
      return
    end
    seen[hash] = true
    candidates[#candidates + 1] = rounded
  end

  add_candidate(base_pos)
  for _, pos in ipairs(find_chests_in_area(minp, maxp)) do
    if is_shared_storage_marker_pos(pos, owner_name) then
      add_candidate(pos)
    end
  end

  if #candidates == 0 then
    add_candidate(base_pos)
  end

  return candidates
end

local function find_shared_storage_chest_for_item(base_pos, itemname, for_put, holder)
  if not is_chest_pos(base_pos) then
    return nil
  end
  local candidates = get_shared_storage_chests(base_pos)
  if #candidates == 0 then
    return base_pos
  end

  local best_empty = nil
  local fallback = nil
  local best_room = -1
  local probe = ItemStack(itemname .. " 1")
  for _, pos in ipairs(candidates) do
		local reserved = working_villages.is_pos_reserved("shared_storage_chest", pos, holder)
    if not reserved then
      local inv = get_chest_inventory(pos)
      if inv then
        fallback = fallback or pos
        if inv:contains_item("main", probe) then
          return pos
        end
        if for_put and inv:room_for_item("main", probe) then
          local size = inv:get_size("main")
          local empty = 0
          for i = 1, size do
            if inv:get_stack("main", i):is_empty() then
              empty = empty + 1
            end
          end
          if empty > best_room then
            best_room = empty
            best_empty = pos
          end
        end
      end
    end
  end

  if for_put then
    return best_empty or fallback
  end
  return fallback
end

local villager_name_first = {
  "Alex","Bastien","Cedric","Daniel","Emile","Fabien","Gaspard","Hugo","Ivan","Julien",
  "Kevin","Louis","Marc","Nicolas","Oscar","Paul","Quentin","Rene","Simon","Theo",
  "Arthur","Bruno","Clement","Diego","Elias","Florian","Gilles","Henri","Isaac","Jules",
}

local villager_name_last = {
  "Martin","Bernard","Dubois","Thomas","Robert","Richard","Petit","Durand","Leroy","Moreau",
  "Simon","Laurent","Michel","Lefevre","Garcia","Roux","Fournier","Girard","Andre","Lambert",
  "Bonnet","Francois","Mercier","Blanc","Guerin","Boyer","Garnier","Chevalier","Perrin","Renaud",
}

local function random_villager_name()
  local first = villager_name_first[math.random(#villager_name_first)]
  local last = villager_name_last[math.random(#villager_name_last)]
  if first and last then
    return first .. " " .. last
  end
  return "Villager"
end

--[[
  Gets the detached inventory for this villager.

  The inventory contains:
  - "main" list: General storage (16 slots)
  - "job" list: Current job item (1 slot)

  @return InvRef - The villager's inventory
  @usage local inv = self:get_inventory()
]]--
function working_villages.villager:get_inventory()
  return minetest.get_inventory {
    type = "detached",
    name = self.inventory_name,
  }
end

function working_villages.villager:get_inventory_name()
  return self.inventory_name
end

function working_villages.villager:reserve_position(scope, pos, ttl)
  return working_villages.reserve_pos(scope, pos, self.inventory_name, ttl)
end

function working_villages.villager:is_position_reserved(scope, pos)
  return working_villages.is_pos_reserved(scope, pos, self.inventory_name)
end

function working_villages.villager:release_reserved_position(scope, pos)
  return working_villages.release_pos(scope, pos, self.inventory_name)
end

function working_villages.villager:ensure_shared_storage_pos()
  self.pos_data = self.pos_data or {}

  local village_pos = get_shared_storage_pos(self.owner_name)
  if is_chest_pos(village_pos) then
    self.pos_data.storage_pos = vector.round(village_pos)
    return self.pos_data.storage_pos
  end

  if is_shared_storage_marker_pos(self.pos_data.storage_pos, self.owner_name) then
    return self.pos_data.storage_pos
  end

  return nil
end

function working_villages.villager:get_shared_storage_chest_for_item(itemname, for_put)
  local base_pos = self:ensure_shared_storage_pos()
  if not is_chest_pos(base_pos) then
    return nil
  end
	return find_shared_storage_chest_for_item(base_pos, itemname, for_put, self.inventory_name)
end

function working_villages.villager:get_shared_storage_chests()
  local base_pos = self:ensure_shared_storage_pos()
  if not is_chest_pos(base_pos) then
    return {}
  end
  return get_shared_storage_chests(base_pos)
end

function working_villages.villager:take_from_shared_storage(req)
  if not req then
    return false
  end
  local base_pos = self:ensure_shared_storage_pos()
  if not is_chest_pos(base_pos) then
    return false
  end
  local inv = self:get_inventory()
  local took_any = false
  local moved_counts = {}
  local all_satisfied = true
  local chests = self:get_shared_storage_chests()
  if #chests == 0 then
    chests = {base_pos}
  end

  for name, count in pairs(req) do
    local need = math.max(0, tonumber(count) or 0)
    if need > 0 then
      for _, storage_pos in ipairs(chests) do
        if need <= 0 then
          break
        end
        if self:reserve_position("shared_storage_chest", storage_pos, 2) then
          local chest_inv = get_chest_inventory(storage_pos)
          if chest_inv then
            local size = chest_inv:get_size("main")
            for i = 1, size do
              if need <= 0 then
                break
              end
              local stack = chest_inv:get_stack("main", i)
              if stack:get_name() == name and not stack:is_empty() then
                local take_count = math.min(need, stack:get_count())
                local moved = inventory_access.take_to_inventory(
                  self, storage_pos, "main", i, inv, "main", take_count)
                if moved > 0 then
                  need = need - moved
                  moved_counts[name] = (moved_counts[name] or 0) + moved
                  took_any = true
                end
              end
            end
          end
          self:release_reserved_position("shared_storage_chest", storage_pos)
        end
      end
      if need > 0 then
        all_satisfied = false
      end
    end
  end

  return took_any, moved_counts, all_satisfied
end

function working_villages.villager:take_tool_from_shared_storage(tool_group)
  local base_pos = self:ensure_shared_storage_pos()
  if not is_chest_pos(base_pos) then
    return false
  end
  local chests = self:get_shared_storage_chests()
  if #chests == 0 then
    chests = {base_pos}
  end

  local inv = self:get_inventory()
  for _, pos in ipairs(chests) do
    if self:reserve_position("shared_storage_chest", pos, 2) then
      local chest_inv = get_chest_inventory(pos)
      if chest_inv then
        local size = chest_inv:get_size("main")
        for i = 1, size do
          local stack = chest_inv:get_stack("main", i)
          if not stack:is_empty() and minetest.get_item_group(stack:get_name(), tool_group) > 0 then
            local moved = inventory_access.take_to_inventory(
              self, pos, "main", i, inv, "main", 1)
            if moved > 0 then
              self:release_reserved_position("shared_storage_chest", pos)
              return true
            end
          end
        end
      end
      self:release_reserved_position("shared_storage_chest", pos)
    end
  end

  return false
end

function working_villages.villager:take_from_shared_storage_by_predicate(predicate, max_count)
  if type(predicate) ~= "function" then
    return false
  end
  local base_pos = self:ensure_shared_storage_pos()
  if not is_chest_pos(base_pos) then
    return false
  end
  local chests = self:get_shared_storage_chests()
  if #chests == 0 then
    chests = {base_pos}
  end

  local inv = self:get_inventory()
  local remaining = max_count or 1
  local took_any = false
  local moved_count = 0
  for _, pos in ipairs(chests) do
    if self:reserve_position("shared_storage_chest", pos, 2) then
      local chest_inv = get_chest_inventory(pos)
      if chest_inv then
        local size = chest_inv:get_size("main")
        for i = 1, size do
          if remaining <= 0 then
            self:release_reserved_position("shared_storage_chest", pos)
            return took_any, moved_count, true
          end
          local stack = chest_inv:get_stack("main", i)
          if not stack:is_empty() and predicate(stack:get_name()) then
            local take_count = math.min(remaining, stack:get_count())
            local moved = inventory_access.take_to_inventory(
              self, pos, "main", i, inv, "main", take_count)
            if moved > 0 then
              remaining = remaining - moved
              moved_count = moved_count + moved
              took_any = true
            end
          end
        end
      end
      self:release_reserved_position("shared_storage_chest", pos)
    end
  end

  return took_any, moved_count, remaining <= 0
end

local physical_delivery_coordination = {
  wait_navigation_key = "resource_delivery_wait",
  wait_reach = 0.85,
  wait_ttl = 5,
  delivery_wait_ttl = 120,
  stock_retry_limit = 4,
  stock_retry_base = 5,
  stock_retry_max = 30,
}

-- Persist durations, never absolute get_gametime() deadlines. Luanti resets
-- get_gametime() when the server starts, so an absolute value saved late in a
-- previous session can otherwise postpone a retry for hours after a restart.
function physical_delivery_coordination.advance_relative_timer(holder, remaining_key, clock_key)
  if type(holder) ~= "table" then
    return 0
  end
  local remaining = math.max(0, tonumber(holder[remaining_key]) or 0)
  local now = math.max(0, tonumber(minetest.get_gametime()) or 0)
  local previous = tonumber(holder[clock_key])
  if previous and now >= previous then
    remaining = math.max(0, remaining - (now - previous))
  end
  if remaining > 0 then
    holder[remaining_key] = remaining
    holder[clock_key] = now
  else
    holder[remaining_key] = nil
    holder[clock_key] = nil
  end
  return remaining
end

function physical_delivery_coordination.touch_delivery_elapsed(state)
  if type(state) ~= "table" then
    return 0
  end
  local now = math.max(0, tonumber(minetest.get_gametime()) or 0)
  local previous = tonumber(state.elapsed_clock)
  local elapsed = math.max(0, tonumber(state.elapsed) or 0)
  if previous and now >= previous then
    elapsed = elapsed + (now - previous)
  elseif not previous then
    local started_at = tonumber(state.started_at)
    if started_at and now >= started_at then
      elapsed = elapsed + (now - started_at)
    end
  end
  state.elapsed = elapsed
  state.elapsed_clock = now
  return elapsed
end

local function add_delivery_counts(target, source)
  for item_name, count in pairs(source or {}) do
    count = math.max(0, math.floor(tonumber(count) or 0))
    if type(item_name) == "string" and item_name ~= "" and count > 0 then
      target[item_name] = (target[item_name] or 0) + count
    end
  end
  return target
end

-- Credit the collaborative ledger from quantities that have already moved.
-- This is usable both by a loaded requester after a direct hand-off and by a
-- supplier after depositing into shared storage for an unloaded requester.
function physical_delivery_coordination.record_task_progress(
    self, task_id, requester_id, delivered)
  local collab = working_villages.collaborative_tasks
  local record = collab and task_id and collab.get and collab.get(task_id) or nil
  if not record or record.state ~= "active"
      or record.owner_name ~= (self.owner_name or "")
      or record.initiator ~= requester_id then
    return false, false
  end

  local contributor_id = tostring(self.inventory_name or "")
  local contributor_allowed = contributor_id == record.initiator
  for _, participant_id in ipairs(record.participants or {}) do
    if participant_id == contributor_id then
      contributor_allowed = true
      break
    end
  end
  if not contributor_allowed then
    return false, false
  end

  local data = type(record.data) == "table" and record.data or {}
  local progress = type(data.delivery_progress) == "table"
    and data.delivery_progress or {}
  progress.items = type(progress.items) == "table" and progress.items or {}
  progress.tools = type(progress.tools) == "table" and progress.tools or {}
  add_delivery_counts(progress.items, delivered and delivered.items or {})
  progress.food = (tonumber(progress.food) or 0)
    + math.max(0, math.floor(tonumber(delivered and delivered.food) or 0))
  local tool_group = delivered and delivered.tool_group or nil
  local tool_count = math.max(0,
    math.floor(tonumber(delivered and delivered.tools) or 0))
  if type(tool_group) == "string" and tool_group ~= "" and tool_count > 0 then
    progress.tools[tool_group] = (tonumber(progress.tools[tool_group]) or 0) + tool_count
  end
  data.delivery_progress = progress

  local complete = false
  if record.name == "resource_delivery" and type(data.items) == "table"
      and next(data.items) ~= nil then
    complete = true
    for item_name, count in pairs(data.items) do
      if (progress.items[item_name] or 0) < math.max(0, tonumber(count) or 0) then
        complete = false
        break
      end
    end
  elseif record.name == "food_support" and data.resource == "food" then
    complete = progress.food >= math.max(1, tonumber(data.count) or 1)
  elseif record.name == "mining_tool_supply" then
    local requested_group = data.tool_group or "pickaxe"
    complete = (progress.tools[requested_group] or 0) >= 1
  end

  local updated = collab.update and collab.update(record.id, {data = data})
  if not updated then
    return false, false
  end
  if complete and collab.complete then
    collab.complete(record.id, {
      delivered_items = progress.items,
      delivered_tools = progress.tools,
      delivered_food = progress.food,
    })
  end
  return true, complete
end

function physical_delivery_coordination.normalize_items(requested)
  local normalized = {}
  local names = {}
  for item_name, count in pairs(requested or {}) do
    count = math.max(0, math.floor(tonumber(count) or 0))
    if type(item_name) == "string" and item_name ~= "" and count > 0 then
      normalized[item_name] = count
      names[#names + 1] = item_name
    end
  end
  table.sort(names)
  return normalized, names
end

function physical_delivery_coordination.count_inventory_item(inv, item_name)
  local total = 0
  local size = inv and inv:get_size("main") or 0
  for index = 1, size do
    local stack = inv:get_stack("main", index)
    if not stack:is_empty() and stack:get_name() == item_name then
      total = total + stack:get_count()
    end
  end
  return total
end

function physical_delivery_coordination.count_inventory_matching(inv, predicate)
  local total = 0
  local size = inv and inv:get_size("main") or 0
  for index = 1, size do
    local stack = inv:get_stack("main", index)
    if not stack:is_empty() and predicate(stack) then
      total = total + stack:get_count()
    end
  end
  return total
end

-- Craft before pathfinding, then re-read the real inventory. A recipe probe is
-- not treated as stock: at least one requested unit must physically exist in
-- the supplier inventory before a delivery state or navigation is started.
function physical_delivery_coordination.prepare_requested_items(self, requested)
  local normalized, names = physical_delivery_coordination.normalize_items(requested)
  local inv = self:get_inventory()
  local crafting = working_villages.crafting
  if crafting then
    for _, item_name in ipairs(names) do
      local requested_count = normalized[item_name]
      if physical_delivery_coordination.count_inventory_item(inv, item_name) < requested_count then
        crafting.ensure_item(self, item_name, requested_count, {
          use_shared_storage = true,
          skip_storage_for = {[item_name] = true},
          fail_cooldown = 5,
          max_depth = 4,
        })
      end
    end
  end

  local available = 0
  for _, item_name in ipairs(names) do
    available = available + math.min(
      normalized[item_name], physical_delivery_coordination.count_inventory_item(inv, item_name))
  end
  return normalized, names, available
end

local function transfer_requested_items(self, requester, base_pos, use_shared_storage, requested)
  local inv = self:get_inventory()
  local moved_items = {}
  local normalized, names = physical_delivery_coordination.normalize_items(requested)
  for _, name in ipairs(names) do
    local requested_count = normalized[name]
    local need = math.max(0, math.floor(tonumber(requested_count) or 0))
    local size = inv:get_size("main")
    for i = 1, size do
      if need <= 0 then
        break
      end
      local stack = inv:get_stack("main", i)
      if stack:get_name() == name and not stack:is_empty() then
        local take_count = math.min(need, stack:get_count())
        local moved = 0
        if use_shared_storage then
          local storage_pos = find_shared_storage_chest_for_item(
            base_pos, name, true, self.inventory_name)
          if storage_pos and self:reserve_position("shared_storage_chest", storage_pos, 2) then
            moved = inventory_access.put_from_inventory(
              self, inv, "main", i, storage_pos, "main", nil, take_count)
            self:release_reserved_position("shared_storage_chest", storage_pos)
          end
        elseif requester and requester ~= self then
          local taken = stack:take_item(take_count)
          local leftover = requester:add_item_to_main(taken)
          moved = take_count - leftover:get_count()
          if not leftover:is_empty() then
            stack:add_item(leftover)
          end
          inv:set_stack("main", i, stack)
        end
        if moved > 0 then
          moved_items[name] = (moved_items[name] or 0) + moved
          need = need - moved
        end
      end
    end
  end
  return moved_items
end

local function transfer_food_items(self, requester, base_pos, use_shared_storage, requested_count)
  local inv = self:get_inventory()
  local remaining = math.max(0, math.floor(tonumber(requested_count) or 0))
  local moved_total = 0
  local size = inv:get_size("main")
  for i = 1, size do
    if remaining <= 0 then
      break
    end
    local stack = inv:get_stack("main", i)
    if not stack:is_empty() and is_food_item(stack:get_name()) then
      local take_count = math.min(remaining, stack:get_count())
      local moved = 0
      if use_shared_storage then
        local storage_pos = find_shared_storage_chest_for_item(
          base_pos, stack:get_name(), true, self.inventory_name)
        if storage_pos and self:reserve_position("shared_storage_chest", storage_pos, 2) then
          moved = inventory_access.put_from_inventory(
            self, inv, "main", i, storage_pos, "main", nil, take_count)
          self:release_reserved_position("shared_storage_chest", storage_pos)
        end
      elseif requester and requester ~= self then
        local taken = stack:take_item(take_count)
        local leftover = requester:add_item_to_main(taken)
        moved = take_count - leftover:get_count()
        if not leftover:is_empty() then
          stack:add_item(leftover)
        end
        inv:set_stack("main", i, stack)
      end
      if moved > 0 then
        remaining = remaining - moved
        moved_total = moved_total + moved
      end
    end
  end
  return moved_total
end

local PHYSICAL_DELIVERY_NAVIGATION_KEY = "resource_delivery"
local PHYSICAL_DELIVERY_REACH = 2.25
local finish_physical_delivery

local function copy_delivery_payload(data)
  local payload = {}
  for key, value in pairs(data or {}) do
    payload[key] = value
  end
  return payload
end

local function valid_delivery_target(pos)
  return type(pos) == "table" and tonumber(pos.x) ~= nil
    and tonumber(pos.y) ~= nil and tonumber(pos.z) ~= nil
end

function physical_delivery_coordination.message_key(self, msg)
  local data = msg and msg.data or {}
  local existing = msg and msg.delivery_id
  if type(existing) == "string" and existing ~= "" then
    return existing
  end
  return table.concat({
    "delivery",
    tostring(tonumber(msg and msg.time) or 0),
    tostring(data.task_id or "direct"),
    tostring(msg and msg.from or "unknown"),
    tostring(self and self.inventory_name or "unknown"),
    tostring(data.requester_id or "storage"),
  }, "|")
end

function physical_delivery_coordination.priority(self, msg)
  local data = msg and msg.data or {}
  local timestamp = math.max(0, tonumber(msg and msg.time) or 0)
  return string.format("%012d|%s|%s|%s", math.floor(timestamp),
    tostring(data.task_id or "direct"),
    tostring(self and self.inventory_name or "unknown"),
    tostring(data.requester_id or "storage"))
end

function physical_delivery_coordination.clear_incoming(self, state)
  if type(state) ~= "table" or type(state.delivery_key) ~= "string"
      or type(state.requester_id) ~= "string" then
    return
  end
  local comm = working_villages.communication
  local requester = comm and comm.find_villager_by_inventory_name
    and comm.find_villager_by_inventory_name(state.requester_id) or nil
  local incoming = requester and requester.job_data
    and requester.job_data.physical_delivery_incoming or nil
  if type(incoming) == "table" then
    incoming[state.delivery_key] = nil
    if next(incoming) == nil then
      requester.job_data.physical_delivery_incoming = nil
    end
  end
end

function physical_delivery_coordination.register_incoming(self, requester, state)
  if not requester or requester == self or type(state) ~= "table"
      or not valid_delivery_target(state.rendezvous_pos) then
    return
  end
  requester.job_data = requester.job_data or {}
  local incoming = type(requester.job_data.physical_delivery_incoming) == "table"
    and requester.job_data.physical_delivery_incoming or {}
  requester.job_data.physical_delivery_incoming = incoming
  local entry = type(incoming[state.delivery_key]) == "table"
    and incoming[state.delivery_key] or {}
  entry.delivery_key = state.delivery_key
  entry.priority = state.priority
  entry.bootstrap_infrastructure = state.bootstrap_infrastructure == true
  entry.order = physical_delivery_coordination.normalize_order(
    state.order or (tostring(state.priority) .. "|" .. tostring(state.delivery_key)),
    entry.bootstrap_infrastructure)
  entry.supplier_id = self.inventory_name
  entry.requester_id = requester.inventory_name
  entry.task_id = state.task_id
  entry.rendezvous_pos = vector.round(state.rendezvous_pos)
  -- A remaining duration, rather than an absolute game-time deadline, survives
  -- a server restart without depending on the new get_gametime() origin.
  entry.remaining = physical_delivery_coordination.wait_ttl
  incoming[state.delivery_key] = entry
end

local function restore_unprocessed_messages(self, messages, first_index)
  if not messages or first_index > #messages then
    return
  end
  self.job_data = self.job_data or {}
  local inbox = type(self.job_data.inbox) == "table" and self.job_data.inbox or {}
  for index = #messages, first_index, -1 do
    table.insert(inbox, 1, messages[index])
  end
  self.job_data.inbox = inbox
end

local function begin_physical_delivery(self, msg, target_pos, target_kind)
  self.job_data = self.job_data or {}
  self.job_data.pending_resource_message = msg
  local state = self.job_data.physical_delivery_state
  local delivery_key = physical_delivery_coordination.message_key(self, msg)
  if type(state) == "table" and type(state.delivery_key) == "string"
      and state.delivery_key ~= delivery_key then
    physical_delivery_coordination.clear_incoming(self, state)
    if self.cancel_go_to_step then
      self:cancel_go_to_step(PHYSICAL_DELIVERY_NAVIGATION_KEY, true)
    end
    state = nil
  end
  if type(state) ~= "table" then
    local current = self.object and self.object:get_pos() or nil
    state = {
      started_at = minetest.get_gametime(),
      elapsed = 0,
      elapsed_clock = minetest.get_gametime(),
      start_pos = current and vector.new(current) or nil,
      last_pos = current and vector.new(current) or nil,
      travelled = 0,
      task_id = msg and msg.data and msg.data.task_id or nil,
      delivery_key = delivery_key,
      priority = physical_delivery_coordination.priority(self, msg),
      requester_id = msg and msg.data and msg.data.requester_id or nil,
      bootstrap_infrastructure = msg and msg.data
        and msg.data.bootstrap_infrastructure == true or false,
    }
    self.job_data.physical_delivery_state = state
  end
  -- Migrate deliveries saved by the first physical-delivery implementation.
  state.delivery_key = state.delivery_key or delivery_key
  state.priority = state.priority or physical_delivery_coordination.priority(self, msg)
  state.bootstrap_infrastructure = msg and msg.data
    and msg.data.bootstrap_infrastructure == true or false
  -- Recompute the order from the message to migrate legacy states which did
  -- not carry an infrastructure-priority prefix.
  state.order = physical_delivery_coordination.message_order(self, msg)
  state.requester_id = state.requester_id
    or (msg and msg.data and msg.data.requester_id or nil)
  if valid_delivery_target(target_pos) then
    state.target_pos = vector.round(target_pos)
    if target_kind == "shared_storage" or not valid_delivery_target(state.rendezvous_pos) then
      state.rendezvous_pos = vector.round(target_pos)
    end
  end
  state.target_kind = target_kind
  local current = self.object and self.object:get_pos() or nil
  if current and state.last_pos then
    state.travelled = (tonumber(state.travelled) or 0) + vector.distance(current, state.last_pos)
  end
  state.last_pos = current and vector.new(current) or state.last_pos
  physical_delivery_coordination.touch_delivery_elapsed(state)
  return state
end

local function physical_delivery_task_is_active(msg)
  local task_id = msg and msg.data and msg.data.task_id or nil
  if not task_id then
    return true
  end
  local collab = working_villages.collaborative_tasks
  local record = collab and collab.get and collab.get(task_id) or nil
  return record ~= nil and record.state == "active"
end

function physical_delivery_coordination.supply_retry_waiting(msg)
  local retry = msg and msg.supply_retry or nil
  if type(retry) ~= "table" or tonumber(retry.remaining) == nil then
    return false
  end
  return physical_delivery_coordination.advance_relative_timer(
    retry, "remaining", "clock") > 0
end

function physical_delivery_coordination.requeue_supply_retry(self, msg, reason)
  if not msg or not physical_delivery_task_is_active(msg) then
    return false
  end
  local retry = type(msg.supply_retry) == "table" and msg.supply_retry or {}
  retry.attempts = math.max(0, math.floor(tonumber(retry.attempts) or 0)) + 1
  msg.supply_retry = retry
  if retry.attempts > physical_delivery_coordination.stock_retry_limit then
    local task_id = msg.data and msg.data.task_id or nil
    local collab = working_villages.collaborative_tasks
    local record = task_id and collab and collab.get and collab.get(task_id) or nil
    if record and record.state == "active" and collab.fail then
      collab.fail(task_id, "Ressources indisponibles apres plusieurs tentatives")
    end
    return false
  end

  retry.reason = reason or "no_deliverable_stock"
  retry.remaining = math.min(
    physical_delivery_coordination.stock_retry_max,
    physical_delivery_coordination.stock_retry_base * (2 ^ (retry.attempts - 1)))
  retry.clock = math.max(0, tonumber(minetest.get_gametime()) or 0)
  self.job_data = self.job_data or {}
  local inbox = type(self.job_data.inbox) == "table" and self.job_data.inbox or {}
  for _, queued in ipairs(inbox) do
    if queued == msg then
      self.job_data.inbox = inbox
      return true
    end
  end
  inbox[#inbox + 1] = msg
  self.job_data.inbox = inbox
  return true
end

local function defer_physical_delivery(self, msg, reason)
  local state = begin_physical_delivery(self, msg, nil, "unavailable")
  if not physical_delivery_task_is_active(msg)
      or (tonumber(state.elapsed) or 0) >= physical_delivery_coordination.delivery_wait_ttl then
    finish_physical_delivery(self, false, {reason = reason or "target_unavailable"}, msg)
    return false
  end
  state.wait_reason = reason or "target_unavailable"
  if self.cancel_go_to_step then
    self:cancel_go_to_step(PHYSICAL_DELIVERY_NAVIGATION_KEY, true)
  end
  self:set_displayed_action("livraison en attente")
  self:set_state_info("Je garde la cargaison jusqu'au retour du destinataire ou du coffre commun.")
  return true
end

local function retry_or_fail_physical_delivery(self, msg, state, reason)
  state.failures = math.max(0, math.floor(tonumber(state.failures) or 0)) + 1
  state.retry_remaining = math.min(30, state.failures * 5)
  state.retry_clock = math.max(0, tonumber(minetest.get_gametime()) or 0)
  state.retry_at = nil
  state.wait_reason = reason or "no_path"
  if self.cancel_go_to_step then
    self:cancel_go_to_step(PHYSICAL_DELIVERY_NAVIGATION_KEY, true)
  end
  if state.failures < 3 then
    self:set_displayed_action("cherche un autre chemin")
    self:set_state_info("Le chemin de livraison est bloque; je vais recalculer un trajet.")
    return true
  end

  local task_id = msg and msg.data and msg.data.task_id or nil
  local collab = working_villages.collaborative_tasks
  if task_id and collab and collab.fail then
    local record = collab.get and collab.get(task_id) or nil
    if record and record.state == "active" then
      collab.fail(task_id, "Livraison impossible apres trois recherches de chemin")
    end
  end
  finish_physical_delivery(self, false, {
    reason = reason or "no_path",
    failures = state.failures,
  }, msg)
  self:set_displayed_action("livraison impossible")
  self:set_state_info("Je n'ai pas trouve de chemin de livraison; la cargaison reste dans mon inventaire.")
  return false
end

finish_physical_delivery = function(self, success, summary, msg)
  self.job_data = self.job_data or {}
  local state = self.job_data.physical_delivery_state
  local expected_key = msg and physical_delivery_coordination.message_key(self, msg) or nil
  if type(state) == "table" and expected_key and state.delivery_key
      and state.delivery_key ~= expected_key then
    return false
  end
  if type(state) == "table" then
    local current = self.object and self.object:get_pos() or nil
    if current and state.last_pos then
      state.travelled = (tonumber(state.travelled) or 0) + vector.distance(current, state.last_pos)
    end
    self.job_data.last_physical_delivery = {
      success = success == true,
      started_at = state.started_at,
      completed_at = minetest.get_gametime(),
      start_pos = state.start_pos,
      target_pos = state.target_pos,
      target_kind = state.target_kind,
      travelled = tonumber(state.travelled) or 0,
      task_id = state.task_id,
      summary = summary,
    }
    physical_delivery_coordination.clear_incoming(self, state)
  end
  local pending = self.job_data.pending_resource_message
  local pending_key = pending and physical_delivery_coordination.message_key(self, pending) or nil
  if not expected_key or pending_key == expected_key then
    self.job_data.pending_resource_message = nil
  end
  if type(state) == "table" and (not expected_key or state.delivery_key == expected_key) then
    self.job_data.physical_delivery_state = nil
  end
  if self.cancel_go_to_step then
    self:cancel_go_to_step(PHYSICAL_DELIVERY_NAVIGATION_KEY, true)
  end
  return true
end

local function reach_physical_delivery_target(self, msg, target_pos, target_kind, requester)
  if not valid_delivery_target(target_pos) or not self.object then
    return nil
  end
  local current = self.object:get_pos()
  if not current then
    return nil
  end
  local state = begin_physical_delivery(self, msg, target_pos, target_kind)
  if target_kind == "requester" then
    physical_delivery_coordination.register_incoming(self, requester, state)
  end
  local now = math.max(0, tonumber(minetest.get_gametime()) or 0)
  -- Migrate the first implementation's absolute deadline. Capping the derived
  -- duration prevents an old pre-restart gametime from becoming a huge delay.
  if state.retry_remaining == nil and tonumber(state.retry_at) then
    state.retry_remaining = math.min(physical_delivery_coordination.stock_retry_max,
      math.max(0, tonumber(state.retry_at) - now))
    state.retry_clock = now
    state.retry_at = nil
  end
  if physical_delivery_coordination.advance_relative_timer(
      state, "retry_remaining", "retry_clock") > 0 then
    if self.cancel_go_to_step then
      self:cancel_go_to_step(PHYSICAL_DELIVERY_NAVIGATION_KEY, true)
    end
    return false, state
  end
  state.wait_reason = nil
  if vector.distance(current, target_pos) <= PHYSICAL_DELIVERY_REACH then
    if self.cancel_go_to_step then
      self:cancel_go_to_step(PHYSICAL_DELIVERY_NAVIGATION_KEY, true)
    end
    return true, state
  end
  self:set_displayed_action(target_kind == "shared_storage"
    and "livre au coffre commun" or "apporte des ressources")
  self:set_state_info(target_kind == "shared_storage"
    and "Je transporte physiquement les ressources jusqu'au coffre commun."
    or "Je transporte physiquement les ressources jusqu'au villageois qui les a demandees.")
  local navigation_target = valid_delivery_target(state.rendezvous_pos)
    and state.rendezvous_pos or target_pos
  if self.go_to_step then
    local reached = self:go_to_step(navigation_target, PHYSICAL_DELIVERY_NAVIGATION_KEY)
    if reached == false then
      retry_or_fail_physical_delivery(self, msg, state, "no_path")
      return false
    elseif reached == true and target_kind == "requester"
        and vector.distance(current, target_pos) > PHYSICAL_DELIVERY_REACH then
      -- The requester was allowed to finish an older, higher-priority
      -- delivery. Retarget only after this stable rendezvous was reached;
      -- never replace the path on every moving-target tick.
      state.rendezvous_pos = vector.round(target_pos)
      state.retargets = math.max(0, math.floor(tonumber(state.retargets) or 0)) + 1
      physical_delivery_coordination.register_incoming(self, requester, state)
    end
  end
  return false, state
end

function physical_delivery_coordination.message_is_outbound(self, msg)
  local data = msg and msg.data or nil
  if not data or msg.type ~= "help_needed"
      or data.requester_id == self.inventory_name then
    return false
  end
  return type(data.items) == "table" or data.tool_group ~= nil
    or data.resource == "food"
end

function physical_delivery_coordination.message_is_bootstrap(self, msg)
  return physical_delivery_coordination.message_is_outbound(self, msg)
    and msg.data.bootstrap_infrastructure == true
end

function physical_delivery_coordination.normalize_order(order, bootstrap_infrastructure)
  order = tostring(order or "")
  if order:match("^[01]|" ) then
    return order
  end
  return (bootstrap_infrastructure == true and "0|" or "1|") .. order
end

function physical_delivery_coordination.message_order(self, msg)
  local priority = physical_delivery_coordination.priority(self, msg)
  local key = physical_delivery_coordination.message_key(self, msg)
  return physical_delivery_coordination.normalize_order(
    priority .. "|" .. key,
    physical_delivery_coordination.message_is_bootstrap(self, msg))
end

function physical_delivery_coordination.outbound_order(self)
  local best = nil
  local state = self.job_data and self.job_data.physical_delivery_state or nil
  local pending = self.job_data and self.job_data.pending_resource_message or nil
  if physical_delivery_coordination.message_is_outbound(self, pending) then
    best = physical_delivery_coordination.message_order(self, pending)
  elseif type(state) == "table" and state.order then
    best = physical_delivery_coordination.normalize_order(
      state.order, state.bootstrap_infrastructure == true)
  end

  -- handle_incoming runs before process_resource_requests. Make a queued
  -- infrastructure request visible here so a supplier waiting for an ordinary
  -- incoming delivery releases that rendezvous and can service the bootstrap.
  local inbox = self.job_data and self.job_data.inbox or nil
  for _, msg in ipairs(type(inbox) == "table" and inbox or {}) do
    if physical_delivery_coordination.message_is_bootstrap(self, msg) then
      local order = physical_delivery_coordination.message_order(self, msg)
      if not best or order < best then
        best = order
      end
    end
  end
  return best
end

function physical_delivery_coordination.cancel_incoming_navigation(self, stop_motion)
  if self.cancel_go_to_step then
    self:cancel_go_to_step(
      physical_delivery_coordination.wait_navigation_key, stop_motion == true)
  end
end

function physical_delivery_coordination.handle_incoming(self, dtime)
  local incoming = self.job_data and self.job_data.physical_delivery_incoming or nil
  if type(incoming) ~= "table" then
    physical_delivery_coordination.cancel_incoming_navigation(self, false)
    return false
  end

  local comm = working_villages.communication
  local elapsed = math.max(0, tonumber(dtime) or 0)
  local selected = nil
  for key, entry in pairs(incoming) do
    if type(entry) ~= "table" or not valid_delivery_target(entry.rendezvous_pos) then
      incoming[key] = nil
    else
      local supplier = comm and comm.find_villager_by_inventory_name
        and comm.find_villager_by_inventory_name(entry.supplier_id) or nil
      local supplier_state = supplier and supplier.job_data
        and supplier.job_data.physical_delivery_state or nil
      if supplier and (type(supplier_state) ~= "table"
          or supplier_state.delivery_key ~= entry.delivery_key) then
        incoming[key] = nil
      else
        entry.remaining = math.max(0,
          (tonumber(entry.remaining) or physical_delivery_coordination.wait_ttl) - elapsed)
        if entry.remaining <= 0 then
          incoming[key] = nil
        else
          local order = physical_delivery_coordination.normalize_order(
            entry.order or (tostring(entry.priority) .. "|" .. tostring(entry.delivery_key)),
            entry.bootstrap_infrastructure == true)
          entry.order = order
          if not selected or order < selected.order then
            selected = {entry = entry, order = order}
          end
        end
      end
    end
  end

  if next(incoming) == nil then
    self.job_data.physical_delivery_incoming = nil
  end
  if not selected then
    physical_delivery_coordination.cancel_incoming_navigation(self, false)
    return false
  end

  -- In a cycle (A delivers to B while B delivers to C, etc.), only the oldest
  -- deterministic delivery advances. Its supplier keeps walking and its
  -- requester waits; every later delivery remains intact and resumes next.
  local outgoing_order = physical_delivery_coordination.outbound_order(self)
  if outgoing_order and outgoing_order < selected.order then
    physical_delivery_coordination.cancel_incoming_navigation(self, false)
    return false
  end

  local rendezvous = selected.entry.rendezvous_pos
  local current = self.object and self.object:get_pos() or nil
  if not current then
    return true
  end
  self:set_displayed_action("attend une livraison")
  self:set_state_info("Je garde un point de rendez-vous stable pour recevoir les ressources, puis je reprends mon travail.")
  if vector.distance(current, rendezvous) <= physical_delivery_coordination.wait_reach then
    physical_delivery_coordination.cancel_incoming_navigation(self, true)
    if self.object then
      self.object:set_velocity({x = 0, y = 0, z = 0})
    end
    self:set_animation(working_villages.animation_frames.STAND)
    return true
  end

  if self.go_to_step then
    local reached = self:go_to_step(
      rendezvous, physical_delivery_coordination.wait_navigation_key)
    if reached == false then
      -- The original meeting node became inaccessible. Hold the requester's
      -- current real position and let the supplier retarget after reaching the
      -- old anchor; no inventory transfer occurs here.
      selected.entry.rendezvous_pos = vector.round(current)
      physical_delivery_coordination.cancel_incoming_navigation(self, true)
    end
  end
  return true
end

function working_villages.villager:queue_physical_delivery(requester_id, data)
  local comm = working_villages.communication
  if not comm or type(requester_id) ~= "string" or requester_id == ""
      or type(data) ~= "table" then
    return false
  end
  local payload = copy_delivery_payload(data)
  payload.requester_id = requester_id
  return comm.send_message(self, self, "help_needed", payload)
end

function physical_delivery_coordination.queue_order(self, msg, pending, sequence)
  local bootstrap_rank = physical_delivery_coordination.message_is_bootstrap(self, msg)
    and "0" or "1"
  local pending_rank = msg == pending and "0" or "1"
  return table.concat({
    bootstrap_rank,
    pending_rank,
    physical_delivery_coordination.priority(self, msg),
    tostring(msg and msg.type or ""),
    physical_delivery_coordination.message_key(self, msg),
    string.format("%08d", math.max(0, math.floor(tonumber(sequence) or 0))),
  }, "|")
end

function physical_delivery_coordination.collect_messages(self, comm)
  self.job_data = self.job_data or {}
  local pending = self.job_data.pending_resource_message
  local consumed = comm.consume_messages(self) or {}
  local queued = {}
  local waiting = {}
  local sequence = 0
  if pending then
    sequence = sequence + 1
    queued[#queued + 1] = {
      msg = pending,
      order = physical_delivery_coordination.queue_order(
        self, pending, pending, sequence),
    }
  end
  for _, msg in ipairs(consumed) do
    if msg ~= pending then
      if physical_delivery_coordination.supply_retry_waiting(msg) then
        waiting[#waiting + 1] = msg
      else
        sequence = sequence + 1
        queued[#queued + 1] = {
          msg = msg,
          order = physical_delivery_coordination.queue_order(
            self, msg, pending, sequence),
        }
      end
    end
  end
  if #waiting > 0 then
    local inbox = type(self.job_data.inbox) == "table" and self.job_data.inbox or {}
    for _, msg in ipairs(waiting) do
      inbox[#inbox + 1] = msg
    end
    self.job_data.inbox = inbox
  end
  table.sort(queued, function(a, b)
    if a.order == b.order then
      return false
    end
    return a.order < b.order
  end)
  local messages = {}
  for _, entry in ipairs(queued) do
    messages[#messages + 1] = entry.msg
  end
  return messages
end

function physical_delivery_coordination.reject_without_trip(self, msg, reason)
  self.job_data = self.job_data or {}
  local key = physical_delivery_coordination.message_key(self, msg)
  local pending = self.job_data.pending_resource_message
  local pending_key = pending
    and physical_delivery_coordination.message_key(self, pending) or nil
  local state = self.job_data.physical_delivery_state
  if pending_key == key or (type(state) == "table" and state.delivery_key == key) then
    finish_physical_delivery(self, false, {reason = reason or "no_deliverable_stock"}, msg)
  end
  local retrying = physical_delivery_coordination.requeue_supply_retry(self, msg, reason)
  self.job_data.last_resource_request_failure = {
    time = minetest.get_gametime(),
    delivery_key = key,
    task_id = msg and msg.data and msg.data.task_id or nil,
    reason = reason or "no_deliverable_stock",
    retrying = retrying,
    attempts = msg and msg.supply_retry and msg.supply_retry.attempts or 0,
  }
  return retrying
end

function working_villages.villager:process_resource_requests()
  local comm = working_villages.communication
  if not comm then
    return false
  end
  self.job_data = self.job_data or {}
  local messages = physical_delivery_coordination.collect_messages(self, comm)
  if not messages or #messages == 0 then
    return false
  end

  local inv = self:get_inventory()
  for message_index, msg in ipairs(messages) do
    if msg.type == "help_needed" and msg.data and msg.data.task_id
        and not physical_delivery_task_is_active(msg) then
      physical_delivery_coordination.reject_without_trip(self, msg, "task_inactive")
    elseif msg.type == "help_needed" and msg.data and msg.data.items
        and msg.data.requester_id ~= self.inventory_name then
      local requested_items, _, available =
        physical_delivery_coordination.prepare_requested_items(self, msg.data.items)
      if available <= 0 then
        physical_delivery_coordination.reject_without_trip(
          self, msg, "requested_items_unavailable")
      else
        local base_pos = self:ensure_shared_storage_pos()
        local requester = msg.data.requester_id
          and comm.find_villager_by_inventory_name(msg.data.requester_id) or nil
        local requester_pos = requester and requester ~= self and requester.object
          and requester.object:get_pos() or nil
        local use_shared_storage = requester_pos == nil and is_chest_pos(base_pos)
        local target_pos = requester_pos or (use_shared_storage and base_pos or nil)
        local target_kind = requester_pos and "requester" or "shared_storage"
        if not target_pos and msg.data.requester_id then
          defer_physical_delivery(self, msg, "requester_unavailable")
          restore_unprocessed_messages(self, messages, message_index + 1)
          return self.job_data.pending_resource_message ~= nil
        end
        if target_pos then
          local reached = reach_physical_delivery_target(
            self, msg, target_pos, target_kind, requester)
          if not reached then
            restore_unprocessed_messages(self, messages, message_index + 1)
            return self.job_data.pending_resource_message ~= nil
          end
        end
        local moved_items = transfer_requested_items(
          self, requester, base_pos, use_shared_storage, requested_items)
        if next(moved_items) and use_shared_storage and not requester
            and msg.data.task_id then
          physical_delivery_coordination.record_task_progress(
            self, msg.data.task_id, msg.data.requester_id, {items = moved_items})
        end
        if next(moved_items) and requester then
          comm.send_message(self, requester, "resource_found", {
            ok = true,
            items = moved_items,
            direct = not use_shared_storage,
            task_id = msg.data.task_id,
          })
        end
        finish_physical_delivery(
          self, next(moved_items) ~= nil, {items = moved_items}, msg)
      end
    elseif msg.type == "help_needed" and msg.data and msg.data.tool_group
        and msg.data.requester_id ~= self.inventory_name then
      local tool_stock = physical_delivery_coordination.count_inventory_matching(
        inv, function(stack)
          return minetest.get_item_group(stack:get_name(), msg.data.tool_group) > 0
        end)
      if tool_stock <= 0 then
        physical_delivery_coordination.reject_without_trip(
          self, msg, "requested_tool_unavailable")
      else
        local base_pos = self:ensure_shared_storage_pos()
        local requester = msg.data.requester_id
          and comm.find_villager_by_inventory_name(msg.data.requester_id) or nil
        local requester_pos = requester and requester ~= self and requester.object
          and requester.object:get_pos() or nil
        local use_shared_storage = requester_pos == nil and is_chest_pos(base_pos)
        local target_pos = requester_pos or (use_shared_storage and base_pos or nil)
        local target_kind = requester_pos and "requester" or "shared_storage"
        if not target_pos and msg.data.requester_id then
          defer_physical_delivery(self, msg, "requester_unavailable")
          restore_unprocessed_messages(self, messages, message_index + 1)
          return self.job_data.pending_resource_message ~= nil
        end
        if target_pos then
          local reached = reach_physical_delivery_target(
            self, msg, target_pos, target_kind, requester)
          if not reached then
            restore_unprocessed_messages(self, messages, message_index + 1)
            return self.job_data.pending_resource_message ~= nil
          end
        end
        local moved = 0
        local remaining = math.max(1, math.floor(tonumber(msg.data.count) or 1))
        local size = inv and inv:get_size("main") or 0
        for index = 1, size do
          if remaining <= 0 then
            break
          end
          local stack = inv:get_stack("main", index)
          if not stack:is_empty()
              and minetest.get_item_group(stack:get_name(), msg.data.tool_group) > 0 then
            local requested = math.min(remaining, stack:get_count())
            local moved_now = 0
            if use_shared_storage then
              local storage_pos = self:get_shared_storage_chest_for_item(stack:get_name(), true)
              if storage_pos and self:reserve_position("shared_storage_chest", storage_pos, 2) then
                moved_now = inventory_access.put_from_inventory(
                  self, inv, "main", index, storage_pos, "main", nil, requested)
                self:release_reserved_position("shared_storage_chest", storage_pos)
              end
            elseif requester and requester ~= self then
              local taken = stack:take_item(requested)
              local leftover = requester:add_item_to_main(taken)
              moved_now = requested - leftover:get_count()
              if not leftover:is_empty() then
                stack:add_item(leftover)
              end
              inv:set_stack("main", index, stack)
            end
            moved = moved + moved_now
            remaining = remaining - moved_now
          end
        end
        if moved > 0 and use_shared_storage and not requester and msg.data.task_id then
          physical_delivery_coordination.record_task_progress(
            self, msg.data.task_id, msg.data.requester_id, {
              tool_group = msg.data.tool_group,
              tools = moved,
            })
        end
        if moved > 0 and requester then
          comm.send_message(self, requester, "resource_found", {
            ok = true,
            tool_group = msg.data.tool_group,
            count = moved,
            direct = not use_shared_storage,
            task_id = msg.data.task_id,
          })
        end
        finish_physical_delivery(self, moved > 0, {
          tool_group = msg.data.tool_group,
          count = moved,
        }, msg)
      end
    elseif msg.type == "help_needed" and msg.data and msg.data.resource == "food"
        and msg.data.requester_id ~= self.inventory_name then
      local food_stock = physical_delivery_coordination.count_inventory_matching(
        inv, function(stack) return is_food_item(stack:get_name()) end)
      if food_stock <= 0 then
        physical_delivery_coordination.reject_without_trip(
          self, msg, "requested_food_unavailable")
      else
        local base_pos = self:ensure_shared_storage_pos()
        local stock_deposit = msg.data.delivery_target == "shared_storage"
        local requester = msg.data.requester_id
          and comm.find_villager_by_inventory_name(msg.data.requester_id) or nil
        local requester_pos = not stock_deposit and requester and requester ~= self
          and requester.object and requester.object:get_pos() or nil
        local use_shared_storage = stock_deposit and is_chest_pos(base_pos)
          or (requester_pos == nil and is_chest_pos(base_pos))
        local target_pos = requester_pos or (use_shared_storage and base_pos or nil)
        local target_kind = requester_pos and "requester" or "shared_storage"
        if not target_pos and (msg.data.requester_id or stock_deposit) then
          defer_physical_delivery(self, msg,
            stock_deposit and "shared_storage_unavailable" or "requester_unavailable")
          restore_unprocessed_messages(self, messages, message_index + 1)
          return self.job_data.pending_resource_message ~= nil
        end
        if target_pos then
          local reached = reach_physical_delivery_target(
            self, msg, target_pos, target_kind, requester)
          if not reached then
            restore_unprocessed_messages(self, messages, message_index + 1)
            return self.job_data.pending_resource_message ~= nil
          end
        end
        local requested_food = math.max(1,
          math.floor(tonumber(msg.data.count) or 2))
        local moved_count = transfer_food_items(
          self, stock_deposit and nil or requester,
          base_pos, use_shared_storage, requested_food)
        if moved_count > 0 and use_shared_storage and msg.data.task_id
            and (stock_deposit or not requester) then
          physical_delivery_coordination.record_task_progress(
            self, msg.data.task_id, msg.data.requester_id, {food = moved_count})
        end
        if moved_count > 0 and requester then
          comm.send_message(self, requester, "resource_found", {
            ok = true,
            resource = "food",
            count = moved_count,
            direct = not use_shared_storage,
            stock_deposit = stock_deposit and use_shared_storage,
            delivery_target = msg.data.delivery_target,
            task_id = msg.data.task_id,
          })
        end
        finish_physical_delivery(self, moved_count > 0, {
          resource = "food",
          count = moved_count,
        }, msg)
      end
    elseif msg.type == "help_needed" and msg.data and msg.data.task_id then
      local collab = working_villages.collaborative_tasks
      local record = collab and collab.get and collab.get(msg.data.task_id) or nil
      if record and record.state == "active" and record.owner_name == (self.owner_name or "") then
        self.job_data = self.job_data or {}
        self.job_data.collab_context = {
          task_id = record.id,
          task = record.name,
          data = record.data,
        }
        if record.name == "danger_response" then
          self.job_data.danger_ticks = 200
          self.job_data.danger_pos = record.data and record.data.pos or nil
          self:set_displayed_action("repond a l'alerte")
          self:set_state_info("Je rejoins la defense collective du village.")
        elseif record.name == "large_building" then
          self:set_state_info("Je participe a l'approvisionnement du grand chantier.")
        end
      end
    elseif msg.type == "task_complete" and msg.data and msg.data.task_id then
      self.job_data = self.job_data or {}
      if self.job_data.collab_context
          and self.job_data.collab_context.task_id == msg.data.task_id then
        self.job_data.collab_context = nil
      end
    elseif msg.type == "resource_found" and msg.data and msg.data.ok then
      self.job_data = self.job_data or {}
      if not msg.data.direct and not msg.data.stock_deposit then
        local storage_pos = self:ensure_shared_storage_pos()
        if is_chest_pos(storage_pos) then
          local reached = reach_physical_delivery_target(
            self, msg, storage_pos, "shared_storage")
          if not reached then
            restore_unprocessed_messages(self, messages, message_index + 1)
            return self.job_data.pending_resource_message ~= nil
          end
        end
      end
      local received_items = {}
      local received_food = 0
      local received_tool_count = 0
      if msg.data.stock_deposit and msg.data.resource == "food" then
        self:set_displayed_action("coordonne les provisions")
        self:set_state_info("Le stock alimentaire commun a recu de nouvelles provisions.")
      elseif msg.data.direct then
        if msg.data.tool_group then
          received_tool_count = math.max(0, math.floor(tonumber(msg.data.count) or 1))
          self:set_displayed_action("recupere un outil")
          self:set_state_info("Quelqu'un m'a donne l'outil dont j'avais besoin.")
        elseif msg.data.items then
          add_delivery_counts(received_items, msg.data.items)
          self:set_displayed_action("recupere des ressources")
          self:set_state_info("Quelqu'un m'a apporte les ressources demandees.")
        elseif msg.data.resource == "food" then
          received_food = math.max(0, math.floor(tonumber(msg.data.count) or 0))
          self:set_displayed_action("recupere des provisions")
          self:set_state_info("Quelqu'un m'a apporte de quoi manger.")
        end
      elseif msg.data.tool_group and self.take_tool_from_shared_storage then
        if self:take_tool_from_shared_storage(msg.data.tool_group) then
          received_tool_count = 1
          self:set_displayed_action("recupere un outil")
          self:set_state_info("Je recupere l'outil signale dans le coffre commun.")
        else
          self:set_state_info("On m'a signale un outil disponible dans le coffre commun.")
        end
      elseif msg.data.items and self.take_from_shared_storage then
        local took_any, moved_items = self:take_from_shared_storage(msg.data.items)
        if took_any then
          add_delivery_counts(received_items, moved_items)
          self:set_displayed_action("recupere des ressources")
          self:set_state_info("Je recupere les ressources signalees dans le coffre commun.")
        else
          self:set_state_info("On m'a signale des ressources disponibles dans le coffre commun.")
        end
      elseif msg.data.resource == "food" and self.take_from_shared_storage_by_predicate then
        local took_any, moved_count = self:take_from_shared_storage_by_predicate(
          is_food_item, msg.data.count or 2)
        if took_any then
          received_food = moved_count or 0
          self:set_displayed_action("recupere des provisions")
          self:set_state_info("Je recupere de la nourriture signalee dans le coffre commun.")
        else
          self:set_state_info("On m'a signale de la nourriture disponible dans le coffre commun.")
        end
      end

      local received_any = next(received_items) ~= nil
        or received_food > 0 or received_tool_count > 0
      if received_any then
        self.job_data.last_supply_signal = {
          time = minetest.get_gametime(),
          tool_group = msg.data.tool_group,
          resource = msg.data.resource,
          direct = msg.data.direct == true,
        }
      end
      finish_physical_delivery(self, received_any or msg.data.stock_deposit == true, {
        items = received_items,
        food = received_food,
        tools = received_tool_count,
      }, msg)

      -- A collaborative delivery is completed only after every requested unit
      -- has physically moved. The same ledger helper also covers unloaded
      -- requesters whose cargo was deposited into shared storage by the sender.
      if received_any then
        physical_delivery_coordination.record_task_progress(
          self, msg.data.task_id or self.job_data.collab_task,
          self.inventory_name, {
            items = received_items,
            food = received_food,
            tool_group = msg.data.tool_group,
            tools = received_tool_count,
          })
      end
    elseif msg.type == "danger_alert" then
      self.job_data = self.job_data or {}
      self.job_data.danger_ticks = 200
      self:set_displayed_action("danger")
      self:set_state_info("Je me mets a l'abri.")
    end
  end
  return self.job_data.pending_resource_message ~= nil
end

function working_villages.villager:count_shared_storage_items(predicate)
  local base_pos = self:ensure_shared_storage_pos()
  if not is_chest_pos(base_pos) then
    return 0
  end

  if predicate == is_food_item then
    return get_shared_storage_summary(base_pos).food
  end
  if predicate == is_raw_food_item then
    return get_shared_storage_summary(base_pos).raw_food
  end
  if predicate == is_wood_item then
    return get_shared_storage_summary(base_pos).wood
  end
  if predicate == is_ore_item then
    return get_shared_storage_summary(base_pos).ore
  end
  if predicate == is_tool_item then
    return get_shared_storage_summary(base_pos).tools
  end

  local chests = self:get_shared_storage_chests()
  if #chests == 0 then
    chests = {base_pos}
  end
  local total = 0
  for _, pos in ipairs(chests) do
    local inv = get_chest_inventory(pos)
    total = total + count_items_in_inventory(inv, predicate)
  end
  return total
end

function working_villages.villager:update_resource_needs()
  local village = working_villages.get_village_status(self, 50)
  if not village or not working_villages.needs.update_resources then
    return nil, nil
  end
  return working_villages.needs.update_resources(self, {
    population = village.population,
    tools = village.available_tools or village.tools or 0,
    materials = village.available_materials or village.materials or 0,
  })
end

-- These are wall-clock seconds (the decision timer below remains expressed in
-- logical steps).  A specialist gets enough time to complete a useful batch,
-- but a five-person village no longer loses one worker for fifteen minutes.
local auto_job_initial_cooldown = working_villages.needs.auto_job_cooldowns.initial
local auto_job_reassignment_cooldown = working_villages.needs.auto_job_cooldowns.specialize
local auto_job_return_cooldown = working_villages.needs.auto_job_cooldowns.returning
local auto_job_village_reassignment_cooldown = working_villages.needs.auto_job_cooldowns.village

local function auto_job_timer_limit(self)
  local id = tostring(self.inventory_name or self.nametag or "")
  local hash = 0
  for i = 1, #id do
    hash = (hash + (id:byte(i) * i)) % 41
  end
  return 80 + hash
end

local function village_auto_job_locked(owner_name, now, kind, cooldown)
  for _, villager in ipairs(list_loaded_owner_villagers(owner_name)) do
    local data = villager.job_data
    local changed_at = data and tonumber(data.auto_job_last_change_at) or nil
    if changed_at and (kind == nil or data.auto_job_last_change_kind == kind) then
      if changed_at > now or (now - changed_at) < cooldown then
        return true
      end
    end
  end
  return false
end

local function record_auto_job_change(self, now, old_job, new_job, reason, kind, cooldown)
  self.job_data = self.job_data or {}
  local previous = self.job_data.auto_job_previous
  if kind == "specialize" then
    previous = old_job or ""
  elseif kind == "return" then
    if previous == new_job then
      previous = ""
    end
  elseif kind == "restore" then
    previous = ""
  elseif kind == "rotate" and (not previous or previous == "") then
    previous = old_job or ""
  elseif kind == "initial" then
    previous = ""
  end
  self.job_data.auto_job_last_change_at = now
  self.job_data.auto_job_last_change_kind = kind
  self.job_data.auto_job_cooldown_until = now + cooldown
  self.job_data.auto_job_previous = previous
  self.job_data.auto_job_target = new_job
  self.job_data.auto_job_reason = reason or "priorite du village"
end

local function select_auto_job_donor(self, village, target_job, now, ignore_personal_cooldown)
  local candidates = {}
  local villagers = list_loaded_owner_villagers(self.owner_name)
  if #villagers == 0 then
    villagers = {self}
  end
  for _, candidate in ipairs(villagers) do
    local data = candidate.job_data or {}
    local cooldown_until = tonumber(data.auto_job_cooldown_until) or 0
    if not candidate.pause and (ignore_personal_cooldown or cooldown_until <= now) then
      local current_job = candidate:get_job_name()
      if current_job ~= target_job then
        local priority = working_villages.needs.reassignment_priority(current_job, village, target_job)
        if priority then
          candidates[#candidates + 1] = {
            villager = candidate,
            priority = priority,
            name = tostring(candidate.inventory_name or candidate.nametag or ""),
          }
        end
      end
    end
  end
  table.sort(candidates, function(a, b)
    if a.priority ~= b.priority then
      return a.priority < b.priority
    end
    return a.name < b.name
  end)
  return candidates[1] and candidates[1].villager or nil
end

function working_villages.villager:maybe_auto_assign_job()
  local job_name = self:get_job_name()
  self:count_timer("auto_job")
  if not self:timer_exceeded("auto_job", auto_job_timer_limit(self)) then
    return
  end

  local village = working_villages.get_village_status(self, 50)
  local now = os.time()

  if job_name and job_name ~= "" then
    if not working_villages.needs.reassignable_jobs[job_name] then
      return
    end
    self.job_data = self.job_data or {}
    local previous_job = self.job_data.auto_job_target == job_name
      and self.job_data.auto_job_previous or nil
    local target_job, reason, transition_kind = working_villages.needs.choose_job_transition(
      job_name, village, previous_job)
    if not target_job or target_job == job_name then
      return
    end
    local emergency_guard = target_job == "working_villages:job_guard"
      and (tonumber(village.recent_danger) or 0) > 0
      and ((village.counts and village.counts["working_villages:job_guard"]) or 0) == 0
    if not emergency_guard and (tonumber(self.job_data.auto_job_cooldown_until) or 0) > now then
      return
    end
    if village_auto_job_locked(
        self.owner_name, now, nil, auto_job_village_reassignment_cooldown) then
      return
    end

    if transition_kind ~= "return" and transition_kind ~= "restore" then
      local donor = select_auto_job_donor(self, village, target_job, now, emergency_guard)
      if donor ~= self then
        return
      end
    end

    local changed, old_job = self:change_job(target_job)
    if not changed then
      return
    end
    local cooldown = (transition_kind == "return" or transition_kind == "restore")
      and auto_job_return_cooldown or auto_job_reassignment_cooldown
    record_auto_job_change(
      self, now, old_job, target_job, reason, transition_kind or "specialize", cooldown)
    self:set_state_info("Je change de mission: " .. (reason or "priorite du village") .. ".")
    self:set_displayed_action("nouvelle mission")
    local job_def = working_villages.registered_jobs[target_job]
    local job_label = (job_def and job_def.description) or target_job
    self:notify_owner_event(
      string.format("Reaffectation prudente vers %s: %s.", job_label, reason or "priorite du village"),
      "auto_job:" .. target_job,
      auto_job_village_reassignment_cooldown,
      "important"
    )
    return
  end

  -- A one-second persistent village lock prevents villagers whose timers expire
  -- in the same server step from all selecting the same initial role.
  if village_auto_job_locked(self.owner_name, now, "initial", 1) then
    return
  end

  local focus = (village.control and village.control.focus) or "balanced"
  local bootstrap_stage = village.bootstrap_stage or working_villages.get_village_bootstrap_stage(village)
  local job = working_villages.needs.choose_initial_job(village)

  if job then
    local changed, old_job = self:change_job(job)
    if not changed then
      return
    end
    record_auto_job_change(
      self, now, old_job, job, "premiere mission", "initial", auto_job_initial_cooldown)
    self:set_state_info("Je prends une mission autonome.")
    self:set_displayed_action("mission")
    local job_def = working_villages.registered_jobs[job]
    local job_label = (job_def and job_def.description) or job
    local focus_label = working_villages.describe_village_focus(focus)
    local bootstrap_label = working_villages.describe_bootstrap_stage(bootstrap_stage)
    self:notify_owner_event(
      string.format("Reaffectation autonome vers %s (%s, phase %s).", job_label, focus_label, bootstrap_label),
      "auto_job:" .. job,
      240,
      "important"
    )
  end
end

function working_villages.villager:maintenance_check()
  if not self.pos_data or not self.pos_data.home_pos then
    return
  end

  local door_item = compat.get_door_item()
  local door_pos = self.pos_data.home_pos
  local node = minetest.get_node(door_pos)
  if not compat.is_door(node.name) and self:has_item_in_main(function(name) return name == door_item end) then
    self:place(door_item, door_pos)
  end

  local torch_items = compat.get_torch_items()
  local light = minetest.get_node_light(self.object:get_pos()) or 0
  if light < 8 and self:has_item_in_main(function(name) return name == torch_items.floor end) then
    local target = vector.add(self.object:get_pos(), {x = 1, y = 0, z = 0})
    local ground = func.find_ground_below(target)
    if ground then
      self:place(torch_items.floor, ground)
    end
  end
end

local function stop_job_lifecycle(self, job_name)
  local job = working_villages.registered_jobs[job_name]
  if not job then
    return
  end
  if type(job.on_stop) == "function" then
    job.on_stop(self)
  end
  if type(job.jobfunc) == "function" then
    self.job_thread = false
  end
end

local function start_job_lifecycle(self, job_name)
  local job = working_villages.registered_jobs[job_name]
  if not job then
    return false
  end
  if type(job.on_start) == "function" then
    job.on_start(self)
  end
  if type(job.jobfunc) == "function" then
    self.job_thread = coroutine.create(job.jobfunc)
  else
    self.job_thread = false
  end
  return true
end

-- Programmatic changes do not trigger detached-inventory callbacks. Keep the
-- same on_stop/on_start lifecycle here so autonomous reassignment cannot leave
-- the previous coroutine running or skip initialization of the new job.
function working_villages.villager:change_job(new_job)
  new_job = type(new_job) == "string" and new_job or ""
  if new_job ~= "" and not working_villages.registered_jobs[new_job] then
    return false, "unregistered_job"
  end

  local inv = self:get_inventory()
  if not inv then
    return false, "missing_inventory"
  end
  local old_job = inv:get_stack("job", 1):get_name()
  if old_job == new_job then
    return false, "unchanged"
  end

  stop_job_lifecycle(self, old_job)
  self.time_counters = {}
  inv:set_stack("job", 1, ItemStack(new_job))
  if new_job ~= "" then
    start_job_lifecycle(self, new_job)
    local job = working_villages.registered_jobs[new_job]
    self:set_displayed_action("actif")
    self:set_state_info(("Je commence le metier de %s."):format(job.description or new_job))
  else
    self.job_thread = false
    self:set_displayed_action("inactif\nAucun metier")
    self:set_state_info("J'arrete de travailler.")
  end
  self:update_infotext()
  return true, old_job
end

--[[
  Gets the name of the villager's current job.

  Handles legacy pending new_job values through change_job so lifecycle hooks
  remain consistent with direct autonomous changes.

  @return string - Job item name (e.g., "working_villages:job_farmer")
  @usage local job_name = self:get_job_name()
]]--
function working_villages.villager:get_job_name()
  local inv = self:get_inventory()
  if not inv then
    return ""
  end

  local entity = self
  if self.object and self.object.get_luaentity then
    entity = self.object:get_luaentity() or self
  end
  local new_job = type(entity.new_job) == "string" and entity.new_job or ""
  if new_job ~= "" then
    entity.new_job = ""
    local changed = self:change_job(new_job)
    if changed then
      return new_job
    end
  end

  return inv:get_stack("job", 1):get_name()
end

--[[
  Gets the full job definition for the villager's current job.

  @return table - Job definition with fields: description, inventory_image, jobfunc, etc.
  @return nil - If villager has no job assigned
  @usage local job = self:get_job()
         if job then job.jobfunc(self) end
]]--
function working_villages.villager:get_job()
  local name = self:get_job_name()
  if name ~= "" then
    return working_villages.registered_jobs[name]
  end
  return nil
end

--[[
  Determines if an object is an enemy of this villager.

  Hostile mobs are detected from registered mob definitions and hostile flags.

  @param obj ObjectRef - Object to check
  @return boolean - true if object is hostile
]]--
function working_villages.villager:is_enemy(obj)
  if not obj or obj == self.object then
    return false
  end
  if obj:is_player() then
    return false
  end
  local luaentity = obj:get_luaentity()
  if not luaentity then
    return false
  end
  if luaentity.name and working_villages.is_villager(luaentity.name) then
    return false
  end

  local mobs_api = rawget(_G, "mcl_mobs")
  if mobs_api and mobs_api.registered_mobs and luaentity.name then
    local def = mobs_api.registered_mobs[luaentity.name]
    if def and (def.spawn_class == "hostile" or def.type == "monster" or def.attack_npcs) then
      return true
    end
  end

  if luaentity.spawn_class == "hostile" or luaentity.type == "monster" then
    return true
  end
  if luaentity.attack_npcs then
    return true
  end

  return false
end

local function get_weapon_score(itemname)
  if not itemname or itemname == "" then
    return 0
  end
  local def = minetest.registered_items[itemname]
  if not def then
    return 0
  end
  local groups = def.groups or {}
  local score = 0
  if (groups.sword or 0) > 0 then
    score = score + 100 + groups.sword
  end
  if (groups.axe or 0) > 0 then
    score = score + 80 + groups.axe
  end
  if (groups.pickaxe or 0) > 0 then
    score = score + 60 + groups.pickaxe
  end
  if (groups.shovel or 0) > 0 then
    score = score + 40 + groups.shovel
  end
  local caps = def.tool_capabilities
  if caps and caps.damage_groups and caps.damage_groups.fleshy then
    score = score + caps.damage_groups.fleshy
  end
  return score
end

function working_villages.villager:is_weapon(itemname)
  return get_weapon_score(itemname) > 0
end

function working_villages.villager:equip_best_weapon()
  local inv = self:get_inventory()
  local best_name
  local best_score = 0
  for _, stack in ipairs(inv:get_list("main")) do
    local name = stack:get_name()
    local score = get_weapon_score(name)
    if score > best_score then
      best_score = score
      best_name = name
    end
  end

  if best_score <= 0 then
    return false
  end

  local wield_name = self:get_wield_item_stack():get_name()
  if get_weapon_score(wield_name) >= best_score then
    return true
  end
  return self:move_main_to_wield(function(name)
    return name == best_name
  end)
end

local function get_attack_damage(stack)
  if not stack or stack:is_empty() then
    return 2
  end
  local def = stack:get_definition()
  if def and def.tool_capabilities and def.tool_capabilities.damage_groups then
    local dmg = def.tool_capabilities.damage_groups.fleshy
    if dmg and dmg > 0 then
      return dmg
    end
  end
  return 2
end

local function is_shield_item(name)
  return minetest.get_item_group(name, "shield") > 0
end

-- Some armor mods only expose "armor_points"; others (or items with no
-- dedicated group) fall back to the generic "armor" group. Every score
-- comparison in this file must use the same fallback on both sides, or
-- equip_best_armor can judge an already-equipped "armor"-group item as
-- worthless and swap it out for something worse.
local function item_armor_points(name)
  local p = minetest.get_item_group(name, "armor_points")
  if p == 0 then
    p = minetest.get_item_group(name, "armor")
  end
  return p
end

local function get_armor_points(self)
  local points = 0
  for _, slot in ipairs({"head", "torso", "legs", "feet"}) do
    local stack = self:get_armor_stack(slot)
    if stack and not stack:is_empty() then
      points = points + item_armor_points(stack:get_name())
    end
  end
  return points
end

local function get_armor_reduction(self)
  local points = get_armor_points(self)
  return math.min(0.6, points * 0.04)
end

local function has_shield(self)
  local wield = self:get_wield_item_stack()
  if wield and not wield:is_empty() and is_shield_item(wield:get_name()) then
    return true
  end
  local offhand = self:get_offhand_item_stack()
  if offhand and not offhand:is_empty() and is_shield_item(offhand:get_name()) then
    return true
  end
  local inv = self:get_inventory()
  for _, stack in ipairs(inv:get_list("main")) do
    if not stack:is_empty() and is_shield_item(stack:get_name()) then
      return true
    end
  end
  return false
end

local function try_trigger_enemy_attack(enemy, target)
  if not enemy or not target then
    return
  end
  local luaentity = enemy:get_luaentity()
  if not luaentity or type(luaentity.do_attack) ~= "function" then
    return
  end
  if luaentity.state == "attack" or luaentity.attack == target then
    return
  end
  if luaentity.type == "monster" or luaentity.spawn_class == "hostile" or luaentity.attack_npcs then
    luaentity:do_attack(target)
  end
end

local function face_dot(self, puncher)
  local pos = self.object:get_pos()
  local ppos = puncher and puncher:get_pos()
  if not pos or not ppos then
    return 0
  end
  local forward = minetest.yaw_to_dir(self.object:get_yaw() or 0)
  local dir = vector.direction(pos, ppos)
  return vector.dot(forward, dir)
end

function working_villages.villager:atack(target)
  if not target or not target:get_pos() then
    return false
  end
  local target_pos = target:get_pos()
  local self_pos = self.object:get_pos()
  local dist = vector.distance(self_pos, target_pos)

  if dist > 2.5 then
    self:set_displayed_action("combat")
    self:set_state_info("Je poursuis un ennemi.")
    if coroutine_can_yield() then
      self:count_timer("combat:repath")
      if self:timer_exceeded("combat:repath", 20) then
        local destination = func.find_adjacent_clear(target_pos)
        if destination then
          destination = func.find_ground_below(destination)
        end
        if destination == false then
          destination = target_pos
        end
        self:go_to(destination)
      else
        self:change_direction(target_pos)
      end
    else
      self:change_direction(target_pos)
    end
    self:handle_obstacles(true)
    -- Use WALK animation while chasing
    self:set_animation(working_villages.animation_frames.WALK)
    return true
  end

  self:count_timer("guard:attack")
  if not self:timer_exceeded("guard:attack", 10) then
    -- Keep standing animation when waiting for attack cooldown
    if dist <= 2.5 then
      if has_shield(self) and not (self.job_data and self.job_data.blocking_ticks and self.job_data.blocking_ticks > 0) then
        self.job_data = self.job_data or {}
        self.job_data.blocking_ticks = 6
        self:set_displayed_action("defense")
        self:set_state_info("Je pare avec mon bouclier.")
      end
      self:set_animation(working_villages.animation_frames.STAND)
    end
    return true
  end

  -- Face the target before attacking
  self:change_direction(target_pos)
  
  -- Smooth attack animation sequence
  local dir = vector.direction(self_pos, target_pos)
  local damage = get_attack_damage(self:get_wield_item_stack())
  
  -- Start attack animation (no coroutine yield here: on_step is a C callback)
  self.job_data = self.job_data or {}
  self.job_data.attack_anim_ticks = 6
  self:set_animation(working_villages.animation_frames.MINE)

  -- Execute the punch immediately to avoid yield across C-call boundary
  local before_hp = target:get_hp()
  target:punch(self.object, 1.0, {full_punch_interval = 1.0, damage_groups = {fleshy = damage}}, dir)
  local after_hp = target:get_hp()
  -- Some mob implementations leave HP unchanged on punch() (knockback-only
  -- reaction, internal cooldown); force it so guard/hunt combat still lands.
  -- Never force a player's HP this way: punch() already applies whatever the
  -- server's damage/PvP rules allow, and every current caller only ever
  -- passes hostile mobs or animals (is_enemy() excludes players), so this is
  -- a safety rail against a future caller accidentally targeting a player.
  if before_hp and after_hp and after_hp == before_hp and not target:is_player() then
    local fallback = math.max(1, damage)
    target:set_hp(math.max(0, before_hp - fallback))
  end

  return true
end

--[[
  Finds the nearest player to this villager.
  
  @param range_distance number - Maximum search radius
  @param pos table - Optional position to search from (defaults to villager position)
  @return ObjectRef - Nearest player object
  @return table - Player position {x, y, z}
  @return number - Distance to player
  @return nil - If no player found in range
  
  @usage local player, pos, dist = self:get_nearest_player(20)
]]--
function working_villages.villager:get_nearest_player(range_distance,pos)
  local min_distance = range_distance
  local player,ppos
  local position = pos or self.object:get_pos()

  local all_objects = minetest.get_objects_inside_radius(position, range_distance)
  for _, object in pairs(all_objects) do
    if object:is_player() then
      local player_position = object:get_pos()
      local distance = vector.distance(position, player_position)

      if distance < min_distance then
        min_distance = distance
        player = object
        ppos = player_position
      end
    end
  end
  return player,ppos,min_distance
end

--[[
  Finds the nearest enemy to this villager.

  Searches nearby loaded objects and returns the closest hostile target.
  
  @param range_distance number - Maximum search radius
  @return ObjectRef - Nearest enemy
]]--
function working_villages.villager:get_nearest_enemy(range_distance)
  local enemy
  local min_distance = range_distance
  local position = self.object:get_pos()

  local all_objects = minetest.get_objects_inside_radius(position, range_distance)
  for _, object in pairs(all_objects) do
    if self:is_enemy(object) then
      local object_position = object:get_pos()
      local distance = vector.distance(position, object_position)

      if distance < min_distance then
        min_distance = distance
        enemy = object
      end
    end
  end
  return enemy
end
-- working_villages.villager.get_nearest_item_by_condition returns the position of
-- an item that returns true for the condition
function working_villages.villager:get_nearest_item_by_condition(cond, range_distance)
  local max_distance=range_distance
  if type(range_distance) == "table" then
    max_distance=math.max(math.max(range_distance.x,range_distance.y),range_distance.z)
  end
  local item = nil
  local min_distance = max_distance
  local position = self.object:get_pos()

  local all_objects = minetest.get_objects_inside_radius(position, max_distance)
  for _, object in pairs(all_objects) do
    if not object:is_player() and object:get_luaentity() and object:get_luaentity().name == "__builtin:item" then
      local found_item = ItemStack(object:get_luaentity().itemstring):to_table()
      if found_item then
        if cond(found_item) then
          local item_position = object:get_pos()
          local distance = vector.distance(position, item_position)

          if distance < min_distance then
            min_distance = distance
            item = object
          end
        end
      end
    end
  end
  return item;
end

-- working_villages.villager.get_front returns a position in front of the villager.
function working_villages.villager:get_front()
  local direction = self:get_look_direction()
  if math.abs(direction.x) >= 0.5 then
    if direction.x > 0 then	direction.x = 1	else direction.x = -1 end
  else
    direction.x = 0
  end

  if math.abs(direction.z) >= 0.5 then
    if direction.z > 0 then	direction.z = 1	else direction.z = -1 end
  else
    direction.z = 0
  end

  --direction.y = direction.y - 1

  return vector.add(vector.round(self.object:get_pos()), direction)
end

-- working_villages.villager.get_front_node returns a node that exists in front of the villager.
function working_villages.villager:get_front_node()
  local front = self:get_front()
  return minetest.get_node(front)
end

-- working_villages.villager.get_back returns a position behind the villager.
function working_villages.villager:get_back()
  local direction = self:get_look_direction()
  if math.abs(direction.x) >= 0.5 then
    if direction.x > 0 then	direction.x = -1
    else direction.x = 1 end
  else
    direction.x = 0
  end

  if math.abs(direction.z) >= 0.5 then
    if direction.z > 0 then	direction.z = -1
    else direction.z = 1 end
  else
    direction.z = 0
  end

  --direction.y = direction.y - 1

  return vector.add(vector.round(self.object:get_pos()), direction)
end

-- working_villages.villager.get_back_node returns a node that exists behind the villager.
function working_villages.villager:get_back_node()
  local back = self:get_back()
  return minetest.get_node(back)
end

-- working_villages.villager.get_look_direction returns a normalized vector that is
-- the villagers's looking direction.
function working_villages.villager:get_look_direction()
  local yaw = self.object:get_yaw()
  return vector.normalize{x = -math.sin(yaw), y = 0.0, z = math.cos(yaw)}
end

-- working_villages.villager.set_animation sets the villager's animation.
-- this method is wrapper for self.object:set_animation.
function working_villages.villager:set_animation(frame)
  self.object:set_animation(frame, 15, 0)
  if frame == working_villages.animation_frames.LAY then
    local dir = self:get_look_direction()
    local dirx = math.abs(dir.x)*0.5
    local dirz = math.abs(dir.z)*0.5
    self.object:set_properties({collisionbox={-0.5-dirx, 0, -0.5-dirz, 0.5+dirx, 0.5, 0.5+dirz}})
  else
    self.object:set_properties({collisionbox={-0.25, 0, -0.25, 0.25, 1.75, 0.25}})
  end
end

-- working_villages.villager.set_yaw_by_direction sets the villager's yaw
-- by a direction vector.
function working_villages.villager:set_yaw_by_direction(direction)
  self.object:set_yaw(math.atan2(direction.z, direction.x) - math.pi / 2)
end

-- working_villages.villager.get_wield_item_stack returns the villager's wield item's stack.
function working_villages.villager:get_wield_item_stack()
  local inv = self:get_inventory()
  return inv:get_stack("wield_item", 1)
end

-- working_villages.villager.set_wield_item_stack sets villager's wield item stack.
function working_villages.villager:set_wield_item_stack(stack)
  local inv = self:get_inventory()
  inv:set_stack("wield_item", 1, stack)
end

-- working_villages.villager.get_offhand_item_stack returns the villager's offhand stack.
function working_villages.villager:get_offhand_item_stack()
  local inv = self:get_inventory()
  return inv:get_stack("offhand", 1)
end

-- working_villages.villager.set_offhand_item_stack sets villager's offhand stack.
function working_villages.villager:set_offhand_item_stack(stack)
  local inv = self:get_inventory()
  inv:set_stack("offhand", 1, stack)
end

--[[
  Armor API Functions
  
  These functions manage armor equipment on villagers.
  Armor is displayed using PNG textures via dummy entities attached to villager bones.
  Compatible with both minetest_game and VoxeLibre armor systems.
  
  Armor slots: head, torso, legs, feet
  Each slot accepts items with the corresponding armor group:
  - head: armor_head (helmets)
  - torso: armor_torso (chestplates)
  - legs: armor_legs (leggings)
  - feet: armor_feet (boots)
]]--

local function ensure_slot_name(slot)
  if slot == "head" or slot == "torso" or slot == "legs" or slot == "feet" then
    return slot
  end
  error("invalid armor slot: " .. tostring(slot))
end

--[[
  Get the armor stack in a specific slot.
  
  @param slot string - Armor slot name ("head", "torso", "legs", or "feet")
  @return ItemStack - The armor item in that slot
  @usage local helmet = self:get_armor_stack("head")
]]--
function working_villages.villager:get_armor_stack(slot)
  local inv = self:get_inventory()
  local slot_name = ensure_slot_name(slot)
  return inv:get_stack(slot_name, 1)
end

--[[
  Set the armor stack in a specific slot.
  
  @param slot string - Armor slot name ("head", "torso", "legs", or "feet")
  @param stack ItemStack - The armor item to place in the slot
  @usage self:set_armor_stack("head", ItemStack("default:steel_helmet"))
]]--
function working_villages.villager:set_armor_stack(slot, stack)
  local inv = self:get_inventory()
  local slot_name = ensure_slot_name(slot)
  inv:set_stack(slot_name, 1, stack)
end

--[[
  Get the helmet/head item.
  Convenience wrapper for get_armor_stack("head").
  
  @return ItemStack - The head armor item
]]--
function working_villages.villager:get_head_item_stack()
  return self:get_armor_stack("head")
end

--[[
  Set the helmet/head item.
  Convenience wrapper for set_armor_stack("head", stack).
  
  @param stack ItemStack - The head armor to equip
]]--
function working_villages.villager:set_head_item_stack(stack)
  self:set_armor_stack("head", stack)
end

local armor_slots = {"head","torso","legs","feet"}

-- pick the best armor in main for a slot based on armor_points/armor groups, move it into slot
function working_villages.villager:equip_best_armor()
  local inv = self:get_inventory()
  for _, slot in ipairs(armor_slots) do
    local best_index = nil
    local best_score = -1
    local main_list = inv:get_list("main")
    for idx, st in ipairs(main_list) do
      if not st:is_empty() and working_villages.require("util").is_armor_for_slot(slot, st) then
        local g = item_armor_points(st:get_name())
        if g > best_score then
          best_score = g
          best_index = idx
        end
      end
    end
    if best_index then
      local current = inv:get_stack(slot, 1)
      local best = inv:get_stack("main", best_index)
      if current:is_empty() or item_armor_points(current:get_name()) < best_score then
        inv:set_stack("main", best_index, current)
        inv:set_stack(slot, 1, best)
      end
    end
  end
  self:refresh_equipment()
end

-- working_villages.villager.add_item_to_main add item to main slot.
-- and returns leftover.
function working_villages.villager:add_item_to_main(stack)
  local inv = self:get_inventory()
  return inv:add_item("main", stack)
end

function working_villages.villager:replace_item_from_main(rstack,astack)
  local inv = self:get_inventory()
  inv:remove_item("main", rstack)
  inv:add_item("main", astack)
end

-- working_villages.villager.move_main_to_wield moves itemstack from main to wield.
-- if this function fails then returns false, else returns true.
function working_villages.villager:move_main_to_wield(pred)
  local inv = self:get_inventory()
  local main_size = inv:get_size("main")

  for i = 1, main_size do
    local stack = inv:get_stack("main", i)
    if pred(stack:get_name()) then
      local wield_stack = inv:get_stack("wield_item", 1)
      inv:set_stack("wield_item", 1, stack)
      inv:remove_item("main", stack)
      inv:add_item("main", wield_stack)
      return true
    end
  end
  return false
end

-- working_villages.villager.is_named reports the villager is still named.
function working_villages.villager:is_named()
  return self.nametag ~= ""
end

-- working_villages.villager.has_item_in_main reports whether the villager has item.
function working_villages.villager:has_item_in_main(pred)
  local inv = self:get_inventory()
  local stacks = inv:get_list("main")

  for _, stack in ipairs(stacks) do
    local itemname = stack:get_name()
    if pred(itemname) then
      return true
    end
  end
end

-- working_villages.villager.change_direction change direction to destination and velocity vector.
function working_villages.villager:change_direction(destination)
  local position = self.object:get_pos()
  local direction = vector.subtract(destination, position)
  direction.y = 0
  local velocity = vector.multiply(vector.normalize(direction), 1.5)

  self.object:set_velocity(velocity)
  self:set_yaw_by_direction(direction)
end

-- working_villages.villager.change_direction_randomly change direction randonly.
function working_villages.villager:change_direction_randomly()
  local direction = {
    x = math.random(0, 5) * 2 - 5,
    y = 0,
    z = math.random(0, 5) * 2 - 5,
  }
  local velocity = vector.multiply(vector.normalize(direction), 1.5)
  self.object:set_velocity(velocity)
  self:set_yaw_by_direction(direction)
  self:set_animation(working_villages.animation_frames.WALK)
end

-- working_villages.villager.get_timer get the value of a counter.
function working_villages.villager:get_timer(timerId)
  self.time_counters = self.time_counters or {}
  return tonumber(self.time_counters[timerId]) or 0
end

-- working_villages.villager.set_timer set the value of a counter.
function working_villages.villager:set_timer(timerId,value)
  assert(type(value)=="number","timers need to be countable")
  self.time_counters = self.time_counters or {}
  self.time_counters[timerId]=value
end

-- working_villages.villager.clear_timers set all counters to 0.
function working_villages.villager:clear_timers()
  self.time_counters = self.time_counters or {}
  for timerId,_ in pairs(self.time_counters) do
    self.time_counters[timerId] = 0
  end
end

local function timer_increment(self, delta)
  return timers.increment(self, delta)
end

-- Count a historical logical step in a frame-rate independent way. Calls made
-- from on_step convert dtime using working_villages_timer_step_seconds;
-- explicit calls outside on_step retain the legacy +1 behaviour.
function working_villages.villager:count_timer(timerId, delta)
  self.time_counters = self.time_counters or {}
  if self.time_counters[timerId] == nil then
    log.info("villager %s timer %q was not initialized", self.inventory_name,timerId)
    self.time_counters[timerId] = 0
  end
  self.time_counters[timerId] = self.time_counters[timerId] + timer_increment(self, delta)
end

-- Count every initialized timer in historical logical steps.
function working_villages.villager:count_timers(delta)
  self.time_counters = self.time_counters or {}
  local increment = timer_increment(self, delta)
  for id, counter in pairs(self.time_counters) do
    self.time_counters[id] = (tonumber(counter) or 0) + increment
  end
end

-- working_villages.villager.timer_exceeded if a timer exceeds the limit it will be reset and true is returned
function working_villages.villager:timer_exceeded(timerId,limit)
  assert(type(limit) == "number", "timer limits need to be countable")
  if self:get_timer(timerId)>=limit then
    self:set_timer(timerId,0)
    return true
  else
    return false
  end
end

-- Use this variant for user-facing settings explicitly documented in seconds.
-- Most historical job thresholds use timer_exceeded and remain logical steps.
function working_villages.villager:seconds_exceeded(timerId, seconds)
  return self:timer_exceeded(timerId, timers.seconds_to_steps(seconds))
end

-- working_villages.villager.update_infotext updates the infotext of the villager.
function working_villages.villager:update_infotext()
  local lines = {}

  -- Villager name at the top if exists
  if self.nametag and self.nametag ~= "" then
    table.insert(lines, "=== " .. self.nametag .. " ===")
  else
    table.insert(lines, "=== Villageois ===")
  end

  -- Job information with icon
  local job = self:get_job()
  if job ~= nil then
    table.insert(lines, "⚒ Métier: " .. job.description)
  else
    table.insert(lines, "⚒ Métier: aucun")
    self.disp_action = "inactif"
  end

  -- Current action/status
  local action_text = self.disp_action or "inactif"
  if self.pause then
    table.insert(lines, "⏸ Statut: " .. action_text .. " (en pause)")
  else
    table.insert(lines, "▶ Statut: " .. action_text)
  end
  
  -- Owner information
  if self.owner_name and self.owner_name ~= "" then
    table.insert(lines, "👤 Propriétaire: " .. self.owner_name)
  end
  
  -- Village name if exists
  if self.village_name and self.village_name ~= "" then
    table.insert(lines, "🏘 Village: " .. self.village_name)
  end

  local infotext = table.concat(lines, "\n")
  self.object:set_properties{infotext = infotext}
end

function working_villages.villager:notify_owner(message)
  if not message or message == "" then
    return
  end
  if self.owner_name and self.owner_name ~= "" then
    minetest.chat_send_player(self.owner_name, message)
  else
    minetest.log("action", "[working_villages] %s: %s", self.inventory_name, message)
  end
end

function working_villages.villager:get_village_control()
  return working_villages.get_owner_village_control(self.owner_name)
end

function working_villages.villager:set_village_control(updates)
  return working_villages.set_owner_village_control(self.owner_name, updates)
end

local function format_villager_message(self, message)
  local speaker = self.nametag
  if not speaker or speaker == "" then
    local job = self:get_job()
    speaker = (job and job.description) or "Villageois"
  end
  return ("[%s] %s"):format(speaker, message)
end

function working_villages.villager:notify_owner_event(message, event_key, min_interval, detail_level)
  if not message or message == "" then
    return false
  end

  local control = self.get_village_control and self:get_village_control() or normalize_village_control(nil)
  local current_level = village_notification_levels[control.notify_level or "important"]
    or village_notification_levels.important
  local required_level = village_notification_levels[detail_level or "important"]
    or village_notification_levels.important
  if current_level < required_level then
    return false
  end

  self.job_data = self.job_data or {}
  self.job_data.owner_event_times = self.job_data.owner_event_times or {}

  local now = minetest.get_gametime()
  local key = event_key or message
  local interval = tonumber(min_interval) or 60
  local last_time = self.job_data.owner_event_times[key] or 0
  if now - last_time < interval then
    return false
  end
  self.job_data.owner_event_times[key] = now

  self:notify_owner(format_villager_message(self, message))
  return true
end

function working_villages.villager:notify_player_event(player_name, message, event_key, min_interval, detail_level)
  if not player_name or player_name == "" or not message or message == "" then
    return false
  end

  if player_name == self.owner_name then
    return self:notify_owner_event(message, event_key, min_interval, detail_level)
  end

  self.job_data = self.job_data or {}
  self.job_data.player_event_times = self.job_data.player_event_times or {}

  local now = minetest.get_gametime()
  local key = player_name .. ":" .. (event_key or message)
  local interval = tonumber(min_interval) or 60
  local last_time = self.job_data.player_event_times[key] or 0
  if now - last_time < interval then
    return false
  end
  self.job_data.player_event_times[key] = now

  minetest.chat_send_player(player_name, format_villager_message(self, message))
  return true
end

-- Job feature notification system
-- Notifies the player about new job features and updates
function working_villages.villager:notify_job_feature(feature_name, feature_description)
  local job = self:get_job()
  if not job then
    return
  end

  self.job_data = self.job_data or {}
  self.job_data.job_feature_notifications = self.job_data.job_feature_notifications or {}
  local job_key = self:get_job_name() or job.description or "job"
  local seen = self.job_data.job_feature_notifications[job_key]
  if not seen then
    seen = {}
    self.job_data.job_feature_notifications[job_key] = seen
  end
  if seen[feature_name] then
    return
  end
  seen[feature_name] = true

  local message = string.format(
    "[%s] 🆕 Nouvelle fonctionnalité: %s - %s",
    job.description or "Villageois",
    feature_name,
    feature_description
  )
  
  self:notify_owner(message)
end

-- Get job-specific data or capabilities
function working_villages.villager:get_job_capability(capability_name)
  local job = self:get_job()
  if not job or not job.capabilities then
    return nil
  end
  return job.capabilities[capability_name]
end

-- Check if villager has a specific job capability
function working_villages.villager:has_job_capability(capability_name)
  return self:get_job_capability(capability_name) ~= nil
end

function working_villages.villager:apply_owner_visuals()
  local vl_compat = working_villages.voxelibre_compat
  if not vl_compat or not vl_compat.is_voxelibre then
    return
  end

  local base_texture = self.base_texture
  if not base_texture and self.initial_properties and self.initial_properties.textures then
    base_texture = self.initial_properties.textures[1]
  end
  if not base_texture or base_texture == "" then
    base_texture = "villager_male.png"
  end

  local mesh = vl_compat.get_player_mesh()
  local textures = vl_compat.format_textures(mesh, base_texture)
  local owner_name = self.owner_name

  if owner_name and owner_name ~= "" and owner_name ~= "working_villages:self_employed" then
    local player = minetest.get_player_by_name(owner_name)
    local skin = player and compat.get_player_skin(player)
    if skin and skin.texture then
      mesh = compat.get_player_mesh(skin.slim_arms)
      textures = compat.format_textures(mesh, skin.texture)
    end
  end

  self.object:set_properties({mesh = mesh, textures = textures})
end

local chat_interval = tonumber(minetest.settings:get("working_villages_autonomous_chat_interval")) or 30
local chat_message_queue = {}  -- Queue for villager messages to avoid spam

-- Clean up old messages from queue periodically
local function clean_message_queue()
  local now = minetest.get_gametime()
  for key, time in pairs(chat_message_queue) do
    if now - time > 120 then  -- Remove messages older than 2 minutes
      chat_message_queue[key] = nil
    end
  end
end

-- Check if a similar message was recently sent
local function is_message_in_queue(message)
  local now = minetest.get_gametime()
  local key = message:lower():gsub("%s+", " ")  -- Normalize message
  if chat_message_queue[key] and (now - chat_message_queue[key]) < 60 then
    return true
  end
  return false
end

-- Add message to queue
local function add_message_to_queue(message)
  local key = message:lower():gsub("%s+", " ")
  chat_message_queue[key] = minetest.get_gametime()
end

--[[
  Makes the villager speak in global chat with spam prevention.
  
  Features:
  - Only speaks when a player is nearby (within 16 blocks)
  - Respects minimum interval between messages (default 30s)
  - Prevents duplicate messages (2x interval)
  - Global message queue to prevent spam from multiple villagers
  
  @param message string - The message to say
  @param min_interval number - Optional minimum interval between messages (default: setting or 30s)
  @return boolean - true if message was sent, false otherwise
]]--
function working_villages.villager:say(message, min_interval)
  if not message or message == "" then
    return false
  end

  local player, _, _ = self:get_nearest_player(16)
  if not player then
    return false
  end

  local now = minetest.get_gametime()
  local interval = min_interval or chat_interval
  
  -- Check personal cooldown
  if self.last_chat_time and (now - self.last_chat_time) < interval then
    return false
  end
  
  -- Check for duplicate message (longer cooldown)
  if self.last_chat_message == message and self.last_chat_time and (now - self.last_chat_time) < (interval * 2) then
    return false
  end
  
  -- Check global message queue to prevent spam from multiple villagers
  if is_message_in_queue(message) then
    return false
  end

  self.last_chat_time = now
  self.last_chat_message = message

  local name = self.nametag
  if not name or name == "" then
    local job = self:get_job()
    if job then
      name = job.description
    else
      name = "Villageois"
    end
  end
  
  minetest.chat_send_all(name .. ": " .. message)
  add_message_to_queue(message)
  
  -- Periodic cleanup
  if math.random(100) < 5 then  -- 5% chance
    clean_message_queue()
  end
  
  return true
end

--[[
  Announces the villager's current action in chat.
  
  Automatically generates appropriate messages based on the villager's state_info.
  This function should be called by jobs to keep players informed of what villagers are doing.
  
  @param custom_message string - Optional custom message, otherwise uses state_info
  @param min_interval number - Optional minimum interval between announcements (default: 60s)
  @return boolean - true if announcement was made, false otherwise
]]--
function working_villages.villager:announce_action(custom_message, min_interval)
  local message = custom_message or self.state_info
  if not message or message == "" then
    return false
  end
  
  -- Use longer interval for action announcements to reduce spam
  local interval = min_interval or (chat_interval * 2)
  return self:say(message, interval)
end

-- working_villages.villager.is_near checks if the villager is within the radius of a position
function working_villages.villager:is_near(pos, distance)
  local p = self.object:get_pos()
  p.y = p.y + 0.5
  return vector.distance(p, pos) < distance
end

function working_villages.villager:handle_liquids()
  local ctrl = self.object
  local inside_node = minetest.get_node(self.object:get_pos())
  -- perhaps only when changed
  if minetest.get_item_group(inside_node.name,"liquid") > 0 then
    -- swim
    local viscosity = minetest.registered_nodes[inside_node.name].liquid_viscosity
    ctrl:set_acceleration{x = 0, y = -self.initial_properties.weight/(100*viscosity), z = 0}
  elseif minetest.registered_nodes[inside_node.name].climbable then
    --go down slowly
    ctrl:set_acceleration{x = 0, y = -0.1, z = 0}
  else
    -- fall
    ctrl:set_acceleration{x = 0, y = -self.initial_properties.weight, z = 0}
  end
end

function working_villages.villager:jump()
  local ctrl = self.object
  local below_node = minetest.get_node(vector.subtract(ctrl:get_pos(),{x=0,y=1,z=0}))
  local velocity = ctrl:get_velocity()
  if below_node.name == "air" then return false end
  local jump_force = math.sqrt(self.initial_properties.weight) * 1.5
  if minetest.get_item_group(below_node.name,"liquid") > 0 then
    local viscosity = minetest.registered_nodes[below_node.name].liquid_viscosity
    jump_force = jump_force/(viscosity*100)
  end
  ctrl:set_velocity{x = velocity.x, y = jump_force, z = velocity.z}
end

local function make_fake_player(self)
  return {
    is_player = function() return true end,
    get_player_name = function() return self.owner_name or "working_villages" end,
    get_player_control = function() return {sneak = true} end,
    get_inventory = function()
      return self:get_inventory()
    end,
    get_pos = function()
      if self.object then
        return self.object:get_pos()
      end
      return {x = 0, y = 0, z = 0}
    end,
    get_look_dir = function()
      local yaw = self.object and self.object:get_yaw() or 0
      return minetest.yaw_to_dir(yaw)
    end,
    get_wielded_item = function()
      return self:get_wield_item_stack()
    end,
  }
end

local function animate_chest_for_villager(self, pos)
  local chests_api = rawget(_G, "mcl_chests")
  if type(chests_api) ~= "table" or type(chests_api.select_and_spawn_entity) ~= "function" then
    return false
  end
  local node = minetest.get_node_or_nil(pos)
  if not node or type(node.name) ~= "string" then
    return false
  end
  if not node.name:find("^mcl_chests:") then
    return false
  end
  local def = minetest.registered_nodes[node.name]
  if not def or not def._chest_entity_mesh or not def._chest_entity_textures then
    return false
  end
  local entity = chests_api.select_and_spawn_entity(pos, node)
  if not entity then
    return false
  end
  if not entity.set_animation then
    return false
  end
  self._last_chest_anim = self._last_chest_anim or {}
  local key = minetest.hash_node_position(pos)
  local now = minetest.get_gametime()
  if self._last_chest_anim[key] and (now - self._last_chest_anim[key]) < 3 then
    return true
  end
  self._last_chest_anim[key] = now
  entity:set_animation("open")
  minetest.after(1.0, function()
    local refreshed = chests_api.select_and_spawn_entity(pos, node)
    if refreshed and refreshed.set_animation then
      refreshed:set_animation("close")
    end
  end)
  return true
end

function working_villages.villager:use_node(pos)
  local node = minetest.get_node(pos)
  local def = minetest.registered_nodes[node.name]
  if not def or not def.on_rightclick then
    return false
  end
  local now = minetest.get_gametime()
  local key = minetest.hash_node_position(pos)
  if self._last_node_use and self._last_node_use.key == key and (now - self._last_node_use.time) < 1 then
    return false
  end
  self._last_node_use = {key = key, time = now}
  if is_chest_pos(pos) then
    animate_chest_for_villager(self, pos)
    return true
  end
  local user = make_fake_player(self)
  local itemstack = user:get_wielded_item() or ItemStack("")
  def.on_rightclick(pos, node, user, itemstack, {type = "node", under = pos, above = pos})
  return true
end

function working_villages.villager:use_wield_on_node(under_pos, above_pos)
  if not under_pos or not above_pos then
    return false
  end
  local stack = self:get_wield_item_stack()
  if not stack or stack:is_empty() then
    return false
  end
  local def = stack:get_definition()
  if not def or (type(def.on_place) ~= "function"
      and type(def.on_secondary_use) ~= "function"
      and type(def.on_use) ~= "function") then
    return false
  end
  local user = make_fake_player(self)
  local pointed = {type = "node", under = under_pos, above = above_pos}
  local before_under = minetest.get_node(under_pos).name
  local before_above = minetest.get_node(above_pos).name
  local new_stack = nil
  -- Minetest Game hoes expose their real till action through `on_use`, while
  -- VoxeLibre hoes expose it through `on_place`. Item definitions may still
  -- inherit a generic callback for the other action, so mere presence is not
  -- enough to choose the correct one: prefer the active profile's native API.
  local vl_compat = working_villages.voxelibre_compat
  if vl_compat and not vl_compat.is_voxelibre and type(def.on_use) == "function" then
    new_stack = def.on_use(stack, user, pointed)
  elseif type(def.on_place) == "function" then
    new_stack = def.on_place(stack, user, pointed)
  elseif type(def.on_secondary_use) == "function" then
    new_stack = def.on_secondary_use(stack, user, pointed)
  elseif type(def.on_use) == "function" then
    new_stack = def.on_use(stack, user, pointed)
  end
  if new_stack and new_stack.is_empty and new_stack:get_name() then
    self:set_wield_item_stack(new_stack)
  end
  return minetest.get_node(under_pos).name ~= before_under
    or minetest.get_node(above_pos).name ~= before_above
end

local VOXELIBRE_DOOR_CLOSE_TIMEOUT = 8
local VOXELIBRE_DOOR_CLOSE_MAX_ATTEMPTS = 3
local VOXELIBRE_PENDING_DOOR_LIMIT = 4

local function voxelibre_door_open_state(pos)
  if not working_villages.voxelibre_compat.is_voxelibre then
    return false
  end
  local node = minetest.get_node_or_nil(pos)
  if not node then
    return nil
  end
  if not working_villages.voxelibre_compat.is_door(node.name) then
    return false
  end
  return minetest.get_meta(pos):get_int("is_open") == 1
end

local function remember_opened_voxelibre_door(self, pos, direction, now)
  local rounded = vector.round(pos)
  local key = minetest.hash_node_position(rounded)
  local pending = self._pending_voxelibre_doors or {}
  self._pending_voxelibre_doors = pending

  if not pending[key] then
    local count = 0
    local oldest_key = nil
    local oldest_time = nil
    for existing_key, entry in pairs(pending) do
      count = count + 1
      if not oldest_time or (entry.opened_at or 0) < oldest_time then
        oldest_key = existing_key
        oldest_time = entry.opened_at or 0
      end
    end
    if count >= VOXELIBRE_PENDING_DOOR_LIMIT and oldest_key then
      pending[oldest_key] = nil
    end
  end

  pending[key] = {
    pos = rounded,
    direction = {x = direction.x or 0, y = 0, z = direction.z or 0},
    opened_at = now,
    next_attempt_at = now + 1,
    expires_at = now + VOXELIBRE_DOOR_CLOSE_TIMEOUT,
    attempts = 0,
  }
end

local function close_traversed_voxelibre_doors(self)
  local pending = self._pending_voxelibre_doors
  if type(pending) ~= "table" then
    return
  end
  local now = minetest.get_gametime()
  local current_pos = self.object and self.object:get_pos() or nil
  for key, entry in pairs(pending) do
    if type(entry) ~= "table" or not entry.pos or now > (entry.expires_at or 0) then
      pending[key] = nil
    else
      local open_state = voxelibre_door_open_state(entry.pos)
      if open_state == false then
        pending[key] = nil
      elseif open_state == true and current_pos and now >= (entry.next_attempt_at or 0) then
        local direction = entry.direction or {}
        local crossed = ((current_pos.x - entry.pos.x) * (direction.x or 0)) +
          ((current_pos.z - entry.pos.z) * (direction.z or 0)) > 0.35
        if crossed then
          entry.attempts = (entry.attempts or 0) + 1
          entry.next_attempt_at = now + 1
          local callback_ok = pcall(self.use_node, self, entry.pos)
          if voxelibre_door_open_state(entry.pos) == false or
              entry.attempts >= VOXELIBRE_DOOR_CLOSE_MAX_ATTEMPTS then
            pending[key] = nil
          elseif not callback_ok then
            -- Keep the bounded retry state; a transient game callback failure
            -- must not abort the villager's movement callback.
            pending[key] = entry
          end
        end
      end
    end
  end
  if next(pending) == nil then
    self._pending_voxelibre_doors = nil
  end
end

--working_villages.villager.handle_obstacles(ignore_fence,ignore_doors)
--if the villager hits a walkable he wil jump
--if ignore_fence is false the villager will not jump over fences
--if ignore_doors is false and the villager hits a door he opens it
function working_villages.villager:handle_obstacles(ignore_fence,ignore_doors)
  local velocity = self.object:get_velocity()
  local front_diff = self:get_look_direction()
  for i,v in pairs(front_diff) do
    local front_pos = vector.new(0,0,0)
    front_pos[i] = v
    front_pos = vector.add(front_pos, vector.round(self.object:get_pos()))
    front_pos.y = math.floor(self.object:get_pos().y)+0.5
    local above_node = vector.new(front_pos)
    local front_node = minetest.get_node(front_pos)
    above_node = vector.add(above_node,{x=0,y=1,z=0})
    above_node = minetest.get_node(above_node)
    local front_def = minetest.registered_nodes[front_node.name]
    local above_def = minetest.registered_nodes[above_node.name]
    if minetest.get_item_group(front_node.name, "fence") > 0 and not(ignore_fence) then
      self:change_direction_randomly()
    elseif not ignore_doors and (
      working_villages.voxelibre_compat.is_door(front_node.name)
      or minetest.get_item_group(front_node.name, "trapdoor") > 0
      or minetest.get_item_group(front_node.name, "fence_gate") > 0
    ) then
      local doors_mod = rawget(_G, "doors")
      if doors_mod and doors_mod.get and working_villages.voxelibre_compat.is_door(front_node.name) then
        local door = doors_mod.get(front_pos)
        local door_dir = vector.apply(minetest.facedir_to_dir(front_node.param2),math.abs)
        local villager_dir = vector.round(vector.apply(front_diff,math.abs))
        if door and type(door.state) == "function" and
            vector.equals(door_dir,villager_dir) then
          if door:state() then
            if type(door.close) == "function" then door:close() end
          elseif type(door.open) == "function" then
            door:open()
          end
        end
      else
        local was_open = voxelibre_door_open_state(front_pos)
        local used = self:use_node(front_pos)
        if used and was_open == false and
            voxelibre_door_open_state(front_pos) == true then
          remember_opened_voxelibre_door(
            self, front_pos, front_diff, minetest.get_gametime())
        end
      end
    elseif front_def and above_def and front_def.walkable
      and not above_def.walkable then
      if velocity.y == 0 then
        local def = minetest.registered_nodes[front_node.name]
        local nBox = def and def.node_box
        if not nBox or not nBox.fixed then
          nBox = {{-0.5,-0.5,-0.5,0.5,0.5,0.5}}
        else
          nBox = nBox.fixed
        end
        if type(nBox[1]) == "number" then
          nBox = {nBox}
        end
        if type(nBox) == "table" then
          for _, box in pairs(nBox) do --TODO: check rotation of the nodebox
            if type(box) == "table" then
              local nHeight = (box[5] - box[2]) + front_pos.y
              if nHeight > self.object:get_pos().y + .5 then
                self:jump()
              end
            end
          end
        end
      end
    end
  end
  if not ignore_doors then
    local back_pos = self:get_back()
    local back_node = minetest.get_node(back_pos)
    if working_villages.voxelibre_compat.is_door(back_node.name) then
      local doors_mod = rawget(_G, "doors")
      if doors_mod and doors_mod.get then
        local door = doors_mod.get(back_pos)
        if door and type(door.close) == "function" then
          door:close()
        end
      end
    end
    close_traversed_voxelibre_doors(self)
  end
end

-- working_villages.villager.pickup_item pickup items placed and put it to main slot.
function working_villages.villager:pickup_item()
  local pos = self.object:get_pos()
  local radius = 1.0
  local all_objects = minetest.get_objects_inside_radius(pos, radius)

  for _, obj in ipairs(all_objects) do
    if not obj:is_player() and obj:get_luaentity() and obj:get_luaentity().itemstring then
      local itemstring = obj:get_luaentity().itemstring
      local stack = ItemStack(itemstring)
      if stack and stack:to_table() then
        local name = stack:to_table().name

        if minetest.registered_items[name] ~= nil then
          local inv = self:get_inventory()
          local leftover = inv:add_item("main", stack)

          minetest.add_item(obj:get_pos(), leftover)
          obj:get_luaentity().itemstring = ""
          obj:remove()
        end
      end
    end
  end
end

local function pick_eat_sound()
  if minetest.get_modpath("default") then
    return "default_eat"
  end
  if minetest.get_modpath("mcl_sounds") then
    return "mcl_sounds_eat"
  end
  return nil
end

function working_villages.villager:find_food_in_inventory()
  local inv = self:get_inventory()
  for i = 1, inv:get_size("main") do
    local stack = inv:get_stack("main", i)
    if not stack:is_empty() and minetest.get_item_group(stack:get_name(), "food") > 0 then
      return i, stack
    end
  end
  return nil, nil
end

function working_villages.villager:try_eat_food()
  local idx, stack = self:find_food_in_inventory()
  if not idx then
    return false
  end
  local eaten_name = stack:get_name()
  stack:take_item(1)
  self:get_inventory():set_stack("main", idx, stack)
  working_villages.needs.adjust(self, "hunger", 25)
  self.job_data = self.job_data or {}
  self.job_data.eating_ticks = 20
  self.job_data.eating_item_name = eaten_name
  self:set_displayed_action("mange")
  self:set_state_info("Je mange.")
  local sound = pick_eat_sound()
  if sound then
    minetest.sound_play(sound, {object = self.object, max_hear_distance = 10})
  end
  return true
end

function working_villages.villager:is_hunt_target(obj)
  if not obj or obj == self.object then
    return false
  end
  if obj:is_player() then
    return false
  end
  local luaentity = obj:get_luaentity()
  if not luaentity or not luaentity.name then
    return false
  end
  if working_villages.is_villager(luaentity.name) then
    return false
  end
  local lname = luaentity.name
  if lname:find("horse") or lname:find("donkey") or lname:find("mule") then
    return false
  end
  local mobs_api = rawget(_G, "mcl_mobs")
  if mobs_api and mobs_api.registered_mobs then
    local def = mobs_api.registered_mobs[lname]
    if def and (def.type == "animal" or def.spawn_class == "passive") then
      return true
    end
  end
  if luaentity.type == "animal" or luaentity.spawn_class == "passive" then
    return true
  end
  if lname:find("mobs_animal:") then
    return true
  end
  return false
end

-- working_villages.villager.move_main_to_offhand moves itemstack from main to offhand.
function working_villages.villager:move_main_to_offhand(pred)
  local inv = self:get_inventory()
  local main_size = inv:get_size("main")

  for i = 1, main_size do
    local stack = inv:get_stack("main", i)
    if pred(stack:get_name()) then
      local offhand_stack = inv:get_stack("offhand", 1)
      inv:set_stack("offhand", 1, stack)
      inv:remove_item("main", stack)
      inv:add_item("main", offhand_stack)
      return true
    end
  end
  return false
end

function working_villages.villager:get_nearest_animal(range_distance)
  local min_distance = range_distance
  local target
  local position = self.object:get_pos()
  local all_objects = minetest.get_objects_inside_radius(position, range_distance)
  for _, object in pairs(all_objects) do
    if self:is_hunt_target(object) then
      local distance = vector.distance(position, object:get_pos())
      if distance < min_distance then
        min_distance = distance
        target = object
      end
    end
  end
  return target
end

local function find_near_furnace(pos, radius)
  local minp = vector.subtract(pos, radius)
  local maxp = vector.add(pos, radius)
  local nodes = minetest.find_nodes_in_area(minp, maxp, {"group:furnace"})
  if #nodes > 0 then
    return nodes[1]
  end
  return nil
end

function working_villages.villager:try_cook_food()
	if working_villages.is_survival_mode and working_villages.is_survival_mode() then
		-- Survival cooking is performed by the cook job through a real furnace,
		-- with source, destination and fuel inventories managed by that node.
		return false
	end
  local inv = self:get_inventory()
  local furnace_pos = find_near_furnace(self.object:get_pos(), 4)
  if not furnace_pos then
    return false
  end
  for i = 1, inv:get_size("main") do
    local stack = inv:get_stack("main", i)
    if not stack:is_empty() then
      local name = stack:get_name()
      if minetest.get_item_group(name, "food_raw") > 0 then
        local cooked = minetest.get_craft_result({
          method = "cooking",
          width = 1,
          items = {stack},
        })
        if cooked and cooked.item and not cooked.item:is_empty() then
          stack:take_item(1)
          inv:set_stack("main", i, stack)
          local leftover = inv:add_item("main", cooked.item)
          if not leftover:is_empty() then
            minetest.add_item(self.object:get_pos(), leftover)
          end
          self:set_displayed_action("cuisine")
          self:set_state_info("Je cuisine la nourriture.")
          return true
        end
      end
    end
  end
  return false
end
-- working_villages.villager.get_job_data get a job data field
function working_villages.villager:get_job_data(key)
  local actual_job_data = self.job_data[self:get_job_name()]
  if actual_job_data == nil then
    return nil
  end
  return actual_job_data[key]
end

-- working_villages.villager.set_job_data set a job data field
function working_villages.villager:set_job_data(key, value)
  local actual_job_data = self.job_data[self:get_job_name()]
  if actual_job_data == nil then
    actual_job_data = {}
    self.job_data[self:get_job_name()] = actual_job_data
  end
  actual_job_data[key] = value
end

-- working_villages.villager:new returns a new villager object.
function working_villages.villager:new(o)
  return setmetatable(o or {}, {__index = self})
end

working_villages.require("villager_state")

local legacy_api_warnings = {}

local function warn_legacy_api(key, message)
  if legacy_api_warnings[key] then
    return
  end
  legacy_api_warnings[key] = true
  log.warning(message)
end

-- Legacy compatibility wrapper. Prefer checking self.pause directly.
function working_villages.villager:is_active()
  warn_legacy_api("is_active", "self:is_active() est obsolete, utilisez `not self.pause`.")
  return not self.pause
end

-- Legacy compatibility wrapper. Prefer set_pause(true) and set_displayed_action().
function working_villages.villager:set_paused(reason)
  warn_legacy_api("set_paused", "self:set_paused() est obsolete, utilisez self:set_pause().")
  self:set_pause(true)
  self:set_displayed_action(reason or "repos")
end

working_villages.require("async_actions")

-- compatibility with like player object
function working_villages.villager:get_player_name()
  return self.object:get_player_name()
end

function working_villages.villager:is_player()
  return false
end

function working_villages.villager:get_wield_index()
  return 1
end

-- Legacy state wrapper kept for old job helpers.
function working_villages.villager:set_state(id)
  if id == "idle" then
    warn_legacy_api("set_state:idle", "self:set_state(\"idle\") est obsolete.")
  elseif id == "goto_dest" then
    warn_legacy_api("set_state:goto_dest", "Utilisez self:go_to(pos) au lieu de self:set_state(\"goto_dest\").")
    self:go_to(self.destination)
  elseif id == "job" then
    warn_legacy_api("set_state:job", "self:set_state(\"job\") n'est plus necessaire.")
  elseif id == "dig_target" then
    warn_legacy_api("set_state:dig_target", "Utilisez self:dig(pos, collect_drops) au lieu de self:set_state(\"dig_target\").")
    self:dig(self.target,true)
  elseif id == "place_wield" then
    warn_legacy_api("set_state:place_wield", "Utilisez self:place(itemname, pos) au lieu de self:set_state(\"place_wield\").")
    local wield_stack = self:get_wield_item_stack()
    self:place(wield_stack:get_name(),self.target)
  end
end

---------------------------------------------------------------------

-- Monotonic villager identifiers. The historical implementation only wrote
-- this counter during a clean shutdown, so a crash could reuse an inventory
-- name. ModStorage is committed immediately after every allocation.
local manufacturing_storage = minetest.get_mod_storage()
local manufacturing_storage_key = "manufacturing_data_v2"

local function load_manufacturing_data()
  local encoded = manufacturing_storage:get_string(manufacturing_storage_key)
  if encoded ~= "" then
    local decoded = minetest.deserialize(encoded)
    if type(decoded) == "table" then
      return decoded
    end
  end

  -- Read the old world file once as a migration source. It is intentionally
  -- left untouched so world owners retain a recovery artefact.
  local legacy_file = io.open(minetest.get_worldpath() .. "/working_villages_data", "r")
  if legacy_file then
    local decoded = minetest.deserialize(legacy_file:read("*a"))
    legacy_file:close()
    if type(decoded) == "table" then
      manufacturing_storage:set_string(manufacturing_storage_key, minetest.serialize(decoded))
      return decoded
    end
  end
  return {}
end

working_villages.manufacturing_data = load_manufacturing_data()

local function persist_manufacturing_data()
  manufacturing_storage:set_string(
    manufacturing_storage_key,
    minetest.serialize(working_villages.manufacturing_data))
end

local function reserve_manufacturing_number(product_name)
  local next_number = math.max(0, math.floor(tonumber(
    working_villages.manufacturing_data[product_name]) or 0))
  working_villages.manufacturing_data[product_name] = next_number + 1
  persist_manufacturing_data()
  return next_number
end

local function observe_manufacturing_number(product_name, number)
  number = math.max(0, math.floor(tonumber(number) or 0))
  local current = math.max(0, math.floor(tonumber(
    working_villages.manufacturing_data[product_name]) or 0))
  if current <= number then
    working_villages.manufacturing_data[product_name] = number + 1
    persist_manufacturing_data()
  end
end

--------------------------------------------------------------------

working_villages.is_voxelibre_armor_mesh = function(mesh_name)
  return mesh_name == "mcl_armor_character.b3d" or
    mesh_name == "mcl_armor_character_female.b3d"
end

-- register empty item entity definition.
-- this entity may be hold by villager's hands.
do
  minetest.register_craftitem("working_villages:dummy_empty_craftitem", {
    wield_image = "working_villages_dummy_empty_craftitem.png",
  })

  -- Configuration for item and armor display positioning
  -- These values control how items and armor appear when attached to villager bones
  local WIELD_ITEM_POSITION = {x = 0.0, y = 0.35, z = 0.25}
  local WIELD_ITEM_ROTATION = {x = -90, y = 45, z = 0}
  local WIELD_ITEM_POSITION_VL = {x = 0.0, y = 0.0, z = 0.0}
  local WIELD_ITEM_ROTATION_VL = {x = 0, y = 0, z = 0}
  local OFFHAND_ITEM_POSITION = {x = -0.2, y = 0.35, z = 0.25}
  local OFFHAND_ITEM_ROTATION = {x = -90, y = -45, z = 0}
  local OFFHAND_ITEM_POSITION_VL = {x = 0.0, y = 0.0, z = 0.0}
  local OFFHAND_ITEM_ROTATION_VL = {x = 0, y = 0, z = 0}
  local HEAD_POSITION = {x = 0, y = 0.70, z = 0}
  
  --[[
    Armor slot configuration: bone name, position offset, and visual size
    
    This table defines how armor pieces are displayed on villagers:
    - bone: The skeleton bone to attach the armor entity to
    - position: Offset from the bone position for proper placement
    - size: Visual scale of the armor piece
    
    Armor is displayed using PNG textures of the armor items via dummy entities.
    The dummy entities show the inventory image/wield image of armor items.
    This works in both minetest_game (with 3d_armor) and VoxeLibre (with mcl_armor).
  ]]--
  local ARMOR_SLOT_CONFIG = {
    head = {bone = "Head", position = {x = 0, y = 0.70, z = 0}, size = {x = 0.3, y = 0.3}},
    torso = {bone = "Body", position = {x = 0, y = 0.35, z = 0}, size = {x = 0.4, y = 0.4}},
    legs = {bone = "Body", position = {x = 0, y = -0.15, z = 0}, size = {x = 0.35, y = 0.35}},
    feet = {bone = "Body", position = {x = 0, y = -0.55, z = 0}, size = {x = 0.3, y = 0.3}},
  }

  local function select_wield_bone(obj)
    local candidates = { "Wield_Item", "Hand_Right", "Arm_Right", "Arm_R" }
    if obj.get_bone_override then
      for _, bone in ipairs(candidates) do
        if obj:get_bone_override(bone) then
          return bone
        end
      end
    elseif obj.get_bone_position then
      for _, bone in ipairs(candidates) do
        if obj:get_bone_position(bone) then
          return bone
        end
      end
    end
    return "Arm_R"
  end

  local function select_offhand_bone(obj)
    local candidates = { "Wield_Item_L", "Hand_Left", "Hand_L", "Arm_Left", "Arm_L" }
    if obj.get_bone_override then
      for _, bone in ipairs(candidates) do
        if obj:get_bone_override(bone) then
          return bone
        end
      end
    elseif obj.get_bone_position then
      for _, bone in ipairs(candidates) do
        if obj:get_bone_position(bone) then
          return bone
        end
      end
    end
    return "Wield_Item"
  end

  local function get_wield_transform(obj, bone)
    if bone == "Wield_Item" then
      return {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0}
    end
    local props = obj:get_properties()
    if props and working_villages.is_voxelibre_armor_mesh(props.mesh) then
      return WIELD_ITEM_POSITION_VL, WIELD_ITEM_ROTATION_VL
    end
    return WIELD_ITEM_POSITION, WIELD_ITEM_ROTATION
  end

  local function get_offhand_transform(obj, bone)
    if bone == "Wield_Item_L" or bone == "Wield_Item" then
      return {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0}
    end
    local props = obj:get_properties()
    if props and working_villages.is_voxelibre_armor_mesh(props.mesh) then
      return OFFHAND_ITEM_POSITION_VL, OFFHAND_ITEM_ROTATION_VL
    end
    return OFFHAND_ITEM_POSITION, OFFHAND_ITEM_ROTATION
  end

    local function select_head_bone(obj)
      if obj.get_bone_override then
        local candidates = { "Head", "Head2", "Head_R", "Head_L" }
        for _, bone in ipairs(candidates) do
          if obj:get_bone_override(bone) then
            return bone
          end
        end
      elseif obj.get_bone_position then
        local candidates = { "Head", "Head2", "Head_R", "Head_L" }
        for _, bone in ipairs(candidates) do
          if obj:get_bone_position(bone) then
            return bone
          end
        end
      end
      return "Head"
    end

    local function select_body_bone(obj)
      local candidates = { "Body", "Torso", "UpperBody", "LowerBody", "Spine", "Pelvis" }
      if obj.get_bone_override then
        for _, bone in ipairs(candidates) do
          if obj:get_bone_override(bone) then
            return bone
          end
        end
      elseif obj.get_bone_position then
        for _, bone in ipairs(candidates) do
          if obj:get_bone_position(bone) then
            return bone
          end
        end
      end
      return ""
    end

  local function on_activate(self)
    -- attach to the nearest villager.
    local all_objects = minetest.get_objects_inside_radius(self.object:get_pos(), 0.1)
    for _, obj in ipairs(all_objects) do
      local luaentity = obj:get_luaentity()

      if luaentity and working_villages.is_villager(luaentity.name) then
        local bone = select_wield_bone(obj)
        local pos_offset, rot_offset = get_wield_transform(obj, bone)
        -- Improved position: moved forward and rotated to appear in hand naturally
        self.object:set_attach(obj, bone, pos_offset, rot_offset)
        self.object:set_properties{wield_item="", is_visible=false}
        return
      end
    end
  end

  local function on_step(self)
    local all_objects = minetest.get_objects_inside_radius(self.object:get_pos(), 0.1)
    for _, obj in ipairs(all_objects) do
      local luaentity = obj:get_luaentity()

      if luaentity and working_villages.is_villager(luaentity.name) then
        local stack = luaentity:get_wield_item_stack()

        local item = stack:get_name()
        if not stack:is_empty() then
          local def = stack:get_definition()
          if def and def._mcl_wieldview_item then
            item = def._mcl_wieldview_item
          end
        end

        if item ~= self.itemname then
          self.itemname = item
          if item == "" then
            self.object:set_properties{wield_item="", is_visible=false}
          else
            self.object:set_properties{wield_item=item, is_visible=true}
          end
        end
        return
      end
    end
    -- if cannot find villager, delete empty item.
    self.object:remove()
    return
  end

  local function on_activate_offhand(self)
    local all_objects = minetest.get_objects_inside_radius(self.object:get_pos(), 0.1)
    for _, obj in ipairs(all_objects) do
      local luaentity = obj:get_luaentity()

      if luaentity and working_villages.is_villager(luaentity.name) then
        local bone = select_offhand_bone(obj)
        local pos_offset, rot_offset = get_offhand_transform(obj, bone)
        self.object:set_attach(obj, bone, pos_offset, rot_offset)
        self.object:set_properties{wield_item="", is_visible=false}
        return
      end
    end
  end

  local function on_step_offhand(self)
    local all_objects = minetest.get_objects_inside_radius(self.object:get_pos(), 0.1)
    for _, obj in ipairs(all_objects) do
      local luaentity = obj:get_luaentity()

      if luaentity and working_villages.is_villager(luaentity.name) then
        local stack = luaentity:get_offhand_item_stack()
        local item = stack:get_name()
        if not stack:is_empty() then
          local def = stack:get_definition()
          if def and def._mcl_wieldview_item then
            item = def._mcl_wieldview_item
          end
        end

        if item ~= self.itemname then
          self.itemname = item
          if item == "" then
            self.object:set_properties{wield_item="", is_visible=false}
          else
            self.object:set_properties{wield_item=item, is_visible=true}
          end
        end
        return
      end
    end
    self.object:remove()
    return
  end

  local function on_activate_head(self)
    local all_objects = minetest.get_objects_inside_radius(self.object:get_pos(), 0.1)
    for _, obj in ipairs(all_objects) do
      local luaentity = obj:get_luaentity()

      if luaentity and working_villages.is_villager(luaentity.name) then
        local bone = select_head_bone(obj)
        self.object:set_attach(obj, bone, HEAD_POSITION, {x = 0, y = 0, z = 0})
        self.object:set_properties{textures={"working_villages:dummy_empty_craftitem"}}
        return
      end
    end
  end

  local function on_step_head(self)
    local all_objects = minetest.get_objects_inside_radius(self.object:get_pos(), 0.1)
    for _, obj in ipairs(all_objects) do
      local luaentity = obj:get_luaentity()

      if luaentity and working_villages.is_villager(luaentity.name) then
        local stack = luaentity:get_head_item_stack()

        if stack:get_name() ~= self.itemname then
          if stack:is_empty() then
            self.itemname = ""
            self.object:set_properties{textures={"working_villages:dummy_empty_craftitem"}}
          else
            self.itemname = stack:get_name()
            self.object:set_properties{textures={self.itemname}}
          end
        end
        return
      end
    end
    self.object:remove()
  end

  minetest.register_entity("working_villages:dummy_item", {
    initial_properties = {
      hp_max		    = 1,
      visual		    = "wielditem",
      visual_size	  = {x = 0.25, y = 0.25},
      collisionbox	= {0, 0, 0, 0, 0, 0},
      physical	    = false,
      textures	    = {"air"},
      is_visible   = false,
      static_save  = false,
    },
    on_activate	  = on_activate,
    on_step       = on_step,
    itemname      = "",
  })

  minetest.register_entity("working_villages:dummy_offhand", {
    initial_properties = {
      hp_max		    = 1,
      visual		    = "wielditem",
      visual_size	  = {x = 0.25, y = 0.25},
      collisionbox	= {0, 0, 0, 0, 0, 0},
      physical	    = false,
      textures	    = {"air"},
      is_visible   = false,
      static_save  = false,
    },
    on_activate	  = on_activate_offhand,
    on_step       = on_step_offhand,
    itemname      = "",
  })

  minetest.register_entity("working_villages:dummy_head", {
    initial_properties = {
      hp_max		    = 1,
      visual		    = "wielditem",
      visual_size	  = {x = 0.3, y = 0.3},
      collisionbox	= {0, 0, 0, 0, 0, 0},
      physical	    = false,
      textures	    = {"air"},
      static_save  = false,
    },
    on_activate	  = on_activate_head,
    on_step       = on_step_head,
    itemname      = "",
  })

  local function get_armor_display_texture(stack)
    if not stack or stack:is_empty() then
      return "working_villages_dummy_empty_craftitem.png"
    end

    local def = stack:get_definition()
    if def then
      local mcl_tex = def._mcl_armor_texture
      if type(mcl_tex) == "function" then
        local ok, tex = pcall(mcl_tex, nil, stack)
        if ok and tex and tex ~= "" then
          return tex
        end
      elseif type(mcl_tex) == "string" and mcl_tex ~= "" then
        return mcl_tex
      end
      if def.armor_texture and def.armor_texture ~= "" then
        return def.armor_texture
      end
      if def.texture and def.texture ~= "" then
        return def.texture
      end
      if def.wield_image and def.wield_image ~= "" then
        return def.wield_image
      end
      if def.inventory_image and def.inventory_image ~= "" then
        return def.inventory_image
      end
    end

    return "working_villages_dummy_empty_craftitem.png"
  end

  -- Armor display entities for visual feedback
  local function create_armor_entity(slot_name, bone_name, pos_offset, size)
    local function on_activate_armor(self)
      local all_objects = minetest.get_objects_inside_radius(self.object:get_pos(), 0.5)
      for _, obj in ipairs(all_objects) do
        local luaentity = obj:get_luaentity()
        if luaentity and working_villages.is_villager(luaentity.name) then
          local bone
          if slot_name == "head" then
            bone = select_head_bone(obj)
          else
            bone = select_body_bone(obj)
          end
          self.object:set_attach(obj, bone, pos_offset, {x = 0, y = 0, z = 0})
          self.object:set_properties{textures={"working_villages_dummy_empty_craftitem.png"}}
          return
        end
      end
    end

    local function on_step_armor(self)
      local all_objects = minetest.get_objects_inside_radius(self.object:get_pos(), 0.5)
      for _, obj in ipairs(all_objects) do
        local luaentity = obj:get_luaentity()
        if luaentity and working_villages.is_villager(luaentity.name) then
          if self.object:get_attach() ~= obj then
            local bone
            if slot_name == "head" then
              bone = select_head_bone(obj)
            else
              bone = select_body_bone(obj)
            end
            self.object:set_attach(obj, bone, pos_offset, {x = 0, y = 0, z = 0})
          end
          local stack = luaentity:get_armor_stack(slot_name)
          local stack_key = stack:to_string()
          if stack_key ~= self.armor_stack_key then
            self.armor_stack_key = stack_key
            self.object:set_properties{textures={get_armor_display_texture(stack)}}
          end
          return
        end
      end
      self.object:remove()
    end

    minetest.register_entity("working_villages:dummy_armor_" .. slot_name, {
      initial_properties = {
        hp_max		    = 1,
        visual		    = "sprite",
        visual_size	  = size,
        collisionbox	= {0, 0, 0, 0, 0, 0},
        physical	    = false,
        textures	    = {"working_villages_dummy_empty_craftitem.png"},
        static_save  = false,
      },
      on_activate	  = on_activate_armor,
      on_step       = on_step_armor,
      armor_stack_key = "",
    })
  end

  -- Register armor entities for each slot using configuration
  for slot_name, config in pairs(ARMOR_SLOT_CONFIG) do
    create_armor_entity(slot_name, config.bone, config.position, config.size)
  end
end

---------------------------------------------------------------------

local function get_mcl_armor_layer_texture(stack)
  if not stack or stack:is_empty() then
    return nil
  end
  local def = stack:get_definition()
  local texture = def and def._mcl_armor_texture
  if type(texture) == "function" then
    texture = texture(nil, stack)
  end
  if texture and texture ~= "" then
    return texture
  end
  return nil
end

function working_villages.villager:update_armor_visuals()
  local mesh = self.object:get_properties().mesh
  if not working_villages.voxelibre_compat.is_voxelibre or
      not working_villages.is_voxelibre_armor_mesh(mesh) then
    return false
  end

  local armor_texture
  for _, slot in ipairs({"head", "torso", "legs", "feet"}) do
    local stack = self:get_armor_stack(slot)
    local tex = get_mcl_armor_layer_texture(stack)
    if tex then
      armor_texture = "(" .. tex .. ")" .. (armor_texture and "^" .. armor_texture or "")
    end
  end
  if not armor_texture or armor_texture == "" then
    armor_texture = "blank.png"
  end

  local props = self.object:get_properties()
  local textures = props.textures or {}
  textures[1] = textures[1] or "blank.png"
  textures[2] = armor_texture
  textures[3] = textures[3] or "blank.png"
  self.object:set_properties({textures = textures})
  return true
end

local function ensure_dummy_head(self)
  local pos = self.object:get_pos()
  local all_objects = minetest.get_objects_inside_radius(pos, 0.5)
  for _, obj in ipairs(all_objects) do
    local luaentity = obj:get_luaentity()
    if luaentity and luaentity.name == "working_villages:dummy_head" then
      if obj.get_attach and obj:get_attach() == self.object then
        return
      end
    end
  end
  minetest.add_entity(pos, "working_villages:dummy_head")
end

local function ensure_dummy_offhand(self)
  local pos = self.object:get_pos()
  local all_objects = minetest.get_objects_inside_radius(pos, 0.5)
  for _, obj in ipairs(all_objects) do
    local luaentity = obj:get_luaentity()
    if luaentity and luaentity.name == "working_villages:dummy_offhand" then
      if obj.get_attach and obj:get_attach() == self.object then
        return
      end
    end
  end
  minetest.add_entity(pos, "working_villages:dummy_offhand")
end

local function ensure_dummy_armor(self)
  if self.update_armor_visuals and self:update_armor_visuals() then
    local pos = self.object:get_pos()
    local all_objects = minetest.get_objects_inside_radius(pos, 0.5)
    for _, obj in ipairs(all_objects) do
      local luaentity = obj:get_luaentity()
      if luaentity and luaentity.name and luaentity.name:find("^working_villages:dummy_armor_") then
        if obj.get_attach and obj:get_attach() == self.object then
          obj:remove()
        end
      end
    end
    return
  end

  local fallback_armor_slots = {"head", "torso", "legs", "feet"}
  local pos = self.object:get_pos()
  
  for _, slot in ipairs(fallback_armor_slots) do
    local entity_name = "working_villages:dummy_armor_" .. slot
    local found = false
    
    local all_objects = minetest.get_objects_inside_radius(pos, 0.5)
    for _, obj in ipairs(all_objects) do
      local luaentity = obj:get_luaentity()
      if luaentity and luaentity.name == entity_name then
        if obj.get_attach and obj:get_attach() == self.object then
          found = true
          break
        end
      end
    end
    
    if not found then
      minetest.add_entity(pos, entity_name)
    end
  end
end

local function ensure_dummy_item(self)
  local pos = self.object:get_pos()
  local all_objects = minetest.get_objects_inside_radius(pos, 0.5)
  for _, obj in ipairs(all_objects) do
    local luaentity = obj:get_luaentity()
    if luaentity and luaentity.name == "working_villages:dummy_item" then
      if obj.get_attach and obj:get_attach() == self.object then
        ensure_dummy_head(self)
        ensure_dummy_offhand(self)
        ensure_dummy_armor(self)
        return
      end
    end
  end
  minetest.add_entity(pos, "working_villages:dummy_item")
  ensure_dummy_head(self)
  ensure_dummy_offhand(self)
  ensure_dummy_armor(self)
end

-- public helper to refresh all visible equipment (wield + offhand + head)
function working_villages.villager:refresh_equipment()
  ensure_dummy_item(self)
end

local function can_manage_inventory(self, player)
  return player ~= nil and working_villages.can_manage_villager
    and working_villages.can_manage_villager(self, player) == true
end

local function can_use_job_catalog(player)
  if not player or not working_villages.can_manage_villager then
    return false
  end
  local forms_module = working_villages.require("forms")
  for _, villager in pairs(forms_module.villagers or {}) do
    if forms_module.is_live_villager(villager)
        and working_villages.can_manage_villager(villager, player) then
      return true
    end
  end
  return false
end

working_villages.job_inv = minetest.create_detached_inventory("working_villages:job_inv", {
	allow_take = function(_, _, _, stack, player)
		return can_use_job_catalog(player) and stack:get_count() or 0
	end,
	allow_put = function()
		return 0
	end,
	allow_move = function()
		return 0
	end,
  on_take = function(inv, listname, _, stack) --inv, listname, index, stack, player
    inv:add_item(listname,stack)
  end,
  on_put = function(inv, listname, _, stack)
    if inv:contains_item(listname, stack:peek_item(1)) then
      --inv:remove_item(listname, stack)
      stack:clear()
    end
  end,
})
working_villages.job_inv:set_size("main", 32)

-- working_villages.register_job registers a definition of a new job.
function working_villages.register_job(job_name, def)
  local name = cmnp(job_name)
  working_villages.registered_jobs[name] = def

  minetest.register_tool(name, {
    stack_max       = 1,
    description     = def.description,
    inventory_image = def.inventory_image,
    groups          = {not_in_creative_inventory = 1}
  })

  --working_villages.job_inv:set_size("main", #working_villages.registered_jobs)
  working_villages.job_inv:add_item("main", ItemStack(name))
end

-- working_villages.register_egg registers a definition of a new egg.
function working_villages.register_egg(egg_name, def)
  local name = cmnp(egg_name)
  working_villages.registered_eggs[name] = def

  minetest.register_tool(name, {
    description     = def.description,
    inventory_image = def.inventory_image,
    stack_max       = 1,

    on_use = function(itemstack, user, pointed_thing)
	  if not user or not pointed_thing or pointed_thing.above == nil or def.product_name == nil then
		return itemstack
	  end
	  local owner_name = user:get_player_name()
	  local population_limit = math.max(5,
		tonumber(minetest.settings:get("working_villages_population_limit")) or 20)
	  if working_villages.population
			and working_villages.population.count(owner_name) >= population_limit then
		minetest.chat_send_player(owner_name,
			("Limite du village atteinte (%d villageois)."):format(population_limit))
		return itemstack
	  end
	  if minetest.is_protected(pointed_thing.above, owner_name) then
		minetest.record_protection_violation(pointed_thing.above, owner_name)
		return itemstack
	  end
	  if pointed_thing.above ~= nil and def.product_name ~= nil then
        -- set villager's direction.
        local new_villager = minetest.add_entity(pointed_thing.above, def.product_name)
		if not new_villager then
			return itemstack
		end
        new_villager:get_luaentity():set_yaw_by_direction(
          vector.subtract(user:get_pos(), new_villager:get_pos())
        )
        local entity = new_villager:get_luaentity()
        entity.owner_name = owner_name
        entity:update_infotext()
        if entity.apply_owner_visuals then
          entity:apply_owner_visuals()
        end
		if working_villages.population then
			working_villages.population.register(entity, pointed_thing.above)
		end

        itemstack:take_item()
        return itemstack
      end
      return nil
    end,
  })
end

local job_coroutines = working_villages.require("job_coroutines")
local forms = working_villages.require("forms")

-- Physics can occasionally move an entity through a floor or wall when the
-- server has a long step.  Keep this guard deliberately local and
-- conservative: only a recent, revalidated standing-pose cache permits an
-- immediate restore; otherwise collision geometry must be intersected for
-- several consecutive callbacks.  A clear underground cavity is therefore a
-- valid safe pose and never sends a miner back to the surface.
-- Forward-declared so it survives the do/end block below: everything else in
-- that block (constants + 11 sibling helpers) is verified by grep to be used
-- nowhere past line 6693, but handle_embedded_body itself is called much
-- later from the villager on_step chain and must stay in scope.
local handle_embedded_body

-- Wrapped for the same 200-top-level-local reason as the village-claims
-- block above: closing this do/end frees these slots for reuse by
-- everything declared afterward, with no call-site changes needed.
do

local EMBEDDED_BODY_CALLBACK_LIMIT = 3
local EMBEDDED_SAFE_CACHE_MAX_DISTANCE = 16
local EMBEDDED_SAFE_SEARCH_RADIUS = 4
local EMBEDDED_SAFE_SEARCH_HEIGHT = 5
local COLLISION_EPSILON = 0.001

local function finite_number(value)
  return type(value) == "number" and value == value and
    value ~= math.huge and value ~= -math.huge
end

local function get_entity_collisionbox(self)
  local properties = self.object and self.object.get_properties and
    self.object:get_properties() or nil
  local box = properties and properties.collisionbox or
    self.initial_properties and self.initial_properties.collisionbox
  if type(box) ~= "table" or #box < 6 then
    return {-0.25, 0, -0.25, 0.25, 1.75, 0.25}
  end
  for index = 1, 6 do
    if not finite_number(box[index]) then
      return {-0.25, 0, -0.25, 0.25, 1.75, 0.25}
    end
  end
  return box
end

local function node_coordinate(value)
  return math.floor(value + 0.5)
end

local function world_entity_box(self, pos)
  local box = get_entity_collisionbox(self)
  return {
    pos.x + box[1], pos.y + box[2], pos.z + box[3],
    pos.x + box[4], pos.y + box[5], pos.z + box[6],
  }, box
end

local function boxes_overlap(first, second)
  return first[1] < second[4] - COLLISION_EPSILON and
    first[4] > second[1] + COLLISION_EPSILON and
    first[2] < second[5] - COLLISION_EPSILON and
    first[5] > second[2] + COLLISION_EPSILON and
    first[3] < second[6] - COLLISION_EPSILON and
    first[6] > second[3] + COLLISION_EPSILON
end

local function collision_boxes_for_node(pos, node)
  if type(minetest.get_node_boxes) == "function" then
    local ok, boxes = pcall(minetest.get_node_boxes,
      "collision_box", pos, node)
    if ok and type(boxes) == "table" then
      return boxes
    end
  end
  return {{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}}
end

local function node_collision_intersects(entity_box, pos, node)
  local def = node and minetest.registered_nodes[node.name]
  if not def or def.walkable ~= true then
    return false
  end
  for _, box in ipairs(collision_boxes_for_node(pos, node)) do
    if type(box) == "table" and #box >= 6 then
      local world_box = {
        pos.x + box[1], pos.y + box[2], pos.z + box[3],
        pos.x + box[4], pos.y + box[5], pos.z + box[6],
      }
      if boxes_overlap(entity_box, world_box) then
        return true
      end
    end
  end
  return false
end

-- Return (intersects, known).  An unloaded/ignore node is not proof of an
-- embedding and must never trigger a blind teleport.
local function body_intersects_walkable(self, pos)
  local entity_box = world_entity_box(self, pos)
  local unknown = false
  local intersects = false
  local min_x = node_coordinate(entity_box[1] + COLLISION_EPSILON)
  local max_x = node_coordinate(entity_box[4] - COLLISION_EPSILON)
  local min_y = node_coordinate(entity_box[2] + COLLISION_EPSILON)
  local max_y = node_coordinate(entity_box[5] - COLLISION_EPSILON)
  local min_z = node_coordinate(entity_box[3] + COLLISION_EPSILON)
  local max_z = node_coordinate(entity_box[6] - COLLISION_EPSILON)

  for x = min_x, max_x do
    for y = min_y, max_y do
      for z = min_z, max_z do
        local node_pos = {x = x, y = y, z = z}
        local node = minetest.get_node_or_nil(node_pos)
        if not node or node.name == "ignore" then
          unknown = true
        elseif node_collision_intersects(entity_box, node_pos, node) then
          intersects = true
        end
      end
    end
  end
  return intersects, not unknown
end

local function pose_has_support(self, pos)
  local entity_box = world_entity_box(self, pos)
  local bottom = entity_box[2]
  local support_y = node_coordinate(bottom - 0.05)
  local min_x = node_coordinate(entity_box[1] + COLLISION_EPSILON)
  local max_x = node_coordinate(entity_box[4] - COLLISION_EPSILON)
  local min_z = node_coordinate(entity_box[3] + COLLISION_EPSILON)
  local max_z = node_coordinate(entity_box[6] - COLLISION_EPSILON)

  for x = min_x, max_x do
    for z = min_z, max_z do
      local node_pos = {x = x, y = support_y, z = z}
      local node = minetest.get_node_or_nil(node_pos)
      if not node or node.name == "ignore" then
        return false
      end
      local def = minetest.registered_nodes[node.name]
      if def and def.walkable == true then
        for _, box in ipairs(collision_boxes_for_node(node_pos, node)) do
          if type(box) == "table" and #box >= 6 then
            local world_box = {
              node_pos.x + box[1], node_pos.y + box[2], node_pos.z + box[3],
              node_pos.x + box[4], node_pos.y + box[5], node_pos.z + box[6],
            }
            local overlaps_xz = entity_box[1] < world_box[4] - COLLISION_EPSILON and
              entity_box[4] > world_box[1] + COLLISION_EPSILON and
              entity_box[3] < world_box[6] - COLLISION_EPSILON and
              entity_box[6] > world_box[3] + COLLISION_EPSILON
            local supports_bottom = world_box[5] <= bottom + 0.05 and
              world_box[5] >= bottom - 0.2
            if overlaps_xz and supports_bottom then
              return true
            end
          end
        end
      end
    end
  end
  return false
end

local function is_safe_standing_pose(self, pos)
  if type(pos) ~= "table" or not finite_number(pos.x) or
      not finite_number(pos.y) or not finite_number(pos.z) then
    return false
  end
  local embedded, known = body_intersects_walkable(self, pos)
  return known and not embedded and pose_has_support(self, pos)
end

local function find_nearby_safe_standing_pose(self, current)
  local _, collisionbox = world_entity_box(self, current)
  local body_node_y = node_coordinate(current.y + collisionbox[2] +
    COLLISION_EPSILON)
  local center_x = node_coordinate(current.x)
  local center_z = node_coordinate(current.z)
  local vertical_offsets = {0, 1, -1, 2, -2, 3, -3, 4, -4, 5, -5}

  for radius = 0, EMBEDDED_SAFE_SEARCH_RADIUS do
    for dx = -radius, radius do
      for dz = -radius, radius do
        if radius == 0 or math.abs(dx) == radius or math.abs(dz) == radius then
          for _, dy in ipairs(vertical_offsets) do
            if math.abs(dy) <= EMBEDDED_SAFE_SEARCH_HEIGHT then
              -- The feet rest on the top face of the node below the body node.
              local candidate = {
                x = center_x + dx,
                y = body_node_y + dy - 0.5 - collisionbox[2],
                z = center_z + dz,
              }
              if is_safe_standing_pose(self, candidate) then
                return candidate
              end
            end
          end
        end
      end
    end
  end
  return nil
end

-- Returns true while normal AI work must be suspended for this callback.
function handle_embedded_body(self)
  if not self.object or type(self.object.get_pos) ~= "function" then
    return false
  end
  local pos = self.object:get_pos()
  if not pos then
    return false
  end
  local embedded, known = body_intersects_walkable(self, pos)
  if not known then
    self._embedded_body_callbacks = 0
    return false
  end
  if not embedded then
    self._embedded_body_callbacks = 0
    -- The body was already checked above; only the support probe is still
    -- needed before refreshing the cache on the normal hot path.
    if pose_has_support(self, pos) then
      self._safe_standing_pos = vector.new(pos)
      self._safe_standing_at = runtime_seconds()
    end
    return false
  end

  -- A long engine step can put a villager several nodes inside a floor and
  -- unload it before a second entity callback.  A recent cache is refreshed
  -- only from a fully-known, collision-free, supported pose and is validated
  -- again here, so it is safe to restore immediately.  Ambiguous or cacheless
  -- cases retain the multi-callback confirmation and local search below.
  local destination = self._safe_standing_pos
  local cached_at = tonumber(self._safe_standing_at)
  local now = runtime_seconds()
  if destination and finite_number(cached_at) and finite_number(now) and
      now >= cached_at and now - cached_at <= 8 and
      is_safe_standing_pose(self, destination) and
      vector.distance(pos, destination) <= EMBEDDED_SAFE_CACHE_MAX_DISTANCE then
    self.object:set_pos(destination)
    if self.object.set_velocity then
      self.object:set_velocity({x = 0, y = 0, z = 0})
    end
    self._safe_standing_pos = vector.new(destination)
    self._safe_standing_at = runtime_seconds()
    self._embedded_body_callbacks = 0
    minetest.log("warning", ("[working_villages] Villager %s recovered from " ..
      "solid-node embedding at %s -> %s"):format(
        tostring(self.inventory_name or self.nametag or "unknown"),
        minetest.pos_to_string(pos, 2),
        minetest.pos_to_string(destination, 2)))
    return true
  end

  self._embedded_body_callbacks = math.min(
    EMBEDDED_BODY_CALLBACK_LIMIT,
    (tonumber(self._embedded_body_callbacks) or 0) + 1)
  if self.object.set_velocity then
    self.object:set_velocity({x = 0, y = 0, z = 0})
  end
  if self._embedded_body_callbacks < EMBEDDED_BODY_CALLBACK_LIMIT then
    return true
  end

  destination = find_nearby_safe_standing_pose(self, pos)
  if not destination then
    return true
  end

  self.object:set_pos(destination)
  if self.object.set_velocity then
    self.object:set_velocity({x = 0, y = 0, z = 0})
  end
  self._safe_standing_pos = vector.new(destination)
  self._safe_standing_at = runtime_seconds()
  self._embedded_body_callbacks = 0
  minetest.log("warning", ("[working_villages] Villager %s recovered from " ..
    "solid-node embedding at %s -> %s"):format(
      tostring(self.inventory_name or self.nametag or "unknown"),
      minetest.pos_to_string(pos, 2), minetest.pos_to_string(destination, 2)))
  return true
end

end -- closes the embedded-body-recovery do-block opened above finite_number

-- working_villages.register_villager registers a definition of a new villager.
function working_villages.register_villager(product_name, def)
  local name = cmnp(product_name)
  working_villages.registered_villagers[name] = def

  -- initialize manufacturing number of a new villager.
  if working_villages.manufacturing_data[name] == nil then
    working_villages.manufacturing_data[name] = 0
    persist_manufacturing_data()
  end

  -- create_inventory creates a new inventory, and returns it.
  local function create_inventory(self)
    self.inventory_name = self.product_name .. "_" .. tostring(self.manufacturing_number)
    local armor_group_for_slot = {
      head = "armor_head",
      torso = "armor_torso",
      legs = "armor_legs",
      feet = "armor_feet",
    }
    local armor_name_hint = {
      head = {"helmet", "cap", "head"},
      torso = {"chestplate", "chest", "body"},
      legs = {"leggings", "leg"},
      feet = {"boots", "shoe"},
    }
    local function is_armor_for_slot(slot, stack)
      local group = armor_group_for_slot[slot]
      if not group then
        return false
      end
      if minetest.get_item_group(stack:get_name(), group) > 0 then
        return true
      end
      -- fallback: name hint in case some VoxeLibre items lack explicit armor_* group
      local hints = armor_name_hint[slot]
      if hints then
        local nm = stack:get_name()
        for _, hint in ipairs(hints) do
          if nm:find(hint, 1, true) then
            return true
          end
        end
      end
      return false
    end
    local inventory = minetest.create_detached_inventory(self.inventory_name, {
      on_put = function(_, listname, _, stack) --inv, listname, index, stack, player
        if listname == "job" then
          local job_name = stack:get_name()
          local job = working_villages.registered_jobs[job_name]
          if type(job.on_start)=="function" then
            job.on_start(self)
          end
          if type(job.jobfunc)=="function" then
            self.job_thread = coroutine.create(job.jobfunc)
          end
          self:set_displayed_action("actif")
          self:set_state_info(("Je commence le metier de %s."):format(job.description))
      end
        ensure_dummy_item(self)
      end,
      allow_put = function(inv, listname, _, stack, player)
		if not can_manage_inventory(self, player) then
			return 0
		end
        -- only jobs can put to a job inventory.
        if listname == "main" then
          return stack:get_count()
      elseif listname == "job" and working_villages.is_job(stack:get_name()) then
        if not inv:is_empty("job") then
          inv:remove_item("job", inv:get_list("job")[1])
        end
        return stack:get_count()
      elseif listname == "wield_item" then
        return 0
      elseif listname == "offhand" then
        if is_shield_item(stack:get_name()) then
          ensure_dummy_item(self)
          return stack:get_count()
        end
        return 0
      end
      if armor_group_for_slot[listname] then
        if is_armor_for_slot(listname, stack) then
          ensure_dummy_item(self)
          return stack:get_count()
        end
        return 0
      end
      return 0
      end,
      on_take = function(_, listname, _, stack) --inv, listname, index, stack, player
        if listname == "job" then
          local job_name = stack:get_name()
          local job = working_villages.registered_jobs[job_name]
          self.time_counters = {}
          if job then
            if type(job.on_stop)=="function" then
              job.on_stop(self)
            elseif type(job.jobfunc)=="function" then
              self.job_thread = false
            end
          end
          self:set_state_info("J'arrete de travailler.")
          self:update_infotext()
      end
        ensure_dummy_item(self)
      end,

      allow_take = function(_, listname, _, stack, player)
		if not can_manage_inventory(self, player) then
			return 0
		end
        if listname == "wield_item" then
          return 0
      end
      return stack:get_count()
      end,

      on_move = function(inv, from_list, _, to_list, to_index)
        --inv, from_list, from_index, to_list, to_index, count, player
        if to_list == "job" or from_list == "job" then
          local job_name = inv:get_stack(to_list, to_index):get_name()
          local job = working_villages.registered_jobs[job_name]

          if to_list == "job" then
            if type(job.on_start)=="function" then
              job.on_start(self)
            end
            if type(job.jobfunc)=="function" then
              self.job_thread = coroutine.create(job.jobfunc)
            end
          elseif from_list == "job" then
            if type(job.on_stop)=="function" then
              job.on_stop(self)
            elseif type(job.jobfunc)=="function" then
              self.job_thread = false
            end
          end

          self:set_displayed_action("actif")
          self:set_state_info(("Je commence le metier de %s."):format(job.description))
        end
        ensure_dummy_item(self)
      end,

      allow_move = function(inv, from_list, from_index, to_list, _, count, player)
		if not can_manage_inventory(self, player) then
			return 0
		end
        --inv, from_list, from_index, to_list, to_index, count, player
        if to_list == "wield_item" then
          return 0
        elseif to_list == "offhand" then
          if is_shield_item(inv:get_stack(from_list, from_index):get_name()) then
            return count
          end
          return 0
        end

        if to_list == "main" then
          return count
        elseif to_list == "job" and working_villages.is_job(inv:get_stack(from_list, from_index):get_name()) then
          return count
        elseif armor_group_for_slot[to_list] then
          if is_armor_for_slot(to_list, inv:get_stack(from_list, from_index)) then
            return count
          end
          return 0
        end

        return 0
      end,
    })

    inventory:set_size("main", 16)
    inventory:set_size("job",  1)
    inventory:set_size("wield_item", 1)
    inventory:set_size("offhand", 1)
    inventory:set_size("head", 1)
    inventory:set_size("torso", 1)
    inventory:set_size("legs", 1)
    inventory:set_size("feet", 1)

    return inventory
  end

  local function fix_pos_data(self)
    if self:has_home() then
      -- share some data from building sign
      local sign = self:get_home()
      self.pos_data.home_pos = sign:get_door()
      self.pos_data.bed_pos = sign:get_bed()
    end
    if self.village_name then
      -- Village-wide shared position data is not implemented yet.
      return
    end
  end

  local function initialize_new_villager(self)
    self.product_name = name
    self.manufacturing_number = reserve_manufacturing_number(name)
    self.owner_name = ""
    self.pause = false
    self.nametag = random_villager_name()
    self.needs = working_villages.needs.create_state()
    self.memory = working_villages.memory.create_state()
    self.persistence_revision = 0
    create_inventory(self)
  end

  local function valid_manufacturing_number(value)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or
        number == -math.huge or number < 0 then
      return nil
    end
    return math.floor(number)
  end

  local function restore_inventory_lists(self, inventory, saved_inventory)
    if type(saved_inventory) ~= "table" then
      return
    end
    for list_name, list in pairs(saved_inventory) do
      if type(list_name) == "string" and type(list) == "table" and
          inventory:get_size(list_name) > 0 then
        local ok, restore_error = pcall(inventory.set_list, inventory, list_name, list)
        if not ok then
          minetest.log("warning", ("[working_villages] inventaire ignore pour %s (%s): %s")
            :format(tostring(self.inventory_name), list_name, tostring(restore_error)))
        end
      end
    end
  end

  -- on_activate is a callback function that is called when the object is created or recreated.
  local function on_activate(self, staticdata)
    -- Registered entity definitions are used as metatables by Luanti. Mutable
    -- table defaults on that definition would otherwise be shared by every
    -- villager of this entity type. Always establish instance-owned runtime
    -- state before loading or creating persistent data.
    self.time_counters = {}
    self.job_data = {}
    self.pos_data = {}
    self.destination = vector.new(0, 0, 0)
    self.path = nil
    self._step_navigations = nil
    self.emergency_retreat_destination = nil
    self.emergency_retreat_kind = nil
    self.job_thread = false
    self.rest_thread = nil
    self.rest_thread_target = nil
    self.initial_spawn_slot = nil

    -- Parse persisted data defensively. Old or damaged worlds can contain a
    -- scalar, truncated data, or no inventory table at all. Such data must not
    -- abort entity activation: an unusable record becomes a fresh villager,
    -- while a usable record keeps its identity and receives an empty inventory.
    local data = nil
    local recovered_state = false
    local recovery_reason = nil
    if type(staticdata) == "string" and staticdata ~= "" then
      local deserialize_ok, decoded = pcall(minetest.deserialize, staticdata)
      if deserialize_ok and type(decoded) == "table" then
        data = decoded
      else
        minetest.log("warning", "[working_villages] staticdata invalide; migration vers un nouveau villageois")
      end
    elseif staticdata ~= nil and staticdata ~= "" then
      minetest.log("warning", "[working_villages] staticdata non textuel; migration vers un nouveau villageois")
    end

    if data and working_villages.population and
        type(working_villages.population.recover_data) == "function" then
      local recovery_product = type(data.product_name) == "string" and data.product_name or name
      local recovery_number = valid_manufacturing_number(data.manufacturing_number)
      if recovery_number ~= nil then
        data, recovered_state, recovery_reason = working_villages.population.recover_data(
          recovery_product .. "_" .. tostring(recovery_number), data)
      end
    end

    if not data then
      initialize_new_villager(self)
    else
      local saved_product_name = data.product_name
      if type(saved_product_name) ~= "string" or
          not working_villages.registered_villagers[saved_product_name] then
        saved_product_name = name
      end
      self.product_name = saved_product_name

      local saved_number = valid_manufacturing_number(data.manufacturing_number)
      if saved_number == nil then
        saved_number = reserve_manufacturing_number(self.product_name)
      else
        observe_manufacturing_number(self.product_name, saved_number)
      end
      self.manufacturing_number = saved_number
      self.nametag = type(data.nametag) == "string" and data.nametag or ""
      if self.nametag == "" then
        self.nametag = random_villager_name()
      end
      self.owner_name = type(data.owner_name) == "string" and data.owner_name or ""
      if type(data.pause) == "boolean" or type(data.pause) == "string" then
        self.pause = data.pause
      else
        self.pause = false
      end
      self.job_data = type(data.job_data) == "table" and data.job_data or {}
      self.state_info = type(data.state_info) == "string" and data.state_info or
        "Je ne fais rien de particulier."
      self.pos_data = type(data.pos_data) == "table" and data.pos_data or {}
      self.needs = type(data.needs) == "table" and data.needs or
        working_villages.needs.create_state()
      self.memory = type(data.memory) == "table" and data.memory or
        working_villages.memory.create_state()
      self.persistence_revision = math.max(0,
        math.floor(tonumber(data.persistence_revision) or 0))
      self.initial_spawn_slot = math.floor(tonumber(data.initial_spawn_slot) or 0)
      if self.initial_spawn_slot < 1 then
        self.initial_spawn_slot = nil
      end

      local inventory = create_inventory(self)
      restore_inventory_lists(self, inventory, data.inventory)
      fix_pos_data(self)
      if recovery_reason == "checkpoint" and type(data.object_pos) == "table" and
          type(data.object_pos.x) == "number" and type(data.object_pos.y) == "number" and
          type(data.object_pos.z) == "number" then
        self.object:set_pos(data.object_pos)
      end
    end

    if recovered_state then
      minetest.log("warning", ("[working_villages] Etat de reprise restaure pour %s (%s)")
        :format(tostring(self.inventory_name), tostring(recovery_reason)))
    end

    working_villages.survival.activate(self, def.hp_max, data)

    ensure_dummy_item(self)
	if working_villages.population then
		working_villages.population.register(self)
	end
    if working_villages._initial_spawn_entity_activated then
      working_villages._initial_spawn_entity_activated(self)
    end

    self:set_displayed_action("actif")
    self.base_texture = self.base_texture or
      (self.initial_properties and self.initial_properties.textures and self.initial_properties.textures[1])
    self:apply_owner_visuals()

    self.object:set_nametag_attributes{
      text = self.nametag
    }

    self.object:set_velocity{x = 0, y = 0, z = 0}
    self.object:set_acceleration{x = 0, y = -self.initial_properties.weight, z = 0}

    --legacy
    if type(self.pause) == "string" then
      self.pause = (self.pause == "resting")
    end

    local job = self:get_job()
    if job ~= nil then
      if type(job.on_start)=="function" then
        job.on_start(self)
      end
      if type(job.jobfunc)=="function" then
        self.job_thread = coroutine.create(job.jobfunc)
      end
      if self.pause then
        if type(job.on_pause)=="function" then
          job.on_pause(self)
        end
        self:set_displayed_action("repos")
      end
    end
  end

  local function serialize_persistent_state(self)
    local inventory = self:get_inventory()
    local data = {
      ["product_name"] = self.product_name,
      ["manufacturing_number"] = self.manufacturing_number,
      ["nametag"] = self.nametag,
      ["owner_name"] = self.owner_name,
      ["inventory"] = {},
      ["pause"] = self.pause,
      ["job_data"] = self.job_data,
      ["state_info"] = self.state_info,
      ["pos_data"] = self.pos_data,
      ["needs"] = self.needs,
      ["memory"] = self.memory,
      ["initial_spawn_slot"] = self.initial_spawn_slot,
      ["survival_schema_version"] = self.survival_schema_version,
      ["persistence_revision"] = math.max(0,
        math.floor(tonumber(self.persistence_revision) or 0)),
      ["object_pos"] = self.object and self.object:get_pos() or nil,
    }

    -- A detached inventory can already be gone during removal/shutdown. Keep
    -- the entity serializable with empty lists instead of crashing the world
    -- save callback; on_activate recreates all declared list sizes safely.
    if inventory then
      for list_name, list in pairs(inventory:get_lists()) do
        data["inventory"][list_name] = {}

        for i, item in ipairs(list) do
          data["inventory"][list_name][i] = item:to_string()
        end
      end
    end

    return minetest.serialize(data)
  end

  -- Called by Luanti when the active object is persisted. The same serializer
  -- feeds the mod-storage checkpoint so a process kill cannot fall back to an
  -- older mapblock copy of the villager.
  local function get_staticdata(self)
	if working_villages._initial_spawn_entity_saved then
		working_villages._initial_spawn_entity_saved(self)
	end
	if working_villages.population and working_villages.population.checkpoint then
		local checkpoint = working_villages.population.checkpoint(self)
		if checkpoint ~= nil then
			return checkpoint
		end
	elseif working_villages.population then
		working_villages.population.register(self)
	end
	return serialize_persistent_state(self)
  end

  local function on_deactivate(self, removal)
	if removal == true then
		if working_villages._initial_spawn_entity_removed then
			working_villages._initial_spawn_entity_removed(self)
		end
		if working_villages.population then
		if working_villages.collaborative_tasks and
				working_villages.collaborative_tasks.participant_unavailable then
			working_villages.collaborative_tasks.participant_unavailable(
				self.inventory_name,
				"Participant supprime ou mort"
			)
		end
		if self.remove_home then
			self:remove_home()
		end
		working_villages.population.unregister(self)
		end
	end
  end

  -- on_step is a callback function that is called every delta times.
  local emergency_weapon_candidates = compat.get_tool_items("sword", {
    "diamond", "mese", "iron", "gold", "bronze", "stone", "wood",
  })

  local function has_weapon_equipped_or_ready(self)
    if not self.is_weapon then
      return false
    end
    local wield = self:get_wield_item_stack()
    if wield and self:is_weapon(wield:get_name()) then
      return true
    end
    return self:has_item_in_main(function(item_name)
      return self:is_weapon(item_name)
    end) == true
  end

  local function ensure_emergency_weapon(self)
    if not self.is_weapon then
      return false
    end
    if has_weapon_equipped_or_ready(self) then
      if self.equip_best_weapon then
        self:equip_best_weapon()
      end
      return true
    end
    if self.take_from_shared_storage_by_predicate then
      if self:take_from_shared_storage_by_predicate(function(item_name)
        return self:is_weapon(item_name)
      end, 1) then
        if self.equip_best_weapon then
          self:equip_best_weapon()
        end
        return true
      end
    end
    if working_villages.crafting and working_villages.crafting.ensure_any_item then
      local crafted = working_villages.crafting.ensure_any_item(self, emergency_weapon_candidates, 1, {
        use_shared_storage = true,
        fail_cooldown = 8,
        max_depth = 4,
      })
      if crafted then
        if self.equip_best_weapon then
          self:equip_best_weapon()
        end
        return true
      end
    end
    return false
  end

  local function normalize_shelter_pos(self, pos)
    if not pos then
      return nil
    end
    pos = vector.round(pos)
    local node = minetest.get_node_or_nil(pos)
    if node and (func.is_chest(pos) or (minetest.registered_nodes[node.name] and minetest.registered_nodes[node.name].walkable)) then
      local adjacent = func.find_adjacent_clear(pos)
      if adjacent and adjacent ~= false then
        return func.find_ground_below(adjacent) or adjacent
      end
    end
    return func.find_ground_below(pos) or pos
  end

  local function valid_assigned_home_bed(self)
    if type(self.has_home) ~= "function" or not self:has_home() or
        type(self.get_home) ~= "function" then
      return nil
    end
    local home = self:get_home()
    if not home or type(home.get_bed) ~= "function" then
      return nil
    end
    local bed_pos = home:get_bed()
    if type(bed_pos) ~= "table" or bed_pos.x == nil or bed_pos.y == nil or
        bed_pos.z == nil then
      return nil
    end
    bed_pos = vector.round(bed_pos)
    if func.is_protected(self, bed_pos) then
      return nil
    end
    return bed_pos
  end

  local function find_owned_structure_shelter(self, radius)
    if not self.object or type(self.object.get_pos) ~= "function" then
      return nil
    end
    local current_pos = self.object:get_pos()
    if not current_pos then
      return nil
    end
    local center = vector.round(current_pos)
    local minp = vector.subtract(center, radius or 24)
    local maxp = vector.add(center, radius or 24)
    local markers = minetest.find_nodes_in_area(minp, maxp, {"working_villages:building_marker"})
    local best_pos = nil
    local best_distance = nil
    for _, marker in ipairs(markers) do
      local meta = minetest.get_meta(marker)
      local owner = meta:get_string("owner")
      local state = meta:get_string("state")
      local schematic = working_villages.normalize_blueprint_name(
        meta:get_string("schematic"))
      if owner == (self.owner_name or "") and state == "built" and
          house_blueprint_names[schematic] then
        local available = false
        if type(working_villages.is_home_available) == "function" then
          available = working_villages.is_home_available(
            marker, self.owner_name, self.inventory_name) == true
        end
        local bed_pos = minetest.string_to_pos(meta:get_string("bed"))
        local door_pos = minetest.string_to_pos(meta:get_string("door"))
        local validator = working_villages.buildings and
          working_villages.buildings.validate_home_nodes
        local valid_nodes, _, canonical_bed = false, nil, nil
        if type(validator) == "function" then
          valid_nodes, _, canonical_bed = validator(bed_pos, door_pos)
        end
        if available and valid_nodes and canonical_bed and
            not func.is_protected(self, canonical_bed) and
            not func.is_protected(self, door_pos) then
          local shelter_pos = vector.round(canonical_bed)
          local distance = vector.distance(center, shelter_pos)
          if not best_distance or distance < best_distance then
            best_distance = distance
            best_pos = shelter_pos
          end
        end
      end
    end
    return best_pos
  end

  local function get_emergency_shelter_pos(self)
    local assigned_bed = valid_assigned_home_bed(self)
    if assigned_bed then
      return assigned_bed
    end
    -- A door, job position, chest, or unfinished construction is not shelter.
    -- Homeless villagers may only use the bed of a built, node-validated house.
    return find_owned_structure_shelter(self, 24)
  end

  local REST_NAVIGATION_RETRY_SECONDS = 30

  local function cancel_rest_navigation(self)
    self.rest_thread = nil
    self.rest_thread_target = nil
    self.path = nil
  end

  local function record_rest_navigation_failure(self, rest_pos)
    cancel_rest_navigation(self)
    self.job_data = self.job_data or {}
    self.job_data.resting = nil
    self.job_data.rest_pos = nil
    self.job_data.rest_retry_remaining = REST_NAVIGATION_RETRY_SECONDS
    self:set_displayed_action("abri inaccessible")
    self:set_state_info("Je ne trouve pas de chemin praticable vers l'abri; je reessaierai plus tard.")
    return false
  end

  -- go_to yields while the path is followed. Drive it in an instance-owned
  -- coroutine so the entity callback itself never yields, and observe its
  -- terminal return value instead of silently retrying a failed path forever.
  local function advance_rest_navigation(self, rest_pos)
    if type(rest_pos) ~= "table" or rest_pos.x == nil or rest_pos.y == nil or
        rest_pos.z == nil then
      return record_rest_navigation_failure(self, rest_pos)
    end
    local rounded = vector.round(rest_pos)
    local target = minetest.hash_node_position(rounded)
    if self.rest_thread and self.rest_thread_target ~= target then
      cancel_rest_navigation(self)
    end
    if not self.rest_thread then
      self.rest_thread_target = target
      self.rest_thread = coroutine.create(function()
        return self:go_to(rounded)
      end)
    end

    local resume_ok, result = coroutine.resume(self.rest_thread)
    if not resume_ok then
      return record_rest_navigation_failure(self, rounded)
    end
    if coroutine.status(self.rest_thread) == "dead" then
      self.rest_thread = nil
      self.rest_thread_target = nil
      if result ~= true then
        return record_rest_navigation_failure(self, rounded)
      end
      return true
    end
    return nil
  end

  local function rest_retry_is_waiting(self, dtime)
    self.job_data = self.job_data or {}
    local remaining = tonumber(self.job_data.rest_retry_remaining) or 0
    if remaining ~= remaining or remaining == math.huge or remaining < 0 then
      remaining = 0
    end
    if remaining <= 0 then
      self.job_data.rest_retry_remaining = nil
      return false
    end
    local elapsed = tonumber(dtime) or 0
    if elapsed ~= elapsed or elapsed == math.huge or elapsed < 0 then
      elapsed = 0
    end
    remaining = math.max(0, remaining - elapsed)
    self.job_data.rest_retry_remaining = remaining > 0 and remaining or nil
    return remaining > 0
  end

  local function get_flee_destination(self, enemy)
    local current = self.object:get_pos()
    local enemy_pos = enemy and enemy:get_pos() or nil
    if not current or not enemy_pos then
      return nil
    end
    local away = vector.subtract(current, enemy_pos)
    away.y = 0
    if vector.length(away) < 0.5 then
      away = {
        x = (math.random(0, 1) * 2) - 1,
        y = 0,
        z = (math.random(0, 1) * 2) - 1,
      }
    end
    away = vector.normalize(away)
    for _, distance in ipairs({10, 8, 6, 4}) do
      local probe = vector.add(current, vector.multiply(away, distance))
      local shelter_pos = normalize_shelter_pos(self, vector.add(probe, {x = 0, y = 2, z = 0}))
      if shelter_pos and not func.is_protected(self, shelter_pos) then
        return shelter_pos
      end
    end
    return nil
  end

  local EMERGENCY_NAVIGATION_KEY = "emergency_retreat"

  local function cancel_emergency_retreat(self, restore_job_motion)
    local state_active = type(self._step_navigations) == "table" and
      self._step_navigations[EMERGENCY_NAVIGATION_KEY] ~= nil
    local was_active = state_active or self.emergency_retreat_destination ~= nil
    if self.cancel_go_to_step then
      self:cancel_go_to_step(EMERGENCY_NAVIGATION_KEY, false)
    end
    self.emergency_retreat_destination = nil
    self.emergency_retreat_kind = nil
    if not (restore_job_motion and was_active and self.object) then
      return was_active
    end
    if self.path and self.path[1] then
      self:change_direction(self.path[1])
    else
      self.object:set_velocity({x = 0, y = 0, z = 0})
      self:set_animation(working_villages.animation_frames.STAND)
    end
    return was_active
  end

  local function select_emergency_destination(self, shelter_pos, enemy)
    if shelter_pos then
      return vector.round(shelter_pos), "shelter"
    end

    local current = self.object:get_pos()
    local enemy_pos = enemy and enemy:get_pos() or nil
    local cached = self.emergency_retreat_destination
    if self.emergency_retreat_kind == "flee" and cached and current and
        vector.distance(current, cached) > 1.5 then
      if not enemy_pos or
          vector.distance(enemy_pos, cached) > vector.distance(enemy_pos, current) + 1 then
        return vector.round(cached), "flee"
      end
    end
    return get_flee_destination(self, enemy), "flee"
  end

  local function handle_emergency_retreat(self)
    local enemy = self:get_nearest_enemy(10)
    local shelter_pos = get_emergency_shelter_pos(self)
    local close_enemy = self:get_nearest_enemy(2)
    local critically_wounded = working_villages.survival.should_retreat(self)

    if self.equip_best_armor then
      self:equip_best_armor()
    end
    local armed = ensure_emergency_weapon(self)

    -- A healthy armed guard must hold the line throughout the danger window.
    -- Previously the emergency branch only fought within two nodes; as soon as
    -- a native monster was knocked one step farther away, the same guard fled
    -- for roughly twenty seconds even at near-full health. Other professions
    -- keep the conservative close-range self-defence rule.
    local guard_defending = self:get_job_name() == "working_villages:job_guard"
      and enemy and armed and not critically_wounded
    local combat_enemy = close_enemy or (guard_defending and enemy) or nil
    if combat_enemy and armed and (guard_defending or not shelter_pos)
        and not critically_wounded then
      cancel_emergency_retreat(self, false)
      self.object:set_velocity({x = 0, y = 0, z = 0})
      try_trigger_enemy_attack(combat_enemy, self.object)
      self:set_displayed_action("combat")
      self:set_state_info(guard_defending
        and "Je poursuis la menace pour defendre le village."
        or "Je repousse l'ennemi pour survivre.")
      self:atack(combat_enemy)
      return true
    end

    local destination, destination_kind = select_emergency_destination(
      self, shelter_pos, enemy)
    if destination then
      self:set_displayed_action(shelter_pos and "abri" or "fuite")
      self:set_state_info(shelter_pos and "Je cours me mettre a l'abri." or "Je fuis le danger.")
      if self.emergency_retreat_kind ~= destination_kind or
          not self.emergency_retreat_destination or
          not vector.equals(self.emergency_retreat_destination, destination) then
        if self.cancel_go_to_step then
          self:cancel_go_to_step(EMERGENCY_NAVIGATION_KEY, false)
        end
        self.emergency_retreat_destination = vector.round(destination)
        self.emergency_retreat_kind = destination_kind
      end
      if vector.distance(self.object:get_pos(), destination) > 1.5 then
        local navigation_result, navigation_error = self:go_to_step(
          self.emergency_retreat_destination, EMERGENCY_NAVIGATION_KEY)
        if navigation_result == false then
          cancel_emergency_retreat(self, false)
          self:set_displayed_action("fuite bloquee")
          self:set_state_info("Le chemin de fuite est bloque; je cherche une autre issue.")
          log.warning("Emergency retreat path failed for %s: %s",
            tostring(self.inventory_name), tostring(navigation_error))
        elseif navigation_result == true then
          self.emergency_retreat_destination = nil
          self.emergency_retreat_kind = nil
        end
      else
        cancel_emergency_retreat(self, false)
        self.object:set_velocity({x = 0, y = 0, z = 0})
        self:set_animation(working_villages.animation_frames.STAND)
      end
      return true
    end

    if close_enemy and armed and not critically_wounded then
      cancel_emergency_retreat(self, false)
      self.object:set_velocity({x = 0, y = 0, z = 0})
      try_trigger_enemy_attack(close_enemy, self.object)
      self:set_displayed_action("combat")
      self:set_state_info("Je me defend faute d'abri.")
      self:atack(close_enemy)
      return true
    end

    cancel_emergency_retreat(self, false)
    self.object:set_velocity({x = 0, y = 0, z = 0})
    self:set_animation(working_villages.animation_frames.STAND)
    self:set_displayed_action("danger")
    self:set_state_info("Je cherche desesperement un abri.")
    return true
  end

  local function on_step(self, dtime)
    --[[ if owner didn't login, the villager does nothing.
		-- perhaps add a check for this to be used in jobfuncs etc.
		if not minetest.get_player_by_name(self.owner_name) then
			return
		end--]]
    dtime = tonumber(dtime) or 0
    if dtime ~= dtime or dtime == math.huge or dtime == -math.huge or dtime < 0 then
      dtime = 0
    end
    self._timer_dtime = dtime

    -- Long server steps must not let an entity continue its job from inside a
    -- solid node.  The guard preserves job_data, inventory, identity, path and
    -- the exact coroutine object; the next clear callback resumes normally.
    if handle_embedded_body(self) then
      return
    end

    self:handle_liquids()

    -- pickup surrounding item.
    self:pickup_item()

    -- keep equipment dummies alive (avoid invisible outils/armures)
    self:count_timer("equip_refresh")
    if self:timer_exceeded("equip_refresh", 200) then
      self:refresh_equipment()
    end

    self.job_data = self.job_data or {}
    local survival_hunger = working_villages.needs.get(self, "hunger") or 100
    local survival_hunger_critical = working_villages.needs.config.hunger.critical or 10
    working_villages.survival.tick_regeneration(self, dtime,
      not (self.job_data.danger_ticks and self.job_data.danger_ticks > 0) and
      survival_hunger > survival_hunger_critical)
    if self.job_data.eating_ticks and self.job_data.eating_ticks > 0 then
      if not self.job_data.eating_started then
        self.job_data.eating_started = true
        local current = self:get_wield_item_stack()
        self.job_data.eating_prev_wield = current and current:to_string() or ""
        local eat_item = self.job_data.eating_item_name
        if eat_item and eat_item ~= "" then
          self:set_wield_item_stack(ItemStack(eat_item))
        end
      end
      self.job_data.eating_ticks = self.job_data.eating_ticks - 1
      self:set_animation(working_villages.animation_frames.MINE)
      if self.job_data.eating_ticks <= 0 then
        local prev = self.job_data.eating_prev_wield
        if prev and prev ~= "" then
          self:set_wield_item_stack(ItemStack(prev))
        end
        self.job_data.eating_prev_wield = nil
        self.job_data.eating_item_name = nil
        self.job_data.eating_started = nil
      end
      return
    end

    if self.job_data.blocking_ticks and self.job_data.blocking_ticks > 0 then
      if not self.job_data.blocking_started then
        self.job_data.blocking_started = true
        local offhand = self:get_offhand_item_stack()
        if not (offhand and is_shield_item(offhand:get_name())) then
          local current = self:get_wield_item_stack()
          if current and is_shield_item(current:get_name()) then
            self:set_offhand_item_stack(current)
            self:set_wield_item_stack(ItemStack())
          else
            self:move_main_to_offhand(function(item_name) return is_shield_item(item_name) end)
          end
        end
      end
      self.job_data.blocking_ticks = self.job_data.blocking_ticks - 1
      self:set_animation(working_villages.animation_frames.STAND)
      if self.job_data.blocking_ticks <= 0 then
        self.job_data.blocking_started = nil
      end
      return
    end

    if self.job_data.attack_anim_ticks and self.job_data.attack_anim_ticks > 0 then
      self.job_data.attack_anim_ticks = self.job_data.attack_anim_ticks - 1
      local vel = self.object:get_velocity()
      if vel and (math.abs(vel.x) + math.abs(vel.z)) > 0.1 then
        self:set_animation(working_villages.animation_frames.WALK_MINE)
      else
        self:set_animation(working_villages.animation_frames.MINE)
      end
    end

    if self.pause and self.pause_auto == nil then
      local reason = self.job_data and self.job_data.pause_reason
      if reason ~= "manual" then
        self.pause_auto = true
        self:set_timer("auto_resume", self:get_timer("auto_resume") or 0)
      end
    end
    if self.pause then
      if self.pause_auto then
        self:count_timer("auto_resume")
        if self:timer_exceeded("auto_resume", 200) then
          self:set_pause(false)
          self:set_displayed_action("actif")
          self:set_state_info("Je reprends automatiquement le travail.")
        end
      end
      return
    end

    self:count_timer("danger_scan")
    if self:timer_exceeded("danger_scan", 40) then
      local enemy = self:get_nearest_enemy(8)
      if enemy and working_villages.communication then
        try_trigger_enemy_attack(enemy, self.object)
        local enemy_pos = enemy.get_pos and enemy:get_pos() or self.object:get_pos()
        working_villages.record_village_threat(self.owner_name, enemy_pos, "near_villager")
        local targets = working_villages.communication.list_loaded_villagers()
        working_villages.communication.broadcast(self, targets, "danger_alert", {
          pos = self.object:get_pos(),
        })
        self.job_data = self.job_data or {}
        self.job_data.danger_ticks = 200
      end
    end

    if self.job_data and self.job_data.danger_ticks and self.job_data.danger_ticks > 0 then
      self.job_data.danger_ticks = math.max(
        0, self.job_data.danger_ticks - timers.increment(self, dtime))
      if self:get_job_name() ~= "working_villages:job_guard" or
          working_villages.survival.should_retreat(self) then
        if handle_emergency_retreat(self) then
          return
        end
        return
      end
    end
    cancel_emergency_retreat(self, true)

    self:count_timer("resource_requests")
    local resource_requests_due = self.job_data.pending_resource_message ~= nil
    if not resource_requests_due then
      resource_requests_due = self:timer_exceeded("resource_requests", 20)
    end

    self:count_timer("maintenance")
    if self:timer_exceeded("maintenance", 200) then
      self:maintenance_check()
    end

    self:count_timer("home_search")
    if self:timer_exceeded("home_search", 200) and not self:has_home()
        and working_villages.claim_nearest_available_home then
      working_villages.claim_nearest_available_home(self, 48)
    end

    self:maybe_auto_assign_job()

    self:count_timer("needs_resources")
    if self:timer_exceeded("needs_resources", 100 + (auto_job_timer_limit(self) - 80)) then
      self:update_resource_needs()
    end
    working_villages.needs.tick(self, dtime)
    self:count_timer("memory_cleanup")
    if self:timer_exceeded("memory_cleanup", 600) then
      ai_behavior.cleanup_memory(self)
    end

    self:count_timer("ai_decision")
    if self:timer_exceeded("ai_decision", 40) then
      working_villages.ai_decision.apply(self)
    end

    working_villages.permissions.tick(self)

    local hunger = working_villages.needs.get(self, "hunger") or 100
    local hunger_low = working_villages.needs.config.hunger.low or 25
    local hunger_critical = working_villages.needs.config.hunger.critical or 10
    if hunger <= hunger_low then
      if self:try_eat_food() then
        return
      end
      if self:try_cook_food() then
        if self:try_eat_food() then
          return
        end
        return
      end
      if self.take_from_shared_storage_by_predicate then
        if self:take_from_shared_storage_by_predicate(is_food_item, 3) then
          if self:try_eat_food() then
            return
          end
        end
      end
      self:count_timer("hunger_search")
      if self:timer_exceeded("hunger_search", 80) then
        if self.collect_nearest_item_by_condition then
          self:collect_nearest_item_by_condition(
            function(item) return minetest.get_item_group(item.name, "food") > 0 end,
            {x = 8, y = 3, z = 8}
          )
        end
      end
      if hunger <= hunger_critical then
        self:set_displayed_action("chasse")
        self:set_state_info("Je cherche de la nourriture.")
        self:count_timer("hunger_hunt_scan")
        if self:timer_exceeded("hunger_hunt_scan", 10) then
          local target = self:get_nearest_animal(12)
          if target then
            self:set_state_info("Je chasse pour manger.")
            self:atack(target)
            return
          end
        end
        if working_villages.communication then
          local food_in_storage = self:count_shared_storage_items(is_food_item)
          if food_in_storage > 0 then
            self:set_state_info("Je vais chercher de la nourriture dans le coffre.")
            return
          end
          self:count_timer("hunger_help")
          if self:timer_exceeded("hunger_help", 120) then
            self.job_data = self.job_data or {}
            local now = minetest.get_gametime()
            local last = self.job_data.hunger_request_time or 0
            if now - last >= 300 then
              local request = {
                resource = "food",
                count = 2,
                info = "J'ai faim, besoin de nourriture",
                requester_id = self.inventory_name,
              }
              local coordinated = false
              if working_villages.collaborative_tasks and not self.job_data.collab_task then
                local started = working_villages.collaborative_tasks.start_task(
                  "food_support", self, request)
                coordinated = started == true
              end
              if not coordinated then
                local helpers = working_villages.communication.find_nearby_villagers(
                  self.object:get_pos(), 30, nil, self.owner_name)
                working_villages.communication.broadcast(self, helpers, "help_needed", request)
              end
              self.job_data.hunger_request_time = now
            end
          end
        end
        return
      end
    end

    local energy = working_villages.needs.get(self, "energy") or 100
    local energy_low = working_villages.needs.config.energy.low or 25
    local energy_recover = math.min((working_villages.needs.config.energy.max or 100), energy_low + 15)
    self.job_data = self.job_data or {}
    if self.job_data.resting then
	  local rest_pos = self.job_data.rest_pos
	  if not rest_pos then
		self.job_data.resting = nil
		cancel_rest_navigation(self)
		return
	  end
	  if self:get_nearest_enemy(10) then
		self.job_data.resting = nil
		self.job_data.rest_pos = nil
		cancel_rest_navigation(self)
		self:set_state_info("Le danger interrompt mon repos.")
		return
	  end
	  if vector.distance(self.object:get_pos(), rest_pos) > 1.6 then
		self:set_displayed_action("cherche un abri")
		self:set_state_info(self:has_home() and "Je rentre me reposer dans mon lit." or
			"Je rejoins un abri de secours pour me reposer.")
		advance_rest_navigation(self, rest_pos)
		return
	  end
	  cancel_rest_navigation(self)
	  self.object:set_velocity({x = 0, y = 0, z = 0})
	  self:set_displayed_action("repos")
	  self:set_state_info(self:has_home() and "Je me repose dans mon logement." or
		"Je recupere dans un abri de secours.")
	  self:set_animation(working_villages.animation_frames.SIT)
	  local recovery_rate = self:has_home() and 1.2 or 0.45
	  working_villages.needs.adjust(self, "energy", recovery_rate * dtime)
      if working_villages.needs.get(self, "energy") >= energy_recover then
        self.job_data.resting = nil
		self.job_data.rest_pos = nil
		self.job_data.rest_retry_remaining = nil
        self:set_displayed_action("actif")
        self:set_state_info("Je me sens mieux.")
      end
      return
    end
    if energy <= energy_low then
	  if rest_retry_is_waiting(self, dtime) then
		self:set_displayed_action("abri inaccessible")
		self:set_state_info("Je recupere avant de chercher un autre chemin vers un abri.")
		return
	  end
	  local rest_pos = get_emergency_shelter_pos(self)
	  if not rest_pos then
		self:set_displayed_action("cherche un abri")
		self:set_state_info("Je suis epuise mais je n'ai ni logement ni abri praticable.")
		return
	  end
	  self.job_data.resting = true
	  self.job_data.rest_pos = vector.round(rest_pos)
	  self.job_data.rest_retry_remaining = nil
	  self:set_displayed_action("cherche un abri")
	  self:set_state_info(self:has_home() and "Je rentre me reposer dans mon lit." or
		"Je cherche un abri de secours pour me reposer.")
      return
    end

    -- Physical deliveries are advanced from the engine callback one safe
    -- navigation step at a time. They run only after danger, hunger and
    -- fatigue handling, and suspend the profession coroutine so it cannot
    -- overwrite the delivery velocity. pending_resource_message is part of
    -- job_data, therefore a world save/reload resumes the same transfer.
    if physical_delivery_coordination.handle_incoming(self, dtime) then
      return
    end
    -- The autonomous worker is the only role able to create the first shared
    -- chest from a completely empty village.  Before that chest exists, do
    -- not let unrelated outbound requests monopolise its profession coroutine:
    -- suppliers can still walk resources to it through handle_incoming above,
    -- and queued requests remain untouched until the infrastructure is ready.
    local initial_bootstrap_reserved = self:get_job_name() == "working_villages:job_autonome"
      and not is_chest_pos(get_shared_storage_pos(self.owner_name))
    if resource_requests_due and not initial_bootstrap_reserved then
      local delivery_busy = self:process_resource_requests()
      if delivery_busy then
        return
      end
    end

    local proposal = self.job_data and self.job_data.plan_proposal
    if proposal and proposal.permission_key then
      local requests = self.job_data.permission_requests
      local req = requests and requests[proposal.permission_key]
      if req and req.status == "approved" then
        local ok, err = working_villages.blueprint_experiments.apply_proposal(proposal)
        if ok then
          self.job_data.learning_note = "Plan mis a jour (.we) : " .. (proposal.blueprint.description or "plan")
          if self.notify_owner then
            self:notify_owner("Plan sauvegarde : " .. (proposal.blueprint.description or "plan"))
          end
        else
          if self.notify_owner then
            self:notify_owner("Echec sauvegarde plan : " .. (err or "erreur inconnue"))
          end
        end
        requests[proposal.permission_key] = nil
        self.job_data.plan_proposal = nil
      elseif req and req.status == "rejected" then
        if self.notify_owner then
          self:notify_owner("Proposition de plan rejetee.")
        end
        requests[proposal.permission_key] = nil
        self.job_data.plan_proposal = nil
      end
    end

    job_coroutines.resume(self,dtime)
  end

  -- on_rightclick is a callback function that is called when a player right-click them.
  local function on_rightclick(self, clicker)
    local wielded_stack = clicker:get_wielded_item()
    if wielded_stack:get_name() == "working_villages:commanding_sceptre"
      and working_villages.can_manage_villager
      and working_villages.can_manage_villager(self, clicker) then

      forms.show_formspec(self, "working_villages:inv_gui", clicker:get_player_name())
    else
      forms.show_formspec(self, "working_villages:talking_menu", clicker:get_player_name())
    end
  end

  -- on_punch is a callback function that is called when a player punches a villager.
  local function on_punch(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
    self.job_data = self.job_data or {}
    -- Returning true suppresses Luanti's default damage mechanism. This lets
    -- the mod apply armor and public-server policy before a fatal hit rather
    -- than attempting to restore HP after the entity may already be gone.
    if not working_villages.survival.player_can_damage(self, puncher) then
      return true
    end

    local danger_was_active = self.job_data.danger_ticks and self.job_data.danger_ticks > 0
    working_villages.survival.note_attack(self, puncher)
    local puncher_pos = nil
    if puncher and type(puncher.get_pos) == "function" then
      local pos_ok, pos = pcall(puncher.get_pos, puncher)
      if pos_ok then
        puncher_pos = pos
      end
    end
    if not danger_was_active and puncher_pos and working_villages.record_village_threat then
      working_villages.record_village_threat(self.owner_name, puncher_pos, "villager_hit")
    end
    if working_villages.survival.is_activation_protected(self) then
      return true
    end

    local shield_block = false
    if has_shield(self) and puncher and face_dot(self, puncher) > 0.2 then
      shield_block = true
      self.job_data.blocking_ticks = 12
    end
    local raw_damage = working_villages.survival.fallback_raw_damage(tool_capabilities, damage)
    local applied_damage = working_villages.survival.effective_damage(
      raw_damage, get_armor_reduction(self), shield_block)
    local before_hp = self.object:get_hp() or 0
    if applied_damage > 0 and before_hp > 0 then
      self.object:set_hp(math.max(0, before_hp - applied_damage))
    end
    return true
  end

  -- register a definition of a new villager.

  local villager_def = working_villages.villager:new({
    initial_properties = {
      hp_max                      = working_villages.survival.max_hp(def.hp_max),
      weight                      = def.weight,
      mesh                        = def.mesh,
      textures                    = def.textures,

      -- Entity properties still need to be registered on the definition itself.
      physical                    = true,
      visual                      = "mesh",
      visual_size                 = {x = 1, y = 1},
      collisionbox                = {-0.25, 0, -0.25, 0.25, 1.75, 0.25},
      pointable                   = true,
      stepheight                  = 0.6,
      is_visible                  = true,
      makes_footstep_sound        = true,
      automatic_face_movement_dir = false,
      infotext                    = "",
      nametag                     = "",
      static_save                 = true,
    }
  })

  -- extra initial properties
  villager_def.pause                       = false
  villager_def.type                        = "npc"
  villager_def.disp_action                 = "inactif\nAucun metier"
  villager_def.state                       = "job"
  villager_def.state_info                  = "Je ne fais rien de particulier."
  villager_def.job_thread                  = false
  villager_def.product_name                = ""
  villager_def.manufacturing_number        = -1
  villager_def.owner_name                  = ""
  villager_def.time_counters               = {}
  villager_def.destination                 = vector.new(0,0,0)
  villager_def.job_data                    = {}
  villager_def.pos_data                    = {}
  villager_def.new_job                     = ""

  -- callback methods
  villager_def.on_activate                 = on_activate
  villager_def.on_step                     = on_step
  villager_def.on_rightclick               = on_rightclick
  villager_def.on_punch                    = on_punch
  villager_def.get_staticdata              = get_staticdata
  villager_def._serialize_persistent_state = serialize_persistent_state
  villager_def.on_deactivate               = on_deactivate
  villager_def.get_emergency_shelter_pos   = get_emergency_shelter_pos
  villager_def.advance_rest_navigation     = advance_rest_navigation
  villager_def.rest_retry_is_waiting       = rest_retry_is_waiting

  -- storage methods
  villager_def.get_stored_table            = working_villages.get_stored_villager_table
  villager_def.set_stored_table            = working_villages.set_stored_villager_table
  villager_def.clear_cached_table          = working_villages.clear_cached_villager_table

  -- home methods
  villager_def.get_home                    = working_villages.get_home
  villager_def.has_home                    = working_villages.is_valid_home
  villager_def.set_home                    = working_villages.set_home
  villager_def.remove_home                 = working_villages.remove_home


  minetest.register_entity(name, villager_def)

  -- register villager egg.
  working_villages.register_egg(name .. "_egg", {
    description     = name .. " oeuf",
    inventory_image = def.egg_image,
    product_name    = name,
  })
end
