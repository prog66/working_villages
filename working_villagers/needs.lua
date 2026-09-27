-- Needs system for villagers (hunger, energy, tools, materials)
-- Lightweight tracking with decay and basic status helpers.

local needs = {}

-- Default needs configuration
needs.config = {
	hunger = { max = 100, decay_rate = 0.1, low = 25, critical = 10 },
	energy = { max = 100, decay_rate = 0.05, low = 25, critical = 10 },
	-- Resource levels are measured from real inventories by api.lua. They stay
	-- visible to status/HUD consumers, but do not enter ai_decision until that
	-- layer can execute a concrete resupply action instead of only displaying text.
	tools = { max = 100, decay_rate = 0.0, low = 30, critical = 10, decision = false },
	materials = { max = 100, decay_rate = 0.0, low = 30, critical = 10, decision = false },
}

-- Create a new needs state table with defaults
function needs.create_state()
	local state = {}
	for name, cfg in pairs(needs.config) do
		state[name] = cfg.max
	end
	return state
end

local function clamp(val, minv, maxv)
	if val < minv then return minv end
	if val > maxv then return maxv end
	return val
end

-- Ensure a villager has a needs state
function needs.ensure(self)
	if type(self.needs) ~= "table" then
		self.needs = needs.create_state()
	end
	for name, cfg in pairs(needs.config) do
		if type(self.needs[name]) ~= "number" then
			self.needs[name] = cfg.max
		end
	end
	return self.needs
end

-- Tick needs decay (called every on_step)
function needs.tick(self, dtime)
	local state = needs.ensure(self)
	for name, cfg in pairs(needs.config) do
		local current = state[name] or cfg.max
		local decayed = current - (cfg.decay_rate or 0) * dtime
		state[name] = clamp(decayed, 0, cfg.max)
	end
end

-- Helpers to read/update
function needs.get(self, name)
	local state = needs.ensure(self)
	return state[name]
end

function needs.set(self, name, value)
	local cfg = needs.config[name]
	if not cfg or type(value) ~= "number" then
		return false
	end
	local state = needs.ensure(self)
	state[name] = clamp(value, 0, cfg.max)
	return true
end

function needs.adjust(self, name, delta)
	local current = needs.get(self, name)
	if current == nil then
		return
	end
	needs.set(self, name, current + delta)
end

local function percentage(count, target)
	count = math.max(tonumber(count) or 0, 0)
	target = math.max(tonumber(target) or 1, 1)
	return clamp((count / target) * 100, 0, 100)
end

-- Convert a real village stock snapshot into the two resource gauges. Targets
-- scale with the loaded population so the same absolute stock is not treated
-- as abundant in a much larger village.
function needs.update_resources(self, snapshot)
	snapshot = type(snapshot) == "table" and snapshot or {}
	local population = math.max(tonumber(snapshot.population) or 1, 1)
	local tool_target = math.max(2, population)
	local material_target = math.max(24, population * 8)
	needs.set(self, "tools", percentage(snapshot.tools, tool_target))
	needs.set(self, "materials", percentage(snapshot.materials, material_target))
	local state = needs.ensure(self)
	state.resources_measured = true
	return state.tools, state.materials
end

local jobs = {
	autonomous = "working_villages:job_autonome",
	farmer = "working_villages:job_farmer",
	woodcutter = "working_villages:job_woodcutter",
	miner = "working_villages:job_miner",
	builder = "working_villages:job_builder",
	cook = "working_villages:job_cook",
	blacksmith = "working_villages:job_blacksmith",
	guard = "working_villages:job_guard",
}

-- Wall-clock pacing for automatic role rotation.  The full specialize/return
-- cycle cannot oscillate faster than 105 seconds, while a resolved temporary
-- role no longer strands a worker for the historical 900 seconds.
needs.auto_job_cooldowns = {
	initial = 30,
	specialize = 60,
	returning = 45,
	village = 10,
}

needs.reassignable_jobs = {
	[jobs.autonomous] = true,
	[jobs.farmer] = true,
	[jobs.woodcutter] = true,
	[jobs.miner] = true,
	[jobs.builder] = true,
	-- Specialists are temporary village assignments.  Keeping them eligible
	-- here is what lets a five-person village recover its gatherer/builder once
	-- the batch of food, tools or danger that justified the role is gone.
	[jobs.cook] = true,
	[jobs.blacksmith] = true,
	[jobs.guard] = true,
}

