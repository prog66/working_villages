-- mcl_skins mod
-- Advanced skin customization for VoxeLibre and Minetest
-- Author: MrRar
-- License: MIT

mcl_skins = {}

-- Storage paths
local storage = minetest.get_mod_storage()
local modpath = minetest.get_modpath("mcl_skins")

-- Color tables
mcl_skins.base_color = {
	"#fce0d0", -- Light skin
	"#f3d3b5", -- Medium-light skin
	"#d4a574", -- Medium skin
	"#a57644", -- Medium-dark skin
	"#754c24", -- Dark skin
	"#3d2817", -- Very dark skin
}

mcl_skins.color = {
	"#ffffff", -- White
	"#f3d3b5", -- Beige
	"#d4a574", -- Tan
	"#ff0000", -- Red
	"#ff8800", -- Orange
	"#ffff00", -- Yellow
	"#88ff00", -- Lime
	"#00ff00", -- Green
	"#00ff88", -- Cyan-green
	"#00ffff", -- Cyan
	"#0088ff", -- Sky blue
	"#0000ff", -- Blue
	"#8800ff", -- Purple
	"#ff00ff", -- Magenta
	"#ff0088", -- Pink
	"#000000", -- Black
	"#555555", -- Dark gray
	"#888888", -- Gray
	"#bbbbbb", -- Light gray
	"#754c24", -- Brown
}

-- Skin item storage
local skin_items = {
	base = {},
	footwear = {},
	eye = {},
	mouth = {},
	bottom = {},
	top = {},
	hair = {},
	headwear = {},
}

-- Default ranks for skin item types
local default_ranks = {
	base = 10,
	footwear = 20,
	eye = 30,
	mouth = 40,
	bottom = 50,
	top = 60,
	hair = 70,
	headwear = 80,
}

-- Player skin data storage
mcl_skins.player_skins = {}

-- Simple skin storage
local simple_skins = {}

-- Get skin items by type
local function get_skin_items(item_type)
	return skin_items[item_type] or {}
end

-- Register a skin item
function mcl_skins.register_item(item)
	if not item.type then
		minetest.log("error", "[mcl_skins] Skin item registered without type")
		return
	end
	
	if not skin_items[item.type] then
		minetest.log("error", "[mcl_skins] Invalid skin item type: " .. item.type)
		return
	end
	
	-- Set defaults
	item.texture = item.texture or "blank.png"
	item.rank = item.rank or default_ranks[item.type]
	item.preview_rotation = item.preview_rotation or {x = 0, y = 0}
	
	-- Add to storage
	table.insert(skin_items[item.type], item)
end

-- Compile skin items into a texture string
function mcl_skins.compile_skin(skin)
	local parts = {}
	local types_in_order = {"base", "footwear", "eye", "mouth", "bottom", "top", "hair", "headwear"}
	
	for _, item_type in ipairs(types_in_order) do
		if skin[item_type] then
			local item_data = skin[item_type]
			if item_data.texture then
				-- Apply color if available and item supports it
				if item_data.color and item_data.mask then
					table.insert(parts, "(" .. item_data.texture .. "^[mask:" .. item_data.mask .. "^[colorize:" .. item_data.color .. ":255)")
				else
					table.insert(parts, item_data.texture)
				end
			end
		end
	end
	
	if #parts == 0 then
		return "blank.png"
	end
	
	return table.concat(parts, "^")
end

-- Update player skin visual
function mcl_skins.update_player_skin(player)
	if not player or not player:is_player() then
		return
	end
	
	local player_name = player:get_player_name()
	local skin_data = mcl_skins.player_skins[player_name]
	
	if not skin_data then
		return
	end
	
	local texture = mcl_skins.compile_skin(skin_data)
	
	-- Update player textures
	local props = player:get_properties()
	props.textures = {texture}
	
	-- Use slim arms for female template if specified
	if skin_data.slim_arms then
		props.mesh = "mcl_armor_character_female.b3d"
	else
		props.mesh = "mcl_armor_character.b3d"
	end
	
	player:set_properties(props)
end

-- Save player skin data
function mcl_skins.save(player)
	if not player or not player:is_player() then
		return
	end
	
	local player_name = player:get_player_name()
	local skin_data = mcl_skins.player_skins[player_name]
	
	if skin_data then
		storage:set_string(player_name, minetest.serialize(skin_data))
	end
