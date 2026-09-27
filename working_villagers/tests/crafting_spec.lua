local modpath = (arg and arg[1]) or "working_villagers"

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) ..
			", got " .. tostring(actual), 2)
	end
end

local Stack = {}
Stack.__index = Stack

local function stack_from(value)
	if getmetatable(value) == Stack then
		return setmetatable({name = value.name, count = value.count}, Stack)
	end
	if type(value) == "table" and value.name then
		return setmetatable({name = value.name, count = tonumber(value.count) or 1}, Stack)
	end
	local name, count = tostring(value or ""):match("^(%S+)%s*(%d*)$")
	if not name or name == "" then
		return setmetatable({name = "", count = 0}, Stack)
	end
	return setmetatable({name = name, count = tonumber(count) or 1}, Stack)
end

function Stack:is_empty()
	return self.name == "" or self.count <= 0
end

function Stack:get_name()
	return self:is_empty() and "" or self.name
end

function Stack:get_count()
	return self:is_empty() and 0 or self.count
end

function Stack:take_item(count)
	count = math.min(tonumber(count) or 1, self:get_count())
	local taken = stack_from({name = self.name, count = count})
	self.count = self.count - count
	if self.count <= 0 then
		self.name = ""
		self.count = 0
	end
	return taken
end

function Stack:to_string()
	if self:is_empty() then
		return ""
	end
	return self.name .. (self.count > 1 and (" " .. self.count) or "")
end

_G.ItemStack = stack_from

local Inventory = {}
Inventory.__index = Inventory

function Inventory:new(items)
	local result = setmetatable({main = {}}, self)
	for index = 1, 16 do
		result.main[index] = stack_from(items and items[index] or "")
	end
	return result
end

function Inventory:get_list(name)
	local copy = {}
	for index, stack in ipairs(self[name] or {}) do
		copy[index] = stack_from(stack)
	end
	return copy
end

function Inventory:get_size(name)
	return #(self[name] or {})
end

function Inventory:get_stack(name, index)
	return stack_from((self[name] or {})[index] or "")
end

function Inventory:set_stack(name, index, stack)
	self[name][index] = stack_from(stack)
end

function Inventory:set_list(name, list)
	self[name] = {}
	for index, stack in ipairs(list or {}) do
		self[name][index] = stack_from(stack)
	end
end

function Inventory:add_item(name, incoming)
	local stack = stack_from(incoming)
	if stack:is_empty() then
		return stack
	end
	for _, current in ipairs(self[name]) do
		if not current:is_empty() and current:get_name() == stack:get_name() then
			current.count = current.count + stack:get_count()
			return stack_from("")
		end
	end
	for index, current in ipairs(self[name]) do
		if current:is_empty() then
			self[name][index] = stack
			return stack_from("")
		end
	end
	return stack
end

function Inventory:room_for_item()
	return true
end

local recipes = {
	["test:pick"] = {{
		method = "normal",
		width = 3,
		items = {
			[1] = "test:mat", [2] = "test:mat", [3] = "test:mat",
			[5] = "test:stick", [8] = "test:stick",
		},
		output = "test:pick",
	}},
	["test:meal"] = {{
		method = "normal",
		width = 2,
		items = {[1] = "test:water_bucket", [2] = "test:flour"},
		output = "test:meal",
	}},
	["test:furnace_stone"] = {{
		method = "normal",
		width = 1,
		items = {[1] = "group:stone"},
		output = "test:furnace_stone",
	}},
	["test:furnace_clay"] = {{
		method = "normal",
		width = 1,
		items = {[1] = "test:clay"},
		output = "test:furnace_clay",
	}},
	["test:furnace_bench"] = {{
		method = "normal",
		width = 3,
		items = {[1] = "test:mat", [2] = "test:mat", [3] = "test:mat"},
		output = "test:furnace_bench",
	}},
}

_G.vector = {
	subtract = function(a, b) return {x = a.x - b.x, y = a.y - b.y, z = a.z - b.z} end,
	add = function(a, b) return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z} end,
}

