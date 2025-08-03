extends Node3D

@export var enemy_scene: PackedScene
@onready var path = $EnemyPath

var spawn_count = 0



func spawn_enemy():
	if enemy_scene == null:
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
