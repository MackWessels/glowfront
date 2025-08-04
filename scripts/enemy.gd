extends CharacterBody3D

@export var speed: float = 3.0
@export var max_health: int = 3
var current_health: int
var is_targetable = false

var path: Array = []
var path_index: int = 0

func _ready():
	await get_tree().create_timer(0.1).timeout
	is_targetable = true
	current_health = max_health
	add_to_group("enemies")

	print("Enemy path:", path)

func _physics_process(delta):
	if path_index >= path.size():
		return

	var target_pos = path[path_index]
	var distance = global_position.distance_to(target_pos)

	if distance < .5:
		global_position = target_pos
		path_index += 1
		velocity = Vector3.ZERO
	else:
		var direction = (target_pos - global_position).normalized()
		velocity = direction * speed

	move_and_slide()
