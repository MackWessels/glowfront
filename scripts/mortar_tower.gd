extends Node3D

# -------- Visual / nodes (inspector-configurable) --------
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

# -------- Target filtering --------
@export var enemy_mask: int = 0                  # set to your enemy layer bits (0 = leave as-is)
@export var enemy_group: String = "enemy"

# -------- Aiming tweaks --------
@export var yaw_offset_deg: float = 0.0          # set to 180 if model faces backwards
@export var prefer_low_arc: bool = true          # shallow lob
@export var lob_pitch_deg: float = 22.0          # visual barrel tilt

# -------- Projectile / ballistics --------
@export var shell_scene: PackedScene
@export var shell_speed: float = 36.0
@export var gravity: float = 30.0
@export var explosion_radius: float = 3.5

# -------- Shared stats (from PowerUps) --------
@export var base_damage: int = 1                 # base before global/meta and end multipliers
@export var base_fire_rate: float = 1.25         # seconds per shot (interval)
@export var base_acquire_range: float = 18.0

# -------- Mortar identity (END-OF-PIPELINE modifiers) --------
# Applied AFTER global/local:
#   final_damage      = global_damage * damage_mult
#   final_interval    = global_interval * fire_interval_mult
#   final_acquire_rng = global_acquire_range * range_mult
@export var damage_mult: float = 1.0             # keep equal to turret by default
@export var fire_interval_mult: float = 1.8      # slower than turret
@export var range_mult: float = 1.35             # longer reach than turret

# -------- Runtime --------
var _current_damage: int = 1
var _current_interval: float = 1.0
var _current_range: float = 12.0
var _can_fire := true
var _target: Node3D = null
var _in_range: Array[Node3D] = []

# Optional debug prints
@export var debug_trace: bool = false

# ---------------- Lifecycle ----------------
func _ready() -> void:
	# Resolve nodes
	DetectionArea = _resolve_node(detection_area_path, "DetectionArea") as Area3D
	ClickBody     = _resolve_node(click_body_path, "ClickBody") as StaticBody3D
	Yaw           = _resolve_node(yaw_path, "Yaw") as Node3D
	Pitch         = _resolve_node(pitch_path, "Pitch", Yaw) as Node3D
	MuzzlePoint   = _resolve_node(muzzle_point_path, "MuzzlePoint", Pitch if Pitch else Yaw) as Node3D
	Smoke         = _resolve_node(smoke_path, "MuzzleSmoke")

	# Setup detection
	if DetectionArea:
		DetectionArea.monitoring = true
		if enemy_mask != 0:
			DetectionArea.collision_mask = enemy_mask
		if not DetectionArea.body_entered.is_connected(_on_enter):
			DetectionArea.body_entered.connect(_on_enter)
		if not DetectionArea.body_exited.is_connected(_on_exit):
			DetectionArea.body_exited.connect(_on_exit)

	# Recompute stats now and whenever PowerUps change
	if PowerUps != null and PowerUps.has_signal("changed"):
		PowerUps.changed.connect(_recompute_stats)

	_recompute_stats()
	_apply_range_to_area(_current_range)

func _process(dt: float) -> void:
	_prune()
	# (re)acquire
	var new_target := _select_target()
	if new_target != _target:
		_target = new_target
		if debug_trace and _target:
			print("[mortar] target:", _target.name)

	# Aim every frame so you can see it track
	if _target and is_instance_valid(_target):
		_aim_at(_target.global_position)
		if _can_fire:
			_fire_volley()  # supports multishot

# ---------------- Targeting ----------------
func _on_enter(b: Node) -> void:
	if b.is_in_group(enemy_group) and not _in_range.has(b):
		_in_range.append(b as Node3D)
		if debug_trace:
			print("[mortar] entered:", b.name)

func _on_exit(b: Node) -> void:
	if b.is_in_group(enemy_group):
		_in_range.erase(b)
		if b == _target:
			_target = null
		if debug_trace:
			print("[mortar] exited:", b.name)

