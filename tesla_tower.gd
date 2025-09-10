extends Node3D
class_name TeslaTower

# ========= Placeable/Toolbar hooks (added for drag & drop) =========
@export var placeable_id: String = "tesla"              # used by toolbar / build manager
@export var footprint: Vector2i = Vector2i(1, 1)        # 1x1 by default; change if needed (e.g., 2x2)
@export var toolbar_icon: Texture2D                     # optional: show in the bar if your UI uses icons

func get_placeable_id() -> String:      return placeable_id
func get_display_name() -> String:      return "Tesla Tower"
func get_build_cost() -> int:           return build_cost
func get_footprint() -> Vector2i:       return footprint
func on_preview_active(active: bool) -> void: _set_range_ring_visible(active)
func on_placed() -> void:               _set_range_ring_visible(false)  # hide ring once built

# ========= Visuals (straight blue beam) =========
@export var laser_width: float = 0.14
@export var laser_duration: float = 0.06
@export var laser_color_core: Color = Color(0.35, 0.80, 1.00, 1.00)  # bright blue
@export var laser_color_glow: Color = Color(0.20, 0.60, 1.00, 0.70)  # softer halo

# ========= Base combat / pacing (mirror your turret) =====
@export var base_damage: int = 1
@export var base_fire_rate: float = 1.0    # seconds per shot (interval)

# local fire-rate upgrades (same knobs so HUD works)
@export var rate_mult_per_level: float = 0.90
@export var rate_level_max: int = 10
var rate_level: int = 0

# local range upgrades (same knobs so HUD works)
@export var base_acquire_range: float = 0.0
@export var range_per_level: float = 2.0
@export var range_level_max: int = 10
var range_level: int = 0

# end-of-pipeline multipliers (kept to match your turret API)
@export var rate_mult_end: float = 1.0
@export var range_mult_end: float = 1.0
@export var damage_mult_end: float = 1.0

# ========= Build / minerals (same as turret) ==============
@export var build_cost: int = 10
@export var minerals_path: NodePath
@export var sell_refund_percent: int = 60
var _minerals: Node = null
signal build_paid(cost: int)
signal build_denied(cost: int)
signal upgraded(kind: String, new_level: int, cost: int)

# ========= TileBoard context ==============================
@export var tile_board_path: NodePath
var _tile_board: Node = null
var _tile_cell: Vector2i = Vector2i(-9999, -9999)
func set_tile_context(board: Node, cell: Vector2i) -> void:
	_tile_board = board
	_tile_cell = cell

# ========= Node refs ======================================
@onready var DetectionArea: Area3D = $DetectionArea
@export var muzzle_path: NodePath
@onready var MuzzlePoint: Node3D = _resolve_muzzle()

var targets_in_range: Array[Node3D] = []
var target: Node3D = null
var can_fire: bool = true

# ========= Derived stats ==================================
var _current_damage: int = 1
var _current_fire_rate: float = 1.0
var _current_acquire_range: float = 12.0
const _FIRE_RATE_MIN: float = 0.05

var _range_shapes: Array[CollisionShape3D] = []
var _rng := RandomNumberGenerator.new()

# ========= Range ring (same look/feel) ====================
@export var range_ring_color: Color = Color(0.25, 0.9, 1.0, 0.35)
@export var range_ring_thickness: float = 0.15
@export var range_ring_height: float = 0.02
var _range_ring: MeshInstance3D = null

# ========= Telemetry ======================================
var _shots_fired: int = 0
var _hits_landed: int = 0
var _kills: int = 0
var _true_damage_done: int = 0

