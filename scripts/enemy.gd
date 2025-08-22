extends CharacterBody3D

# ---------------- movement ----------------
@export var speed: float = 2
@export var acceleration: float = 15.0
@export var max_speed: float = 6.0
@export var turn_speed_deg: float = 540.0
@export var tile_board_path: NodePath

# keep for turret hits only (we don't use it for anti-stuck)
@export var knockback_decay: float = 6.0
@export var knockback_max: float = 8.0

# ---------------- identity ----------------
@export var is_elite: bool = false

# ---------------- health / combat ----------------
@export var max_health: int = 200
@export var armor_pct: float = 0.0
var health: int = 100
signal died
signal health_changed(current: int, maxv: int)

# ---------------- economy ----------------
@export var bounty: int = 5

const EPS: float = 0.0001

# ---------------- state ----------------
var _board: Node = null
var _knockback: Vector3 = Vector3.ZERO
var _dead: bool = false

# Idle
var _idle: bool = false
var _idle_timer: float = -1.0

# Y-plane lock
var _y_lock_enabled: bool = true
var _y_plane: float = 0.0
var _y_plane_set: bool = false

# --- tile change signal for TileBoard reservations ---
signal cell_changed(old_cell: Vector2i, new_cell: Vector2i)
var _last_emitted_cell: Vector2i = Vector2i(-99999, -99999)

# --- anti-stall (very small lateral nudge only when stuck) ---
var _unstick_timer: float = 0.0
var _unstick_phase: int = 0  # toggles -1 / +1
const UNSTICK_TRIGGER_SPEED := 0.05      # if moving slower than this…
const UNSTICK_TRIGGER_TIME  := 0.20      # …for this long, apply nudge
const UNSTICK_LATERAL_FACTOR := 0.75     # lateral strength relative to forward

# local 4-connected
const _ORTHO: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0),
	Vector2i(0, 1), Vector2i(0, -1)
]

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

	# If the board recomputes, just reset the anti-stuck state
	if _board and _board.has_signal("global_path_changed"):
		_board.connect("global_path_changed", Callable(self, "_on_board_path_changed"))

	add_to_group("enemy", true)
	add_to_group("enemies", true)
	if is_elite:
		add_to_group("elite_enemies", true)

# ---------- idle ----------
func set_idle(on: bool, seconds: float = -1.0) -> void:
	_idle = on
	_idle_timer = seconds

func idle_for(seconds: float) -> void:
	set_idle(true, seconds)

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
		_die_with_reward(true)

func _compute_damage_from_ctx(ctx: Dictionary) -> int:
	var base: int = int(ctx.get("base", 0))
	var flat_bonus: int = int(ctx.get("flat_bonus", 0))
	var mult: float = float(ctx.get("mult", 1.0))
	var p: float = clampf(float(ctx.get("crit_chance", 0.0)), 0.0, 1.0)
	var do_crit: bool = (p > 0.0 and randf() < p)
	var crit_mult: float = float(ctx.get("crit_mult", 2.0))
	var raw: float = float(base + flat_bonus) * mult
	if do_crit:
		raw *= crit_mult
	var reduced: float = raw * (1.0 - clampf(armor_pct, 0.0, 0.95))
	return int(floor(maxf(1.0, reduced)))

func _die_with_reward(award: bool) -> void:
	if _dead:
		return
	_dead = true
	if award:
		if bounty > 0:
			var src: String = ("elite_kill" if is_elite else "kill")
			_econ_add(bounty, src)
		Shards.award_for_enemy(is_elite)
	emit_signal("died")
	queue_free()

func on_reach_goal() -> void:
	_die_with_reward(false)

