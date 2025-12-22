working_villages.register_job("working_villages:job_empty", {
	description      = "vide (working_villages)",
	inventory_image  = "default_paper.png",
	jobfunc          = function() end,
})

-- only a recipe of the empty job is registered.
-- other job is created by writing on the empty job.
minetest.register_craft{
	output = "working_villages:job_empty",
	recipe = {
		{working_villages.voxelibre_compat.get_item("default:paper"), working_villages.voxelibre_compat.get_item("default:obsidian")},
	},
}
