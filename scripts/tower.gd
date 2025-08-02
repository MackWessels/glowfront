extends Node3D

@export var projectile_scene: PackedScene
@export var fire_rate: float = 1.0

@onready var DetectionArea = $DetectionArea
@onready var MuzzlePoint = $tower_model/Turret/Barrel/MuzzlePoint
@onready var Turret = $tower_model/Turret

var can_fire = true
var target = null
var targets_in_range: Array = []

func _ready():
	DetectionArea.body_entered.connect(_on_body_entered)
	DetectionArea.body_exited.connect(_on_body_exited)


func _on_body_entered(body):
	if body.is_in_group("enemies"):
		targets_in_range.append(body)

func _on_body_exited(body):
	if body.is_in_group("enemies"):
		targets_in_range.erase(body)
		if body == target:
			target = null

func _process(delta):
	targets_in_range = targets_in_range.filter(func(e): return is_instance_valid(e))
	if target == null or not is_instance_valid(target) or not targets_in_range.has(target):
		target = null
		if targets_in_range.size() > 0:
			target = targets_in_range[0]

	if target:
		var turret_pos = Turret.global_transform.origin
		var target_pos = target.global_transform.origin
		target_pos.y = turret_pos.y  
		Turret.look_at(target_pos, Vector3.UP)
		if can_fire:
			fire()

func fire():
	if not projectile_scene:
		return
	if not is_instance_valid(target):
		return

	can_fire = false

	var projectile = projectile_scene.instantiate()
	get_tree().current_scene.add_child(projectile)
	projectile.global_transform.origin = MuzzlePoint.global_transform.origin
	projectile.look_at(target.global_transform.origin, Vector3.UP)
	await get_tree().create_timer(fire_rate).timeout

	can_fire = true
