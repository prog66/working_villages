-- Minimal local module loader for working_villages.
-- Modules are resolved below the mod directory and executed at most once.

local loader = {}

local function validate_module_name(name)
	if type(name) ~= "string" then
		return nil, "module name must be a string"
	end
	if name == "" then
		return nil, "module name must not be empty"
	end
	if name:sub(1, 1) == "/" or name:sub(-1) == "/" or
			name:find("\\", 1, true) or name:find(":", 1, true) then
		return nil, "absolute paths and platform-specific separators are not allowed"
	end
	if name:find("//", 1, true) then
		return nil, "empty path segments are not allowed"
	end

	local segment_count = 0
	for segment in name:gmatch("[^/]+") do
		segment_count = segment_count + 1
		if not segment:match("^[%a%d_][%a%d_-]*$") then
			return nil, "invalid path segment " .. string.format("%q", segment)
		end
	end
	if segment_count == 0 then
		return nil, "module name must contain a path segment"
	end
	return name
end

local function cycle_description(stack, name)
	local first = 1
	for index, module_name in ipairs(stack) do
		if module_name == name then
			first = index
			break
		end
	end

	local chain = {}
	for index = first, #stack do
		chain[#chain + 1] = stack[index]
	end
	chain[#chain + 1] = name
	return table.concat(chain, " -> ")
end

function loader.install(mod, options)
	if type(mod) ~= "table" then
		error("working_villages loader requires a mod table", 2)
	end
	if type(mod.modpath) ~= "string" or mod.modpath == "" then
		error("working_villages loader requires a non-empty modpath", 2)
	end

	options = options or {}
	local load_file = options.load_file or dofile
	if type(load_file) ~= "function" then
		error("working_villages loader requires a file loader function", 2)
	end

	local modules = options.modules or {}
	local loaded = {init = true, loader = true}
	local loading = {}
	local stack = {}
	modules.init = mod
	modules.loader = loader

	local function require_local(name)
		local valid_name, validation_error = validate_module_name(name)
		if not valid_name then
			error(
				"invalid working_villages module name " .. string.format("%q", tostring(name)) ..
				": " .. validation_error,
				2
			)
		end

		if loaded[valid_name] then
			return modules[valid_name]
		end
		if loading[valid_name] then
			error("circular working_villages module dependency: " .. cycle_description(stack, valid_name), 2)
		end

		loading[valid_name] = true
		stack[#stack + 1] = valid_name
		local path = mod.modpath .. "/" .. valid_name .. ".lua"
		local ok, result = pcall(load_file, path)
		stack[#stack] = nil
		loading[valid_name] = nil

		if not ok then
			error("failed to load working_villages module " .. string.format("%q", valid_name) ..
				" from " .. path .. ": " .. tostring(result), 2)
		end

		loaded[valid_name] = true
		modules[valid_name] = result
		return result
	end

	mod.modules = modules
	mod.require = require_local
	return require_local
end

return loader
