local OWNER_ALPHA = "wv_owner_alpha"
local OWNER_BETA = "wv_owner_beta"
local TIMEOUT_SECONDS = 120

local centers = {
	[OWNER_ALPHA] = {x = -20, y = 1, z = 0},
	[OWNER_BETA] = {x = 20, y = 1, z = 0},
}

local started_at
local completed = false

local function fail(message)
	if completed then return end
	completed = true
	minetest.log("error", "WORKING_VILLAGES_MULTIPLAYER_PROTECTION_FAIL:" .. message)
	minetest.request_shutdown("multiplayer protection runtime failed", true, 1)
end

local function assert_true(value, message)
	if not value then
		error(message, 0)
	end
end

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error(("%s (expected=%s actual=%s)"):format(
			message, tostring(expected), tostring(actual)), 0)
	end
end

local function ensure_test_ground(center)
	minetest.load_area(
		{x = center.x - 8, y = -2, z = center.z - 8},
		{x = center.x + 8, y = 5, z = center.z + 8})
	for x = center.x - 4, center.x + 4 do
		for z = center.z - 4, center.z + 4 do
			minetest.set_node({x = x, y = 0, z = z}, {name = "mcl_core:stone"})
			for y = 1, 4 do
				minetest.set_node({x = x, y = y, z = z}, {name = "air"})
			end
		end
	end
end

local function setup_village(owner)
	local center = centers[owner]
	ensure_test_ground(center)
	local registry = working_villages.village_registry
	assert_true(registry and registry.ensure, "village registry unavailable")
	local village, ensure_error = registry.ensure(owner, {
		center = center,
		radius = 8,
	})
	assert_true(village ~= nil, "registry creation failed for " .. owner .. ": " .. tostring(ensure_error))
	local claim = working_villages.set_owner_village_claim(owner, center, {
		radius = 8,
		height = 5,
		storage_pos = center,
	})
	assert_true(claim ~= nil, "claim creation failed for " .. owner)
	return village, claim
end

local function protected_dig_probe(owner_player, outsider_player, center)
	local target = {x = center.x, y = 1, z = center.z + 2}
	local node_name = "mcl_core:dirt"
	minetest.set_node(target, {name = node_name})

	local owner_name = owner_player:get_player_name()
	local outsider_name = outsider_player:get_player_name()
	assert_equal(minetest.is_protected(target, owner_name), false,
		"owner was refused inside own village")
	assert_equal(minetest.is_protected(target, outsider_name), true,
		"outsider was allowed inside neighbouring village")

	minetest.node_dig(target, minetest.get_node(target), outsider_player)
	assert_equal(minetest.get_node(target).name, node_name,
		"outsider changed a protected village node")

	minetest.node_dig(target, minetest.get_node(target), owner_player)
	assert_equal(minetest.get_node(target).name, "air",
		"owner could not dig inside own village")
	return true
end

local function run_test(alpha, beta)
	local village_alpha, claim_alpha = setup_village(OWNER_ALPHA)
	local village_beta, claim_beta = setup_village(OWNER_BETA)
	assert_true(village_alpha.id ~= village_beta.id, "village ids collided")
	assert_true(claim_alpha.owner_name ~= claim_beta.owner_name, "claim owners collided")

	alpha:set_pos({x = centers[OWNER_ALPHA].x, y = 2, z = centers[OWNER_ALPHA].z})
	beta:set_pos({x = centers[OWNER_BETA].x, y = 2, z = centers[OWNER_BETA].z})

	local villager_alpha = {owner_name = OWNER_ALPHA}
	local villager_beta = {owner_name = OWNER_BETA}
	assert_true(working_villages.can_manage_villager(villager_alpha, alpha),
		"alpha could not manage own villager")
	assert_true(not working_villages.can_manage_villager(villager_alpha, beta),
		"beta could manage alpha villager")
	assert_true(working_villages.can_manage_villager(villager_beta, beta),
		"beta could not manage own villager")
	assert_true(not working_villages.can_manage_villager(villager_beta, alpha),
		"alpha could manage beta villager")

	protected_dig_probe(alpha, beta, centers[OWNER_ALPHA])
	protected_dig_probe(beta, alpha, centers[OWNER_BETA])

	completed = true
	minetest.log("action",
		"WORKING_VILLAGES_MULTIPLAYER_PROTECTION_OK:players=2:villages=2:own_dig=allowed:cross_dig=blocked")
	minetest.request_shutdown("multiplayer protection runtime complete", true, 0)
end

minetest.register_globalstep(function()
	if completed then return end
	if not started_at then
		started_at = minetest.get_gametime()
		return
	end
	local alpha = minetest.get_player_by_name(OWNER_ALPHA)
	local beta = minetest.get_player_by_name(OWNER_BETA)
	if alpha and beta then
		local ok, err = pcall(run_test, alpha, beta)
		if not ok then fail(tostring(err)) end
		return
	end
	if minetest.get_gametime() - started_at >= TIMEOUT_SECONDS then
		fail("timed out waiting for both real clients")
	end
end)
