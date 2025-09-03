extends Node3D

# ------------- Visual / nodes -------------
@onready var DetectionArea: Area3D   = $DetectionArea
@onready var ClickBody: StaticBody3D = $ClickBody
@onready var Yaw: Node3D             = $mortar_model/Yaw
@onready var Pitch: Node3D           = $mortar_model/Yaw/Pitch
@onready var MuzzlePoint: Node3D     = $mortar_model/Yaw/Pitch/MuzzlePoint
@onready var Smoke: Node = $MuzzleSmoke

# ------------- Projectile / ballistics -------------
@export var shell_scene: PackedScene
@export var shell_speed: float = 36.0     # muzzle speed
@export var gravity: float = 30.0         # should match MortarShell
@export var explosion_radius: float = 3.5

# ------------- Shared stats (base from PowerUps like your turret) -------------
@export var base_damage: int = 1
@export var base_fire_rate: float = 1.25  # seconds / shot (before multipliers)
@export var base_acquire_range: float = 18.0

# ------------- Mortar identity (end multipliers) -------------
@export var damage_mult: float = 2.5      # big pop
@export var fire_interval_mult: float = 2.2  # much slower than regular turret
@export var range_mult: float = 1.6       # longer legs
@export var fixed_pitch_deg: float = 55.0 # “mortar-y” arc preference

# ------------- Runtime -------------
var _current_damage: int = 1
var _current_interval: float = 1.0
var _current_range: float = 12.0
var _can_fire := true
var _target: Node3D = null
var _in_range: Array[Node3D] = []

func _ready() -> void:
	# Hook area
	DetectionArea.body_entered.connect(_on_enter)
	DetectionArea.body_exited.connect(_on_exit)
	# Initial stats
	_recompute_stats()
	_apply_range_to_area(_current_range)

func _process(dt: float) -> void:
	# pick target
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
		if e == null: continue
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
	var origin := Yaw.global_position
	var dir := world_target - origin
	var yaw_angle := atan2(dir.x, dir.z)
	Yaw.rotation.y = yaw_angle

	# Use a fixed elevation; visual-only because we compute velocity precisely at fire
	Pitch.rotation.x = deg_to_rad(clamp(fixed_pitch_deg, 10.0, 80.0)) * -1.0

func _fire_at(world_target: Vector3) -> void:
	_can_fire = false

	var start := MuzzlePoint.global_position
	var v := _solve_high_arc(start, world_target, shell_speed, gravity)
	if v == Vector3.ZERO:
		# fallback: lob with fixed pitch and current yaw
		var forward := (world_target - start); forward.y = 0.0
		forward = forward.normalized()
		var elev := deg_to_rad(clamp(fixed_pitch_deg, 10.0, 80.0))
		v = forward * (cos(elev) * shell_speed) + Vector3.UP * (sin(elev) * shell_speed)

	_spawn_shell(start, v)

	if Smoke and Smoke.has_method("restart"):
		Smoke.call("restart")

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

# Closed-form ballistic (high arc). Returns ZERO if impossible.
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
	# High arc
	var theta := atan2(s2 + root, g * d)
	var dir_h := Vector3(xz.x / d, 0.0, xz.y / d)
	var v := dir_h * (cos(theta) * speed) + Vector3.UP * (sin(theta) * speed)
	return v

# ---------------- Stats ----------------
func _recompute_stats() -> void:
	var dmg := base_damage
	var rate := base_fire_rate
	var rng := base_acquire_range

	if Engine.has_singleton("PowerUps"):
		var PU = Engine.get_singleton("PowerUps")
		# If yours aren’t singletons, swap for your autoload node reference
	if typeof(PowerUps) != TYPE_NIL:
		if PowerUps.has_method("turret_damage_value"):
			dmg = PowerUps.turret_damage_value()
		if PowerUps.has_method("turret_rate_mult"):
			rate *= maxf(0.01, PowerUps.turret_rate_mult())
		if PowerUps.has_method("turret_range_bonus"):
			rng += PowerUps.turret_range_bonus()

	_current_damage  = int(round(max(1.0, float(dmg) * damage_mult)))
	_current_interval = max(0.05, rate * fire_interval_mult)
	_current_range   = max(2.0, rng * range_mult)

	_apply_range_to_area(_current_range)

func _apply_range_to_area(r: float) -> void:
	var cs := DetectionArea.get_child(0) as CollisionShape3D
	if cs and cs.shape is SphereShape3D:
		var s := (cs.shape as SphereShape3D).duplicate()
		s.radius = r
		cs.shape = s
