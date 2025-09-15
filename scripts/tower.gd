extends Node3D
#
# Turret: hitscan BLACK laser + right-click stats + selling + telemetry + range ring
#
var _stats_layer: CanvasLayer = null

# ---------- Visuals ----------
@export var projectile_scene: PackedScene  # kept for compatibility; unused
@export var tracer_speed: float = 12.0     # unused for laser
@export var max_range: float = 40.0

# Laser settings
@export var laser_width: float = 0.12
@export var laser_duration: float = 0.07
@export var laser_color_core: Color = Color(0, 0, 0, 0.95) # black, mostly opaque
@export var laser_color_glow: Color = Color(0, 0, 0, 0.65) # softer outer band

# ---------- Base combat ----------
@export var base_damage: int = 1
@export var base_fire_rate: float = 1.0   # seconds per shot (interval)

# ---------- Local fire-rate upgrades (multiplies interval) ----------
@export var rate_mult_per_level: float = 0.90
@export var rate_level_max: int = 10
var rate_level: int = 0

# ---------- Local range upgrades (adds units) ----------
@export var base_acquire_range: float = 0.0
@export var range_per_level: float = 2.0
@export var range_level_max: int = 10
var range_level: int = 0

# ---------- End-of-pipeline modifiers (variants override these) ----------
# Applied AFTER global/local calculations:
#   fire interval *= rate_mult_end   ( >1 = slower ; <1 = faster )
#   acquire range *= range_mult_end  ( >1 = farther)
#   damage       *= damage_mult_end
@export var rate_mult_end: float = 1.0
@export var range_mult_end: float = 1.0
@export var damage_mult_end: float = 1.0

# Yaw lock (regular turret=true; sniper sets to false)
@export var yaw_only: bool = true

# ---------- Chain lightning (autoload bridge helpers) ----------
@export var chain_debug_prints: bool = true
@export var chain_force_test: bool = false   # set true to force zaps for verification

# ---------- Build / minerals ----------
@export var build_cost: int = 10
@export var minerals_path: NodePath
@export var sell_refund_percent: int = 60
var _minerals: Node = null
signal build_paid(cost: int)
signal build_denied(cost: int)
signal upgraded(kind: String, new_level: int, cost: int)

# ---------- TileBoard context ----------
@export var tile_board_path: NodePath
var _tile_board: Node = null
var _tile_cell: Vector2i = Vector2i(-9999, -9999)
func set_tile_context(board: Node, cell: Vector2i) -> void:
	_tile_board = board
	_tile_cell  = cell

# ---------- Targeting ----------
var DetectionArea: Area3D = null
var Turret: Node3D = null
var MuzzlePoint: Node3D = null
var ClickBody: StaticBody3D = null
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

# ---------- Telemetry ----------
var _spent_local: int = 0
var _lifetime_s: float = 0.0
var _shots_fired: int = 0
var _hits_landed: int = 0
var _kills: int = 0
var _true_damage_done: int = 0

# ---------- Stats UI ----------
var _stats_window: AcceptDialog = null
var _stats_label: Label = null
var _ui_refresh_accum: float = 0.0

# ---------- Range ring ----------
@export var range_ring_color: Color = Color(0.25, 0.9, 1.0, 0.35)
@export var range_ring_thickness: float = 0.15
@export var range_ring_height: float = 0.02
var _range_ring: MeshInstance3D = null

