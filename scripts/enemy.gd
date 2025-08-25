extends CharacterBody3D
class_name Enemy

# ===================== Movement =====================
@export var speed: float = 3.0
@export var turn_speed_deg: float = 540.0
@export var lane_spread_tiles: float = 0.35      # max lane magnitude (in tiles)
@export var tile_board_path: NodePath
@export var goal_node_path: NodePath

# ==== Lane carry/relax on turns ====
@export_range(0.0, 1.0, 0.01) var carry_lane_across_turns: float = 0.35
@export var lane_blend_len_tiles: float = 0.35
@export var straight_dot_threshold: float = 0.995   # cos(angle). 0.995 ≈ 5.7°

# ==== Lane diversity ====
@export var enable_lane_bias: bool = true
@export_range(0.0, 1.0, 0.01) var lane_bias_strength: float = 0.6
@export var num_lanes: int = 0                      # 0=continuous, >=2 quantizes into lanes
@export var enable_lane_jitter: bool = true
@export var lane_jitter_tiles: float = 0.06         # per-tile deterministic jitter (in tiles)

# ==== Dynamic path-change smoothing ====
@export var adopt_path_on_boundary: bool = true     # prefer switching routes only at tile edges
@export var path_change_cooldown: float = 0.12      # seconds to debounce repeated flow changes
@export var min_reproject_fraction: float = 0.12    # clamp s forward after mid-segment retarget
@export var lock_retarget_until_boundary: bool = true

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

# ===================== Segment following (a..b) =====================
var _cur_cell: Vector2i = Vector2i(-9999, -9999)
var _next_cell: Vector2i = Vector2i(-9999, -9999)

var _a: Vector3 = Vector3.ZERO
var _b: Vector3 = Vector3.ZERO
var _v: Vector3 = Vector3.ZERO
var _L: float = 0.0

var _tangent: Vector3 = Vector3.FORWARD
var _perp: Vector3 = Vector3.RIGHT

var _s: float = 0.0                     # distance along current segment [0, L]
var _lane_w: float = 0.0                # current lane offset (world units)
var _tile_w: float = 1.0                # world tile size

# ===== Lane blend state (for new segments) =====
var _blend_active: bool = false
var _blend_from: float = 0.0
var _blend_to: float = 0.0
var _blend_s0: float = 0.0
var _blend_len: float = 0.0

# ===== Path-change smoothing =====
var _pending_path_change: bool = false
var _path_change_timer: float = 0.0
var _segment_retarget_locked: bool = false

# ===== Variety state =====
var _lane_signature: float = 0.0        # per-enemy [-1,1] bias (set at spawn)

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
		if typeof(tv) == TYPE_FLOAT or typeof(tv) == TYPE_INT:
			_tile_w = float(tv)
		else:
			_tile_w = 1.0

	if _y_lock_enabled:
		_y_plane = global_position.y

	# Listen for path changes (adopt smoothly)
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
	if _y_lock_enabled:
		p.y = _y_plane
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
	if _goal:
		return _board_cell_of_pos(_goal.global_position)
	return _board_cell_of_pos(global_position)

func _next_from(c: Vector2i) -> Vector2i:
	if _board and _board.has_method("next_cell_from"):
		return _board.call("next_cell_from", c)
	return c

func _max_lane_abs() -> float:
	var half: float = _tile_w * 0.5
	return minf(half * 0.9, lane_spread_tiles * _tile_w)

func _lerp(a: float, b: float, t: float) -> float:
	return a + (b - a) * t

func _is_turn(prev_tan: Vector3, new_tan: Vector3) -> bool:
	return prev_tan.dot(new_tan) < straight_dot_threshold

# Per-tile deterministic jitter in [-1,1]
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

# --------- NEW: blocked/unsafe cell check ----------
func _cell_blocked(c: Vector2i) -> bool:
	if _board == null:
		return false
	# Reserved?
	if _board.has_method("is_cell_reserved") and bool(_board.call("is_cell_reserved", c)):
		return true
	# Non-walkable? (prefer public; fall back to tile_board private)
	if _board.has_method("is_cell_walkable"):
		return not bool(_board.call("is_cell_walkable", c))
	if _board.has_method("_tile_is_walkable"):
		return not bool(_board.call("_tile_is_walkable", c))
	return false

