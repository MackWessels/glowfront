extends Node3D

@export var projectile_scene: PackedScene
@export var fire_rate: float = 1.0
@export var hit_damage: int = 1
@export var max_range: float = 40.0
@export var tracer_speed: float = 120.0
@export var ray_mask: int = -1

@onready var DetectionArea: Area3D   = $DetectionArea
@onready var Turret: Node3D          = $tower_model/Turret
@onready var MuzzlePoint: Node3D     = $tower_model/Turret/Barrel/MuzzlePoint


var _anim: AnimationPlayer = null
var _muzzle_particles: Node = null   

var can_fire: bool = true
var target: Node3D = null
var targets_in_range: Array[Node3D] = []

func _ready() -> void:
	DetectionArea.body_entered.connect(_on_body_entered)
	DetectionArea.body_exited.connect(_on_body_exited)

	_anim = get_node_or_null("tower_model/AnimationPlayer") as AnimationPlayer
	if _anim == null:
		_anim = get_node_or_null("AnimationPlayer") as AnimationPlayer

	_muzzle_particles = MuzzlePoint.get_node_or_null("MuzzleFlash")
	if _muzzle_particles == null:
		_muzzle_particles = MuzzlePoint.get_node_or_null("GPUParticles3D")
	if _muzzle_particles == null:
		_muzzle_particles = MuzzlePoint.get_node_or_null("CPUParticles3D")

func _on_body_entered(body: Node) -> void:
	if body.is_in_group("enemies"):
		targets_in_range.append(body as Node3D)

func _on_body_exited(body: Node) -> void:
	if body.is_in_group("enemies"):
		targets_in_range.erase(body)
		if body == target:
			_disconnect_target_signals()
			target = null

func _process(_delta: float) -> void:
	# prune freed enemies
	var keep: Array[Node3D] = []
	for e in targets_in_range:
		if is_instance_valid(e):
			keep.append(e)
	targets_in_range = keep

	# maintain lock unless dead/left range
	if target == null or (not is_instance_valid(target)) or (not targets_in_range.has(target)):
		_disconnect_target_signals()
		target = null
		if targets_in_range.size() > 0:
			target = targets_in_range[0]
			_connect_target_signals(target)

	# aim + fire
	if target != null and is_instance_valid(target):
		var turret_pos: Vector3 = Turret.global_position
		var target_pos: Vector3 = target.global_position
		target_pos.y = turret_pos.y
		Turret.look_at(target_pos, Vector3.UP)

		if can_fire:
			fire()

func fire() -> void:
	if target == null or (not is_instance_valid(target)):
		return

	can_fire = false

	var from: Vector3 = MuzzlePoint.global_position
	var to_target: Vector3 = target.global_position
	var dir: Vector3 = (to_target - from).normalized()
	var max_to: Vector3 = from + dir * max_range

	# hitscan 
	var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, max_to)
	query.exclude = [self, Turret, MuzzlePoint]
	query.collision_mask = ray_mask
	query.collide_with_areas = true
	query.collide_with_bodies = true

	var result: Dictionary = space_state.intersect_ray(query)

	var shot_end: Vector3 = max_to
	var hit_enemy: Node = null

	if result.has("position"):
		shot_end = result["position"]
		var collider: Object = result.get("collider", null)
		if collider != null:
			hit_enemy = _find_enemy_root(collider)

	# apply damage immediately
	if hit_enemy != null:
		_apply_damage(hit_enemy, hit_damage)

	# visual projectile + shoot fx
	_spawn_tracer(from, shot_end)
	_play_shoot_fx()

	await get_tree().create_timer(fire_rate).timeout
	can_fire = true

func _spawn_tracer(start_pos: Vector3, end_pos: Vector3) -> void:
	if projectile_scene == null:
		return

	var tracer := projectile_scene.instantiate() as Node3D
	if tracer == null:
		return

	# Add to scene first so transforms are stable
	get_tree().current_scene.add_child(tracer)

	# Position at muzzle
	tracer.global_position = start_pos

	if tracer.has_method("setup"):
		tracer.call("setup", start_pos, end_pos, tracer_speed)
	else:
		var s: Vector3 = tracer.scale
		tracer.look_at(end_pos, Vector3.UP)
		tracer.scale = s

		var dist: float = start_pos.distance_to(end_pos)
		var dur: float = 0.05
		if tracer_speed > 0.0:
			dur = max(dist / tracer_speed, 0.05)

		var tw := get_tree().create_tween()
		tw.tween_property(tracer, "global_position", end_pos, dur)
		tw.tween_callback(tracer.queue_free)


func _play_shoot_fx() -> void:
	if _muzzle_particles != null:
		if _muzzle_particles.has_method("restart"):
			_muzzle_particles.call("restart")
		elif _muzzle_particles.has_method("emitting"):
			_muzzle_particles.set("emitting", false)
			_muzzle_particles.set("emitting", true)

	if _anim != null:
		var clip: StringName = &"shoot"
		if not _anim.has_animation(clip):
			if _anim.has_animation(&"fire"):
				clip = &"fire"
			else:
				var list := _anim.get_animation_list()
				if list.size() > 0:
					clip = list[0]
		_anim.stop()
		_anim.play(clip)

func _find_enemy_root(obj: Object) -> Node:
	var n := obj as Node
	while n != null:
		if n.is_in_group("enemies"):
			return n
		n = n.get_parent()
	return null

func _apply_damage(enemy: Node, amount: int) -> void:
	if enemy.has_method("take_damage"):
		enemy.call("take_damage", amount)
	elif enemy.has_method("apply_damage"):
		enemy.call("apply_damage", amount)
	elif enemy.has_method("hit"):
		enemy.call("hit", amount)

func _connect_target_signals(t: Node) -> void:
	if t == null:
		return
	if t.has_signal("died"):
		if not t.is_connected("died", Callable(self, "_on_target_died")):
			t.connect("died", Callable(self, "_on_target_died"))

func _disconnect_target_signals() -> void:
	if target == null:
		return
	if target.has_signal("died") and target.is_connected("died", Callable(self, "_on_target_died")):
		target.disconnect("died", Callable(self, "_on_target_died"))

func _on_target_died() -> void:
	_disconnect_target_signals()
	target = null
