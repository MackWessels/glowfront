extends Camera3D

# ---- TileBoard hookup ----
@export var tile_board_path: NodePath
@export var use_goal_start: bool = true

# ---- Startup framing: above goal, looking INTO the board ----
@export var start_back_distance: float = 6.0
@export var start_hover: float = 12.0
@export var start_pitch_bias_deg: float = -10.0

@export_enum("center", "ahead_tiles") var look_target: String = "ahead_tiles"
@export var aim_ahead_tiles: float = 2.0

@export var start_distance_override: float = -1.0
@export var start_zoom_scale: float = 0.75

# ---- Orbit state ----
@export var focus_point: Vector3 = Vector3.ZERO
@export var distance: float = 12.0
@export var min_distance: float = 4.0
@export var max_distance: float = 80.0
@export var yaw_deg: float = 45.0
@export var pitch_deg: float = -45.0
@export var min_pitch_deg: float = -85.0
@export var max_pitch_deg: float = -10.0

# ---- Feel ----
@export var zoom_step: float = 2.0
@export var keyboard_rotate_speed: float = 90.0   # Q/E degrees per second
@export var drag_pan_speed: float = 1.0           # ≈ world meters per screen pixel at current zoom

# ---- Keyboard panning ----
@export var pan_speed: float = 20.0
@export var pan_fast_mult: float = 2.5
@export var pan_slow_mult: float = 0.5

# ---- Build integration ----
@export var build_manager_path: NodePath
var _build_mgr: Node = null

# ---- Internal state ----
var _pan_offset: Vector3 = Vector3.ZERO
var _snapped_once: bool = false
var _mouse_panning: bool = false
var _pan_start_focus: Vector3 = Vector3.ZERO

func _ready() -> void:
	current = true
	_resolve_build_manager()
	if use_goal_start:
		call_deferred("_try_snap_from_goal")

func _process(delta: float) -> void:
	# Rotate with Q/E
	if Input.is_key_pressed(KEY_Q): yaw_deg -= keyboard_rotate_speed * delta
	if Input.is_key_pressed(KEY_E): yaw_deg += keyboard_rotate_speed * delta

	_pan_with_keyboard(delta)
	_clamp_state()
	_update_transform()

func _unhandled_input(event: InputEvent) -> void:
	# Block camera input when cursor is over interactive UI.
	if _ui_pointer_blocks_mouse():
		if event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_mouse_panning = false
		return

	if event is InputEventMouseButton:
		# Zoom with wheel
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_apply_zoom(-zoom_step); return
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_apply_zoom(zoom_step);  return

		# LMB drag-to-pan when NOT in build/placement mode
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if not _is_build_mode_active():
					_mouse_panning = true
					_pan_start_focus = _get_focus()
			else:
				_mouse_panning = false

	elif event is InputEventMouseMotion:
		# Smooth tablet-style panning: convert pixel delta to world delta.
		if _mouse_panning and not _is_build_mode_active():
			var px_scale := _pixels_to_world_scale()
			var right := global_transform.basis.x; right.y = 0.0; right = right.normalized()
			var fwd   := -global_transform.basis.z; fwd.y   = 0.0; fwd   = fwd.normalized()
			# Drag right -> world moves to the left (subtract right * dx). Drag up -> move forward.
			_pan_offset += (-right * event.relative.x + fwd * event.relative.y) * px_scale
			_update_transform()

# ---------------- Helpers ----------------
func _pixels_to_world_scale() -> float:
	# Convert 1 screen pixel of mouse drag to world meters at current zoom/FOV.
	var h := float(get_viewport().get_visible_rect().size.y)
	if h <= 0.0:
		return 0.0
	if projection == PROJECTION_PERSPECTIVE:
		var meters_per_screen_height := 2.0 * distance * tan(deg_to_rad(fov) * 0.5)
		return (meters_per_screen_height / h) * drag_pan_speed
	else:
		# Orthographic: 'size' is half the screen height in world units.
		return (2.0 * size / h) * drag_pan_speed

var _bm_cached: Node = null
func _bm() -> Node:
	if _bm_cached and is_instance_valid(_bm_cached):
		return _bm_cached
	_bm_cached = get_tree().root.find_child("BuildManager", true, false)
	return _bm_cached

func _is_build_mode_active() -> bool:
	var m := _bm()
	if m and m.has_method("is_build_mode_active"):
		return bool(m.call("is_build_mode_active"))
	return false

func _ui_pointer_blocks_mouse() -> bool:
	var vp := get_viewport()
	var c := vp.gui_get_hovered_control()
	while c != null:
		var ctrl := c as Control
		if ctrl == null: break
		if ctrl.visible and ctrl.mouse_filter != Control.MOUSE_FILTER_IGNORE:
			return true
		c = ctrl.get_parent() as Control
	return false

