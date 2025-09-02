extends Node
# Drag-to-place: button_down starts a drag; mouse release drops on a tile.

@export var tile_board_path: NodePath
@export var camera_path: NodePath
@export var tile_ray_mask: int = 1 << 0   # set to your TILE layer bit
@export var ray_length: float = 2000.0

var _board: Node = null
var _cam: Camera3D = null

var _drag_action: String = ""     # non-empty while dragging
var _hover_tile: Node = null

func _ready() -> void:
	set_process(true)
	set_process_input(true)

	# Resolve board/camera
	if tile_board_path != NodePath(""):
		_board = get_node_or_null(tile_board_path)
	else:
		_board = get_tree().root.find_child("TileBoard", true, false)

	if camera_path != NodePath(""):
		_cam = get_node_or_null(camera_path) as Camera3D

func begin_drag(action: String) -> void:
	_drag_action = action
	Input.set_default_cursor_shape(Input.CURSOR_DRAG) # “holding” feedback
	_update_hover()                                   # show highlight immediately

func end_drag_try_place() -> void:
	if _drag_action == "":
		return

	_update_hover()  # make sure hover is fresh
	if _hover_tile != null and _board != null:
		if _board.has_method("request_build_on_tile"):
			_board.call("request_build_on_tile", _hover_tile, _drag_action)
		else:
			# Fallback to your existing placement path
			_board.call("set_active_tile", _hover_tile)
			_board.call("_on_place_selected", _drag_action)

	_cancel_drag_visuals()

func cancel_drag() -> void:
	if _drag_action == "":
		return
	_cancel_drag_visuals()

func _cancel_drag_visuals() -> void:
	if _board and _board.has_method("clear_active_tile"):
		_board.call("clear_active_tile")
	_hover_tile = null
	_drag_action = ""
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)

func _process(_dt: float) -> void:
	if _drag_action != "":
		_update_hover()

func _input(e: InputEvent) -> void:
	# Only handle events while dragging
	if _drag_action == "":
		return

	var mb := e as InputEventMouseButton
	if mb and not mb.pressed:
		if mb.button_index == MOUSE_BUTTON_LEFT:
			end_drag_try_place()
		return

	if mb and mb.pressed:
		if mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			cancel_drag()
			return

	var ek := e as InputEventKey
	if ek and ek.pressed and ek.keycode == KEY_ESCAPE:
		cancel_drag()

# -------- helpers --------
func _update_hover() -> void:
	var cam := _get_cam()
	if cam == null:
		return
	var mp: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = cam.project_ray_origin(mp)
	var to:   Vector3 = from + cam.project_ray_normal(mp) * ray_length

	var space := get_viewport().world_3d.direct_space_state
	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.collision_mask = tile_ray_mask
	var hit := space.intersect_ray(params)

	var new_tile: Node = null
	if not hit.is_empty():
		new_tile = _owning_tile(hit.get("collider"))

	if new_tile != _hover_tile:
		# clear previous highlight
		if _hover_tile and _board and _board.has_method("clear_active_tile"):
			_board.call("clear_active_tile")
		_hover_tile = new_tile
		# show new highlight
		if _hover_tile and _board and _board.has_method("set_active_tile"):
			_board.call("set_active_tile", _hover_tile)

func _owning_tile(n: Node) -> Node:
	var cur := n
	while cur:
		if cur.has("grid_position") and cur.has("tile_board"):
			return cur
		cur = cur.get_parent()
	return null

func _get_cam() -> Camera3D:
	if _cam != null:
		return _cam
	return get_viewport().get_camera_3d()
