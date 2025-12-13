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
- Required: `default`
- Optional: `doors`, `beds`, `farming`

#### For VoxeLibre:
- Required: `mcl_core`
- Optional: `mcl_doors`, `mcl_beds`, `mcl_chests`, `mcl_farming`, `mcl_torches`

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