# Effective lane at current _s (applies blend without teleport)
func _lane_at_s() -> float:
	if _blend_active and _blend_len > 0.0:
		var t := clampf((_s - _blend_s0) / _blend_len, 0.0, 1.0)
		if t >= 1.0:
			_blend_active = false
			_lane_w = _blend_to
			return _lane_w
		return _lerp(_blend_from, _blend_to, t)
	return _lane_w

# ===================== Segment build / reprojection =====================
func _init_segment(fresh_spawn: bool) -> void:
	_blend_active = false
	_pending_path_change = false
	_path_change_timer = 0.0
	_segment_retarget_locked = false
	if _board == null:
		return

	_cur_cell = _board_cell_of_pos(global_position)
	_next_cell = _next_from(_cur_cell)

	_a = _cell_center(_cur_cell)
	_b = _cell_center(_next_cell)
	seg__recompute_vectors()

	# Initial lane & per-enemy bias
	if fresh_spawn:
		var max_off := _max_lane_abs()
		_lane_w = randf_range(-max_off, max_off)
		_lane_signature = randf_range(-1.0, 1.0)

	# Start at closest point; keep current lateral
	_reproject_to_segment(true)

func seg__recompute_vectors() -> void:
	_v = _b - _a
	_v.y = 0.0
	_L = _v.length()
	if _L <= 0.0001:
		_tangent = Vector3.FORWARD
		_perp = Vector3.RIGHT
	else:
		_tangent = _v / _L
		_perp = Vector3(-_tangent.z, 0.0, _tangent.x)

func _reproject_to_segment(preserve_lateral: bool) -> void:
	var rel: Vector3 = global_position - _a
	rel.y = 0.0
	var s: float = rel.dot(_tangent)
	_s = clampf(s, 0.0, _L)
	if preserve_lateral:
		var cur_lat: float = rel.dot(_perp)
		var max_off := _max_lane_abs()
		_lane_w = clampf(cur_lat, -max_off, max_off)

# ===================== Physics =====================
func _physics_process(delta: float) -> void:
	# Debounce repeated path changes
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

	var remaining: float = speed * delta
	var max_hops: int = 8

	while remaining > 0.0001 and max_hops > 0:
		max_hops -= 1

		# Degenerate segment? advance
		if _L <= 0.0001:
			_advance_to_next_segment()
			continue

		var take: float = minf(remaining, _L - _s)
		_s += take
		remaining -= take

		var pos_no_lat: Vector3 = _a + _tangent * _s
		var lane_eff := _lane_at_s()
		var desired: Vector3 = pos_no_lat + _perp * lane_eff
		global_position = _apply_y_lock(desired)

		_update_facing_toward(_tangent, delta)

		# ===== Boundary guard: don't step into a newly walled tile =====
		if _s >= _L - 0.00001:
			# If the planned next cell is now blocked, pivot to the new next BEFORE advancing.
			if _cell_blocked(_next_cell):
				var reroute: Vector2i = _next_from(_cur_cell)
				if reroute != _next_cell:
					_pivot_mid_segment_to(reroute)
					continue  # stay in current cell this frame
			# Normal end-of-segment
			if _next_cell == _goal_cell():
				_on_reach_goal()
				return
			_advance_to_next_segment()

	velocity = Vector3.ZERO

