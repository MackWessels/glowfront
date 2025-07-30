extends CharacterBody3D

@export var speed: float = 3.0
@export var max_health: int = 3
var current_health: int
var path_follow: PathFollow3D

func _ready():
	current_health = max_health
	path_follow = get_parent()

func _physics_process(delta):
	if path_follow == null or not is_instance_valid(path_follow):
		return
	if not path_follow.is_inside_tree():
		return

	path_follow.progress += speed * delta
	global_transform.origin = path_follow.global_transform.origin

func take_damage(damage_amount: int):
	current_health -= damage_amount
	if current_health <= 0:
		queue_free()
