local init = os.clock()
minetest.log("action", "["..minetest.get_current_modname().."] loading init")

working_villages={
	modpath = minetest.get_modpath("working_villages"),
}

if not minetest.get_modpath("modutil") then
    local portable_path = working_villages.modpath.."/modutil/portable.lua"
    local file = io.open(portable_path, "r")
    if file then
        file:close()
        dofile(portable_path)
    else
        error("\n\n" ..
            "================================================================================\n" ..
            "ERROR: modutil submodule not initialized!\n" ..
            "================================================================================\n" ..
            "The modutil submodule is required but the files are missing.\n" ..
            "\n" ..
            "To fix this, run the following command in your working_villages directory:\n" ..
            "  git submodule update --init\n" ..
            "\n" ..
            "Or if you haven't cloned yet, use:\n" ..
            "  git clone --recursive https://github.com/theFox6/working_villages.git\n" ..
            "\n" ..
            "Alternatively, you can install the 'modutil' mod separately.\n" ..
            "See README.MD for more details.\n" ..
            "================================================================================\n")
    end
end

modutil.require("local_require")(working_villages)
local log = working_villages.require("log")

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

-- Load VoxeLibre compatibility layer early
working_villages.voxelibre_compat = working_villages.require("voxelibre_compat")
working_villages.farming_compat = working_villages.require("farming_compat")
if working_villages.voxelibre_compat.is_voxelibre then
  log.action("VoxeLibre detected - enabling compatibility mode")
else
  log.action("minetest_game detected - using standard mode")
end

working_villages.require("groups")
--TODO: check for which preloading is needed
--content
working_villages.require("forms")
working_villages.require("talking")
working_villages.require("guard_forms")
--TODO: instead use the building sign mod when it is ready
working_villages.require("building")
working_villages.require("storage")
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
working_villages.require("register")
working_villages.require("commanding_sceptre")

working_villages.require("deprecated")

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
-- new specialized jobs
working_villages.require("jobs/blacksmith")
working_villages.require("jobs/miner")
-- autonomous job
working_villages.require("jobs/autonomous")
-- learner job (for villagers without a profession)
working_villages.require("jobs/learner")
--testing jobs
working_villages.require("jobs/torcher")
working_villages.require("jobs/snowclearer")

if working_villages.setting_enabled("spawn",false) then
  working_villages.require("spawn")
end

if working_villages.setting_enabled("debug_tools",false) then
  working_villages.require("util_test")
end

--ready
local time_to_load= os.clock() - init
log.action("loaded init in %.4f s", time_to_load)
