# Blueprint System Documentation

## Overview

The blueprint system allows villagers to learn construction plans, build from those plans, and progressively improve their construction skills. This system adds depth to the building mechanics and enables villagers to become more capable over time.

## Architecture

### Core Components

1. **Blueprint Registry** (`blueprints.lua`)
   - Central system for managing all blueprints
   - Stores blueprint definitions and learned blueprints
   - Handles experience tracking and skill progression

2. **Default Blueprints** (`blueprints_default.lua`)
   - Pre-registered blueprints for common structures
   - Houses, workshops, farms, and infrastructure

3. **Job Integration**
   - Builder job enhanced with experience gain
   - New jobs (Blacksmith, Miner) use the experience system

## Blueprint Structure

A blueprint consists of:
- **Category**: Type of structure (house, farm, workshop, decoration, infrastructure)
- **Difficulty**: Skill level required (1-5)
- **Description**: What the blueprint represents
- **Nodes**: List of blocks that make up the structure
- **Schematic File**: Optional reference to a WorldEdit schematic
- **Improvements**: Progressive enhancements that can be applied

## How It Works

### Learning Blueprints

1. Villagers gain **experience points** by completing construction tasks
2. When they have enough experience, they can learn new blueprints
3. Each blueprint has a difficulty level that determines experience requirements:
   - Beginner (1): 10 experience points
   - Intermediate (2): 20 experience points
   - Advanced (3): 30 experience points
   - Expert (4): 40 experience points
   - Master (5): 50 experience points

### Improving Blueprints

Once learned, blueprints can be improved to higher levels:
- Each improvement level requires: `current_level × difficulty × 20` experience
- Improvements add features like:
  - Better materials (wood → stone)
  - Additional decorations (windows, lighting)
  - Functional enhancements (storage, workbenches)
  - Expanded structures (additional rooms, floors)

### Experience Gain

Villagers gain experience through:
- **Completing buildings**: 5 experience per building (Builder)
- **Repairing tools**: 1 experience per repair (Blacksmith)
- **Mining resources**: 1 experience per block mined (Miner)
- **Harvesting crops**: Small amounts (Farmer)

## API Reference

### Registering a Blueprint

```lua
working_villages.blueprints.register(name, definition)
```

**Parameters:**
- `name`: Unique identifier for the blueprint
- `definition`: Table containing:
  - `category`: One of CATEGORY constants
  - `difficulty`: One of DIFFICULTY constants
  - `description`: Human-readable description
  - `nodes`: (Optional) List of node data
  - `schematic_file`: (Optional) WorldEdit schematic filename
  - `improvements`: (Optional) List of improvement definitions

**Example:**
```lua
working_villages.blueprints.register("custom_house", {
    category = working_villages.blueprints.CATEGORY.HOUSE,
    difficulty = working_villages.blueprints.DIFFICULTY.INTERMEDIATE,
    description = "A custom designed house",
    schematic_file = "custom_house.we",
    improvements = {
        {
            type = "replace_nodes",
            description = "Upgrade walls to stone",
            from = "default:wood",
            to = "default:stone",
        },
    },
})
```

### Teaching a Blueprint to a Villager

```lua
local success, message = working_villages.blueprints.teach(inv_name, blueprint_name)
```

**Parameters:**
- `inv_name`: Villager's inventory name
- `blueprint_name`: Name of the blueprint to teach

**Returns:**
- `success`: Boolean indicating if teaching succeeded
- `message`: Description of the result

### Improving a Blueprint

```lua
local success, message = working_villages.blueprints.improve(inv_name, blueprint_name)
```

**Parameters:**
- `inv_name`: Villager's inventory name
- `blueprint_name`: Name of the blueprint to improve

**Returns:**
- `success`: Boolean indicating if improvement succeeded
- `message`: Description of the result

### Adding Experience

```lua
working_villages.blueprints.add_experience(inv_name, amount)
```

**Parameters:**
- `inv_name`: Villager's inventory name
- `amount`: Amount of experience to add

### Checking Learning Status

```lua
-- Check if learned
local has_learned = working_villages.blueprints.has_learned(inv_name, blueprint_name)

-- Get current level
local level = working_villages.blueprints.get_level(inv_name, blueprint_name)

-- Get blueprints available to learn
local available = working_villages.blueprints.get_available_to_learn(inv_name)

-- Get blueprints available to improve
local improvements = working_villages.blueprints.get_available_to_improve(inv_name)
```

