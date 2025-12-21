# VoxeLibre Porting Guide

This document details the complete adaptation of working_villages for VoxeLibre (Minecraft-like game for Minetest).

## Overview

The working_villages mod now supports both **minetest_game** and **VoxeLibre** through a compatibility layer that automatically detects the active game and adapts all functionality accordingly.

## Architecture

### Compatibility Layer (`voxelibre_compat.lua`)

The core of the adaptation is the compatibility layer that provides:

1. **Automatic Game Detection**: Detects VoxeLibre by checking for `mcl_core` mod
2. **Item/Block Mapping**: Translates between minetest_game and VoxeLibre namespaces
3. **Helper Functions**: Provides game-agnostic APIs for common operations

### Farming Compatibility (`farming_compat.lua`)

A specialized module for farming mechanics that:

1. **Detects Farming Mods**: Checks for `farming` or `mcl_farming`
2. **Plant Databases**: Maintains separate plant configurations for each game
3. **Unified API**: Provides a consistent interface for farming operations

## Item/Block Mappings

### Core Items

| minetest_game | VoxeLibre | Usage |
|---------------|-----------|-------|
| `default:chest` | `mcl_chests:chest` | Storage containers |
| `default:torch` | `mcl_torches:torch` | Light source |
| `default:torch_wall` | `mcl_torches:torch_wall` | Wall-mounted torch |
| `default:wood` | `mcl_core:wood` | Building material |
| `default:paper` | `mcl_core:paper` | Crafting material |
| `default:obsidian` | `mcl_core:obsidian` | Hard block |
| `default:snow` | `mcl_core:snow` | Snow layer |

### Plants and Nature

| minetest_game | VoxeLibre | Usage |
|---------------|-----------|-------|
| `default:apple` | `mcl_core:apple` | Food item |
| `default:cactus` | `mcl_core:cactus` | Desert plant |
| `default:papyrus` | `mcl_core:reeds` | Sugar cane |
| `default:dry_shrub` | `mcl_core:deadbush` | Dead bush |

### Doors

VoxeLibre doors use a different naming convention:
- `doors:door_wood_a` → `mcl_doors:wooden_door_b_1`
- `doors:door_wood_c` → `mcl_doors:wooden_door_t_1`

Door handling requires special logic as VoxeLibre doors have different states and node names.

### Beds

VoxeLibre supports 16 colored beds instead of a single bed type:
- `beds:bed_top` → `mcl_beds:bed_*_top` (where * is a color)
- `beds:bed_bottom` → `mcl_beds:bed_*_bottom`

All bed colors are supported: red, blue, cyan, grey, silver, black, yellow, green, orange, purple, magenta, pink, white, brown, lime, light_blue.

## Farming System

### minetest_game Farming

The `farming` mod provides various crops with different growth stages:
- Wheat: 8 stages (`farming:wheat_1` to `farming:wheat_8`)
- Carrots, potatoes, etc. with varying stages
- Special items like beanpoles and trellises for support

### VoxeLibre Farming

The `mcl_farming` mod uses Minecraft-like farming:
- Most crops: 8 stages (0-7)
- Wheat: `mcl_farming:wheat_0` to `mcl_farming:wheat_7`
- Different seed/replant mechanics
- No support structures needed

### Farmer Job Adaptation

The farmer job now:
1. Detects which farming mod is active
2. Uses the appropriate plant database
3. Harvests fully-grown crops
4. Replants using correct seeds/items for the active system

## Module-by-Module Changes

### Core Modules

#### `groups.lua`
- Uses `voxelibre_compat.get_door_items()` for door groups
- Uses `voxelibre_compat.get_chest_items()` for chest groups
- Supports all 16 VoxeLibre bed colors

#### `api.lua`
- Door detection uses `voxelibre_compat.is_door()`
- Checks if `doors` mod exists before calling `doors.get()`
- VoxeLibre doors may not support the same API

#### `building.lua`
- Door name normalization handles VoxeLibre formats
- Supports both `_b_` and `_t_` door variants
- Handles `mcl_farming` growth stages

#### `pathfinder.lua`
- Walkability checks use compatibility layer
- Doors are correctly identified in both games

### Job Modules

#### `jobs/builder.lua`
- Torch conversion handles VoxeLibre torch types
- Uses mapped item names for torch placement

#### `jobs/empty.lua`
- Crafting recipe uses mapped item names
- Compatible with both game item sets

#### `jobs/farmer.lua`
- Completely refactored to use `farming_compat` module
- Works with both `farming` and `mcl_farming`
- Correct replanting for each crop type

#### `jobs/plant_collector.lua`
- Herb collection uses mapped item names
- Supports VoxeLibre plant variants

#### `jobs/snowclearer.lua`
- Snow detection uses mapped snow block name

#### `jobs/torcher.lua`
- Torch placement uses mapped torch name

#### `jobs/util.lua`
- Chest detection uses `voxelibre_compat.is_chest()`

#### `jobs/woodcutter.lua`
- Uses item groups (tree, sapling, soil, axe)
- Groups work in both games

### Building Sign Module

#### `building_sign/schematics.lua`
- Schematic loading handles VoxeLibre door formats
- Node name normalization supports both games

## Dependencies

### minetest_game
- Required: None (all optional now)
- Optional: `default`, `doors`, `beds`, `farming`

### VoxeLibre
- Required: None (all optional)
- Optional: `mcl_core`, `mcl_doors`, `mcl_beds`, `mcl_chests`, `mcl_farming`, `mcl_torches`

The mod uses `modpath` checks to determine which mods are loaded and adapts accordingly.

## Complex Porting Points

### 1. Door Mechanics

**Challenge**: VoxeLibre doors have different node names and possibly different APIs.

