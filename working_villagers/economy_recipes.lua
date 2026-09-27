-- Small cross-game recipes which close otherwise impossible agricultural
-- bootstrap loops.  Every output is backed by a normal Luanti recipe: no job
-- or villager receives free inventory here.

local economy = {
	enabled = false,
	straw_bundle = "working_villages:straw_bundle",
	flatbread = "working_villages:flatbread",
}

local compat = working_villages.compat or working_villages.voxelibre_compat
local profile = working_villages.game_profile or (compat and compat.game_profile) or {}

local function first_registered(candidates)
	for _, name in ipairs(candidates or {}) do
		if minetest.registered_items[name] then
			return name
		end
	end
	return nil
end

local grain_candidates = profile.is_voxelibre and {
	"mcl_farming:wheat_item",
} or {
	"farming:wheat",
}

economy.grain = first_registered(grain_candidates)
-- Only the bottom half is ever placed/crafted here: both supported games
-- auto-place the matching top half from it, so there is no recipe use for
-- a separate bed_top item reference.
economy.bed_bottom = compat and compat.get_item("beds:bed_bottom") or nil

if not economy.grain
		or not economy.bed_bottom
		or not minetest.registered_items[economy.bed_bottom] then
	minetest.log("warning", "[working_villages] Agricultural economy recipes disabled: " ..
		"registered wheat or bed output is unavailable for profile " .. tostring(profile.id))
	return economy
end

local grain_def = minetest.registered_items[economy.grain] or {}
local straw_image = grain_def.inventory_image or grain_def.wield_image or ""
if straw_image == "" then
	straw_image = profile.is_voxelibre and "farming_wheat_harvested.png" or "farming_wheat.png"
end

local eat_flatbread = minetest.item_eat(4)

minetest.register_craftitem(economy.straw_bundle, {
	description = "Botte de paille liee",
	inventory_image = straw_image .. "^[brighten",
	groups = {
		flammable = 2,
		compostability = 65,
	},
	stack_max = profile.is_voxelibre and 64 or 99,
})

minetest.register_craftitem(economy.flatbread, {
	description = "Pain plat de village",
	inventory_image = "farming_bread.png^[colorize:#C9964C:24",
	wield_image = "farming_bread.png^[colorize:#C9964C:24",
	on_use = eat_flatbread,
	on_place = eat_flatbread,
	on_secondary_use = eat_flatbread,
	groups = {
		food = 2,
		eatable = 4,
		flammable = 1,
		compostability = 65,
	},
	_mcl_saturation = 3.6,
	stack_max = profile.is_voxelibre and 64 or 99,
	touch_interaction = "short_dig_long_place",
})

-- Three harvested wheat items make one compact mattress component.  Keeping
-- this recipe at three inputs and the bed at 2x2 lets a five-villager village
-- bootstrap before it owns a crafting table, while still consuming six crops
-- and two real planks for one bed.
minetest.register_craft({
	type = "shapeless",
	output = economy.straw_bundle,
	recipe = {
		economy.grain,
		economy.grain,
		economy.grain,
	},
})

minetest.register_craft({
	output = economy.bed_bottom,
	recipe = {
		{economy.straw_bundle, economy.straw_bundle},
		{"group:wood", "group:wood"},
	},
})

-- A cook can now turn the farmer's primary crop into a real food output in
-- either supported game.  One input produces exactly one output; furnace
-- fuel remains an independent, normally consumed resource.
minetest.register_craft({
	type = "cooking",
	output = economy.flatbread,
	recipe = economy.grain,
	cooktime = 8,
})

economy.enabled = true
minetest.log("action", "[working_villages] Agricultural bed and flatbread recipes enabled for " ..
	tostring(profile.id))

return economy
