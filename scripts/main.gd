extends Node3D

@export var enemy_scene: PackedScene
@export var spawn_point: Node3D

var enemies_spawned = 0
var max_enemies = 5

func _ready():
	spawn_enemies()

func spawn_enemies():
	var spawn_delay = 1.0
	for i in range(max_enemies):
		await get_tree().create_timer(spawn_delay).timeout

		var enemy_path_follow = PathFollow3D.new()
		var enemy = enemy_scene.instantiate()

		# Set transform of path follow to spawn point
		enemy_path_follow.transform = spawn_point.transform

		# Set the enemy's path follower reference
		enemy.path_follow = enemy_path_follow

		# Attach enemy to path follower and add to EnemyPath
		enemy_path_follow.add_child(enemy)
		$EnemyPath.add_child(enemy_path_follow)

		enemies_spawned += 1
