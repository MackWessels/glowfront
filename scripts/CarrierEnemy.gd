extends Enemy
class_name CarrierEnemy

# ============================ Config ============================
@export var minion_scene: PackedScene
@export var drop_every_tiles: float = 2.0
@export var drop_jitter_tiles: float = 0.35
@export var max_drops: int = 0
@export var carrier_hover_frac: float = 0.25
@export var tile_surface_frac: float = 0.02
@export var hole_path: NodePath
@export var use_spawner_hook: bool = true
@export var debug_drops: bool = false

# ============================ Internal ==========================
var _rng := RandomNumberGenerator.new()
var _hole: Node3D = null
var _spawner: Node = null
var _spacing_world: float = 1.0
var _accum_dist_world: float = 0.0
var _last_pos: Vector3 = Vector3.ZERO
var _drops_done: int = 0
var _tile_board: Node = null

# ============================ Lifecycle =========================
func _ready() -> void:
	_rng.randomize()
	super._ready()

	_tile_board = _board
	_hole = get_node_or_null(hole_path) as Node3D
	var t := get_node_or_null("Target") as Node3D

	aim_marker_path = t.get_path()
	lock_y_to(_y_plane + carrier_hover_frac * _tile_w)
	_spacing_world = maxf(0.25 * _tile_w, drop_every_tiles * _tile_w)
	_last_pos = global_position
	set_meta(&"spawn_tags", ["carrier"])

func set_spawner(sp: Node) -> void:
	_spawner = sp
	if super.has_method("set_spawner"):
		super.set_spawner(sp)

func set_minion_scene(ps: PackedScene) -> void:
	minion_scene = ps

# ============================ Physics ===========================
func _physics_process(delta: float) -> void:
	super._physics_process(delta)

	var now := global_position
	var moved := (now - _last_pos).length()
	_last_pos = now

	_accum_dist_world += moved
	while _accum_dist_world >= _spacing_world:
		_accum_dist_world -= _spacing_world
		_try_drop()

# ============================ Drop logic ========================
func _try_drop() -> void:
	if minion_scene == null: return
	if max_drops > 0 and _drops_done >= max_drops: return
	if _tile_board == null: return

	var drop_from: Vector3 = global_position
	if _hole != null:
		drop_from = _hole.global_position

	var target_cell: Vector2i = _world_to_cell_safe(drop_from)
	var center: Vector3 = _cell_to_world_center(target_cell)
	var ground_y: float = _surface_y(center.y)

	if _spawn_one_minion(center, ground_y):
		_drops_done += 1
		if debug_drops:
			print("[Carrier] dropped at cell=", target_cell, " (total=", _drops_done, ")")

func _spawn_one_minion(center: Vector3, ground_y: float) -> bool:
	if minion_scene == null:
		return false

	var r: float = drop_jitter_tiles * _tile_w * 0.5
	var jx: float = _rng.randf_range(-r, r)
	var jz: float = _rng.randf_range(-r, r)

	# Base position from hole if present, else tile center
	var base_x: float = center.x
	var base_z: float = center.z
	if _hole != null:
		base_x = _hole.global_position.x
		base_z = _hole.global_position.z

	# Start height: hole.y if present
	var start_y: float = ground_y + maxf(0.05 * _tile_w, carrier_hover_frac * 0.5 * _tile_w)
	if _hole != null:
		start_y = _hole.global_position.y

	# Use hole ROTATION only (avoid inheriting its scale)
	var start_basis := Basis.IDENTITY
	if _hole != null:
		start_basis = Basis(_hole.global_transform.basis.get_rotation_quaternion())
	var world_offset := start_basis * Vector3(jx, 0.0, jz)

	var start_pos := Vector3(base_x, start_y, base_z) + world_offset
	var start_xf := Transform3D(start_basis, start_pos)

	var child: Node3D = null

	if use_spawner_hook and _spawner != null and _spawner.has_method("request_child_spawn"):
		child = _spawner.request_child_spawn(minion_scene, start_xf, true, ["carrier"]) as Node3D
	else:
		var e := minion_scene.instantiate()
		if e == null:
			return false
		child = e as Node3D
		add_child(child)
		child.global_transform = start_xf
		# Minimal wiring (unchanged)
		if _tile_board != null and child.has_method("set_tile_board"):
			child.call("set_tile_board", _tile_board)
		elif _tile_board != null and child.has("tile_board_path"):
			child.set("tile_board_path", _tile_board.get_path())
		var g: Variant = null
		if _tile_board != null:
			g = _tile_board.get("goal_node")
		if typeof(g) == TYPE_OBJECT and g != null and g is Node3D and child.has("goal_node_path"):
			child.set("goal_node_path", (g as Node3D).get_path())

	if child == null:
		return false

	if child.has_method("land_from_drop"):
		child.call("land_from_drop", ground_y, 0.18)
	elif child.has_method("lock_y_to"):
		child.call("lock_y_to", ground_y)
	else:
		child.global_position = Vector3(child.global_position.x, ground_y, child.global_position.z)

	return true

# ============================ Helpers ===========================
func _world_to_cell_safe(p: Vector3) -> Vector2i:
	if _tile_board and _tile_board.has_method("world_to_cell"):
		return _tile_board.call("world_to_cell", p)
	return Vector2i.ZERO

func _cell_to_world_center(c: Vector2i) -> Vector3:
	if _tile_board and _tile_board.has_method("cell_center"):
		return _tile_board.call("cell_center", c)
	if _tile_board and _tile_board.has_method("cell_to_world"):
		return _tile_board.call("cell_to_world", c)
	return Vector3.ZERO

func _surface_y(center_y: float) -> float:
	var off := 0.0
	if _tile_board != null:
		var v: Variant = _tile_board.get("tile_surface_offset_y")
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			off = float(v)
	if off == 0.0:
		off = tile_surface_frac * _tile_w
	return center_y + off