end

-- Load player skin data
local function load_skin(player)
	if not player or not player:is_player() then
		return
	end
	
	local player_name = player:get_player_name()
	local data = storage:get_string(player_name)
	
	if data and data ~= "" then
		mcl_skins.player_skins[player_name] = minetest.deserialize(data)
	else
		-- Set default skin
		mcl_skins.player_skins[player_name] = {
			base = {texture = "blank.png", color = mcl_skins.base_color[1]},
			slim_arms = false,
		}
	end
	
	mcl_skins.update_player_skin(player)
end

-- Get skin list for node registration
function mcl_skins.get_skin_list()
	local list = {}
	
	-- Add simple skins
	for i, skin in ipairs(simple_skins) do
		table.insert(list, {
			id = "mcl_skins_skin_" .. i,
			texture = skin.texture,
			slim_arms = skin.slim_arms or false,
		})
	end
	
	return list
end

-- Get node ID for player's skin
function mcl_skins.get_node_id_by_player(player)
	if not player or not player:is_player() then
		return "mcl_skins_skin_1"
	end
	
	local player_name = player:get_player_name()
	local skin_data = mcl_skins.player_skins[player_name]
	
	if not skin_data then
		return "mcl_skins_skin_1"
	end
	
	-- For now, return a generic node ID
	-- This could be extended to match against registered simple skins
	return "mcl_skins_skin_1"
end

-- Register a simple skin
function mcl_skins.register_simple_skin(skin)
	if not skin.texture then
		minetest.log("error", "[mcl_skins] Simple skin registered without texture")
		return
	end
	
	table.insert(simple_skins, {
		texture = skin.texture,
		slim_arms = skin.slim_arms or false,
	})
end

