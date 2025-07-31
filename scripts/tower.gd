extends Node3D

@onready var detection_area = $DetectionArea
@onready var turret = $tower_model/Turret
@onready var muzzle_point = $tower_model/Turret/Barrel/MuzzlePoint
@export var projectile_scene: PackedScene

var target: Node3D = null
var enemies_in_range: Array = []
var shoot_timer := 0.0
const SHOOT_INTERVAL := 1.0

func _ready():
	detection_area.body_entered.connect(_on_body_entered)
	detection_area.body_exited.connect(_on_body_exited)

func _process(delta):
	if target == null or not is_instance_valid(target):
		target = enemies_in_range[0] if enemies_in_range.size() > 0 else null

	if target:
		track_target()
		shoot_timer -= delta
		if shoot_timer <= 0:
			shoot()
			shoot_timer = SHOOT_INTERVAL

func _on_body_entered(body):
	if body.is_in_group("enemies"):
		enemies_in_range.append(body)
		if target == null:
			target = body

func _on_body_exited(body):
	if body in enemies_in_range:
		enemies_in_range.erase(body)
		if body == target:
			target = enemies_in_range[0] if enemies_in_range.size() > 0 else null

func track_target():
	turret.look_at(target.global_transform.origin, Vector3.UP)

func shoot():
	if not projectile_scene or target == null:
		return

	var bullet = projectile_scene.instantiate()
	bullet.global_transform.origin = muzzle_point.global_transform.origin

	var shoot_dir = (target.global_transform.origin - muzzle_point.global_transform.origin).normalized()
	bullet.direction = shoot_dir

	get_parent().add_child(bullet)