needs.specialist_jobs = {
	[jobs.cook] = true,
	[jobs.blacksmith] = true,
	[jobs.guard] = true,
}

local function stock(snapshot, available_name, storage_name)
	return math.max(tonumber(snapshot[available_name]) or tonumber(snapshot[storage_name]) or 0, 0)
end

local function role_count(village, job_name)
	local counts = type(village.counts) == "table" and village.counts or {}
	return math.max(tonumber(counts[job_name]) or 0, 0)
end

local function role_targets(village)
	local population = math.max(tonumber(village.population) or 1, 1)
	return {
		[jobs.autonomous] = 1,
		[jobs.farmer] = math.max(1, math.floor((population + 1) / 4)),
		[jobs.woodcutter] = math.max(1, math.floor((population + 2) / 4)),
		[jobs.miner] = math.max(1, math.floor(population / 5)),
		[jobs.builder] = 1,
		[jobs.cook] = 1,
		[jobs.blacksmith] = 1,
		[jobs.guard] = math.max(1, math.floor((population + 2) / 5)),
	}
end

-- Pure bootstrap phase selection.  Defence is reactive (real danger) or an
-- explicit player priority; it is not a mandatory staffing gate that prevents
-- a balanced village from starting its first shelter.
function needs.choose_bootstrap_stage(village)
	village = type(village) == "table" and village or {}
	local population = math.max(tonumber(village.population) or 0, 1)
	local focus = type(village.control) == "table" and village.control.focus or "balanced"
	local food = stock(village, "available_food", "food") +
		stock(village, "available_raw_food", "raw_food")
	local wood = stock(village, "available_wood", "wood")
	local tools = stock(village, "available_tools", "tools")
	local guards = role_count(village, jobs.guard)

	if (math.max(tonumber(village.recent_danger) or 0, 0) > 0 or focus == "defense")
		and guards == 0 then
		return "defense"
	end
	if not village.shared_storage_ready then
		if wood < math.max(8, population * 2) then
			return "wood"
		end
		return "storage"
	end
	if food < math.max(16, population * 4) then
		return "food"
	end
	if tools < math.max(3, population) then
		return "tools"
	end
	return "build"
end

-- Pure demand predicate shared by assignment and release.  A specialist stays
-- only while its concrete inputs and output shortage (or an actual defence
-- order) still exist.  This deliberately avoids permanent "just in case"
-- specialists in small balanced villages.
function needs.specialist_job_needed(job_name, village)
	village = type(village) == "table" and village or {}
	local population = math.max(tonumber(village.population) or 1, 1)
	local stage = village.bootstrap_stage or ""
	local focus = type(village.control) == "table" and village.control.focus or "balanced"
	local danger = math.max(tonumber(village.recent_danger) or 0, 0)
	local food = stock(village, "available_food", "food")
	local raw_food = stock(village, "available_raw_food", "raw_food")
	local ore = stock(village, "available_ore", "ore")
	local tools = stock(village, "available_tools", "tools")
	local forged_tools = stock(village, "available_forged_tools", "forged_tools")
	local targets = role_targets(village)

	if job_name == jobs.guard then
		local guard_order = danger > 0 or focus == "defense"
		return guard_order and role_count(village, job_name) <= targets[job_name]
	end
	if job_name == jobs.blacksmith then
		local ore_input = math.max(4, population)
		local tool_target = math.max(4, population)
		local upgrade_needed = forged_tools < math.max(1, math.floor(population / 4))
		local useful_phase = stage == "tools" or stage == "defense" or
			focus == "industry" or focus == "defense" or
			(stage == "build" and upgrade_needed)
		return ore >= ore_input and (tools < tool_target or upgrade_needed) and useful_phase and
			role_count(village, job_name) <= targets[job_name]
	end
	if job_name == jobs.cook then
		local raw_input = math.max(6, population * 2)
		local food_target = math.max(24, population * 6)
		local useful_phase = stage == "food" or focus == "food" or raw_food > food
		return raw_food >= raw_input and food < food_target and useful_phase and
			role_count(village, job_name) <= targets[job_name]
	end
	return false
