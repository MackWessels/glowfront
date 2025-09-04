extends Node3D

# -------- Visual / nodes (safe, inspector-configurable) --------
@export var detection_area_path: NodePath
@export var click_body_path: NodePath
@export var yaw_path: NodePath
@export var pitch_path: NodePath
@export var muzzle_point_path: NodePath
@export var smoke_path: NodePath

var DetectionArea: Area3D
var ClickBody: StaticBody3D
var Yaw: Node3D
var Pitch: Node3D
var MuzzlePoint: Node3D
var Smoke: Node

# -------- Projectile / ballistics --------
@export var shell_scene: PackedScene
@export var shell_speed: float = 36.0
@export var gravity: float = 30.0
@export var explosion_radius: float = 3.5

# -------- Shared stats (from PowerUps) --------
@export var base_damage: int = 1
@export var base_fire_rate: float = 1.25
@export var base_acquire_range: float = 18.0

# -------- Mortar identity --------
@export var damage_mult: float = 2.5
@export var fire_interval_mult: float = 2.2
@export var range_mult: float = 1.6
@export var fixed_pitch_deg: float = 55.0

# -------- Runtime --------
var _current_damage: int = 1
var _current_interval: float = 1.0
var _current_range: float = 12.0
var _can_fire := true
var _target: Node3D = null
var _in_range: Array[Node3D] = []

# ---------------- Lifecycle ----------------
func _ready() -> void:
	# Resolve nodes (no onready lookups -> no "Node not found" spam)
	DetectionArea = _resolve_node(detection_area_path, "DetectionArea") as Area3D
	ClickBody     = _resolve_node(click_body_path, "ClickBody") as StaticBody3D

	Yaw           = _resolve_node(yaw_path, "Yaw") as Node3D
	# Prefer searching under Yaw for Pitch and MuzzlePoint if not explicitly set
	Pitch         = _resolve_node(pitch_path, "Pitch", Yaw) as Node3D
	MuzzlePoint   = _resolve_node(muzzle_point_path, "MuzzlePoint", Pitch if Pitch else Yaw) as Node3D
	Smoke         = _resolve_node(smoke_path, "MuzzleSmoke")

	# Hook area signals (guard if area missing)
	if DetectionArea:
		DetectionArea.body_entered.connect(_on_enter)
		DetectionArea.body_exited.connect(_on_exit)

	_recompute_stats()
	_apply_range_to_area(_current_range)

func _process(dt: float) -> void:
	_prune()
	if _target == null or not is_instance_valid(_target) or not _in_range.has(_target):
		_target = _select_target()
	if _target and is_instance_valid(_target):
		_aim_at(_target.global_position)
		if _can_fire:
			_fire_at(_target.global_position)

# ---------------- Targeting ----------------
func _on_enter(b: Node) -> void:
	if b.is_in_group("enemy"):
		_in_range.append(b as Node3D)

func _on_exit(b: Node) -> void:
	if b.is_in_group("enemy"):
		_in_range.erase(b)
		if b == _target:
			_target = null

func _select_target() -> Node3D:
	var best: Node3D = null
	var best_d := INF
	var o := global_transform.origin
	for e in _in_range:
		if e == null:
			continue
		var d := o.distance_to(e.global_transform.origin)
		if d < best_d:
			best_d = d
			best = e
	return best

func _prune() -> void:
	var keep: Array[Node3D] = []
	for e in _in_range:
		if e and is_instance_valid(e):
			keep.append(e)
	_in_range = keep

# ---------------- Fire / ballistics ----------------
func _aim_at(world_target: Vector3) -> void:
	var yaw_node: Node3D = Yaw if Yaw else self
	var pitch_node: Node3D = Pitch if Pitch else yaw_node

	var origin := yaw_node.global_position
	var dir := world_target - origin
	var yaw_angle := atan2(dir.x, dir.z)
	yaw_node.rotation.y = yaw_angle

	pitch_node.rotation.x = -deg_to_rad(clamp(fixed_pitch_deg, 10.0, 80.0))

func _fire_at(world_target: Vector3) -> void:
	_can_fire = false

	var start: Vector3 = MuzzlePoint.global_position if MuzzlePoint else global_position
	var v := _solve_high_arc(start, world_target, shell_speed, gravity)
	if v == Vector3.ZERO:
		var forward := world_target - start
		forward.y = 0.0
		forward = forward.normalized()
		var elev := deg_to_rad(clamp(fixed_pitch_deg, 10.0, 80.0))
		v = forward * (cos(elev) * shell_speed) + Vector3.UP * (sin(elev) * shell_speed)

	_spawn_shell(start, v)

	if Smoke and Smoke.has_method("restart"):
		Smoke.call("restart")
	elif Smoke and Smoke.has_method("set_emitting"):
		Smoke.call("set_emitting", true)

	await get_tree().create_timer(_current_interval).timeout
	_can_fire = true

func _spawn_shell(start: Vector3, vel: Vector3) -> void:
	if shell_scene == null:
		return
	var s := shell_scene.instantiate() as Node3D
	get_tree().current_scene.add_child(s)
	s.global_position = start
	if s.has_method("setup"):
		var dmg := _current_damage
		s.call("setup", start, vel, explosion_radius, dmg, self)
	if s.has("gravity"):
		s.set("gravity", gravity)

# Closed-form ballistic (high arc)
func _solve_high_arc(from: Vector3, to: Vector3, speed: float, g: float) -> Vector3:
	var diff := to - from
	var xz := Vector2(diff.x, diff.z)
	var d := xz.length()
	if d < 0.001:
		return Vector3.ZERO
	var y := diff.y
	var s2 := speed * speed
	var under := s2 * s2 - g * (g * d * d + 2.0 * y * s2)
	if under < 0.0:
		return Vector3.ZERO
	var root := sqrt(under)
	var theta := atan2(s2 + root, g * d)  # high arc
	var dir_h := Vector3(xz.x / d, 0.0, xz.y / d)
	return dir_h * (cos(theta) * speed) + Vector3.UP * (sin(theta) * speed)

# ---------------- Stats ----------------
func _recompute_stats() -> void:
	var dmg := base_damage
	var rate := base_fire_rate
	var rng := base_acquire_range

	var PU: Object = null          
	if Engine.has_singleton("PowerUps"):
		PU = Engine.get_singleton("PowerUps")
	if PU == null and typeof(PowerUps) != TYPE_NIL:
		PU = PowerUps

	if PU != null:
		if PU.has_method("turret_damage_value"):
			dmg = PU.turret_damage_value()
		if PU.has_method("turret_rate_mult"):
			rate *= maxf(0.01, PU.turret_rate_mult())
		if PU.has_method("turret_range_bonus"):
			rng += PU.turret_range_bonus()

	_current_damage   = int(round(max(1.0, float(dmg) * damage_mult)))
	_current_interval = max(0.05, rate * fire_interval_mult)
	_current_range    = max(2.0, rng * range_mult)

	_apply_range_to_area(_current_range)


func _apply_range_to_area(r: float) -> void:
	if not DetectionArea:
		return
	var cs := DetectionArea.get_child(0) as CollisionShape3D
	if cs and cs.shape is SphereShape3D:
		var s := (cs.shape as SphereShape3D).duplicate()
		s.radius = r
		cs.shape = s

# ---------------- Helpers ----------------
func _resolve_node(p: NodePath, name_hint: String, from: Node = null) -> Node:
	var base := from if from else self
	var n: Node = null
	if p != NodePath("") and base.has_node(p):
		n = base.get_node(p)
	if n == null:
		n = base.find_child(name_hint, true, false)
	return n