# ---- pivot helper used at boundary and for mid-segment retargets ----
func _pivot_mid_segment_to(new_next: Vector2i) -> void:
	var cur_pos: Vector3 = _apply_y_lock(global_position)
	var pb: Vector3 = _cell_center(new_next)

	# New local frame from current position
	var v: Vector3 = pb - cur_pos
	v.y = 0.0
	var L: float = v.length()
	var new_tan: Vector3
	if L > 0.0001:
		new_tan = v / L
	else:
		new_tan = _tangent
	var new_perp: Vector3 = Vector3(-new_tan.z, 0.0, new_tan.x)

	# Keep current lane magnitude in the NEW frame
	var max_off: float = _max_lane_abs()
	var cur_lane: float = clampf(_lane_at_s(), -max_off, max_off)

	# Start the new segment at our current spot (offset back by lane on the new perp)
	var a2: Vector3 = cur_pos - new_perp * cur_lane

	_next_cell = new_next
	_a = a2
	_b = pb
	seg__recompute_vectors()

	# s ~ 0 at the pivot; keep lane in new frame
	var rel: Vector3 = cur_pos - _a
	rel.y = 0.0
	_s = clampf(rel.dot(_tangent), 0.0, _L)
	_lane_w = cur_lane

	# tiny nudge so we don't sit exactly at s=0
	if _L > 0.0 and _s <= 0.0:
		_s = minf(0.0005, _L * 0.05)

# ===================== Advance to next segment =====================
func _advance_to_next_segment() -> void:
	var old_c: Vector2i = _cur_cell
	var new_c: Vector2i = _next_cell
	if old_c != new_c:
		emit_signal("cell_changed", old_c, new_c)

	# Remember old tangent
	var prev_tangent := _tangent

	_cur_cell = _next_cell
	_next_cell = _next_from(_cur_cell)  # adopt latest path

	_a = _cell_center(_cur_cell)
	_b = _cell_center(_next_cell)
	seg__recompute_vectors()

	var max_off := _max_lane_abs()

	if _is_turn(prev_tangent, _tangent):
		# Reproject in NEW frame to measure current lateral correctly
		_reproject_to_segment(true)

		# Compose target lane: partial carry + per-enemy bias + per-tile jitter
		var target := _lane_w * carry_lane_across_turns
		if enable_lane_bias and lane_bias_strength > 0.0:
			target += lane_bias_strength * _lane_signature * max_off
		if enable_lane_jitter and lane_jitter_tiles > 0.0:
			var j := _hash2f(_cur_cell) * (lane_jitter_tiles * _tile_w)
			target += j
		target = clampf(target, -max_off, max_off)
		target = _quantize_lane(target, max_off)

		# Blend from measured lane to target over the first part of the segment
		_blend_from = _lane_w
		_blend_to = target
		_blend_s0 = _s
		_blend_len = maxf(0.0, lane_blend_len_tiles * _tile_w)
		_blend_active = (_blend_len > 0.0)
	else:
		# Straight: preserve current lane exactly (no blend)
		_reproject_to_segment(false)
		_blend_active = false

	# Tiny nudge away from exact endpoints to avoid oscillations
	if _L > 0.0 and _s <= 0.0:
		_s = minf(0.0005, _L * 0.05)

	# Clear any pending path-change request & unlock retargets for the new segment
	_pending_path_change = false
	_segment_retarget_locked = false

# ===================== Path-change handler =====================
func _on_board_changed() -> void:
	if _board == null:
		return

	# Debounce storms of recompute signals
	if _path_change_timer > 0.0:
		_pending_path_change = true
		return
	_path_change_timer = path_change_cooldown

	var new_next: Vector2i = _next_from(_cur_cell)
	if new_next == _next_cell:
		return

	# ---- widened "must retarget": reserved OR blocked ----
	var must_retarget: bool = _cell_blocked(_next_cell)

	# If already retargeted mid-segment once, don't do it again until boundary
	if _segment_retarget_locked and (adopt_path_on_boundary or not must_retarget):
		_pending_path_change = true
		return

	if must_retarget:
		_segment_retarget_locked = lock_retarget_until_boundary
		_pivot_mid_segment_to(new_next)
	else:
		# Not forced: defer or adopt gently
		if adopt_path_on_boundary:
			_pending_path_change = true
		else:
			_pivot_mid_segment_to(new_next)
			if _L > 0.0:
				var min_s2: float = clampf(min_reproject_fraction, 0.0, 0.45) * _L
				_s = maxf(_s, min_s2)

# ===================== Facing =====================
func _update_facing_toward(dir_or_vec: Vector3, delta: float) -> void:
	var v: Vector3 = dir_or_vec
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

# ===================== Goal =====================
func _on_reach_goal() -> void:
	emit_signal("died")
	queue_free()