# =========================================================
# Lifecycle
# =========================================================
func _ready() -> void:
	add_to_group("turret")

	# Bind nodes in a path-agnostic way (supports different scene hierarchies)
	_bind_nodes_if_missing()

	_resolve_minerals()
	if tile_board_path != NodePath(""):
		_tile_board = get_node_or_null(tile_board_path)

	if not _attempt_build_payment():
		build_denied.emit(build_cost)
		queue_free()
		return
	_spent_local += max(0, build_cost)
	build_paid.emit(build_cost)

	if DetectionArea:
		DetectionArea.body_entered.connect(_on_body_entered)
		DetectionArea.body_exited.connect(_on_body_exited)
	if ClickBody and not ClickBody.is_connected("input_event", Callable(self, "_on_clickbody_input")):
		ClickBody.input_event.connect(_on_clickbody_input)

	# Flexible FX lookups
	_anim = _try_node([
		"tower_model/AnimationPlayer",
		"sniper_tower_model/AnimationPlayer",
		"AnimationPlayer"
	]) as AnimationPlayer

	if MuzzlePoint:
		_muzzle_particles = MuzzlePoint.get_node_or_null("MuzzleFlash")
		if _muzzle_particles == null:
			_muzzle_particles = MuzzlePoint.get_node_or_null("GPUParticles3D")
		if _muzzle_particles == null:
			_muzzle_particles = MuzzlePoint.get_node_or_null("CPUParticles3D")

	_gather_range_shapes()
	if base_acquire_range <= 0.0:
		var detected := _detect_initial_range()
		if detected > 0.0:
			base_acquire_range = detected
		else:
			base_acquire_range = 12.0

	if PowerUps != null and PowerUps.has_signal("changed"):
		PowerUps.changed.connect(_recompute_stats)

	_recompute_stats()

# =========================================================
# Process (aim only when ready; fire immediately after aim)
# =========================================================
func _process(dt: float) -> void:
	_lifetime_s += dt

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

	# Aim only when ready to shoot (prevents pointing at someone we won't fire at)
	if Turret != null and target != null and is_instance_valid(target) and can_fire:
		var tpos: Vector3 = Turret.global_position
		var aim: Vector3 = _aim_point_of(target)
		if yaw_only:
			aim.y = tpos.y   # lock pitch for regular turrets
		Turret.look_at(aim, Vector3.UP)
		fire()

	if _stats_window != null and _stats_window.visible:
		_ui_refresh_accum += dt
	if _ui_refresh_accum > 0.25:
		_ui_refresh_accum = 0.0
		_refresh_stats_text()

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

func _try_refund(amount: int) -> void:
	if amount <= 0 or _minerals == null:
		return
	if _minerals.has_method("add"):
		_minerals.call("add", amount); return
	if _minerals.has_method("set_amount"):
		var cur := _get_balance(); _minerals.call("set_amount", cur + amount); return
	if _minerals.has("minerals"):
		var cur2 := 0
		var v = _minerals.get("minerals")
		if typeof(v) == TYPE_INT: cur2 = int(v)
		_minerals.set("minerals", cur2 + amount)

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
	if rate_level >= rate_level_max: return false
	var cost := get_rate_upgrade_cost()
	if not _try_spend(cost): return false
	_spent_local += cost
	rate_level += 1
	_recompute_stats()
	upgraded.emit("fire_rate", rate_level, cost)
	return true

func upgrade_range() -> bool:
	if range_level >= range_level_max: return false
	var cost := get_range_upgrade_cost()
	if not _try_spend(cost): return false
	_spent_local += cost
	range_level += 1
	_recompute_stats()
	upgraded.emit("range", range_level, cost)
	return true

func upgrade_damage() -> bool:
	if PowerUps != null and PowerUps.purchase("turret_damage"):
		_recompute_stats()
		upgraded.emit("damage", 0, 0)
		return true
	return false

func _scaled_cost(base_cost: int, scale: float, level: int) -> int:
	var c := float(base_cost) * pow(maxf(1.0, scale), max(0, level))
	return int(round(maxf(1.0, c)))

# =========================================================
# Derived stats
# =========================================================
func _recompute_stats() -> void:
	# Damage (base/global). End modifier applied at roll time (so UI and logic stay in sync below).
	if PowerUps != null and PowerUps.has_method("turret_damage_value"):
		_current_damage = PowerUps.turret_damage_value()
	else:
		_current_damage = base_damage

	# Fire interval = base * local * global * end, clamped
	var local_mult := pow(maxf(0.01, rate_mult_per_level), rate_level)
	var global_mult := 1.0
	if PowerUps != null and PowerUps.has_method("turret_rate_mult"):
		global_mult = maxf(0.01, PowerUps.turret_rate_mult())
	_current_fire_rate = clampf(base_fire_rate * local_mult * global_mult * rate_mult_end, _FIRE_RATE_MIN, 999.0)

	# Acquire range = (base + local + global_add) * end
	var local_add := range_per_level * float(range_level)
	var global_add := 0.0
	if PowerUps != null and PowerUps.has_method("turret_range_bonus"):
		global_add = PowerUps.turret_range_bonus()
	_current_acquire_range = maxf(0.5, (base_acquire_range + local_add + global_add) * range_mult_end)
	_apply_range_to_area(_current_acquire_range)

	if _stats_window != null and _stats_window.visible:
		_update_range_ring()

