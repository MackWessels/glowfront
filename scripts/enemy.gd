extends CharacterBody3D

@export var speed: float = 4.0
@export var acceleration: float = 18.0
@export var goal_radius: float = 0.6
@export var tile_board_path: NodePath

@export var max_speed: float = 6.0
@export var knockback_decay: float = 6.0
@export var knockback_max: float = 8.0

const ENTRY_RADIUS_DEFAULT: float = 0.20
const ENTRY_RADIUS_MIN: float = 0.01
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

	if tile_board_path != NodePath(""):
		var n := get_node_or_null(tile_board_path)
		if n:
			_board = n
		else:
			push_warning("Enemy: tile_board_path not found: %s" % [tile_board_path])

	if _y_lock_enabled and not _y_plane_set:
		_y_plane = global_position.y
		_y_plane_set = true

	add_to_group("enemy", true)


func set_paused(p: bool) -> void:
	_paused = p


func lock_y_to(y: float) -> void:
	_y_plane = y
	_y_plane_set = true
	_y_lock_enabled = true

	if abs(global_position.y - y) > EPS:
		var p := global_position
		p.y = y
		global_position = p

	if abs(velocity.y) > EPS:
		velocity.y = 0.0


func set_entry_point(p: Vector3) -> void:
	set_entry_target(p, ENTRY_RADIUS_DEFAULT)


func set_entry_target(p: Vector3, radius: float) -> void:
	if _y_lock_enabled and _y_plane_set:
		p.y = _y_plane

	_entry_point = p
	_entry_radius = max(ENTRY_RADIUS_MIN, radius)

	var to_entry := _entry_point - global_position
	to_entry.y = 0.0
	_entry_active = to_entry.length() > (_entry_radius + EPS)


func _physics_process(delta: float) -> void:
	# paused or no board
	if _paused or _board == null:
		velocity.x = 0.0
		velocity.z = 0.0
		if abs(velocity.y) > EPS:
			velocity.y = 0.0
		_apply_y_lock()
		move_and_slide()
		return

	# first frame only Y lock
	if _y_lock_enabled and not _y_plane_set:
		_y_plane = global_position.y
		_y_plane_set = true

	# take a small step into lane, then switch off
	if _entry_active:
		var to_entry := _entry_point - global_position
		to_entry.y = 0.0
		var r := _entry_radius + EPS
		if to_entry.length_squared() <= r * r:
			_entry_active = false
		else:
			var target_vel := Vector3.ZERO
			if to_entry.length_squared() > EPS * EPS:
				target_vel = to_entry.normalized() * speed
			_move_horizontal_toward(target_vel, delta)
			return

	# goal check
	var goal_pos: Vector3 = _board.get_goal_position()        
	var to_goal: Vector3 = goal_pos - global_position         
	to_goal.y = 0.0
	if to_goal.length_squared() <= goal_radius * goal_radius:
		queue_free()
		return

	# flow-field drive
	var dir := _get_flow_dir()
	var target_vel := Vector3.ZERO
	if dir != Vector3.ZERO:
		target_vel = dir * speed

	_move_horizontal_toward(target_vel, delta)


func _move_horizontal_toward(target_vel: Vector3, delta: float) -> void:
	# horizontal = steering + knockback
	var desired := Vector3(
		target_vel.x + _knockback.x,
		0.0,
		target_vel.z + _knockback.z
	)

	# Current horizontal
	var cur_h := Vector3(velocity.x, 0.0, velocity.z)

	# Accelerate toward target
	cur_h = cur_h.move_toward(desired, acceleration * delta)

	var max_sq := max_speed * max_speed
	var cur_sq := cur_h.length_squared()
	if cur_sq > max_sq and cur_sq > EPS * EPS:
		cur_h = cur_h * (max_speed / sqrt(cur_sq))

	velocity = Vector3(cur_h.x, 0.0, cur_h.z)

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
	var goal_pos: Vector3 = _board.get_goal_position()
	var goal_cell: Vector2i = _board.world_to_cell(goal_pos)

	# If outside known tiles, steer gently toward goal
	if not _board.tiles.has(pos):
		var v_out: Vector3 = goal_pos - global_position
		v_out.y = 0.0
		var L2: float = v_out.length_squared()
		if L2 > EPS * EPS:
			return v_out / sqrt(L2)
		return Vector3.ZERO

	# If we're on the goal cell, steer straight to the goal point
	if pos == goal_cell:
		var v_goal: Vector3 = goal_pos - global_position
		v_goal.y = 0.0
		var Lg2: float = v_goal.length_squared()
		if Lg2 > EPS * EPS:
			return v_goal / sqrt(Lg2)
		return Vector3.ZERO

	# If current cell is temporarily blue or not walkable, escape to best neighbor
	var standing_blocked: bool = bool(_board.closing.get(pos, false))
	if not standing_blocked:
		var tile := _board.tiles.get(pos) as Node
		if tile and tile.has_method("is_walkable"):
			standing_blocked = not tile.is_walkable()

	if standing_blocked:
		var best: Vector2i = pos
		var best_val: int = 1_000_000

		for o: Vector2i in _board.ORTHO_DIRS:
			var nb: Vector2i = pos + o
			if _board.cost.has(nb):
				var c: int = int(_board.cost[nb])
				if c < best_val:
					best_val = c
					best = nb

		if best != pos:
			var v2: Vector3 = _board.cell_to_world(best) - global_position
			v2.y = 0.0
			var L2b: float = v2.length_squared()
			if L2b > EPS * EPS:
				return v2 / sqrt(L2b)
		return Vector3.ZERO

	# Normal case: use precomputed flow-field direction
	var dir: Vector3 = _board.dir_field.get(pos, Vector3.ZERO)
	dir.y = 0.0
	var d2: float = dir.length_squared()
	if d2 > EPS * EPS:
		return dir / sqrt(d2)
	return Vector3.ZERO
