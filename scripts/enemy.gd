extends CharacterBody3D

#  movement 
@export var speed: float = 2.0
@export var acceleration: float = 15.0
@export var max_speed: float = 6.0
@export var goal_radius: float = 0.6
@export var tile_board_path: NodePath
@export var knockback_decay: float = 6.0
@export var knockback_max: float = 8.0
@export var turn_speed_deg: float = 540.0        # NEW: yaw turn rate

# identity
@export var is_elite: bool = false               # NEW: elite tag

# health 
@export var max_health: int = 3
var health: int = 0
signal died

# entry step targeting 
const ENTRY_RADIUS_DEFAULT: float = 0.20
const ENTRY_RADIUS_MIN: float = 0.01
const EPS: float = 0.0001

# entry fail-safes 
@export var entry_abort_timeout: float = 1.00     
@export var entry_stuck_speed: float = 0.05        
@export var entry_stuck_duration: float = 0.25   
@export var entry_abort_on_collision: bool = true  

# state 
var _board: Node = null
var _knockback: Vector3 = Vector3.ZERO
var _paused: bool = false
var _dead: bool = false

# Y-plane lock
var _y_lock_enabled: bool = true
var _y_plane: float = 0.0
var _y_plane_set: bool = false

# spawn / entry step
var _entry_active: bool = false
var _entry_point: Vector3 = Vector3.ZERO
var _entry_radius: float = ENTRY_RADIUS_DEFAULT

# entry tracking
var _entry_elapsed: float = 0.0
var _entry_stuck_t: float = 0.0
var _entry_prev_dist: float = 1e9

#  entry ghosting 
var _ghost_until_entry: bool = false
var _saved_layer: int = 0
var _saved_mask: int = 0

# health bar 
const _HB_SIZE: Vector2   = Vector2(0.6, 0.08)
const _HB_OFFSET_Y: float = 0.9
var _hb_root: Node3D = null
var _hb_bar: MeshInstance3D = null

func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	floor_snap_length = 0.0

	# init health
	health = max_health

	if tile_board_path != NodePath(""):
		var n := get_node_or_null(tile_board_path)
		if n:
			_board = n
		else:
			push_warning("Enemy: tile_board_path not found: %s" % [tile_board_path])

	if _y_lock_enabled and not _y_plane_set:
		_y_plane = global_position.y
		_y_plane_set = true

	add_to_group("enemies", true)
	if is_elite:
		add_to_group("elite_enemies", true)   # NEW
	_build_healthbar()

func set_paused(p: bool) -> void:
	_paused = p

# damage / death 
func take_damage(amount: int) -> void:
	if _dead:
		return
	health -= amount
	if health <= 0:
		_die()
	else:
		_update_healthbar()

func _die() -> void:
	if _dead:
		return
	_dead = true
	emit_signal("died")
	queue_free()

#  helpers 
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
	# snap target to our y-plane if locked
	if _y_lock_enabled and _y_plane_set:
		p.y = _y_plane

	# clamp radius
	if radius < ENTRY_RADIUS_MIN:
		radius = ENTRY_RADIUS_MIN

	_entry_point = p
	_entry_radius = radius

	# decide if we need an entry step
	if not is_inside_tree():
		_entry_active = true
	else:
		var to_entry: Vector3 = _entry_point - global_position
		to_entry.y = 0.0
		var r: float = _entry_radius + EPS
		_entry_active = to_entry.length_squared() > r * r

	# reset entry trackers
	_entry_elapsed = 0.0
	_entry_stuck_t = 0.0
	_entry_prev_dist = 1e9

# called by spawner right after set_entry_target
func ghost_until_entry() -> void:
	_ghost_until_entry = true
	_saved_layer = collision_layer
	_saved_mask  = collision_mask
	collision_layer = 0
	collision_mask  = 0

func _restore_collision_if_ghosting() -> void:
	if _ghost_until_entry:
		_ghost_until_entry = false
		collision_layer = _saved_layer
		collision_mask  = _saved_mask

# optional: used by spawner between spawns
func reset_for_spawn() -> void:
	_paused = false
	_dead = false
	velocity = Vector3.ZERO
	_knockback = Vector3.ZERO

	# restore HP to new max
	health = max_health
	_update_healthbar()

	# do not change ghost flags here, spawner may set them right after

