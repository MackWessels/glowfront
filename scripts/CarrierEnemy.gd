extends "res://scripts/enemy.gd"
class_name CarrierEnemy

# ---------- Carrier config ----------
@export var minion_scene: PackedScene

@export var hover_offset: float = 0.6            # carrier floats above ground by this much
@export var drop_every_tiles: float = 1.5         # spacing between drops (in tiles)
@export var minions_per_drop: int = 1
@export var max_drops: int = 6

# Per-tile crowding protection
@export var max_per_tile: int = 3
@export var search_radius_tiles: int = 2

# Within-tile spawn jitter (in tile space)
@export var drop_spread: float = 0.35

# Visual landing time and tiny lift to avoid z-fighting/sinking
@export var landing_time: float = 0.20
@export var landing_nudge_y: float = 0.01         # world units

# Optional node that marks the drop hole on the carrier
@export var hole_path: NodePath = NodePath("Hole")

@export var debug_drops: bool = false

# ---------- Internals ----------
var _hole: Node3D = null
var _spawner: Node = null
var _tile_board: Node = null

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

var _accum_dist_world: float = 0.0
var _spacing_world: float = 1.0
var _drops_done: int = 0
var _cell_counts: Dictionary = {}    # Vector2i -> int

# =====================================================================
# Lifecycle
# =====================================================================
func _ready() -> void:
	_rng.randomize()

	# base Enemy wires board/goal/pathing
	super._ready()

	_tile_board = _board
	_hole = get_node_or_null(hole_path) as Node3D

	# hover above path
	lock_y_to(_y_plane + hover_offset)

	# distance between drops in world units
	_spacing_world = maxf(0.25 * _tile_w, drop_every_tiles * _tile_w)

func set_spawner(sp: Node) -> void:
	_spawner = sp
	if super.has_method("set_spawner"):
		super.set_spawner(sp)

# =====================================================================
# Movement hook: after base moves, accumulate distance and drop
# =====================================================================
func _physics_process(delta: float) -> void:
	var prev: Vector3 = global_position
	super._physics_process(delta)

	var moved: float = Vector2(global_position.x - prev.x, global_position.z - prev.z).length()
	if moved > 0.0:
		_accum_dist_world += moved
		if _accum_dist_world >= _spacing_world:
			_accum_dist_world = 0.0
			_try_drop()

# =====================================================================
# Drop logic
# =====================================================================
func _try_drop() -> void:
	if minion_scene == null or _drops_done >= max_drops:
		return

	# World position we're above (hole if present)
	var drop_from: Vector3 = _hole.global_position if _hole != null else global_position

	# Prefer the cell directly under the hole
	var target_cell: Vector2i = _world_to_cell_safe(drop_from)

	var candidate_v: Variant = _find_valid_drop_cell(target_cell)
	if candidate_v == null:
		if debug_drops:
			print("[Carrier] skip drop; no free cell near ", target_cell)
		return
	var candidate_cell: Vector2i = candidate_v

	# Use the board’s cell-center Y as the ground — no hover math, no raycast.
	var center: Vector3 = _cell_to_world_center(candidate_cell)
	var ground_y: float = center.y + landing_nudge_y

	var spawned: int = 0
	for i in range(minions_per_drop):
		if _spawn_one_minion(center, ground_y):
			spawned += 1
		else:
			break

	if spawned > 0:
		_drops_done += 1
		_increment_cell(candidate_cell, spawned)
		if debug_drops:
			print("[Carrier] dropped ", spawned, " at cell=", candidate_cell,
				  " ground_y=", ground_y, " total=", _drops_done, "/", max_drops)

