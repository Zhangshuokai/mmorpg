class_name Protocol
extends RefCounted
## Single source of truth for the wire protocol.
##
## This file is shared verbatim by the client and the server project through the
## `res://shared` directory junction (see scripts/link_shared.ps1). Never fork it.

# --- Networking -------------------------------------------------------------
const SERVER_PORT := 7000
const DEFAULT_HOST := "127.0.0.1"
const MAX_CLIENTS := 16
const PROTOCOL_VERSION := 1

# --- World tick -------------------------------------------------------------
const TICK_HZ := 20
const TICK_DT := 0.05

# --- Gameplay placeholders (single class / single skill / single mob) -------
const MOVE_SPEED := 5.0
const WORLD_BOUNDS := 60.0
const SPAWN_POINT := Vector3(0.0, 1.0, 0.0)

## Static map shared by both ends (server builds collision, client builds visuals).
const MAP_HALF := 30.0
const COVER_SIZE := Vector3(2.0, 2.0, 2.0)
const COVER_POSITIONS: Array[Vector3] = [
	Vector3(6.0, 0.0, 6.0),
	Vector3(-8.0, 0.0, 4.0),
	Vector3(3.0, 0.0, -9.0),
	Vector3(-5.0, 0.0, -12.0),
]

const PLAYER_MAX_HP := 100
const PLAYER_RADIUS := 0.4
const PLAYER_RESPAWN_SEC := 5.0
const MELEE_RANGE := 3.0
const MELEE_DAMAGE := 20
const MELEE_COOLDOWN := 1.0

const MOB_MAX_HP := 60
const MOB_DAMAGE := 5
const MOB_SPEED := 2.5
const MOB_ATTACK_RANGE := 2.0
const MOB_ATTACK_COOLDOWN := 2.0
const MOB_AGGRO_RANGE := 14.0
const MOB_RESPAWN_SEC := 8.0
const MOB_COUNT := 3
## Mob entity ids live in a reserved range so they never collide with peer ids.
const MOB_ID_BASE := 1000000

const SAVE_INTERVAL_SEC := 10.0

## Client-side interpolation speed (higher = snappier, less smooth).
const INTERP_SPEED := 12.0

# --- Account / character name rules (shared by client pre-checks and server) --
const USER_MIN := 3
const USER_MAX := 16
const PASS_MIN := 4
const NAME_MIN := 2
const NAME_MAX := 12

# --- Enums ------------------------------------------------------------------
enum EntityKind { PLAYER = 0, MOB = 1 }
enum ClassId { WARRIOR = 0 }
enum Buttons { NONE = 0, ATTACK = 1 }

## Stable logical ids for logging/debug overlays. Informational only: the wire
## contract is RPC_NAMES below (Machine-checked by scripts/link_shared.ps1 -Verify).
enum Msg {
	INPUT = 0,
	USE_ABILITY,
	LIST_CHARACTERS,
	CREATE_CHARACTER,
	SELECT_CHARACTER,
	LOGIN_RESULT,
	CHARACTER_LIST,
	ENTER_WORLD,
	SPAWN_ENTITY,
	DESPAWN_ENTITY,
	WORLD_STATE,
	COMBAT_EVENT,
	HP_UPDATE,
}

## The single source of truth for the wire contract: every RPC that must exist,
## exactly once, in shared/net/net_rpc.gd.
## scripts/link_shared.ps1 -Verify fails when this list, the declared functions
## and the "no @rpc outside net_rpc.gd" rule disagree.
const RPC_NAMES: Array[String] = [
	"c2s_input",
	"c2s_use_ability",
	"c2s_list_characters",
	"c2s_create_character",
	"c2s_select_character",
	"s2c_login_result",
	"s2c_character_list",
	"s2c_enter_world",
	"s2c_spawn_entity",
	"s2c_despawn_entity",
	"s2c_world_state",
	"s2c_combat_event",
	"s2c_hp_update",
]

# --- Auth payload keys (credentials travel via auth_callback, never via RPC) -
const AUTH_USER := "user"
const AUTH_PASS := "pass"
const AUTH_REGISTER := "register"
const AUTH_PROTOCOL := "protocol"

## Builds the auth payload.
##
## SECURITY: ENet/UDP used by Godot's high-level multiplayer is NOT encrypted, so
## the password below travels in cleartext. This MVP is explicitly LAN /
## trusted-network only (see AGENTS.md, "安全边界"). Before any public exposure,
## replace plaintext with a challenge-response handshake (server nonce + salted
## proof) or move to an encrypted transport.
static func auth_payload(username: String, password: String, register: bool) -> PackedByteArray:
	return JSON.stringify({
		AUTH_USER: username,
		AUTH_PASS: password,
		AUTH_REGISTER: register,
		AUTH_PROTOCOL: PROTOCOL_VERSION,
	}).to_utf8_buffer()
