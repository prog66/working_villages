local crafting = {}

local recipe_cache = {}
local group_candidate_cache = {}
local compat = working_villages.compat or working_villages.voxelibre_compat

local function merge_counts(target, source)
	if not source then
		return
	end
	for key, value in pairs(source) do
		target[key] = (target[key] or 0) + value
	end
	return target
end

local function new_result()
	return {
		missing_items = {},
		missing_specs = {},
		workstation_required = false,
	}
end

local function add_missing(result, spec, count)
	if not spec or count <= 0 then
		return result
	end
	if spec.kind == "item" then
		result.missing_items[spec.name] = (result.missing_items[spec.name] or 0) + count
	else
		result.missing_specs[spec.raw] = (result.missing_specs[spec.raw] or 0) + count
	end
	return result
end

local function has_missing(result)
	if not result then
		return false
	end
	return next(result.missing_items) ~= nil or next(result.missing_specs) ~= nil
end

local function normalize_spec(raw)
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	if raw:sub(1, 6) == "group:" then
		return {
			kind = "group",
			name = raw:sub(7),
			raw = raw,
		}
	end
	return {
		kind = "item",
		name = raw,
		raw = raw,
	}
end

local function matches_spec(itemname, spec)
	if not itemname or itemname == "" or not spec then
		return false
	end
	if spec.kind == "item" then
		return itemname == spec.name
	end
	return minetest.get_item_group(itemname, spec.name) > 0
end

local function count_matching_in_main(self, spec)
	local total = 0
	for _, stack in ipairs(self:get_inventory():get_list("main") or {}) do
		if not stack:is_empty() and matches_spec(stack:get_name(), spec) then
			total = total + stack:get_count()
		end
	end
	return total
end

local function restore_stack(self, stack)
	if not stack or stack:is_empty() then
		return
	end
	local leftover = self:add_item_to_main(stack)
	if leftover and not leftover:is_empty() and self.object then
		minetest.add_item(self.object:get_pos(), leftover)
	end
end

local function take_one_from_main(self, spec)
	local inv = self:get_inventory()
	for index, stack in ipairs(inv:get_list("main") or {}) do
		if not stack:is_empty() and matches_spec(stack:get_name(), spec) then
			local taken = stack:take_item(1)
			inv:set_stack("main", index, stack)
			return taken
		end
	end
	return nil
end

local function get_recipe_output_count(recipe)
	local output = ItemStack(recipe.output or "")
	if output:is_empty() then
		return 1
	end
	return math.max(output:get_count(), 1)
end

local function count_recipe_items(recipe)
	local count = 0
	-- Luanti represents empty slots in shaped recipes as nil.  Using ipairs
	-- would therefore stop at the first hole and under-count/truncate the recipe.
	for _, item in pairs(recipe.items or {}) do
		if item and item ~= "" then
			count = count + 1
		end
	end
	return count
end

local function recipe_slot_count(recipe)
	local max_index = 0
	for index, _ in pairs(recipe.items or {}) do
		if type(index) == "number" and index > max_index and index % 1 == 0 then
			max_index = index
		end
	end
	local width = math.max(tonumber(recipe.width) or 0, 0)
	if width > 0 and max_index > 0 then
		-- Preserve trailing empty cells on the last occupied row.  They matter to
		-- get_craft_result for shaped recipes even though they are absent from the
		-- sparse table returned by get_all_craft_recipes.
		return math.ceil(max_index / width) * width
	end
	return max_index
end

local function restore_craft_remainders(self, craft_result, decremented_input)
	-- get_craft_result puts replacements back into the decremented grid whenever
	-- they fit there.  Only replacements which could not fit are returned in
	-- output.replacements, so both collections must be restored.
	local decremented_items = type(decremented_input) == "table" and decremented_input.items or nil
	if type(decremented_items) == "table" then
		local max_index = 0
		for index, _ in pairs(decremented_items) do
			if type(index) == "number" and index > max_index and index % 1 == 0 then
				max_index = index
			end
		end
		for index = 1, max_index do
			local stack = decremented_items[index]
			if stack then
				restore_stack(self, ItemStack(stack))
			end
		end
	end

	for _, stack in pairs((craft_result and craft_result.replacements) or {}) do
		if stack then
			restore_stack(self, ItemStack(stack))
		end
	end
end

local function get_recipes(itemname)
	if recipe_cache[itemname] ~= nil then
		return recipe_cache[itemname]
	end
	local recipes = {}
	for _, recipe in ipairs(minetest.get_all_craft_recipes(itemname) or {}) do
		if recipe.method == "normal" or recipe.method == "shapeless" then
			local output = ItemStack(recipe.output or "")
			if not output:is_empty() and output:get_name() == itemname then
				table.insert(recipes, recipe)
			end
		end
	end
	table.sort(recipes, function(left, right)
		local left_out = get_recipe_output_count(left)
		local right_out = get_recipe_output_count(right)
		if left_out ~= right_out then
			return left_out > right_out
		end
		return count_recipe_items(left) < count_recipe_items(right)
	end)
	recipe_cache[itemname] = recipes
	return recipes
