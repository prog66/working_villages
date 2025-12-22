# minetest mod working_villages
[![luacheck][luacheck badge]][luacheck workflow]  
This mod adds Villagers performing work.
The plan is to make villagers build up their own villages.

[working_villages forum page](https://forum.minetest.net/viewtopic.php?f=9&t=17429)

## Planned Features
* villages
  * built up by the villagers
* villagers
  * trading and building up an economy
  * working / doing their jobs
* jobs
  * miner, farmer, woodcutter and many more

## implemented Features
no crafting recipes yet (you will have to use creative)
features:
* **Learning Mode for Idle Villagers** (NEW!)
  * Villagers without a job automatically enter learning mode
  * They explore the environment and discover new places
  * They socialize with other villagers and players
  * They experiment with simple tasks (gathering items, observing)
  * They ask players for validation on what they learn
  * Makes the village feel more alive and immersive
  * Can be disabled with: `working_villages_enable_learning_mode = false`
  * Settings: `working_villages_learner_explore_radius`, `working_villages_learner_social_range`, `working_villages_learner_experiment_interval`
* **Initial Villager Spawn** (NEW!)
  * When spawning is enabled, 5 NPCs spawn at world spawn on server start
  * Includes: woodcutter, farmer, herb collector, builder, and one unemployed villager
  * NPCs are self-employed and can be commanded by any player with a commanding sceptre
  * Enable with: `working_villages_enable_spawn = true` in minetest.conf or world settings
  * Spawn occurs once per world, 5 seconds after first server start with spawning enabled
* **Blueprint Learning System**
  * Villagers can learn construction blueprints
  * Progressive skill system with experience points
  * Blueprint improvements - upgrade structures over time
  * 8 default blueprints (houses, farms, workshops, infrastructure)
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
  * **learner/apprentice** (learning mode for villagers without a job - explores, socializes, experiments) - NEW!
  * **blacksmith** (works with metal, repairs tools, smelts ores) - NEW!
  * **miner** (mines stone and ores, places torches underground) - NEW!
  * woodcutter/lumberjack (cutting trees and planting saplings)
  * farmer (harvests and replants crops)
  * plant collector (collecting all sort of fauna to produce dyes etc.)
  * player follower (following any player, night active)
  * builder (builds the nearest building defined by a building marker, gains experience)
  * guard (protects the village)
* testing jobs:
  * snowclearer (clearing snow away)
  * torcher (following player and placing torches in the dark, night active)

for developing jobs, villagers, etc. read [api.md](api.MD)  
for new job details see [JOBS.md](JOBS.md)  
for blueprint system see [BLUEPRINTS.md](BLUEPRINTS.md)

## Documentation

📚 **Complete documentation is available:**

- **[ARCHITECTURE.md](ARCHITECTURE.md)** - Detailed system architecture and component overview
- **[API_REFERENCE.md](API_REFERENCE.md)** - Complete API reference for developers
- **[ROADMAP.md](ROADMAP.md)** - Future features and development roadmap
- **[CONTRIBUTING.md](CONTRIBUTING.md)** - How to contribute and coding standards
- **[BLUEPRINTS.md](BLUEPRINTS.md)** - Blueprint learning system documentation
- **[JOBS.md](JOBS.md)** - Detailed job system documentation
- **[api.MD](api.MD)** - Original API documentation

## For Developers

The mod now includes advanced systems for easier development:

### 🤖 AI Behavior System (`ai_behavior.lua`)
- Task priority system for intelligent decision-making
- State machine for villager states
- Memory system for learning and remembering locations
- See `jobs/EXAMPLE_enhanced_plant_collector.lua` for usage

### 🔧 Job Patterns (`job_patterns.lua`)
- Reusable patterns for common job tasks
- Chest interaction helpers
- Search and act patterns
- Tool management utilities
- Reduces code duplication

### 📖 Getting Started
1. Read [ARCHITECTURE.md](ARCHITECTURE.md) to understand the system
2. Check [API_REFERENCE.md](API_REFERENCE.md) for available functions
3. Look at [CONTRIBUTING.md](CONTRIBUTING.md) for coding standards
4. See `jobs/EXAMPLE_enhanced_plant_collector.lua` for a complete example
5. Review [ROADMAP.md](ROADMAP.md) for planned features

## VoxeLibre Compatibility
This mod fully supports VoxeLibre (Minecraft-like game for Minetest). The following adaptations have been made:

### Automatic Detection
The mod automatically detects whether it's running on minetest_game or VoxeLibre and adapts all functionality accordingly.

### Block/Item Mapping
- Doors: `doors:*` → `mcl_doors:*`
- Chests: `default:chest` → `mcl_chests:chest`
- Torches: `default:torch` → `mcl_torches:torch`
- Basic blocks: `default:*` → `mcl_core:*`
- Plants: `default:papyrus` → `mcl_core:reeds`, etc.

### Farming System
Both the minetest_game `farming` mod and VoxeLibre `mcl_farming` are supported:
- Farmer job works with crops from either system
- Plant growth stages are handled automatically
- Replanting logic adapts to the active farming system

### Villager Behavior
All villager jobs work seamlessly in VoxeLibre:
- Woodcutter: Uses VoxeLibre tree/sapling groups
- Farmer: Harvests and plants VoxeLibre crops
- Builder: Places VoxeLibre blocks and doors, gains experience
- Blacksmith: Works with VoxeLibre metals and tools
- Miner: Mines VoxeLibre stone and ores
- Torcher: Places VoxeLibre torches
- Plant collector: Collects VoxeLibre plants

### Complex Porting Points
1. **Door handling**: VoxeLibre uses different door node names and states. The compatibility layer handles both formats.
2. **Bed colors**: VoxeLibre has 16 colored beds vs single bed type in minetest_game. All colors are supported.
3. **Farming stages**: Different growth stage systems between farming mods are abstracted.
4. **Optional dependencies**: Both game dependencies are marked optional to support both environments.

## screenshots
![Screenshot 1](screenshot.png)
![Screenshot 2](screenshot.2.png)
![Screenshot 3](screenshot.3.png)
![Screenshot 4](screenshot.4.png)

## Submodules
Currently working_villages only has the modutil portable submodule.
It is needed to be able to run without the modutil mod.  
This means you can either download the modutil mod and enable it or get the submodule:

When cloning add "--recursive" option to clone including all submodules:
```
git clone --recursive https://github.com/theFox6/working_villages.git
```

If one of the submodule folders is empty use:
```
git submodule update --init
```
This will clone all missing submodules.

## Dependencies
working_villages needs modutil to load utilities it can also use modutil portable though  
doors can be used by the villagers that's why there is a dependency

### Game Compatibility
working_villages is compatible with both **minetest_game** and **VoxeLibre** (formerly MineClone2):

#### For minetest_game:
- Required: None
- Optional: `default` (provides character.b3d model), `doors`, `beds`, `farming`

#### For VoxeLibre:
- Required: None
- Optional: `mcl_core`, `mcl_player` (provides character.b3d model), `mcl_doors`, `mcl_beds`, `mcl_chests`, `mcl_farming`, `mcl_torches`

The mod automatically detects which game is running and adapts its behavior accordingly. All features work seamlessly in both environments.

## missing modutil
If you clone the mod you either need to **install and activate the modutil mod** or you need to **[clone it recursively](#cloning)**.  
If modutil is not present you will get the following error:
`.minetest/mods/working_villages/modutil/portable.lua: No such file or directory`

## cloning
When cloning first add "--recursive" option to clone including all submodules:
```
git clone --recursive https://github.com/theFox6/working_villages.git
```
else the submodule folders will be empty.

If one of the submodule folders is empty use:
```
git submodule update --init
```
This will clone all missing submodules.

To pull all changes in the repo including changes in the submodules use:
```
git pull --recurse-submodules
```

## License
* working_villages by theFox6 is avalible under the MIT License

Exceptions to the above:
* villager skin textures from the Homedecor mod: CC-by-SA 3.0 or higher
* the base of the api is the source code of the Maidroid mod: [LGPLv2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt) or later license.
* the egg textures are included in the Maidroid mod: [CC-BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) or later license.
* the letters texture is from the Memorandum mod
* the sign textures and the base of the torcher job texture are from the default mod in minetest_game and from Gambit: CC BY-SA 3.0
* horsetail texture as base for the herb collectors job texture from Mossmanikin's Ferns: CC-By-SA 3.0

[luacheck badge]: https://github.com/theFox6/working_villages/workflows/luacheck/badge.svg
[luacheck workflow]: https://github.com/theFox6/working_villages/actions?query=workflow%3Aluacheck
