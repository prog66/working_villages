# working_villages runtime harness

`working_villages_test` is a small Luanti test mod. Enable it only in a disposable
world together with `working_villages`. A successful run logs
`WORKING_VILLAGES_TESTS_OK` and shuts the dedicated server down.

The harness checks deterministic loader, initial-spawn state, owner-setting
precedence, persistence round-trip, exact inventory/collaboration accounting,
population allowance, migration, shelter/rest, gameplay mode, and the active
game profile. It also runs nineteen standalone specs in isolated globals under
Luanti's Lua 5.1 runtime: startup, needs, population, access, forms access,
collaborative tasks, crafting, timekeeping, job coroutines, chest cadence, tool
fallback, farmer priority, crop planning, construction-site planning, miner
bootstrap, autonomous wait, physical delivery, artisan safety, and
public-server survival. Each must log
`STANDALONE_SPEC_OK:<filename>`. The village-registry spec runs separately and
must log `VILLAGE_REGISTRY_SPEC_OK`.

For an isolated run, create a disposable world, link `working_villagers` and
`working_villages_test` into its `worldmods` directory, copy `world.mt` and
`minetest.conf`, then start a dedicated Luanti server with VoxeLibre. Do not use
an existing player world for this harness.

Release archives intentionally exclude `working_villagers/tests`. To validate
an extracted or installed package without adding files to it, also link the
repository directory `working_villagers/tests` into `worldmods` under the name
`working_villages_specs` and enable that test-support mod. A successful strict
package run logs `WORKING_VILLAGES_EXTERNAL_SPECS_OK`. The specifications stay
outside the runtime package while still exercising its public and internal
contracts.

The final audit run had no `ERROR`, `FATAL`, or `ModError`, but produced 20
`Calling this function during script init is disallowed` warnings. Many are
test-harness noise from deliberately exercising access/auth and game-time APIs
during initialization. A successful run is therefore not warning-free; inspect
errors and success markers separately, and do not attribute warnings to normal
gameplay without a reproduction outside the harness.

`working_villages_spawn_test` is a separate, slower three-run harness. Enable
initial spawning, set `working_villages_initial_village_owner` to
`working_villages_spawn_test_owner`, and run the same disposable world three times.
The first run must log `WORKING_VILLAGES_SPAWN_OK:created:5`; the second must log
`WORKING_VILLAGES_SPAWN_OK:reloaded:5`,
`WORKING_VILLAGES_SPAWN_DURABILITY_OK:unload_reload:5`, and
`WORKING_VILLAGES_SPAWN_DURABILITY_OK:replacement:5`; the third must log
`WORKING_VILLAGES_SPAWN_DURABILITY_OK:restart:5`. It checks persistent slot
identities, the five configured initial roles, unload/reload without duplication,
and one exact replacement after a real entity removal. It does not simulate
player gameplay or job AI.

`working_villages_inventory_test` is a profile-aware container callback test.
Copy `inventory_world.mt` and `inventory_test.conf`, enable the test mod beside
`working_villages`, and select either VoxeLibre or minetest_game with Luanti's
`--gameid`. It resolves the active game's real furnace and ingot, transfers two
outputs through the registered allow/on callbacks, and checks exact accounting.
VoxeLibre additionally verifies that accumulated furnace XP remains stored when
an offline owner cannot be represented by a real `PlayerRef`. Success logs
`OFFLINE_FURNACE_CALLBACK_OK:voxelibre` or
`OFFLINE_FURNACE_CALLBACK_OK:minetest_game` and shuts the server down.

`working_villages_home_test` places the active game's real bed and door nodes.
It validates the required access path, rejects missing/blocked access, and
checks that one bed cannot be assigned to two villagers. Success logs
`HOME_VALIDATION_SPEC_OK`.

`working_villages_door_test` resolves the active game's concrete door nodes and
craftitem, verifies a survival recipe, then calls the real registered
`craftitem.on_place`. It checks the two-node pair, orientation, exact 2-to-1
consumption, recognition of both schematic steps, and an atomic refusal when
only the upper node is protected. Success logs
`DOOR_PLACEMENT_EXACT_OK:voxelibre` or
`DOOR_PLACEMENT_EXACT_OK:minetest_game`.

`working_villages_tool_runtime_test` creates one real miner entity with empty
tool slots. Before the tool scenario, it places a real hostile four nodes away
and first verifies public-server health, activation protection, exact reduced
damage and unauthorized-player blocking through the production `on_punch`.
It drives the production `on_step` callback repeatedly. The miner must retain
one persistent path away from danger without a C-boundary yield, pause or job
change. It then requires one immediate, deduplicated tool request, a visible
fallback and no free pickaxe, delivers one real pickaxe from the active game,
and requires the miner to equip it, clear the fallback and retain exactly one
tool. Success logs `EMERGENCY_RETREAT_RUNTIME_OK:<profile>` followed by
`TOOL_FALLBACK_RUNTIME_OK:voxelibre` or
`TOOL_FALLBACK_RUNTIME_OK:minetest_game`.
The same run finally requires a half-health guard to disengage while keeping
its profession coroutine, logged as `WOUNDED_GUARD_RETREAT_RUNTIME_OK:<profile>`.

