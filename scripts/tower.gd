extends Node3D

@onready var detection_area = $DetectionArea
@onready var turret = $tower_model/Turret
@onready var muzzle_point = $tower_model/Turret/Barrel/MuzzlePoint
@export var projectile_scene: PackedScene

var target: Node3D = null
var shoot_timer := 0.0
const SHOOT_INTERVAL := 1.0

func _ready():
	detection_area.body_entered.connect(_on_body_entered)
	detection_area.body_exited.connect(_on_body_exited)

func _process(delta):
	if target and is_instance_valid(target):
		track_target()
		shoot_timer -= delta
		if shoot_timer <= 0:
			shoot()
			shoot_timer = SHOOT_INTERVAL
	elif target and not is_instance_valid(target):
		target = null

func _on_body_entered(body):
	if body.is_in_group("enemies") and not target:
		target = body

func _on_body_exited(body):
	if body == target:
		target = null

func track_target():
	var direction = (target.global_transform.origin - turret.global_transform.origin).normalized()
	turret.look_at(target.global_transform.origin, Vector3.UP)

func shoot():
	if not projectile_scene: return
	var bullet = projectile_scene.instantiate()
	get_parent().add_child(bullet)
	bullet.global_transform = muzzle_point.global_transform
	bullet.look_at(target.global_transform.origin)