func _pan_with_keyboard(delta: float) -> void:
	var speed: float = pan_speed
	if Input.is_key_pressed(KEY_SHIFT): speed *= pan_fast_mult
	elif Input.is_key_pressed(KEY_CTRL): speed *= pan_slow_mult

	var v := Vector2.ZERO
	if Input.is_key_pressed(KEY_S): v.y -= 1
	if Input.is_key_pressed(KEY_W): v.y += 1
	if Input.is_key_pressed(KEY_A): v.x -= 1
	if Input.is_key_pressed(KEY_D): v.x += 1
	if Input.is_key_pressed(KEY_DOWN): v.y -= 1
	if Input.is_key_pressed(KEY_UP):   v.y += 1
	if Input.is_key_pressed(KEY_LEFT): v.x -= 1
	if Input.is_key_pressed(KEY_RIGHT):v.x += 1
	if v == Vector2.ZERO: return
	v = v.normalized()

	var right := global_transform.basis.x; right.y = 0.0; right = right.normalized()
	var fwd   := -global_transform.basis.z; fwd.y = 0.0;   fwd   = fwd.normalized()
	_pan_offset += (right * v.x + fwd * v.y) * speed * delta

func _apply_zoom(amount: float) -> void:
	if projection == PROJECTION_ORTHOGONAL:
		size = clampf(size + amount * 0.25, 1.0, 200.0)
	distance = clampf(distance + amount, min_distance, max_distance)

func _clamp_state() -> void:
	pitch_deg = clampf(pitch_deg, min_pitch_deg, max_pitch_deg)
	distance  = clampf(distance,  min_distance, max_distance)
	yaw_deg   = fmod(yaw_deg, 360.0)

func _get_focus() -> Vector3:
	return focus_point + _pan_offset

func _update_transform() -> void:
	var center := _get_focus()
	var yaw := deg_to_rad(yaw_deg)
	var pitch := deg_to_rad(pitch_deg)
	var dir := Vector3(
		cos(pitch) * cos(yaw),
		sin(pitch),
		cos(pitch) * sin(yaw)
	).normalized()
	global_position = center - dir * distance
	look_at(center, Vector3.UP)

# ---------- Startup snapping ----------
func _try_snap_from_goal() -> void:
	if _snapped_once: return
	var tb := _get_tileboard()
	if tb == null:
		call_deferred("_try_snap_from_goal")
		return

	if not (tb.has_method("get_goal_position") and tb.has_method("get_spawn_position")):
		if tb.has_signal("global_path_changed"):
			tb.connect("global_path_changed", Callable(self, "_on_tileboard_ready_once"), CONNECT_ONE_SHOT)
		return

	_snap_goal_over_board(tb)
	_snapped_once = true

func _on_tileboard_ready_once() -> void:
	if _snapped_once: return
	var tb := _get_tileboard()
	if tb and tb.has_method("get_goal_position") and tb.has_method("get_spawn_position"):
		_snap_goal_over_board(tb)
		_snapped_once = true

func _snap_goal_over_board(tb: Node) -> void:
	var goal_pos: Vector3 = Vector3(tb.call("get_goal_position"))
	var spawn_pos: Vector3 = Vector3(tb.call("get_spawn_position"))

	var sx: int = int(tb.get("board_size_x"))
	var sz: int = int(tb.get("board_size_z"))
	var mid := Vector2i(sx >> 1, sz >> 1)
	var board_center: Vector3 = Vector3(tb.call("cell_to_world", mid))

	var into_board: Vector3 = board_center - goal_pos
	into_board.y = 0.0
	if into_board.length_squared() < 1e-6:
		into_board = spawn_pos - goal_pos
		into_board.y = 0.0
	if into_board.length_squared() < 1e-6:
		into_board = Vector3(1, 0, 0)
	into_board = into_board.normalized()

	var cam_pos: Vector3 = goal_pos - into_board * start_back_distance + Vector3.UP * start_hover

	var center: Vector3
	if look_target == "center":
		center = board_center
	else:
		var tile_size: float = float(tb.get("tile_size"))
		center = goal_pos + into_board * (tile_size * aim_ahead_tiles)

	var diff: Vector3 = center - cam_pos
	var base_dist: float = maxf(diff.length(), 0.001)

	yaw_deg = rad_to_deg(atan2(diff.z, diff.x))
	var y_ratio: float = clampf(diff.y / base_dist, -1.0, 1.0)
	pitch_deg = rad_to_deg(asin(y_ratio)) + start_pitch_bias_deg

	var desired_distance: float = clampf(base_dist, min_distance, max_distance)
	if start_distance_override > 0.0:
		desired_distance = clampf(start_distance_override, min_distance, max_distance)
	else:
		desired_distance = clampf(desired_distance * start_zoom_scale, min_distance, max_distance)
	distance = desired_distance

	focus_point = center
	_pan_offset = Vector3.ZERO
	_clamp_state()
	_update_transform()

func _get_tileboard() -> Node:
	if tile_board_path != NodePath():
		var n := get_node_or_null(tile_board_path)
		if n != null: return n
	var list := get_tree().get_nodes_in_group("TileBoard")
	return list[0] if list.size() > 0 else null

func _resolve_build_manager() -> void:
	if build_manager_path != NodePath(""):
		_build_mgr = get_node_or_null(build_manager_path)
	if _build_mgr == null:
		_build_mgr = get_tree().root.find_child("BuildManager", true, false)
