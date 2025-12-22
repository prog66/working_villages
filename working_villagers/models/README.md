# Character Model Directory

This directory contains fallback models for villagers.

## Required Model: character.b3d

Villagers use the `character.b3d` 3D model file, which should be provided by your game:
- **minetest_game**: Provided by the `default` mod
- **VoxeLibre**: Provided by the `mcl_player` mod

## If character.b3d is Missing

If you see errors like `Mesh not found: "character.b3d"`, you need to:

### For minetest_game:
1. Ensure the `default` mod is enabled
2. The `default` mod is usually part of the base minetest_game installation

### For VoxeLibre (MineClone2):
1. Ensure the `mcl_player` mod is enabled
2. This mod should be part of your VoxeLibre installation
3. Check that your VoxeLibre version is complete and up-to-date

### Manual Installation (Advanced):
If you cannot enable the required mods, you can manually add a `character.b3d` file to this directory:
1. Obtain a compatible `character.b3d` model file
2. Place it in this `models/` directory
3. The mod will then use this bundled model

## Fallback Model

The `character_fallback.obj` file provides a simple cube-based fallback representation, but it does not support animations like the proper `character.b3d` file. This is provided for reference only and is not automatically used.

## Model Requirements

The character model should:
- Be in B3D format for full animation support
- Include standard character bones: Head, Body, Arm_Right, Arm_Left, Leg_Right, Leg_Left
- Be approximately 2 units tall (1.75 units for the character, head at ~2.0)
- Support the animation frames defined in the mod (stand, walk, mine, sit, lay)
