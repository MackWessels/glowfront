extends Enemy
class_name CarrierEnemy

# ============================ Config ============================
# What the carrier drops
@export var minion_scene: PackedScene

# Distance between drops (in tiles)
@export var drop_every_tiles: float = 2.0
# Random X/Z jitter inside the target tile (in tiles)
@export var drop_jitter_tiles: float = 0.35
# Optional cap (<=0 = unlimited)
@export var max_drops: int = 0

# Carrier hover above the path (as a fraction of tile width)
@export var carrier_hover_frac: float = 0.25

# How much to raise the *surface* above the tile cell-center if the board
# doesn't expose a surface offset (as a fraction of tile width).
@export var tile_surface_frac: float = 0.02

# Where the “hole” is on the carrier (used both for visual drop start and turret aim)
@export var hole_path: NodePath

# Toggle to prefer asking the spawner to instantiate (so it can do caps / bookkeeping)
@export var use_spawner_hook: bool = true

# Debug
@export var debug_drops: bool = false


# ============================ Internal ==========================
var _rng := RandomNumberGenerator.new()
var _hole: Node3D = null
var _spawner: Node = null

var _spacing_world: float = 1.0
var _accum_dist_world: float = 0.0
var _last_pos: Vector3 = Vector3.ZERO
var _drops_done: int = 0

# Cached board alias (for readability)
var _tile_board: Node = null

# ============================ Lifecycle =========================
func _ready() -> void:
	_rng.randomize()
	super._ready()

	_tile_board = _board  # inherited from Enemy
	_hole = get_node_or_null(hole_path) as Node3D
	var t := get_node_or_null("Target") as Node3D

	# Let the base-class aim API target the hole (turrets will aim there)
	# Enemy.gd must expose `aim_marker_path` and `get_aim_point()`.
	aim_marker_path = t.get_path()

	# Hover a bit above the path
	lock_y_to(_y_plane + carrier_hover_frac * _tile_w)

	# “Tiles to meters”
	_spacing_world = maxf(0.25 * _tile_w, drop_every_tiles * _tile_w)

	_last_pos = global_position

	# Helpful tag for prioritizing carriers (optional; turrets may read this)
	set_meta(&"spawn_tags", ["carrier"])

# Spawner wiring (called from EnemySpawner when it instantiates us)
func set_spawner(sp: Node) -> void:
	_spawner = sp
	if super.has_method("set_spawner"):
		super.set_spawner(sp)

# Optional if you want to override via script before play
func set_minion_scene(ps: PackedScene) -> void:
	minion_scene = ps

# ============================ Physics ===========================
func _physics_process(delta: float) -> void:
	# Move like a normal Enemy
	super._physics_process(delta)

	# Distance accumulation since last frame; drop at fixed spacing
	var now := global_position
	var moved := (now - _last_pos).length()
	_last_pos = now

	_accum_dist_world += moved
	while _accum_dist_world >= _spacing_world:
		_accum_dist_world -= _spacing_world
		_try_drop()

# ============================ Drop logic ========================
func _try_drop() -> void:
	if minion_scene == null:
		return
	if max_drops > 0 and _drops_done >= max_drops:
		return
	if _tile_board == null:
		return

	# Decide which world position to evaluate (hole center preferred)
	var drop_from: Vector3 = global_position
	if _hole != null:
		drop_from = _hole.global_position

	# Choose the tile directly under the hole (or the carrier)
	var target_cell: Vector2i = _world_to_cell_safe(drop_from)

	# You can insert occupancy checks here if your board exposes them
	# e.g., if not _is_cell_free_for_spawn(target_cell): return

	# Center of that cell
	var center: Vector3 = _cell_to_world_center(target_cell)

	# Compute proper surface height (lift above cell center)
	var ground_y: float = _surface_y(center.y)

	if _spawn_one_minion(center, ground_y):
		_drops_done += 1
		if debug_drops:
			print("[Carrier] dropped at cell=", target_cell, " (total=", _drops_done, ")")

func _spawn_one_minion(center: Vector3, ground_y: float) -> bool:
	if minion_scene == null:
		return false

	# Small jitter inside the tile so they don't stack perfectly
	var r := drop_jitter_tiles * _tile_w * 0.5
	var jx := _rng.randf_range(-r, r)
	var jz := _rng.randf_range(-r, r)

	# Start at the hole height (visibly inside the carrier), else just above ground
	var start_y: float = ground_y + maxf(0.05 * _tile_w, carrier_hover_frac * 0.5 * _tile_w)
	if _hole != null:
		start_y = _hole.global_position.y

	var start_pos := Vector3(center.x + jx, start_y, center.z + jz)
	var start_xf := Transform3D(Basis.IDENTITY, start_pos)

	var child: Node3D = null

	# Prefer spawner hook so caps & wave accounting stay centralized
	if use_spawner_hook and _spawner != null and _spawner.has_method("request_child_spawn"):
		child = _spawner.request_child_spawn(minion_scene, start_xf, true, ["carrier"]) as Node3D
	else:
		# Local fallback (not ideal for caps/accounting but works if spawner lacks the hook)
		var e := minion_scene.instantiate()
		if e == null:
			return false
		child = e as Node3D
		add_child(child)
		# Try to pass references the way the spawner would
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

	# Soft land to the exact surface Y, then lock Y to it
	if child.has_method("land_from_drop"):
		child.call("land_from_drop", ground_y, 0.18)
	elif child.has_method("lock_y_to"):
		child.call("lock_y_to", ground_y)
	else:
		# Last resort: forcibly set the Y
		child.global_position = Vector3(child.global_position.x, ground_y, child.global_position.z)

	return true

# ============================ Helpers ===========================
# Convert a world position to a cell using whatever the board exposes
func _world_to_cell_safe(p: Vector3) -> Vector2i:
	if _tile_board and _tile_board.has_method("world_to_cell"):
		return _tile_board.call("world_to_cell", p)
	return Vector2i.ZERO

# Get the visual center of a cell using whatever the board exposes
func _cell_to_world_center(c: Vector2i) -> Vector3:
	if _tile_board and _tile_board.has_method("cell_center"):
		return _tile_board.call("cell_center", c)
	if _tile_board and _tile_board.has_method("cell_to_world"):
		return _tile_board.call("cell_to_world", c)
	return Vector3.ZERO

# Lift from cell center to visible tile *surface* Y
func _surface_y(center_y: float) -> float:
	var off := 0.0
	# Prefer a precise offset if the board exposes one
	if _tile_board != null:
		var v: Variant = _tile_board.get("tile_surface_offset_y")
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			off = float(v)
	# Fallback: small fraction of tile width
	if off == 0.0:
		off = tile_surface_frac * _tile_w
	return center_y + off
