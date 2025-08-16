extends Node3D

# ---------- Visuals / feel ----------
@export var projectile_scene: PackedScene
@export var tracer_speed: float = 120.0
@export var max_range: float = 40.0      

# ---------- Combat base ----------
@export var base_damage: int = 1           # starting damage before upgrades
@export var base_fire_rate: float = 1.0    # seconds between shots before upgrades

# ---------- Damage upgrades ----------
@export var dmg_per_level: int = 1
@export var dmg_cost_base: int = 15
@export var dmg_cost_scale: float = 1.4
@export var dmg_level_max: int = 10
var dmg_level: int = 0

# ---------- Fire-rate upgrades (multiplicative; lower = faster) ----------
@export var rate_mult_per_level: float = 0.90   # 10% faster each level
@export var rate_cost_base: int = 12
@export var rate_cost_scale: float = 1.35
@export var rate_level_max: int = 10
var rate_level: int = 0

# ---------- RANGE (target acquisition) upgrades ----------
# base_acquire_range = 0 to auto-read from DetectionArea shape on _ready().
@export var base_acquire_range: float = 0.0
@export var range_per_level: float = 2.0         # linear growth per level
@export var range_cost_base: int = 10
@export var range_cost_scale: float = 1.30
@export var range_level_max: int = 10
var range_level: int = 0

# ---------- Build / Minerals ----------
@export var build_cost: int = 10
@export var minerals_path: NodePath
var _minerals: Node = null
signal build_paid(cost: int)
signal build_denied(cost: int)
signal upgraded(kind: String, new_level: int, cost: int)

# ---------- Targeting ----------
@onready var DetectionArea: Area3D   = $DetectionArea
@onready var Turret: Node3D          = $tower_model/Turret
@onready var MuzzlePoint: Node3D     = $tower_model/Turret/Barrel/MuzzlePoint

var can_fire: bool = true
var target: Node3D = null
var targets_in_range: Array[Node3D] = []

# ---------- FX ----------
var _anim: AnimationPlayer = null
var _muzzle_particles: Node = null

# ---------- Derived stats ----------
var _current_damage: int = 1
var _current_fire_rate: float = 1.0
var _current_acquire_range: float = 12.0
const _FIRE_RATE_MIN: float = 0.05

var _range_shapes: Array[CollisionShape3D] = []

# -------------------------------------------------
# Lifecycle
# -------------------------------------------------
func _ready() -> void:
	_resolve_minerals()
	if not _attempt_build_payment():
		emit_signal("build_denied", build_cost)
		queue_free()
		return
	emit_signal("build_paid", build_cost)

	# Signals for detection
	DetectionArea.body_entered.connect(_on_body_entered)
	DetectionArea.body_exited.connect(_on_body_exited)

	# FX handles
	_anim = get_node_or_null("tower_model/AnimationPlayer") as AnimationPlayer
	if _anim == null:
		_anim = get_node_or_null("AnimationPlayer") as AnimationPlayer
	_muzzle_particles = MuzzlePoint.get_node_or_null("MuzzleFlash")
	if _muzzle_particles == null:
		_muzzle_particles = MuzzlePoint.get_node_or_null("GPUParticles3D")
	if _muzzle_particles == null:
		_muzzle_particles = MuzzlePoint.get_node_or_null("CPUParticles3D")

	# Range shapes
	_gather_range_shapes()
	# If base_acquire_range wasn't set, read it from the existing shape
	if base_acquire_range <= 0.0:
		var detected := _detect_initial_range()
		base_acquire_range = detected if detected > 0.0 else 12.0

	_recompute_stats()

func set_minerals_ref(n: Node) -> void:
	_minerals = n

func _resolve_minerals() -> void:
	if minerals_path != NodePath(""):
		_minerals = get_node_or_null(minerals_path)
	if _minerals == null:
		_minerals = get_node_or_null("/root/Minerals")
	if _minerals == null:
		var root := get_tree().root
		if root != null:
			_minerals = root.find_child("Minerals", true, false)

func _attempt_build_payment() -> bool:
	if build_cost <= 0:
		return true
	return _try_spend(build_cost)

func _try_spend(amount: int) -> bool:
	if amount <= 0:
		return true
	if _minerals == null:
		return false
	if _minerals.has_method("spend"):
		return bool(_minerals.call("spend", amount))

	var ok := false
	if _minerals.has_method("can_afford"):
		ok = bool(_minerals.call("can_afford", amount))
	if ok:
		if _minerals.has_method("set_amount"):
			var cur := _get_balance()
			_minerals.call("set_amount", max(0, cur - amount))
			return true
		if _minerals.has("minerals"):
			var cur2 := 0
			var v = _minerals.get("minerals")
			if typeof(v) == TYPE_INT:
				cur2 = int(v)
			_minerals.set("minerals", max(0, cur2 - amount))
			return true
	return false

func _get_balance() -> int:
	if _minerals == null:
		return 0
	if _minerals.has("minerals"):
		var v = _minerals.get("minerals")
		if typeof(v) == TYPE_INT:
			return int(v)
	return 0

# -------------------------------------------------
# Upgrades
# -------------------------------------------------
func get_damage_upgrade_cost() -> int:
	if dmg_level >= dmg_level_max:
		return 0
	return _scaled_cost(dmg_cost_base, dmg_cost_scale, dmg_level)

func get_rate_upgrade_cost() -> int:
	if rate_level >= rate_level_max:
		return 0
	return _scaled_cost(rate_cost_base, rate_cost_scale, rate_level)

func get_range_upgrade_cost() -> int:
	if range_level >= range_level_max:
		return 0
	return _scaled_cost(range_cost_base, range_cost_scale, range_level)