## Improvement Types

### 1. Replace Nodes
Replaces specific blocks with better materials:
```lua
{
    type = "replace_nodes",
    description = "Upgrade to stone",
    from = "default:wood",
    to = "default:stone",
}
```

### 2. Add Nodes
Adds new blocks to the structure:
```lua
{
    type = "add_nodes",
    description = "Add windows",
    nodes = {
        {pos = {x=1, y=2, z=0}, node = {name="default:glass"}},
        -- ... more nodes
    },
}
```

### 3. Add Decoration
Adds decorative elements:
```lua
{
    type = "add_decoration",
    description = "Add lighting",
    nodes = {
        {pos = {x=2, y=3, z=2}, node = {name="default:torch"}},
        -- ... more nodes
    },
}
```

## Default Blueprints

The system comes with 8 default blueprints:

### Houses
- **simple_house**: Basic wooden shelter (Beginner)
- **fancy_house**: Multi-room dwelling (Intermediate)

### Farms
- **farm_plot**: Small farming area (Beginner)

### Workshops
- **workshop**: General purpose workspace (Intermediate)
- **blacksmith_forge**: Specialized smithing area (Advanced)

### Infrastructure
- **town_square**: Central gathering area (Advanced)
- **watchtower**: Defensive structure (Intermediate)

### Decoration
- **garden**: Decorative landscaping (Beginner)

## Storage Format

Blueprint learning data is saved to `<world_path>/working_villages_blueprints` in Minetest's serialization format.

### Data Structure
```lua
{
    ["villager_inv_name"] = {
        blueprints = {
            ["blueprint_name"] = level,
            -- ... more blueprints
        },
        experience = number,
        construction_count = number,
    },
    -- ... more villagers
}
```

## Integration with Existing Systems

### Building Markers
The blueprint system works with the existing building marker system. When a builder completes a structure marked by a building marker, they gain experience.

### Job System
Jobs can award experience to villagers through the blueprint system API. This creates a skill progression mechanic across all job types.

### VoxeLibre Compatibility
All blueprints respect the VoxeLibre compatibility layer. Item names are automatically mapped when running on VoxeLibre.

## Future Extensions

The blueprint system is designed to be easily extensible:

1. **Custom Blueprints**: Server owners can add blueprints via mods
2. **Blueprint Trading**: Villagers could trade blueprints with players
3. **Blueprint Books**: Items that teach blueprints when used
4. **Specialization**: Villagers could specialize in certain categories
5. **Quality Levels**: Higher level builders produce better quality structures
6. **Automation**: Advanced builders could autonomously plan and build villages

## Example: Creating a Custom Blueprint Mod

```lua
-- In your mod's init.lua
local blueprints = working_villages.blueprints

-- Register a custom blueprint
blueprints.register("mymod:castle_tower", {
    category = blueprints.CATEGORY.INFRASTRUCTURE,
    difficulty = blueprints.DIFFICULTY.EXPERT,
    description = "A tall defensive tower",
    schematic_file = "castle_tower.we",
    improvements = {
        {
            type = "replace_nodes",
            from = "default:stone",
            to = "default:stonebrick",
        },
        {
            type = "add_decoration",
            description = "Add battlements",
            nodes = {}, -- Define battlement nodes
        },
    },
})
```

## Best Practices

1. **Balance Difficulty**: Ensure blueprints have appropriate difficulty for their complexity
2. **Meaningful Improvements**: Each improvement should add visible value
3. **Resource Requirements**: Consider the materials needed when designing blueprints
4. **VoxeLibre Compatibility**: Always use the compatibility layer for item names
5. **Documentation**: Document custom blueprints for server administrators

## Troubleshooting

### Villagers Not Gaining Experience
- Check that the job's jobfunc calls `blueprints.add_experience()`
- Verify the inventory name is correct

### Blueprints Not Learning
- Ensure villager has enough experience points
- Check blueprint difficulty requirements
- Verify blueprint is registered properly

### Improvements Not Applying
- Check improvement type is valid
- Ensure node names are correct for current game (minetest_game vs VoxeLibre)
- Verify improvement definitions are properly formatted
