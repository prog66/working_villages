local func = working_villages.require("jobs/util")
local fail = working_villages.require("failures")
local log = working_villages.require("log")
local co_command = working_villages.require("job_coroutines").commands
local follower = working_villages.require("jobs/follow_player")
local compat = working_villages.voxelibre_compat
local crafting = working_villages.crafting
local comm = working_villages.communication

local torcher = {}
local torch_items = compat.get_torch_items()
local desired_torch_stock = 6
local torch_request_cooldown = 30

local function is_torch_item(name)
	return name == torch_items.floor or name == torch_items.wall
end

local function count_torches_in_main(v)
	local total = 0
	for _, stack in ipairs(v:get_inventory():get_list("main") or {}) do
		if not stack:is_empty() and is_torch_item(stack:get_name()) then
			total = total + stack:get_count()
		end
	end
	return total
end

local function count_torches(v)
	local total = 0
	local wield = v:get_wield_item_stack()
	if wield and is_torch_item(wield:get_name()) then
		total = total + wield:get_count()
	end
	return total + count_torches_in_main(v)
end

local function request_torches(v, needed)
	v.job_data = v.job_data or {}
	local now = minetest.get_gametime()
	local last = v.job_data.torcher_torch_request_time or 0
	if now - last < torch_request_cooldown then
		return false
	end
	if comm then
		comm.broadcast(v, comm.list_loaded_villagers(), "help_needed", {
			items = {[torch_items.floor] = math.max(1, needed or desired_torch_stock)},
			requester_id = v.inventory_name,
		})
	end
	v.job_data.torcher_torch_request_time = now
	v:set_state_info("Je demande des torches.")
	v:set_displayed_action("cherche des torches")
	return true
end

local function ensure_torches(v, desired_count)
	desired_count = math.max(1, desired_count or desired_torch_stock)
	local current = count_torches(v)
	if current >= desired_count then
		return true
	end
	if v.take_from_shared_storage then
		v:take_from_shared_storage({[torch_items.floor] = desired_count - current})
		current = count_torches(v)
		if current >= desired_count then
			return true
		end
	end
	if crafting then
		for target = count_torches_in_main(v) + 1, desired_count do
			local ok = select(1, crafting.ensure_item(v, torch_items.floor, target, {
				use_shared_storage = true,
				fail_cooldown = 10,
				max_depth = 4,
			}))
			if not ok then
				break
			end
		end
		current = count_torches(v)
		if current >= desired_count then
			return true
		end
	end
	if current > 0 then
		return true
	end
	request_torches(v, desired_count)
	return false
end

local function has_nearby_torch(pos)
	local minp = vector.subtract(pos, {x = 2, y = 2, z = 2})
	local maxp = vector.add(pos, {x = 2, y = 2, z = 2})
	local nodes = minetest.find_nodes_in_area(minp, maxp, {torch_items.floor, torch_items.wall})
	return nodes and #nodes > 0
end

local function can_place_torch_at(v, pos)
	pos = vector.round(pos)
	if v.is_position_reserved and v:is_position_reserved("torch_spot", pos) then
		return false
	end
	if has_nearby_torch(pos) then
		return false
	end
	if not torcher.is_dark(pos) then
		return false
	end
	if v and func and func.is_protected and func.is_protected(v, pos) then
		return false
	end
	if v and working_villages.failed_pos_test(pos) then
		return false
	end
	local node = minetest.get_node_or_nil(pos)
	if not node then
		return false
	end
	local def = minetest.registered_nodes[node.name]
	if not def then
		return false
	end
	if def.walkable and not def.buildable_to then
		return false
	end
	local support = minetest.get_node(vector.add(pos,{x=0,y=-1,z=0}))
	if not torcher.is_walkable(support.name) then
		return false
	end
	return true
end

function torcher.is_dark(pos)
	local light_level = minetest.get_node_light(pos)
	return light_level <= 5
end

function torcher.is_walkable(nodename)
  if minetest.registered_nodes[nodename] == nil then
    return true
  end
  return minetest.registered_nodes[nodename].walkable
end

function torcher.place_torch_at(v,pos)
	pos = vector.round(pos)
	if not can_place_torch_at(v, pos) then
		return false
	end
	if not ensure_torches(v, desired_torch_stock) then
		return false
	end
	if v.reserve_position and not v:reserve_position("torch_spot", pos, 12) then
		return false
	end
	local sucess, ret = v:place(torch_items.floor,pos)
	if v.release_reserved_position then
		v:release_reserved_position("torch_spot", pos)
	end
  if sucess == false then
    if ret == fail.too_far then
      log.error("torch placement in front of villager %s was too far away", v.inventory_name)
    elseif ret == fail.blocked then
      log.verbose("pos in front of villager %s blocked", v.inventory_name)
			working_villages.failed_pos_record(pos)
    elseif ret == fail.not_in_inventory then
      local msg = "Hey, je n'ai plus de torches !"
			request_torches(v, desired_torch_stock)
      local player = v:get_nearest_player(10)
      if player ~= nil then
				v:notify_player_event(player:get_player_name(), msg, "torcher:no_torch", 120, "important")
      elseif v.owner_name then
				v:notify_player_event(v.owner_name, msg, "torcher:no_torch", 120, "important")
      else
        print(("torcher at %s doesn't have torches"):format(minetest.pos_to_string(v.object:get_pos())))
      end
			return false
    else
      log.error("unknown failure in torch placement of villager %s: %s",v.inventory_name,ret)
    end
		return false
  end
	v:set_displayed_action("pose une torche")
	v:set_state_info("J'eclaire le chemin.")
	return true
end

working_villages.register_job("working_villages:job_torcher", {
	description      = "porteur de torches (working_villages)",
	long_description = "Je suis le joueur le plus proche et j'eclaire le chemin avec des torches.",
	inventory_image  = "default_paper.png^working_villages_torcher.png",
	capabilities = {
		torch_placement = true,
		light_detection = true,
		player_following = true,
		automatic_lighting = true,
	},
	on_start = function(self)
		-- Notify player about torcher capabilities
		self:notify_job_feature(
			"Porteur de torches",
			"Suit le joueur et éclaire automatiquement les zones sombres"
		)
	end,
	jobfunc = function(self)
			if self.equip_best_weapon then self:equip_best_weapon() end
			if self.equip_best_armor then self:equip_best_armor() end
			self:count_timer("torcher:supply")
			if self:timer_exceeded("torcher:supply", 20) then
				ensure_torches(self, desired_torch_stock)
			end
		while (self.pause) do
			coroutine.yield()
		end
		local position = self.object:get_pos()
		if torcher.is_dark(position) then
			local front = self:get_front() -- if it is dark, set torch.
				if can_place_torch_at(self, front) then
					torcher.place_torch_at(self,front)
			end
		end
		follower.step(self)
	end,
})

return torcher
