-- Persistent per-player HUD: tracked villager (name, job, needs) or a
-- village summary when no owned villager is nearby.
--
-- The bar/panel textures are built by colorizing+resizing a single opaque
-- pixel (working_villages_pixel.png). "blank.png" is NOT usable for this:
-- it is the conventional fully-transparent placeholder texture in both
-- supported games, so colorizing it stays invisible. That mismatch made
-- every bar in this HUD invisible before this file used the mod's own
-- pixel texture.

local hud = {}

local pixel = "working_villages_pixel.png"
local function tint(hex, alpha, width, height)
	return pixel .. "^[colorize:" .. hex .. ":" .. alpha .. "^[resize:" .. width .. "x" .. height
end

local PANEL_COLOR = "#05070a"
local PANEL_ALPHA = 170
local BAR_BG_COLOR = "#10161f"
local BAR_BG_ALPHA = 230
local BAR_W = 90
local BAR_H = 8
local ROW_H = 20
local PANEL_W = 236

local NEEDS = {
	{ key = "hunger", label = "Faim", color = "#ffb347" },
	{ key = "energy", label = "Energie", color = "#9be870" },
	{ key = "tools", label = "Outils", color = "#9bb8ff" },
	{ key = "materials", label = "Materiaux", color = "#d0d0d0" },
}

local PANEL_H = 44 + (#NEEDS * ROW_H) + 10

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

local function village_summary(name)
	local pop = working_villages.population
	if not pop or not pop.snapshot then
		return "Village: donnees indisponibles"
	end
	local total, by_job = 0, {}
	for _, record in pairs(pop.snapshot()) do
		if record.owner_name == name then
			total = total + 1
			local job = (record.job_name or ""):gsub("^.*job_", "")
			if job ~= "" then
				by_job[job] = (by_job[job] or 0) + 1
			end
		end
	end
	if total == 0 then
		return "Aucun villageois. Utilisez le sceptre de commande."
	end
	local parts = {}
	for job, count in pairs(by_job) do
		parts[#parts + 1] = job .. ":" .. count
	end
	table.sort(parts)
	return "Village (" .. total .. "): " .. table.concat(parts, "  ")
end

local function add_player_hud(player)
	local name = player:get_player_name()
	if HUD_STATE[name] then
		return
	end
	local ids = {}
	local pos = { x = 0.02, y = 0.25 }

	ids.panel = player:hud_add({
		type = "image",
		position = pos,
		offset = { x = -10, y = -26 },
		text = tint(PANEL_COLOR, PANEL_ALPHA, PANEL_W, PANEL_H),
		alignment = { x = 1, y = 1 },
	})

	ids.title = player:hud_add({
		type = "text",
		position = pos,
		offset = { x = 0, y = -22 },
		text = "Working Villages",
		alignment = { x = 1, y = 1 },
		number = 0xd8e6ff,
	})

	ids.status_icon = player:hud_add({
		type = "image",
		position = pos,
		offset = { x = 0, y = 0 },
		text = "working_villages_question.png^[resize:12x12",
		alignment = { x = 1, y = 1 },
	})

	ids.status_text = player:hud_add({
		type = "text",
		position = pos,
		offset = { x = 16, y = -2 },
		text = "...",
		alignment = { x = 1, y = 1 },
		number = 0xFFFFFF,
	})

	ids.needs = {}
	for i, need in ipairs(NEEDS) do
		local y = 20 + (i - 1) * ROW_H
		ids.needs[need.key] = {
			icon = player:hud_add({
				type = "image",
				position = pos,
				offset = { x = 0, y = y },
				text = tint(need.color, 255, 12, 12),
				alignment = { x = 0, y = 0 },
			}),
			bg = player:hud_add({
				type = "image",
				position = pos,
				offset = { x = 18, y = y },
				text = tint(BAR_BG_COLOR, BAR_BG_ALPHA, BAR_W, BAR_H),
				alignment = { x = 0, y = 0 },
			}),
			fg = player:hud_add({
				type = "image",
				position = pos,
				offset = { x = 18, y = y },
				text = tint(need.color, 255, BAR_W, BAR_H),
				alignment = { x = 0, y = 0 },
			}),
			label = player:hud_add({
				type = "text",
				position = pos,
				offset = { x = 18 + BAR_W + 6, y = y - 2 },
				text = need.label .. ": 100",
				alignment = { x = 0, y = 0 },
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
		player:hud_change(ids.status_text, "text", village_summary(name))
		for _, need in ipairs(NEEDS) do
			local elem = ids.needs[need.key]
			player:hud_change(elem.fg, "text", tint(need.color, 255, 1, BAR_H))
			player:hud_change(elem.label, "text", need.label .. ": -")
		end
		return
	end

	local job = villager.get_job_name and villager:get_job_name()
	local job_def = job and job ~= "" and working_villages.registered_jobs[job]
	local job_label = job_def and job_def.description or job or "sans metier"
	local who = (villager.nametag and villager.nametag ~= "") and villager.nametag or "Villageois"

	local note = who .. " - " .. job_label
	if villager.job_data and villager.job_data.plan_proposal then
		note = note .. " | Proposition .we en attente"
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
	player:hud_change(ids.status_text, "text", note)

	for _, need in ipairs(NEEDS) do
		local current = working_villages.needs.get(villager, need.key) or 0
		local width = math.max(1, math.floor(BAR_W * (current / 100)))
		local elem = ids.needs[need.key]
		player:hud_change(elem.fg, "text", tint(need.color, 255, width, BAR_H))
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
