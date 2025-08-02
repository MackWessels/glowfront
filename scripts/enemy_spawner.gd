extends Node3D

@export var enemy_scene: PackedScene
@export var spawn_count: int = 5
@export var spawn_interval: float = 1.0
@export var enemy_path: NodePath  # Optional: If using PathFollow3D

var spawned = 0
var timer := Timer.new()

func _ready():
	print("Enemy spawner ready")
	timer.wait_time = spawn_interval
	timer.one_shot = false
	timer.timeout.connect(_on_timer_timeout)
	add_child(timer)
	timer.start()

func _on_timer_timeout():
	if spawned >= spawn_count:
		timer.stop()
		return

	if enemy_scene:
		var enemy = enemy_scene.instantiate()

		# Optional: Set path follow if you have a PathFollow3D system
		if enemy_path != NodePath():
			var path_follower = get_node(enemy_path).duplicate()
			path_follower.add_child(enemy)
			get_tree().current_scene.add_child(path_follower)
		else:
			get_tree().current_scene.add_child(enemy)

		enemy.add_to_group("enemies")  # Ensure turret detects it
		print("Spawned enemy #%d: %s" % [spawned + 1, enemy.name])

		spawned += 1
