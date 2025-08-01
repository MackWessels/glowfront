extends Node3D

@export var enemy_scene: PackedScene
@onready var path = $EnemyPath

var spawn_count = 0

func _ready():
	for i in range(5):
		spawn_enemy()

	# DEBUG: See if the Tile node is found
	var tile = get_node_or_null("Tile")
	if tile:
		print("Tile is present in Main!")
	else:
		print("Tile NOT found in Main.")


func spawn_enemy():
	if enemy_scene == null:
		print("Enemy scene not assigned!")
		return

	var enemy = enemy_scene.instantiate()
	var follower = PathFollow3D.new()
	follower.progress_ratio = 0.0

	follower.add_child(enemy)
	path.add_child(follower)

	print("Spawned enemy #", spawn_count + 1)
	spawn_count += 1

func _process(delta):
	for follower in path.get_children():
		if follower is PathFollow3D:
			follower.progress_ratio += delta * 0.05