end

local function recipe_requires_workstation(recipe)
	if working_villages.gameplay_mode ~= "survival" or not (compat and compat.is_voxelibre) then
		return false
	end
	return (tonumber(recipe.width) or 0) > 2 or count_recipe_items(recipe) > 4
end

local function has_village_workstation(self)
	local center = self.object and self.object:get_pos() or nil
	if working_villages.get_shared_storage_pos then
		center = working_villages.get_shared_storage_pos(self.owner_name) or center
	end
	if not center then
		return false
	end
	local names = {"group:crafting_table", "group:workbench"}
	if compat and compat.get_crafting_table_items then
		for _, name in ipairs(compat.get_crafting_table_items()) do
			names[#names + 1] = name
		end
	end
	local range = {x = 16, y = 8, z = 16}
	for _, pos in ipairs(minetest.find_nodes_in_area(
			vector.subtract(center, range), vector.add(center, range), names)) do
		local node = minetest.get_node_or_nil(pos)
		if node and compat and compat.is_crafting_table(node.name) then
			return true
		end
	end
	return false
end

local function get_group_candidates(group_name)
	if group_candidate_cache[group_name] then
		return group_candidate_cache[group_name]
	end
	local candidates = {}
	for name, _ in pairs(minetest.registered_items) do
		if minetest.get_item_group(name, group_name) > 0 then
			table.insert(candidates, name)
		end
	end
	table.sort(candidates)
	group_candidate_cache[group_name] = candidates
	return candidates
end

local function rank_group_candidates(self, spec)
	local ranked = {}
	for _, name in ipairs(get_group_candidates(spec.name)) do
		local available = count_matching_in_main(self, normalize_spec(name))
		local recipes = get_recipes(name)
		table.insert(ranked, {
			name = name,
			available = available,
			craftable = #recipes > 0,
		})
	end
	table.sort(ranked, function(left, right)
		if left.available ~= right.available then
			return left.available > right.available
		end
		if left.craftable ~= right.craftable then
			return left.craftable
		end
		return left.name < right.name
	end)
	return ranked
end

local function ensure_context(ctx)
	ctx = ctx or {}
	ctx.depth = ctx.depth or 0
	ctx.max_depth = ctx.max_depth or 4
	ctx.active = ctx.active or {}
	return ctx
end

local function craft_failures(self)
	self.job_data = self.job_data or {}
	self.job_data.crafting_failures = self.job_data.crafting_failures or {}
	return self.job_data.crafting_failures
end

local function snapshot_main_inventory(self)
	local snapshot = {}
	for index, stack in ipairs(self:get_inventory():get_list("main") or {}) do
		snapshot[index] = ItemStack(stack)
	end
	return snapshot
end

local function restore_main_inventory(self, snapshot)
	if snapshot then
		self:get_inventory():set_list("main", snapshot)
	end
end

local function ensure_item_internal(self, itemname, count, opts, ctx)
	ctx = ensure_context(ctx)
	if count_matching_in_main(self, normalize_spec(itemname)) >= count then
		return true, new_result()
	end

	if opts.use_shared_storage and not (opts.skip_storage_for and opts.skip_storage_for[itemname]) then
		self:take_from_shared_storage({[itemname] = math.max(1, count - count_matching_in_main(self, normalize_spec(itemname)))})
		if count_matching_in_main(self, normalize_spec(itemname)) >= count then
			return true, new_result()
		end
	end

	if ctx.depth >= ctx.max_depth or ctx.active[itemname] then
		local result = new_result()
		add_missing(result, normalize_spec(itemname), count)
		return false, result
	end

	local recipes = get_recipes(itemname)
	if #recipes == 0 then
		local result = new_result()
		add_missing(result, normalize_spec(itemname), count)
		return false, result
	end

	ctx.active[itemname] = true
	local result = new_result()

	for _, recipe in ipairs(recipes) do
		if recipe_requires_workstation(recipe) and not has_village_workstation(self) then
			result.workstation_required = true
			if self.set_displayed_action then
				self:set_displayed_action("cherche un etabli")
			end
			if self.set_state_info then
				self:set_state_info("Cette recette exige un etabli du village.")
			end
		else
		while count_matching_in_main(self, normalize_spec(itemname)) < count do
			local consumed = {}
			local actual_items = {}
			local missing = new_result()
			local slot_count = recipe_slot_count(recipe)
			for slot_index = 1, slot_count do
				local raw_spec = recipe.items and recipe.items[slot_index] or nil
				local spec = normalize_spec(raw_spec)
				if spec then
					local taken = take_one_from_main(self, spec)
					if not taken and opts.use_shared_storage then
						self:take_from_shared_storage_by_predicate(function(candidate)
							return matches_spec(candidate, spec)
						end, 1)
						taken = take_one_from_main(self, spec)
					end
					if not taken then
						if spec.kind == "item" then
							local ok, nested = ensure_item_internal(self, spec.name, 1, opts, {
								depth = ctx.depth + 1,
								max_depth = ctx.max_depth,
								active = ctx.active,
							})
							if ok then
								taken = take_one_from_main(self, spec)
							else
								merge_counts(missing.missing_items, nested.missing_items)
								merge_counts(missing.missing_specs, nested.missing_specs)
							end
						else
							for _, candidate in ipairs(rank_group_candidates(self, spec)) do
								local ok = false
								if candidate.available > 0 then
									ok = true
								elseif candidate.craftable then
									ok = select(1, ensure_item_internal(self, candidate.name, 1, opts, {
										depth = ctx.depth + 1,
										max_depth = ctx.max_depth,
										active = ctx.active,
									}))
								end
								if ok then
									taken = take_one_from_main(self, spec)
									if taken then
										break
									end
								end
							end
							if not taken then
								add_missing(missing, spec, 1)
							end
						end
					end
					if not taken then
						for _, stack in ipairs(consumed) do
							restore_stack(self, stack)
						end
						merge_counts(result.missing_items, missing.missing_items)
						merge_counts(result.missing_specs, missing.missing_specs)
						break
					end
					table.insert(consumed, taken)
					table.insert(actual_items, taken)
				else
					table.insert(actual_items, ItemStack())
				end
			end

			if has_missing(missing) then
				break
			end

			local craft_method = recipe.method == "shapeless" and "normal" or (recipe.method or "normal")
			local craft_result, decremented_input = minetest.get_craft_result({
				method = craft_method,
				width = recipe.width or 0,
				items = actual_items,
			})
			local output = craft_result and craft_result.item or ItemStack()
			if output:is_empty() or output:get_name() ~= itemname then
				for _, stack in ipairs(consumed) do
					restore_stack(self, stack)
				end
				add_missing(result, normalize_spec(itemname), count)
				break
			end

			local inv = self:get_inventory()
			if not inv:room_for_item("main", output) then
				for _, stack in ipairs(consumed) do
					restore_stack(self, stack)
				end
				add_missing(result, normalize_spec(itemname), count)
				break
			end

			local leftover = self:add_item_to_main(output)
			if leftover and not leftover:is_empty() then
				restore_stack(self, leftover)
				add_missing(result, normalize_spec(itemname), count)
				break
			end

			restore_craft_remainders(self, craft_result, decremented_input)
		end
		end

		if count_matching_in_main(self, normalize_spec(itemname)) >= count then
			ctx.active[itemname] = nil
			return true, result
		end
	end

	ctx.active[itemname] = nil
	if not has_missing(result) then
		add_missing(result, normalize_spec(itemname), count)
	end
	return false, result
end

function crafting.ensure_item(self, itemname, count, opts, ctx)
	if not self or not itemname or itemname == "" then
		return false, new_result()
	end
	count = tonumber(count) or 1
	count = math.max(1, count)
	opts = opts or {}
	local spec = normalize_spec(itemname)
	if not spec then
		return false, new_result()
	end
	if count_matching_in_main(self, spec) >= count then
		return true, new_result()
	end

	local failures = craft_failures(self)
	local now = minetest.get_gametime()
	local cooldown = tonumber(opts.fail_cooldown) or 15
	if not opts.force and failures[itemname] and (now - failures[itemname]) < cooldown then
		local result = new_result()
		add_missing(result, spec, count)
		return false, result
	end

	-- Recursive exploration may legitimately craft intermediates before a later
	-- ingredient or workstation proves unavailable. For inventory-local calls,
	-- failure must be atomic: retain the exact pre-attempt stacks instead of
	-- slowly consuming bootstrap resources across retries. Shared-storage calls
	-- are excluded because their transaction spans a world inventory too.
	local rollback_snapshot = opts.rollback_local_failure ~= false
		and not opts.use_shared_storage and snapshot_main_inventory(self) or nil
	local ok, result = ensure_item_internal(self, itemname, count, opts, ctx)
	if ok then
		failures[itemname] = nil
		return true, result
	end
	restore_main_inventory(self, rollback_snapshot)
	failures[itemname] = now
	return false, result
end

function crafting.ensure_any_item(self, candidates, count, opts)
	local aggregate = new_result()
	for _, itemname in ipairs(candidates or {}) do
		if itemname and itemname ~= "" and minetest.registered_items[itemname] then
			local ok, result = crafting.ensure_item(self, itemname, count, opts)
			if ok then
				return itemname, result
			end
			if result then
				merge_counts(aggregate.missing_items, result.missing_items)
				merge_counts(aggregate.missing_specs, result.missing_specs)
				aggregate.workstation_required = aggregate.workstation_required
					or result.workstation_required == true
			end
		end
	end
	return nil, aggregate
end

return crafting
