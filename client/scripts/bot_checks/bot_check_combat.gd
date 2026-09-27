class_name BotCheckCombat
extends BotCheck
## Combat/kill/respawn assertions (WB2 owns extending this domain).

func evaluate() -> Array:
	var multiplayer_only: bool = bot.multiplayer_only
	var respawn_required: bool = bot.require_respawn
	return [
		{
			"order": 80, "name": "combat_event", "required": not multiplayer_only,
			"ok": bot._combat_seen, "detail": "dealt %d damage" % bot._damage_dealt,
		},
		{
			"order": 90, "name": "mob_kill", "required": not multiplayer_only,
			"ok": bot._kill_seen, "detail": "",
		},
		{
			"order": 100, "name": "mob_respawn", "required": respawn_required,
			"ok": bot._respawn_seen, "detail": "",
		},
		{
			"order": 110, "name": "took_damage", "required": false,
			"ok": bot._damage_taken > 0, "detail": "%d damage taken" % bot._damage_taken,
		},
	]
