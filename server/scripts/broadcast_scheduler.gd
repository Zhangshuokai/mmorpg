class_name BroadcastScheduler
extends RefCounted
## Per-peer priority accumulator + per-packet byte budget (S-N-5).
##
## Every world tick each visible entity becomes a candidate carrying its encoded
## size in bytes and a priority weight. `select()` adds the weight to the
## entity's accumulated priority, then greedily takes the highest-accumulated
## candidates while the packet stays within Protocol.PACKET_BUDGET_BYTES.
##
## Selected entities reset their accumulator; skipped ones keep it, so they
## outrank fresher candidates on the following ticks and are guaranteed eventual
## delivery instead of starving behind a permanently busy neighbourhood.

var budget_bytes: int = Protocol.PACKET_BUDGET_BYTES
var base_weight: float = Protocol.BROADCAST_PRIORITY_BASE

## peer_id -> { entity_id -> accumulated priority }
var _acc: Dictionary = {}


func set_budget(bytes: int) -> void:
	budget_bytes = bytes


## Adds each candidate's weight to its accumulator and returns the ids to send.
##
## `items`: Array of Dictionary with keys:
##     "id"    (int)   entity id,
##     "size"  (int)   encoded payload size in bytes,
##     "weight"(float) optional per-tick priority weight (defaults to
##                     base_weight).
## `reserve_bytes`: fixed envelope cost (tick + empty array header) charged
##     before any entity bytes.
## `mandatory`: ids that must be included regardless of budget (the peer's own
##     player must never be dropped); their bytes are charged first.
func select(peer_id: int, items: Array, reserve_bytes: int = 0, mandatory: Array = []) -> Array[int]:
	var acc: Dictionary = _acc.get(peer_id, {})
	for item: Dictionary in items:
		var id := int(item["id"])
		var weight := float(item.get("weight", base_weight))
		acc[id] = float(acc.get(id, 0.0)) + weight

	var must: Dictionary = {}
	for id: int in mandatory:
		must[id] = true

	# Highest accumulated priority first; id breaks ties so the order is stable.
	var order: Array = items.duplicate()
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa := float(acc.get(int(a["id"]), 0.0))
		var pb := float(acc.get(int(b["id"]), 0.0))
		if not is_equal_approx(pa, pb):
			return pa > pb
		return int(a["id"]) < int(b["id"]))

	var selected: Array[int] = []
	var used := reserve_bytes
	for item: Dictionary in order:
		var id := int(item["id"])
		if must.has(id):
			used += int(item["size"])
			selected.append(id)
	for item: Dictionary in order:
		var id := int(item["id"])
		if must.has(id):
			continue
		var size := int(item["size"])
		if used + size > budget_bytes:
			continue
		used += size
		selected.append(id)
		acc[id] = 0.0
	for id: int in mandatory:
		acc[id] = 0.0

	_acc[peer_id] = acc
	return selected


## Drops accumulated priority for one entity (left AoI / despawned).
func forget(peer_id: int, id: int) -> void:
	var acc: Dictionary = _acc.get(peer_id)
	if acc != null:
		acc.erase(id)


## Drops all accumulator state for a peer (disconnect).
func drop_peer(peer_id: int) -> void:
	_acc.erase(peer_id)


func accumulated(peer_id: int, id: int) -> float:
	var acc: Dictionary = _acc.get(peer_id)
	if acc == null:
		return 0.0
	return float(acc.get(id, 0.0))
