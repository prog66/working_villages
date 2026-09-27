-- Standalone pure regression tests for measured resource needs and safe job
-- reassignment policy.
-- Run from the repository root with:
--   lua working_villagers/tests/needs_spec.lua working_villagers

local modpath = (arg and arg[1]) or "working_villagers"
local needs = dofile(modpath .. "/needs.lua")

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) ..
			", got " .. tostring(actual), 2)
	end
end

local villager = {}
local tools, materials = needs.update_resources(villager, {
	population = 4,
	tools = 2,
	materials = 16,
})
assert_equal(tools, 50, "tool gauge uses real per-population stock")
assert_equal(materials, 50, "material gauge uses real per-population stock")
assert_equal(villager.needs.resources_measured, true, "resource snapshot is marked measured")

tools, materials = needs.update_resources(villager, {
	population = 2,
	tools = 99,
	materials = -5,
})
assert_equal(tools, 100, "tool gauge clamps abundance")
assert_equal(materials, 0, "material gauge clamps invalid negative stock")

needs.set(villager, "hunger", 0)
needs.set(villager, "energy", 100)
needs.set(villager, "tools", 0)
needs.set(villager, "materials", 0)
local low = needs.get_low(villager)
assert_equal(#low, 1, "non-executable resource gauges do not drive ai_decision")
assert_equal(low[1].name, "hunger", "executable low need remains visible to decisions")

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

local target = needs.choose_specialist_job({
	population = 5,
	recent_danger = 20,
	counts = {},
})
assert_equal(target, jobs.guard, "danger requests a guard first")

target = needs.choose_specialist_job({
	population = 4,
	bootstrap_stage = "food",
	available_food = 0,
	available_raw_food = 12,
	counts = {},
})
assert_equal(target, jobs.cook, "real raw food and low cooked stock request a cook")

target = needs.choose_specialist_job({
	population = 4,
	bootstrap_stage = "tools",
	available_ore = 8,
	available_tools = 0,
	counts = {},
})
assert_equal(target, jobs.blacksmith, "real ore and low tool stock request a blacksmith")

target = needs.choose_specialist_job({
	population = 4,
	control = {focus = "exploration"},
	counts = {},
})
assert_equal(target, jobs.autonomous, "exploration first preserves an autonomous scout")

target = needs.choose_specialist_job({
	population = 4,
	control = {focus = "exploration"},
	counts = {[jobs.autonomous] = 1},
})
assert_equal(target, jobs.miner, "exploration can add a miner after its scout")

target = needs.choose_specialist_job({
	population = 2,
	available_food = 20,
	available_raw_food = 0,
	available_ore = 0,
	available_tools = 2,
	counts = {},
})
assert_equal(target, nil, "no usable specialist input means no reassignment")

assert_equal(needs.choose_bootstrap_stage({
	population = 5,
	shared_storage_ready = true,
	available_food = 80,
	available_raw_food = 0,
	available_ore = 0,
	available_tools = 15,
	recent_danger = 0,
	control = {focus = "balanced"},
	counts = {},
}), "build", "balanced bootstrap reaches the first shelter without a mandatory guard")
assert_equal(needs.choose_bootstrap_stage({
	population = 5,
	shared_storage_ready = true,
	available_food = 80,
	available_raw_food = 0,
	available_ore = 8,
	available_tools = 15,
	recent_danger = 0,
	control = {focus = "balanced"},
	counts = {},
}), "build", "leftover ore does not make a permanent blacksmith a bootstrap gate")
assert_equal(needs.choose_bootstrap_stage({
	population = 5,
	recent_danger = 1,
	counts = {},
}), "defense", "real danger still opens the defense phase")
assert_equal(needs.choose_bootstrap_stage({
	population = 5,
	control = {focus = "defense"},
	counts = {},
}), "defense", "explicit defense focus still requests defense")

local initial = {
	population = 5,
	bootstrap_stage = "wood",
	available_wood = 0,
	available_food = 0,
	counts = {},
}
assert_equal(needs.choose_initial_job(initial), jobs.woodcutter,
	"fresh village assigns a woodcutter first")
initial.counts[jobs.woodcutter] = 1
assert_equal(needs.choose_initial_job(initial), jobs.autonomous,
	"fresh village preserves an autonomous generalist")
initial.counts[jobs.autonomous] = 1
assert_equal(needs.choose_initial_job(initial), jobs.farmer,
	"fresh village adds its food producer")
initial.counts[jobs.farmer] = 1
assert_equal(needs.choose_initial_job(initial), nil,
	"fresh village does not invent a guard or blacksmith without demand")

initial.bootstrap_stage = "tools"
initial.available_wood = 80
initial.available_food = 80
initial.available_ore = 0
initial.available_tools = 0
assert_equal(needs.choose_initial_job(initial), jobs.miner,
	"tool phase first restores ore extraction")
initial.counts[jobs.miner] = 1
assert_equal(needs.choose_initial_job(initial), nil,
	"blacksmith is not assigned before usable ore exists")
initial.available_ore = 8
assert_equal(needs.choose_initial_job(initial), jobs.blacksmith,
	"blacksmith becomes useful once a real input batch exists")

local five_roles = {
	population = 5,
	bootstrap_stage = "food",
	available_food = 0,
	available_raw_food = 12,
	available_ore = 0,
	available_tools = 5,
	available_forged_tools = 0,
	homeless = 5,
	built_houses = 0,
	counts = {
		[jobs.autonomous] = 1,
		[jobs.farmer] = 1,
		[jobs.woodcutter] = 1,
		[jobs.miner] = 1,
		[jobs.builder] = 1,
	},
}
local transition, _, transition_kind = needs.choose_job_transition(
	jobs.autonomous, five_roles, jobs.autonomous)
assert_equal(transition, jobs.cook, "five-person village temporarily opens a cook role")
assert_equal(transition_kind, "specialize", "productive role enters a specialist mission")

five_roles.counts[jobs.autonomous] = 0
five_roles.counts[jobs.cook] = 1
transition = needs.choose_job_transition(jobs.cook, five_roles, jobs.autonomous)
assert_equal(transition, nil, "cook remains assigned while a real cooking batch exists")
five_roles.bootstrap_stage = "build"
five_roles.available_food = 40
five_roles.available_raw_food = 0
five_roles.built_houses = 1
transition, _, transition_kind = needs.choose_job_transition(
	jobs.cook, five_roles, jobs.autonomous)
assert_equal(transition, jobs.autonomous, "finished cook returns the missing autonomous role")
assert_equal(transition_kind, "return", "resolved specialist mission is an explicit return")

five_roles.bootstrap_stage = "build"
five_roles.available_ore = 8
five_roles.available_tools = 6
five_roles.available_forged_tools = 0
five_roles.counts[jobs.cook] = 1
transition, _, transition_kind = needs.choose_job_transition(
	jobs.cook, five_roles, jobs.autonomous)
assert_equal(transition, jobs.blacksmith,
	"primitive tool stock does not prevent the first forged-tool upgrade")
assert_equal(transition_kind, "rotate",
	"a still-useful cook yields one bounded turn to the higher-priority forge")

five_roles.counts[jobs.cook] = 0
five_roles.counts[jobs.autonomous] = 1
five_roles.bootstrap_stage = "tools"
five_roles.available_ore = 8
five_roles.available_tools = 0
transition = needs.choose_job_transition(jobs.autonomous, five_roles, jobs.autonomous)
assert_equal(transition, jobs.blacksmith, "same small village can next open its forge role")
five_roles.counts[jobs.autonomous] = 0
five_roles.counts[jobs.blacksmith] = 1
five_roles.bootstrap_stage = "build"
five_roles.available_tools = 5
five_roles.available_forged_tools = 1
transition = needs.choose_job_transition(jobs.blacksmith, five_roles, jobs.autonomous)
assert_equal(transition, jobs.autonomous, "finished blacksmith restores the generalist")

five_roles.counts[jobs.blacksmith] = 0
five_roles.counts[jobs.autonomous] = 1
five_roles.recent_danger = 5
transition = needs.choose_job_transition(jobs.autonomous, five_roles, jobs.autonomous)
assert_equal(transition, jobs.guard, "danger can temporarily rotate the same fifth villager to guard")
five_roles.counts[jobs.autonomous] = 0
five_roles.counts[jobs.guard] = 1
five_roles.recent_danger = 0
transition = needs.choose_job_transition(jobs.guard, five_roles, jobs.autonomous)
assert_equal(transition, jobs.autonomous, "guard returns when balanced village danger has cleared")

five_roles.counts[jobs.guard] = 1
five_roles.counts[jobs.builder] = 0
five_roles.active_sites = 1
transition = needs.choose_job_transition(jobs.guard, five_roles, jobs.autonomous)
assert_equal(transition, jobs.builder, "resolved specialist restores an active builder before a generalist")
five_roles.counts[jobs.guard] = 0
five_roles.counts[jobs.builder] = 1
five_roles.active_sites = 0
five_roles.homeless = 0
transition, _, transition_kind = needs.choose_job_transition(
	jobs.builder, five_roles, jobs.autonomous)
assert_equal(transition, jobs.autonomous,
	"temporary builder restores its original autonomous role after the site is finished")
assert_equal(transition_kind, "restore", "second-stage return is classified without oscillation")

local rotation = {
	population = 5,
	bootstrap_stage = "tools",
	available_food = 40,
	available_raw_food = 0,
	available_ore = 8,
	available_tools = 0,
	available_forged_tools = 0,
	built_houses = 1,
	counts = {
		[jobs.cook] = 1,
		[jobs.farmer] = 1,
		[jobs.woodcutter] = 1,
		[jobs.miner] = 1,
		[jobs.builder] = 1,
	},
}
transition, _, transition_kind = needs.choose_job_transition(jobs.cook, rotation, jobs.autonomous)
assert_equal(transition, jobs.blacksmith, "obsolete specialist may rotate directly to the next real demand")
assert_equal(transition_kind, "rotate", "specialist-to-specialist transition is classified")

assert(needs.auto_job_cooldowns.specialize >= 45,
	"specialist cooldown must prevent per-tick oscillation")
assert(needs.auto_job_cooldowns.specialize <= 90,
	"specialist cooldown must remain playable")
assert(needs.auto_job_cooldowns.returning >= 30,
	"return cooldown must prevent immediate bounce")
assert(needs.auto_job_cooldowns.village <= 15,
	"village lock must not serialize useful decisions for minutes")

local village = {
	population = 4,
	active_sites = 0,
	homeless = 0,
	counts = {
		[jobs.autonomous] = 1,
		[jobs.farmer] = 2,
		[jobs.woodcutter] = 1,
		[jobs.miner] = 1,
	},
}
assert_equal(needs.reassignment_priority(jobs.autonomous, village, jobs.cook), 1,
	"autonomous role is the preferred balanced donor")
assert_equal(needs.reassignment_priority(jobs.builder, village, jobs.cook), 2,
	"idle builder is a safe donor")
assert_equal(needs.reassignment_priority(jobs.farmer, village, jobs.cook), 5,
	"only excess farmers can donate")

village.counts[jobs.farmer] = 1
assert_equal(needs.reassignment_priority(jobs.farmer, village, jobs.cook), nil,
	"minimum farmer staffing is protected")
village.active_sites = 1
assert_equal(needs.reassignment_priority(jobs.builder, village, jobs.cook), nil,
	"active builder is protected")
village.recent_danger = 10
assert_equal(needs.reassignment_priority(jobs.builder, village, jobs.guard), 2,
	"an active builder may answer a guard emergency")
village.recent_danger = 0

village.control = {focus = "exploration"}
assert_equal(needs.reassignment_priority(jobs.autonomous, village, jobs.guard), nil,
	"exploration never sacrifices its sole autonomous scout")

print("NEEDS_SPEC_OK")
