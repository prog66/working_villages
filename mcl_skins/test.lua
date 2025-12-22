-- Test file for mcl_skins mod
-- This file can be used to manually test the mcl_skins functionality

-- Test 1: Check if mcl_skins global is available
assert(mcl_skins, "mcl_skins global should be available")
print("[mcl_skins_test] ✓ mcl_skins global is available")

-- Test 2: Check if base_color table exists
assert(mcl_skins.base_color, "mcl_skins.base_color should exist")
assert(#mcl_skins.base_color > 0, "mcl_skins.base_color should have colors")
print("[mcl_skins_test] ✓ base_color table exists with " .. #mcl_skins.base_color .. " colors")

-- Test 3: Check if color table exists
assert(mcl_skins.color, "mcl_skins.color should exist")
assert(#mcl_skins.color > 0, "mcl_skins.color should have colors")
print("[mcl_skins_test] ✓ color table exists with " .. #mcl_skins.color .. " colors")

-- Test 4: Check if API functions exist
assert(type(mcl_skins.register_item) == "function", "mcl_skins.register_item should be a function")
assert(type(mcl_skins.show_formspec) == "function", "mcl_skins.show_formspec should be a function")
assert(type(mcl_skins.get_skin_list) == "function", "mcl_skins.get_skin_list should be a function")
assert(type(mcl_skins.get_node_id_by_player) == "function", "mcl_skins.get_node_id_by_player should be a function")
assert(type(mcl_skins.save) == "function", "mcl_skins.save should be a function")
assert(type(mcl_skins.update_player_skin) == "function", "mcl_skins.update_player_skin should be a function")
assert(type(mcl_skins.compile_skin) == "function", "mcl_skins.compile_skin should be a function")
assert(type(mcl_skins.register_simple_skin) == "function", "mcl_skins.register_simple_skin should be a function")
print("[mcl_skins_test] ✓ All API functions are available")

-- Test 5: Check if player_skins table exists
assert(mcl_skins.player_skins, "mcl_skins.player_skins should exist")
assert(type(mcl_skins.player_skins) == "table", "mcl_skins.player_skins should be a table")
print("[mcl_skins_test] ✓ player_skins table exists")

-- Test 6: Test compile_skin function
local test_skin = {
	base = {texture = "base.png"},
	eye = {texture = "eye.png"},
	mouth = {texture = "mouth.png"},
}
local compiled = mcl_skins.compile_skin(test_skin)
assert(type(compiled) == "string", "compile_skin should return a string")
assert(compiled:find("base.png"), "compiled skin should contain base texture")
print("[mcl_skins_test] ✓ compile_skin function works: " .. compiled)

-- Test 7: Test register_simple_skin function
mcl_skins.register_simple_skin({
	texture = "test_character.png",
	slim_arms = false,
})
local skin_list = mcl_skins.get_skin_list()
assert(#skin_list > 0, "skin_list should have at least one skin")
print("[mcl_skins_test] ✓ register_simple_skin and get_skin_list work")

-- Test 8: Test register_item function
local test_item_count = 0
local function count_items()
	-- This is a simple test, actual counting would require access to internal tables
	test_item_count = test_item_count + 1
end

mcl_skins.register_item({
	type = "hair",
	texture = "test_hair.png",
	mask = "test_hair_mask.png",
	rank = 70,
})
count_items()
print("[mcl_skins_test] ✓ register_item function works")

print("[mcl_skins_test] All tests passed! ✓")
