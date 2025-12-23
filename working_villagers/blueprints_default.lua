-- Default Blueprint Registrations
-- This file registers the default blueprints available to villagers

local blueprints = working_villages.blueprints
local compat = working_villages.voxelibre_compat

-- Simple house blueprint (beginner)
blueprints.register("simple_house", {
	category = blueprints.CATEGORY.HOUSE,
	difficulty = blueprints.DIFFICULTY.BEGINNER,
	description = "Une simple maison en bois avec un lit et une porte",
	schematic_file = "simple_hut.we",
	improvements = {
		{
			type = "replace_nodes",
			description = "Passer aux fondations en pierre",
			from = compat.get_item("default:wood"),
			to = compat.get_item("default:stone"),
		},
		{
			type = "add_decoration",
			description = "Ajouter des fenetres et decorations",
			nodes = {},  -- Would contain window positions
		},
	},
})

-- Fancy house blueprint (intermediate)
blueprints.register("fancy_house", {
	category = blueprints.CATEGORY.HOUSE,
	difficulty = blueprints.DIFFICULTY.INTERMEDIATE,
	description = "Une maison plus elaboree avec plusieurs pieces",
	schematic_file = "fancy_hut.we",
	improvements = {
		{
			type = "add_decoration",
			description = "Ajouter du mobilier et de l'eclairage",
			nodes = {},  -- Would contain torch and furniture positions
		},
		{
			type = "replace_nodes",
			description = "Ameliorer avec de meilleurs materiaux",
			from = compat.get_item("default:wood"),
			to = compat.get_item("default:junglewood"),
		},
	},
})

-- Farm plot blueprint (beginner)
blueprints.register("farm_plot", {
	category = blueprints.CATEGORY.FARM,
	difficulty = blueprints.DIFFICULTY.BEGINNER,
	description = "Un petit champ avec terre labouree",
	improvements = {
		{
			type = "add_nodes",
			description = "Ajouter des canaux d'irrigation",
			nodes = {},
		},
		{
			type = "add_decoration",
			description = "Ajouter une cloture autour de la ferme",
			nodes = {},
		},
	},
})

-- Workshop blueprint (intermediate)
blueprints.register("workshop", {
	category = blueprints.CATEGORY.WORKSHOP,
	difficulty = blueprints.DIFFICULTY.INTERMEDIATE,
	description = "Un atelier avec stockage",
	improvements = {
		{
			type = "add_nodes",
			description = "Ajouter des etablis et coffres",
			nodes = {},
		},
		{
			type = "add_decoration",
			description = "Ajouter eclairage et organisation",
			nodes = {},
		},
	},
})

-- Blacksmith forge (advanced)
blueprints.register("blacksmith_forge", {
	category = blueprints.CATEGORY.WORKSHOP,
	difficulty = blueprints.DIFFICULTY.ADVANCED,
	description = "Un atelier de forge avec forge et enclume",
	improvements = {
		{
			type = "replace_nodes",
			description = "Ameliorer avec des materiaux resistants a la chaleur",
			from = compat.get_item("default:wood"),
			to = compat.get_item("default:stone"),
		},
		{
			type = "add_nodes",
			description = "Ajouter des outils avances de forge",
			nodes = {},
		},
	},
})

-- Town square (advanced)
blueprints.register("town_square", {
	category = blueprints.CATEGORY.INFRASTRUCTURE,
	difficulty = blueprints.DIFFICULTY.ADVANCED,
	description = "Une place centrale pour le village",
	improvements = {
		{
			type = "add_decoration",
			description = "Ajouter des bancs et decorations",
			nodes = {},
		},
		{
			type = "add_nodes",
			description = "Ajouter une fontaine ou un monument",
			nodes = {},
		},
	},
})

-- Watchtower (intermediate)
blueprints.register("watchtower", {
	category = blueprints.CATEGORY.INFRASTRUCTURE,
	difficulty = blueprints.DIFFICULTY.INTERMEDIATE,
	description = "Une tour haute pour proteger le village",
	improvements = {
		{
			type = "add_nodes",
			description = "Ajouter echelle et plateformes",
			nodes = {},
		},
		{
			type = "replace_nodes",
			description = "Renforcer avec de la pierre",
			from = compat.get_item("default:wood"),
			to = compat.get_item("default:cobble"),
		},
		{
			type = "add_decoration",
			description = "Ajouter des torches et cloches d'alerte",
			nodes = {},
		},
	},
})

-- Garden (beginner)
blueprints.register("garden", {
	category = blueprints.CATEGORY.DECORATION,
	difficulty = blueprints.DIFFICULTY.BEGINNER,
	description = "Un jardin decoratif avec plantes et chemins",
	improvements = {
		{
			type = "add_decoration",
			description = "Ajouter des fleurs et plantes decoratives",
			nodes = {},
		},
		{
			type = "add_nodes",
			description = "Ajouter des chemins et bordures",
			nodes = {},
		},
	},
})

-- Minimal house (beginner) - only bed and door, no chest
blueprints.register("minimal_house", {
	category = blueprints.CATEGORY.HOUSE,
	difficulty = blueprints.DIFFICULTY.BEGINNER,
	description = "Une maison minimaliste avec seulement un lit et une porte",
	schematic_file = "minimal_house.we",
	improvements = {
		{
			type = "add_decoration",
			description = "Ajouter une fenêtre",
			nodes = {},
		},
		{
			type = "replace_nodes",
			description = "Améliorer les murs en pierre",
			from = compat.get_item("default:wood"),
			to = compat.get_item("default:stone"),
		},
	},
})

-- Minimal shelter (beginner) - very simple structure with only bed and door
blueprints.register("minimal_shelter", {
	category = blueprints.CATEGORY.HOUSE,
	difficulty = blueprints.DIFFICULTY.BEGINNER,
	description = "Un abri très simple avec juste un lit et une porte",
	schematic_file = "minimal_shelter.we",
	improvements = {
		{
			type = "replace_nodes",
			description = "Renforcer avec du bois dur",
			from = compat.get_item("default:wood"),
			to = compat.get_item("default:junglewood"),
		},
		{
			type = "add_decoration",
			description = "Ajouter un éclairage basique",
			nodes = {},
		},
	},
})

minetest.log("action", "[blueprints] Registered " .. 10 .. " default blueprints")
