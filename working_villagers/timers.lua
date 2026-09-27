-- Frame-rate independent compatibility for the historical job timers.
--
-- Job thresholds in working_villages have always been expressed in logical
-- steps (see API_REFERENCE.md).  Advancing them directly by dtime turned a
-- historical threshold of 10 steps into 10 real seconds.  At the usual server
-- step, it used to represent roughly one second.  This module preserves those
-- logical units while still using elapsed time, so slower or faster servers do
-- not change villager behaviour.

local timers = {}

local configured_step = nil
if minetest and minetest.settings and minetest.settings.get then
	configured_step = tonumber(minetest.settings:get("working_villages_timer_step_seconds"))
end

timers.step_seconds = configured_step or 0.1
if timers.step_seconds <= 0 or timers.step_seconds ~= timers.step_seconds
		or timers.step_seconds == math.huge then
	timers.step_seconds = 0.1
end

local function valid_elapsed(value)
	value = tonumber(value)
	if value == nil or value < 0 or value ~= value
			or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

-- Return logical timer steps.  Calls outside on_step retain the legacy +1
-- behaviour; calls carrying dtime are normalized to the configured step.
function timers.increment(self, explicit_dtime)
	local elapsed = explicit_dtime
	if elapsed == nil and self then
		elapsed = self._timer_dtime
	end
	if elapsed == nil then
		return 1
	end
	elapsed = valid_elapsed(elapsed)
	if elapsed == nil then
		return 0
	end
	return elapsed / timers.step_seconds
end

function timers.seconds_to_steps(seconds)
	local elapsed = valid_elapsed(seconds)
	if elapsed == nil then
		return 0
	end
	return elapsed / timers.step_seconds
end

return timers
