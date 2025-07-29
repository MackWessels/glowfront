extends CharacterBody3D

@export var speed = 3.0
var path_follow

func _ready():
	path_follow = get_parent()  

func _physics_process(delta):
	if path_follow:
		path_follow.progress += speed * delta
		global_transform.origin = path_follow.global_transform.origin
