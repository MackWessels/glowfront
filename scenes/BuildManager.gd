extends Node
# Drag-to-place with visible “ghost” cursor. Drop on LMB release.

@export var tile_board_path: NodePath
@export var camera_path: NodePath
@export var tile_ray_mask: int = 1 << 3      # <- Layer 4 (set to 8). Change if your layer differs.
@export var ray_length: float = 2000.0

var _board: Node = null
var _cam: Camera3D = null
var _drag_action: String = ""
var _hover_tile: Node = null

var _ghost_layer: CanvasLayer
var _ghost: TextureRect

func _ready() -> void:
	set_process(true)
	set_process_input(true)
	add_to_group("build_manager")

	# Resolve board
	if tile_board_path != NodePath(""):
		_board = get_node_or_null(tile_board_path)
	else:
		_board = get_tree().root.find_child("TileBoard", true, false)

	# Resolve camera
	if camera_path != NodePath(""):
		_cam = get_node_or_null(camera_path) as Camera3D

	# Minimal “in hand” ghost icon
	_ghost_layer = CanvasLayer.new()
	_ghost_layer.layer = 200
	_ghost_layer.visible = false
	get_tree().root.add_child(_ghost_layer)

	_ghost = TextureRect.new()
	_ghost.size = Vector2(20, 20)
	_ghost.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_ghost.modulate = Color(0, 0, 0, 0.85)
	_ghost.texture = _make_circle_tex(20)
	_ghost_layer.add_child(_ghost)

func _make_circle_tex(sz: int) -> Texture2D:
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var r := float(sz) * 0.45
	var c := Vector2(sz * 0.5, sz * 0.5)
	for y in sz:
		for x in sz:
			if c.distance_to(Vector2(x, y)) <= r:
				img.set_pixel(x, y, Color.BLACK)
	return ImageTexture.create_from_image(img)

# ---------- API from toolbar ----------
func begin_drag(action: String) -> void:
	_drag_action = action
	_hover_tile = null
	Input.set_default_cursor_shape(Input.CURSOR_DRAG)
	_ghost_layer.visible = true
	print("[BuildManager] begin_drag:", action)
	_update_hover()

func end_drag_try_place() -> void:
	if _drag_action == "":
		return
	_update_hover()
	if _hover_tile != null and _board != null:
		print("[BuildManager] place:", _drag_action, "on", _hover_tile.name)
		if _board.has_method("request_build_on_tile"):
			_board.call("request_build_on_tile", _hover_tile, _drag_action)
		else:
			_board.call("set_active_tile", _hover_tile)
			_board.call("_on_place_selected", _drag_action)
	else:
		print("[BuildManager] drop: no valid tile under cursor")
	_cancel_drag_visuals()

func cancel_drag() -> void:
	if _drag_action == "":
		return
	print("[BuildManager] cancel_drag")
	_cancel_drag_visuals()

func _cancel_drag_visuals() -> void:
	_hover_tile = null
	_drag_action = ""
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	_ghost_layer.visible = false


# ---------- Main loop ----------
func _process(_dt: float) -> void:
	if _ghost_layer.visible:
		_ghost.position = get_viewport().get_mouse_position() + Vector2(12, 12)

	if _drag_action != "":
		_update_hover()
		# Even if UI swallows the release, we check the real state:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			end_drag_try_place()

func _input(e: InputEvent) -> void:
	if _drag_action == "":
		return
	var mb := e as InputEventMouseButton
	if mb and mb.pressed and (mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE):
		cancel_drag()
		return
	var ek := e as InputEventKey
	if ek and ek.pressed and ek.keycode == KEY_ESCAPE:
		cancel_drag()

# ---------- Hover sampling ----------
func _update_hover() -> void:
	var cam := _get_cam()
	if cam == null:
		return
	var mp: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = cam.project_ray_origin(mp)
	var to:   Vector3 = from + cam.project_ray_normal(mp) * ray_length

	var space := get_viewport().world_3d.direct_space_state

	# 1) with mask
	var params := PhysicsRayQueryParameters3D.create(from, to)
	params.collision_mask = tile_ray_mask
	var hit := space.intersect_ray(params)

	# 2) debug fallback without mask
	if hit.is_empty():
		var params_all := PhysicsRayQueryParameters3D.create(from, to)
		var hit2 := space.intersect_ray(params_all)
		if not hit2.is_empty():
			var cobj := hit2.get("collider") as CollisionObject3D
			if cobj != null:
				print("[BuildManager] Ray hit (unmasked): ", cobj, "  layer=", cobj.collision_layer)

	var new_tile: Node = null
	if not hit.is_empty():
		var col: Node = hit.get("collider") as Node   # <-- explicit type to avoid Variant warning
		print_verbose("[BuildManager] Ray hit: ", col)
		new_tile = _owning_tile(col)

	if new_tile != _hover_tile:
		if _hover_tile and _board and _board.has_method("clear_active_tile"):
			_board.call("clear_active_tile")
		_hover_tile = new_tile
		if _hover_tile and _board and _board.has_method("set_active_tile"):
			_board.call("set_active_tile", _hover_tile)

func _owning_tile(n: Node) -> Node:
	var cur := n
	while cur:
		# Use '=' (dynamic) so there's no 'inferred from Variant' warning
		var gp = cur.get("grid_position")
		var tb = cur.get("tile_board")

		if typeof(gp) == TYPE_VECTOR2I and tb != null:
			return cur

		# Heuristics if the properties live one level up
		if cur.has_method("apply_placement") or cur.has_method("repair_tile") or cur.has_method("is_walkable"):
			return cur

		cur = cur.get_parent()
	return null


func _get_cam() -> Camera3D:
	if _cam != null:
		return _cam
	return get_viewport().get_camera_3d()
