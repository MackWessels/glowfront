extends CharacterBody3D
class_name Enemy

# -------- Movement --------
@export var speed: float = 2.0
@export var accel: float = 22.0
@export var turn_speed_deg: float = 540.0

# Y-lock
var _y_lock_enabled: bool = true

# Lane cosmetics
@export var lane_spread_tiles: float = 0.35
@export_range(0.0, 1.0, 0.01) var lane_bias_strength: float = 0.6
@export var num_lanes: int = 0
@export var lane_jitter_tiles: float = 0.06
@export var lane_slew_per_sec: float = 12.0

# Board refs
@export var tile_board_path: NodePath
@export var goal_node_path: NodePath

# Stats injected by spawner
@export var health: int = 10
@export var attack: int = 1
@export var mass: float = 1.0

# Rewards/flags from spawner (fixed per color; not wave-scaled)
@export var mineral_reward: int = 1
@export var is_elite: bool = false

# Visual level (1=green, 2=blue, 3=red, 4=black)
var _level: int = 1
@export var level: int = 1:
	set(value):
		_level = clampi(value, 1, 4)
		_apply_level_skin()
	get:
		return _level

signal died
signal damaged(by, amount: int, killed: bool)

var _board: Node = null
var _goal: Node3D = null
var _spawner_ref: Node = null
var _tile_w: float = 1.0
var _y_plane: float = 0.0

var _cur_cell: Vector2i = Vector2i(-9999, -9999)
var _planned_next: Vector2i = Vector2i(-9999, -9999)
var _planned_next_is_offgrid: bool = false
var _tile_target: Vector3 = Vector3.ZERO
var _seg_tan: Vector3 = Vector3.FORWARD
var _seg_perp: Vector3 = Vector3.RIGHT

var _lane_state: float = 0.0
var _lane_target: float = 0.0
var _lane_initialized: bool = false
var _lane_max_off_cached: float = 0.0
var _lane_sig: float = 0.0
var _lane_sig_ready: bool = false

var _needs_replan: bool = false

# Entry glide
var _entry_active: bool = false
var _entry_target: Vector3 = Vector3.ZERO
@export var _entry_radius: float = 0.4

var _lane_signature: float = 9999.0

# Visual handle
@onready var _ufo_base: MeshInstance3D = get_node_or_null("UFO/Base") as MeshInstance3D
var _base_original_override: Material = null

var _dead: bool = false

# Track board path version (if board exposes one)
var _last_path_version: int = -1

# ============================ Lifecycle ============================
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
	_y_lock_enabled = true
	_lane_initialized = false

	# react to global path rebakes
	if _board and _board.has_signal("global_path_changed"):
		_board.connect("global_path_changed", Callable(self, "_on_board_changed"))

	# init path version if board exposes it
	_last_path_version = _get_board_path_version()

	velocity = Vector3.ZERO
	_cur_cell = _board_cell_of_pos(global_position)
	_plan_from_cell(_cur_cell)

	if _ufo_base != null:
		_base_original_override = _ufo_base.material_override
	_apply_level_skin()

func reset_for_spawn() -> void:
	velocity = Vector3.ZERO
	_lane_initialized = false
	_lane_sig_ready = false
	_cur_cell = _board_cell_of_pos(global_position)
	_plan_from_cell(_cur_cell)
	_entry_active = false
	_dead = false
	_y_plane = global_position.y
	_y_lock_enabled = true
	_apply_level_skin()

func set_entry_target(p: Vector3, radius: float) -> void:
	_entry_target = p
	_entry_radius = maxf(0.05, radius)
	_entry_active = true

func apply_stats(s: Dictionary) -> void:
	if s.has("health"): health = int(s["health"])
	if s.has("attack"): attack = int(s["attack"])
	if s.has("mass"):   mass   = float(s["mass"])
	if s.has("speed"):  speed  = float(s["speed"])

# --------- Integration helpers ----------
func set_tile_board(tb: Node) -> void:
	_board = tb
	if tb != null and tb is Node:
		tile_board_path = (tb as Node).get_path()
	_tile_w = _get_tile_w()

func set_spawner(sp: Node) -> void:
	_spawner_ref = sp

func lock_y_to(y: float) -> void:
	_y_plane = y
	_y_lock_enabled = true
	global_position.y = y

func unlock_y() -> void:
	_y_lock_enabled = false

