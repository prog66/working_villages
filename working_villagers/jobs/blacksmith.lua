-- Blacksmith Job
-- A villager that works with metal, repairs tools, and creates metal items

local func = working_villages.require("jobs/util")
local compat = working_villages.voxelibre_compat
local blueprints = working_villages.blueprints

-- Materials that blacksmiths work with
local metal_ores = {
	[compat.get_item("default:stone_with_iron")] = true,
	[compat.get_item("default:stone_with_copper")] = true,
	[compat.get_item("default:stone_with_gold")] = true,
}

local metal_ingots = {
	[compat.get_item("default:steel_ingot")] = true,
	[compat.get_item("default:copper_ingot")] = true,
	[compat.get_item("default:gold_ingot")] = true,
}

local function is_metal_ore(name)
	if type(name) == "table" then
		name = name.name or name:get_name()
	end
	return metal_ores[name] or false
end

local function is_metal_ingot(name)
	if type(name) == "table" then
		name = name.name or name:get_name()
	end
	return metal_ingots[name] or false
end

-- Check if a position has a furnace (for smelting)
local function is_furnace(pos)
	local node = minetest.get_node(pos)
	local node_name = node.name
	
	-- Check for both minetest_game and VoxeLibre furnaces
	if compat.is_voxelibre then
		return node_name:find("mcl_furnaces:") ~= nil
	else
		return node_name:find("default:furnace") ~= nil
	end
end

local function find_furnace(p)
	if minetest.is_protected(p, "") then return false end
	return is_furnace(p)
end

-- Check if a tool needs repair (damaged)
local function needs_repair(itemstack)
	if type(itemstack) == "string" then
		itemstack = ItemStack(itemstack)
	end
	
	local wear = itemstack:get_wear()
	-- Consider tools damaged if they have more than 20% wear
	return wear > 13107  -- 65535 * 0.2
end

-- Function to repair a tool (reduce wear)
local function repair_tool(self, itemstack)
	if not needs_repair(itemstack) then
		return false
	end
	
	local current_wear = itemstack:get_wear()
	-- Repair 10% of the tool's durability
	local repair_amount = 6553  -- 65535 * 0.1
	local new_wear = math.max(0, current_wear - repair_amount)
	
	itemstack:set_wear(new_wear)
	
	-- Award experience for repairing
	local inv_name = self:get_inventory_name()
	blueprints.add_experience(inv_name, 1)
	
	return true
end

local function put_func(_, stack)
	local name = stack:get_name()
	-- Keep metal ingots and damaged tools
	if is_metal_ingot(name) or needs_repair(stack) then
		return false
	end
	return true
end

local function take_func(_, stack)
	return not put_func(_, stack)
end

local searching_range = {x = 15, y = 5, z = 15}

working_villages.register_job("working_villages:job_blacksmith", {
	description = "forgeron (working_villages)",
	long_description = "Je travaille le metal et le feu. Je collecte des minerais, je les fond en lingots, "..
		"je repare les outils abimes et j'aide a construire en metal. "..
		"J'ai besoin d'un four pour bien travailler.",
	inventory_image = "default_paper.png^working_villages_blacksmith.png",
	jobfunc = function(self)
		self:handle_night()
		self:handle_chest(take_func, put_func)
		self:handle_job_pos()
		
		self:count_timer("blacksmith:search")
		self:count_timer("blacksmith:change_dir")
		self:count_timer("blacksmith:announce")
		self:handle_obstacles()
		
		if self:timer_exceeded("blacksmith:search", 20) then
			-- Check for damaged tools in inventory and repair them
			local inv = self:get_inventory()
			local main_inv = inv:get_list("main")
			local repaired_something = false
			
			for i, stack in ipairs(main_inv) do
				if not stack:is_empty() and needs_repair(stack) then
					if repair_tool(self, stack) then
						inv:set_stack("main", i, stack)
						self:set_state_info("Repare : " .. stack:get_name())
						self:set_displayed_action("repare des outils")
						self:delay(50)
						repaired_something = true
						if self:timer_exceeded("blacksmith:announce", 160) then
							self:announce_action("Je repare les outils uses pour qu'ils durent plus longtemps.")
						end
						break
					end
				end
			end
			
			if not repaired_something then
				-- Collect metal ores
				self:collect_nearest_item_by_condition(is_metal_ore, searching_range)
				
				-- Try to find and collect metal ingots
				self:collect_nearest_item_by_condition(is_metal_ingot, searching_range)
				
				-- Look for a furnace to work at
				local furnace_pos = func.search_surrounding(self.object:get_pos(), find_furnace, searching_range)
				if furnace_pos then
					-- Check if we have ores to smelt
					if self:has_item_in_main(is_metal_ore) then
						local destination = func.find_adjacent_clear(furnace_pos)
						if destination then
							destination = func.find_ground_below(destination)
							if destination then
								self:set_displayed_action("travaille a la forge")
								self:go_to(destination)
								self:use_node(furnace_pos)
								-- In a real implementation, we would interact with the furnace
								-- For now, just indicate the blacksmith is working
								self:set_state_info("Je travaille a la forge, je prepare la fusion du minerai.")
								self:delay(100)
								if self:timer_exceeded("blacksmith:announce", 160) then
									self:announce_action("Je fond le minerai pour creer des lingots de metal.")
								end
							end
						end
					else
						self:set_state_info("Je cherche du minerai ou des outils a reparer.")
					end
				else
					self:set_state_info("Je cherche un four.")
					if self:timer_exceeded("blacksmith:announce", 200) then
						self:announce_action("J'ai besoin d'un four pour travailler le metal.")
					end
				end
			end
		elseif self:timer_exceeded("blacksmith:change_dir", 50) then
			self:change_direction_randomly()
		end
	end,
})
