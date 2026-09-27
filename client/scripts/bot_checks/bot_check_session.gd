class_name BotCheckSession
extends BotCheck
## Session/account assertions: login, character list, world entry, local HP/name.

func evaluate() -> Array:
	return [
		{
			"order": 10, "name": "login", "required": true,
			"ok": bot._login_ok, "detail": "",
		},
		{
			"order": 20, "name": "character_list", "required": true,
			"ok": bot._list_received, "detail": "",
		},
		{
			"order": 30, "name": "enter_world", "required": true,
			"ok": bot._enter_world, "detail": "entity=%d" % bot._self_id,
		},
		{
			"order": 40, "name": "local_hp", "required": true,
			"ok": bot._self_hp > 0 and bot._self_max_hp == Protocol.PLAYER_MAX_HP,
			"detail": "%d/%d" % [bot._self_hp, bot._self_max_hp],
		},
		{
			"order": 50, "name": "local_name", "required": false,
			"ok": not bot._self_name.is_empty(), "detail": bot._self_name,
		},
	]
