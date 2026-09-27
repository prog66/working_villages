local log = {}

local function format_message(message, ...)
	local text = tostring(message)
	local argument_count = select("#", ...)
	if argument_count == 0 then
		return text
	end

	local ok, formatted = pcall(string.format, text, ...)
	if ok then
		return formatted
	end

	local arguments = {}
	for index = 1, argument_count do
		arguments[index] = tostring(select(index, ...))
	end
	return text .. " | " .. table.concat(arguments, " ") .. " [format error: " .. tostring(formatted) .. "]"
end

local function make_logger(level)
	return function(message, ...)
		minetest.log(level, "[working_villages] " .. format_message(message, ...))
	end
end

log.error = make_logger("error")
log.warning = make_logger("warning")
log.action = make_logger("action")
log.info = make_logger("info")
log.verbose = make_logger("verbose")
log.debug = log.verbose

return log
