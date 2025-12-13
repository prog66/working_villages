-- Default Blueprint Registrations
-- This file registers the default blueprints available to villagers

local blueprints = working_villages.blueprints
local compat = working_villages.voxelibre_compat

-- Simple house blueprint (beginner)
blueprints.register("simple_house", {
	category = blueprints.CATEGORY.HOUSE,
	difficulty = blueprints.DIFFICULTY.BEGINNER,
	description = "A simple wooden house with a bed and door",
	schematic_file = "simple_hut.we",
	improvements = {
		{
			type = "replace_nodes",
			description = "Upgrade to stone foundation",
			from = compat.get_item("default:wood"),
			to = compat.get_item("default:stone"),
		},
		{
			type = "add_decoration",
			description = "Add windows and decorations",
			nodes = {},  -- Would contain window positions
		},
	},
})

-- Fancy house blueprint (intermediate)
blueprints.register("fancy_house", {
	category = blueprints.CATEGORY.HOUSE,
	difficulty = blueprints.DIFFICULTY.INTERMEDIATE,
	description = "A more elaborate house with multiple rooms",
	schematic_file = "fancy_hut.we",
	improvements = {
		{
			type = "add_decoration",
			description = "Add furniture and lighting",
			nodes = {},  -- Would contain torch and furniture positions
		},
		{
			type = "replace_nodes",
			description = "Upgrade to better materials",
			from = compat.get_item("default:wood"),
			to = compat.get_item("default:junglewood"),
		},
	},
})

-- Farm plot blueprint (beginner)
blueprints.register("farm_plot", {
	category = blueprints.CATEGORY.FARM,
	difficulty = blueprints.DIFFICULTY.BEGINNER,
	description = "A small farming plot with tilled soil",
	improvements = {
		{
			type = "add_nodes",
			description = "Add irrigation channels",
			nodes = {},
		},
		{
			type = "add_decoration",
			description = "Add fence around the farm",
			nodes = {},
		},
	},
})

-- Workshop blueprint (intermediate)
blueprints.register("workshop", {
	category = blueprints.CATEGORY.WORKSHOP,
	difficulty = blueprints.DIFFICULTY.INTERMEDIATE,
	description = "A workshop building with storage",
	improvements = {
		{
			type = "add_nodes",
			description = "Add workbenches and storage chests",
			nodes = {},
		},
		{
			type = "add_decoration",
			description = "Add lighting and organization",
			nodes = {},
		},
	},
})

-- Blacksmith forge (advanced)
blueprints.register("blacksmith_forge", {
	category = blueprints.CATEGORY.WORKSHOP,
	difficulty = blueprints.DIFFICULTY.ADVANCED,
	description = "A blacksmith workshop with forge and anvil",
	improvements = {
		{
			type = "replace_nodes",
			description = "Upgrade to heat-resistant materials",
			from = compat.get_item("default:wood"),
			to = compat.get_item("default:stone"),
		},
		{
			type = "add_nodes",
			description = "Add advanced smithing tools",
			nodes = {},
		},
	},
})

-- Town square (advanced)
blueprints.register("town_square", {
	category = blueprints.CATEGORY.INFRASTRUCTURE,
	difficulty = blueprints.DIFFICULTY.ADVANCED,
	description = "A central gathering area for the village",
	improvements = {
		{
			type = "add_decoration",
			description = "Add benches and decorative elements",
			nodes = {},
		},
		{
			type = "add_nodes",
			description = "Add central fountain or monument",
			nodes = {},
		},
	},
})

-- Watchtower (intermediate)
blueprints.register("watchtower", {
	category = blueprints.CATEGORY.INFRASTRUCTURE,
	difficulty = blueprints.DIFFICULTY.INTERMEDIATE,
	description = "A tall tower for village protection",
	improvements = {
		{
			type = "add_nodes",
			description = "Add ladder and platform levels",
			nodes = {},
		},
		{
			type = "replace_nodes",
			description = "Reinforce with stone",
			from = compat.get_item("default:wood"),
			to = compat.get_item("default:cobble"),
		},
		{
			type = "add_decoration",
			description = "Add torches and warning bells",
			nodes = {},
		},
	},
})

-- Garden (beginner)
blueprints.register("garden", {
	category = blueprints.CATEGORY.DECORATION,
	difficulty = blueprints.DIFFICULTY.BEGINNER,
	description = "A decorative garden with plants and paths",
	improvements = {
		{
			type = "add_decoration",
			description = "Add flowers and decorative plants",
			nodes = {},
		},
		{
			type = "add_nodes",
			description = "Add paths and borders",
			nodes = {},
		},
	},
})

minetest.log("action", "[blueprints] Registered " .. 8 .. " default blueprints")
