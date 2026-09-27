-- Standalone fake-Luanti regression tests for forms access routing.
-- Run from the repository root with:
--   lua working_villagers/tests/forms_access_spec.lua working_villagers

local modpath = (arg and arg[1]) or "working_villagers"
local receive_fields
local shown_forms = {}
local messages = {}

local function assert_equal(actual, expected, message)
	if actual ~= expected then
		error((message or "values differ") .. ": expected " .. tostring(expected) ..
			", got " .. tostring(actual), 2)
	end
end

minetest = {
	register_on_player_receive_fields = function(callback)
		receive_fields = callback
	end,
	show_formspec = function(player_name, formname, formspec)
		shown_forms[#shown_forms + 1] = {
			player_name = player_name,
			formname = formname,
			formspec = formspec,
		}
	end,
	chat_send_player = function(player_name, message)
		messages[#messages + 1] = {player_name = player_name, message = message}
	end,
	formspec_escape = function(value)
		return tostring(value or "")
	end,
	wrap_text = function(value)
		return value
	end,
	settings = {
		get = function()
			return nil
		end,
	},
}

local log = {
	warning = function() end,
	error = function() end,
}
local allow_manage = false
local access_villager
local access_player

working_villages = {
	require = function(name)
		assert_equal(name, "log", "unexpected early module")
		return log
	end,
	can_manage_villager = function(villager, player)
		access_villager = villager
		access_player = player
		return allow_manage, allow_manage and "owner" or "not_owner"
	end,
	voxelibre_compat = {
		get_gui_bg = function() return "" end,
		get_gui_bg_img = function() return "" end,
		get_gui_slots = function() return "" end,
	},
	registered_jobs = {},
}

local forms = dofile(modpath .. "/forms.lua")
working_villages.forms = forms
working_villages.require = function(name)
	if name == "forms" then
		return forms
	end
	if name == "log" then
		return log
	end
	error("unexpected module " .. tostring(name))
end

local player = {
	get_player_name = function()
		return "alice"
	end,
}

local villager = {inventory_name = "villager:1", owner_name = "alice"}
local current_entity = villager
villager.object = {
	get_luaentity = function()
		return current_entity
	end,
	get_pos = function()
		return current_entity and {x = 1, y = 2, z = 3} or nil
	end,
}

forms.register_page("working_villages:talking_menu", {
	constructor = function() return "size[1,1]" end,
})

local public_calls = 0
forms.register_page("spec:public", {
	constructor = function() return "size[1,1]" end,
	receiver = function(_, target, sender)
		assert_equal(target, villager, "public target")
		assert_equal(sender, player, "public sender")
		public_calls = public_calls + 1
	end,
})

local private_calls = 0
forms.register_page("spec:private", {
	requires_manage = true,
	constructor = function() return "size[1,1]" end,
	receiver = function(_, target, sender)
		assert_equal(target, villager, "private target")
		assert_equal(sender, player, "private sender")
		private_calls = private_calls + 1
	end,
})

assert_equal(forms.show_formspec(villager, "spec:public", "alice"), true, "public form opens")
receive_fields(player, "spec:public_villager:1", {open = true})
assert_equal(public_calls, 1, "public dialogue remains callable")

assert_equal(forms.show_formspec(villager, "spec:private", "alice"), false,
	"private form denied before construction")
receive_fields(player, "spec:private_villager:1", {apply = true})
assert_equal(private_calls, 0, "forged private callback denied")
assert_equal(access_villager, villager, "access checks the resolved villager")
assert_equal(access_player, player, "callback access checks the actual sender")

allow_manage = true
assert_equal(forms.show_formspec(villager, "spec:private", "alice"), true, "managed form opens")
receive_fields(player, "spec:private_villager:1", {apply = true})
assert_equal(private_calls, 1, "managed callback accepted")

current_entity = nil
receive_fields(player, "spec:private_villager:1", {apply = true})
assert_equal(private_calls, 1, "removed villager callback rejected")
assert(messages[#messages].message:match("perime"), "stale callback gives feedback")

current_entity = villager
receive_fields(player, "spec:private_missing", {apply = true})
assert_equal(private_calls, 1, "unknown inventory identifier rejected")

local registered = working_villages.regisered_forms
for _, page_name in ipairs({
	"working_villages:job_change",
	"working_villages:data_change",
	"working_villages:inv_gui",
}) do
	assert(registered[page_name].requires_manage, page_name .. " must require management access")
end

working_villages.blueprints = {}
working_villages.blueprint_experiments = {}
working_villages.permissions = {}
working_villages.blueprint_construction = {}
dofile(modpath .. "/blueprint_forms.lua")
dofile(modpath .. "/guard_forms.lua")

for _, page_name in ipairs({
	"working_villages:blueprints_menu",
	"working_villages:learn_blueprints",
	"working_villages:improve_blueprints",
	"working_villages:experiments_blueprints",
	"working_villages:build_blueprints",
	"working_villages:permissions_menu",
	"working_villages:guard_config",
	"working_villages:guard_check",
}) do
	assert(registered[page_name].requires_manage, page_name .. " must require management access")
end

print("FORMS_ACCESS_SPEC_OK")