# Smooth landing when being dropped by a carrier
func land_from_drop(target_y: float, t: float = 0.2) -> void:
	# Allow tween to control Y without being clamped
	unlock_y()

	# briefly disable collisions during the drop to avoid snagging edge cases
	var had_collision_obj := self is CollisionObject3D
	var old_layer := 0
	var old_mask := 0
	if had_collision_obj:
		old_layer = (self as CollisionObject3D).collision_layer
		old_mask = (self as CollisionObject3D).collision_mask
		(self as CollisionObject3D).collision_layer = 0
		(self as CollisionObject3D).collision_mask = 0

	var tw := create_tween()
	tw.tween_property(self, "global_position:y", target_y, t)\
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func ():
		if had_collision_obj and is_instance_valid(self):
			(self as CollisionObject3D).collision_layer = old_layer
			(self as CollisionObject3D).collision_mask = old_mask
		# Lock exactly at the landing height
		lock_y_to(target_y))

# ============================ Combat ============================
func take_damage(ctx: Dictionary) -> void:
	var by: Node = ctx.get("by", null) as Node

	# Prefer precomputed final damage
	var dmg: int = -1
	if ctx.has("final"):
		dmg = int(ctx["final"])
	else:
		# Back-compat path (old callers): compute here.
		var base: int = int(ctx.get("base", 0))
		var flat: int = int(ctx.get("flat_bonus", 0))
		var mult: float = float(ctx.get("mult", 1.0))
		var crit_mult: float = float(ctx.get("crit_mult", 2.0))
		var crit_chance: float = float(ctx.get("crit_chance", 0.0))
		if crit_chance > 0.0 and randf() < crit_chance:
			mult *= crit_mult
		dmg = int(max(0.0, round(float(base + flat) * mult)))

	if dmg <= 0:
		return

	health -= dmg
	var killed := (health <= 0)
	emit_signal("damaged", by, dmg, killed)
	if killed:
		_die(true)

func _die(killed: bool) -> void:
	if _dead:
		return
	_dead = true

	if killed:
		# ---- Minerals ----
		var payout: int = 0
		if typeof(PowerUps) != TYPE_NIL and PowerUps.has_method("award_bounty"):
			var info: Dictionary = PowerUps.award_bounty(max(0, mineral_reward), "kill")
			payout = int(info.get("payout", 0))
		else:
			payout = max(0, mineral_reward)
			_award_minerals(payout)

		# Notify spawner (parent if possible, else stored ref)
		var spawner := get_parent()
		if (spawner == null or not spawner.has_method("notify_kill_payout")) and _spawner_ref != null:
			spawner = _spawner_ref
		if spawner and spawner.has_method("notify_kill_payout"):
			spawner.notify_kill_payout(payout)

		# ---- Shards (unchanged) ----
		var shards: Node = get_node_or_null("/root/Shards")
		if shards != null:
			if shards.has_method("award_for_enemy"):
				shards.call("award_for_enemy", is_elite)
			elif shards.has_method("add"):
				if is_elite: shards.call("add", 5)
				elif randf() < 0.03: shards.call("add", 1)

	emit_signal("died")
	queue_free()

# ============================ Goal / Leak ============================
func _on_reach_goal() -> void:
	# Tell the spawner we leaked before removing ourselves.
	var spawner := get_parent()
	if (spawner == null or not spawner.has_method("notify_leak")) and _spawner_ref != null:
		spawner = _spawner_ref
	if spawner and spawner.has_method("notify_leak"):
		spawner.notify_leak(self)
	_die(false)  # no rewards on leak

# ============================ Helpers ============================
func _apply_y_lock(p: Vector3) -> Vector3:
	if _y_lock_enabled:
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

func _is_offgrid_cell(c: Vector2i) -> bool:
	if _board and _board.has_method("is_in_bounds"):
		return not bool(_board.call("is_in_bounds", c))
	var sx: int = int(_board.get("board_size_x")) if _board else 0
	var sz: int = int(_board.get("board_size_z")) if _board else 0
	return c.x < 0 or c.y < 0 or c.x >= sx or c.y >= sz

func _hash2f(c: Vector2i) -> float:
	var h: int = int(c.x) * 374761393 + int(c.y) * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	var u: float = float(h & 0x7fffffff) / float(0x7fffffff)
	return u * 2.0 - 1.0

