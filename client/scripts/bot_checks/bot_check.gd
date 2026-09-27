class_name BotCheck
extends RefCounted
## Base class for bot assertion modules (WB0 split; WB8 owns the registry).
##
## The bot runner (client/scripts/bot.gd) globs `res://scripts/bot_checks/*.gd`,
## instantiates every BotCheck found and evaluates them. Each workbench adds its
## own `bot_check_<domain>.gd` (e.g. bot_check_combat.gd, bot_check_inventory.gd)
## and never edits the runner, so parallel branches never conflict on the
## assertion set. Discovery is automatic: drop the file in and it runs.
##
## Module contract:
##   * `extends BotCheck` (class_name);
##   * read state from `bot` (set by the runner before evaluate()).
##
## `evaluate()` returns an Array of result dictionaries:
##   {"order": int,           print order (keeps the historical output sequence)
##    "name": String,         the CHECK name
##    "ok": bool,
##    "required": bool,       true  -> prints OK/FAIL and gates the run verdict
##                            false -> prints OK/N/A and never fails the run
##    "detail": String}       optional "(...)" suffix
##
## FROZEN (WB8/CI depend on it): the `[bot] CHECK <name>=OK|FAIL|N/A` and
## `[bot] RESULT PASS|FAIL` output lines and the process exit codes (0 pass,
## 1 fail). Do not change their format; add assertions, not output shapes.

const MOVE_EPSILON := 1.0

## Set by the runner before evaluate() is called.
var bot


func evaluate() -> Array:
	return []
