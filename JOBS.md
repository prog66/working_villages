# New Job Documentation

This document describes the new specialized jobs added to the working_villages mod.

## Blacksmith Job

### Overview
The blacksmith is a specialized villager that works with metal and tools. They collect metal ores, smelt them, repair damaged tools, and contribute to the village's metalworking needs.

### Capabilities

1. **Metal Collection**
   - Actively searches for metal ores (iron, copper, gold)
   - Collects metal ingots
   - Stores metals for later use

2. **Tool Repair**
   - Detects damaged tools in inventory
   - Repairs tools to restore durability
   - Tools are considered damaged if they have more than 20% wear
   - Each repair restores 10% of tool durability
   - Awards 1 experience point per repair

3. **Forge Work**
   - Seeks out furnaces to work at
   - Prepares to smelt ores into ingots
   - Works best when near a furnace

4. **Blueprint System Integration**
   - Gains experience through repairs and metalworking
   - Can learn advanced workshop and forge blueprints
   - Contributes to village infrastructure

### Behavior

- **Daytime**: Actively searches for metal ores and damaged tools
- **Night**: Returns home to sleep (if home is set)
- **Chest Interaction**: Stores metals and takes damaged tools from chests
- **Search Range**: 15 blocks in each direction (x, z), 5 blocks vertical (y)

### Requirements

- Works best with access to a furnace
- No special tools required, but benefits from having storage space

### Job Change Recipe

Given through the job change interface in the villager's inventory.

### Compatible Materials

#### Minetest Game
- `default:stone_with_iron`
- `default:stone_with_copper`
- `default:stone_with_gold`
- `default:steel_ingot`
- `default:copper_ingot`
- `default:gold_ingot`

#### VoxeLibre
Automatically mapped to VoxeLibre equivalents through the compatibility layer.

---

## Miner Job

### Overview
The miner is a specialized villager that excavates stone and ores from the ground. They help gather building materials and valuable minerals while exploring underground areas.

### Capabilities

1. **Stone Mining**
   - Mines any stone-type blocks
   - Identifies mineable blocks by their groups (stone, cracky)
   - Avoids mining decorative blocks (bricks, carved stone)

2. **Ore Collection**
   - Automatically collects valuable ores
   - Picks up dropped items from mining
   - Stores resources in inventory

3. **Underground Lighting**
   - Places torches in dark areas while working
   - Checks light levels periodically
   - Places torches on walls when light level is below 8
   - Helps illuminate mining areas

4. **Blueprint System Integration**
   - Gains 1 experience point per block mined
   - Contributes to overall construction skills
   - Can learn infrastructure blueprints

### Behavior

- **Daytime**: Actively mines stone and ores
- **Night**: Returns home to sleep (if home is set)
- **Chest Interaction**: Stores mined materials, retrieves pickaxes and torches
- **Search Range**: 10 blocks in each direction
- **Tool Management**: Automatically requests pickaxes when needed

### Requirements

**Essential:**
- Pickaxe (any tier)

**Optional but Recommended:**
- Torches (for lighting dark areas)
- Storage chest nearby (to deposit mined materials)

### Pickaxe Management

The miner will:
1. Check if they have a pickaxe before mining
2. Request a pickaxe if they don't have one
3. Accept any tier of pickaxe (wood, stone, iron, diamond)
4. Keep the pickaxe and not store it in chests

### Torch Management

The miner will:
1. Take torches from chests if they have fewer than 10
2. Place torches when light level is below 8
3. Prefer placing torches on walls rather than the ground

### Mining Strategy

The miner:
- Searches for mineable blocks in a 10-block radius
- Avoids protected areas
- Remembers failed mining attempts to avoid repeating them
- Collects dropped items automatically
- Works both at surface level and underground

### Job Change Recipe

Given through the job change interface in the villager's inventory.

### Compatible Blocks

The miner can mine blocks with the following groups:
- `stone` group (any value > 0)
- `cracky` group (any value > 0)

**Excluded:**
- Blocks with "brick" in the name
- Blocks with "carved" in the name
- Protected areas

---

## Job Enhancements

### All Jobs Now Support:

1. **Experience System**
   - Jobs can award experience to villagers
   - Experience enables learning new blueprints
   - Creates skill progression over time

2. **VoxeLibre Compatibility**
   - All new jobs fully support VoxeLibre
   - Item names automatically mapped
   - Works seamlessly in both minetest_game and VoxeLibre

### Enhanced Builder Job

The builder job now:
- Awards 5 experience points when completing a building
- Displays completion message
- Integrates with blueprint system for future improvements

---

## Future Enhancements

### Planned Features

1. **Blacksmith**
   - Actual smelting interaction with furnaces
   - Crafting metal tools and items
   - Creating decorative metal objects
   - Trading repaired tools with players

2. **Miner**
   - Strategic mining patterns (tunnels, shafts)
   - Resource detection and prioritization
   - Support structure placement (pillars, supports)
   - Cave exploration and mapping

3. **General Job System**
   - Job specialization levels
   - Master craftsmen with unique abilities
   - Job training between villagers
   - Collaborative work on large projects

---

## Configuration

### Job-Specific Settings

Currently, the jobs use hardcoded settings. Future versions may include:
- Configurable search ranges
- Adjustable experience rates
- Customizable work hours
- Tool durability thresholds

---

## Troubleshooting

### Blacksmith Issues

**Blacksmith not repairing tools:**
- Ensure tools are actually damaged (>20% wear)
- Check that blacksmith has inventory space
- Verify tools are in the villager's inventory

**Blacksmith not collecting ores:**
- Confirm ores are within search range (15 blocks)
- Check that areas are not protected
- Ensure blacksmith has inventory space

### Miner Issues

**Miner not mining:**
- Verify the miner has a pickaxe
- Check that there are mineable blocks nearby
- Ensure the area is not protected
- Confirm blocks are not in the failed position list

**Miner not placing torches:**
- Check that miner has torches in inventory
- Verify light level is below 8
- Ensure there are walls nearby for torch placement

---

## Integration Examples

### Setting Up a Mining Operation

1. Give a villager the miner job
2. Provide a pickaxe (any tier)
3. Give some torches (optional, but recommended)
4. Place a chest nearby for storing mined resources
5. Set a home for the miner to return to at night

### Setting Up a Blacksmith Workshop

1. Give a villager the blacksmith job
2. Build or place a furnace nearby
3. Place a chest for storing metals and damaged tools
4. Optionally, build a workshop structure
5. Supply initial metal ores or ingots

### Combining Jobs for Village Development

1. **Miner** gathers stone and ores
2. **Blacksmith** processes ores and repairs tools
3. **Builder** uses materials to construct buildings
4. **Farmer** provides food for all villagers
5. **Woodcutter** supplies wood for construction

---

## Performance Considerations

### Miner Performance
- Miners automatically clean up dropped items to prevent lag
- Failed position tracking prevents repeated unsuccessful attempts
- Reasonable search ranges prevent excessive world scanning

### Blacksmith Performance
- Repairs are processed one at a time
- Forge detection uses simple radius search
- Item checking is optimized with early exits

---

## Compatibility

Both new jobs are fully compatible with:
- **minetest_game**: Uses standard default mod items
- **VoxeLibre**: Automatically maps to mcl_* mods
- **Protected areas**: Respects area protection mods
- **Existing jobs**: Works alongside all existing jobs

---

## Credits

These jobs extend the working_villages mod with new capabilities while maintaining compatibility with existing systems and following the established code patterns.
