class_name SpatialGrid
extends RefCounted
## Uniform-grid spatial partition of the authoritative entity set (S-N-4).
##
## The grid is a pure index: it is rebuilt once per world tick from
## WorldState.entities and never integrates movement itself (WB4 must not
## duplicate the maths WorldMovement/WorldMobs already ran). Queries are used to
## find the entities inside a player's AoI circle.
##
## Cells are keyed on the horizontal (XZ) plane because the map is a flat plane
## and vertical offset is irrelevant for visibility.

var cell_size: float = Protocol.AOI_GRID_CELL

var _cells: Dictionary = {}      ## Vector2i cell -> Array[int] entity ids
var _cell_of: Dictionary = {}    ## entity id -> Vector2i cell
var _pos: Dictionary = {}        ## entity id -> Vector3 (position at insert)


func _init(p_cell_size: float = Protocol.AOI_GRID_CELL) -> void:
	cell_size = maxf(0.001, p_cell_size)


func clear() -> void:
	_cells.clear()
	_cell_of.clear()
	_pos.clear()


func size() -> int:
	return _cell_of.size()


## One-pass rebuild; called by WorldSync at the start of every broadcast tick.
func rebuild(entities: Dictionary) -> void:
	clear()
	for id: int in entities.keys():
		var e: EntityState = entities[id]
		_put(id, e.pos)


func insert(id: int, pos: Vector3) -> void:
	remove(id)
	_put(id, pos)


func remove(id: int) -> void:
	if not _cell_of.has(id):
		return
	var key: Vector2i = _cell_of[id]
	_cell_of.erase(id)
	_pos.erase(id)
	var bucket: Array = _cells.get(key, [])
	bucket.erase(id)
	if bucket.is_empty():
		_cells.erase(key)
	else:
		_cells[key] = bucket


func cell_of(pos: Vector3) -> Vector2i:
	return Vector2i(
		int(floor(pos.x / cell_size)),
		int(floor(pos.z / cell_size)))


## Ids in every cell whose AABB overlaps the circle's bounding box. Not distance
## filtered: use query_circle() for exact AoI membership.
func query_radius(center: Vector3, radius: float) -> Array[int]:
	var out: Array[int] = []
	if _cells.is_empty():
		return out
	var min_x := int(floor((center.x - radius) / cell_size))
	var max_x := int(floor((center.x + radius) / cell_size))
	var min_z := int(floor((center.z - radius) / cell_size))
	var max_z := int(floor((center.z + radius) / cell_size))
	for cx in range(min_x, max_x + 1):
		for cz in range(min_z, max_z + 1):
			var bucket: Variant = _cells.get(Vector2i(cx, cz))
			if bucket != null:
				for id: int in bucket:
					out.append(id)
	return out


## Exact AoI membership on the horizontal plane, using the positions captured at
## rebuild time (the authoritative positions for this tick).
func query_circle(center: Vector3, radius: float) -> Array[int]:
	var out: Array[int] = []
	var r2 := radius * radius
	for id: int in query_radius(center, radius):
		var p: Vector3 = _pos[id]
		var dx := p.x - center.x
		var dz := p.z - center.z
		if dx * dx + dz * dz <= r2:
			out.append(id)
	return out


## Position of an indexed entity at the last insert/rebuild; Vector3.ZERO when the
## id is unknown.
func position_of(id: int) -> Vector3:
	return _pos.get(id, Vector3.ZERO)


func _put(id: int, pos: Vector3) -> void:
	var key := cell_of(pos)
	_cell_of[id] = key
	_pos[id] = pos
	var bucket: Array = _cells.get(key, [])
	bucket.append(id)
	_cells[key] = bucket