`working_villages_farmer_seed_test` is a real-engine regression for the
farmer's seed bootstrap. Copy `farmer_seed_world.mt` and
`farmer_seed_test.conf` into a fresh disposable world, link
`working_villages` and the test mod under `worldmods`, then run it once in each
supported game. The harness creates a real farmer with one real hoe but no
seed, surrounds the field with the active game's natural grass whose registered
drop table can yield a crop seed, and lets the production `on_step` and farmer
coroutine run without direct job calls. It requires the farmer to dig a source
and observe a legitimately dropped seed. It then gives the unchanged runtime
up to 120 seconds to transform dirt into real farmland and sow a real crop.
Tilling and sowing get their own success markers; failure to sow is a harness
failure, so `FARMER_SEED_RUNTIME_OK` proves the complete acquisition, tilling
and sowing chain rather than only the seed bootstrap.
Markers are:

```text
FARMER_SEED_ZERO_INJECTION_OK:<profile>:<hoe>
FARMER_NATURAL_SEED_ACQUIRED_OK:<profile>:<seed>:...
FARMER_AUTONOMOUS_TILL_OK:<profile>:<farmland>:...
FARMER_AUTONOMOUS_SOW_OK:<profile>:<crop>:...
FARMER_SEED_RUNTIME_OK:<profile>
```

`working_villages_woodcutter_bootstrap_test` is the corresponding real-engine
regression for the first empty woodcutter of a new village. Copy
`woodcutter_bootstrap_world.mt` and `woodcutter_bootstrap_test.conf` into a
fresh disposable world, link the production mod and this test mod under
`worldmods`, and run it once per supported game. It starts one real woodcutter
with no wood, chest, workbench or tool, then provides only registered tree
nodes. The production job may hand-dig at most six trunks, and only when the
active game's real survival-hand capabilities say they are diggable. In
VoxeLibre it must craft and consume one real workbench before the registered
3x3 wooden-axe recipe can succeed. A paused real autonomous worker first proves
that the woodcutter yields workbench ownership instead of competing with the
normal chest/utility bootstrap, then leaves the focused scenario. The harness
counts world removals, every relevant carried/dropped stack, the workbench and
the axe in common plank units, verifies the six-log budget against the exact
registered workbench/chest/axe recipes, and also leaves an undiggable tree-group
negative control untouched.
Success logs:

```text
WOODCUTTER_HAND_GATE_OK:<profile>:<log>:plank=<plank>
WOODCUTTER_ZERO_INJECTION_OK:<profile>:logs=<count>
WOODCUTTER_WORKBENCH_ARBITRATION_OK:voxelibre:job=working_villages:job_autonome
WOODCUTTER_REAL_LOG_TRANSFER_OK:<profile>:<log>:removed=<n>:carried_or_dropped=<n>
WOODCUTTER_AXE_CRAFTED_OK:<profile>:<axe>:logs_dug=<n>
WOODCUTTER_BOOTSTRAP_BALANCE_OK:<profile>:supplied=<n>:accounted=<n>
WOODCUTTER_BOOTSTRAP_BUDGET_OK:<profile>:available=<n>:required=<n>:chest=<item>
WOODCUTTER_BOOTSTRAP_RUNTIME_OK:<profile>
```

`working_villages_physical_delivery_test` is a separate two-run engine
regression for autonomous bootstrap arbitration and a real `resource_delivery`
task. Copy
`physical_delivery_world.mt` and `physical_delivery_test.conf` into a fresh
disposable world, link `working_villages` and this test mod under `worldmods`,
then start the same world twice. Override the template game ID when testing
Minetest Game.

The fresh-world prelude creates a real autonomous worker, woodcutter supplier,
and builder requester with no shared chest. It queues an executable outbound
request on the autonomous worker and requires that request to remain untouched
while its profession continues. The woodcutter must then walk one exact test
resource to the autonomous worker with no remote transfer. Only after a valid
active-game chest is constructed and registered may the autonomous worker walk
the deferred resource to the builder. The two resources are counted across all
three detached inventories, the shared chest, and dropped entities throughout.
Success logs:

```text
PHYSICAL_DELIVERY_BOOTSTRAP_RESERVED_OK:<profile>
PHYSICAL_DELIVERY_BOOTSTRAP_RECEPTION_OK:<profile>
PHYSICAL_DELIVERY_BOOTSTRAP_RELEASE_OK:<profile>
```

