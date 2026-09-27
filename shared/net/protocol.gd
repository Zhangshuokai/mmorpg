class_name Protocol
extends RefCounted
## Single source of truth for the wire protocol.
##
## This file is shared verbatim by the client and the server project through the
## `res://shared` directory junction (see scripts/link_shared.ps1). Never fork it.
##
## WB0 froze this surface so the parallel workbenches can rely on stable ids,
## bounds and RPC signatures. Only ids and boundaries belong here: gameplay
## *values* move to shared/data/tables/*.json (S-D-3, owned by WB1). If a future
## workbench needs a new constant/RPC, it goes through the contract-change
## protocol in the plan (three places in lockstep + link_shared.ps1 -Verify).

# --- Networking -------------------------------------------------------------
const SERVER_PORT := 7000
const DEFAULT_HOST := "127.0.0.1"
const MAX_CLIENTS := 16
## Bumped to 2 by WB0 (auth v2 keys + prediction ack). This branch is NOT
## wire-compatible with the old v1 clients; version negotiation is S-E-3 (P1).
const PROTOCOL_VERSION := 2

# --- World tick -------------------------------------------------------------
const TICK_HZ := 20
const TICK_DT := 0.05

# --- Gameplay placeholders (single class / single skill / single mob) -------
## NOTE (S-D-3): these concrete numbers are legacy and will migrate to
## shared/data/tables/*.json in WB1. WB0 added only ids/bounds below; it did not
## move existing values, so server behaviour stays identical.
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

# --- Zones / channels / instances (S-N-7) -----------------------------------
## Stable logical zone ids. Map layouts live in shared/data/tables/zones.json.
enum ZoneId { WORLD = 1 }
const ZONE_DEFAULT := ZoneId.WORLD
## Persisted zone key stored in characters.zone (kept in sync with ZoneId).
const ZONE_KEY_WORLD := "world"
const CHANNEL_DEFAULT := 0
const ZONE_MAX_CHANNELS := 8
## Instance ids are reserved above the mob range so they never collide with
## peer ids or mob ids.
const INSTANCE_ID_BASE := 2000000
const ZONE_MAX_INSTANCES := 64

# --- Interest management / bandwidth (S-N-4, S-N-5) -------------------------
## Visibility radius used by the server's spatial grid (WB4).
const AOI_RADIUS := 40.0
const AOI_GRID_CELL := 16.0
## Hard ceiling on the serialized entity array of one s2c_world_state packet.
const PACKET_BUDGET_BYTES := 1200
## Base priority weight handed to an entity that has never been sent.
const BROADCAST_PRIORITY_BASE := 1.0

# --- Abilities / combat (S-G-1, S-G-2) --------------------------------------
## Ability ids. Damage/cooldown/range numbers live in abilities.json (WB2).
enum AbilityId { MELEE = 0 }
## Target selector kinds (how an ability picks its target).
enum TargetType { NONE = 0, SELF = 1, ENEMY = 2, ALLY = 3, POSITION = 4 }
const ABILITY_MAX_TARGETS := 8
## Bounds only; the concrete per-ability values are data-table driven.
const GCD_MAX_SEC := 5.0
const ABILITY_RANGE_MAX := 60.0
const COOLDOWN_MAX_SEC := 3600.0

# --- Items / inventory / equipment (S-G-5) ----------------------------------
enum ItemKind { NONE = 0, WEAPON = 1, ARMOR = 2, CONSUMABLE = 3, MISC = 4 }
enum EquipSlot {
	MAIN_HAND = 0,
	OFF_HAND = 1,
	HEAD = 2,
	CHEST = 3,
	LEGS = 4,
	FEET = 5,
}
const EQUIP_SLOT_COUNT := 6
const INVENTORY_SLOTS := 40
const INVENTORY_SLOTS_MAX := 80
const BAG_COUNT_MAX := 4
const ITEM_STACK_MAX := 999

# --- Character attributes / progression (S-G-2, S-G-7) ----------------------
enum Stat { STRENGTH = 0, AGILITY = 1, STAMINA = 2, INTELLECT = 3 }
const STAT_COUNT := 4
const LEVEL_MIN := 1
const LEVEL_MAX := 60

# --- Persistence / schema (S-D-1) -------------------------------------------
## Bumped whenever the migration chain changes. server/scripts/migrations.gd
## owns the chain and its reserved sequence ranges.
const DB_SCHEMA_VERSION := 1

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
	MOVE_ITEM,
	EQUIP_ITEM,
	UNEQUIP_ITEM,
	CHANGE_ZONE,
	LOGIN_RESULT,
	CHARACTER_LIST,
	ENTER_WORLD,
	SPAWN_ENTITY,
	DESPAWN_ENTITY,
	WORLD_STATE,
	COMBAT_EVENT,
	HP_UPDATE,
	INPUT_ACK,
	INVENTORY,
	ZONE_CHANGED,
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
	"c2s_move_item",
	"c2s_equip_item",
	"c2s_unequip_item",
	"c2s_change_zone",
	"s2c_login_result",
	"s2c_character_list",
	"s2c_enter_world",
	"s2c_spawn_entity",
	"s2c_despawn_entity",
	"s2c_world_state",
	"s2c_combat_event",
	"s2c_hp_update",
	"s2c_input_ack",
	"s2c_inventory",
	"s2c_zone_changed",
]

# --- Auth payload keys (credentials travel via auth_callback, never via RPC) -
## v1 (cleartext, dev/LAN only). Kept so the current handshake keeps working.
const AUTH_USER := "user"
const AUTH_PASS := "pass"
const AUTH_REGISTER := "register"
const AUTH_PROTOCOL := "protocol"
## v2 challenge-response keys (S-E-1, implemented by WB7). WB0 only freezes the
## key names; the password-mode handshake above is still what runs today.
const AUTH_VERSION := "v"
const AUTH_MODE := "mode"
const AUTH_NONCE := "nonce"
const AUTH_PROOF := "proof"
const AUTH_SALT := "salt"
const AUTH_MODE_PASSWORD := "password"
const AUTH_MODE_PROOF := "proof"

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
