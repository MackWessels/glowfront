# res://scripts/mortar_tower.gd
extends Node3D

# ---------- Nodes ----------
@export var detection_area_path: NodePath
@export var click_body_path: NodePath
@export var yaw_path: NodePath
@export var pitch_path: NodePath                 # PitchPivot at hinge (child of Yaw)
@export var muzzle_point_path: NodePath
@export var smoke_path: NodePath

# Hinge axis markers (two-point axis = precise)
@export var pitch_axis_a_path: NodePath          # e.g., mortarv2/base/vertPiviot1
@export var pitch_axis_b_path: NodePath          # e.g., mortarv2/base/vertPiviot2
@export var align_pitch_to_axis_on_ready := true

# Scale handling (leave false to keep authored size)
@export var force_unit_scale_on_ready := false
@export var bake_unit_scale_once := false

var DetectionArea: Area3D
var ClickBody: StaticBody3D
var Yaw: Node3D
var Pitch: Node3D                                # the PitchPivot
var MuzzlePoint: Node3D
var Smoke: Node

# ---------- Target filter ----------
@export var enemy_mask: int = 0
@export var enemy_group: String = "enemy"

# ---------- Aiming ----------
@export var yaw_offset_deg: float = 0.0
@export var prefer_low_arc: bool = true
@export var lob_pitch_deg: float = 22.0          # fallback visual tilt
@export var pitch_bias_deg: float = 0.0          # negative aims lower, positive higher

# ---------- Projectile / ballistics ----------
@export var shell_scene: PackedScene
@export var shell_speed: float = 36.0
@export var gravity: float = 30.0
@export var explosion_radius: float = 3.5

# ---------- Base stats ----------
@export var base_damage: int = 1
@export var base_fire_rate: float = 1.25         # seconds/shot
@export var base_acquire_range: float = 18.0

# ---------- Identity multipliers (end of pipeline) ----------
@export var damage_mult: float = 1.0
@export var fire_interval_mult: float = 1.8
@export var range_mult: float = 1.35

# ---------- Runtime ----------
var _current_damage: int = 1
var _current_interval: float = 1.0
var _current_range: float = 12.0
var _can_fire := true
var _target: Node3D = null
var _in_range: Array[Node3D] = []
var _damage_cbs: Dictionary = {}                 # inst_id -> Callable

@export var debug_trace := false


func _ready() -> void:
	# Resolve nodes
	DetectionArea = _resolve_node(detection_area_path, "DetectionArea") as Area3D
	ClickBody     = _resolve_node(click_body_path, "ClickBody") as StaticBody3D
	Yaw           = _resolve_node(yaw_path, "Yaw") as Node3D
	Pitch         = _resolve_node(pitch_path, "PitchPivot", Yaw) as Node3D
	MuzzlePoint   = _resolve_node(muzzle_point_path, "MuzzlePoint", Pitch if Pitch else Yaw) as Node3D
	Smoke         = _resolve_node(smoke_path, "MuzzleSmoke")

	# Optional scale scrub / bake
	if force_unit_scale_on_ready:
		_normalize_scale(self)
		_normalize_scale(Yaw)
		_normalize_scale(Pitch)
	if bake_unit_scale_once:
		_bake_unit_scale_preserving_world(Yaw)
		_bake_unit_scale_preserving_world(Pitch)
		bake_unit_scale_once = false

	# Align the pitch pivot to the axis defined by two markers
	if align_pitch_to_axis_on_ready:
		_align_pitch_to_axis_once()

	# Detection
	if DetectionArea:
		DetectionArea.monitoring = true
		if enemy_mask != 0:
			DetectionArea.collision_mask = enemy_mask
		if not DetectionArea.body_entered.is_connected(_on_enter):
			DetectionArea.body_entered.connect(_on_enter)
		if not DetectionArea.body_exited.is_connected(_on_exit):
			DetectionArea.body_exited.connect(_on_exit)
		for b in DetectionArea.get_overlapping_bodies():
			_on_enter(b)

	# Stats
	if PowerUps != null and PowerUps.has_signal("changed"):
		PowerUps.changed.connect(_recompute_stats)
	_recompute_stats()
	_apply_range_to_area(_current_range)


func _process(_dt: float) -> void:
	_prune()
	var new_target := _select_target()
	if new_target != _target:
		_target = new_target
		if debug_trace and _target:
			print("[mortar] target:", _target.name)

	if _target and is_instance_valid(_target):
		_aim_at(_target.global_position)
		if _can_fire:
			_fire_volley()


# ---------- Targeting ----------
func _on_enter(b: Node) -> void:
	if not (b is Node3D):
		return
	if b.is_in_group(enemy_group) and not _in_range.has(b):
		_in_range.append(b as Node3D)
		if b.has_signal("damaged"):
			var id := b.get_instance_id()
			if not _damage_cbs.has(id):
				var cb := Callable(self, "_on_enemy_damaged").bind(b)
				b.connect("damaged", cb)
				_damage_cbs[id] = cb
		if debug_trace:
			print("[mortar] entered:", b.name)

