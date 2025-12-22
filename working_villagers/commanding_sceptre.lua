minetest.register_tool("working_villages:commanding_sceptre", {
	description = "sceptre de commande",
	inventory_image = "working_villages_commanding_sceptre.png",
	on_use = function(itemstack, user, pointed_thing)
		if (pointed_thing.type == "object") then
			local obj = pointed_thing.ref
			local luaentity = obj:get_luaentity()
			if not working_villages.is_villager(luaentity.name) then
				if luaentity.name == "__builtin:item" then
					luaentity:on_punch(user)
				end
				return
			end

			local job = luaentity:get_job()
			if job ~= nil then
				if luaentity.pause then
					luaentity:set_pause(false)
					luaentity.pause_auto = nil
					if type(job.on_resume)=="function" then
						job.on_resume(luaentity)
					end
					luaentity:set_displayed_action("actif")
					luaentity:set_state_info("Je reprends mon travail.")
				else
					luaentity:set_pause(true)
					luaentity.pause_auto = false
					luaentity:set_displayed_action("attend")
					luaentity:set_state_info("On m'a demande d'attendre ici.")
					if type(job.on_pause)=="function" then
						job.on_pause(luaentity)
					end
				end
			end

			return itemstack
		end
	end
})
