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
