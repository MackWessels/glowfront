extends Node3D

@export var enemy_scene: PackedScene
@export var tile_board: Node
@export var spawn_interval: float = 1.5

func _ready():
	spawn_enemies()

func spawn_enemies():
	for i in range(30):
		await get_tree().create_timer(spawn_interval).timeout
		spawn_enemy()

func spawn_enemy():
	if not enemy_scene or not tile_board:
		return

	if tile_board.cached_path.is_empty():
			return

	var enemy = enemy_scene.instantiate()
	add_child(enemy)

	enemy.global_position = tile_board.cached_path[0]
	enemy.set_path(tile_board.get_node("Path3D").curve)
	enemy.set_tile_board(tile_board)