func _on_exit(b: Node) -> void:
	if not (b is Node3D):
		return
	if b.is_in_group(enemy_group):
		_in_range.erase(b)
		if b == _target:
			_target = null
		var id := b.get_instance_id()
		if _damage_cbs.has(id):
			var cb: Callable = _damage_cbs[id]
			if b.is_connected("damaged", cb):
				b.disconnect("damaged", cb)
			_damage_cbs.erase(id)
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
		return o.distance_to(a.global_transform.origin) < o.distance_to(b.global_transform.origin)
	)
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


# ---------- Fire / ballistics ----------
func _aim_at(world_target: Vector3) -> void:
	var yaw_node: Node3D = (Yaw if Yaw else self)
	var pitch_node: Node3D = (Pitch if Pitch else yaw_node)

	var origin := yaw_node.global_position
	var dir := world_target - origin
	var yaw_angle := atan2(dir.x, dir.z) + deg_to_rad(yaw_offset_deg)
	yaw_node.rotation = Vector3(0.0, yaw_angle, 0.0)

	# start point for ballistic calc
	var start: Vector3 = origin
	if MuzzlePoint != null and is_instance_valid(MuzzlePoint):
		start = MuzzlePoint.global_position

	# compute launch vector
	var v := _solve_arc(start, world_target, shell_speed, gravity, prefer_low_arc)

	var elev_rad: float
	if v == Vector3.ZERO:
		elev_rad = deg_to_rad(clamp(lob_pitch_deg, 2.0, 80.0))  # fallback
	else:
		var v_h := Vector2(v.x, v.z).length()
		elev_rad = atan2(v.y, v_h)

	# nudge up/down visually
	elev_rad += deg_to_rad(pitch_bias_deg)

	# Only pitch on local X
	pitch_node.rotation = Vector3(-elev_rad, 0.0, 0.0)

func _fire_volley() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	_can_fire = false

	var want := _compute_multishot_count()
	var victims := _select_victims_widest(want, _target)
	for v in victims:
		if v and is_instance_valid(v):
			_fire_single(v)

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

	if s.has_method("setup"):
		s.call("setup", start, vel, explosion_radius, dmg, self)
	if s.has_method("set_gravity"):
		s.call("set_gravity", gravity)
	else:
		s.set("gravity", gravity)

# Closed-form ballistic; choose low or high arc
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


# ---------- Stats ----------
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

	_current_damage   = int(round(max(1.0, float(dmg) * damage_mult)))
	_current_interval = max(0.05, interval * fire_interval_mult)
	_current_range    = max(2.0, rng * range_mult)

	_apply_range_to_area(_current_range)

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


# ---------- Chain lightning hook ----------
func _on_enemy_damaged(by: Node, amount: int, killed: bool, victim: Node) -> void:
	if by != self or amount <= 0 or not (victim is Node3D):
		return
	if ChainLightning and ChainLightning.has_method("is_running") and ChainLightning.is_running():
		return
	ChainLightning.try_proc(victim, amount, self)


# ---------- Range shape ----------
func _apply_range_to_area(r: float) -> void:
	if not DetectionArea:
		return
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


# ---------- Helpers ----------
func _resolve_node(p: NodePath, name_hint: String, from: Node = null) -> Node:
	var base := from if from else self
	var n: Node = null
	if p != NodePath("") and base.has_node(p):
		n = base.get_node(p)
	if n == null:
		n = base.find_child(name_hint, true, false)
	return n

func _normalize_scale(n: Node3D) -> void:
	if n:
		n.scale = Vector3.ONE

func _bake_unit_scale_preserving_world(n: Node3D) -> void:
	if n == null:
		return
	var s := n.global_transform.basis.get_scale()
	if s.is_equal_approx(Vector3.ONE):
		return
	for c in n.get_children():
		if c is Node3D:
			var t := (c as Node3D).global_transform
			t.basis = t.basis.scaled(s)
			(c as Node3D).global_transform = t
	n.scale = Vector3.ONE

func _align_pitch_to_axis_once() -> void:
	if pitch_axis_a_path == NodePath("") or pitch_axis_b_path == NodePath(""):
		return
	var a := _resolve_node(pitch_axis_a_path, "vertPiviot1") as Node3D
	var b := _resolve_node(pitch_axis_b_path, "vertPiviot2") as Node3D
	if a == null or b == null or Pitch == null:
		return

	# X points along the hinge (a -> b)
	var axis_x := (b.global_position - a.global_position)
	if axis_x.length() < 0.001:
		return
	axis_x = axis_x.normalized()

	# Choose an up vector (Pythonic ternary form)
	var up := (Yaw.global_transform.basis.y.normalized() if Yaw != null else Vector3.UP)

	# Build an orthonormal basis
	var axis_z := axis_x.cross(up)
	if axis_z.length() < 0.001:
		up = Vector3.FORWARD
		axis_z = axis_x.cross(up)
	axis_z = axis_z.normalized()
	var axis_y := axis_z.cross(axis_x).normalized()

	var basis := Basis(axis_x, axis_y, axis_z)
	var origin := (a.global_position + b.global_position) * 0.5

	# Preserve child world pose while moving the pivot
	var turret := Pitch.get_node_or_null("Turret") as Node3D
	var tpose: Transform3D = (turret.global_transform if turret != null else Transform3D())
	Pitch.global_transform = Transform3D(basis, origin)
	if turret != null:
		turret.global_transform = tpose
