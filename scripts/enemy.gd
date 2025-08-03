extends CharacterBody3D

@export var speed: float = 3.0
@export var max_health: int = 3
var current_health: int
var path_follow: PathFollow3D
var is_targetable = false

func _ready():
	await get_tree().create_timer(0.1).timeout
	is_targetable = true
	current_health = max_health
	add_to_group("enemies")



func _physics_process(delta):
	if path_follow == null or not is_instance_valid(path_follow):
		return
	if not path_follow.is_inside_tree():
		return

	path_follow.progress += speed * delta
	global_transform.origin = path_follow.global_position

func take_damage(damage_amount: int):
	current_health -= damage_amount
	if current_health <= 0:
		queue_free()
