extends Node

# -------- Scene refs --------
@export var tile_board_path: NodePath
@export var camera_path: NodePath

# -------- State --------
var _board: Node = null
var _cam: Camera3D = null

# Actions: "", "turret", "wall", "miner", "mortar", "tesla", "shard_miner"
var _armed_action: String = ""
var _sticky: bool = false

var _hover_tile: Node = null

# Orb (visual)
const CURSOR_PX := 22
var _cursor_orb: TextureRect = null

signal build_mode_changed(armed_action: String, sticky: bool)

# ================= Lifecycle =================
func _ready() -> void:
	_ensure_refs()
	set_process(true)
	set_process_unhandled_input(true)

# ================= Public API =================
func arm_build(action: String) -> void:
	if not _is_valid_action(action): return
	_ensure_refs()
	_armed_action = action
	_sticky = true
	_emit_mode()
	_ensure_cursor_orb(true)

func set_sticky(on: bool) -> void:
	_sticky = on
	_emit_mode()

func cancel_build() -> void:
	_sticky = false
	_exit_build_mode()

func is_build_mode_active() -> bool:
	return _armed_action != ""

# ================= Per-frame =================
func _process(_dt: float) -> void:
	_ensure_refs()

	if _cursor_orb != null:
		_cursor_orb.position = get_viewport().get_mouse_position() - Vector2(CURSOR_PX, CURSOR_PX)

	if _armed_action != "":
		var tile: Node = _ray_pick_tile()
		if tile != _hover_tile:
			if _board != null and _board.has_method("clear_active_tile") and _hover_tile != null:
				_board.call("clear_active_tile", _hover_tile)
			_hover_tile = tile
			if _board != null and _board.has_method("set_active_tile"):
				_board.call("set_active_tile", _hover_tile)

# ================= Input (WORLD ONLY) =================
func _unhandled_input(e: InputEvent) -> void:
	if _armed_action == "":
		return

	var mb := e as InputEventMouseButton
	if mb == null:
		return

	# LMB: place on current hover
	if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
		var tile: Node = _ray_pick_tile()
		if tile != null and _board != null and _board.has_method("request_build_on_tile"):
			_board.call("request_build_on_tile", tile, _armed_action)
		get_viewport().set_input_as_handled()

	# RMB: cancel
	elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		cancel_build()
		get_viewport().set_input_as_handled()

# ================= Exit / cleanup =================
func _exit_build_mode() -> void:
	if _board != null and _board.has_method("clear_active_tile"):
		_board.call("clear_active_tile", _hover_tile)
	_hover_tile = null
	_armed_action = ""
	_emit_mode()
	_ensure_cursor_orb(false)

# ================= Picking =================
func _ray_pick_tile() -> Node:
	_ensure_refs()
	if _cam == null or _board == null:
		return null

	# Mouse ray
	var mp: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = _cam.project_ray_origin(mp)
	var to: Vector3 = from + _cam.project_ray_normal(mp) * 2000.0
	var dir: Vector3 = (to - from).normalized()

	var space: PhysicsDirectSpaceState3D = _cam.get_world_3d().direct_space_state

	# 1) Physics ray on ALL layers (bodies + areas)
	var p: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to)
	p.collide_with_bodies = true
	p.collide_with_areas = true
	p.collision_mask = 0x7FFFFFFF
	var hit: Dictionary = space.intersect_ray(p)
	if not hit.is_empty():
		var col: Object = hit.get("collider")
		if col != null:
			var n: Node = col as Node
			while n != null and not n.has_method("apply_placement"):
				n = n.get_parent()
			if n != null:
				return n

	# 2) Plane intersection (use tile Y if available)
	var plane_y: float = _board.global_position.y
	var tiles_v: Variant = _board.get("tiles")
	if typeof(tiles_v) == TYPE_DICTIONARY and (tiles_v as Dictionary).size() > 0:
		var vals: Array = (tiles_v as Dictionary).values()
		var any_tile_v: Variant = vals[0]
		var n3: Node3D = any_tile_v as Node3D
		if n3 != null:
			plane_y = n3.global_transform.origin.y
	elif _board.has_method("cell_to_world"):
		var ow_v: Variant = _board.call("cell_to_world", Vector2i(0, 0))
		plane_y = Vector3(ow_v).y

	var plane := Plane(Vector3.UP, plane_y)
	var hitpos_opt: Variant = plane.intersects_ray(from, dir) # Vector3 or null
	if hitpos_opt == null:
		return null
	var hitpos: Vector3 = hitpos_opt as Vector3

	# world -> cell -> tile
	if _board.has_method("world_to_cell"):
		var cv: Variant = _board.call("world_to_cell", hitpos)
		if typeof(cv) == TYPE_VECTOR2I:
			var cell: Vector2i = cv as Vector2i
			var tiles2: Dictionary = _board.get("tiles") as Dictionary
			if tiles2.has(cell):
				return tiles2[cell]

	# 3) Nearest tile on XZ (last resort)
	if typeof(tiles_v) == TYPE_DICTIONARY and (tiles_v as Dictionary).size() > 0:
		var best: Node = null
		var best_d: float = INF
		var tiles3: Dictionary = tiles_v as Dictionary
		for key_v in tiles3.keys():
			var key: Vector2i = key_v as Vector2i
			var pos_w: Vector3
			if _board.has_method("cell_to_world"):
				var pos_v: Variant = _board.call("cell_to_world", key)
				pos_w = Vector3(pos_v)
			else:
				var node3: Node3D = tiles3[key_v] as Node3D
				pos_w = (node3.global_transform.origin if node3 != null else Vector3.ZERO)
			var d2: float = (Vector2(pos_w.x, pos_w.z) - Vector2(hitpos.x, hitpos.z)).length_squared()
			if d2 < best_d:
				best_d = d2
				best = tiles3[key_v]
		return best

	return null

# ================= Cursor orb =================
func _ensure_cursor_orb(on: bool) -> void:
	if on:
		if _cursor_orb != null: return
		var tex: Texture2D = _make_circle_tex(CURSOR_PX)
		var orb := TextureRect.new()
		orb.texture = tex
		orb.size = Vector2(CURSOR_PX, CURSOR_PX)
		orb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		orb.z_index = RenderingServer.CANVAS_ITEM_Z_MAX - 1
		orb.position = get_viewport().get_mouse_position() - Vector2(CURSOR_PX, CURSOR_PX)
		get_tree().root.add_child(orb)
		_cursor_orb = orb
	else:
		if _cursor_orb != null and is_instance_valid(_cursor_orb):
			_cursor_orb.queue_free()
		_cursor_orb = null

func _make_circle_tex(sz: int) -> Texture2D:
	var img: Image = Image.create(sz, sz, false, Image.FORMAT_RGBA8)
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

# ================= Internals =================
func _ensure_refs() -> void:
	# Board
	if _board == null:
		if tile_board_path != NodePath(""):
			_board = get_node_or_null(tile_board_path)
		if _board == null:
			var boards: Array = get_tree().get_nodes_in_group("TileBoard")
			if boards.size() > 0:
				_board = boards[0]
		if _board == null:
			_board = get_tree().root.find_child("TileBoard", true, false)
	# Camera
	if _cam == null:
		if camera_path != NodePath(""):
			_cam = get_node_or_null(camera_path) as Camera3D
		if _cam == null:
			_cam = get_viewport().get_camera_3d()

func _is_valid_action(a: String) -> bool:
	return a == "turret" or a == "wall" or a == "miner" or a == "mortar" or a == "tesla" or a == "shard_miner"

func _emit_mode() -> void:
	emit_signal("build_mode_changed", _armed_action, _sticky)
