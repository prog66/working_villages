-- Simple AI decision layer based on villager needs.
-- Scores needs and surfaces the most urgent action hint.

local ai_decision = {}

local need_priority = {
	critical = 2,
	low = 1,
}

local function top_need(self)
	local lows = working_villages.needs.get_low(self)
	local best = nil
	for _, need in ipairs(lows) do
		if best == nil then
			best = need
		else
			local best_score = need_priority[best.level] or 0
			local current_score = need_priority[need.level] or 0
			if current_score > best_score or (current_score == best_score and need.value < best.value) then
				best = need
			end
		end
	end
	return best
end

-- Evaluate needs and return a task hint
function ai_decision.evaluate(self)
	local need = top_need(self)
	if not need then
		return {name = "work", priority = 0}
	end

	if need.name == "energy" then
		return {name = "rest", priority = 100, info = "Je suis epuise, je dois me reposer."}
	end
	if need.name == "hunger" then
		return {name = "eat", priority = 90, info = "J'ai faim, je dois manger."}
	end
	if need.name == "tools" then
		return {name = "tool_up", priority = 80, info = "J'ai besoin d'outils pour travailler."}
	end
	if need.name == "materials" then
		return {name = "supply", priority = 70, info = "Je manque de matériaux."}
	end
	return {name = "work", priority = 0}
end

-- Apply the decision: set state info/action hint (non-blocking)
function ai_decision.apply(self)
	if not self or not self.set_state_info then
		return
	end
	local decision = ai_decision.evaluate(self)
	if decision and decision.priority > 0 and decision.info then
		self:set_displayed_action(decision.name)
		self:set_state_info(decision.info)
	end
end

return ai_decision