-- Show formspec
function mcl_skins.show_formspec(player, active_tab, page_num)
	if not player or not player:is_player() then
		return
	end
	
	active_tab = active_tab or "base"
	page_num = page_num or 1
	
	local player_name = player:get_player_name()
	local skin_data = mcl_skins.player_skins[player_name] or {}
	
	local formspec = {
		"formspec_version[4]",
		"size[12,10]",
		"label[0.5,0.5;Skin Customization]",
		"button[0.5,1;2,0.8;tab_base;Base]",
		"button[2.5,1;2,0.8;tab_eye;Eyes]",
		"button[4.5,1;2,0.8;tab_mouth;Mouth]",
		"button[6.5,1;2,0.8;tab_hair;Hair]",
		"button[8.5,1;2,0.8;tab_top;Top]",
		"button[0.5,2;2,0.8;tab_bottom;Bottom]",
		"button[2.5,2;2,0.8;tab_footwear;Footwear]",
		"button[4.5,2;2,0.8;tab_headwear;Headwear]",
	}
	
	-- Get items for active tab
	local items = get_skin_items(active_tab)
	local items_per_page = 20
	local total_pages = math.max(1, math.ceil(#items / items_per_page))
	page_num = math.max(1, math.min(page_num, total_pages))
	
	local start_idx = (page_num - 1) * items_per_page + 1
	local end_idx = math.min(start_idx + items_per_page - 1, #items)
	
	-- Display items
	local y = 3
	local x = 0.5
	for i = start_idx, end_idx do
		local item = items[i]
		if item then
			local btn_name = "item_" .. active_tab .. "_" .. i
			table.insert(formspec, string.format("button[%f,%f;2,0.8;%s;Item %d]", x, y, btn_name, i))
			
			x = x + 2.5
			if x > 10 then
				x = 0.5
				y = y + 1
			end
		end
	end
	
	-- Pagination
	if total_pages > 1 then
		table.insert(formspec, string.format("label[0.5,9;Page %d of %d]", page_num, total_pages))
		if page_num > 1 then
			table.insert(formspec, "button[3,8.5;2,0.8;prev_page;Previous]")
		end
		if page_num < total_pages then
			table.insert(formspec, "button[6,8.5;2,0.8;next_page;Next]")
		end
	end
	
	table.insert(formspec, "button[9,8.5;2,0.8;close;Close]")
	
	minetest.show_formspec(player_name, "mcl_skins:customization", table.concat(formspec, ""))
end

-- Handle formspec submission
minetest.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= "mcl_skins:customization" then
		return
	end
	
	local player_name = player:get_player_name()
	
	-- Handle tab switches
	for tab in pairs(skin_items) do
		if fields["tab_" .. tab] then
			mcl_skins.show_formspec(player, tab, 1)
			return
		end
	end
	
	-- Handle pagination
	if fields.prev_page or fields.next_page then
		-- Would need to track current page and tab
		return
	end
	
	-- Handle item selection
	for field_name in pairs(fields) do
		if field_name:sub(1, 5) == "item_" then
			local parts = {}
			for part in field_name:gmatch("[^_]+") do
				table.insert(parts, part)
			end
			
			if #parts >= 3 then
				local item_type = parts[2]
				local item_idx = tonumber(parts[3])
				
				if item_idx and skin_items[item_type] then
					local item = skin_items[item_type][item_idx]
					if item then
						if not mcl_skins.player_skins[player_name] then
							mcl_skins.player_skins[player_name] = {}
						end
						mcl_skins.player_skins[player_name][item_type] = {
							texture = item.texture,
							mask = item.mask,
							color = item.color,
						}
						mcl_skins.update_player_skin(player)
						mcl_skins.save(player)
					end
				end
			end
			return
		end
	end
	
	if fields.close or fields.quit then
		minetest.close_formspec(player_name, "mcl_skins:customization")
	end
end)

-- Chat command
minetest.register_chatcommand("skin", {
	description = "Open skin customization",
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if player then
			mcl_skins.show_formspec(player)
			return true, "Opening skin customization..."
		end
		return false, "Player not found"
	end,
})

-- Player join/leave handlers
minetest.register_on_joinplayer(function(player)
	load_skin(player)
end)

minetest.register_on_leaveplayer(function(player)
	if player and player:is_player() then
		mcl_skins.save(player)
		local player_name = player:get_player_name()
		mcl_skins.player_skins[player_name] = nil
	end
end)

-- Register some default skin items
-- Base skins
mcl_skins.register_item({
	type = "base",
	texture = "mcl_skins_base_1.png",
	template1 = true,
	mask = "mcl_skins_base_mask.png",
})

mcl_skins.register_item({
	type = "base",
	texture = "mcl_skins_base_2.png",
	template2 = true,
	mask = "mcl_skins_base_mask.png",
})

-- Eyes
mcl_skins.register_item({
	type = "eye",
	texture = "mcl_skins_eye_1.png",
	template1 = true,
	template2 = true,
})

mcl_skins.register_item({
	type = "eye",
	texture = "mcl_skins_eye_2.png",
})

-- Mouth
mcl_skins.register_item({
	type = "mouth",
	texture = "mcl_skins_mouth_1.png",
	template1 = true,
	template2 = true,
})

mcl_skins.register_item({
	type = "mouth",
	texture = "mcl_skins_mouth_2.png",
})

-- Hair
mcl_skins.register_item({
	type = "hair",
	texture = "mcl_skins_hair_1.png",
	mask = "mcl_skins_hair_mask.png",
})

mcl_skins.register_item({
	type = "hair",
	texture = "mcl_skins_hair_2.png",
	mask = "mcl_skins_hair_mask.png",
})

-- Clothing - Top
mcl_skins.register_item({
	type = "top",
	texture = "mcl_skins_top_1.png",
	mask = "mcl_skins_top_mask.png",
})

mcl_skins.register_item({
	type = "top",
	texture = "mcl_skins_top_2.png",
	mask = "mcl_skins_top_mask.png",
})

-- Clothing - Bottom
mcl_skins.register_item({
	type = "bottom",
	texture = "mcl_skins_bottom_1.png",
	mask = "mcl_skins_bottom_mask.png",
})

mcl_skins.register_item({
	type = "bottom",
	texture = "mcl_skins_bottom_2.png",
	mask = "mcl_skins_bottom_mask.png",
})

-- Footwear
mcl_skins.register_item({
	type = "footwear",
	texture = "mcl_skins_footwear_1.png",
})

mcl_skins.register_item({
	type = "footwear",
	texture = "mcl_skins_footwear_2.png",
})

-- Headwear
mcl_skins.register_item({
	type = "headwear",
	texture = "mcl_skins_headwear_1.png",
})

mcl_skins.register_item({
	type = "headwear",
	texture = "mcl_skins_headwear_2.png",
})

minetest.log("action", "[mcl_skins] Mod loaded successfully")
