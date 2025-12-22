# Character Model Directory

This directory is reserved for potential future bundled character models.

## Required Model: character.b3d

Villagers use the `character.b3d` 3D model file, which must be provided by your game:
- **minetest_game**: Provided by the `default` mod
- **VoxeLibre**: Provided by the `mcl_player` mod

## If character.b3d is Missing

If you see errors like `Mesh not found: "character.b3d"`, you need to:

### For minetest_game:
1. Ensure the `default` mod is enabled
2. The `default` mod is usually part of the base minetest_game installation
3. If it's missing, reinstall minetest_game

### For VoxeLibre (MineClone2):
1. Ensure the `mcl_player` mod is enabled
2. This mod should be part of your VoxeLibre installation
3. Check that your VoxeLibre version is complete and up-to-date
4. If using an older version of MineClone2, try updating to VoxeLibre

### Troubleshooting:
- Check that the required mod is listed in your enabled mods
- Verify the mod directory exists in your game installation
- Try reinstalling your game (minetest_game or VoxeLibre)
- Ensure no mod loading errors occur before working_villages loads

## Reference Files

The `character_fallback.obj` file provides a simple cube-based reference model showing approximate villager proportions. This is for reference only and is not automatically used by the mod.

## Model Requirements

The character model should:
- Be in B3D format for full animation support
- Include standard character bones: Head, Body, Arm_Right, Arm_Left, Leg_Right, Leg_Left
- Be approximately 2 units tall (1.75 units for the character, head at ~2.0)
- Support the animation frames defined in the mod (stand, walk, mine, sit, lay)
