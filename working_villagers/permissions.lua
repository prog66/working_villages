-- Permission/approval system for villager actions
-- Allows villagers to ask owners before doing sensitive actions.

local permissions = {}

local CLOCK_KIND = "gametime_v1"
local AUTO_ACCEPT_DELAY = 5
local MANUAL_ONLY_PREFIX = "save_plan:"

local function game_time()
	local now = tonumber(minetest.get_gametime()) or 0
	return math.max(0, now)
end

local function stamp(record, field, now)
	record[field] = now or game_time()
	record[field .. "_clock"] = CLOCK_KIND
end

local function elapsed_or_restart(record, field, now)
	local timestamp = tonumber(record[field])
	if record[field .. "_clock"] ~= CLOCK_KIND or
			not timestamp or timestamp < 0 or timestamp > now then
		-- Old os.clock values and timestamps from a later/rolled-back session
		-- cannot be compared with Luanti's game clock. Start the TTL again.
		stamp(record, field, now)
		return 0
	end
	return now - timestamp
end

local function is_manual_only(key)
	return type(key) == "string" and key:sub(1, #MANUAL_ONLY_PREFIX) == MANUAL_ONLY_PREFIX
end

local function restart_pending(record, now)
	record.status = "pending"
	stamp(record, "created", now)
	record.responded = nil
	record.responded_clock = nil
	record.decision_source = nil
end

local function ensure_requests(self)
	self.job_data = self.job_data or {}
	self.job_data.permission_requests = self.job_data.permission_requests or {}
	return self.job_data.permission_requests
end

function permissions.should_auto_accept(self)
	local enabled = minetest.settings:get_bool("working_villages_auto_approve_autonomous_actions")
	if enabled == nil then
		enabled = true
	end
	if not enabled then
		return false
	end
	local owner = self.owner_name or ""
	if owner == "" then
		return false
	end
	-- Decisions stay scoped to the entity owner and all world mutations still
	-- pass through protection checks. Other connected players therefore do not
	-- freeze an otherwise autonomous village.
	return true
end

function permissions.request(self, key, message, payload)
	local requests = ensure_requests(self)
	local req = requests[key]
	if req and req.status == "approved" then
		if is_manual_only(key) and req.decision_source ~= "manual" then
			-- Old saves cannot prove that a human approved the file write.
			restart_pending(req)
			return false
		end
		return true
	end
	if req and req.status == "rejected" then
		restart_pending(req)
		req.message = message
		req.payload = payload or {}
		if self.notify_owner then
			self:notify_owner(message)
		end
		return false
	end
	if not req then
		requests[key] = {
			status = "pending",
			message = message,
			payload = payload or {},
		}
		stamp(requests[key], "created")
		if self.notify_owner then
			self:notify_owner(message)
		end
	end
	return false
end

function permissions.respond(self, key, approve)
	local requests = ensure_requests(self)
	local req = requests[key]
	if not req then
		return nil
	end
	req.status = approve and "approved" or "rejected"
	stamp(req, "responded")
	req.decision_source = "manual"
	return req
end

function permissions.tick(self)
	local requests = self.job_data and self.job_data.permission_requests
	if not requests then
		return
	end
	local auto_accept = permissions.should_auto_accept(self)
	local now = game_time()
	for key, req in pairs(requests) do
		if type(req) == "table" and is_manual_only(key) and req.status == "approved" and
				req.decision_source ~= "manual" then
			-- Fail closed for approvals persisted before decision sources existed.
			restart_pending(req, now)
		end
		local age
		if type(req) == "table" and req.status == "pending" then
			age = elapsed_or_restart(req, "created", now)
		end
		if auto_accept and age and not is_manual_only(key) and age >= AUTO_ACCEPT_DELAY then
			req.status = "approved"
			stamp(req, "responded", now)
			req.decision_source = "auto"
			if self.notify_owner then
				self:notify_owner("Auto-accept (serveur solo) : " .. (req.message or "demande"))
			end
		end
	end
end

return permissions
