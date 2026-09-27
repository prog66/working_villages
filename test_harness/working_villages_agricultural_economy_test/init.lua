local TEST_NAME = "working_villages_agricultural_economy_test"

local function fail(message)
	error("[" .. TEST_NAME .. "] " .. tostring(message), 2)
end

local function assert_true(value, message)
	if not value then
		fail(message or "expected a truthy value")
	end
end

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		fail((message or "values differ") .. ": got " .. tostring(actual)
			.. ", expected " .. tostring(expected))
	end
end

local function count_item(inv, item_name)
	local count = 0
	for _, stack in ipairs(inv:get_list("main") or {}) do
		if stack:get_name() == item_name then
			count = count + stack:get_count()
		end
	end
	return count
end

local function inventory_total(inv)
	local total = 0
	for _, stack in ipairs(inv:get_list("main") or {}) do
		total = total + stack:get_count()
	end
	return total
end

local function make_crafter()
	local inv_name = TEST_NAME .. "_" .. tostring(minetest.get_us_time())
	local inv = minetest.create_detached_inventory(inv_name, {})
	inv:set_size("main", 16)
	local villager = {
		job_data = {},
		object = {
			get_pos = function()
				return {x = 0, y = 1, z = 0}
			end,
		},
		get_inventory = function()
			return inv
		end,
		add_item_to_main = function(_, stack)
			return inv:add_item("main", stack)
		end,
		take_from_shared_storage = function()
			return 0
		end,
		take_from_shared_storage_by_predicate = function()
			return 0
		end,
		set_displayed_action = function() end,
		set_state_info = function() end,
	}
	return villager, inv
end

local function choose_wood_chain()
	local compat = working_villages.compat
	local pairs = {
		{compat.get_item("default:tree"), compat.get_item("default:wood")},
		{"default:tree", "default:wood"},
		{"mcl_core:tree", "mcl_core:wood"},
	}
	for _, names in ipairs(pairs) do
		local log_name, plank_name = names[1], names[2]
		if minetest.registered_items[log_name]
				and minetest.registered_items[plank_name]
				and minetest.get_item_group(log_name, "tree") > 0
				and minetest.get_item_group(plank_name, "wood") > 0 then
			local output, decremented = minetest.get_craft_result({
				method = "normal",
				width = 1,
				items = {ItemStack(log_name)},
			})
			if output and output.item
					and output.item:get_name() == plank_name
					and output.item:get_count() >= 2
					and ItemStack(decremented.items[1] or ""):is_empty() then
				return log_name, plank_name, output.item:get_count()
			end
		end
	end
	fail("active profile exposes no exact one-log to planks recipe")
end

local function assert_cooking_exact(chain, profile_id)
	local flatbread_def = minetest.registered_items[chain.flatbread]
	assert_true(flatbread_def ~= nil, "flatbread output is not registered")
	assert_true(minetest.get_item_group(chain.flatbread, "food") > 0,
		"flatbread is not visible to villager food logic")
	assert_true(minetest.get_item_group(chain.flatbread, "eatable") > 0,
		"flatbread is not edible in the active game")
	assert_true(type(flatbread_def.on_use) == "function"
		or type(flatbread_def.on_place) == "function",
		"flatbread has no real eating callback")

	local input = ItemStack(chain.grain .. " 2")
	local first, first_decremented = minetest.get_craft_result({
		method = "cooking",
		width = 1,
		items = {input},
	})
	assert_equal(first.item:get_name(), chain.flatbread,
		"wheat cooking selected the wrong output")
	assert_equal(first.item:get_count(), 1,
		"one cooking operation did not produce exactly one flatbread")
	assert_true(tonumber(first.time) and first.time > 0,
		"flatbread cooking time is not positive")
	local remaining = ItemStack(first_decremented.items[1] or "")
	assert_equal(remaining:get_name(), chain.grain,
		"first cooking operation changed the remaining input")
	assert_equal(remaining:get_count(), 1,
		"first cooking operation did not consume exactly one wheat")

	local second, second_decremented = minetest.get_craft_result({
		method = "cooking",
		width = 1,
		items = {remaining},
	})
	assert_equal(second.item:get_name(), chain.flatbread,
		"second wheat cooking selected the wrong output")
	assert_equal(second.item:get_count(), 1,
		"second cooking operation did not produce exactly one flatbread")
	assert_true(ItemStack(second_decremented.items[1] or ""):is_empty(),
		"second cooking operation did not consume the final wheat")
	assert_equal(first.item:get_count() + second.item:get_count(), 2,
		"two wheat did not account to exactly two flatbreads")

	minetest.log("action", "AGRICULTURAL_FLATBREAD_RECIPE_OK:" .. profile_id
		.. ":" .. chain.grain .. ":" .. chain.flatbread .. ":2>2")
