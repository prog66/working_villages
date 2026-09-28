# minetest mod working_villages

This mod adds Villagers performing work.
The plan is to make villagers build up their own villages.

This is a fork ([prog66/working_villages](https://github.com/prog66/working_villages))
of the original [theFox6/working_villages](https://github.com/theFox6/working_villages)
mod; see [cloning](#cloning) below and License at the bottom for
attribution. All alpha.1+ work described in this document lives on this
fork.

Current local release: **0.13.0-alpha.9**. It is an auditable development
package, not a stable or ContentDB release. See [DEPLOYMENT.md](DEPLOYMENT.md)
for the verified archive/install workflow and [AUDIT_STATUS.md](AUDIT_STATUS.md)
for the remaining gameplay gates.

[working_villages forum page](https://forum.minetest.net/viewtopic.php?f=9&t=17429)

## Quick start: how to actually play this

The rest of this document is a detailed, hedged technical/audit reference.
This section is the short version for someone who just installed the mod
and wants to see villagers doing things.

1. **Install** it as described in [INSTALLATION.md](INSTALLATION.md), then
   set `working_villages_enable_spawn = true` in your world/minetest.conf
   (see [settingtypes.txt](working_villagers/settingtypes.txt) for every
   other tunable).
2. **Join the world.** Five villagers spawn near your spawn point on first
   join: a woodcutter, a farmer, a miner, a builder, and an "autonomous"
   generalist. If the automatic spawn doesn't trigger, run `/wv_spawn5`
   near yourself.
3. **Watch them work.** This is the point of the mod: villagers are meant
   to run the village *by themselves* — chopping wood, farming, mining,
   crafting tools, building houses, storing everything in a shared chest —
   with no player input required. The "autonomous" villager bootstraps the
   village (places the first shared chest, picks up whatever job is
   missing) so the other four have somewhere to work from.
4. **Check the HUD.** Look at your closest owned villager: a small panel
   appears in the corner of your screen showing that villager's name, job,
   and needs (hunger/energy/tools/materials). When none of your villagers
   are nearby, it shows a one-line summary of your whole village instead
   (population per job).
5. **Help them go faster if you want to** — you never have to:
   - Hand a villager tools, food, or building materials directly (they
     accept real item drops/inventory transfers).
   - Right-click any villager (bare-handed) to open its talk menu: a
     village dashboard, priority/strategy controls, and a forced "next
     building" order.
   - Craft and use the **commanding sceptre**: left-click a villager to
     pause/resume it, right-click one while holding the sceptre (if you
     manage it) to jump straight to its inventory/job-change screen, and
     use its own use-menu to pilot the whole village (strategic focus,
     notification level, forced next build) without hunting down every
     individual villager.
   - Set/move the shared village chest yourself with `/wv_storage_set here`
     if you want it somewhere specific before the autonomous villager gets
     to it.
6. **Change jobs** any time from a villager's inventory menu ("change
   job"), or hand it an empty/learner job sheet to make it idle or start
   learning. See the full job list below and [JOBS.md](JOBS.md) for what
   each one actually does.

That's the loop: spawn a group, let them run the village on their own pace,
and step in with direct help (or the sceptre) whenever you want things to
move faster. Everything below this point gets progressively more detailed
and more focused on exactly what is and isn't proven to work yet — see
[AUDIT_STATUS.md](AUDIT_STATUS.md) if you want the unvarnished state of
testing before relying on this on a real server.

## Features represented in the current code

The default `working_villages_gameplay_mode` is `survival`: villager crafting,
placement, digging and industry are intended to consume real resources.
`creative_test` is a separate development mode which permits only the
explicitly enabled testing shortcuts. Results obtained with those shortcuts do
not validate the survival economy.

Six direct recipes are currently registered: the commanding sceptre, the
empty job sheet, the learner job sheet, the straw bundle, the agricultural bed
and cooked flatbread. Most profession items do not have a direct craft recipe,
so recipe coverage is still incomplete.

* **Visual and Animation Systems** (v2.0 code; client rendering still requires manual validation)
  * Hand-item positioning and equipment-display handling are present
  * Guard attack/walk/idle transition handling is present
* **Job Capability System** (NEW! v2.0)
  * Capability metadata and notification hooks are available to professions
  * Several jobs declare specializations such as combat, mining, farming, crafting or furnace use
* **Learning Mode for Idle Villagers** (NEW!)
  * Villagers without a job automatically enter learning mode
  * They explore the environment and discover new places
  * They socialize with other villagers and players
  * They experiment with simple tasks (gathering items, observing)
  * They ask players for validation on what they learn
  * The resulting pacing and usefulness still need a manual playtest
  * Can be disabled with: `working_villages_enable_learning_mode = false`
  * Settings: `working_villages_learner_explore_radius`, `working_villages_learner_social_range`, `working_villages_learner_experiment_interval`
* **Initial Villager Spawn** (NEW!)
  * When spawning is enabled, 5 NPCs spawn near the world spawn anchor
  * The fixed initial roles are woodcutter, farmer, autonomous, miner, and builder
  * Owner resolution prefers a persisted owner, then the requester of an explicitly forced manual spawn, then `working_villages_initial_village_owner`, and finally the first connected player. Public self-employed ownership is used only when no other owner is available and `working_villages_self_employed_public = true`
  * Enable with: `working_villages_enable_spawn = true` in minetest.conf or world settings
  * Spawn occurs once per world, using `static_spawnpoint` when configured, otherwise the first joining player's spawn position
  * Manual recovery command: `/wv_spawn5` near your player position. A player with the `server` privilege may use it in either mode; a non-admin may use it only in `creative_test` while carrying a commanding sceptre
* **Shared Village Storage**
  * Villagers take and deposit items in the registered shared-storage chest network, not in arbitrary nearby chests
  * Use `/wv_storage_set here` near a chest to define or move the village shared chest
  * Use `/wv_storage_show` to verify the current shared chest and `/wv_storage_clear` to reset it
  * Villagers now scan all marked shared chests around that anchor and retry logistics more frequently
* **Missing-tool fallback (alpha.3)**
  * Miners, woodcutters and builders equip a carried tool before using it
  * They check shared storage, try resource-accounted crafting, then issue one identified request without changing profession
  * While waiting, they collect real nearby supplies or visibly patrol instead of remaining motionless
  * Farmers, guards and autonomous villagers now avoid delayed or duplicate supply requests after a server restart
* **Safe emergency navigation (alpha.4)**
  * A non-guard under threat follows an isolated, persistent escape path without yielding from the engine callback
  * Emergency navigation no longer overwrites a suspended profession path and resumes normal movement when danger ends
  * Callback-driven maintenance placement keeps protection and inventory accounting without an illegal coroutine yield
* **Public-server survivability (alpha.6)**
  * Villagers have twice their historical maximum health by default and take half incoming damage after armor and shield reductions
  * Damage is decided before Luanti applies it, so a fatal hit can no longer remove the entity before armor is accounted for
  * A ten-second activation shield prevents deaths while AI and mapblocks resume; fed villagers regenerate slowly after twenty safe seconds
  * Direct player damage defaults to `owner_only`; strangers cannot grief villagers, while `protection_bypass` administrators retain control
  * Any accepted hit triggers danger immediately, and villagers at or below half health retreat; this includes guards
  * Every value is configurable in `settingtypes.txt`; set `working_villages_player_damage_mode = none` for fully protected public NPCs
* **Deterministic farming and safe construction (alpha.7)**
  * New plots keep a persistent crop plan instead of changing crop with inventory pickup order; server owners can choose `uniform`, deterministic `rows`, or legacy `available`
  * Harvested plants are replanted only with their matching seed, and missing planned seed is retried before a deliberate replan
  * Autonomous sites use a deterministic ring search and reject the complete footprint when its foundation is uneven, wet, protected, occupied, inaccessible, or too close to another marker
  * Blueprint interiors now contain explicit air-clearing steps; harmless vegetation is removed physically before walls are placed, while solid or liquid obstructions pause the site
  * The builder that opens a site reserves it immediately, and workers already at their job/crop target skip pointless path searches
  * Site validation has a node-work budget so large blueprints cannot multiply an unbounded terrain scan in one decision
* **Privacy fix, real HUD, and a new job (alpha.8)**
  * The village dashboard no longer reveals a village's exact chest/home/job coordinates to players who don't manage it; any player could previously read that from any villager
  * The persistent per-player HUD (needs + tracked villager) was rendering nothing but text since its introduction (a transparent placeholder texture was being colorized, which stays transparent); bars are now actually visible, with a village summary shown when no owned villager is nearby
  * New **trader** job: mans a trading post whose talk-menu page opens a read/write window onto the real shared chest via Minetest's own list widgets, gated to owner/allies
* **Fixed a mod-breaking Lua limit, and a context-sensitive talk menu (alpha.9)**
  * `api.lua` had grown past Lua's hard 200-local-variables-per-function limit; the mod could no longer load at all under a real interpreter. Found by an actual deployment attempt and fixed by scoping two internal subsystems into `do...end` blocks
  * The villager talk menu now hides options that don't apply to the villager you're talking to (a blacksmith-only order screen no longer shows up when talking to a farmer, and so on) instead of showing all options to everyone
  * See [CHANGELOG.md](CHANGELOG.md) for the full list of alpha.8/alpha.9 fixes
* **Targeted P0 autonomy evidence (alpha.5)**
  * A physical supplier-to-requester delivery moved real cargo between two villagers, with exact conservation and restart recovery in both supported games
  * A real farmer acquired a natural seed, tilled soil and sowed it in both profiles; the complete mature-crop harvest/replant/deposit loop remains open
  * A real miner started empty, consumed exactly three cobbles and two sticks from shared storage, crafted a capable pickaxe, mined one registered iron ore, travelled more than ten nodes and deposited the exact drop in both profiles
  * Blacksmith output and builder consumption have deterministic protection against partial-deposit loss, duplicate output and incapable tools; these are safety contracts, not complete profession playthroughs
  * The two-phase five-villager harness now counts terrain, inventories, furnaces, deliveries and construction across a restart, but no terminal full-economy verdict has yet been obtained
* **Blueprint Learning System**
  * Villagers can learn construction blueprints
  * Progressive skill system with experience points
  * Blueprint improvements - upgrade structures over time
  * 12 blueprint definitions are registered (houses, farms, workshops, infrastructure and decoration); end-to-end construction of every definition is not yet validated
  * See [BLUEPRINTS.md](BLUEPRINTS.md) for details
* building markers
  * for building houses and saving the houses details
  * save the position of the door and the bed
  * some jobs will let the villagers return home at night
  * at home the villagers will go to bed
* spawn-eggs for villagers
  * female and male
  * (just for a nicer look)
* commanding sceptre
  * leftclick villagers to let them pause their work
  * rightclick villagers to open the inventory
  * items can be exchanged in the inventory
  * home can be set in the inventory
  * jobs can be changed in the inventory
* jobs
  * jobs define what the villagers should do
  * jobs can be changed in the inventory by clicking change job
  * in the job change form the jobs can be changed by replacing the current job by one of the jobs below (shift+click possible)
* **registered jobs:**
  * **empty** (idle job item; can hand over to learning mode when enabled)
  * **learner/apprentice** (learning mode for villagers without a job - explores, socializes, experiments) - NEW!
  * **autonomous** (bootstrap, resource collection and exploration logic) - NEW!
  * **cook** (shared-storage and furnace workflow) - NEW!
  * **blacksmith** (works with metal, repairs tools, smelts ores) - NEW!
  * **miner** (mines stone and ores, places torches underground) - NEW!
  * **trader** (mans the trading post; remote read/write access to the shared chest via its talk menu, gated to owner/allies) - NEW!
  * woodcutter/lumberjack (cutting trees and planting saplings)
  * farmer (harvests and replants crops)
  * plant collector (collecting all sort of fauna to produce dyes etc.)
  * player follower (following any player, night active)
  * builder (builds the nearest building defined by a building marker, gains experience)
  * guard (protects the village)
* testing jobs:
  * snowclearer (clearing snow away)
  * torcher (following player and placing torches in the dark, night active)

for developing jobs, villagers, etc. read [api.md](working_villagers/api.MD)
for new job details see [JOBS.md](JOBS.md)  
for blueprint system see [BLUEPRINTS.md](BLUEPRINTS.md)

## Documentation

The documentation set currently includes:

- **[CHANGELOG.md](CHANGELOG.md)** - What changed in each alpha, including bugs found and fixed
- **[ARCHITECTURE.md](ARCHITECTURE.md)** - Detailed system architecture and component overview
- **[API_REFERENCE.md](API_REFERENCE.md)** - Maintained public API reference for developers
- **[ROADMAP.md](ROADMAP.md)** - Future features and development roadmap
- **[CONTRIBUTING.md](CONTRIBUTING.md)** - How to contribute and coding standards
- **[BLUEPRINTS.md](BLUEPRINTS.md)** - Blueprint learning system documentation
- **[JOBS.md](JOBS.md)** - Detailed job system documentation
- **[INSTALLATION.md](INSTALLATION.md)** - Supported-game installation and first checks
- **[DEPLOYMENT.md](DEPLOYMENT.md)** - Reproducible local alpha packaging and deployment
- **[AUDIT_STATUS.md](AUDIT_STATUS.md)** - Evidence matrix and known blockers
- **[VALIDATION_CHECKLIST.md](VALIDATION_CHECKLIST.md)** - Manual gameplay protocol
- **[api.MD](working_villagers/api.MD)** - Original API documentation

## For Developers

### AI Behavior System (`ai_behavior.lua`)
- Task priority system for intelligent decision-making
- State machine for villager states
- Memory system for learning and remembering locations

### Job Patterns (`job_patterns.lua`)
- Reusable helpers for common job tasks (chest interaction, search-and-act,
  tool management) meant to reduce duplication across job files
- Loaded, but not currently used by any shipped job; the only place it is
  actually exercised today is the example below. Adopting it in existing
  jobs is open work (see ROADMAP.md)

### Getting Started
1. Read [ARCHITECTURE.md](ARCHITECTURE.md) to understand the system
2. Check [API_REFERENCE.md](API_REFERENCE.md) for available functions
3. Look at [CONTRIBUTING.md](CONTRIBUTING.md) for coding standards
4. See the [enhanced plant-collector example](working_villagers/jobs/EXAMPLE_enhanced_plant_collector.lua)
   for how `ai_behavior.lua` and `job_patterns.lua` are meant to be used
   together; it is not loaded by default
5. Review [ROADMAP.md](ROADMAP.md) for planned features

## Game compatibility

The runtime detects VoxeLibre through `mcl_core` and Minetest Game through
`default`. Unsupported games fail with an explicit startup error. Item, node,
door, bed, chest, furnace, farming, tool, and food differences are routed
through the compatibility layer where the current code needs them.

The current automated evidence uses Luanti 5.17.0. Headless disposable-world
tests have loaded the mod, exercised mappings and storage, performed exact
container/furnace transfers, checked initial-spawn persistence, exercised
targeted home/door scenarios and completed targeted physical-delivery, farmer
and miner paths with both VoxeLibre and the official Minetest Game. The full
targeted VoxeLibre runs used an isolated disposable game copy
whose `vl_hudbars` dependency metadata was patched to work around a game-side
load-order failure. The same metadata fix now lets the locally installed
VoxeLibre 0.92.1 pass the strict core harness, but this is still not proof from
an untouched VoxeLibre installation. No connected client playthrough, complete
five-villager economic chain, or verdict about playability has yet been
observed in either game. See
[AUDIT_STATUS.md](AUDIT_STATUS.md) for the proof matrix and remaining gates.

### Examples of explicit block/item mappings
- Wood door states: `doors:door_wood_a` / `doors:door_wood_c` → matching `mcl_doors:*` states
- Chests: `default:chest` → `mcl_chests:chest`
- Torches: `default:torch` → `mcl_torches:torch`
- Basic examples: `default:stone` → `mcl_core:stone`, `default:cobble` → `mcl_core:cobble`
- Plant example: `default:papyrus` → `mcl_core:reeds`

### Farming system

The code contains crop mappings, growth-stage detection, harvest and replant
branches for the Minetest Game `farming` mod and VoxeLibre `mcl_farming`.
Mappings have automated coverage; a complete farmer harvest/replant cycle has
not yet been manually validated in either profile.

### Villager behavior represented in code

The compatibility layer supplies active-game item and node candidates to the
woodcutter, farmer, builder, blacksmith, miner, torcher and plant collector.
This describes routing present in the source, not proof that each profession
can complete its full gameplay loop in both games.

### Important porting points
1. **Door handling**: VoxeLibre uses different door node names and states. Targeted headless door scenarios pass in both profiles, but real player/villager traversal still needs manual validation.
2. **Bed colors**: VoxeLibre has colored beds while Minetest Game has one base type; the registered color mappings are enumerated in the compatibility layer.
3. **Farming stages**: Different growth stage systems between farming mods are abstracted.
4. **Optional dependencies**: game mods are declared optional so one package can load after whichever supported game provides them.

## screenshots
![Screenshot 1](screenshot.png)
![Screenshot 2](screenshot.2.png)
![Screenshot 3](screenshot.3.png)
![Screenshot 4](screenshot.4.png)

## Submodules

The repository still contains historical Git metadata for `modutil`, but the
current runtime uses the maintained local `working_villagers/loader.lua`.
Neither the external `modutil` mod nor its portable submodule is required to
start the current code.

## Dependencies

Install the `working_villagers` source directory as a mod named
`working_villages`, then enable it in either VoxeLibre or Minetest Game. Game
modules such as doors, beds, farming, chests, furnaces, and tools are optional
dependencies in `mod.conf` so Luanti orders them before this mod when present.
The exact clean-install procedure and known test boundaries are documented in
[INSTALLATION.md](INSTALLATION.md).

### Game Compatibility
The code targets both **Minetest Game** and **VoxeLibre** (formerly MineClone2):

#### For Minetest Game:
- Profile anchor: `default`
- Used when available: `player_api`, `doors`, `beds`, `farming`, `flowers`

#### For VoxeLibre:
- Profile anchor: `mcl_core`
- Used when available: the declared `mcl_*` door, bed, chest, farming,
  furnace, tool, inventory, armor, mob, and sound modules

Automated engine coverage exists for both profiles. Manual validation of every
job, door traversal, bed use, combat, and the full survival economy remains
required before describing either profile as fully compatible.

## cloning

This repository is a fork of [theFox6/working_villages](https://github.com/theFox6/working_villages),
the original mod this one is built on (see License below for attribution).
All alpha work described in this document happens on this fork; clone it
directly rather than the upstream original:
```
git clone https://github.com/prog66/working_villages.git
```

Contributors who specifically need the repository's historical submodule
checkout may additionally run:
```
git submodule update --init
```

To pull all changes in the repo including changes in the submodules use:
```
git pull --recurse-submodules
```

## License
* working_villages by theFox6 is available under the MIT License

Exceptions to the above:
* villager skin textures from the Homedecor mod: CC-by-SA 3.0 or higher
* the base of the api is the source code of the Maidroid mod: [LGPLv2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt) or later license.
* the egg textures are included in the Maidroid mod: [CC-BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) or later license.
* the letters texture is from the Memorandum mod
* the sign textures and the base of the torcher job texture are from the default mod in minetest_game and from Gambit: CC BY-SA 3.0
* horsetail texture as base for the herb collectors job texture from Mossmanikin's Ferns: CC-By-SA 3.0
