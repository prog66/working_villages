local forms = working_villages.require("forms")

forms.register_menu_page("working_villages:talking_menu", "bonjour")

forms.register_text_page("working_villages:job_desc",
	function(villager)
		local job = villager:get_job()
		if not job then
			return "Je n'ai pas de metier."
		end
		return job.long_description or "quelque chose..."
end)

forms.put_link("working_villages:talking_menu", "working_villages:job_desc",
	"Que fais-tu dans ton metier ?")

forms.register_text_page("working_villages:state",
  function(villager)
    return villager.state_info
end)

forms.put_link("working_villages:talking_menu", "working_villages:state",
  "Que fais-tu en ce moment ?")

-- Add learning mode specific dialogue
forms.register_text_page("working_villages:learning_status",
	function(villager)
		local job = villager:get_job()
		if not job or job.description ~= "apprenant (working_villages)" then
			return "Je ne suis pas en mode apprentissage actuellement."
		end
		
		local messages = {
			"J'explore le monde et j'apprends de nouvelles choses chaque jour.",
			"Je parle avec les autres villageois pour comprendre comment fonctionne notre village.",
			"J'essaie différentes activités pour voir ce que je pourrais faire.",
			"Je cherche encore ma voie. Peut-être avez-vous un métier pour moi ?",
		}
		return messages[math.random(#messages)]
	end)

forms.put_link("working_villages:talking_menu", "working_villages:learning_status",
	"Que penses-tu de l'apprentissage ?")

-- Add encouragement option for learners
forms.register_text_page("working_villages:encouragement",
	function(villager)
		local job = villager:get_job()
		if not job or job.description ~= "apprenant (working_villages)" then
			return "Merci pour l'encouragement !"
		end
		return "Merci beaucoup ! Vos encouragements m'aident à apprendre. " ..
			"Un jour, j'espère devenir aussi compétent que les autres villageois !"
	end)

forms.put_link("working_villages:talking_menu", "working_villages:encouragement",
	"Continue d'apprendre, c'est bien !")