func _ready() -> void:
	add_to_group("turret")
	add_to_group("placeable") # <-- lets your BuildManager find it generically
	_rng.randomize()

	_resolve_minerals()
	if tile_board_path != NodePath(""):
		_tile_board = get_node_or_null(tile_board_path)

	# Pay on spawn (matches your turret flow). If your BuildManager already paid, keep this true.
	if not _attempt_build_payment():
		build_denied.emit(build_cost)
		queue_free()
		return
	build_paid.emit(build_cost)

	DetectionArea.body_entered.connect(_on_body_entered)
	DetectionArea.body_exited.connect(_on_body_exited)

	_gather_range_shapes()
	if base_acquire_range <= 0.0:
		var detected := _detect_initial_range()
		base_acquire_range = (detected if detected > 0.0 else 12.0)

	if PowerUps != null and PowerUps.has_signal("changed"):
		PowerUps.changed.connect(_recompute_stats)

	_recompute_stats()
	_set_range_ring_visible(false)

func _process(_dt: float) -> void:
	# prune dead
	var keep: Array[Node3D] = []
	for e in targets_in_range:
		if e != null and is_instance_valid(e):
			keep.append(e)
	targets_in_range = keep

	# lock target
	if target == null or not is_instance_valid(target) or not targets_in_range.has(target):
		target = _select_target()

	if target != null and is_instance_valid(target) and can_fire:
		_fire_chain_like_powerup(target)

# =========================================================
# Targeting
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
			target = null

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

# =========================================================
# Firing — behaves like PowerUps chain proc (always-on)
# =========================================================
func _fire_chain_like_powerup(primary: Node3D) -> void:
	can_fire = false
	_shots_fired += 1

	# Roll damage ONCE per shot (same as basic turret)
	var initial_final_damage: int = _roll_final_damage_for_shot()
	var start_pos: Vector3 = MuzzlePoint.global_position if MuzzlePoint != null else global_transform.origin

	# How many simultaneous beams?
	var want: int = _compute_multishot_count()

	# Build victims list: primary first; then closest others
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

	# Pull chain params from PowerUps, but chains ALWAYS happen for Tesla
	var jumps: int = 4
	var radius: float = 5.0
	var pct: float = 20.0
	if PowerUps != null:
		jumps = max(4, PowerUps.chain_jumps_value())
		radius = PowerUps.chain_radius_value()
		pct = PowerUps.chain_damage_percent_value()
	var per_bounce_damage: int = int(maxf(0.0, round(float(initial_final_damage) * (pct * 0.01))))

	# Fire one chain per victim
	for v in victims:
		if v == null or not is_instance_valid(v):
			continue

		# Initial strike
		_do_hit_segment(start_pos, v, initial_final_damage)

		# Local chain from this victim
		var visited: Array = [v]
		var current := v
		for _i in range(jumps):
			var next := _find_next_target_in_radius(current, visited, radius)
			if next == null: break
			_do_hit_segment(current.global_transform.origin, next, per_bounce_damage)
			visited.append(next)
			current = next

	await get_tree().create_timer(_current_fire_rate).timeout
	can_fire = true

func _do_hit_segment(from_pos: Vector3, enemy: Node3D, dmg: int) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	var to_pos: Vector3 = _aim_point_of(enemy)
	_apply_damage_final(enemy, dmg)
	_spawn_laser_beam(from_pos, to_pos)
	_hits_landed += 1
	# Allow the *upgrade* chain to proc off these mimic hits as well
	_call_chain_autoload(enemy, dmg, from_pos)

func _find_next_target_in_radius(from_enemy: Node3D, visited: Array, radius: float) -> Node3D:
	var from_pos := from_enemy.global_transform.origin
	var best: Node3D = null
	var best_d := INF
	var all := get_tree().get_nodes_in_group("enemy")
	for e in all:
		var n := e as Node3D
		if n == null: continue
		if not is_instance_valid(n): continue
		if visited.has(n): continue
		var d := from_pos.distance_to(n.global_transform.origin)
		if d <= radius and d < best_d:
			best_d = d
			best = n
	return best