func _select_target() -> Node3D:
	var best: Node3D = null
	var best_d := INF
	var o := global_transform.origin
	for e in _in_range:
		if e == null or not is_instance_valid(e):
			continue
		var d := o.distance_to(e.global_transform.origin)
		if d < best_d:
			best_d = d
			best = e
	return best

func _targets_sorted_by_distance() -> Array[Node3D]:
	var arr: Array[Node3D] = []
	for e in _in_range:
		if e != null and is_instance_valid(e):
			arr.append(e)
	arr.sort_custom(func(a, b):
		var o := global_transform.origin
		return o.distance_to(a.global_transform.origin) < o.distance_to(b.global_transform.origin))
	return arr

func _select_victims_widest(count: int, primary: Node3D) -> Array[Node3D]:
	var sorted := _targets_sorted_by_distance()
	if sorted.has(primary):
		sorted.erase(primary)
	var victims: Array[Node3D] = [primary]
	var extra := clampi(count - 1, 0, sorted.size())
	for i in range(extra):
		victims.append(sorted[i])
	return victims

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
	var yaw_angle := atan2(dir.x, dir.z) + deg_to_rad(yaw_offset_deg)

	# Pure yaw—no accidental roll
	yaw_node.rotation = Vector3(0.0, yaw_angle, 0.0)

	# Visual-only tilt (trajectory is computed on fire)
	pitch_node.rotation = Vector3(-deg_to_rad(clamp(lob_pitch_deg, 2.0, 80.0)), 0.0, 0.0)

func _fire_volley() -> void:
	if _target == null or not is_instance_valid(_target):
		return

	_can_fire = false

	# How many shells this trigger?
	var want := _compute_multishot_count()
	var victims := _select_victims_widest(want, _target)

	# Roll damage once per shell (crit can vary per shell)
	for v in victims:
		if v == null or not is_instance_valid(v):
			continue
		_fire_single(v)

	# smoke once per volley
	if Smoke and Smoke.has_method("restart"):
		Smoke.call("restart")
	elif Smoke and Smoke.has_method("set_emitting"):
		Smoke.call("set_emitting", true)

	await get_tree().create_timer(_current_interval).timeout
	_can_fire = true

func _fire_single(victim: Node3D) -> void:
	var start: Vector3 = (MuzzlePoint.global_position
		if (MuzzlePoint != null and is_instance_valid(MuzzlePoint))
		else global_position)

	var world_target := victim.global_position
	var v: Vector3 = _solve_arc(start, world_target, shell_speed, gravity, prefer_low_arc)

	# Fallback shallow lob if no analytical solution
	if v == Vector3.ZERO:
		var forward := world_target - start
		forward.y = 0.0
		if forward.length() > 0.001:
			forward = forward.normalized()
		var elev := deg_to_rad(clamp(lob_pitch_deg, 2.0, 80.0))
		v = forward * (cos(elev) * shell_speed) + Vector3.UP * (sin(elev) * shell_speed)

	if debug_trace:
		print("[mortar] fire v=", v)

	var dmg := _roll_final_damage_for_shot()
	_spawn_shell(start, v, dmg)

func _spawn_shell(start: Vector3, vel: Vector3, dmg: int) -> void:
	if shell_scene == null:
		if debug_trace:
			print("[mortar] no shell_scene assigned")
		return
	var s := shell_scene.instantiate() as Node3D
	var parent: Node = get_tree().current_scene
	if parent == null:
		parent = get_tree().root
	parent.add_child(s)
	s.global_position = start

	# Preferred: shell exposes setup(start, vel, radius, damage, owner)
	if s.has_method("setup"):
		s.call("setup", start, vel, explosion_radius, dmg, self)
	# Gravity handoff (method or exported variable)
	if s.has_method("set_gravity"):
		s.call("set_gravity", gravity)
	else:
		s.set("gravity", gravity)

