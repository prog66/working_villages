max_line_length = 240

ignore = {
	--setting a read-only field of a global variable
	--"122",
	--unused globals
	--"131",
	--setting and acessing undefined fields of global variables
	--"14.",
	--unused variables and arguments
	"21.",
	--setting and never acessing variables
	"23.",
	--whitespace
	"61.",
	--TODO: check which ones these are
	"621",
	"631"
}

read_globals = {
	-- minetest
	"AreaStore",
	"dump",
	"minetest",
	"vector",
	"VoxelManip",
	"VoxelArea",
	"ItemStack",
	-- mods - minetest_game
	"default", "doors",
	-- mods - VoxeLibre
	"mcl_core", "mcl_doors", "mcl_beds", "mcl_chests", "mcl_farming", "mcl_torches", "mcl_sounds",
	-- special minetest functions
	"table.copy",
}

globals = {
	-- modpack mods
	"building_sign",
	"working_villages",
	"mcl_skins",
	-- submodule mods
	"modutil",
	"LuaVenusCompiler"
}

allow_defined_top = true

exclude_files = {
	-- development files
	"working_villagers/development",
	-- bad syntax is tested here
	"working_villagers/modutil/LuaVenusCompiler/testout"
}
