extends Node

# ------------ Scene refs (optional) ------------
@export var tile_board_path: NodePath
@export var camera_path: NodePath

# ------------ Picking / layers ------------
const TILE_LAYER_MASK := 1 << 3  # layer 4
const CURSOR_PX := 22            # cursor orb size (px)

# ------------ State ------------
var _board: Node = null
var _cam: Camera3D = null

var _armed_action: String = ""     # "", "turret", "wall", "mortar"
var _drag_active: bool = false

var _hover_tile: Node = null
var _hover_tiles: Array[Node] = []  # multi-tile preview (mortar)

var _cursor_orb: TextureRect = null
var _mouse_down_last: bool = false

# ================= Lifecycle =================
func _ready() -> void:
	# Board
	if tile_board_path != NodePath(""):
		_board = get_node_or_null(tile_board_path)
	if _board == null:
		_board = get_tree().root.find_child("TileBoard", true, false)

	# Camera
	if camera_path != NodePath(""):
		_cam = get_node_or_null(camera_path) as Camera3D
	if _cam == null:
		_cam = get_viewport().get_camera_3d()

	set_process(true)  # for cursor orb follow

func _process(_dt: float) -> void:
	# follow the cursor
	if _cursor_orb:
		_cursor_orb.position = get_viewport().get_mouse_position() - Vector2(CURSOR_PX, CURSOR_PX)

	# update hover every frame
	if _armed_action != "" or _drag_active:
		_set_hover_tile(_ray_pick_tile())

		# place on global mouse-up (even if UI consumed the event)
		var down := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		if _mouse_down_last and not down:
			_try_place_on_hover()
		_mouse_down_last = down
	else:
		_mouse_down_last = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)


func _exit_tree() -> void:
	_ensure_cursor_orb(false)


# ================= Public API (toolbar) =================
# Called by toolbar buttons on mouse *down* (begin click-and-hold drag)
func begin_drag(action: String) -> void:
	_armed_action = action
	_drag_active = true
	_ensure_cursor_orb(true)
	get_viewport().set_input_as_handled()   # let the button stay happy

# Optional: quick-click to arm (without hold)
func arm_build(action: String) -> void:
	_armed_action = action
	_drag_active = false
	_ensure_cursor_orb(true)
	get_viewport().set_input_as_handled()


# ================= Input (WORLD ONLY) =================
func _unhandled_input(e: InputEvent) -> void:
	if (_armed_action == "" and not _drag_active):
		return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_RIGHT and e.pressed:
		_exit_build_mode()



# ================= Hover preview =================
func _set_hover_tile(tile: Node) -> void:
	for t in _hover_tiles:
		if t and t.has_method("set_pending_blue"):
			t.call("set_pending_blue", false)
	_hover_tiles.clear()
	_hover_tile = tile

	if tile == null:
		return

	if _armed_action == "mortar":
		var cells := _collect_mortar_tiles(tile)
		for t in cells:
			if t and t.has_method("set_pending_blue"):
				t.call("set_pending_blue", true)
			_hover_tiles.append(t)
	else:
		if tile.has_method("set_pending_blue"):
			tile.call("set_pending_blue", true)
		_hover_tiles.append(tile)

func _collect_mortar_tiles(anchor: Node) -> Array[Node]:
	var result: Array[Node] = []
	if _board == null or anchor == null:
		return result
	var tiles_v: Variant = _board.get("tiles")
	if typeof(tiles_v) != TYPE_DICTIONARY:
		return result
	var tiles: Dictionary = tiles_v

	var pos: Vector2i
	var gp_v: Variant = anchor.get("grid_position")
	if typeof(gp_v) == TYPE_VECTOR2I:
		pos = Vector2i(gp_v)
	else:
		pos = Vector2i(int(anchor.get("grid_x")), int(anchor.get("grid_z")))

	for off in [Vector2i(0,0), Vector2i(1,0), Vector2i(0,1), Vector2i(1,1)]:
		var c: Vector2i = pos + off
		if tiles.has(c):
			var t: Node = tiles[c]
			if t != null:
				result.append(t)
	return result


# ================= Place =================
func _try_place_on_hover() -> void:
	if _hover_tile == null:
		_exit_build_mode()
		return
	if not _hover_tile.has_method("apply_placement"):
		_exit_build_mode()
		return

	_hover_tile.call("apply_placement", _armed_action)

	# Refresh flow/pathing
	if _board and _board.has_method("_recompute_flow"):
		var ok: bool = bool(_board.call("_recompute_flow"))
		if typeof(ok) == TYPE_BOOL and not ok:
			if _hover_tile.has_method("repair_tile"):
				_hover_tile.call("repair_tile")

	_exit_build_mode()

func _exit_build_mode() -> void:
	# clear preview
	for t in _hover_tiles:
		if t and t.has_method("set_pending_blue"):
			t.call("set_pending_blue", false)
	_hover_tiles.clear()
	_hover_tile = null

	_drag_active = false
	_armed_action = ""
	_ensure_cursor_orb(false)


# ================= Picking =================
func _ray_pick_tile() -> Node:
	if _cam == null:
		_cam = get_viewport().get_camera_3d()
	if _cam == null:
		return null

	var mp := get_viewport().get_mouse_position()
	var from := _cam.project_ray_origin(mp)
	var to := from + _cam.project_ray_normal(mp) * 2000.0

	var space := _cam.get_world_3d().direct_space_state
	var p := PhysicsRayQueryParameters3D.create(from, to)
	p.collide_with_areas = false
	p.collide_with_bodies = true
	p.collision_mask = TILE_LAYER_MASK

	var hit := space.intersect_ray(p)
	if hit.is_empty():
		return null

	var col: Object = hit.get("collider")
	if col == null:
		return null

	var n: Node = col as Node
	while n and not n.has_method("apply_placement"):
		n = n.get_parent()
	return n


# ================= Cursor orb =================
func _ensure_cursor_orb(on: bool) -> void:
	if on:
		if _cursor_orb:
			return
		var tex := _make_circle_tex(CURSOR_PX)
		var orb := TextureRect.new()
		orb.texture = tex
		orb.size = Vector2(CURSOR_PX, CURSOR_PX)
		orb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		orb.z_index = RenderingServer.CANVAS_ITEM_Z_MAX - 1
		orb.position = get_viewport().get_mouse_position() - Vector2(CURSOR_PX, CURSOR_PX)
		get_tree().root.add_child(orb)
		_cursor_orb = orb
	else:
		if _cursor_orb and is_instance_valid(_cursor_orb):
			_cursor_orb.queue_free()
		_cursor_orb = null

func _make_circle_tex(sz: int) -> Texture2D:
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var r := float(sz) * 0.5 - 0.5
	var cx := (float(sz) - 1.0) * 0.5
	var cy := (float(sz) - 1.0) * 0.5
	var ring := maxf(1.0, r * 0.16)
	for y in sz:
		for x in sz:
			var dx := float(x) - cx
			var dy := float(y) - cy
			var d := sqrt(dx * dx + dy * dy)
			var a := clampf(1.0 - absf(d - r) / ring, 0.0, 1.0)
			if a > 0.0:
				img.set_pixel(x, y, Color(0, 0, 0, a))
	return ImageTexture.create_from_image(img)