end

-- Pure village policy: specialist jobs are requested only when their inputs
-- exist and the current phase/focus makes the role immediately useful.
function needs.choose_specialist_job(village)
	village = type(village) == "table" and village or {}
	local counts = type(village.counts) == "table" and village.counts or {}
	local population = math.max(tonumber(village.population) or 1, 1)
	local stage = village.bootstrap_stage or ""
	local focus = type(village.control) == "table" and village.control.focus or "balanced"
	local danger = math.max(tonumber(village.recent_danger) or 0, 0)
	local guards = tonumber(counts[jobs.guard]) or 0
	local cooks = tonumber(counts[jobs.cook]) or 0
	local blacksmiths = tonumber(counts[jobs.blacksmith]) or 0
	local autonomous = tonumber(counts[jobs.autonomous]) or 0
	local miners = tonumber(counts[jobs.miner]) or 0

	local target_guards = role_targets(village)[jobs.guard]
	if danger > 0 and guards < target_guards then
		return jobs.guard, "danger recent"
	end
	if guards < target_guards and (stage == "defense" or focus == "defense") then
		return jobs.guard, "phase defense"
	end
	if focus == "exploration" and autonomous == 0 then
		return jobs.autonomous, "exploration sans eclaireur autonome"
	end

	if blacksmiths == 0 and population >= 4 and
		needs.specialist_job_needed(jobs.blacksmith, village) then
		return jobs.blacksmith, "minerai disponible et outils insuffisants"
	end

	if cooks == 0 and needs.specialist_job_needed(jobs.cook, village) then
		return jobs.cook, "nourriture crue a transformer"
	end

	if focus == "exploration" and population >= 3 and miners == 0 then
		return jobs.miner, "exploration des ressources souterraines"
	end

	return nil, nil
end

local function return_role_is_useful(job_name, village, targets)
	local count = role_count(village, job_name)
	if job_name == jobs.builder then
		return count < targets[job_name] and
			((tonumber(village.active_sites) or 0) > 0 or
			(tonumber(village.homeless) or 0) > 0 or
			(tonumber(village.built_houses) or 0) == 0)
	end
	return count < (targets[job_name] or 1)
end

-- Pick the productive role restored after a temporary specialist mission.
-- Active construction and bootstrap shortages win first; otherwise the prior
-- role is recovered when still useful, then the autonomous generalist slot.
function needs.choose_return_job(village, preferred_job)
	village = type(village) == "table" and village or {}
	local targets = role_targets(village)
	local stage = village.bootstrap_stage or ""
	local stage_roles = {
		wood = jobs.woodcutter,
		storage = jobs.autonomous,
		food = jobs.farmer,
		tools = jobs.miner,
		build = jobs.builder,
	}
	local stage_role = stage_roles[stage]

	if (tonumber(village.active_sites) or 0) > 0 and
		return_role_is_useful(jobs.builder, village, targets) then
		return jobs.builder, "chantier sans constructeur"
	end
	if stage_role and return_role_is_useful(stage_role, village, targets) then
		return stage_role, "role essentiel de la phase " .. stage
	end
	for _, job_name in ipairs({jobs.woodcutter, jobs.farmer, jobs.miner}) do
		if return_role_is_useful(job_name, village, targets) then
			return job_name, "role essentiel manquant"
		end
	end
	if preferred_job and not needs.specialist_jobs[preferred_job] and
		needs.reassignable_jobs[preferred_job] and
		return_role_is_useful(preferred_job, village, targets) then
		return preferred_job, "retour a la mission precedente"
	end
	if return_role_is_useful(jobs.autonomous, village, targets) then
		return jobs.autonomous, "retour a l'autonomie generale"
	end
	if return_role_is_useful(jobs.builder, village, targets) then
		return jobs.builder, "preparation du prochain chantier"
	end
	if preferred_job and not needs.specialist_jobs[preferred_job] and
		needs.reassignable_jobs[preferred_job] then
		return preferred_job, "retour a la mission precedente"
	end
	return jobs.autonomous, "renfort autonome polyvalent"
end

