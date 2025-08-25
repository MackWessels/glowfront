extends CharacterBody3D
class_name Enemy

# ===================== Movement (stable, zero-jitter) =====================
@export var speed: float = 3.0
@export var turn_speed_deg: float = 540.0
@export var tile_board_path: NodePath
@export var goal_node_path: NodePath

# How close to the next edge (in tiles) we allow movement before stopping if it's blocked
@export var stop_margin_tiles: float = 0.25

# ===================== Signals =====================
signal died
signal cell_changed(old_cell: Vector2i, new_cell: Vector2i)

# ===================== Internal refs =====================
var _board: Node = null
var _goal: Node3D = null

# ===================== Y lock =====================
var _y_lock_enabled: bool = true
var _y_plane: float = 0.0
func lock_y_to(y: float) -> void:
	_y_plane = y
	_y_lock_enabled = true

# ===================== Segment following (center -> center) =====================
var _cur_cell: Vector2i = Vector2i(-9999, -9999)
var _next_cell: Vector2i = Vector2i(-9999, -9999)

var _a: Vector3 = Vector3.ZERO     # start (center of current cell or current pos if waiting)
var _b: Vector3 = Vector3.ZERO     # target (center of next cell)
var _v: Vector3 = Vector3.ZERO
var _L: float = 0.0
var _tangent: Vector3 = Vector3.FORWARD

var _s: float = 0.0                # distance along [0, _L]
var _tile_w: float = 1.0
var _stop_margin_world: float = 0.2

# Waiting near an edge because the planned next cell became blocked
var _waiting_at_edge: bool = false

# Path-change debounce (we still ignore mid-segment route changes)
@export var path_change_cooldown: float = 0.12
var _path_change_timer: float = 0.0
var _pending_path_change: bool = false

# ===================== Optional first step into board =====================
var _entry_active: bool = false
var _entry_target: Vector3 = Vector3.ZERO
@export var _entry_radius: float = 0.4

# ===================== Lifecycle =====================
func _ready() -> void:
	add_to_group("enemy")

	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	floor_snap_length = 0.0

	# Resolve references
	if tile_board_path != NodePath(""):
		_board = get_node_or_null(tile_board_path)
	if goal_node_path != NodePath(""):
		_goal = get_node_or_null(goal_node_path) as Node3D
	elif _board != null:
		var g: Variant = _board.get("goal_node")
		if typeof(g) == TYPE_OBJECT and g != null and g is Node3D:
			_goal = g

	# Cache tile size
	if _board and _board.has_method("tile_world_size"):
		_tile_w = float(_board.call("tile_world_size"))
	else:
		var tv: Variant = 1.0
		if _board:
			tv = _board.get("tile_size")
		_tile_w = float(tv) if (typeof(tv) == TYPE_FLOAT or typeof(tv) == TYPE_INT) else 1.0

	_stop_margin_world = maxf(0.05, stop_margin_tiles * _tile_w)

	if _y_lock_enabled:
		_y_plane = global_position.y

	# Listen for path changes (we’ll only act at boundaries / wait state)
	if _board and _board.has_signal("global_path_changed"):
		_board.connect("global_path_changed", Callable(self, "_on_board_changed"))

	_init_segment(true)

func reset_for_spawn() -> void:
	_init_segment(true)

func set_entry_target(p: Vector3, radius: float) -> void:
	_entry_target = p
	_entry_radius = maxf(0.05, radius)
	_entry_active = true

# ===================== Helpers =====================
func _apply_y_lock(p: Vector3) -> Vector3:
	if _y_lock_enabled: p.y = _y_plane
	return p

func _board_cell_of_pos(p: Vector3) -> Vector2i:
	if _board and _board.has_method("world_to_cell"):
		return _board.call("world_to_cell", p)
	return Vector2i(0, 0)

func _cell_center(c: Vector2i) -> Vector3:
	if _board and _board.has_method("cell_center"):
		return _board.call("cell_center", c)
	elif _board and _board.has_method("cell_to_world"):
		return _board.call("cell_to_world", c)
	return Vector3.ZERO

func _goal_cell() -> Vector2i:
	if _board and _board.has_method("_goal_cell"):
		return _board.call("_goal_cell")
	return _board_cell_of_pos(_goal.global_position) if _goal else _board_cell_of_pos(global_position)

func _next_from(c: Vector2i) -> Vector2i:
	if _board and _board.has_method("next_cell_from"):
		return _board.call("next_cell_from", c)
	return c

func _cell_blocked(c: Vector2i) -> bool:
	if _board == null: return false
	if _board.has_method("is_cell_reserved") and bool(_board.call("is_cell_reserved", c)):
		return true
	if _board.has_method("is_cell_walkable"):
		return not bool(_board.call("is_cell_walkable", c))
	if _board.has_method("_tile_is_walkable"):
		return not bool(_board.call("_tile_is_walkable", c))
	return false

