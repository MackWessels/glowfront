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
	if not enemy_scene or tile_board.cached_path.is_empty():
		print("Cannot spawn enemy: missing scene or path")
		return

	var enemy = enemy_scene.instantiate()
	enemy.path = tile_board.cached_path.duplicate()
	enemy.path_index = 0
	add_child(enemy)
	enemy.global_position = enemy.path[0]