func upgrade_damage() -> bool:
	if dmg_level >= dmg_level_max:
		return false
	var cost := get_damage_upgrade_cost()
	if not _try_spend(cost):
		return false
	dmg_level += 1
	_recompute_stats()
	emit_signal("upgraded", "damage", dmg_level, cost)
	return true

func upgrade_fire_rate() -> bool:
	if rate_level >= rate_level_max:
		return false
	var cost := get_rate_upgrade_cost()
	if not _try_spend(cost):
		return false
	rate_level += 1
	_recompute_stats()
	emit_signal("upgraded", "fire_rate", rate_level, cost)
	return true

func upgrade_range() -> bool:
	if range_level >= range_level_max:
		return false
	var cost := get_range_upgrade_cost()
	if not _try_spend(cost):
		return false
	range_level += 1
	_recompute_stats()
	emit_signal("upgraded", "range", range_level, cost)
	return true

func _scaled_cost(base_cost: int, scale: float, level: int) -> int:
	var c := float(base_cost) * pow(max(1.0, scale), max(0, level))
	return int(round(max(1.0, c)))

func _recompute_stats() -> void:
	_current_damage = max(1, base_damage + dmg_per_level * dmg_level)

	var mult := pow(max(0.01, rate_mult_per_level), rate_level)
	_current_fire_rate = clamp(base_fire_rate * mult, _FIRE_RATE_MIN, 999.0)

	var base_r := base_acquire_range if base_acquire_range > 0.0 else 12.0
	_current_acquire_range = max(0.5, base_r + range_per_level * float(range_level))
	_apply_range_to_area(_current_acquire_range)

# -------------------------------------------------
# Targeting + Firing
# -------------------------------------------------
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
	# prune invalids
	var keep: Array[Node3D] = []
	for e in targets_in_range:
		if is_instance_valid(e):
			keep.append(e)
	targets_in_range = keep

	# select target
	if target == null or not is_instance_valid(target) or not targets_in_range.has(target):
		_disconnect_target_signals()
		target = _select_target()
		if target != null:
			_connect_target_signals(target)

	# aim + fire
	if target != null and is_instance_valid(target):
		var turret_pos: Vector3 = Turret.global_position
		var target_pos: Vector3 = target.global_position
		target_pos.y = turret_pos.y
		Turret.look_at(target_pos, Vector3.UP)

		if can_fire:
			fire()

func _select_target() -> Node3D:
	if targets_in_range.is_empty():
		return null
	var best: Node3D = null
	var best_d: float = INF
	var origin := global_transform.origin
	for e in targets_in_range:
		if e == null or not is_instance_valid(e):
			continue
		var d := origin.distance_to(e.global_transform.origin)
		if d < best_d:
			best_d = d
			best = e
	return best

func fire() -> void:
	if target == null or not is_instance_valid(target):
		return
	can_fire = false

	var victim := target
	var from: Vector3 = MuzzlePoint.global_position
	var end_pos: Vector3 = victim.global_position
	# Clamp tracer length, not used for targeting
	var to_vec := end_pos - from
	var dist := to_vec.length()
	if dist > max_range and dist > 0.0001:
		end_pos = from + to_vec.normalized() * max_range

	# apply damage directly to locked target
	var ctx := _build_damage_context()
	_apply_damage(victim, ctx)

	# visuals
	_spawn_tracer(from, end_pos)
	_play_shoot_fx()

	await get_tree().create_timer(_current_fire_rate).timeout
	can_fire = true

# -------------------------------------------------
# Damage
# -------------------------------------------------
func _build_damage_context() -> Dictionary:
	return {
		"source": "turret",
		"tags": ["physical", "hitscan"],
		"base": _current_damage,
		"flat_bonus": 0,
		"mult": 1.0,
		"crit_chance": 0.0,
		"crit_mult": 2.0
	}

func _apply_damage(enemy: Node, ctx: Dictionary) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	if enemy.has_method("take_damage"):
		enemy.call("take_damage", ctx)
	elif enemy.has_method("apply_damage"):
		enemy.call("apply_damage", ctx)
	elif enemy.has_method("hit"):
		enemy.call("hit", ctx)

# -------------------------------------------------
# Range helpers
# -------------------------------------------------
func _gather_range_shapes() -> void:
	_range_shapes.clear()
	_collect_shapes_recursive(DetectionArea)

func _collect_shapes_recursive(n: Node) -> void:
	for c in n.get_children():
		var cs := c as CollisionShape3D
		if cs != null and cs.shape != null:
			_range_shapes.append(cs)
		_collect_shapes_recursive(c)

func _detect_initial_range() -> float:
	for cs in _range_shapes:
		var s := cs.shape
		if s is SphereShape3D:
			return (s as SphereShape3D).radius
		elif s is CylinderShape3D:
			return (s as CylinderShape3D).radius
		elif s is CapsuleShape3D:
			return (s as CapsuleShape3D).radius
		elif s is BoxShape3D:
			var sz := (s as BoxShape3D).size
			return max(sz.x, sz.z) * 0.5
	return 0.0

func _apply_range_to_area(r: float) -> void:
	for cs in _range_shapes:
		if cs.shape == null:
			continue
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

# -------------------------------------------------
# FX
# -------------------------------------------------
func _spawn_tracer(start_pos: Vector3, end_pos: Vector3) -> void:
	if projectile_scene == null:
		return
	var tracer := projectile_scene.instantiate() as Node3D
	if tracer == null:
		return
	get_tree().current_scene.add_child(tracer)
	tracer.global_position = start_pos

	if tracer.has_method("setup"):
		tracer.call("setup", start_pos, end_pos, tracer_speed)
	else:
		var s := tracer.scale
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

# -------------------------------------------------
# Target death
# -------------------------------------------------
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
