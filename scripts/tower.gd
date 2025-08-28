extends Node3D

# ---------- Visuals ----------
@export var projectile_scene: PackedScene
@export var tracer_speed: float = 12.0
@export var max_range: float = 40.0

# ---------- Base combat ----------
@export var base_damage: int = 1                         # used if PowerUps missing
@export var base_fire_rate: float = 1.0                  # seconds per shot (interval)

# ---------- Local fire-rate upgrades (multiplies interval) ----------
@export var rate_mult_per_level: float = 0.90
@export var rate_level_max: int = 10
var rate_level: int = 0

# ---------- Local range upgrades (adds units) ----------
@export var base_acquire_range: float = 0.0              # 0 => auto-detect from shape or 12
@export var range_per_level: float = 2.0
@export var range_level_max: int = 10
var range_level: int = 0

# ---------- Build / minerals ----------
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

# ---------- Derived stats (live) ----------
var _current_damage: int = 1
var _current_fire_rate: float = 1.0        # seconds between shots
var _current_acquire_range: float = 12.0
const _FIRE_RATE_MIN: float = 0.05

var _range_shapes: Array[CollisionShape3D] = []

# =========================================================
# Lifecycle
# =========================================================
func _ready() -> void:
	add_to_group("turret")

	_resolve_minerals()
	if not _attempt_build_payment():
		build_denied.emit(build_cost)
		queue_free()
		return
	build_paid.emit(build_cost)

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

	_gather_range_shapes()
	if base_acquire_range <= 0.0:
		var detected := _detect_initial_range()
		base_acquire_range = (detected if detected > 0.0 else 12.0)

	if PowerUps != null and PowerUps.has_signal("changed"):
		PowerUps.changed.connect(func(): _recompute_stats())

	_recompute_stats()

# =========================================================
# Economy helpers
# =========================================================
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
	if amount <= 0 or _minerals == null:
		return amount <= 0
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
	if _minerals and _minerals.has("minerals"):
		var v = _minerals.get("minerals")
		if typeof(v) == TYPE_INT:
			return int(v)
	return 0

# =========================================================
# Upgrades (local)
# =========================================================
func get_rate_upgrade_cost() -> int:
	if rate_level >= rate_level_max:
		return 0
	return _scaled_cost(12, 1.35, rate_level)

func get_range_upgrade_cost() -> int:
	if range_level >= range_level_max:
		return 0
	return _scaled_cost(10, 1.30, range_level)

func upgrade_fire_rate() -> bool:
	if rate_level >= rate_level_max:
		return false
	var cost := get_rate_upgrade_cost()
	if not _try_spend(cost):
		return false
	rate_level += 1
	_recompute_stats()
	upgraded.emit("fire_rate", rate_level, cost)
	return true

func upgrade_range() -> bool:
	if range_level >= range_level_max:
		return false
	var cost := get_range_upgrade_cost()
	if not _try_spend(cost):
		return false
	range_level += 1
	_recompute_stats()
	upgraded.emit("range", range_level, cost)
	return true

func upgrade_damage() -> bool:
	# Global, via PowerUps
	if PowerUps != null and PowerUps.purchase("turret_damage"):
		_recompute_stats()
		upgraded.emit("damage", 0, 0)
		return true
	return false

func _scaled_cost(base_cost: int, scale: float, level: int) -> int:
	var c := float(base_cost) * pow(max(1.0, scale), max(0, level))
	return int(round(max(1.0, c)))

# =========================================================
# Derived stats
# =========================================================
func _recompute_stats() -> void:
	# Damage
	if PowerUps != null and PowerUps.has_method("turret_damage_value"):
		_current_damage = PowerUps.turret_damage_value()
	else:
		_current_damage = base_damage

	# Fire interval = base * local * global, clamped
	var local_mult := pow(max(0.01, rate_mult_per_level), rate_level)
	var global_mult := 1.0
	if PowerUps != null and PowerUps.has_method("turret_rate_mult"):
		global_mult = maxf(0.01, PowerUps.turret_rate_mult())
	_current_fire_rate = clamp(base_fire_rate * local_mult * global_mult, _FIRE_RATE_MIN, 999.0)

	# Acquire range = base + local + global
	var local_add := range_per_level * float(range_level)
	var global_add := 0.0
	if PowerUps != null and PowerUps.has_method("turret_range_bonus"):
		global_add = PowerUps.turret_range_bonus()
	_current_acquire_range = max(0.5, base_acquire_range + local_add + global_add)
	_apply_range_to_area(_current_acquire_range)

# =========================================================
# Multi-shot helpers
# =========================================================
func _compute_multishot_count() -> int:
	# Returns how many distinct enemies to hit this shot.
	var pct: float = 0.0
	if PowerUps != null and PowerUps.has_method("multishot_percent_value"):
		pct = maxf(0.0, PowerUps.multishot_percent_value())

	# 100% guarantees +1 target; overflow is chance for one more, etc.
	# e.g., 170% => base 1 + 1 guaranteed = 2, plus 70% chance for 3rd.
	var extra_guaranteed: int = int(floor(pct / 100.0))
	var remainder: float = pct - float(extra_guaranteed) * 100.0

	var count: int = 1 + extra_guaranteed
	if remainder > 0.0:
		if randf() * 100.0 < remainder:
			count += 1
	return max(1, count)

func _targets_sorted_by_distance() -> Array[Node3D]:
	var arr: Array[Node3D] = []
	for e in targets_in_range:
		if e != null and is_instance_valid(e):
			arr.append(e)
	# Sort by distance ascending (closest first) — Godot 4 expects a single Callable
	arr.sort_custom(Callable(self, "_cmp_by_distance"))
	return arr

