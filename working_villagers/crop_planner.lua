-- Persistent crop layout planning for deterministic, readable fields.

local crop_planner = {}

local VALID_STRATEGIES = {
	uniform = true,
	rows = true,
	available = true,
}

local configured_strategy = minetest.settings and
	minetest.settings:get("working_villages_farmer_crop_strategy") or nil
configured_strategy = tostring(configured_strategy or "uniform"):lower()
if not VALID_STRATEGIES[configured_strategy] then
	configured_strategy = "uniform"
end

local function normalized_available(names)
	local seen = {}
	local result = {}
	for _, name in ipairs(names or {}) do
		if type(name) == "string" and name ~= "" and not seen[name] then
			seen[name] = true
			result[#result + 1] = name
		end
	end
	table.sort(result)
	return result
end

local function contains(names, wanted)
	for _, name in ipairs(names) do
		if name == wanted then
			return true
		end
	end
	return false
end

local function stable_signature(value)
	local result = 0
	for index = 1, #value do
		result = (result * 33 + value:byte(index)) % 2147483647
	end
	return result
end

local function get_plan(villager)
	villager.job_data = villager.job_data or {}
	local plan = villager.job_data.farmer_crop_plan
	if type(plan) ~= "table" or plan.schema ~= 1 then
		plan = {
			schema = 1,
			strategy = configured_strategy,
			rows = {},
			missing = {},
		}
		villager.job_data.farmer_crop_plan = plan
	end
	plan.strategy = VALID_STRATEGIES[plan.strategy] and plan.strategy or configured_strategy
	plan.rows = type(plan.rows) == "table" and plan.rows or {}
	plan.missing = type(plan.missing) == "table" and plan.missing or {}
	return plan
end

local function row_key(pos, center)
	pos = pos or center or {x = 0, y = 0, z = 0}
	center = center or {x = 0, y = 0, z = 0}
	return tostring(math.floor((pos.z - center.z) / 2))
end

local function choose_stable(names, identity, salt)
	if #names == 0 then
		return nil
	end
	local signature = stable_signature(tostring(identity or "farmer") .. ":" .. tostring(salt or "0"))
	return names[(signature % #names) + 1]
end

local function planned_seed(plan, key)
	if plan.strategy == "rows" then
		return plan.rows[key]
	end
	return plan.primary_seed
end

local function set_planned_seed(plan, key, seed)
	if plan.strategy == "rows" then
		plan.rows[key] = seed
	else
		plan.primary_seed = seed
	end
	plan.missing[key] = nil
end

function crop_planner.choose(villager, available_names, pos, center)
	local names = normalized_available(available_names)
	if #names == 0 then
		return nil
	end
	local plan = get_plan(villager)
	if plan.strategy == "available" then
		return names[1]
	end

	local key = plan.strategy == "rows" and row_key(pos, center) or "primary"
	local current = planned_seed(plan, key)
	if current and contains(names, current) then
		plan.missing[key] = nil
		return current
	end
	if current then
		-- Give chest retrieval a few profession cycles to restore the planned
		-- seed. Only then re-plan, avoiding both permanent stalls and a crop
		-- change caused by one transient inventory transfer.
		plan.missing[key] = (tonumber(plan.missing[key]) or 0) + 1
		if plan.missing[key] < 3 then
			return nil
		end
	end

	local identity = villager.inventory_name or villager.nametag or "farmer"
	local selected = choose_stable(names, identity, key)
	set_planned_seed(plan, key, selected)
	return selected
end

function crop_planner.remember(villager, seed_name, pos, center)
	if type(seed_name) ~= "string" or seed_name == "" then
		return false
	end
	local plan = get_plan(villager)
	if plan.strategy == "rows" then
		set_planned_seed(plan, row_key(pos, center), seed_name)
	elseif plan.strategy == "uniform" and not plan.primary_seed then
		set_planned_seed(plan, "primary", seed_name)
	end
	return true
end

function crop_planner.get_primary(villager)
	local plan = get_plan(villager)
	return plan.primary_seed
end

function crop_planner.get_strategy(villager)
	return get_plan(villager).strategy
end

return crop_planner
