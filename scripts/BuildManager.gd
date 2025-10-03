extends Node

@export var tile_board_path: NodePath
@export var camera_path: NodePath

signal build_mode_changed(armed_action: String, sticky: bool)

const ACTIONS: Array[String] = [
	"turret", "wall", "miner", "mortar", "tesla", "shard_miner", "sniper"
]

var _board: Node = null
var _cam: Camera3D = null
var _armed_action: String = ""
var _sticky: bool = false
var _hover_tile: Node = null

func _ready() -> void:
	_ensure_refs()
	set_process(true)
	set_process_unhandled_input(true)

func arm_build(action: String) -> void:
	if not _is_valid_action(action):
		return
	_ensure_refs()
	if _armed_action != "" and _armed_action != action:
		if _board != null and _board.has_method("clear_active_tile") and _hover_tile != null:
			_board.call("clear_active_tile", _hover_tile)
		_hover_tile = null
	_armed_action = action
	_sticky = true
	_emit_mode()

func set_sticky(on: bool) -> void:
	_sticky = on
	_emit_mode()

func cancel_build() -> void:
	_sticky = false
	_exit_build_mode()

func is_build_mode_active() -> bool:
	return _armed_action != ""

func _process(_dt: float) -> void:
	_ensure_refs()
	if _armed_action == "":
		if _hover_tile != null and _board != null and _board.has_method("clear_active_tile"):
			_board.call("clear_active_tile", _hover_tile)
		_hover_tile = null
		return

	if _is_pointer_over_ui():
		if _hover_tile != null and _board != null and _board.has_method("clear_active_tile"):
			_board.call("clear_active_tile", _hover_tile)
		_hover_tile = null
		return

	var tile: Node = _ray_pick_tile()
	if tile != _hover_tile:
		if _hover_tile != null and _board != null and _board.has_method("clear_active_tile"):
			_board.call("clear_active_tile", _hover_tile)
		_hover_tile = tile
		if _board != null and _board.has_method("set_active_tile") and _hover_tile != null:
			_board.call("set_active_tile", _hover_tile, _armed_action)

func _unhandled_input(e: InputEvent) -> void:
	if _armed_action == "" or _is_pointer_over_ui():
		return

	var mb := e as InputEventMouseButton
	if mb != null and mb.pressed:
		if mb.button_index == MOUSE_BUTTON_LEFT:
			var tile: Node = _ray_pick_tile()
			if tile != null and _board != null and _board.has_method("request_build_on_tile"):
				_board.call("request_build_on_tile", tile, _armed_action)
			get_viewport().set_input_as_handled()
			return
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			cancel_build()
			get_viewport().set_input_as_handled()
			return

	var kb := e as InputEventKey
	if kb != null and kb.pressed and not kb.echo and kb.keycode == KEY_ESCAPE:
		cancel_build()
		get_viewport().set_input_as_handled()

func _exit_build_mode() -> void:
	if _board != null and _board.has_method("clear_active_tile"):
		_board.call("clear_active_tile", _hover_tile)
	_hover_tile = null
	_armed_action = ""
	_emit_mode()

func _ray_pick_tile() -> Node:
	_ensure_refs()
	if _cam == null or _board == null:
		return null

	var mp: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = _cam.project_ray_origin(mp)
	var to: Vector3 = from + _cam.project_ray_normal(mp) * 2000.0
	var dir: Vector3 = (to - from).normalized()

	var space: PhysicsDirectSpaceState3D = _cam.get_world_3d().direct_space_state
	var p := PhysicsRayQueryParameters3D.create(from, to)
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

	var plane_y: float = _board.global_position.y
	var tiles_v: Variant = _board.get("tiles")
	if typeof(tiles_v) == TYPE_DICTIONARY and (tiles_v as Dictionary).size() > 0:
		var any_tile: Node3D = ((tiles_v as Dictionary).values()[0]) as Node3D
		if any_tile != null:
			plane_y = any_tile.global_transform.origin.y
	elif _board.has_method("cell_to_world"):
		var ow: Variant = _board.call("cell_to_world", Vector2i(0, 0))
		plane_y = Vector3(ow).y

	var plane := Plane(Vector3.UP, plane_y)
	var plane_hit: Variant = plane.intersects_ray(from, dir)
	if plane_hit == null:
		return null
	var hitpos: Vector3 = plane_hit as Vector3

	if _board.has_method("world_to_cell"):
		var cv: Variant = _board.call("world_to_cell", hitpos)
		if typeof(cv) == TYPE_VECTOR2I:
			var cell: Vector2i = cv as Vector2i
			var tiles_dict := _board.get("tiles") as Dictionary
			if tiles_dict.has(cell):
				return tiles_dict[cell]

	if typeof(tiles_v) == TYPE_DICTIONARY and (tiles_v as Dictionary).size() > 0:
		var best: Node = null
		var best_d: float = INF
		var tiles3: Dictionary = tiles_v as Dictionary
		for key_v in tiles3.keys():
			var key: Vector2i = key_v as Vector2i
			var pos_w: Vector3 = Vector3.ZERO
			if _board.has_method("cell_to_world"):
				var pos_v: Variant = _board.call("cell_to_world", key)
				pos_w = Vector3(pos_v)
			else:
				var node3: Node3D = tiles3[key_v] as Node3D
				if node3 != null:
					pos_w = node3.global_transform.origin
			var d2: float = (Vector2(pos_w.x, pos_w.z) - Vector2(hitpos.x, hitpos.z)).length_squared()
			if d2 < best_d:
				best_d = d2
				best = tiles3[key_v]
		return best

	return null

func _ensure_refs() -> void:
	if _board == null:
		if tile_board_path != NodePath(""):
			_board = get_node_or_null(tile_board_path)
		if _board == null:
			var boards := get_tree().get_nodes_in_group("TileBoard")
			if boards.size() > 0:
				_board = boards[0]
		if _board == null:
			_board = get_tree().root.find_child("TileBoard", true, false)

	if _cam == null:
		if camera_path != NodePath(""):
			_cam = get_node_or_null(camera_path) as Camera3D
		if _cam == null:
			_cam = get_viewport().get_camera_3d()

func _is_valid_action(a: String) -> bool:
	return ACTIONS.has(a)

func _emit_mode() -> void:
	emit_signal("build_mode_changed", _armed_action, _sticky)

func _is_pointer_over_ui() -> bool:
	var win := get_tree().root
	if win and win.has_method("gui_get_hovered_control"):
		return win.gui_get_hovered_control() != null
	var vp := get_viewport()
	if vp and vp.has_method("gui_pick"):
		return vp.gui_pick(vp.get_mouse_position()) != null
	return false
