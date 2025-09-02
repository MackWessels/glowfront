# build_drop_layer.gd
extends Control

@export var tile_board_path: NodePath
@export var camera_path: NodePath
@export var ray_length: float = 2000.0
@export var tile_ray_mask: int = 1 << 0   # set to your tiles' collision layer

var _board: Node = null
var _cam: Camera3D = null
var _drag_active: bool = false

func _ready() -> void:
	# Let clicks pass when *not* dragging; we’ll flip to STOP during drag.
	mouse_filter = Control.MOUSE_FILTER_PASS
	z_index = 1000
	_board = (tile_board_path != NodePath("")) ? get_node_or_null(tile_board_path)
		: get_tree().root.find_child("TileBoard", true, false)
	if camera_path != NodePath(""):
		_cam = get_node_or_null(camera_path) as Camera3D

func _get_cam() -> Camera3D:
	var c: Camera3D = _cam
	if c == null:
		c = get_viewport().get_camera_3d()
	return c

func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_BEGIN:
		_drag_active = true
		mouse_filter = Control.MOUSE_FILTER_STOP  # must capture for can_drop/drop
	elif what == NOTIFICATION_DRAG_END:
		_drag_active = false
		mouse_filter = Control.MOUSE_FILTER_PASS
		_clear_highlight()

# Godot 4: underscore variants
func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY or not data.has("action"):
		_clear_highlight()
		return false
	var tile: Node = _tile_at_screen(at_position)
	if tile != null:
		if _board and _board.has_method("set_active_tile"):
			_board.call("set_active_tile", tile)  # show blue pending highlight
		return true
	_clear_highlight()
	return false

func _drop_data(at_position: Vector2, data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY or not data.has("action"):
		return
	var tile: Node = _tile_at_screen(at_position)
	if tile == null:
		_clear_highlight()
		return
	var action := String(data["action"])  # e.g., "turret"
	if _board and _board.has_method("request_build_on_tile"):
		_board.call("request_build_on_tile", tile, action)
	else:
		if _board:
			_board.call("set_active_tile", tile)
			_board.call("_on_place_selected", action)
	_clear_highlight()

func _clear_highlight() -> void:
	if _board and _board.has_method("clear_active_tile"):
		_board.call("clear_active_tile")

func _tile_at_screen(p: Vector2) -> Node:
	var cam: Camera3D = _get_cam()
	if cam == null:
		return null
	var from: Vector3 = cam.project_ray_origin(p)
	var to:   Vector3 = from + cam.project_ray_normal(p) * ray_length

	var space: PhysicsDirectSpaceState3D = get_viewport().world_3d.direct_space_state
	var params: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to)
	params.collision_mask = tile_ray_mask
	# params.collide_with_areas = true  # enable if your tiles use Area3D
	var hit: Dictionary = space.intersect_ray(params)
	if hit.is_empty():
		return null
	var col: Node = hit.get("collider")
	return _owning_tile(col)

func _owning_tile(n: Node) -> Node:
	var cur := n
	while cur != null:
		if cur.has("grid_position") and cur.has("tile_board"):
			return cur
		cur = cur.get_parent()
	return null
