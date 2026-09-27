local init = os.clock()
local modname = minetest.get_current_modname()
minetest.log("action", "["..modname.."] loading init")

working_villages={
	modpath = minetest.get_modpath(modname),
}

if not working_villages.modpath then
  error("[working_villages] Unable to resolve the mod path")
end

local function read_release_version()
  local version_file = io.open(working_villages.modpath.."/VERSION", "r")
  if not version_file then
    return "development"
  end
  local version = version_file:read("*l") or ""
  version_file:close()
  version = tostring(version):gsub("^%s+", ""):gsub("%s+$", "")
  if version == "" then
    return "development"
  end
  return version
end

working_villages.release_version = read_release_version()
minetest.log("action", "["..modname.."] version "..working_villages.release_version)

local loader = dofile(working_villages.modpath.."/loader.lua")
loader.install(working_villages)
local log = working_villages.require("log")
working_villages.village_registry = working_villages.require("village_registry")

function working_villages.setting_enabled(name, default)
  local b = minetest.settings:get_bool("working_villages_enable_"..name)
  if b == nil then
    if default == nil then
      return false
    end
    return default
  end
  return b
end

local configured_gameplay_mode = minetest.settings:get("working_villages_gameplay_mode") or "survival"
configured_gameplay_mode = tostring(configured_gameplay_mode):lower():gsub("^%s+", ""):gsub("%s+$", "")
if configured_gameplay_mode ~= "survival" and configured_gameplay_mode ~= "creative_test" then
  log.warning(
    "Invalid working_villages_gameplay_mode %q; falling back to survival",
    configured_gameplay_mode
  )
  configured_gameplay_mode = "survival"
end
working_villages.gameplay_mode = configured_gameplay_mode

function working_villages.is_survival_mode()
  return working_villages.gameplay_mode == "survival"
end

-- Load unified VoxeLibre/minetest_game compat layer early
working_villages.compat = working_villages.require("compat/vl")
working_villages.voxelibre_compat = working_villages.compat
working_villages.game_profile = working_villages.compat.game_profile or working_villages.compat.detect_profile()
working_villages.compat.game_profile = working_villages.game_profile
if not working_villages.game_profile.supported then
  error(
    "[working_villages] Unsupported game: expected VoxeLibre (mcl_core) " ..
    "or minetest_game (default)"
  )
end
working_villages.needs = working_villages.require("needs")
working_villages.memory = working_villages.require("memory")
working_villages.survival = working_villages.require("survival")
working_villages.ai_decision = working_villages.require("ai_decision")
working_villages.permissions = working_villages.require("permissions")
working_villages.inventory_access = working_villages.require("inventory_access")
working_villages.farming_compat = working_villages.require("farming_compat")
working_villages.crop_planner = working_villages.require("crop_planner")
working_villages.construction_planner = working_villages.require("construction_planner")
working_villages.blueprint_experiments = working_villages.require("blueprint_experiments")
working_villages.hud = working_villages.require("hud")
working_villages.communication = working_villages.require("communication")
working_villages.collaborative_tasks = working_villages.require("collaborative_tasks")
if working_villages.game_profile.is_voxelibre then
  log.action("VoxeLibre detected - enabling compatibility mode")
else
  log.action("minetest_game detected - using standard mode")
end

working_villages.require("groups")
working_villages.economy_recipes = working_villages.require("economy_recipes")
--TODO: check for which preloading is needed
--content
working_villages.access = working_villages.require("access")
working_villages.require("forms")
working_villages.require("talking")
working_villages.require("guard_forms")
--TODO: instead use the building sign mod when it is ready
working_villages.require("building")
working_villages.require("storage")
working_villages.population = working_villages.require("population")
-- Blueprint learning and management system
working_villages.blueprints = working_villages.require("blueprints")
working_villages.require("blueprints_default")
working_villages.blueprint_construction = working_villages.require("blueprint_construction")
working_villages.require("blueprint_forms")

-- Enhanced AI and job pattern systems
working_villages.job_patterns = working_villages.require("job_patterns")
working_villages.ai_behavior = working_villages.require("ai_behavior")

--base
working_villages.require("api")
working_villages.crafting = working_villages.require("crafting")
working_villages.work_fallback = working_villages.require("work_fallback")
working_villages.require("register")
working_villages.require("commanding_sceptre")

--job helpers
working_villages.require("jobs/util")
working_villages.require("jobs/empty")
--base jobs
working_villages.require("jobs/builder")
working_villages.require("jobs/follow_player")
working_villages.require("jobs/guard")
working_villages.require("jobs/plant_collector")
working_villages.require("jobs/farmer")
working_villages.require("jobs/woodcutter")
working_villages.require("jobs/cook")
-- new specialized jobs
working_villages.require("jobs/blacksmith")
working_villages.require("jobs/miner")
working_villages.require("jobs/trader")
-- autonomous job
working_villages.require("jobs/autonomous")
-- learner job (for villagers without a profession)
working_villages.require("jobs/learner")
--testing jobs
working_villages.require("jobs/torcher")
working_villages.require("jobs/snowclearer")

working_villages.require("spawn")

minetest.register_on_newplayer(function(player)
  if working_villages.gameplay_mode ~= "creative_test" then
    return
  end
  if not player or not player:is_player() then
    return
  end
  local inv = player:get_inventory()
  if inv and not inv:contains_item("main", "working_villages:commanding_sceptre") then
    local leftover = inv:add_item("main", "working_villages:commanding_sceptre")
    if leftover and not leftover:is_empty() then
      minetest.add_item(player:get_pos(), leftover)
    end
  end
end)

if working_villages.setting_enabled("debug_tools",false) then
  working_villages.require("util_test")
end

-- Collaborative task registry
working_villages.collaborative_tasks.register_task("large_building", {
	required_jobs = {"working_villages:job_builder", "working_villages:job_woodcutter"},
	min_villagers = 2,
	radius = 30,
	description = "Construction collaborative (grand batiment)",
})

working_villages.collaborative_tasks.register_task("danger_response", {
	required_jobs = {"working_villages:job_guard"},
	min_villagers = 2,
	radius = 40,
	description = "Reponse a une alerte de danger",
})

working_villages.collaborative_tasks.register_task("resource_delivery", {
	required_jobs = {"working_villages:job_woodcutter", "working_villages:job_builder"},
	min_villagers = 2,
	radius = 30,
	description = "Livraison de materiaux pour chantier",
})

working_villages.collaborative_tasks.register_task("food_support", {
	required_jobs = {"working_villages:job_farmer", "working_villages:job_cook"},
	min_villagers = 2,
	radius = 30,
	timeout = 300,
	description = "Collecte, cuisson et livraison de nourriture",
})

working_villages.collaborative_tasks.register_task("mining_tool_supply", {
	required_jobs = {"working_villages:job_miner", "working_villages:job_blacksmith"},
	min_villagers = 2,
	radius = 30,
	timeout = 600,
	description = "Fabrication et livraison d'un outil de mine",
})

--ready
local time_to_load= os.clock() - init
log.action("loaded init in %.4f s", time_to_load)
