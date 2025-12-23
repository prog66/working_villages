--[[
  Learner Job - Makes villagers come alive when they don't have a profession
  
  Features:
  - Explores the environment and discovers new places
  - Talks to other villagers and players
  - Experiments with simple tasks and learns
  - Asks for player validation on learned behaviors
  - Creates a more immersive and living world
]]--

local func = working_villages.require("jobs/util")
local ai_behavior = working_villages.ai_behavior

-- Configuration
local explore_radius = tonumber(minetest.settings:get("working_villages_learner_explore_radius")) or 15
local social_range = tonumber(minetest.settings:get("working_villages_learner_social_range")) or 10
local experiment_interval = tonumber(minetest.settings:get("working_villages_learner_experiment_interval")) or 120

-- Learning mode messages
local explore_messages = {
	"Je découvre ce lieu intéressant.",
	"Je me demande ce qu'il y a par là.",
	"C'est fascinant de voir tout ça.",
	"Je n'avais jamais vu cet endroit avant.",
	"Il y a tant à apprendre ici.",
}

local social_messages = {
	"Bonjour ! Comment allez-vous ?",
	"Vous avez fait quelque chose d'intéressant aujourd'hui ?",
	"Je suis en train d'apprendre de nouvelles choses.",
	"Que pensez-vous de ce village ?",
	"Je cherche à apprendre un métier. Avez-vous des conseils ?",
}

local thinking_messages = {
	"Hmm, je me demande comment ça marche...",
	"Peut-être que je devrais essayer ça.",
	"Je réfléchis à ce que je pourrais faire.",
	"Il y a sûrement quelque chose d'utile à apprendre ici.",
}

local player_question_messages = {
	"Ai-je bien fait ?",
	"Qu'en pensez-vous ?",
	"Est-ce que c'était correct ?",
	"Devrais-je continuer comme ça ?",
}

--[[
  Picks a random exploration target within radius
]]--
local function pick_explore_target(self)
	local base = vector.round(self.object:get_pos())
	local dx = math.random(-explore_radius, explore_radius)
	local dz = math.random(-explore_radius, explore_radius)
	local pos = {x = base.x + dx, y = base.y + 2, z = base.z + dz}
	local ground = func.find_ground_below(pos)
	return ground or base
end

--[[
  Finds nearby villagers or players to interact with
]]--
local function find_social_target(self)
	local pos = self.object:get_pos()
	
	-- First check for other villagers
	local villagers = ai_behavior.patterns.find_nearby_workers(self, social_range)
	if #villagers > 0 then
		return villagers[math.random(#villagers)]
	end
	
	-- Then check for players
	local player, distance, _ = self:get_nearest_player(social_range)
	if player then
		return player
	end
	
	return nil
end

--[[
  Make the villager explore the environment
]]--
local function do_exploration(self)
	self:count_timer("learner:explore")
	
	if self:timer_exceeded("learner:explore", 100) then
		local destination = pick_explore_target(self)
		self:set_displayed_action("exploration")
		self:set_state_info("J'explore les alentours pour apprendre.")
		
		-- Remember explored location
		ai_behavior.memory.remember_location(self, "explored", destination, {
			time = os.clock()
		})
		
		-- Occasionally say something while exploring
		if math.random(100) < 30 then
			local message = explore_messages[math.random(#explore_messages)]
			self:say(message, 60)
		end
		
		self:go_to(destination)
		return true
	end
	
	return false
end

--[[
  Make the villager interact socially with others
]]--
local function do_social_interaction(self)
	self:count_timer("learner:social")
	
	if self:timer_exceeded("learner:social", 150) then
		local target = find_social_target(self)
		
		if target then
			self:set_displayed_action("socialisation")
			self:set_state_info("Je parle avec quelqu'un.")
			
			local message = social_messages[math.random(#social_messages)]
			self:say(message, 45)
			
			-- Move closer to the target if it's not too far
			local target_pos
			if type(target.get_pos) == "function" then
				target_pos = target:get_pos()
			elseif type(target.object) == "table" and type(target.object.get_pos) == "function" then
				target_pos = target.object:get_pos()
			end
			
			if target_pos then
				local my_pos = self.object:get_pos()
				local distance = vector.distance(my_pos, target_pos)
				if distance > 2 and distance < social_range then
					self:go_to(target_pos)
				end
			end
			
			return true
		end
	end
	
	return false
end

--[[
  Make the villager experiment with simple tasks
]]--
local function do_experimentation(self)
	self:count_timer("learner:experiment")
	
	if self:timer_exceeded("learner:experiment", experiment_interval) then
		local my_pos = self.object:get_pos()
		
		-- Try to pick up nearby items (learning to gather)
		if math.random(100) < 40 then
			local range = {x = 5, y = 2, z = 5}
			if self:collect_nearest_item_by_condition(function() return true end, range) then
				self:set_displayed_action("apprentissage")
				self:set_state_info("J'apprends à ramasser des objets.")
				
				-- Ask player for validation occasionally
				if math.random(100) < 50 then
					local question = player_question_messages[math.random(#player_question_messages)]
					self:say("Je ramasse des objets. " .. question, 90)
				end
				
				return true
			end
		end
		
		-- Try observing surroundings (learning about environment)
		if math.random(100) < 30 then
			self:set_displayed_action("observation")
			self:set_state_info("J'observe mon environnement pour apprendre.")
			
			local message = thinking_messages[math.random(#thinking_messages)]
			self:say(message, 60)
			
			-- Look around (change direction)
			self:change_direction_randomly()
			return true
		end
	end
	
	return false
end

--[[
  Idle thinking behavior
]]--
local function do_idle_thinking(self)
	self:count_timer("learner:think")
	
	if self:timer_exceeded("learner:think", 80) then
		self:set_displayed_action("réflexion")
		self:set_state_info("Je réfléchis à ce que je pourrais apprendre.")
		
		-- Change direction occasionally to appear alive
		if math.random(100) < 60 then
			self:change_direction_randomly()
		end
		
		return true
	end
	
	return false
end

--[[
  Main learning mode job function
]]--
local function learner_jobfunc(self)
	-- Handle basic needs
	self:handle_night()
	self:handle_obstacles()
	
	-- Set AI state to IDLE (since we're not working a job)
	ai_behavior.state_machine.set_state(self, ai_behavior.STATES.IDLE)
	
	-- Periodic memory cleanup
	if math.random(100) < 5 then
		ai_behavior.cleanup_memory(self)
	end
	
	-- Try different behaviors in order of priority
	-- Social interaction has higher priority to make villagers feel alive
	if do_social_interaction(self) then
		return
	end
	
	-- Experimentation to show learning
	if do_experimentation(self) then
		return
	end
	
	-- Exploration to discover the world
	if do_exploration(self) then
		return
	end
	
	-- Default idle behavior
	do_idle_thinking(self)
end

-- Register the learner job
working_villages.register_job("working_villages:job_apprenant", {
	description      = "apprenant (working_villages)",
	long_description = "Je suis en mode apprentissage. J'explore les environs, je parle aux autres villageois et aux joueurs, " ..
		"et j'essaie d'apprendre de nouvelles choses. Je pourrais vous demander si ce que je fais est bien. " ..
		"Donnez-moi un métier pour que je puisse devenir utile au village !",
	inventory_image  = "default_paper.png^working_villages_question.png",
	jobfunc = learner_jobfunc,
})

-- Craft recipe for learner job
-- Made from empty job + book (representing learning/education)
minetest.register_craft{
	output = "working_villages:job_apprenant",
	recipe = {
		{"working_villages:job_empty", working_villages.voxelibre_compat.get_item("default:book")},
	},
}