# =========================================================
# Multishot + damage rolling
# =========================================================
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

func _roll_final_damage_for_shot() -> int:
	var total := float(_current_damage) * damage_mult_end
	var crit_ch := 0.0
	var crit_mul := 2.0
	if PowerUps != null:
		if PowerUps.has_method("crit_chance_value"):
			crit_ch = clampf(PowerUps.crit_chance_value(), 0.0, 1.0)
		if PowerUps.has_method("crit_mult_value"):
			crit_mul = maxf(1.0, PowerUps.crit_mult_value())
	if randf() < crit_ch:
		total *= crit_mul
	return int(maxf(0.0, round(total)))

func _targets_sorted_by_distance() -> Array[Node3D]:
	var arr: Array[Node3D] = []
	for e in targets_in_range:
		if e != null and is_instance_valid(e):
			arr.append(e)
	arr.sort_custom(Callable(self, "_cmp_by_distance"))
	return arr

func _cmp_by_distance(a: Node3D, b: Node3D) -> bool:
	var o: Vector3 = global_transform.origin
	var da: float = o.distance_to(a.global_transform.origin)
	var db: float = o.distance_to(b.global_transform.origin)
	return da < db

func _select_victims_widest(count: int) -> Array[Node3D]:
	var sorted: Array[Node3D] = _targets_sorted_by_distance()
	var n: int = min(count, sorted.size())
	var victims: Array[Node3D] = []
	for i in range(n):
		victims.append(sorted[i])
	return victims

# =========================================================
# Targeting + firing
# =========================================================
func _on_body_entered(body: Node) -> void:
	if body.is_in_group("enemy"):
		if body.has_signal("damaged") and not body.is_connected("damaged", Callable(self, "_on_enemy_damaged")):
			body.connect("damaged", Callable(self, "_on_enemy_damaged"))
		if not targets_in_range.has(body):
			targets_in_range.append(body as Node3D)

func _on_body_exited(body: Node) -> void:
	if body.is_in_group("enemy"):
		if body.has_signal("damaged") and body.is_connected("damaged", Callable(self, "_on_enemy_damaged")):
			body.disconnect("damaged", Callable(self, "_on_enemy_damaged"))
		targets_in_range.erase(body)
		if body == target:
			_disconnect_target_signals()
			target = null

# Right-click toggles the dialog
func _on_clickbody_input(_camera: Node, event: InputEvent, _pos: Vector3, _norm: Vector3, _shape: int) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
		var dlg := _ensure_stats_dialog()
		if dlg.visible:
			dlg.hide()
		else:
			_refresh_stats_text()
			var vp := get_viewport().get_visible_rect().size
			dlg.size = dlg.size.clamp(Vector2i(320, 220), Vector2i(vp.x - 80, vp.y - 80))
			dlg.popup_centered()

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

func _current_valid_target() -> Node3D:
	if target != null and is_instance_valid(target) and targets_in_range.has(target):
		return target
	return _select_target()