# Closed-form ballistic; choose low (shallow) or high (steep) arc
func _solve_arc(from: Vector3, to: Vector3, speed: float, g: float, prefer_low: bool) -> Vector3:
	var diff := to - from
	var xz := Vector2(diff.x, diff.z)
	var d := xz.length()
	if d < 0.001:
		return Vector3.ZERO
	var y := diff.y
	var s2 := speed * speed
	var disc := s2 * s2 - g * (g * d * d + 2.0 * y * s2)
	if disc < 0.0:
		return Vector3.ZERO

	var root := sqrt(disc)
	var theta_low := atan2(s2 - root, g * d)
	var theta_high := atan2(s2 + root, g * d)
	var theta := (theta_low if prefer_low else theta_high)

	var dir_h := Vector3(xz.x / d, 0.0, xz.y / d)
	return dir_h * (cos(theta) * speed) + Vector3.UP * (sin(theta) * speed)

# ---------------- Stats (global + end multipliers) ----------------
func _recompute_stats() -> void:
	var dmg := base_damage
	var interval := base_fire_rate
	var rng := base_acquire_range

	if PowerUps != null:
		if PowerUps.has_method("turret_damage_value"):
			dmg = PowerUps.turret_damage_value()
		if PowerUps.has_method("turret_rate_mult"):
			interval *= maxf(0.01, PowerUps.turret_rate_mult())
		if PowerUps.has_method("turret_range_bonus"):
			rng += PowerUps.turret_range_bonus()

	# End-of-pipeline identity multipliers
	_current_damage   = int(round(max(1.0, float(dmg) * damage_mult)))
	_current_interval = max(0.05, interval * fire_interval_mult)
	_current_range    = max(2.0, rng * range_mult)

	_apply_range_to_area(_current_range)

# Crit + damage roll (per shell)
func _roll_final_damage_for_shot() -> int:
	var total := float(_current_damage)
	if PowerUps != null:
		var crit_ch := 0.0
		var crit_mul := 2.0
		if PowerUps.has_method("crit_chance_value"):
			crit_ch = clampf(PowerUps.crit_chance_value(), 0.0, 1.0)
		if PowerUps.has_method("crit_mult_value"):
			crit_mul = maxf(1.0, PowerUps.crit_mult_value())
		if randf() < crit_ch:
			total *= crit_mul
	return int(maxf(1.0, round(total)))

# Multishot count using your global upgrade (supports >100%)
func _compute_multishot_count() -> int:
	var level := 0
	if PowerUps != null:
		if PowerUps.has_method("applied_for"):
			level = int(PowerUps.applied_for("turret_multishot"))
		if level <= 0 and PowerUps.has_method("total_level"):
			level = int(PowerUps.total_level("turret_multishot"))
	if level <= 0:
		return 1

	var pct := 0.0
	if PowerUps.has_method("multishot_percent_value"):
		pct = maxf(0.0, float(PowerUps.multishot_percent_value()))
	var extras := pct * 0.01
	var whole := int(floor(extras))
	var frac  := extras - float(whole)

	var shots := 1 + whole
	if randf() < frac:
		shots += 1
	return max(1, shots)

# ---------------- Range shape apply ----------------
func _apply_range_to_area(r: float) -> void:
	if not DetectionArea:
		return
	# Try first child shape; safe no-op if none
	var cs := DetectionArea.get_child(0) as CollisionShape3D
	if cs == null or cs.shape == null:
		return
	var s: Shape3D = cs.shape.duplicate()
	s.resource_local_to_scene = true
	if s is SphereShape3D:
		(s as SphereShape3D).radius = r
	elif s is CylinderShape3D:
		(s as CylinderShape3D).radius = r
	elif s is CapsuleShape3D:
		(s as CapsuleShape3D).radius = r
	elif s is BoxShape3D:
		var b := s as BoxShape3D
		var sz := b.size
		b.size = Vector3(r * 2.0, sz.y, r * 2.0)
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
