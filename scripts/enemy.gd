extends CharacterBody3D
class_name Enemy

# Movement
@export var speed: float = 2.0
@export var accel: float = 22.0
@export var turn_speed_deg: float = 540.0

# Lanes 
@export var lane_spread_tiles: float = 0.35
@export_range(0.0, 1.0, 0.01) var lane_bias_strength: float = 0.6
@export var num_lanes: int = 0
@export var lane_jitter_tiles: float = 0.06

# Refs
@export var tile_board_path: NodePath
@export var goal_node_path: NodePath

signal died

var _board: Node = null
var _goal: Node3D = null
var _tile_w: float = 1.0
var _y_plane: float = 0.0

var _cur_cell: Vector2i = Vector2i(-9999, -9999)
var _planned_next: Vector2i = Vector2i(-9999, -9999)
var _planned_next_is_offgrid := false
var _tile_target: Vector3 = Vector3.ZERO

var _lane_signature: float = 0.0
var _needs_replan := false

# Optional entry glide
var _entry_active := false
var _entry_target: Vector3 = Vector3.ZERO
@export var _entry_radius: float = 0.4

func _ready() -> void:
	add_to_group("enemy")
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	floor_snap_length = 0.0

	if tile_board_path != NodePath(""):
		_board = get_node_or_null(tile_board_path)
	if goal_node_path != NodePath(""):
		_goal = get_node_or_null(goal_node_path) as Node3D
	elif _board != null:
		var g: Variant = _board.get("goal_node")
		if typeof(g) == TYPE_OBJECT and g != null and g is Node3D:
			_goal = g

	_tile_w = _get_tile_w()
	_y_plane = global_position.y
	_lane_signature = randf_range(-1.0, 1.0)

	if _board and _board.has_signal("global_path_changed"):
		_board.connect("global_path_changed", Callable(self, "_on_board_changed"))

	velocity = Vector3.ZERO
	_cur_cell = _board_cell_of_pos(global_position)
	_plan_from_cell(_cur_cell)

func reset_for_spawn() -> void:
	velocity = Vector3.ZERO
	_lane_signature = randf_range(-1.0, 1.0)
	_cur_cell = _board_cell_of_pos(global_position)
	_plan_from_cell(_cur_cell)
	_entry_active = false

func set_entry_target(p: Vector3, radius: float) -> void:
	_entry_target = p
	_entry_radius = maxf(0.05, radius)
	_entry_active = true

# ---------- helpers ----------
func _apply_y_lock(p: Vector3) -> Vector3:
	p.y = _y_plane
	return p

func _board_cell_of_pos(p: Vector3) -> Vector2i:
	return _board.call("world_to_cell", p) if (_board and _board.has_method("world_to_cell")) else Vector2i.ZERO

func _cell_center(c: Vector2i) -> Vector3:
	if _board and _board.has_method("cell_center"):
		return _board.call("cell_center", c)
	elif _board and _board.has_method("cell_to_world"):
		return _board.call("cell_to_world", c)
	return Vector3.ZERO

func _next_from(c: Vector2i) -> Vector2i:
	return _board.call("next_cell_from", c) if (_board and _board.has_method("next_cell_from")) else c

func _is_offgrid_cell(c: Vector2i) -> bool:
	if _board and _board.has_method("is_in_bounds"):
		return not bool(_board.call("is_in_bounds", c))
	# fallback if board helper not present
	var sx: int = int(_board.get("board_size_x")) if _board else 0
	var sz: int = int(_board.get("board_size_z")) if _board else 0
	return c.x < 0 or c.y < 0 or c.x >= sx or c.y >= sz

func _hash2f(c: Vector2i) -> float:
	var h: int = int(c.x) * 374761393 + int(c.y) * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return (float(h & 0x7fffffff) / float(0x7fffffff)) * 2.0 - 1.0

func _quantize_lane(x: float, max_off: float) -> float:
	if num_lanes >= 2:
		var span := 2.0 * max_off
		var step := span / float(num_lanes - 1)
		var idx: int = int(round((x + max_off) / step))
		return clampf(float(idx) * step - max_off, -max_off, max_off)
	return x