# ---------------- physics ----------------
func _physics_process(delta: float) -> void:
	if _dead:
		return

	# Idle
	if _idle or _board == null:
		if _idle and _idle_timer >= 0.0:
			_idle_timer -= delta
			if _idle_timer <= 0.0:
				_idle = false
		_slow_to_stop(delta)
		return

	if _y_lock_enabled and not _y_plane_set:
		_y_plane = global_position.y
		_y_plane_set = true

	# 1) get desired direction from board (no sub-goal)
	var dir_vec: Vector3 = _compute_dir_from_board()

	# 2) tiny lateral nudge only if we appear stalled
	var hspeed := Vector3(velocity.x, 0.0, velocity.z).length()
	var move_dir := dir_vec
	if dir_vec != Vector3.ZERO:
		if hspeed < UNSTICK_TRIGGER_SPEED:
			_unstick_timer += delta
			if _unstick_timer > UNSTICK_TRIGGER_TIME:
				_unstick_phase = (1 if _unstick_phase <= 0 else -1)
				var lat := Vector3(dir_vec.z, 0.0, -dir_vec.x) * float(_unstick_phase)
				move_dir = (dir_vec + lat * UNSTICK_LATERAL_FACTOR).normalized()
				_unstick_timer = UNSTICK_TRIGGER_TIME * 0.5
		else:
			_unstick_timer = 0.0

	var target_vel: Vector3 = (move_dir * speed) if move_dir != Vector3.ZERO else Vector3.ZERO
	_move_horizontal_toward(target_vel, delta)

func _slow_to_stop(delta: float) -> void:
	var cur_h_idle: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	cur_h_idle = cur_h_idle.move_toward(Vector3.ZERO, acceleration * delta)
	velocity = Vector3(cur_h_idle.x, 0.0, cur_h_idle.z)
	if abs(velocity.y) > EPS:
		velocity.y = 0.0
	_apply_y_lock()
	move_and_slide()

func _move_horizontal_toward(target_vel: Vector3, delta: float) -> void:
	# decay external knockback only
	if _knockback.length_squared() > EPS * EPS:
		var decay: float = max(0.0, 1.0 - knockback_decay * delta)
		_knockback *= decay
		if _knockback.length_squared() < (EPS * EPS):
			_knockback = Vector3.ZERO

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
	_emit_cell_if_changed()

func _apply_y_lock() -> void:
	if _y_lock_enabled and _y_plane_set:
		if abs(global_position.y - _y_plane) > EPS:
			var p: Vector3 = global_position
			p.y = _y_plane
			global_position = p

# ---------------- direction from board (no sub-goal) ----------------
func _compute_dir_from_board() -> Vector3:
	if _board == null:
		return Vector3.ZERO

	# Prefer the board's continuous sample (handles spawner/goal pens & reservations)
	if _board.has_method("sample_flow_dir"):
		var d: Vector3 = _board.call("sample_flow_dir", global_position)
		d.y = 0.0
		var L2: float = d.length_squared()
		if L2 > EPS * EPS:
			return d / sqrt(L2)

	# Fallback: greedy to cheapest neighbor by cost
	if not (_board.has_method("world_to_cell") and _board.has_method("cell_to_world")):
		return Vector3.ZERO

	var pos_cell: Vector2i = _board.call("world_to_cell", global_position)
	var cost_map: Dictionary = {}
	var v_cost = _board.get("cost")
	if typeof(v_cost) == TYPE_DICTIONARY:
		cost_map = v_cost
	if not cost_map.has(pos_cell):
		return Vector3.ZERO

	var best: Vector2i = pos_cell
	var best_val: int = int(cost_map[pos_cell])
	for o in _ORTHO:
		var nb: Vector2i = pos_cell + o
		if cost_map.has(nb):
			var c: int = int(cost_map[nb])
			if c < best_val:
				best_val = c
				best = nb

	if best != pos_cell:
		var to: Vector3 = _board.call("cell_to_world", best) - global_position
		to.y = 0.0
		var L2b := to.length_squared()
		if L2b > EPS * EPS:
			return to / sqrt(L2b)
	return Vector3.ZERO

# --- board changed -> clear anti-stuck hysteresis ---
func _on_board_path_changed() -> void:
	_unstick_timer = 0.0
	_unstick_phase = 0

# ---------- facing ----------
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

# ---------------- economy helpers ----------------
func _econ_add(amount: int, source: String) -> void:
	if amount == 0:
		return
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

# ---------------- emit tile changes for TileBoard ----------------
func _emit_cell_if_changed() -> void:
	if _board == null or not _board.has_method("world_to_cell"):
		return
	var cur_cell: Vector2i = _board.call("world_to_cell", global_position)
	if cur_cell != _last_emitted_cell:
		var prev: Vector2i = _last_emitted_cell
		_last_emitted_cell = cur_cell
		emit_signal("cell_changed", prev, cur_cell)