The rest of the first run creates a real builder and a real woodcutter 24 nodes apart. The
woodcutter owns four units of a registered wood item and the builder requests
exactly three through `collaborative_tasks.start_task`. No shared chest is
configured, so this intentionally exercises direct villager-to-villager
delivery. The run requires zero transfer outside a three-node arrival radius,
observes the supplier move toward the requester, persists both identities and
the active task, then logs:

```text
PHYSICAL_DELIVERY_NO_REMOTE_TRANSFER_OK:<profile>
PHYSICAL_DELIVERY_PHASE1_OK:<profile>
```

After restarting the same world, the second run requires the same two real
entities and active task, unchanged inventories, resumed supplier movement, an
atomic 3-unit transfer only at proximity, a terminal task result of exactly
three units, and unchanged totals for one additional second. Success logs:

```text
PHYSICAL_DELIVERY_RELOAD_OK:<profile>
PHYSICAL_DELIVERY_MOVEMENT_OK:<profile>
PHYSICAL_DELIVERY_EXACT_OK:<profile>
PHYSICAL_DELIVERY_PERSISTENCE_OK:<profile>
PHYSICAL_DELIVERY_RUNTIME_OK:<profile>
```

The harness counts the requested item across both detached inventories and all
dropped item entities throughout the scenario. A third run is optional and
logs `PHYSICAL_DELIVERY_RECHECK_OK:<profile>` only if the completed state still
has the exact 3/1 split. The test is deliberately strict: a runtime that
transfers a `help_needed.items` message immediately at range fails before any
phase-one success marker.

Most harnesses are headless server tests. They are not evidence of a human
playthrough, animation quality or gameplay pleasure. The dedicated
multiplayer-protection harness is the exception: it requires two real connected
graphical clients, but remains an automated protection check rather than a
human usability session.

`working_villages_village_runtime_test` is the strict two-phase complete-village
harness. In a fresh survival world it starts five real professions and requires
the chain wood, shared chest, tools, crops, ore, furnace, cooking, forging,
physical delivery and a partially built `minimal_shelter`. Phase one shuts down
only after writing an exact construction checkpoint. Starting the same world a
second time must restore the five identity tuples, inventories, stable job
state, construction index and ledger, then complete danger interruption/resume,
exact construction accounting, hunger, rest, night sleep and dawn work resume.
Only `WORKING_VILLAGES_VILLAGE_RUNTIME_OK:<profile>` is a terminal success.

`working_villages_native_combat_test` runs only with VoxeLibre and uses its
registered `mobs_mc:zombie` entity. A real guard must receive damage, kill three
successive native monsters, survive and retain its identity and profession for
at least sixty seconds. Success logs
`WORKING_VILLAGES_NATIVE_COMBAT_OK:voxelibre`.

`working_villages_multi_village_load_test` creates four isolated registry
records and twenty real villagers, runs them for sixty seconds and checks every
owner/profession identity throughout. It also rejects a 95th-percentile server
step above 0.20 seconds or a maximum step above one second. Success logs
`WORKING_VILLAGES_MULTI_VILLAGE_LOAD_OK:<profile>`.

`working_villages_multiplayer_protection_test` waits for the two real connected
clients `wv_owner_alpha` and `wv_owner_beta`, creates a village and claim for
each and calls the engine's real dig path. Each owner must be able to dig in
their own claim and be refused in the neighbouring claim; management rights
must also remain owner-specific. Success logs
`WORKING_VILLAGES_MULTIPLAYER_PROTECTION_OK:players=2:villages=2:own_dig=allowed:cross_dig=blocked`.

`working_villages_agricultural_economy_test` validates the two renewable
agricultural recipes needed by a fresh village in both supported games. Copy
`agricultural_economy_world.mt` and `agricultural_economy_test.conf` into a
fresh disposable world and link this test mod beside `working_villages`.
Override the template game ID for Minetest Game. The test gives the production
recursive crafter exactly six harvested wheat items and one registered tree
log. It must recursively turn the log into its real plank output, consume two
of those planks through two real straw-bundle recipes, and produce exactly the
active profile's `minimal_shelter` bed-bottom node. The harness requires the
unused recipe planks to remain and rejects every other intermediate or extra
output. It also asks Luanti's cooking engine to process two wheat one at a time
and requires exactly two edible flatbreads and zero remaining wheat. Success
logs:

```text
AGRICULTURAL_FLATBREAD_RECIPE_OK:<profile>:<wheat>:working_villages:flatbread:2>2
AGRICULTURAL_BED_RECIPE_OK:<profile>:<wheat>+<log>:6+1>1+<unused_planks>:<bed_bottom>
WORKING_VILLAGES_AGRICULTURAL_ECONOMY_OK:<profile>
```

This recipe/accounting harness does not itself drive a farmer, a cook, a
furnace timer, or a builder construction coroutine. Those remain acceptance
conditions for the complete-village runtime harness.
