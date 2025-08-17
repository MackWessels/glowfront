extends CharacterBody3D

# ---------------- movement ----------------
@export var speed: float = 2.0
@export var acceleration: float = 15.0
@export var max_speed: float = 6.0
@export var goal_radius: float = 0.6
@export var tile_board_path: NodePath
@export var knockback_decay: float = 6.0
@export var knockback_max: float = 8.0
@export var turn_speed_deg: float = 540.0

# ---------------- identity ----------------
@export var is_elite: bool = false

# ---------------- health / combat ----------------
@export var max_health: int = 2            # lighter default HP
@export var armor_pct: float = 0.0         # 0.0–0.95 percent-based reduction
var health: int = 1
signal died
signal health_changed(current: int, maxv: int)

# ---------------- economy ----------------
@export var bounty: int = 5

# ---------------- turret avoidance ----------------
@export var avoid_turrets: bool = true
@export var avoid_radius_tiles: float = 1.1     # influence radius in tiles
@export var avoid_strength_tiles: float = 0.8  # ~10% tile/sec push

# ---------------- entry step targeting ----------------
const ENTRY_RADIUS_DEFAULT: float = 0.20
const ENTRY_RADIUS_MIN: float = 0.01
const EPS: float = 0.0001

# entry fail-safes
@export var entry_abort_timeout: float = 1.00
@export var entry_stuck_speed: float = 0.05
@export var entry_stuck_duration: float = 0.25
@export var entry_abort_on_collision: bool = true

# ---------------- state ----------------
var _board: Node = null
var _knockback: Vector3 = Vector3.ZERO
var _paused: bool = false        # kept for back-compat; maps to idle
var _dead: bool = false

# Idle state
var _idle: bool = false
var _idle_timer: float = -1.0     # <0 = indefinite idle

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

# entry ghosting
var _ghost_until_entry: bool = false
var _saved_layer: int = 0
var _saved_mask: int = 0

func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	floor_snap_length = 0.0

	health = max_health

	if tile_board_path != NodePath(""):
		var n: Node = get_node_or_null(tile_board_path)
		if n != null:
			_board = n
		else:
			push_warning("Enemy: tile_board_path not found: %s" % [tile_board_path])

	if _y_lock_enabled and not _y_plane_set:
		_y_plane = global_position.y
		_y_plane_set = true

	add_to_group("enemy", true)
	add_to_group("enemies", true)
	if is_elite:
		add_to_group("elite_enemies", true)

# ---------- idle API (replaces pause) ----------
func set_idle(on: bool, seconds: float = -1.0) -> void:
	_idle = on
	_idle_timer = seconds
	_paused = on   # legacy sync

func idle_for(seconds: float) -> void:
	set_idle(true, seconds)

# Back-compat shim
func set_paused(p: bool) -> void:
	set_idle(p)

# ---------------- damage / death ----------------
func take_damage(d) -> void:
	if _dead:
		return

	var dmg: int = 0
	if typeof(d) == TYPE_DICTIONARY:
		dmg = _compute_damage_from_ctx(d)
	else:
		dmg = int(d)

	if dmg <= 0:
		return

	health = max(health - dmg, 0)
	emit_signal("health_changed", health, max_health)

	if health <= 0:
		_die_with_reward(true)  # killed by damage -> award bounty

func _compute_damage_from_ctx(ctx: Dictionary) -> int:
	var base: int = int(ctx.get("base", 0))
	var flat_bonus: int = int(ctx.get("flat_bonus", 0))
	var mult: float = float(ctx.get("mult", 1.0))

	# Optional crit
	var p: float = clampf(float(ctx.get("crit_chance", 0.0)), 0.0, 1.0)
	var do_crit: bool = (p > 0.0 and randf() < p)
	var crit_mult: float = float(ctx.get("crit_mult", 2.0))

	var raw: float = float(base + flat_bonus) * mult
	if do_crit:
		raw *= crit_mult

	# Armor as percent reduction
	var reduced: float = raw * (1.0 - clampf(armor_pct, 0.0, 0.95))
	var final_amount: int = int(floor(maxf(1.0, reduced)))
	return final_amount

func _die_with_reward(award: bool) -> void:
	if _dead:
		return
	_dead = true

	if award and bounty > 0:
		var src: String = "kill"
		if is_elite:
			src = "elite_kill"
		_econ_add(bounty, src)

	emit_signal("died")
	queue_free()

# No bounty for reaching goal
func on_reach_goal() -> void:
	_die_with_reward(false)