# =========================================================
# Damage / stats (same math as your turret)
# =========================================================
func _recompute_stats() -> void:
	if PowerUps != null and PowerUps.has_method("turret_damage_value"):
		_current_damage = PowerUps.turret_damage_value()
	else:
		_current_damage = base_damage

	var local_mult := pow(maxf(0.01, rate_mult_per_level), rate_level)
	var global_mult := 1.0
	if PowerUps != null and PowerUps.has_method("turret_rate_mult"):
		global_mult = maxf(0.01, PowerUps.turret_rate_mult())
	_current_fire_rate = clampf(base_fire_rate * local_mult * global_mult * rate_mult_end, _FIRE_RATE_MIN, 999.0)

	var local_add := range_per_level * float(range_level)
	var global_add := 0.0
	if PowerUps != null and PowerUps.has_method("turret_range_bonus"):
		global_add = PowerUps.turret_range_bonus()
	_current_acquire_range = maxf(0.5, (base_acquire_range + local_add + global_add) * range_mult_end)
	_apply_range_to_area(_current_acquire_range)
	_update_range_ring()

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

func _apply_damage_final(enemy: Node, dmg: int) -> void:
	if enemy and is_instance_valid(enemy) and enemy.has_method("take_damage"):
		enemy.call("take_damage", {"final": dmg, "source": "turret", "by": self})

func _on_enemy_damaged(by, amount: int, killed: bool) -> void:
	if by == self:
		_true_damage_done += max(0, amount)
		if killed:
			_kills += 1

func _aim_point_of(n: Node) -> Vector3:
	if n != null and n.has_method("get_aim_point"):
		return n.get_aim_point()
	var n3 := n as Node3D
	if n3 != null:
		return n3.global_position
	return Vector3.ZERO

# =========================================================
# Chain Lightning autoload bridge (to allow *upgrade* procs)
# =========================================================
func _call_chain_autoload(start_enemy: Node3D, base_final_damage: int, start_pos: Vector3) -> void:
	var CL: Object = get_node_or_null("/root/ChainLightning")
	if CL == null and typeof(ChainLightning) != TYPE_NIL:
		CL = ChainLightning
	if CL == null:
		return
	if CL.has_method("try_proc"):
		CL.call("try_proc", start_enemy, base_final_damage, self, start_pos)
	elif CL.has_method("zap_chain"):
		CL.call("zap_chain", start_pos, start_enemy, base_final_damage, self)


# =========================================================
# Economy
# =========================================================
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
# Range helpers (same as your turret)
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

# ring
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
	var mi := _ensure_range_ring()
	mi.visible = v
	if v:
		_update_range_ring()

# =========================================================
# Zig-zag arc builder (Line3D)
# =========================================================
func _spawn_laser_beam(start_pos: Vector3, end_pos: Vector3) -> void:
	var length: float = maxf(0.05, start_pos.distance_to(end_pos))
	var mid: Vector3 = (start_pos + end_pos) * 0.5

	var root := Node3D.new()
	root.name = "TeslaBeam"
	var parent: Node = get_tree().current_scene
	if parent == null:
		parent = get_tree().root
	parent.add_child(root)
	root.global_position = mid
	root.look_at(end_pos, Vector3.UP)   # +Z toward target

	# Core (thin, bright)
	var core := MeshInstance3D.new()
	var core_mesh := BoxMesh.new()
	core_mesh.size = Vector3(laser_width * 0.33, laser_width * 0.33, length)
	core.mesh = core_mesh
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var core_mat := StandardMaterial3D.new()
	core_mat.resource_local_to_scene = true
	core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	core_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD     # brighter blue
	core_mat.albedo_color = laser_color_core
	core_mat.emission_enabled = true
	core_mat.emission = laser_color_core                     # glow from emission
	core_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	core.material_override = core_mat
	root.add_child(core)

	# Glow (fatter, softer)
	var glow := MeshInstance3D.new()
	var glow_mesh := BoxMesh.new()
	glow_mesh.size = Vector3(laser_width, laser_width, length)
	glow.mesh = glow_mesh
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var glow_mat := StandardMaterial3D.new()
	glow_mat.resource_local_to_scene = true
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	glow_mat.albedo_color = laser_color_glow
	glow_mat.emission_enabled = true
	glow_mat.emission = laser_color_glow
	glow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	glow.material_override = glow_mat
	root.add_child(glow)

	# Fade + cleanup
	var tw := get_tree().create_tween()
	tw.tween_property(glow_mat, "albedo_color:a", 0.0, laser_duration)
	tw.tween_property(core_mat, "albedo_color:a", 0.0, laser_duration)
	# also fade emission so it blooms less as it fades
	tw.tween_property(glow_mat, "emission:a", 0.0, laser_duration)
	tw.tween_property(core_mat, "emission:a", 0.0, laser_duration)
	tw.tween_callback(root.queue_free)

