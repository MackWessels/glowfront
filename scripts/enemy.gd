extends CharacterBody3D

@export var speed: float = 4.0
@export var acceleration: float = 18.0
@export var goal_radius: float = 0.6
@export var tile_board_path: NodePath

@export var max_speed: float = 6.0
@export var knockback_decay: float = 6.0
@export var knockback_max: float = 8.0

const ENTRY_RADIUS_DEFAULT: float = 0.20
const EPS: float = 0.0001

var _board: Node = null
var _knockback: Vector3 = Vector3.ZERO
var _paused: bool = false

var _y_lock_enabled: bool = true
var _y_plane: float = 0.0
var _y_plane_set: bool = false

var _entry_active: bool = false
var _entry_point: Vector3 = Vector3.ZERO
var _entry_radius: float = ENTRY_RADIUS_DEFAULT

func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	floor_snap_length = 0.0

	if has_node(tile_board_path):
		_board = get_node(tile_board_path)
	else:
		_board = null
	add_to_group("enemy")

func set_paused(p: bool) -> void:
	_paused = p

# Spawner will pin all enemies to the same Y plane
func lock_y_to(y: float) -> void:
	_y_plane = y
	_y_plane_set = true
	_y_lock_enabled = true
	var p: Vector3 = global_position
	p.y = _y_plane
	global_position = p

# allow passing just a point
func set_entry_point(p: Vector3) -> void:
	set_entry_target(p, ENTRY_RADIUS_DEFAULT)

# target + small radius
func set_entry_target(p: Vector3, radius: float) -> void:
	_entry_point = p
	_entry_radius = max(0.01, radius)
	_entry_active = true

func _physics_process(delta: float) -> void:
	if _paused:
		velocity = Vector3.ZERO
		_apply_y_lock()
		move_and_slide()
		return

	if _board == null:
		velocity = Vector3.ZERO
		_apply_y_lock()
		move_and_slide()
		return

	if _y_lock_enabled and not _y_plane_set:
		_y_plane = global_position.y
		_y_plane_set = true

	#  take a small step into the lane, then switch
	if _entry_active:
		var to_entry: Vector3 = _entry_point - global_position
		to_entry.y = 0.0
		var dist: float = to_entry.length()
		if dist <= _entry_radius:
			_entry_active = false
		else:
			var target_vel: Vector3 = Vector3.ZERO
			if dist > EPS:
				target_vel = to_entry.normalized() * speed
			_move_horiz_toward(target_vel, delta)
			return
	# END ENTRY

	# Goal check
	var goal_pos: Vector3 = _board.get_goal_position()
	if global_position.distance_to(goal_pos) <= goal_radius:
		queue_free()
		return

	# Flow-field drive (from board data)
	var dir: Vector3 = _get_flow_dir()
	var target_vel: Vector3 = Vector3.ZERO
	if dir != Vector3.ZERO:
		target_vel = dir * speed
	target_vel.y = 0.0

	_move_horiz_toward(target_vel, delta)

func _move_horiz_toward(target_vel: Vector3, delta: float) -> void:
	var desired: Vector3 = target_vel + _knockback
	desired.y = 0.0

	var cur_h: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	cur_h = cur_h.move_toward(desired, acceleration * delta)
	if cur_h.length() > max_speed:
		cur_h = cur_h.normalized() * max_speed

	velocity.x = cur_h.x
	velocity.z = cur_h.z
	velocity.y = 0.0

	_apply_y_lock()
	move_and_slide()

func _apply_y_lock() -> void:
	if _y_lock_enabled and _y_plane_set:
		if abs(global_position.y - _y_plane) > EPS:
			var p: Vector3 = global_position
			p.y = _y_plane
			global_position = p


func _get_flow_dir() -> Vector3:
	# Safety
	if _board == null:
		return Vector3.ZERO

	# Current cell & goal cell
	var pos: Vector2i = _board.world_to_cell(global_position)
	var goal_cell: Vector2i = _board.world_to_cell(_board.get_goal_position())

	# If we're on the goal cell, steer straight to the goal point
	if pos == goal_cell:
		var v_goal: Vector3 = _board.get_goal_position() - global_position
		v_goal.y = 0.0
		var Lg: float = v_goal.length()
		if Lg > EPS:
			return v_goal / Lg
		return Vector3.ZERO

	# If current cell is temporarily blue or not walkable, try to escape to best neighbor
	var standing_blocked: bool = bool(_board.closing.get(pos, false)) or not _board.tiles[pos].is_walkable()
	if standing_blocked:
		var best: Vector2i = pos
		var best_val: int = 1000000
		for o in _board.ORTHO_DIRS:
			var nb: Vector2i = pos + o
			if _board.cost.has(nb):
				var c: int = int(_board.cost[nb])
				if c < best_val:
					best_val = c
					best = nb
		if best != pos:
			var v2: Vector3 = _board.cell_to_world(best) - global_position
			v2.y = 0.0
			var L2: float = v2.length()
			if L2 > EPS:
				return v2 / L2
		return Vector3.ZERO

	# Normal case: use precomputed flow-field direction
	return _board.dir_field.get(pos, Vector3.ZERO)
