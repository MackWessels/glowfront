extends Node3D

@export var enemy_scene: PackedScene
@export var tile_board: Node
@export var spawn_interval: float = 1.5

func _ready():
	spawn_enemies()

func spawn_enemies():
	for i in range(15):
		await get_tree().create_timer(spawn_interval).timeout
		spawn_enemy()

func spawn_enemy():
	if not enemy_scene or not tile_board.has_node("Path3D"):
		print("Missing enemy scene or tile_board Path3D")
		return

	var enemy = enemy_scene.instantiate()
	var path3d = tile_board.get_node("Path3D")
	var curve = path3d.curve

	if curve == null or curve.get_point_count() == 0:
		print("No path curve found")
		return

	# Pass the curve to the enemy
	enemy.set_path(curve)
	add_child(enemy)
