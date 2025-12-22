-- Get the appropriate player model for the current game
local voxelibre_compat = working_villages.voxelibre_compat
local player_mesh = voxelibre_compat.get_player_mesh()
local male_textures = voxelibre_compat.format_textures(player_mesh, "villager_male.png")

working_villages.register_villager("working_villages:villager_male", {
	hp_max     = 30,
	weight     = 20,
	mesh       = player_mesh,
	textures   = male_textures,
	egg_image  = "villager_male_egg.png",
})
local product_name = "working_villages:villager_female"
local texture_name = "villager_female.png"
local female_textures = voxelibre_compat.format_textures(player_mesh, texture_name)
local egg_img_name = "villager_female_egg.png"
working_villages.register_villager(product_name, {
	hp_max     = 20,
	weight     = 18,
	mesh       = player_mesh,
	textures   = female_textures,
	egg_image  = egg_img_name,
})