func fire() -> void:
	if Turret == null or MuzzlePoint == null:
		return
	# Lock a primary target for this shot (ensures we shoot what we're aiming at)
	var primary: Node3D = _current_valid_target()
	if primary == null:
		return
	can_fire = false

	# Re-aim at the primary we will actually shoot
	var turret_pos: Vector3 = Turret.global_position
	var primary_aim: Vector3 = _aim_point_of(primary)
	var final_aim: Vector3 = primary_aim
	if yaw_only:
		final_aim.y = turret_pos.y
	Turret.look_at(final_aim, Vector3.UP)

	# --- Multishot ---
	var want: int = _compute_multishot_count()

	# Build victims list: primary first; then extras
	var victims: Array[Node3D] = [primary]
	if want > 1:
		var pool: Array[Node3D] = _select_victims_widest(want)
		if pool.has(primary):
			pool.erase(primary)
		var extra: int = clampi(want - 1, 0, pool.size())
		for i in range(extra):
			var v: Node3D = pool[i]
			if v != null and is_instance_valid(v):
				victims.append(v)

	var from: Vector3 = MuzzlePoint.global_position
	var dmg_this_shot: int = _roll_final_damage_for_shot()

	_play_shoot_fx()
	_shots_fired += 1
	_hits_landed += victims.size()

	for v in victims:
		if v == null or not is_instance_valid(v):
			continue
		var end_pos: Vector3 = _aim_point_of(v)              # ← aim at marker/offset
		var to_vec: Vector3 = end_pos - from
		var dist: float = to_vec.length()
		if dist > max_range and dist > 0.0001:
			end_pos = from + to_vec.normalized() * max_range

		_apply_damage_final(v, dmg_this_shot)
		_spawn_laser_beam(from, end_pos)

		# --- Chain lightning autoload (blue FX) ---
		_call_chain_autoload(v, dmg_this_shot, from)

	await get_tree().create_timer(_current_fire_rate).timeout
	can_fire = true

func _apply_damage_final(enemy: Node, dmg: int) -> void:
	if enemy and is_instance_valid(enemy) and enemy.has_method("take_damage"):
		enemy.call("take_damage", {"final": dmg, "source": "turret", "by": self})

func _on_enemy_damaged(by, amount: int, killed: bool) -> void:
	if by == self:
		_true_damage_done += max(0, amount)
		if killed:
			_kills += 1

# =========================================================
# Chain lightning (autoload bridge)
# =========================================================
func _call_chain_autoload(start_enemy: Node3D, base_final_damage: int, start_pos: Vector3) -> void:
	var CL: Object = get_node_or_null("/root/ChainLightning")
	if CL == null and typeof(ChainLightning) != TYPE_NIL:
		CL = ChainLightning
	if CL == null:
		if chain_debug_prints:
			print("[turret] ChainLightning autoload not found")
		return

	if chain_force_test and CL.has_method("zap_chain"):
		if chain_debug_prints:
			print("[turret] FORCED chain zap")
		CL.call("zap_chain", start_pos, start_enemy, base_final_damage, self)
		return

	if CL.has_method("try_proc"):
		CL.call("try_proc", start_enemy, base_final_damage, self, start_pos)
	elif CL.has_method("zap_chain"):
		CL.call("zap_chain", start_pos, start_enemy, base_final_damage, self)

# =========================================================
# Range helpers
# =========================================================
func _gather_range_shapes() -> void:
	_range_shapes.clear()
	if DetectionArea:
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
			return maxf(sz.x, sz.z) * 0.5
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

# ---- Range ring visuals ----
func _ensure_range_ring() -> MeshInstance3D:
	if _range_ring != null:
		return _range_ring

	var mi := MeshInstance3D.new()
	mi.name = "RangeRing"
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position.y = range_ring_height

	var tor := TorusMesh.new()
	tor.resource_local_to_scene = true
	mi.mesh = tor

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = range_ring_color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat

	add_child(mi)
	_range_ring = mi
	_update_range_ring()
	return _range_ring

func _update_range_ring() -> void:
	if _range_ring == null:
		return
	var tor: TorusMesh = _range_ring.mesh as TorusMesh
	if tor == null:
		tor = TorusMesh.new()
		tor.resource_local_to_scene = true
		_range_ring.mesh = tor

	var outer: float = maxf(0.01, _current_acquire_range)
	var inner: float = maxf(0.001, outer - maxf(0.01, range_ring_thickness))
	tor.outer_radius = outer
	tor.inner_radius = inner
	_range_ring.position.y = range_ring_height

func _set_range_ring_visible(v: bool) -> void:
	var mi: MeshInstance3D = _ensure_range_ring()
	mi.visible = v
	if v:
		_update_range_ring()

