class_name BotCheck
extends RefCounted
## Base class for bot assertion modules (WB0 split; WB8 owns the registry).
##
## The bot runner (client/scripts/bot.gd) globs `res://scripts/bot_checks/*.gd`,
## instantiates every BotCheck found and evaluates them. Each workbench adds its
## own `bot_check_<domain>.gd` and never edits the runner, so parallel branches
## never conflict on the assertion set.
##
## `evaluate()` returns an Array of result dictionaries:
##   {"order": int,           print order (keeps the historical output sequence)
##    "name": String,         the CHECK name
##    "ok": bool,
##    "required": bool,       true  -> prints OK/FAIL and gates the run verdict
##                            false -> prints OK/N/A and never fails the run
##    "detail": String}       optional "(...)" suffix

const MOVE_EPSILON := 1.0

## Set by the runner before evaluate() is called.
var bot


func evaluate() -> Array:
	return []