end

local function assert_bed_chain_exact(chain, profile_id)
	local compat = working_villages.compat
	assert_equal(chain.bed_bottom, compat.get_item("beds:bed_bottom"),
		"economy bed output differs from the minimal_shelter schematic mapping")
	assert_true(minetest.registered_nodes[chain.bed_bottom] ~= nil,
		"mapped bed_bottom is not a registered node")
	assert_true(minetest.registered_nodes[chain.bed_top] ~= nil,
		"mapped bed_top is not a registered node")
	assert_true(compat.is_bed_top(chain.bed_top),
		"mapped bed top is not recognized by the builder")
	assert_true(minetest.get_item_group(chain.bed_bottom, "villager_bed_bottom") > 0,
		"mapped bed bottom is not recognized as a villager bed")
	assert_true(#(minetest.get_all_craft_recipes(chain.bed_bottom) or {}) > 0,
		"mapped bed bottom exposes no real craft recipe")

	local log_name, plank_name, plank_yield = choose_wood_chain()
	local villager, inv = make_crafter()
	inv:add_item("main", ItemStack(chain.grain .. " 6"))
	inv:add_item("main", ItemStack(log_name))
	assert_equal(inventory_total(inv), 7, "bed test initial inventory is not exact")

	local crafted, details = working_villages.crafting.ensure_item(
		villager,
		chain.bed_bottom,
		1,
		{
			use_shared_storage = false,
			force = true,
			max_depth = 5,
		}
	)
	assert_true(crafted, "production recursive crafting failed: "
		.. minetest.serialize(details or {}))
	assert_equal(count_item(inv, chain.bed_bottom), 1,
		"recursive crafting did not produce exactly one mapped bed_bottom")
	assert_equal(count_item(inv, chain.grain), 0,
		"recursive bed crafting did not consume exactly six wheat")
	assert_equal(count_item(inv, log_name), 0,
		"recursive bed crafting did not consume exactly one log")
	assert_equal(count_item(inv, plank_name), plank_yield - 2,
		"recursive bed crafting did not consume exactly two generated planks")
	assert_equal(count_item(inv, chain.straw_bundle), 0,
		"recursive bed crafting left an unaccounted straw intermediate")
	assert_equal(inventory_total(inv), 1 + plank_yield - 2,
		"recursive bed crafting created an unexpected extra item")
	for _, stack in ipairs(inv:get_list("main") or {}) do
		assert_true(stack:is_empty() or stack:get_name() == chain.bed_bottom
			or stack:get_name() == plank_name,
			"recursive bed crafting created unexpected item " .. stack:get_name())
	end

	minetest.log("action", "AGRICULTURAL_BED_RECIPE_OK:" .. profile_id
		.. ":" .. chain.grain .. "+" .. log_name .. ":6+1>1+"
		.. tostring(plank_yield - 2) .. ":" .. chain.bed_bottom)
end

local function run()
	local profile = working_villages.game_profile or {}
	local chain = working_villages.economy_recipes
	assert_true(profile.supported, "active game profile is unsupported")
	assert_true(chain and chain.enabled, "agricultural economy recipes are disabled")
	assert_true(minetest.registered_items[chain.grain] ~= nil,
		"profile wheat input is not registered")
	assert_true(minetest.registered_items[chain.straw_bundle] ~= nil,
		"straw intermediate is not registered")

	assert_cooking_exact(chain, profile.id)
	assert_bed_chain_exact(chain, profile.id)
	minetest.log("action", "WORKING_VILLAGES_AGRICULTURAL_ECONOMY_OK:" .. profile.id)
end

minetest.after(0, function()
	local ok, err = xpcall(run, debug.traceback)
	if not ok then
		minetest.log("error", tostring(err))
	end
	minetest.request_shutdown(
		ok and "working_villages agricultural economy tests completed"
			or "working_villages agricultural economy tests failed",
		false,
		0
	)
end)
