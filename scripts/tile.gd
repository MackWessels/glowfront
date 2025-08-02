extends StaticBody3D

@export var turret_scene: PackedScene
var has_turret = false
var grid_x: int
var grid_z: int

func _input_event(camera: Camera3D, event: InputEvent, position: Vector3, normal: Vector3, shape_idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if not has_turret:
			place_turret()

func place_turret():
	if turret_scene == null:
		return

	var turret = turret_scene.instantiate()

	var holder = get_tree().get_current_scene().get_node_or_null("TurretHolder")
	if holder:
		holder.add_child(turret)
	else:
		get_tree().get_root().add_child(turret)

	turret.global_position = global_position
	has_turret = true
