class_name BotCheckMovement
extends BotCheck
## Movement/replication assertions (WB6 owns extending this domain).

func evaluate() -> Array:
	var remote_required: bool = bot.require_remote
	return [
		{
			"order": 60, "name": "movement", "required": true,
			"ok": bot._moved >= MOVE_EPSILON, "detail": "moved %.2fm" % bot._moved,
		},
		{
			"order": 70, "name": "world_state_ticks", "required": true,
			"ok": bot._ticks > 0, "detail": "%d ticks" % bot._ticks,
		},
		{
			"order": 120, "name": "remote_player_moved", "required": remote_required,
			"ok": bot._remote_travel >= MOVE_EPSILON, "detail": "%.2fm" % bot._remote_travel,
		},
	]