# Spawn one minion starting at hole height, then land it to the tile
func _spawn_one_minion(center: Vector3, ground_y: float) -> bool:
	# jitter within tile
	var r: float = drop_spread * _tile_w * 0.5
	var jx: float = _rng.randf_range(-r, r)
	var jz: float = _rng.randf_range(-r, r)

	# start at the hole height (or hover height above ground as fallback)
	var start_y: float = _hole.global_position.y if _hole != null else (ground_y + hover_offset)
	var start_pos: Vector3 = Vector3(center.x + jx, start_y, center.z + jz)
	var start_xf: Transform3D = Transform3D(Basis.IDENTITY, start_pos)

	# Prefer the spawner hook so caps & accounting stay centralized
	if _spawner != null and _spawner.has_method("request_child_spawn"):
		var child: Node = _spawner.request_child_spawn(minion_scene, start_xf, true, ["carrier"])
		if child == null:
			return false

		# Smooth land to ground, then re-lock Y (implemented in Enemy.gd)
		if child.has_method("land_from_drop"):
			child.land_from_drop(ground_y, landing_time)
		else:
			# Fallback: manually tween Y then lock
			if child is Node3D:
				if child.has_method("unlock_y"):
					child.unlock_y()
				var c3: Node3D = child as Node3D
				var tw := create_tween()
				tw.tween_property(c3, "global_position:y", ground_y, landing_time)\
					.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
				tw.tween_callback(func ():
					if is_instance_valid(child) and child.has_method("lock_y_to"):
						child.lock_y_to(ground_y))
		return true

	# ---- Fallback (no spawner): local instantiate & land ----
	var e: Node = minion_scene.instantiate()
	if e == null:
		return false
	if _tile_board != null and e.has_method("set_tile_board"):
		e.set_tile_board(_tile_board)
	if _spawner != null and e.has_method("set_spawner"):
		e.set_spawner(_spawner)

	var e3: Node3D = e as Node3D
	if e3 == null:
		return false
	e3.global_position = start_pos
	add_child(e)

	# Save collision state OUTSIDE the if-block so the tween callback can see it
	var had_collision: bool = false
	var saved_layer: int = 0
	var saved_mask: int = 0
	if e is CollisionObject3D:
		had_collision = true
		var co: CollisionObject3D = e as CollisionObject3D
		saved_layer = co.collision_layer
		saved_mask = co.collision_mask
		co.collision_layer = 0
		co.collision_mask = 0

	if e.has_method("unlock_y"):
		e.unlock_y()

	var tw2 := create_tween()
	tw2.tween_property(e3, "global_position:y", ground_y, landing_time)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw2.tween_callback(func ():
		if is_instance_valid(e):
			if had_collision:
				var co2: CollisionObject3D = e as CollisionObject3D
				co2.collision_layer = saved_layer
				co2.collision_mask = saved_mask
			if e.has_method("lock_y_to"):
				e.lock_y_to(ground_y))
	return true

# =====================================================================
# Board helpers
# =====================================================================
func _world_to_cell_safe(p: Vector3) -> Vector2i:
	if _tile_board and _tile_board.has_method("world_to_cell"):
		return _tile_board.call("world_to_cell", p)
	# fall back to base helper
	return _board_cell_of_pos(p)

func _cell_to_world_center(c: Vector2i) -> Vector3:
	if _tile_board and _tile_board.has_method("cell_center"):
		return _tile_board.call("cell_center", c)
	elif _tile_board and _tile_board.has_method("cell_to_world"):
		return _tile_board.call("cell_to_world", c)
	# last resort: assume flat grid at our hover plane
	return Vector3(c.x * _tile_w, _y_plane - hover_offset, c.y * _tile_w)

func _count_at(c: Vector2i) -> int:
	return int(_cell_counts.get(c, 0))

func _increment_cell(c: Vector2i, by: int = 1) -> void:
	_cell_counts[c] = _count_at(c) + max(1, by)

func _find_valid_drop_cell(target: Vector2i) -> Variant:
	# direct cell first
	if _count_at(target) < max_per_tile:
		return target
	# search neighborhood
	for r in range(1, max(1, search_radius_tiles) + 1):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var c := Vector2i(target.x + dx, target.y + dz)
				if _count_at(c) < max_per_tile:
					return c
	return null