_G.minetest = {
	registered_items = {
		["test:pick"] = {}, ["test:mat"] = {}, ["test:stick"] = {},
		["test:meal"] = {}, ["test:water_bucket"] = {}, ["test:empty_bucket"] = {},
		["test:flour"] = {}, ["test:bonus"] = {},
		["test:furnace_stone"] = {}, ["test:furnace_clay"] = {},
		["test:furnace_bench"] = {}, ["test:clay"] = {},
	},
	get_all_craft_recipes = function(name)
		return recipes[name]
	end,
	get_craft_result = function(input)
		local function item_name(index)
			local stack = input.items[index]
			return stack and stack:get_name() or ""
		end
		if input.width == 3 and #input.items == 9 and
				item_name(1) == "test:mat" and item_name(2) == "test:mat" and
				item_name(3) == "test:mat" and item_name(4) == "" and
				item_name(5) == "test:stick" and item_name(6) == "" and
				item_name(7) == "" and item_name(8) == "test:stick" and item_name(9) == "" then
			local empty = {}
			for index = 1, 9 do empty[index] = stack_from("") end
			return {item = stack_from("test:pick"), replacements = {}}, {items = empty}
		end
		if input.width == 2 and item_name(1) == "test:water_bucket" and item_name(2) == "test:flour" then
			return {
				item = stack_from("test:meal"),
				replacements = {stack_from("test:bonus")},
			}, {
				items = {stack_from("test:empty_bucket"), stack_from("")},
			}
		end
		return {item = stack_from(""), replacements = {}}, {items = {}}
	end,
	get_item_group = function()
		return 0
	end,
	get_gametime = function()
		return 100
	end,
	find_nodes_in_area = function()
		return {}
	end,
	add_item = function()
		error("test inventory unexpectedly overflowed")
	end,
}

_G.working_villages = {
	gameplay_mode = "survival",
	compat = {
		is_voxelibre = false,
		get_crafting_table_items = function() return {} end,
		is_crafting_table = function() return false end,
	},
}

local crafting = dofile(modpath .. "/crafting.lua")

local function new_villager(items)
	local inv = Inventory:new(items)
	return {
		job_data = {},
		get_inventory = function() return inv end,
		add_item_to_main = function(_, stack) return inv:add_item("main", stack) end,
	}, inv
end

local function count_item(inv, name)
	local total = 0
	for _, stack in ipairs(inv:get_list("main")) do
		if stack:get_name() == name then
			total = total + stack:get_count()
		end
	end
	return total
end

local villager, inv = new_villager({"test:mat 3", "test:stick 2"})
assert_equal(select(1, crafting.ensure_item(villager, "test:pick", 1)), true,
	"sparse shaped recipe must craft")
assert_equal(count_item(inv, "test:pick"), 1, "pick output")
assert_equal(count_item(inv, "test:mat"), 0, "pick material consumption")
assert_equal(count_item(inv, "test:stick"), 0, "pick stick consumption")

local replacement_villager, replacement_inv = new_villager({"test:water_bucket", "test:flour"})
assert_equal(select(1, crafting.ensure_item(replacement_villager, "test:meal", 1)), true,
	"recipe with replacements must craft")
assert_equal(count_item(replacement_inv, "test:meal"), 1, "meal output")
assert_equal(count_item(replacement_inv, "test:empty_bucket"), 1,
	"replacement restored from decremented input")
assert_equal(count_item(replacement_inv, "test:bonus"), 1,
	"overflow replacement restored from output")
assert_equal(count_item(replacement_inv, "test:water_bucket"), 0, "filled bucket consumed")
assert_equal(count_item(replacement_inv, "test:flour"), 0, "flour consumed")

local diagnostic_villager = new_villager({})
diagnostic_villager.object = {get_pos = function() return {x = 0, y = 0, z = 0} end}
working_villages.compat.is_voxelibre = true
local selected, diagnostic = crafting.ensure_any_item(diagnostic_villager, {
	"test:furnace_stone",
	"test:furnace_clay",
	"test:furnace_bench",
}, 1, {force = true})
assert_equal(selected, nil, "unavailable utility candidate unexpectedly crafted")
assert_equal(diagnostic.missing_specs["group:stone"], 1,
	"ensure_any_item lost a missing group from an earlier candidate")
assert_equal(diagnostic.missing_items["test:clay"], 1,
	"ensure_any_item lost a missing concrete item from another candidate")
assert_equal(diagnostic.workstation_required, true,
	"ensure_any_item lost the workstation requirement of a candidate")

print("CRAFTING_SPEC_OK")