func _max_lane_abs() -> float:
	return minf(_tile_w * 0.45, lane_spread_tiles * _tile_w)

# Plan one tile ahead (supports off-grid eject)
func _plan_from_cell(c: Vector2i) -> void:
	var n := _next_from(c)
	_planned_next = n
	_planned_next_is_offgrid = _is_offgrid_cell(n)

	var a := _cell_center(c)
	var b := _cell_center(n)
	var d := b - a; d.y = 0.0
	var L := d.length()
	var tan := (d / L) if L > 0.0001 else Vector3.FORWARD
	var perp := Vector3(-tan.z, 0.0, tan.x)

	var max_off := _max_lane_abs()
	var lane := lane_bias_strength * _lane_signature * max_off
	lane += _hash2f(c) * (lane_jitter_tiles * _tile_w)
	lane = _quantize_lane(clampf(lane, -max_off, max_off), max_off)

	_tile_target = b + perp * lane
	_needs_replan = false

func _accelerate_toward(v: Vector3, target_v: Vector3, a: float, dt: float) -> Vector3:
	var dv := target_v - v
	var max_dv := a * dt
	if dv.length() > max_dv:
		dv = dv.normalized() * max_dv
	return v + dv

# ---------- physics ----------
func _physics_process(delta: float) -> void:
	# optional entry glide
	if _entry_active:
		var to_target := _entry_target - global_position
		to_target.y = 0.0
		var L := to_target.length()
		if L <= _entry_radius:
			_entry_active = false
			velocity = Vector3.ZERO
		else:
			var tv := (to_target / maxf(L, 0.0001)) * speed
			velocity = _accelerate_toward(velocity, tv, accel, delta)
			_update_facing_toward(velocity, delta)
			velocity.y = 0.0
			move_and_slide()
			global_position = _apply_y_lock(global_position)
			_update_cell_and_replan()
			return

	if _needs_replan:
		_plan_from_cell(_cur_cell)

	var live_next := _next_from(_cur_cell)
	if live_next != _planned_next:
		_plan_from_cell(_cur_cell)

	var seek := _tile_target - global_position
	seek.y = 0.0
	var dist := seek.length()

	# off-grid eject reached -> despawn
	if _planned_next_is_offgrid and dist <= maxf(_tile_w * 0.25, 0.1):
		_on_reach_goal()
		return

	if dist > 0.01:
		var tv_main := (seek / dist) * speed
		velocity = _accelerate_toward(velocity, tv_main, accel, delta)

	_update_facing_toward(velocity, delta)

	velocity.y = 0.0
	move_and_slide()
	global_position = _apply_y_lock(global_position)
	_update_cell_and_replan()

func _update_cell_and_replan() -> void:
	var new_cell := _board_cell_of_pos(global_position)
	if new_cell != _cur_cell:
		_cur_cell = new_cell
		_plan_from_cell(_cur_cell)

# ---------- facing ----------
func _update_facing_toward(dir_or_vec: Vector3, delta: float) -> void:
	var v := dir_or_vec; v.y = 0.0
	if v.length_squared() < 1e-8:
		return
	var desired_fwd := v.normalized()
	var current_fwd: Vector3 = -global_transform.basis.z
	current_fwd.y = 0.0
	if current_fwd.length_squared() <= 1e-8:
		current_fwd = Vector3.FORWARD
	var angle := current_fwd.signed_angle_to(desired_fwd, Vector3.UP)
	var max_step := deg_to_rad(turn_speed_deg) * delta
	rotate_y(clampf(angle, -max_step, max_step))

# ---------- board change ----------
func _on_board_changed() -> void:
	_needs_replan = true

# ---------- goal ----------
func _on_reach_goal() -> void:
	emit_signal("died")
	queue_free()

# ---------- small helper ----------
func _get_tile_w() -> float:
	if _board and _board.has_method("tile_world_size"):
		return float(_board.call("tile_world_size"))
	var tv: Variant = _board.get("tile_size") if _board else 1.0
	return float(tv) if (typeof(tv) == TYPE_FLOAT or typeof(tv) == TYPE_INT) else 1.0