func _spawn_beam_segment(parent: Node3D, a: Vector3, b: Vector3) -> Array[StandardMaterial3D]:
	var root: Node3D = Node3D.new()
	root.name = "seg"
	parent.add_child(root)

	var mid: Vector3 = (a + b) * 0.5
	var length: float = maxf(0.02, a.distance_to(b))
	root.global_position = mid
	root.look_at(b, Vector3.UP)  # +Z along the segment

	# Core
	var core_mesh: BoxMesh = BoxMesh.new()
	core_mesh.size = Vector3(laser_width * 0.5, laser_width * 0.5, length)
	var core: MeshInstance3D = MeshInstance3D.new()
	core.mesh = core_mesh
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var core_mat: StandardMaterial3D = StandardMaterial3D.new()
	core_mat.resource_local_to_scene = true
	core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	core_mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	core_mat.albedo_color = laser_color_core
	core_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	core.material_override = core_mat
	root.add_child(core)

	# Glow
	var glow_mesh: BoxMesh = BoxMesh.new()
	glow_mesh.size = Vector3(laser_width, laser_width, length)
	var glow: MeshInstance3D = MeshInstance3D.new()
	glow.mesh = glow_mesh
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var glow_mat: StandardMaterial3D = StandardMaterial3D.new()
	glow_mat.resource_local_to_scene = true
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow_mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	glow_mat.albedo_color = laser_color_glow
	glow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	glow.material_override = glow_mat
	root.add_child(glow)

	var out: Array[StandardMaterial3D] = []
	out.append(core_mat)
	out.append(glow_mat)
	return out

# =========================================================
# Upgrades API (HUD hooks)
# =========================================================
func get_base_fire_rate() -> float:        return float(base_fire_rate)
func get_rate_mult_per_level() -> float:   return float(rate_mult_per_level)
func get_rate_level() -> int:              return int(rate_level)
func get_min_fire_interval() -> float:     return float(_FIRE_RATE_MIN)
func get_current_fire_interval() -> float: return float(_current_fire_rate)
func get_base_acquire_range() -> float:    return float(base_acquire_range)
func get_range_per_level() -> float:       return float(range_per_level)
func get_range_level() -> int:             return int(range_level)
func get_current_acquire_range() -> float: return float(_current_acquire_range)

func upgrade_fire_rate() -> bool:
	if rate_level >= rate_level_max:
		return false
	var cost := _scaled_cost(12, 1.35, rate_level)
	if not _try_spend(cost):
		return false
	rate_level += 1
	_recompute_stats()
	upgraded.emit("fire_rate", rate_level, cost)
	return true

func upgrade_range() -> bool:
	if range_level >= range_level_max:
		return false
	var cost := _scaled_cost(10, 1.30, range_level)
	if not _try_spend(cost):
		return false
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

func _resolve_muzzle() -> Node3D:
	var n: Node3D = null
	if muzzle_path != NodePath(""):
		n = get_node_or_null(muzzle_path) as Node3D
	if n == null:
		n = get_node_or_null("MuzzlePoint") as Node3D                 # sibling
	if n == null:
		n = get_node_or_null("DetectionArea/MuzzlePoint") as Node3D   # legacy path
	return n

# ---------- Multishot + victim picking (same logic as basic turret) ----------
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
