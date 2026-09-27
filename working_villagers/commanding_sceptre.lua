local access = working_villages.access or working_villages.require("access")

local function send_access_denied(user, reason)
	if not user or type(user.get_player_name) ~= "function" then
		return
	end
	local player_name = user:get_player_name()
	if not player_name or player_name == "" then
		return
	end
	local message = "Vous ne pouvez pas commander ce villageois."
	if reason == "self_employed_private" then
		message = "Ce villageois autonome n'est pas public et ne peut pas etre commande."
	elseif reason == "commanding_sceptre_required" then
		message = "Un sceptre de commande est necessaire pour gerer ce villageois autonome."
	elseif reason == "not_owner" then
		message = "Vous n'etes pas le proprietaire de ce villageois."
	end
	minetest.chat_send_player(player_name, message)
end

minetest.register_tool("working_villages:commanding_sceptre", {
	description = "sceptre de commande",
	inventory_image = "working_villages_commanding_sceptre.png",
	on_use = function(itemstack, user, pointed_thing)
		if pointed_thing and pointed_thing.type == "object" and pointed_thing.ref then
			local obj = pointed_thing.ref
			local luaentity = obj:get_luaentity()
			if not luaentity or not working_villages.is_villager(luaentity.name) then
				if luaentity and luaentity.name == "__builtin:item" and type(luaentity.on_punch) == "function" then
					luaentity:on_punch(user)
				end
				return itemstack
			end

			local allowed, reason = access.can_manage_villager(luaentity, user)
			if not allowed then
				send_access_denied(user, reason)
				return itemstack
			end

			local job = type(luaentity.get_job) == "function" and luaentity:get_job() or nil
			if not job then
				return itemstack
			end
			if luaentity.pause then
				luaentity:set_pause(false)
				luaentity.pause_auto = nil
				luaentity.job_data = luaentity.job_data or {}
				luaentity.job_data.pause_reason = nil
				if type(job.on_resume)=="function" then
					job.on_resume(luaentity)
				end
				luaentity:set_displayed_action("actif")
				luaentity:set_state_info("Je reprends mon travail.")
			else
				luaentity:set_pause(true)
				luaentity.pause_auto = false
				luaentity.job_data = luaentity.job_data or {}
				luaentity.job_data.pause_reason = "manual"
				luaentity:set_displayed_action("attend")
				luaentity:set_state_info("On m'a demande d'attendre ici.")
				if type(job.on_pause)=="function" then
					job.on_pause(luaentity)
				end
			end

			return itemstack
		end
		return itemstack
	end
})

minetest.register_craft({
	output = "working_villages:commanding_sceptre",
	recipe = {
		{working_villages.voxelibre_compat.get_item("default:gold_ingot")},
		{working_villages.voxelibre_compat.get_item("default:paper")},
		{working_villages.voxelibre_compat.get_item("default:stick")},
	},
})