# ---------------- helpers ----------------
func lock_y_to(y: float) -> void:
	_y_plane = y
	_y_plane_set = true
	_y_lock_enabled = true

	if abs(global_position.y - y) > EPS:
		var p: Vector3 = global_position
		p.y = y
		global_position = p

	if abs(velocity.y) > EPS:
		velocity.y = 0.0

func set_entry_point(p: Vector3) -> void:
	set_entry_target(p, ENTRY_RADIUS_DEFAULT)

func set_entry_target(p: Vector3, radius: float) -> void:
	if _y_lock_enabled and _y_plane_set:
		p.y = _y_plane

	if radius < ENTRY_RADIUS_MIN:
		radius = ENTRY_RADIUS_MIN

	_entry_point = p
	_entry_radius = radius

	if not is_inside_tree():
		_entry_active = true
	else:
		var to_entry: Vector3 = _entry_point - global_position
		to_entry.y = 0.0
		var r: float = _entry_radius + EPS
		_entry_active = to_entry.length_squared() > r * r

	_entry_elapsed = 0.0
	_entry_stuck_t = 0.0
	_entry_prev_dist = 1e9

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

func reset_for_spawn() -> void:
	_idle = false
	_idle_timer = -1.0
	_paused = false

	_dead = false
	velocity = Vector3.ZERO
	_knockback = Vector3.ZERO

	health = max_health
	emit_signal("health_changed", health, max_health)

# ---------------- physics ----------------
func _physics_process(delta: float) -> void:
	if _dead:
		return

	# Idle / legacy paused / no board: stand still (with optional timed idle)
	if _idle or _paused or _board == null:
		if _idle and _idle_timer >= 0.0:
			_idle_timer -= delta
			if _idle_timer <= 0.0:
				_idle = false
				_paused = false

		var cur_h: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
		cur_h = cur_h.move_toward(Vector3.ZERO, acceleration * delta)
		velocity = Vector3(cur_h.x, 0.0, cur_h.z)

		if abs(velocity.y) > EPS:
			velocity.y = 0.0
		_apply_y_lock()
		move_and_slide()
		return

	if _y_lock_enabled and not _y_plane_set:
		_y_plane = global_position.y
		_y_plane_set = true

	# Entry step (pre-walk nudge)
	if _entry_active:
		_entry_elapsed += delta

		var to_entry: Vector3 = _entry_point - global_position
		to_entry.y = 0.0
		var r: float = _entry_radius + EPS

		if to_entry.length_squared() <= r * r:
			_entry_active = false
			_restore_collision_if_ghosting()
		else:
			var target_vel: Vector3 = Vector3.ZERO
			if to_entry.length_squared() > EPS * EPS:
				target_vel = to_entry.normalized() * speed

			_move_horizontal_toward(target_vel, delta)

			var dist_now: float = to_entry.length()
			if dist_now > _entry_prev_dist - 0.02:
				_entry_stuck_t += delta
			else:
				_entry_stuck_t = 0.0
			_entry_prev_dist = dist_now

			var horiz_speed: float = sqrt(velocity.x * velocity.x + velocity.z * velocity.z)
			if horiz_speed < entry_stuck_speed:
				_entry_stuck_t += delta

			if entry_abort_on_collision:
				if get_slide_collision_count() > 0:
					_entry_stuck_t += 0.12

			if _entry_elapsed >= entry_abort_timeout or _entry_stuck_t >= entry_stuck_duration:
				_entry_active = false
				_knockback = Vector3.ZERO
				_restore_collision_if_ghosting()

			if _entry_active:
				return

	# Goal check — NO reward if reached
	var goal_pos: Vector3 = _board.get_goal_position()
	var to_goal: Vector3 = goal_pos - global_position
	to_goal.y = 0.0
	if to_goal.length_squared() <= goal_radius * goal_radius:
		on_reach_goal()
		return

	# Flow-field steering
	var dir_vec: Vector3 = _get_flow_dir()
	var target_vel2: Vector3 = Vector3.ZERO
	if dir_vec != Vector3.ZERO:
		target_vel2 = dir_vec * speed

	# Add gentle push away from nearby turret
	target_vel2 += _turret_avoidance_velocity()

	_move_horizontal_toward(target_vel2, delta)

