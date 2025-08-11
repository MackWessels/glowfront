extends CharacterBody3D

@export var speed: float = 4.0
@export var acceleration: float = 18.0
@export var goal_radius: float = 0.6
@export var tile_board_path: NodePath

@export var max_speed: float = 6.0
@export var knockback_decay: float = 6.0
@export var knockback_max: float = 8.0

const ENTRY_RADIUS_DEFAULT: float = 0.20

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
			if dist > 0.0001:
				target_vel = to_entry.normalized() * speed
			_move_horiz_toward(target_vel, delta)
			return
	# END ENTRY

	# Goal check
	var goal_pos: Vector3 = _board.get_goal_position()
	if global_position.distance_to(goal_pos) <= goal_radius:
		queue_free()
		return

	# Flow-field drive
	var dir: Vector3 = _board.get_dir_for_world(global_position)
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

	# Decay knockback
	if _knockback.length() > 0.0:
		_knockback = _knockback.move_toward(Vector3.ZERO, knockback_decay * delta)

func _apply_y_lock() -> void:
	if _y_lock_enabled and _y_plane_set:
		if abs(global_position.y - _y_plane) > 0.0001:
			var p: Vector3 = global_position
			p.y = _y_plane
			global_position = p

# Knockback 
func apply_knockback_from(source_world: Vector3, force: float) -> void:
	# ignore during entry
	if _entry_active:
		return
	var dir: Vector3 = global_position - source_world
	dir.y = 0.0
	if dir.length() > 0.0001:
		dir = dir.normalized()
		_knockback += dir * force
		if _knockback.length() > knockback_max:
			_knockback = _knockback.normalized() * knockback_max

func apply_knockback_dir(direction_world: Vector3, force: float) -> void:
	if _entry_active:
		return
	var dir: Vector3 = direction_world
	dir.y = 0.0
	if dir.length() > 0.0001:
		dir = dir.normalized()
		_knockback += dir * force
		if _knockback.length() > knockback_max:
			_knockback = _knockback.normalized() * knockback_max