func _physics_process(delta: float) -> void:
	if _dead:
		return

	# paused or no board
	if _paused or _board == null:
		velocity.x = 0.0
		velocity.z = 0.0
		if abs(velocity.y) > EPS:
			velocity.y = 0.0
		_apply_y_lock()
		move_and_slide()
		_update_hb_height()
		return

	# first frame only Y lock
	if _y_lock_enabled and not _y_plane_set:
		_y_plane = global_position.y
		_y_plane_set = true

	# take a short step into the lane, then switch off (with fail-safes)
	if _entry_active:
		_entry_elapsed += delta

		var to_entry := _entry_point - global_position
		to_entry.y = 0.0
		var r := _entry_radius + EPS

		# finished entry?
		if to_entry.length_squared() <= r * r:
			_entry_active = false
			_restore_collision_if_ghosting()
		else:
			# desired step straight toward the entry point
			var target_vel := Vector3.ZERO
			if to_entry.length_squared() > EPS * EPS:
				target_vel = to_entry.normalized() * speed

			_move_horizontal_toward(target_vel, delta)

			# STUCK / COLLISION DETECTION
			var dist_now := to_entry.length()
			if dist_now > _entry_prev_dist - 0.02:
				_entry_stuck_t += delta
			else:
				_entry_stuck_t = 0.0
			_entry_prev_dist = dist_now

			var horiz_speed := sqrt(velocity.x * velocity.x + velocity.z * velocity.z)
			if horiz_speed < entry_stuck_speed:
				_entry_stuck_t += delta

			if entry_abort_on_collision:
				if get_slide_collision_count() > 0:
					_entry_stuck_t += 0.12

			if _entry_elapsed >= entry_abort_timeout or _entry_stuck_t >= entry_stuck_duration:
				_entry_active = false
				_knockback = Vector3.ZERO
				_restore_collision_if_ghosting()

			_update_hb_height()

			# While still doing the entry step, skip normal flow logic
			if _entry_active:
				return

	# goal check
	var goal_pos: Vector3 = _board.get_goal_position()
	var to_goal: Vector3 = goal_pos - global_position
	to_goal.y = 0.0
	if to_goal.length_squared() <= goal_radius * goal_radius:
		_die()
		return

	# flow-field steering
	var dir := _get_flow_dir()
	var target_vel := Vector3.ZERO
	if dir != Vector3.ZERO:
		target_vel = dir * speed

	_move_horizontal_toward(target_vel, delta)
	_update_hb_height()

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

	# Clamp to max speed
	var max_sq := max_speed * max_speed
	var cur_sq := cur_h.length_squared()
	if cur_sq > max_sq and cur_sq > EPS * EPS:
		var scale := max_speed / sqrt(cur_sq)
		cur_h = cur_h * scale

	velocity = Vector3(cur_h.x, 0.0, cur_h.z)

	_apply_y_lock()
	move_and_slide()
	_update_facing_from_velocity(delta)   # NEW: turn to face movement

func _apply_y_lock() -> void:
	if _y_lock_enabled and _y_plane_set:
		if abs(global_position.y - _y_plane) > EPS:
			var p: Vector3 = global_position
			p.y = _y_plane
			global_position = p

func _get_flow_dir() -> Vector3:
	if _board == null:
		return Vector3.ZERO

	var pos: Vector2i = _board.world_to_cell(global_position)
	var goal_pos: Vector3 = _board.get_goal_position()
	var goal_cell: Vector2i = _board.world_to_cell(goal_pos)

	# Outside known tiles: steer gently toward goal
	if not _board.tiles.has(pos):
		var v_out: Vector3 = goal_pos - global_position
		v_out.y = 0.0
		var L2: float = v_out.length_squared()
		if L2 > EPS * EPS:
			return v_out / sqrt(L2)
		return Vector3.ZERO

	# On goal cell: steer directly to goal point
	if pos == goal_cell:
		var v_goal: Vector3 = goal_pos - global_position
		v_goal.y = 0.0
		var Lg2: float = v_goal.length_squared()
		if Lg2 > EPS * EPS:
			return v_goal / sqrt(Lg2)
		return Vector3.ZERO

	# If current cell is temporarily blue or not walkable, escape to best neighbor
	var standing_blocked: bool = false
	if bool(_board.closing.get(pos, false)):
		standing_blocked = true
	else:
		var tile: Node = _board.tiles.get(pos)
		if tile and tile.has_method("is_walkable"):
			if not tile.is_walkable():
				standing_blocked = true

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

	# Use precomputed flow-field direction
	var dir: Vector3 = _board.dir_field.get(pos, Vector3.ZERO)
	dir.y = 0.0
	var d2: float = dir.length_squared()
	if d2 > EPS * EPS:
		return dir / sqrt(d2)

	return Vector3.ZERO

# ---------- NEW: facing control ----------
func _update_facing_from_velocity(delta: float) -> void:
	var h := Vector3(velocity.x, 0.0, velocity.z)
	var L2 := h.length_squared()
	if L2 <= EPS * EPS:
		return

	var desired_fwd := h / sqrt(L2)                 # where we’re moving
	var current_fwd := -global_transform.basis.z    # Godot forward is -Z
	current_fwd.y = 0.0
	var cf2 := current_fwd.length_squared()
	if cf2 > EPS * EPS:
		current_fwd /= sqrt(cf2)
	else:
		current_fwd = Vector3.FORWARD

	var angle := current_fwd.signed_angle_to(desired_fwd, Vector3.UP)
	var max_step := deg_to_rad(turn_speed_deg) * delta
	if angle > max_step:
		angle = max_step
	elif angle < -max_step:
		angle = -max_step

	rotate_y(angle)
# ----------------------------------------

func _build_healthbar() -> void:
	_hb_root = Node3D.new()
	add_child(_hb_root)
	_update_hb_height()

	# red, unshaded, billboard-on-Y
	var quad := QuadMesh.new()
	quad.size = _HB_SIZE

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 0.1, 0.1, 1.0)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.disable_receive_shadows = true
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y

	_hb_bar = MeshInstance3D.new()
	_hb_bar.mesh = quad
	_hb_bar.material_override = mat
	_hb_root.add_child(_hb_bar)

	_update_healthbar()

func _update_hb_height() -> void:
	# keep it floating above the y-locked plane 
	var base_y := global_position.y
	if _y_plane_set:
		base_y = _y_plane
	_hb_root.global_position = Vector3(global_position.x, base_y + _HB_OFFSET_Y, global_position.z)

func _update_healthbar() -> void:
	if _hb_bar == null:
		return
	var t: float = 0.0
	if max_health > 0:
		t = float(health) / float(max_health)
	if t < 0.0:
		t = 0.0
	if t > 1.0:
		t = 1.0
	# scale X down to zero 
	_hb_bar.scale = Vector3(t, 1.0, 1.0)