func _move_horizontal_toward(target_vel: Vector3, delta: float) -> void:
	var desired: Vector3 = Vector3(
		target_vel.x + _knockback.x,
		0.0,
		target_vel.z + _knockback.z
	)

	var cur_h: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	cur_h = cur_h.move_toward(desired, acceleration * delta)

	var max_sq: float = max_speed * max_speed
	var cur_sq: float = cur_h.length_squared()
	if cur_sq > max_sq and cur_sq > EPS * EPS:
		var scale: float = max_speed / sqrt(cur_sq)
		cur_h = cur_h * scale

	velocity = Vector3(cur_h.x, 0.0, cur_h.z)

	_apply_y_lock()
	move_and_slide()
	_update_facing_from_velocity(delta)

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

	if not _board.tiles.has(pos):
		var v_out: Vector3 = goal_pos - global_position
		v_out.y = 0.0
		var L2: float = v_out.length_squared()
		if L2 > EPS * EPS:
			return v_out / sqrt(L2)
		return Vector3.ZERO

	if pos == goal_cell:
		var v_goal: Vector3 = goal_pos - global_position
		v_goal.y = 0.0
		var Lg2: float = v_goal.length_squared()
		if Lg2 > EPS * EPS:
			return v_goal / sqrt(Lg2)
		return Vector3.ZERO

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
		var best_val: int = 1000000
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

	var dir_v: Vector3 = _board.dir_field.get(pos, Vector3.ZERO)
	dir_v.y = 0.0
	var d2: float = dir_v.length_squared()
	if d2 > EPS * EPS:
		return dir_v / sqrt(d2)

	return Vector3.ZERO

# ---------- facing control ----------
func _update_facing_from_velocity(delta: float) -> void:
	var h: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	var L2: float = h.length_squared()
	if L2 <= EPS * EPS:
		return

	var desired_fwd: Vector3 = h / sqrt(L2)
	var current_fwd: Vector3 = -global_transform.basis.z
	current_fwd.y = 0.0
	var cf2: float = current_fwd.length_squared()
	if cf2 > EPS * EPS:
		current_fwd /= sqrt(cf2)
	else:
		current_fwd = Vector3.FORWARD

	var angle: float = current_fwd.signed_angle_to(desired_fwd, Vector3.UP)
	var max_step: float = deg_to_rad(turn_speed_deg) * delta
	angle = clamp(angle, -max_step, max_step)
	rotate_y(angle)

# ---------------- turret avoidance helpers ----------------
func _turret_avoidance_velocity() -> Vector3:
	if not avoid_turrets or _board == null:
		return Vector3.ZERO

	var tile_size: float = _get_tile_size()
	var radius: float = avoid_radius_tiles * tile_size
	if radius < EPS:
		radius = EPS

	var strength: float = avoid_strength_tiles * tile_size
	if strength < 0.0:
		strength = 0.0

	var nearest_pos: Vector3 = Vector3.ZERO
	var best_d2: float = 1.0e18
	var found: bool = false

	for n in _get_turret_nodes():
		if n is Node3D:
			var p: Vector3 = (n as Node3D).global_position
			var v: Vector3 = global_position - p
			v.y = 0.0
			var d2: float = v.length_squared()
			if d2 < radius * radius and d2 < best_d2:
				best_d2 = d2
				nearest_pos = p
				found = true

	if not found:
		return Vector3.ZERO

	var d: float = sqrt(best_d2)
	var away: Vector3 = global_position - nearest_pos
	away.y = 0.0
	if d <= EPS:
		away = Vector3(1, 0, 0)  # arbitrary push if overlapping
	else:
		away /= d

	# Full push at contact, fades to 0 at radius.
	var falloff: float = 1.0 - clampf(d / radius, 0.0, 1.0)
	return away * (strength * falloff)

func _get_turret_nodes() -> Array:
	var arr: Array = []
	arr.append_array(get_tree().get_nodes_in_group("turret"))
	arr.append_array(get_tree().get_nodes_in_group("turrets"))
	return arr

func _get_tile_size() -> float:
	if _board == null:
		return 1.0
	var v: Variant = _board.get("tile_size")
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	return 1.0

# ---------------- economy helpers (autoload) ----------------
func _econ_add(amount: int, source: String) -> void:
	if amount == 0:
		return
	# Call the Economy autoload directly, without any prints.
	if Economy.has_method("add"):
		Economy.call("add", amount, source)
	elif Economy.has_method("deposit"):
		Economy.call("deposit", amount)
	elif Economy.has_method("set_amount"):
		var v: Variant = Economy.get("minerals")
		var cur: int = 0
		if typeof(v) == TYPE_INT:
			cur = int(v)
		Economy.call("set_amount", cur + amount)
	else:
		var v2: Variant = Economy.get("minerals")
		if typeof(v2) == TYPE_INT:
			Economy.set("minerals", int(v2) + amount)
