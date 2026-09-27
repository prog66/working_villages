-- Persistent HUD for villager learning + needs

local hud = {}

local pixel = "blank.png"
local function color_icon(hex)
	return pixel .. "^[colorize:" .. hex .. ":255^[resize:12x12"
end

local function bar_bg(width, height)
	return pixel .. "^[colorize:#10161f:220^[resize:" .. width .. "x" .. height
end

local function bar_fg(width, height)
	return pixel .. "^[colorize:#7ec7ff:255^[resize:" .. width .. "x" .. height
end

local NEEDS = {
	{ key = "hunger", label = "Faim", icon = color_icon("#ffb347") },
	{ key = "energy", label = "Energie", icon = color_icon("#9be870") },
	{ key = "tools", label = "Outils", icon = color_icon("#9bb8ff") },
	{ key = "materials", label = "Materiaux", icon = color_icon("#d0d0d0") },
}

local HUD_STATE = {}

local function find_target_villager(player)
	local name = player:get_player_name()
	local pos = player:get_pos()
	local objs = minetest.get_objects_inside_radius(pos, 12)
	local best, best_dist
	for _, obj in ipairs(objs) do
		local lua = obj:get_luaentity()
		if lua and working_villages.is_villager(lua.name) and lua.owner_name == name then
			local dist = vector.distance(pos, obj:get_pos())
			if not best_dist or dist < best_dist then
				best_dist = dist
				best = lua
			end
		end
	end
	return best
end

local function add_player_hud(player)
	local name = player:get_player_name()
	if HUD_STATE[name] then
		return
	end
	local ids = {}
	local base_x = 0.02
	local base_y = 0.25
	local bar_width = 90
	local bar_height = 6
	local gap = 0.03

	ids.title = player:hud_add({
		type = "text",
		position = {x = base_x, y = base_y - 0.05},
		offset = {x = 0, y = 0},
		text = "Apprentissages",
		alignment = {x = 0, y = 0},
		number = 0xFFFFFF,
	})

	ids.learn_icon = player:hud_add({
		type = "image",
		position = {x = base_x, y = base_y - 0.02},
		offset = {x = 0, y = 0},
		text = "working_villages_question.png^[resize:12x12",
		alignment = {x = 0, y = 0},
	})

	ids.learn_text = player:hud_add({
		type = "text",
		position = {x = base_x, y = base_y - 0.02},
		offset = {x = 16, y = 0},
		text = "-",
		alignment = {x = 0, y = 0},
		number = 0xFFFFFF,
	})

	ids.needs = {}
	for i, need in ipairs(NEEDS) do
		local y = base_y + (i - 1) * gap
		ids.needs[need.key] = {
			icon = player:hud_add({
				type = "image",
				position = {x = base_x, y = y},
				offset = {x = 0, y = 0},
				text = need.icon,
				alignment = {x = 0, y = 0},
			}),
			bg = player:hud_add({
				type = "image",
				position = {x = base_x, y = y},
				offset = {x = 18, y = 0},
				text = bar_bg(bar_width, bar_height),
				alignment = {x = 0, y = 0},
			}),
			fg = player:hud_add({
				type = "image",
				position = {x = base_x, y = y},
				offset = {x = 18, y = 0},
				text = bar_fg(bar_width, bar_height),
				alignment = {x = 0, y = 0},
			}),
			label = player:hud_add({
				type = "text",
				position = {x = base_x, y = y},
				offset = {x = 18 + bar_width + 6, y = -2},
				text = need.label .. ": 100",
				alignment = {x = 0, y = 0},
				number = 0xFFFFFF,
			}),
		}
	end

	HUD_STATE[name] = ids
end

local function remove_player_hud(player)
	local name = player:get_player_name()
	local ids = HUD_STATE[name]
	if not ids then
		return
	end
	for _, id in pairs(ids) do
		if type(id) == "table" then
			for _, sub in pairs(id) do
				if type(sub) == "table" then
					for _, subid in pairs(sub) do
						player:hud_remove(subid)
					end
				else
					player:hud_remove(sub)
				end
			end
		else
			player:hud_remove(id)
		end
	end
	HUD_STATE[name] = nil
end

local function update_player_hud(player)
	local name = player:get_player_name()
	local ids = HUD_STATE[name]
	if not ids then
		return
	end
	local villager = find_target_villager(player)
	if not villager then
		player:hud_change(ids.learn_text, "text", "Aucun villageois proche")
		return
	end

	local note = villager.job_data and villager.job_data.learning_note or "Aucun apprentissage recent"
	if villager.job_data and villager.job_data.plan_proposal then
		note = "Proposition .we en attente"
	end
	local pending = 0
	if villager.job_data and villager.job_data.permission_requests then
		for _, req in pairs(villager.job_data.permission_requests) do
			if req.status == "pending" then
				pending = pending + 1
			end
		end
	end
	if pending > 0 then
		note = note .. " | Autorisations: " .. tostring(pending)
	end
	local inbox = villager.job_data and villager.job_data.inbox
	if inbox and #inbox > 0 then
		note = note .. " | Messages: " .. tostring(#inbox)
	end
	player:hud_change(ids.learn_text, "text", note)

	for _, need in ipairs(NEEDS) do
		local current = working_villages.needs.get(villager, need.key) or 0
		local width = math.max(1, math.floor(90 * (current / 100)))
		local elem = ids.needs[need.key]
		player:hud_change(elem.fg, "text", bar_fg(width, 6))
		player:hud_change(elem.label, "text", need.label .. ": " .. tostring(math.floor(current)))
	end
end

local timer = 0
minetest.register_globalstep(function(dtime)
	timer = timer + dtime
	if timer < 1 then
		return
	end
	timer = 0
	for _, player in ipairs(minetest.get_connected_players()) do
		add_player_hud(player)
		update_player_hud(player)
	end
end)

minetest.register_on_joinplayer(add_player_hud)
minetest.register_on_leaveplayer(remove_player_hud)

return hud
