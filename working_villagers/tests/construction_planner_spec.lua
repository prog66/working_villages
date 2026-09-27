-- Deterministic blueprint ordering and safe-site regression.

local modpath = (arg and arg[1]) or "working_villagers"

local function key(pos)
	return table.concat({pos.x, pos.y, pos.z}, ":")
end

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected)
			.. ", got " .. tostring(actual), 2)
	end
end

local nodes = {}
local protected_positions = {}
local groups = {
	["test:torch"] = {attached_node = 1, torch = 1},
	["test:chest"] = {chest = 1},
	["test:water"] = {liquid = 1},
}

_G.minetest = {
	registered_nodes = {
		air = {buildable_to = true, walkable = false, liquidtype = "none"},
		["test:stone"] = {buildable_to = false, walkable = true, liquidtype = "none"},
		["test:wood"] = {buildable_to = false, walkable = true, liquidtype = "none"},
		["test:torch"] = {buildable_to = false, walkable = false, liquidtype = "none"},
		["test:chest"] = {buildable_to = false, walkable = true, liquidtype = "none"},
		["test:water"] = {buildable_to = true, walkable = false, liquidtype = "source"},
	},
	get_item_group = function(name, group)
		return groups[name] and groups[name][group] or 0
	end,
	get_node_or_nil = function(pos)
		return {name = nodes[key(pos)] or (pos.y == 0 and "test:stone" or "air")}
	end,
	is_protected = function(pos)
		return protected_positions[key(pos)] == true
	end,
}

local planner = dofile(modpath .. "/construction_planner.lua")
local prepared = planner.prepare_nodes({
	{pos = {x = 0, y = 1, z = 0}, node = {name = "test:torch"}},
	{pos = {x = 0, y = 0, z = 0}, node = {name = "test:wood"}},
	{pos = {x = 1, y = 0, z = 0}, node = {name = "test:wood"}},
})
assert_equal(#prepared, 4, "planner did not fill the bounded interior")
assert_equal(prepared[1].node.name, "air", "interior clearing was not scheduled first")
assert_equal(prepared[#prepared].node.name, "test:torch", "attached node was not scheduled last")
assert_equal(prepared[2].pos.y, 0, "foundation ordering is not bottom-up")
print("CONSTRUCTION_PLAN_ORDER_SPEC_OK")

local offsets = planner.candidate_offsets(4, 6, 2)
assert(#offsets >= 8, "site planner produced too few deterministic candidates")
assert_equal(offsets[1].x, -4, "candidate ordering changed")
assert_equal(offsets[1].z, -4, "candidate ordering changed")

local site_nodes = planner.prepare_nodes({
	{pos = {x = 0, y = 1, z = 0}, node = {name = "test:wood"}},
	{pos = {x = 1, y = 1, z = 0}, node = {name = "test:wood"}},
})
local marker = {x = -2, y = 1, z = -2}
local valid, reason = planner.validate_site({owner_name = "owner"}, site_nodes, marker)
assert(valid, "flat clear site was rejected: " .. tostring(reason))

nodes[key({x = 1, y = 1, z = 0})] = "test:chest"
valid, reason = planner.validate_site({owner_name = "owner"}, site_nodes, marker)
assert(not valid and reason == "volume occupe", "existing infrastructure was not rejected")
nodes = {}
protected_positions[key({x = 0, y = 1, z = 0})] = true
valid, reason = planner.validate_site({owner_name = "owner"}, site_nodes, marker)
assert(not valid and reason == "volume protege", "protected volume was not rejected")
protected_positions = {}
nodes[key({x = 0, y = 0, z = 0})] = "test:water"
valid, reason = planner.validate_site({owner_name = "owner"}, site_nodes, marker)
assert(not valid and reason == "terrain non plat ou fragile", "liquid foundation was not rejected")
print("CONSTRUCTION_SITE_VALIDATION_SPEC_OK")