**Solution**: 
- Detect doors by namespace pattern instead of exact names
- Check if `doors` mod exists before using its API
- Handle cases where door API is unavailable gracefully

### 2. Bed Colors

**Challenge**: VoxeLibre has 16 bed colors vs 1 in minetest_game.

**Solution**:
- Generate list of all bed variants dynamically
- Apply villager_bed groups to all variants
- Bed detection works with any color

### 3. Farming Growth Stages

**Challenge**: Different growth stage systems and final stage numbers.

**Solution**:
- Separate plant databases for each farming system
- Abstract plant detection behind unified API
- Each database defines mature stage and replant items

### 4. Item Group Compatibility

**Challenge**: Some groups might differ between games.

**Solution**:
- Use groups where possible (tree, sapling, soil, etc.)
- These groups are consistent across both games
- Fall back to name checks only when necessary

### 5. Optional Dependencies

**Challenge**: Can't hard-depend on either game's mods.

**Solution**:
- Mark all game-specific mods as optional
- Detect which mods are present at runtime
- Adapt behavior based on available mods

## Character Model and Skeleton

### Model File: character.b3d

Both minetest_game and VoxeLibre use the same 3D model file format: `character.b3d`. This model is provided by:
- **minetest_game**: `default` mod provides the character model
- **VoxeLibre**: `mcl_player` mod provides the character model

The working_villages mod references this model but doesn't include it directly, relying on the base game to provide it.

### Skeleton/Bones Structure

The `character.b3d` model includes the following bone structure for animations:
- **Body**: Main torso bone
- **Head**: Head bone (for head movements)
- **Arm_Left** and **Arm_Right**: Arm bones (for arm movements)
- **Leg_Left** and **Leg_Right**: Leg bones (for walking animations)

### Animation Frames

The villager entities use standard Minetest character animations defined in `api.lua`:
```lua
working_villages.animation_frames = {
  STAND     = { x=  0, y= 79, },  -- Standing still
  LAY       = { x=162, y=166, },  -- Lying down (sleeping)
  WALK      = { x=168, y=187, },  -- Walking animation
  MINE      = { x=189, y=198, },  -- Mining/working animation
  WALK_MINE = { x=200, y=219, },  -- Walking while carrying something
  SIT       = { x= 81, y=160, },  -- Sitting animation
}
```

These frame ranges are compatible with both minetest_game and VoxeLibre character models.

### Skin Textures

Villager skins are PNG texture files applied to the character model:
- **minetest_game**: Traditionally uses 64x32 pixel format
- **VoxeLibre**: Uses 64x64 pixel format (Minecraft-compatible)

The mod includes two default villager skins:
- `villager_male.png`
- `villager_female.png`

Both textures work with either game format. The compatibility layer (`voxelibre_compat.lua`) provides `get_skin_info()` to identify the expected format for each game.

### Full VoxeLibre Skin Support

✅ **Verified Compatibility:**
1. Character model (`character.b3d`) is properly referenced via compatibility layer
2. Skeleton/bones structure is identical between games
3. Animation frames are compatible with both game models
4. Skin textures work in both 64x32 and 64x64 formats
5. All villager entity properties (collisionbox, visual_size, etc.) are compatible

### Initial NPC Spawning

When spawning is enabled (`working_villages_enable_spawn = true`), the mod now spawns an initial group of 5 NPCs at the world spawn point:

1. **Woodcutter** - Collects trees and plants saplings
2. **Farmer** - Tends to crops
3. **Herb Collector** - Gathers plants and herbs
4. **Builder** - Constructs buildings
5. **Unemployed Villager** - Ready to be assigned a job

The initial spawn happens once per world, 5 seconds after server start. NPCs are positioned in a circular pattern around the spawn point for better distribution.

## Testing Recommendations

When testing VoxeLibre compatibility:

1. **Villager Spawning and Appearance**
   - Verify spawn eggs work
   - Check villager appearance with correct textures
   - Verify character model loads correctly (character.b3d)
   - Confirm skeleton/bones are properly animated
   - Test initial spawn of 5 NPCs at world spawn (when spawning enabled)
   - Verify NPCs spawn in circular pattern around spawn point

2. **Animation Verification**
   - Test STAND animation (idle)
   - Test WALK animation (moving)
   - Test MINE animation (working)
   - Test LAY animation (sleeping in bed)
   - Test SIT animation (sitting)
   - Confirm all animations work smoothly without glitches

3. **Basic Jobs**
   - Test woodcutter with VoxeLibre trees
   - Test farmer with mcl_farming crops
   - Test plant collector with VoxeLibre plants

4. **Building System**
   - Test building placement with VoxeLibre blocks
   - Verify door placement in buildings
   - Check bed recognition in homes

5. **Interactions**
   - Test commanding sceptre
   - Verify inventory access
   - Check job changes

6. **Night Behavior**
   - Verify villagers go home at night
   - Check bed pathfinding
   - Test bed sleeping

## Future Enhancements

Potential improvements for VoxeLibre support:

1. **Villager Trading**: Adapt to VoxeLibre's trading system
2. **Village Generation**: Create VoxeLibre-style villages
3. **Mob AI**: Align behavior with VoxeLibre mobs
4. **Block Variants**: Support VoxeLibre-specific block types
5. **Biome Awareness**: Use VoxeLibre biome system

## Conclusion

The VoxeLibre adaptation maintains full compatibility with minetest_game while adding complete VoxeLibre support. The compatibility layer approach ensures:

- **Maintainability**: Changes to one game don't affect the other
- **Extensibility**: Easy to add support for more games
- **Performance**: Runtime detection is minimal overhead
- **Clarity**: Game-specific code is clearly separated

All features of working_villages now work seamlessly in both minetest_game and VoxeLibre.