func _rebuild_segment(new_start_from_current_pos: bool) -> void:
	if new_start_from_current_pos:
		_a = _apply_y_lock(global_position)
	else:
		_a = _cell_center(_cur_cell)
	_b = _cell_center(_next_cell)
	_v = _b - _a
	_v.y = 0.0
	_L = _v.length()
	_tangent = (_v / _L) if _L > 0.0001 else Vector3.FORWARD
	# project s from current pos to avoid snaps
	var rel: Vector3 = _apply_y_lock(global_position) - _a
	rel.y = 0.0
	_s = clampf(rel.dot(_tangent), 0.0, _L)

# ===================== Segment build =====================
func _init_segment(fresh_spawn: bool) -> void:
	_pending_path_change = false
	_path_change_timer = 0.0
	_waiting_at_edge = false
	if _board == null: return

	_cur_cell = _board_cell_of_pos(global_position)
	_next_cell = _next_from(_cur_cell)
	_rebuild_segment(false)

# ===================== Physics =====================
func _physics_process(delta: float) -> void:
	# cooldown
	if _path_change_timer > 0.0:
		_path_change_timer = maxf(0.0, _path_change_timer - delta)

	# Optional first step into the board
	if _entry_active:
		var vstep: Vector3 = _entry_target - global_position
		vstep.y = 0.0
		var Ls: float = vstep.length()
		if Ls <= _entry_radius:
			_entry_active = false
			_init_segment(false)
		else:
			var step_entry: float = minf(speed * delta, Ls)
			if step_entry > 0.0001:
				global_position = _apply_y_lock(global_position + (vstep / Ls) * step_entry)
			_update_facing_toward(vstep, delta)
			velocity = Vector3.ZERO
			return

	# If waiting at edge, poll for a new valid next cell and start from current pos
	if _waiting_at_edge:
		var new_next: Vector2i = _next_from(_cur_cell)
		if new_next != _next_cell and not _cell_blocked(new_next):
			_next_cell = new_next
			_rebuild_segment(true)   # start new segment from where we are
			_waiting_at_edge = false
		else:
			# face intended direction while waiting
			_update_facing_toward(_tangent, delta)
			velocity = Vector3.ZERO
			return

	# Normal advance toward edge
	if _L <= 0.0001:
		_advance_to_next_segment()
		velocity = Vector3.ZERO
		return

	var remaining: float = speed * delta
	var take: float = minf(remaining, _L - _s)
	_s += take

	# Position update
	var desired: Vector3 = _a + _tangent * _s
	global_position = _apply_y_lock(desired)
	_update_facing_toward(_tangent, delta)

	# Stop-line guard: if next cell got blocked, stop short of edge and wait
	if (_L - _s) <= _stop_margin_world and _cell_blocked(_next_cell):
		_s = maxf(_L - _stop_margin_world, 0.0)  # clamp back to stop line
		global_position = _apply_y_lock(_a + _tangent * _s)
		_waiting_at_edge = true
		velocity = Vector3.ZERO
		return

	# Reached edge?
	if _s >= _L - 0.00001:
		if _next_cell == _goal_cell():
			_on_reach_goal()
			return
		_advance_to_next_segment()

	velocity = Vector3.ZERO

# ===================== Advance to next segment =====================
func _advance_to_next_segment() -> void:
	var old_c: Vector2i = _cur_cell
	var new_c: Vector2i = _next_cell
	if old_c != new_c:
		emit_signal("cell_changed", old_c, new_c)

	_cur_cell = _next_cell
	_next_cell = _next_from(_cur_cell)  # adopt latest path ONLY at boundary
	_rebuild_segment(false)

	# tiny nudge to avoid exact endpoints
	if _L > 0.0 and _s <= 0.0:
		_s = minf(0.0005, _L * 0.05)

	_pending_path_change = false
	_waiting_at_edge = false

# ===================== Path-change handler =====================
func _on_board_changed() -> void:
	if _board == null: return
	# debounce
	if _path_change_timer > 0.0:
		_pending_path_change = true
		return
	_path_change_timer = path_change_cooldown

	# We do not re-route mid-segment anymore.
	# If the planned next cell is blocked we’ll get caught by the stop-line guard
	# and wait for a new next cell at the boundary.
	_pending_path_change = true

# ===================== Facing =====================
func _update_facing_toward(dir_or_vec: Vector3, delta: float) -> void:
	var v: Vector3 = dir_or_vec
	if v.length_squared() < 1e-8: return
	var desired_fwd: Vector3 = v.normalized()
	var current_fwd: Vector3 = -global_transform.basis.z
	current_fwd.y = 0.0
	if current_fwd.length_squared() <= 1e-8:
		current_fwd = Vector3.FORWARD
	var angle: float = current_fwd.signed_angle_to(desired_fwd, Vector3.UP)
	var max_step: float = deg_to_rad(turn_speed_deg) * delta
	angle = clampf(angle, -max_step, max_step)
	rotate_y(angle)

# ===================== Goal =====================
func _on_reach_goal() -> void:
	emit_signal("died")
	queue_free()
