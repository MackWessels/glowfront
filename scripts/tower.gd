extends Node3D

@export var projectile_scene: PackedScene
@export var fire_rate: float = 1 # seconds between shots; lower = faster

@onready var DetectionArea: Area3D = $DetectionArea
@onready var MuzzlePoint: Node3D = $tower_model/Turret/Barrel/MuzzlePoint
@onready var Turret: Node3D = $tower_model/Turret

var can_fire: bool = true
var target: Node3D = null
var targets_in_range: Array = []

func _ready() -> void:
	DetectionArea.body_entered.connect(_on_body_entered)
	DetectionArea.body_exited.connect(_on_body_exited)

func _on_body_entered(body: Node) -> void:
	if body.is_in_group("enemies"):
		targets_in_range.append(body)

func _on_body_exited(body: Node) -> void:
	if body.is_in_group("enemies"):
		targets_in_range.erase(body)
		if body == target:
			target = null

func _process(delta: float) -> void:
	# prune freed enemies
	targets_in_range = targets_in_range.filter(func(e): return is_instance_valid(e))

	# choose a target if needed
	if target == null or not is_instance_valid(target) or not targets_in_range.has(target):
		target = null
		if targets_in_range.size() > 0:
			# pick the first, or swap this for nearest if you want
			target = targets_in_range[0]

	# aim and fire
	if target:
		var turret_pos := Turret.global_transform.origin
		var target_pos := target.global_transform.origin
		target_pos.y = turret_pos.y
		Turret.look_at(target_pos, Vector3.UP)

		if can_fire:
			fire()

func fire() -> void:
	if not projectile_scene:
		return
	if not is_instance_valid(target):
		return

	can_fire = false

	var projectile := projectile_scene.instantiate()
	get_tree().current_scene.add_child(projectile)
	projectile.global_transform.origin = MuzzlePoint.global_transform.origin

	# Compute shot direction from muzzle to target
	var dir: Vector3 = (target.global_transform.origin - projectile.global_transform.origin).normalized()

	# Face the projectile for visuals (optional)
	projectile.look_at(projectile.global_transform.origin + dir, Vector3.UP)

	# IMPORTANT: tell the projectile which way to move
	projectile.direction = dir

	# cooldown (seconds between shots)
	await get_tree().create_timer(fire_rate).timeout
	can_fire = true
