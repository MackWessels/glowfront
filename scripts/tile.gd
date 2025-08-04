extends StaticBody3D

@export var turret_scene: PackedScene
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

func _input_event(camera: Camera3D, event: InputEvent, position: Vector3, normal: Vector3, shape_idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if not has_turret:
			place_turret()

func place_turret():
	var turret = turret_scene.instantiate()
	turret.global_position = global_position
	get_tree().get_root().add_child(turret)
	has_turret = true
	set_wall(true)
	tile_board.update_path()

func set_wall(value: bool):
	is_wall = value

func is_walkable() -> bool:
	return not is_wall