# =========================================================
# FX (BLACK laser beam via MIX blending; fades out quickly)
# =========================================================
func _spawn_laser_beam(start_pos: Vector3, end_pos: Vector3) -> void:
	var length: float = maxf(0.05, start_pos.distance_to(end_pos))
	var mid: Vector3 = (start_pos + end_pos) * 0.5

	var root := Node3D.new()
	root.name = "LaserBeam"
	var parent: Node = get_tree().current_scene
	if parent == null:
		parent = get_tree().root
	parent.add_child(root)
	root.global_position = mid
	root.look_at(end_pos, Vector3.UP)   # +Z toward target

	# Core (thin)
	var core := MeshInstance3D.new()
	var core_mesh := BoxMesh.new()
	core_mesh.size = Vector3(laser_width * 0.33, laser_width * 0.33, length)
	core.mesh = core_mesh
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var core_mat := StandardMaterial3D.new()
	core_mat.resource_local_to_scene = true
	core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	core_mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	core_mat.albedo_color = laser_color_core
	core_mat.emission_enabled = false
	core_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	core.material_override = core_mat
	root.add_child(core)

	# Glow (fatter)
	var glow := MeshInstance3D.new()
	var glow_mesh := BoxMesh.new()
	glow_mesh.size = Vector3(laser_width, laser_width, length)
	glow.mesh = glow_mesh
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var glow_mat := StandardMaterial3D.new()
	glow_mat.resource_local_to_scene = true
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow_mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	glow_mat.albedo_color = laser_color_glow
	glow_mat.emission_enabled = false
	glow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	glow.material_override = glow_mat
	root.add_child(glow)

	# Fade + cleanup
	var tw := get_tree().create_tween()
	tw.tween_property(glow_mat, "albedo_color:a", 0.0, laser_duration)
	tw.tween_property(core_mat, "albedo_color:a", 0.0, laser_duration)
	tw.tween_callback(root.queue_free)

# Keep muzzle flash / animation
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
	if target and target.has_signal("damaged") and target.is_connected("damaged", Callable(self, "_on_enemy_damaged")):
		target.disconnect("damaged", Callable(self, "_on_enemy_damaged"))
	_disconnect_target_signals()
	target = null

# =========================================================
# Stats dialog
# =========================================================
func _ensure_stats_dialog() -> AcceptDialog:
	if _stats_window != null:
		return _stats_window

	if _stats_layer == null:
		_stats_layer = CanvasLayer.new()
		_stats_layer.layer = 200
		_stats_layer.process_mode = Node.PROCESS_MODE_ALWAYS
		get_tree().root.add_child(_stats_layer)

	var dlg := AcceptDialog.new()
	dlg.title = "Turret"
	dlg.unresizable = false
	dlg.min_size = Vector2i(420, 240)
	dlg.size = Vector2i(460, 300)
	dlg.exclusive = false
	dlg.always_on_top = true
	dlg.process_mode = Node.PROCESS_MODE_ALWAYS
	dlg.dialog_hide_on_ok = true
	dlg.confirmed.connect(Callable(dlg, "hide"))
	dlg.close_requested.connect(Callable(dlg, "hide"))
	dlg.canceled.connect(Callable(dlg, "hide"))
	dlg.visibility_changed.connect(func ():
		_set_range_ring_visible(dlg.visible)
		if dlg.visible:
			_update_range_ring()
	)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	dlg.add_child(root)

	var sc := ScrollContainer.new()
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	root.add_child(sc)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	sc.add_child(margin)

	_stats_label = Label.new()
	_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stats_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stats_label.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_stats_label.custom_minimum_size = Vector2(360, 0)
	margin.add_child(_stats_label)

	dlg.add_button("Sell", false, "sell")
	dlg.custom_action.connect(func(name):
		if name == "sell":
			_on_sell_pressed()
			dlg.hide()
	)
	dlg.get_ok_button().text = "Close"

	_stats_layer.add_child(dlg)
	_stats_window = dlg
	return dlg

func _refresh_stats_text() -> void:
	if _stats_label == null:
		return

	var shots_per_s: float = 0.0
	if _current_fire_rate > 0.0:
		shots_per_s = 1.0 / _current_fire_rate
	var refund_preview := int(round(float(_spent_local) * float(sell_refund_percent) / 100.0))

	var fire_rate_str := String.num(_current_fire_rate, 2)
	var shots_per_s_str := String.num(shots_per_s, 2)
	var range_str := String.num(_current_acquire_range, 1)
	var lifetime_str := String.num(_lifetime_s, 1)
	var shown_damage := int(round(float(_current_damage) * damage_mult_end))

	var s := "Current\n"
	s += "  Damage: %d\n" % shown_damage
	s += "  Fire: " + fire_rate_str + "s (" + shots_per_s_str + "/s)\n"
	s += "  Range: " + range_str + "\n"
	s += "\nTotals\n"
	s += "  Shots: %d\n" % _shots_fired
	s += "  Kills: %d\n" % _kills
	s += "  Damage done: %d\n" % _true_damage_done
	s += "  Lifetime: " + lifetime_str + "s\n"
	s += "\nSell refund: " + str(refund_preview) + " (" + str(sell_refund_percent) + "% of local spend)"
	_stats_label.text = s