func _max_lane_abs() -> float:
	return minf(_tile_w * 0.45, lane_spread_tiles * _tile_w)

func _lane_signature_value() -> float:
	if not _lane_sig_ready:
		if _lane_signature >= -1.0 and _lane_signature <= 1.0:
			_lane_sig = clampf(_lane_signature, -1.0, 1.0)
		else:
			_lane_sig = randf_range(-1.0, 1.0)
		_lane_sig_ready = true
	return _lane_sig

func _get_board_path_version() -> int:
	if _board == null: return -1
	var v: Variant = _board.get("path_version")
	return int(v) if typeof(v) in [TYPE_INT, TYPE_FLOAT] else _last_path_version

# ---------------- Planning / Path ----------------
func _plan_from_cell(c: Vector2i) -> void:
	var n: Vector2i = _next_from(c)
	_planned_next = n
	_planned_next_is_offgrid = _is_offgrid_cell(n)

	var a: Vector3 = _cell_center(c)
	var b: Vector3 = _cell_center(n)
	var d: Vector3 = b - a; d.y = 0.0
	var L: float = d.length()
	_seg_tan = (d / L) if L > 0.0001 else Vector3.FORWARD
	_seg_perp = Vector3(-_seg_tan.z, 0.0, _seg_tan.x)

	_lane_max_off_cached = _max_lane_abs()
	var desired: float = lane_bias_strength * _lane_signature_value() * _lane_max_off_cached
	desired += _hash2f(c) * (lane_jitter_tiles * _tile_w)
	desired = clampf(desired, -_lane_max_off_cached, _lane_max_off_cached)
	_lane_target = desired

	if not _lane_initialized:
		_lane_state = desired
		_lane_initialized = true

	_rebuild_tile_target()

func _rebuild_tile_target() -> void:
	var off: float = _maybe_quantize(_lane_state, _lane_max_off_cached)
	_tile_target = _cell_center(_planned_next) + _seg_perp * off

func _maybe_quantize(x: float, max_off: float) -> float:
	if num_lanes >= 2 and max_off > 0.0:
		var span: float = 2.0 * max_off
		var step: float = span / float(num_lanes - 1)
		var idx: int = int(round((x + max_off) / step))
		return clampf(float(idx) * step - max_off, -max_off, max_off)
	return x

func _accelerate_toward(v: Vector3, target_v: Vector3, a: float, dt: float) -> Vector3:
	var dv: Vector3 = target_v - v
	var max_dv: float = a * dt
	if dv.length() > max_dv:
		dv = dv.normalized() * max_dv
	return v + dv

# ---------------- Physics ----------------
func _physics_process(delta: float) -> void:
	# Replan when the board says the path changed.
	var pv: int = _get_board_path_version()
	if pv != _last_path_version:
		_last_path_version = pv
		_lane_initialized = false
		_needs_replan = true

	if lane_slew_per_sec > 0.0 and _lane_initialized:
		var step: float = lane_slew_per_sec * delta * _lane_max_off_cached
		_lane_state = move_toward(_lane_state, _lane_target, step)
		_rebuild_tile_target()

	# optional entry glide
	if _entry_active:
		var to_target: Vector3 = _entry_target - global_position
		to_target.y = 0.0
		var L: float = to_target.length()
		if L <= _entry_radius:
			_entry_active = false
			velocity = Vector3.ZERO
			_cur_cell = _board_cell_of_pos(global_position)
			_lane_initialized = false
			_plan_from_cell(_cur_cell)
		else:
			var tv: Vector3 = to_target / maxf(L, 0.0001) * speed
			velocity = _accelerate_toward(velocity, tv, accel, delta)
			_update_facing_toward(velocity, delta)
			velocity.y = 0.0
			move_and_slide()
			global_position = _apply_y_lock(global_position)
			_emit_cell_if_changed()
			return

	if _needs_replan:
		_needs_replan = false
		_lane_initialized = false
		_plan_from_cell(_cur_cell)

	var live_next: Vector2i = _next_from(_cur_cell)
	if live_next != _planned_next:
		_lane_initialized = false
		_plan_from_cell(_cur_cell)

	var seek: Vector3 = _tile_target - global_position
	seek.y = 0.0
	var dist: float = seek.length()

	if _planned_next_is_offgrid and dist <= maxf(_tile_w * 0.25, 0.1):
		_on_reach_goal()
		return

	if dist > 0.01:
		var tv_main: Vector3 = (seek / dist) * speed
		velocity = _accelerate_toward(velocity, tv_main, accel, delta)

	_update_facing_toward(velocity, delta)

	velocity.y = 0.0
	move_and_slide()
	global_position = _apply_y_lock(global_position)
	_emit_cell_if_changed()

