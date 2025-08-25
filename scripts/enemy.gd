extends CharacterBody3D
class_name Enemy

# ========= Conveyor movement =========
@export var speed: float = .5

@export var accel: float = 22.0
@export var turn_speed_deg: float = 540.0

# Lane variety (cosmetic lateral bias)
@export var lane_spread_tiles: float = 0.35
@export_range(0.0, 1.0, 0.01) var lane_bias_strength: float = 0.6
@export var num_lanes: int = 0                 # 0=continuous, >=2 quantizes
@export var lane_jitter_tiles: float = 0.06

# Refs
@export var tile_board_path: NodePath
@export var goal_node_path: NodePath

# ===== Signals =====
signal died
signal cell_changed(old_cell: Vector2i, new_cell: Vector2i)

# ===== Internals =====
var _board: Node = null
var _goal: Node3D = null
var _tile_w: float = 1.0
var _y_plane: float = 0.0

var _cur_cell: Vector2i = Vector2i(-9999, -9999)
var _planned_next: Vector2i = Vector2i(-9999, -9999)
var _tile_target: Vector3 = Vector3.ZERO      # where to go inside the planned_next tile
var _tile_tangent: Vector3 = Vector3.FORWARD  # for facing

var _lane_signature: float = 0.0              # per-enemy [-1,1]
var _needs_replan: bool = false               # set on board change

# Optional entry glide from edge/pen
var _entry_active: bool = false
var _entry_target: Vector3 = Vector3.ZERO
@export var _entry_radius: float = 0.4

# ===================== Lifecycle =====================
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

	if _board and _board.has_method("tile_world_size"):
		_tile_w = float(_board.call("tile_world_size"))
	else:
		var tv: Variant = _board.get("tile_size") if _board else 1.0
		_tile_w = float(tv) if (typeof(tv) == TYPE_FLOAT or typeof(tv) == TYPE_INT) else 1.0

	_y_plane = global_position.y
	_lane_signature = randf_range(-1.0, 1.0)

	if _board and _board.has_signal("global_path_changed"):
		_board.connect("global_path_changed", Callable(self, "_on_board_changed"))

	velocity = Vector3.ZERO
	_cur_cell = _board_cell_of_pos(global_position)
	_plan_from_cell(_cur_cell)  # initial plan

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

# ===================== Helpers =====================
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

func _goal_cell() -> Vector2i:
	if _board and _board.has_method("_goal_cell"):
		return _board.call("_goal_cell")
	return _board_cell_of_pos(_goal.global_position) if _goal else _board_cell_of_pos(global_position)

func _next_from(c: Vector2i) -> Vector2i:
	return _board.call("next_cell_from", c) if (_board and _board.has_method("next_cell_from")) else c

# small hash for deterministic per-tile jitter
func _hash2f(c: Vector2i) -> float:
	var h: int = int(c.x) * 374761393 + int(c.y) * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	var u: float = float(h & 0x7fffffff) / float(0x7fffffff)
	return u * 2.0 - 1.0

func _quantize_lane(x: float, max_off: float) -> float:
	if num_lanes >= 2:
		var span: float = 2.0 * max_off
		var step: float = span / float(num_lanes - 1)
		var idx: int = int(round((x + max_off) / step))
		var q: float = float(idx) * step - max_off
		return clampf(q, -max_off, max_off)
	return x

func _max_lane_abs() -> float:
	return minf(_tile_w * 0.45, lane_spread_tiles * _tile_w)

# Re-plan from the current cell. Called on tile entry, and whenever board says flow changed.
func _plan_from_cell(c: Vector2i) -> void:
	var n: Vector2i = _next_from(c)
	_planned_next = n

	# Goal cell? head to its center then despawn
	if n == c:
		_tile_target = _cell_center(_goal_cell())
		_tile_tangent = (_tile_target - global_position).normalized()
		return

	var a := _cell_center(c)
	var b := _cell_center(n)
	var d := b - a
	d.y = 0.0
	var L := d.length()
	var tan := (d / L) if L > 0.0001 else Vector3.FORWARD
	var perp := Vector3(-tan.z, 0.0, tan.x)

	# choose a lateral offset for *this tile* (stable + varied)
	var max_off := _max_lane_abs()
	var lane := lane_bias_strength * _lane_signature * max_off
	lane += _hash2f(c) * (lane_jitter_tiles * _tile_w)
	lane = _quantize_lane(clampf(lane, -max_off, max_off), max_off)

	_tile_target = b + perp * lane
	_tile_tangent = tan
	_needs_replan = false

func _accelerate_toward(v: Vector3, target_v: Vector3, a: float, dt: float) -> Vector3:
	var dv := target_v - v
	var max_dv := a * dt
	if dv.length() > max_dv:
		dv = dv.normalized() * max_dv
	return v + dv

# ===================== Physics =====================
func _physics_process(delta: float) -> void:
	# Optional entry glide
	if _entry_active:
		var to_target: Vector3 = _entry_target - global_position
		to_target.y = 0.0
		var L := to_target.length()
		if L <= _entry_radius:
			_entry_active = false
			velocity = Vector3.ZERO
		else:
			var tv := to_target / maxf(L, 0.0001) * speed
			velocity = _accelerate_toward(velocity, tv, accel, delta)
			_update_facing_toward(velocity, delta)
			velocity.y = 0.0
			move_and_slide()
			global_position = _apply_y_lock(global_position)
			_emit_cell_if_changed()
			return

	# If board said paths changed while we are *still in this tile*, re-plan for this tile.
	if _needs_replan:
		_plan_from_cell(_cur_cell)

	# If board’s suggested exit for this tile changed since last frame, re-plan.
	var live_next := _next_from(_cur_cell)
	if live_next != _planned_next:
		_plan_from_cell(_cur_cell)

	# Steer toward the current tile target
	var seek := _tile_target - global_position
	seek.y = 0.0
	var dist := seek.length()

	# If we’re very close to the target and that target belongs to _planned_next, let the cell change drive a new plan.
	if dist > 0.01:
		var tv_main := (seek / dist) * speed
		velocity = _accelerate_toward(velocity, tv_main, accel, delta)

	# Face motion
	_update_facing_toward(velocity, delta)

	# Slide on plane
	velocity.y = 0.0
	move_and_slide()
	global_position = _apply_y_lock(global_position)

	# If we entered a new cell, emit + plan from it
	_emit_cell_if_changed()

func _emit_cell_if_changed() -> void:
	var new_cell := _board_cell_of_pos(global_position)
	if new_cell != _cur_cell:
		var old := _cur_cell
		_cur_cell = new_cell
		emit_signal("cell_changed", old, new_cell)
		_plan_from_cell(_cur_cell)   # <<< re-plan every tile entry

# ===================== Facing =====================
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
	angle = clampf(angle, -max_step, max_step)
	rotate_y(angle)

# ===================== Board change =====================
func _on_board_changed() -> void:
	# Don’t snap mid-tile; just request a re-plan for the current tile on next physics step.
	_needs_replan = true

# ===================== Goal =====================
func _on_reach_goal() -> void:
	emit_signal("died")
	queue_free()
