extends Node3D

@onready var turret = $tower_model/Turret
@onready var muzzle_point = $tower_model/Turret/Barrel/MuzzlePoint
@onready var detection_area = $DetectionArea

var target : Node3D = null
var cooldown : float = 1.0
var timer : float = 0.0

var projectile_scene := preload("res://scenes/projectile.tscn")

func _ready():
	detection_area.body_entered.connect(_on_body_entered)
	detection_area.body_exited.connect(_on_body_exited)

func _process(delta):
	if target and is_instance_valid(target):
		# Rotate turret to face target
		turret.look_at(target.global_transform.origin, Vector3.UP)

		# Countdown and shoot if ready
		timer -= delta
		if timer <= 0.0:
			shoot()
			timer = cooldown
	else:
		target = null

func shoot():
	var bullet = projectile_scene.instantiate()
	
	var origin = muzzle_point.global_transform.origin
	var target_pos = target.global_transform.origin
	var direction = (target_pos - origin).normalized()
	bullet.global_transform.origin = origin
	bullet.direction = direction
	get_tree().current_scene.add_child(bullet)

func _on_body_entered(body):
	if body.name == "Enemy" and target == null:
		target = body

func _on_body_exited(body):
	if body == target:
		target = null
