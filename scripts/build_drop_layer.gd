extends Control
# Full-screen drop target: raycasts to tiles and tells TileBoard to build.

@export var tile_board_path: NodePath
@export var camera_path: NodePath
@export var ray_length: float = 2000.0
@export var tile_ray_mask: int = 1 << 0   # <- set to the TILE collider layer

var _board: Node = null
var _cam: Camera3D = null
var _drag_active: bool = false

func _ready() -> void:
	# Fill the screen but don't eat input until a drag is happening.
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 1000

	if tile_board_path != NodePath(""):
		_board = get_node_or_null(tile_board_path)
	else:
		_board = get_tree().root.find_child("TileBoard", true, false)

	if camera_path != NodePath(""):
		_cam = get_node_or_null(camera_path) as Camera3D

# Called by the toolbar button right before it starts a drag.
func enable_drag_capture() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Safety: if for some reason a drag doesn’t actually begin, revert soon.
	var t := get_tree().create_timer(0.3)
	t.timeout.connect(func ():
		if not _drag_active:
			mouse_filter = Control.MOUSE_FILTER_IGNORE
	)

func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_BEGIN:
		_drag_active = true
	elif what == NOTIFICATION_DRAG_END:
		_drag_active = false
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_clear_highlight()

func _get_cam() -> Camera3D:
	var c: Camera3D = _cam
	if c == null:
		c = get_viewport().get_camera_3d()
	return c

# ---------------- Drag & Drop (Godot 4 underscore variants) ----------------
func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY or not (data as Dictionary).has("action"):
		_clear_highlight()
		return false
	var tile: Node = _tile_at_screen(at_position)
	if tile != null:
		if _board and _board.has_method("set_active_tile"):
			_board.call("set_active_tile", tile) # your blue highlight
		return true
	_clear_highlight()
	return false

func _drop_data(at_position: Vector2, data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY or not (data as Dictionary).has("action"):
		return
	var tile: Node = _tile_at_screen(at_position)
	if tile == null:
		_clear_highlight(); return

	var action := String((data as Dictionary)["action"])  # "turret", "wall", etc.
	if _board and _board.has_method("request_build_on_tile"):
		_board.call("request_build_on_tile", tile, action)
	else:
		# Fallback if you didn’t add the helper:
		if _board:
			_board.call("set_active_tile", tile)
			_board.call("_on_place_selected", action)

	_clear_highlight()
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _clear_highlight() -> void:
	if _board and _board.has_method("clear_active_tile"):
		_board.call("clear_active_tile")

# ---------------- Raycast into 3D ----------------
func _tile_at_screen(p: Vector2) -> Node:
	var cam: Camera3D = _get_cam()
	if cam == null: return null

	var from: Vector3 = cam.project_ray_origin(p)
	var to:   Vector3 = from + cam.project_ray_normal(p) * ray_length

	var space: PhysicsDirectSpaceState3D = get_viewport().world_3d.direct_space_state
	var params: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to)
	params.collision_mask = tile_ray_mask
	# params.collide_with_areas = true  # enable if your tiles use Area3D

	var hit: Dictionary = space.intersect_ray(params)
	if hit.is_empty(): return null

	var col: Node = hit.get("collider")
	return _owning_tile(col)

func _owning_tile(n: Node) -> Node:
	var cur := n
	while cur != null:
		if cur.has("grid_position") and cur.has("tile_board"): # your tiles expose these
			return cur
		cur = cur.get_parent()
	return null
