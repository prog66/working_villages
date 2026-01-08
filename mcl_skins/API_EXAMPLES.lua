-- Example: Creating a custom skins mod that depends on mcl_skins
-- Save this as your_mod/init.lua

-- Example 1: Register custom skin items
mcl_skins.register_item({
    type = "hair",
    texture = "my_custom_hair.png",
    mask = "my_custom_hair_mask.png",
    preview_rotation = {x = 0, y = 180},
})

mcl_skins.register_item({
    type = "top",
    texture = "my_custom_shirt.png",
    mask = "my_custom_shirt_mask.png",
})

mcl_skins.register_item({
    type = "headwear",
    texture = "my_custom_hat.png",
    rank = 85,  -- Higher rank to appear above hair
})

-- Example 2: Register a complete simple skin
mcl_skins.register_simple_skin({
    texture = "character_steve.png",
    slim_arms = false,
})

mcl_skins.register_simple_skin({
    texture = "character_alex.png",
    slim_arms = true,
})

-- Example 3: Programmatically set a player's skin
minetest.register_chatcommand("setskin", {
    params = "<player_name>",
    description = "Set a custom skin for a player",
    privs = {server = true},
    func = function(name, param)
        local player = minetest.get_player_by_name(param)
        if not player then
            return false, "Player not found"
        end
        
        -- Create custom skin data
        mcl_skins.player_skins[param] = {
            base = {
                texture = "mcl_skins_base_1.png",
                color = mcl_skins.base_color[1],
                mask = "mcl_skins_base_mask.png",
            },
            eye = {
                texture = "mcl_skins_eye_1.png",
            },
            mouth = {
                texture = "mcl_skins_mouth_1.png",
            },
            hair = {
                texture = "mcl_skins_hair_1.png",
                color = "#654321",  -- Brown hair
                mask = "mcl_skins_hair_mask.png",
            },
            top = {
                texture = "mcl_skins_top_1.png",
                color = "#0000ff",  -- Blue shirt
                mask = "mcl_skins_top_mask.png",
            },
            bottom = {
                texture = "mcl_skins_bottom_1.png",
                color = "#000000",  -- Black pants
                mask = "mcl_skins_bottom_mask.png",
            },
            slim_arms = false,
        }
        
        -- Update the player's appearance
        mcl_skins.update_player_skin(player)
        mcl_skins.save(player)
        
        return true, "Skin set for " .. param
    end,
})

-- Example 4: Get all registered skins for custom node registration
local skins = mcl_skins.get_skin_list()
for _, skin in ipairs(skins) do
    -- Register a node for each skin
    minetest.register_node("mymod:" .. skin.id, {
        description = "Player Statue (" .. skin.id .. ")",
        tiles = {skin.texture},
        groups = {oddly_breakable_by_hand = 3},
    })
end

-- Example 5: Compile a custom skin combination
local custom_skin = {
    base = {texture = "base.png", color = "#fce0d0"},
    eye = {texture = "eye.png"},
    mouth = {texture = "mouth.png"},
    hair = {texture = "hair.png", color = "#654321", mask = "hair_mask.png"},
}

local texture_string = mcl_skins.compile_skin(custom_skin)
print("Compiled texture: " .. texture_string)

-- Example 6: Open skin customization for a player from code
minetest.register_chatcommand("openskins", {
    params = "",
    description = "Open skin customization",
    func = function(name)
        local player = minetest.get_player_by_name(name)
        if player then
            -- Open to the hair tab, page 1
            mcl_skins.show_formspec(player, "hair", 1)
            return true, "Opening skin customization..."
        end
        return false, "Player not found"
    end,
})

-- Example 7: Access color tables
print("Available base colors:")
for i, color in ipairs(mcl_skins.base_color) do
    print(i .. ": " .. color)
end

print("Available general colors:")
for i, color in ipairs(mcl_skins.color) do
    print(i .. ": " .. color)
end

-- Example 8: Register items with different ranks
-- Lower rank items appear first (bottom layer)
mcl_skins.register_item({
    type = "base",
    texture = "underwear.png",
    rank = 5,  -- Lower than default base rank (10)
})

-- Higher rank items appear on top
mcl_skins.register_item({
    type = "top",
    texture = "jacket.png",
    rank = 65,  -- Higher than default top rank (60)
})