func _cmp_by_distance(a: Node3D, b: Node3D) -> bool:
	var o: Vector3 = global_transform.origin
	var da: float = o.distance_to(a.global_transform.origin)
	var db: float = o.distance_to(b.global_transform.origin)
	return da < db

func _select_victims_widest(count: int) -> Array[Node3D]:
	# Pick up to `count` closest distinct enemies currently in range.
	var sorted: Array[Node3D] = _targets_sorted_by_distance()
	var n: int = min(count, sorted.size())
	var victims: Array[Node3D] = []
	for i in n:
		victims.append(sorted[i])
	return victims

# =========================================================
# Targeting + firing
# =========================================================
func _on_body_entered(body: Node) -> void:
	if body.is_in_group("enemy"):
		targets_in_range.append(body as Node3D)

func _on_body_exited(body: Node) -> void:
	if body.is_in_group("enemy"):
		targets_in_range.erase(body)
		if body == target:
			_disconnect_target_signals()
			target = null

func _process(_dt: float) -> void:
	# prune dead
	var keep: Array[Node3D] = []
	for e in targets_in_range:
		if is_instance_valid(e):
			keep.append(e)
	targets_in_range = keep

	if target == null or not is_instance_valid(target) or not targets_in_range.has(target):
		_disconnect_target_signals()
		target = _select_target()
		if target != null:
			_connect_target_signals(target)

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
	var best_d := INF
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

	# Decide how many enemies to hit this shot; clamp to what's actually in range.
	var want: int = _compute_multishot_count()
	var victims: Array[Node3D] = _select_victims_widest(want)
	if victims.is_empty():
		can_fire = true
		return

	var from: Vector3 = MuzzlePoint.global_position
	var ctx: Dictionary = _build_damage_context()

	# Play muzzle/animation once per shot.
	_play_shoot_fx()

	# Apply to each distinct victim; spawn one tracer per victim.
	for v in victims:
		if v == null or not is_instance_valid(v):
			continue
		var end_pos: Vector3 = v.global_position

		var to_vec: Vector3 = end_pos - from
		var dist: float = to_vec.length()
		if dist > max_range and dist > 0.0001:
			end_pos = from + to_vec.normalized() * max_range

		_apply_damage(v, ctx)
		_spawn_tracer(from, end_pos)

	await get_tree().create_timer(_current_fire_rate).timeout
	can_fire = true

# =========================================================
# Damage context
# =========================================================
func _build_damage_context() -> Dictionary:
	var crit_ch: float = 0.0
	var crit_mul: float = 2.0
	if PowerUps != null:
		if PowerUps.has_method("crit_chance_value"):
			crit_ch = clampf(PowerUps.crit_chance_value(), 0.0, 1.0)
		if PowerUps.has_method("crit_mult_value"):
			crit_mul = maxf(1.0, PowerUps.crit_mult_value())

	return {
		"source": "turret",
		"tags": ["physical", "hitscan"],
		"base": _current_damage,
		"flat_bonus": 0,
		"mult": 1.0,
		"crit_chance": crit_ch,
		"crit_mult": crit_mul
	}

func _apply_damage(enemy: Node, ctx: Dictionary) -> void:
	if enemy and is_instance_valid(enemy) and enemy.has_method("take_damage"):
		enemy.call("take_damage", ctx)

# =========================================================
# Range helpers
# =========================================================
func _gather_range_shapes() -> void:
	_range_shapes.clear()
	_collect_shapes_recursive(DetectionArea)

func _collect_shapes_recursive(n: Node) -> void:
	for c in n.get_children():
		var cs := c as CollisionShape3D
		if cs and cs.shape != null:
			_range_shapes.append(cs)
		_collect_shapes_recursive(c)

func _detect_initial_range() -> float:
	for cs in _range_shapes:
		var s := cs.shape
		if s is SphereShape3D:
			return (s as SphereShape3D).radius
		if s is CylinderShape3D:
			return (s as CylinderShape3D).radius
		if s is CapsuleShape3D:
			return (s as CapsuleShape3D).radius
		if s is BoxShape3D:
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

# =========================================================
# FX
# =========================================================
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
		var dist2: float = start_pos.distance_to(end_pos)
		var dur: float = 0.05
		if tracer_speed > 0.0:
			dur = dist2 / tracer_speed
		dur = max(dur, 0.05)
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

# =========================================================
# Target death wiring
# =========================================================
func _connect_target_signals(t: Node) -> void:
	if t == null:
		return
	if t.has_signal("died") and not t.is_connected("died", Callable(self, "_on_target_died")):
		t.connect("died", Callable(self, "_on_target_died"))

func _disconnect_target_signals() -> void:
	if target == null:
		return
	if target.has_signal("died") and target.is_connected("died", Callable(self, "_on_target_died")):
		target.disconnect("died", Callable(self, "_on_target_died"))

func _on_target_died() -> void:
	_disconnect_target_signals()
	target = null

# =========================================================
# Getters (used by HUD/PowerUps helpers)
# =========================================================
func get_base_fire_rate() -> float:        return float(base_fire_rate)
func get_rate_mult_per_level() -> float:   return float(rate_mult_per_level)
func get_rate_level() -> int:              return int(rate_level)
func get_min_fire_interval() -> float:     return float(_FIRE_RATE_MIN)
func get_current_fire_interval() -> float: return float(_current_fire_rate)

func get_base_acquire_range() -> float:        return float(base_acquire_range)
func get_range_per_level() -> float:           return float(range_per_level)
func get_range_level() -> int:                 return int(range_level)
func get_current_acquire_range() -> float:     return float(_current_acquire_range)