-- Pure transition policy used by api.lua and exercised without an engine.
function needs.choose_job_transition(current_job, village, preferred_job)
	village = type(village) == "table" and village or {}
	local specialist, specialist_reason = needs.choose_specialist_job(village)
	if needs.specialist_jobs[current_job] then
		if specialist and specialist ~= current_job then
			return specialist, specialist_reason, "rotate"
		end
		if needs.specialist_job_needed(current_job, village) then
			return nil, nil, nil
		end
		local return_job, return_reason = needs.choose_return_job(village, preferred_job)
		return return_job, return_reason, "return"
	end
	if specialist and specialist ~= current_job then
		return specialist, specialist_reason, "specialize"
	end
	if preferred_job and preferred_job ~= current_job and
		not needs.specialist_jobs[preferred_job] and
		needs.reassignable_jobs[preferred_job] then
		local targets = role_targets(village)
		local preferred_missing = role_count(village, preferred_job) <
			(targets[preferred_job] or 1)
		local current_released = (current_job == jobs.builder and
			(tonumber(village.active_sites) or 0) == 0 and
			(tonumber(village.homeless) or 0) == 0) or
			(current_job ~= jobs.autonomous and current_job ~= jobs.builder and
				role_count(village, current_job) > (targets[current_job] or 1))
		if preferred_missing and current_released then
			return preferred_job, "fin de la mission essentielle temporaire", "restore"
		end
	end
	return nil, nil, nil
end

-- Pure first-assignment policy.  Jobless villagers fill the bootstrap chain in
-- dependency order; cooks/blacksmiths are admitted only with real inputs, and
-- guards only for danger or an explicit defence focus.
function needs.choose_initial_job(village)
	village = type(village) == "table" and village or {}
	local counts = type(village.counts) == "table" and village.counts or {}
	local population = math.max(tonumber(village.population) or 1, 1)
	local wood = stock(village, "available_wood", "wood")
	local food = stock(village, "available_food", "food")
	local raw_food = stock(village, "available_raw_food", "raw_food")
	local ore = stock(village, "available_ore", "ore")
	local active_sites = math.max(tonumber(village.active_sites) or 0, 0)
	local homeless = math.max(tonumber(village.homeless) or 0, 0)
	local built_houses = math.max(tonumber(village.built_houses) or 0, 0)
	local focus = type(village.control) == "table" and village.control.focus or "balanced"
	local stage = village.bootstrap_stage or needs.choose_bootstrap_stage(village)
	local targets = role_targets(village)
	local woodcutters = role_count(village, jobs.woodcutter)
	local farmers = role_count(village, jobs.farmer)
	local miners = role_count(village, jobs.miner)
	local builders = role_count(village, jobs.builder)
	local cooks = role_count(village, jobs.cook)
	local blacksmiths = role_count(village, jobs.blacksmith)
	local guards = role_count(village, jobs.guard)
	local autonomous = role_count(village, jobs.autonomous)
	local builder_ready = wood >= math.max(30, population * 8) and
		food >= math.max(20, population * 4)

	if math.max(tonumber(village.recent_danger) or 0, 0) > 0 and guards < targets[jobs.guard] then
		return jobs.guard
	end
	if focus == "exploration" and autonomous == 0 then
		return jobs.autonomous
	end
	if stage == "wood" then
		if woodcutters == 0 then return jobs.woodcutter end
		if autonomous == 0 then return jobs.autonomous end
		if farmers == 0 then return jobs.farmer end
		return nil
	end
	if stage == "storage" then
		if autonomous == 0 then return jobs.autonomous end
		if woodcutters == 0 then return jobs.woodcutter end
		if farmers == 0 then return jobs.farmer end
		return nil
	end
	if stage == "food" then
		if farmers < targets[jobs.farmer] then return jobs.farmer end
		if cooks == 0 and needs.specialist_job_needed(jobs.cook, village) then return jobs.cook end
		if woodcutters == 0 then return jobs.woodcutter end
		return nil
	end
	if stage == "tools" then
		if woodcutters < targets[jobs.woodcutter] then return jobs.woodcutter end
		if miners < targets[jobs.miner] then return jobs.miner end
		if blacksmiths == 0 and population >= 4 and
			needs.specialist_job_needed(jobs.blacksmith, village) then
			return jobs.blacksmith
		end
		if farmers == 0 then return jobs.farmer end
		return nil
	end
	if stage == "defense" then
		if guards < targets[jobs.guard] then return jobs.guard end
		if blacksmiths == 0 and population >= 4 and
			needs.specialist_job_needed(jobs.blacksmith, village) then
			return jobs.blacksmith
		end
		return nil
	end

	if focus == "defense" and guards < targets[jobs.guard] then return jobs.guard end
	if focus == "food" and food < math.max(24, population * 7) and
		farmers < (targets[jobs.farmer] + 1) then
		return jobs.farmer
	end
	if focus == "housing" and builders == 0 and
		(active_sites > 0 or (homeless > 0 and builder_ready)) then
		return jobs.builder
	end
	if focus == "industry" and blacksmiths == 0 and population >= 4 and
		needs.specialist_job_needed(jobs.blacksmith, village) then
		return jobs.blacksmith
	end
	if focus == "industry" and ore < math.max(12, population * 5) and
		miners < (targets[jobs.miner] + 1) then
		return jobs.miner
	end
	if focus == "exploration" and population >= 3 and miners < targets[jobs.miner] then
		return jobs.miner
	end

	if food < math.max(20, population * 6) and farmers < targets[jobs.farmer] then
		return jobs.farmer
	end
	if wood < math.max(30, population * 10) and woodcutters < targets[jobs.woodcutter] then
		return jobs.woodcutter
	end
	if ore < math.max(10, population * 4) and miners < targets[jobs.miner] then
		return jobs.miner
	end
	-- Once the economy reaches build, shelter capacity is more important than
	-- opening another optional specialist slot.
	if builders == 0 and (active_sites > 0 or built_houses == 0 or
		(homeless > 0 and builder_ready)) then
		return jobs.builder
	end
	if cooks == 0 and needs.specialist_job_needed(jobs.cook, village) then return jobs.cook end
	if blacksmiths == 0 and population >= 4 and
		needs.specialist_job_needed(jobs.blacksmith, village) then
		return jobs.blacksmith
	end
	if autonomous == 0 then return jobs.autonomous end
	return nil