func _on_sell_pressed() -> void:
	var refund := int(round(float(_spent_local) * float(sell_refund_percent) / 100.0))
	_try_refund(refund)
	_mark_tile_freed()
	_set_range_ring_visible(false)
	if _stats_window != null:
		_stats_window.hide()
	queue_free()

func _mark_tile_freed() -> void:
	if _tile_board == null and tile_board_path != NodePath(""):
		_tile_board = get_node_or_null(tile_board_path)
	if _tile_board == null:
		var b := get_tree().root.find_child("TileBoard", true, false)
		if b is Node: _tile_board = b
	if _tile_board == null:
		return

	var cell := _tile_cell
	if (cell.x <= -9999 or cell.y <= -9999) and _tile_board.has_method("world_to_cell"):
		cell = _tile_board.call("world_to_cell", global_transform.origin)

	if _tile_board.has_method("free_tile"):
		_tile_board.call("free_tile", cell)
		return

	var tile: Node = null
	if _tile_board.has("tiles"):
		var d: Variant = _tile_board.get("tiles")
		if typeof(d) == TYPE_DICTIONARY:
			var dict: Dictionary = d
			if dict.has(cell):
				tile = dict[cell]
	if tile and tile.has_method("repair_tile"):
		tile.call("repair_tile")

	if _tile_board.has_method("_recompute_flow"):
		_tile_board.call("_recompute_flow")
	if _tile_board.has_method("_emit_path_changed"):
		_tile_board.call("_emit_path_changed")
	elif _tile_board.has_signal("global_path_changed"):
		_tile_board.emit_signal("global_path_changed")

func toggle_stats_panel() -> void:
	var dlg := _ensure_stats_dialog()
	if dlg.visible:
		dlg.hide()
	else:
		_refresh_stats_text()
		_set_range_ring_visible(true)
		_update_range_ring()
		dlg.popup_centered()

# Where to aim on an enemy (carriers = hole marker; UFOs = fallback)
func _aim_point_of(n: Node) -> Vector3:
	if n != null and n.has_method("get_aim_point"):
		return n.get_aim_point()
	var n3 := n as Node3D
	if n3 != null:
		return n3.global_position
	return Vector3.ZERO

# =========================================================
# Getters (HUD/PowerUps)
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

# =========================================================
# Binding helpers (path-agnostic)
# =========================================================
func _bind_nodes_if_missing() -> void:
	if DetectionArea == null:
		DetectionArea = _try_node(["DetectionArea"]) as Area3D
	if ClickBody == null:
		ClickBody = _try_node(["StaticBody3D", "ClickBody"]) as StaticBody3D
	if Turret == null:
		Turret = _try_node([
			"tower_model/Turret",
			"sniper_tower_model/TurretPivot", # if you add a pivot
			"sniper_tower_model/Turret",
			"TurretPivot",
			"Turret"
		]) as Node3D
	if MuzzlePoint == null:
		MuzzlePoint = _try_node([
			"tower_model/Turret/Barrel/MuzzlePoint",
			"sniper_tower_model/Turret/Barrel/MuzzlePoint",
			"sniper_tower_model/TurretPivot/TurretModel/Barrel/MuzzlePoint",
			"MuzzlePoint"
		]) as Node3D

func _try_node(paths: Array) -> Node:
	for p in paths:
		var n := get_node_or_null(p)
		if n != null: return n
	# fallback: recursive search by the last element name if unique
	for p in paths:
		var name := String(p).get_file()   # after last '/'
		if name == "": name = String(p)
		var n2 := find_child(name, true, false)
		if n2 != null: return n2
	return null
