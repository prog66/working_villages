local DURATION_SECONDS = 60
local EXPECTED_VILLAGES = 4
local WORKERS_PER_VILLAGE = 5
local EXPECTED_WORKERS = EXPECTED_VILLAGES * WORKERS_PER_VILLAGE
local P95_BUDGET = 0.20
local MAX_STEP_BUDGET = 1.00
local ENTITY = "working_villages:villager_female"
local JOBS = {
	"working_villages:job_woodcutter",
	"working_villages:job_farmer",
	"working_villages:job_autonome",
	"working_villages:job_miner",
	"working_villages:job_builder",
}
local CENTERS = {
	{x = -32, y = 1, z = -32}, {x = 32, y = 1, z = -32},
	{x = -32, y = 1, z = 32}, {x = 32, y = 1, z = 32},
}

local expected = {}
local samples = {}
local started_at
local finished = false

local function fail(message)
	if finished then return end
	finished = true
	minetest.log("error", "WORKING_VILLAGES_MULTI_VILLAGE_LOAD_FAILED:"
		.. tostring(message))
	minetest.request_shutdown("working_villages multi-village load test failed", false, 0)
end

local function assert_true(value, message)
	if not value then error(message or "expected truthy value", 2) end
end

local function setup_world()
	local stone = working_villages.compat.get_item("default:stone")
	assert_true(minetest.registered_nodes[stone], "load arena stone is not registered")
	minetest.load_area({x = -64, y = -2, z = -64}, {x = 64, y = 5, z = 64})
	for x = -56, 56 do
		for z = -56, 56 do
			minetest.set_node({x = x, y = 0, z = z}, {name = stone})
			for y = 1, 3 do
				minetest.set_node({x = x, y = y, z = z}, {name = "air"})
			end
		end
	end
	if minetest.forceload_block then
		for x = -64, 48, 16 do
			for z = -64, 48, 16 do
				assert_true(minetest.forceload_block({x = x, y = 0, z = z}, true),
					"could not forceload load-test block")
			end
		end
	end
end

local function spawn_population()
	local registry = assert(working_villages.village_registry,
		"village registry is unavailable")
	for village_index, center in ipairs(CENTERS) do
		local owner = "working_villages_load_owner_" .. village_index
		local village, ensure_error = registry.ensure(owner, {
			center = vector.round(center), radius = 24,
		})
		assert_true(village, "could not create load village: " .. tostring(ensure_error))
		for worker_index, job in ipairs(JOBS) do
			local offset = worker_index - 3
			local pos = {x = center.x + offset * 2, y = 1, z = center.z}
			local object = minetest.add_entity(pos, ENTITY)
			assert_true(object, "could not spawn load worker")
			local worker = assert(object:get_luaentity())
			worker.owner_name = owner
			worker.pos_data = worker.pos_data or {}
			worker.pos_data.job_pos = vector.round(pos)
			working_villages.needs.set(worker, "hunger", 100)
			working_villages.needs.set(worker, "energy", 100)
			local changed, reason = worker:change_job(job)
			assert_true(changed, "could not assign load worker: " .. tostring(reason))
			assert_true(type(worker.inventory_name) == "string"
				and worker.inventory_name ~= "", "load worker has no identity")
			expected[worker.inventory_name] = {owner = owner, job = job}
		end
	end
	local count = 0
	for _ in pairs(expected) do count = count + 1 end
	assert_true(count == EXPECTED_WORKERS,
		"load population identity collision: " .. count .. "/" .. EXPECTED_WORKERS)
end

local function current_workers()
	local found = {}
	for _, entity in pairs(minetest.luaentities or {}) do
		if entity and entity.name and working_villages.is_villager(entity.name)
				and expected[entity.inventory_name] then
			found[entity.inventory_name] = entity
		end
	end
	return found
end

local function percentile(values, fraction)
	local sorted = {}
	for index, value in ipairs(values) do sorted[index] = value end
	table.sort(sorted)
	local index = math.max(1, math.min(#sorted, math.ceil(#sorted * fraction)))
	return sorted[index]
end

minetest.register_globalstep(function(dtime)
	if started_at and not finished then samples[#samples + 1] = dtime end
end)

local function validate_tick()
	if finished then return end
	local ok, err = xpcall(function()
		local found = current_workers()
		local count = 0
		for id, contract in pairs(expected) do
			local worker = found[id]
			assert_true(worker, "load worker unloaded or lost: " .. id)
			assert_true(worker.owner_name == contract.owner,
				"worker crossed village ownership: " .. id)
			assert_true(worker:get_job_name() == contract.job,
				"worker changed profession under load: " .. id)
			count = count + 1
		end
		assert_true(count == EXPECTED_WORKERS, "unexpected load worker count")

		local registry = working_villages.village_registry
		for village_index = 1, EXPECTED_VILLAGES do
			local owner = "working_villages_load_owner_" .. village_index
			local village = registry.get(owner)
			assert_true(village and village.owner == owner,
				"registry isolation failed for " .. owner)
		end

		local elapsed = minetest.get_us_time() / 1000000 - started_at
		if elapsed >= DURATION_SECONDS then
			assert_true(#samples > 100, "too few server-step samples")
			local total, maximum = 0, 0
			for _, value in ipairs(samples) do
				total = total + value
				maximum = math.max(maximum, value)
			end
			local average = total / #samples
			local p95 = percentile(samples, 0.95)
			assert_true(p95 <= P95_BUDGET,
				("p95 step %.3fs exceeds %.3fs"):format(p95, P95_BUDGET))
			assert_true(maximum <= MAX_STEP_BUDGET,
				("maximum step %.3fs exceeds %.3fs"):format(maximum, MAX_STEP_BUDGET))
			finished = true
			minetest.log("action", "WORKING_VILLAGES_MULTI_VILLAGE_LOAD_OK:"
				.. working_villages.game_profile.id
				.. ":villages=" .. EXPECTED_VILLAGES
				.. ":workers=" .. EXPECTED_WORKERS
				.. ":samples=" .. #samples
				.. ":average=" .. string.format("%.4f", average)
				.. ":p95=" .. string.format("%.4f", p95)
				.. ":max=" .. string.format("%.4f", maximum))
			minetest.request_shutdown("working_villages multi-village load test completed", false, 0)
			return
		end
		minetest.after(1, validate_tick)
	end, debug.traceback)
	if not ok then fail(err) end
end

minetest.after(0, function()
	local ok, err = xpcall(function()
		minetest.set_timeofday(0.5)
		setup_world()
		spawn_population()
		started_at = minetest.get_us_time() / 1000000
		minetest.log("action", "MULTI_VILLAGE_LOAD_STARTED:"
			.. working_villages.game_profile.id .. ":villages=" .. EXPECTED_VILLAGES
			.. ":workers=" .. EXPECTED_WORKERS)
		minetest.after(1, validate_tick)
	end, debug.traceback)
	if not ok then fail(err) end
end)

