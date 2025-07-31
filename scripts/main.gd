extends Node3D

@export var enemy_scene: PackedScene
@onready var camera = $OverheadCamera
@onready var path = $EnemyPath

var spawn_count = 0

func _ready():
	for i in range(5):
		spawn_enemy()

func spawn_enemy():
	if enemy_scene == null:
		print("Enemy scene not assigned.")
		return

	var enemy = enemy_scene.instantiate()
	var follower = PathFollow3D.new()
	follower.progress_ratio = 0.0
	follower.add_child(enemy)
	path.add_child(follower)
	spawn_count += 1

func _process(delta):
	for follower in path.get_children():
		if follower is PathFollow3D:
			follower.progress_ratio += delta * 0.05

func _unhandled_input(event):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var from = camera.project_ray_origin(event.position)
		var to = from + camera.project_ray_normal(event.position) * 1000.0

		var space_state = get_world_3d().direct_space_state
		var query = PhysicsRayQueryParameters3D.create(from, to)
		query.collision_mask = 1  # Adjust as needed for your Tile's layer
		var result = space_state.intersect_ray(query)

		if result:
			print("Clicked:", result.collider.name)
			if result.collider.has_method("on_tile_clicked"):
				result.collider.on_tile_clicked()
			else:
				print("Not a tile")
