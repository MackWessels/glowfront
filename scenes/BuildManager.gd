extends Node

# ------------ Scene refs (optional) ------------
@export var tile_board_path: NodePath
@export var camera_path: NodePath

# ------------ Picking / layers ------------
const TILE_LAYER_MASK := 1 << 3  # layer 4

# Cursor orb (pixels)
const CURSOR_PX := 22

# ------------ State ------------
var _board: Node = null
var _cam: Camera3D = null

var _armed_action: String = ""     # "", "turret", "wall", "mortar"
var _drag_active: bool = false

var _hover_tile: Node = null
var _hover_tiles: Array[Node] = []  # multi-tile preview (mortar)

var _cursor_orb: TextureRect = null


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

	set_process_input(true)


func _exit_tree() -> void:
	_ensure_cursor_orb(false)


# ================= Public API =================
# Called by toolbar buttons on mouse *down* (begin click-and-hold drag)
func begin_drag(action: String) -> void:
	_armed_action = action
	_drag_active = true
	_ensure_cursor_orb(true)
	get_viewport().set_input_as_handled()   # <- was accept_event()


# Optional: quick-click to arm (without hold)
func arm_build(action: String) -> void:
	_armed_action = action
	_drag_active = false
	_ensure_cursor_orb(true)
	get_viewport().set_input_as_handled()   # optional, also replaces accept_event()



# ================= Input =================
func _input(e: InputEvent) -> void:
	if _cursor_orb:
		_cursor_orb.position = get_viewport().get_mouse_position() - Vector2(CURSOR_PX, CURSOR_PX)

	if _armed_action == "" and not _drag_active:
		return

	if e is InputEventMouseMotion:
		_set_hover_tile(_ray_pick_tile())
		get_viewport().set_input_as_handled()   # <- replaces accept_event()
		return

	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			get_viewport().set_input_as_handled()
		else:
			_try_place_on_hover()
			_drag_active = false
			_disarm()
			get_viewport().set_input_as_handled()
		return



# ================= Hover preview =================
func _set_hover_tile(tile: Node) -> void:
	# clear previous preview
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


# Collect the 2×2 around 'anchor' (top-left anchor rules on your Tile.gd)
func _collect_mortar_tiles(anchor: Node) -> Array[Node]:
	var result: Array[Node] = []
	if _board == null or anchor == null:
		return result

	var tiles_v: Variant = _board.get("tiles")
	if typeof(tiles_v) != TYPE_DICTIONARY:
		return result
	var tiles: Dictionary = tiles_v

	# Get tile grid position
	var pos: Vector2i
	var gp_v: Variant = anchor.get("grid_position")
	if typeof(gp_v) == TYPE_VECTOR2I:
		pos = Vector2i(gp_v)
	else:
		pos = Vector2i(int(anchor.get("grid_x")), int(anchor.get("grid_z")))

	var offsets: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1, 0),
		Vector2i(0, 1), Vector2i(1, 1)
	]
	for off: Vector2i in offsets:
		var c: Vector2i = pos + off
		if tiles.has(c):
			var t: Node = tiles[c]
			if t != null:
				result.append(t)

	return result


# ================= Place =================
func _try_place_on_hover() -> void:
	if _hover_tile == null:
		return
	if not _hover_tile.has_method("apply_placement"):
		return

	# Place on the hovered tile
	_hover_tile.call("apply_placement", _armed_action)

	# IMPORTANT: refresh pathing on the board
	if _board and _board.has_method("_recompute_flow"):
		var ok: bool = bool(_board.call("_recompute_flow"))

		# If your board returns false when the path is blocked, undo placement
		if typeof(ok) == TYPE_BOOL and not ok:
			if _hover_tile.has_method("repair_tile"):
				_hover_tile.call("repair_tile")
			# (Optional) show feedback here (beep/flash)

	# Clean up cursor/drag UI
	_ensure_cursor_orb(false)
	_drag_active = false
	_armed_action = ""


func _disarm() -> void:
	_armed_action = ""
	# clear preview
	for t in _hover_tiles:
		if t and t.has_method("set_pending_blue"):
			t.call("set_pending_blue", false)
	_hover_tiles.clear()
	_hover_tile = null
	_ensure_cursor_orb(false)


# ================= Picking =================
func _ray_pick_tile() -> Node:
	if _cam == null:
		_cam = get_viewport().get_camera_3d()
	if _cam == null:
		return null

	var mp: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = _cam.project_ray_origin(mp)
	var to: Vector3 = from + _cam.project_ray_normal(mp) * 2000.0

	var space := _cam.get_world_3d().direct_space_state
	var p := PhysicsRayQueryParameters3D.create(from, to)
	p.collide_with_areas = false
	p.collide_with_bodies = true
	p.collision_mask = TILE_LAYER_MASK

	var hit: Dictionary = space.intersect_ray(p)
	if hit.is_empty():
		return null

	var col: Object = hit.get("collider")
	if col == null:
		return null

	# climb to the tile script node: look for the placement API
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
		var tr := TextureRect.new()
		tr.texture = tex
		tr.size = Vector2(CURSOR_PX, CURSOR_PX)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.z_index = 100000
		tr.position = get_viewport().get_mouse_position() - Vector2(CURSOR_PX, CURSOR_PX)
		# add to GUI root (Window is fine)
		get_tree().root.add_child(tr)
		_cursor_orb = tr
	else:
		if _cursor_orb and is_instance_valid(_cursor_orb):
			_cursor_orb.queue_free()
		_cursor_orb = null


func _make_circle_tex(sz: int) -> Texture2D:
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	var r: float = float(sz) * 0.5 - 0.5
	var cx: float = (float(sz) - 1.0) * 0.5
	var cy: float = (float(sz) - 1.0) * 0.5
	var ring: float = maxf(1.0, r * 0.16)

	for y in sz:
		for x in sz:
			var dx: float = float(x) - cx
			var dy: float = float(y) - cy
			var d: float = sqrt(dx * dx + dy * dy)
			var a: float = clampf(1.0 - absf(d - r) / ring, 0.0, 1.0)
			if a > 0.0:
				img.set_pixel(x, y, Color(0, 0, 0, a))
	return ImageTexture.create_from_image(img)
