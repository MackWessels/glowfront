extends Node

# -------- Scene refs (optional) --------
@export var tile_board_path: NodePath
@export var camera_path: NodePath
@export var drop_layer_path: NodePath                    # BuildDropLayer (Control) — optional

# Optional toolbar buttons. If set, we’ll auto-connect them.
@export var turret_button_path: NodePath
@export var wall_button_path: NodePath
@export var miner_button_path: NodePath
@export var mortar_button_path: NodePath

# -------- Picking / layers --------
const TILE_LAYER_MASK := 1 << 3   # layer 4
const CURSOR_PX := 22

# -------- State --------
var _board: Node = null
var _cam: Camera3D = null
var _drop: Node = null

# Actions: "", "turret", "wall", "miner", "mortar"
var _armed_action: String = ""
var _drag_active: bool = false

var _hover_tile: Node = null
var _hover_tiles: Array[Node] = []   # multi-tile preview (mortar)

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

	# Drop layer (optional)
	if drop_layer_path != NodePath(""):
		_drop = get_node_or_null(drop_layer_path)

	# Auto-wire toolbar buttons (optional)
	_wire_button(turret_button_path, "turret")
	_wire_button(wall_button_path,   "wall")
	_wire_button(miner_button_path,  "miner")
	_wire_button(mortar_button_path, "mortar")

	set_process(true)

func _wire_button(p: NodePath, action: String) -> void:
	if p == NodePath(""):
		return
	var n := get_node_or_null(p)
	if n == null:
		return
	# If it’s a BaseButton, hook both quick-click and click-and-hold.
	var bb := n as BaseButton
	if bb:
		if not bb.is_connected("button_down", Callable(self, "_on_toolbar_button_down")):
			bb.button_down.connect(_on_toolbar_button_down.bind(action))
		if not bb.is_connected("pressed", Callable(self, "_on_toolbar_pressed")):
			bb.pressed.connect(_on_toolbar_pressed.bind(action))
	else:
		# Fallback: connect generic gui_input for mousedown
		if not n.is_connected("gui_input", Callable(self, "_on_toolbar_gui_input")):
			n.gui_input.connect(_on_toolbar_gui_input.bind(action))

func _on_toolbar_button_down(action: String) -> void:
	# Start a drag (click-and-hold). Ask drop layer to capture.
	if _drop and _drop.has_method("enable_drag_capture"):
		_drop.call("enable_drag_capture")
	begin_drag(action)

func _on_toolbar_pressed(action: String) -> void:
	# Quick-click: arm build without drag.
	arm_build(action)

func _on_toolbar_gui_input(ev: InputEvent, action: String) -> void:
	var mb := ev as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
		if _drop and _drop.has_method("enable_drag_capture"):
			_drop.call("enable_drag_capture")
		begin_drag(action)

# ================= Public API (toolbar / menus) =================
func begin_drag(action: String) -> void:
	if not _is_valid_action(action):
		return
	_armed_action = action
	_drag_active = true
	_ensure_cursor_orb(true)
	get_viewport().set_input_as_handled()

func arm_build(action: String) -> void:
	if not _is_valid_action(action):
		return
	_armed_action = action
	_drag_active = false
	_ensure_cursor_orb(true)
	get_viewport().set_input_as_handled()

func _is_valid_action(a: String) -> bool:
	return a == "turret" or a == "wall" or a == "miner" or a == "mortar"

# ================= Per-frame =================
func _process(_dt: float) -> void:
	if _cursor_orb:
		_cursor_orb.position = get_viewport().get_mouse_position() - Vector2(CURSOR_PX, CURSOR_PX)

	if _armed_action != "" or _drag_active:
		_set_hover_tile(_ray_pick_tile())

		var down := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		if _mouse_down_last and not down:
			_try_place_on_hover()
		_mouse_down_last = down
	else:
		_mouse_down_last = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)

func _exit_tree() -> void:
	_ensure_cursor_orb(false)

# ================= Input (WORLD ONLY) =================
func _unhandled_input(e: InputEvent) -> void:
	if (_armed_action == "" and not _drag_active):
		return
	var mb := e as InputEventMouseButton
	if mb and mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
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
		for t2 in cells:
			if t2 and t2.has_method("set_pending_blue"):
				t2.call("set_pending_blue", true)
			_hover_tiles.append(t2)
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
	if _hover_tile == null or _armed_action == "":
		_exit_build_mode()
		return

	# Delegate placement + path checks to TileBoard.
	if _board and _board.has_method("request_build_on_tile"):
		_board.call("request_build_on_tile", _hover_tile, _armed_action)
	else:
		# Fallback if board doesn’t expose the helper.
		if _hover_tile.has_method("apply_placement"):
			_hover_tile.call("apply_placement", _armed_action)
		if _board and _board.has_method("_recompute_flow"):
			var ok: bool = bool(_board.call("_recompute_flow"))
			if typeof(ok) == TYPE_BOOL and not ok and _hover_tile.has_method("repair_tile"):
				_hover_tile.call("repair_tile")

	_exit_build_mode()

func _exit_build_mode() -> void:
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