end

-- Rank safe donors. Essential gatherers are eligible only above their minimum
-- staffing target; the autonomous role is preferred and an idle builder is the
-- next least disruptive option.
function needs.reassignment_priority(current_job, village, target_job)
	if not needs.reassignable_jobs[current_job] then
		return nil
	end
	village = type(village) == "table" and village or {}
	if needs.specialist_jobs[current_job] then
		if current_job ~= target_job and not needs.specialist_job_needed(current_job, village) then
			return 0
		end
		return nil
	end
	local counts = type(village.counts) == "table" and village.counts or {}
	local population = math.max(tonumber(village.population) or 1, 1)
	if current_job == jobs.autonomous then
		if target_job == jobs.autonomous then
			return nil
		end
		local focus = type(village.control) == "table" and village.control.focus or "balanced"
		if focus == "exploration" and (tonumber(counts[jobs.autonomous]) or 0) <= 1 then
			return nil
		end
		return 1
	end
	if current_job == jobs.builder then
		local emergency_guard = target_job == jobs.guard and (tonumber(village.recent_danger) or 0) > 0
		if emergency_guard or ((tonumber(village.active_sites) or 0) == 0 and
			(tonumber(village.homeless) or 0) == 0) then
			return 2
		end
		return nil
	end
	local targets = {
		[jobs.woodcutter] = math.max(1, math.floor((population + 2) / 4)),
		[jobs.miner] = math.max(1, math.floor(population / 5)),
		[jobs.farmer] = math.max(1, math.floor((population + 1) / 4)),
	}
	local target = targets[current_job]
	if target and (tonumber(counts[current_job]) or 0) > target then
		if current_job == jobs.woodcutter then return 3 end
		if current_job == jobs.miner then return 4 end
		return 5
	end
	return nil
end

-- Return a list of needs that are low/critical
function needs.get_low(self)
	local state = needs.ensure(self)
	local low = {}
	for name, cfg in pairs(needs.config) do
		local val = state[name]
		if cfg.decision ~= false and val <= cfg.critical then
			table.insert(low, { name = name, level = "critical", value = val })
		elseif cfg.decision ~= false and val <= cfg.low then
			table.insert(low, { name = name, level = "low", value = val })
		end
	end
	return low
end

return needs
