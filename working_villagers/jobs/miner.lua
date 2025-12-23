-- Miner Job
-- A villager that mines stone and ores underground

local func = working_villages.require("jobs/util")
local compat = working_villages.voxelibre_compat
local blueprints = working_villages.blueprints

-- Check if a node is mineable stone or ore
local function is_mineable(node_name)
	if type(node_name) == "table" then
		node_name = node_name.name
	end
	
	-- Check item groups
	local stone_group = minetest.get_item_group(node_name, "stone")
	local cracky_group = minetest.get_item_group(node_name, "cracky")
	
	if stone_group > 0 or cracky_group > 0 then
		-- Exclude nodes that shouldn't be mined
		if node_name:find("brick") or node_name:find("carved") then
			return false
		end
		return true
	end
	
	return false
end

-- Check if a tool is a pickaxe
local function is_pickaxe(name)
	if type(name) == "table" then
		name = name.name or name:get_name()
	end
	return minetest.get_item_group(name, "pickaxe") > 0
end

-- Find a mineable block nearby
local function find_mineable_block(p)
	local node = minetest.get_node(p)
	
	if not is_mineable(node.name) then
		return false
	end
	
	-- Don't mine protected areas
	if minetest.is_protected(p, "") then
		return false
	end
	
	-- Check if this position has failed before
	if working_villages.failed_pos_test(p) then
		return false
	end
	
	-- Prefer blocks that are not at surface level (y < 0 is underground)
	-- But also allow surface mining
	return true
end

-- Function to place torches in dark areas while mining
local function should_place_torch(pos)
	local light_level = minetest.get_node_light(pos)
	if not light_level then
		return false
	end
	return light_level < 8
end

local function put_func(_, stack)
	local name = stack:get_name()
	-- Keep pickaxes and torches
	if is_pickaxe(name) or name == compat.get_item("default:torch") then
		return false
	end
	return true
end

local function take_func(villager, stack)
	local name = stack:get_name()
	-- Take pickaxes if we don't have one, and torches if we're low
	if is_pickaxe(name) then
		local inv = villager:get_inventory()
		-- Check if we already have a pickaxe
		for i = 1, inv:get_size("main") do
			local itemstack = inv:get_stack("main", i)
			if is_pickaxe(itemstack:get_name()) then
				return false  -- Already have a pickaxe
			end
		end
		return true
	end
	
	if name == compat.get_item("default:torch") then
		-- Take torches if we have less than 10
		local inv = villager:get_inventory()
		local torch_count = 0
		for i = 1, inv:get_size("main") do
			local itemstack = inv:get_stack("main", i)
			if itemstack:get_name() == compat.get_item("default:torch") then
				torch_count = torch_count + itemstack:get_count()
			end
		end
		return torch_count < 10
	end
	
	return false
end

local searching_range = {x = 10, y = 10, z = 10}

working_villages.register_job("working_villages:job_miner", {
	description = "mineur (working_villages)",
	long_description = "Je mine la pierre et les minerais. "..
		"Je collecte des mineraux utiles et j'aide a creuser pour la construction. "..
		"J'ai besoin d'une pioche et je pose des torches pour eclairer.",
	inventory_image = "default_paper.png^working_villages_miner.png",
	capabilities = {
		mining = true,
		ore_detection = true,
		torch_placement = true,
		auto_item_collection = true,
		underground_navigation = true,
	},
	on_start = function(self)
		-- Notify player about miner capabilities
		self:notify_job_feature(
			"Minage automatique",
			"Mine pierre et minerais, pose des torches, collecte automatiquement les items minés"
		)
	end,
	jobfunc = function(self)
		self:handle_night()
		self:handle_chest(take_func, put_func)
		self:handle_job_pos()
		
		self:count_timer("miner:search")
		self:count_timer("miner:change_dir")
		self:count_timer("miner:torch_check")
		self:count_timer("miner:announce")
		self:handle_obstacles()
		
		-- Check if we have a pickaxe
		local has_pickaxe = false
		local inv = self:get_inventory()
		for i = 1, inv:get_size("main") do
			local itemstack = inv:get_stack("main", i)
			if is_pickaxe(itemstack:get_name()) then
				has_pickaxe = true
				break
			end
		end
		
		if not has_pickaxe then
			self:set_state_info("J'ai besoin d'une pioche pour miner. Donnez-m'en une.")
			self:set_displayed_action("cherche une pioche")
			self:announce_action("J'ai besoin d'une pioche pour travailler.", 90)
			return
		end
		
		if self:timer_exceeded("miner:search", 20) then
			-- Collect any dropped items (from mining)
			local pos = self.object:get_pos()
			local objects = minetest.get_objects_inside_radius(pos, 5)
			for _, obj in ipairs(objects) do
				if obj:is_player() == false then
					local entity = obj:get_luaentity()
					if entity and entity.name == "__builtin:item" then
						local item = entity.itemstring
						if item then
							local itemstack = ItemStack(item)
							if inv:room_for_item("main", itemstack) then
								inv:add_item("main", itemstack)
								obj:remove()
							end
						end
					end
				end
			end
			
			-- Find a block to mine
			local target = func.search_surrounding(self.object:get_pos(), find_mineable_block, searching_range)
			if target then
				local destination = func.find_adjacent_clear(target)
				if destination then
					destination = func.find_ground_below(destination)
				end
				if destination == false then
					print("failure: no adjacent walkable found")
					destination = target
				end
				
				self:set_displayed_action("mine")
				local success = self:go_to(destination)
				if success then
					self:dig(target, true)
					
					-- Award experience for mining
					local inv_name = self:get_inventory_name()
					blueprints.add_experience(inv_name, 1)
					
					self:set_state_info("Je mine des ressources utiles.")
					if self:timer_exceeded("miner:announce", 140) then
						self:announce_action("Je mine de la pierre et des minerais.")
					end
				else
					working_villages.failed_pos_record(target)
					self:set_displayed_action("cherche un autre filon")
				end
			else
				self:set_state_info("Je cherche de la pierre ou du minerai.")
			end
		elseif self:timer_exceeded("miner:torch_check", 100) then
			-- Occasionally check if we should place a torch
			local pos = self.object:get_pos()
			if should_place_torch(pos) then
				local torch_name = compat.get_item("default:torch")
				if self:has_item_in_main(function(name) return name == torch_name end) then
					-- Try to place a torch on a nearby wall
					local dirs = {
						{x=1, y=0, z=0},
						{x=-1, y=0, z=0},
						{x=0, y=0, z=1},
						{x=0, y=0, z=-1},
					}
					for _, dir in ipairs(dirs) do
						local wall_pos = vector.add(pos, dir)
						local wall_node = minetest.get_node(wall_pos)
						if wall_node.name ~= "air" then
							local torch_pos = vector.subtract(wall_pos, dir)
							self:place(torch_name, torch_pos)
							self:set_displayed_action("pose une torche")
							self:announce_action("Je pose des torches pour eclairer les galeries.", 180)
							break
						end
					end
				end
			end
		elseif self:timer_exceeded("miner:change_dir", 50) then
			self:change_direction_randomly()
		end
	end,
})
