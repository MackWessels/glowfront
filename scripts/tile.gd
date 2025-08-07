extends StaticBody3D

@export var turret_scene: PackedScene
@export var wall_scene: PackedScene
@export var placement_menu: PopupMenu

@onready var crack_overlay = $CrackOverlay


var has_turret = false
var grid_x: int
var grid_z: int

var grid_position: Vector2i:
	get:
		return Vector2i(grid_x, grid_z)
	set(value):
		grid_x = value.x
		grid_z = value.y

var tile_board: Node
var is_wall = false
var blocked := false
var is_broken := false
var placed_object: Node = null

func _input_event(camera: Camera3D, event: InputEvent, position: Vector3, normal: Vector3, shape_idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		tile_board.active_tile = self

		# Adjust menu items based on tile state
		placement_menu.clear()
		if is_broken:
			placement_menu.add_item("Repair", 2)
		elif not has_turret and not is_wall:
			placement_menu.add_item("Place Turret", 0)
			placement_menu.add_item("Place Wall", 1)

		# Show the menu
		if placement_menu.item_count > 0:
			placement_menu.position = get_viewport().get_mouse_position()
			placement_menu.popup()

func place_turret():
	if is_broken:
		return
	var turret = turret_scene.instantiate()
	turret.global_position = global_position
	get_tree().get_root().add_child(turret)
	placed_object = turret
	has_turret = true
	set_wall(true)
	blocked = true
	tile_board.update_path()

func place_wall():
	if is_broken:
		return
	var wall = wall_scene.instantiate()
	wall.global_position = global_position
	get_tree().get_root().add_child(wall)
	placed_object = wall
	set_wall(true)
	blocked = true
	tile_board.update_path()

func set_wall(value: bool):
	is_wall = value

func is_walkable() -> bool:
	return not blocked

func apply_placement(action: String):
	match action:
		"turret":
			place_turret()
		"wall":
			place_wall()
		"repair":
			repair_tile()

func break_tile():
	if is_broken:
		return
	blocked = false
	is_wall = false
	has_turret = false
	is_broken = true
	if is_instance_valid(placed_object):
		placed_object.queue_free()
		placed_object = null
	if is_instance_valid(crack_overlay):
		crack_overlay.visible = true

func repair_tile():
	is_broken = false
	if is_instance_valid(crack_overlay):
		crack_overlay.visible = false