func _emit_cell_if_changed() -> void:
	var new_cell: Vector2i = _board_cell_of_pos(global_position)
	if new_cell != _cur_cell:
		_cur_cell = new_cell
		_plan_from_cell(_cur_cell)

func _update_facing_toward(dir_or_vec: Vector3, delta: float) -> void:
	var v: Vector3 = dir_or_vec; v.y = 0.0
	if v.length_squared() < 1e-8:
		return
	var desired_fwd: Vector3 = v.normalized()
	var current_fwd: Vector3 = -global_transform.basis.z
	current_fwd.y = 0.0
	if current_fwd.length_squared() <= 1e-8:
		current_fwd = Vector3.FORWARD
	var angle: float = current_fwd.signed_angle_to(desired_fwd, Vector3.UP)
	var max_step: float = deg_to_rad(turn_speed_deg) * delta
	angle = clampf(angle, -max_step, max_step)
	rotate_y(angle)

func _on_board_changed() -> void:
	_last_path_version = _get_board_path_version()
	_lane_initialized = false
	_cur_cell = _board_cell_of_pos(global_position)
	_plan_from_cell(_cur_cell)

# ---------------- Tile size ----------------
func _get_tile_w() -> float:
	if _board and _board.has_method("tile_world_size"):
		return float(_board.call("tile_world_size"))
	var tv: Variant = _board.get("tile_size") if _board else 1.0
	return float(tv) if (typeof(tv) == TYPE_FLOAT or typeof(tv) == TYPE_INT) else 1.0

# ---------------- Fallback econ (used only if PowerUps missing) ----------------
func _award_minerals(amount: int) -> void:
	if amount <= 0: return
	if typeof(Economy) != TYPE_NIL:
		if Economy.has_method("earn"): Economy.earn(amount); return
		if Economy.has_method("add"): Economy.add(amount); return
		if Economy.has_method("deposit"): Economy.deposit(amount); return
		if Economy.has_method("set_amount") and Economy.has_method("balance"):
			Economy.set_amount(int(Economy.balance()) + amount); return
		var bv: Variant = Economy.get("minerals")
		if typeof(bv) == TYPE_INT:
			Economy.set("minerals", int(bv) + amount); return
	var econ: Node = get_node_or_null("/root/Minerals")
	if econ != null:
		if econ.has_method("earn"): econ.call("earn", amount); return
		if econ.has_method("add"): econ.call("add", amount); return
		if econ.has_method("set_amount"):
			var cur: int = 0
			var v: Variant = econ.get("minerals")
			if typeof(v) == TYPE_INT: cur = int(v)
			econ.call("set_amount", cur + amount); return
		var bv2: Variant = econ.get("minerals")
		if typeof(bv2) == TYPE_INT:
			econ.set("minerals", int(bv2) + amount); return

# -------- Level color --------
func _color_for_level(lvl: int) -> Color:
	match clampi(lvl, 1, 4):
		1: return Color(0.35, 0.90, 0.35)  # green
		2: return Color(0.30, 0.55, 1.00)  # blue
		3: return Color(1.00, 0.25, 0.25)  # red
		_: return Color(0.05, 0.05, 0.05)  # black

func _apply_level_skin() -> void:
	if _ufo_base == null:
		_ufo_base = get_node_or_null("UFO/Base") as MeshInstance3D
		if _ufo_base != null and _base_original_override == null:
			_base_original_override = _ufo_base.material_override
	if _ufo_base == null:
		return

	var col: Color = _color_for_level(_level)
	var mat: StandardMaterial3D
	if _ufo_base.material_override is StandardMaterial3D:
		mat = ((_ufo_base.material_override as StandardMaterial3D).duplicate() as StandardMaterial3D)
	else:
		mat = StandardMaterial3D.new()
	mat.resource_local_to_scene = true
	mat.albedo_color = col
	mat.metallic = 0.15
	mat.roughness = 0.35
	_ufo_base.material_override = mat
