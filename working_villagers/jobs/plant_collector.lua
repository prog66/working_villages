local func = working_villages.require("jobs/util")
local compat = working_villages.voxelibre_compat

local herbs = {
  -- more priority definitions
	names = {
		[compat.get_item("default:apple")]={},
		[compat.get_item("default:cactus")]={collect_only_top=true},
		[compat.get_item("default:papyrus")]={collect_only_top=true},
		[compat.get_item("default:dry_shrub")]={},
		[compat.get_item("flowers:mushroom_brown")]={},
		[compat.get_item("flowers:mushroom_red")]={},
	},
  -- less priority definitions
	groups = {
		["flora"]={},
		["mushroom"]={},
	},
}

function herbs.get_herb(item_name)
  -- check more priority definitions
	for key, value in pairs(herbs.names) do
		if item_name==key then
			return value
		end
	end
  -- check less priority definitions
	for key, value in pairs(herbs.groups) do
		if minetest.get_item_group(item_name, key) > 0 then
			return value;
		end
	end
	return nil
end

function herbs.is_herb(item_name)
  local data = herbs.get_herb(item_name);
  if (not data) then
    return false;
  end
  return true;
end

local function find_herb_node(pos)
	local node = minetest.get_node(pos);
  local data = herbs.get_herb(node.name);
  if (not data) then
    return false;
  end

  if data.collect_only_top then
    -- prevent to collect plat part, which can continue to grow
    local pos_below = {x=pos.x, y=pos.y-1, z=pos.z}
    local node_below = minetest.get_node(pos_below);
    if (node_below.name~=node.name) then
      return false;
    end
    local pos_above = {x=pos.x, y=pos.y+1, z=pos.z}
    local node_above = minetest.get_node(pos_above);
    if (node_above.name==node.name) then
      return false;
    end
  end

  return true;
end

local searching_range = {x = 10, y = 5, z = 10}

local function reserve_herb_target(self, pos, ttl)
	if not self.reserve_position then
		return true
	end
	return self:reserve_position("herb_target", pos, ttl or 12)
end

local function release_herb_target(self, pos)
	if self.release_reserved_position then
		self:release_reserved_position("herb_target", pos)
	end
end

local function put_func()
  return true;
end

working_villages.register_job("working_villages:job_herbcollector", {
	description      = "cueilleur (working_villages)",
	long_description = "Je cherche toutes sortes de plantes et je les ramasse.",
	inventory_image  = "default_paper.png^working_villages_herb_collector.png",
	capabilities = {
		plant_gathering = true,
		flora_recognition = true,
		sustainable_harvesting = true,
		mushroom_collection = true,
		cactus_handling = true,
	},
	on_start = function(self)
		-- Notify player about plant collector capabilities
		self:notify_job_feature(
			"Cueillette de plantes",
			"Collecte plantes, champignons, cactus et papyrus. Récolte durable."
		)
	end,
	jobfunc = function(self)
			if self.equip_best_weapon then self:equip_best_weapon() end
			if self.equip_best_armor then self:equip_best_armor() end
		self:handle_night()
		self:handle_chest(nil, put_func)
		self:handle_job_pos()

		self:count_timer("herbcollector:search")
		self:count_timer("herbcollector:change_dir")
		self:count_timer("herbcollector:announce")
		self:handle_obstacles()
		if self:timer_exceeded("herbcollector:search",10) then
			self:collect_nearest_item_by_condition(herbs.is_herb, searching_range)
			local target = func.search_surrounding(self.object:get_pos(), function(pos)
				if self.is_position_reserved and self:is_position_reserved("herb_target", pos) then
					return false
				end
				if func.is_protected(self, pos) or working_villages.failed_pos_test(pos) then
					return false
				end
				return find_herb_node(pos)
			end, searching_range)
			if target ~= nil then
				if not reserve_herb_target(self, target, 15) then
					self:set_displayed_action("cherche une autre plante")
					return
				end
				local destination = func.find_adjacent_clear(target)
				if destination then
				  destination = func.find_ground_below(destination)
				end
				if destination==false then
					destination = target
				end
				local moved = self:go_to(destination)
				if not moved then
					release_herb_target(self, target)
					working_villages.failed_pos_record(target)
					self:set_displayed_action("plante inaccessible")
					return
				end
				herbs.get_herb(minetest.get_node(target).name)
				local dug = self:dig(target,true)
				release_herb_target(self, target)
				if not dug then
					working_villages.failed_pos_record(target)
					self:set_displayed_action("plante ratee")
					return
				end
				self:set_state_info("Je cueille des plantes.")
				self:set_displayed_action("cueille des plantes")
				if self:timer_exceeded("herbcollector:announce", 130) then
					self:announce_action("Je collecte des plantes pour en faire des colorants et des remedes.")
				end
			else
				self:set_state_info("Je cherche des plantes utiles.")
				self:set_displayed_action("cherche des plantes")
			end
		elseif self:timer_exceeded("herbcollector:change_dir",25) then
			self:change_direction_randomly()
		end
	end,
})

working_villages.herbs = herbs
