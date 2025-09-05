extends Node
## Global Chain Lightning helper (blue zaps)

const ENEMY_GROUP := "enemy"

# ---------- Visual tuning ----------
@export var beam_width: float = 0.09
@export var beam_duration: float = 0.08
@export var color_core: Color = Color(0.55, 0.85, 1.0, 0.95) # bright blue core
@export var color_glow: Color = Color(0.25, 0.65, 1.0, 0.65) # softer blue glow

# Optional segmented “zig” look
@export var use_polyline: bool = false
@export var jitter_segments: int = 6
@export var jitter_amount: float = 0.35

# ---------- Re-entry guard ----------
var _is_proccing: bool = false
func is_running() -> bool: return _is_proccing

# =========================================================
# Public API
# =========================================================
# start_pos is OPTIONAL so both 3-arg (mortar) and 4-arg (turret) calls work.
func try_proc(start_enemy: Node, source_final_damage: int, owner: Node, start_pos: Variant = null) -> void:
	if _is_proccing:
		return

	var chance := (PowerUps.chain_chance_value() if PowerUps and PowerUps.has_method("chain_chance_value") else 0.0)
	if chance <= 0.0 or randf() > chance:
		return

	var jumps := (PowerUps.chain_jumps_value() if PowerUps and PowerUps.has_method("chain_jumps_value") else 0)
	if jumps <= 0:
		return

	var pct := (PowerUps.chain_damage_percent_value() if PowerUps and PowerUps.has_method("chain_damage_percent_value") else 0.0)
	var dmg := int(round(maxf(0.0, float(source_final_damage) * (pct * 0.01))))
	if dmg < 1:  # floor to 1 so tiny % still deals a zap
		dmg = 1

	var radius := (PowerUps.chain_radius_value() if PowerUps and PowerUps.has_method("chain_radius_value") else 5.0)

	_is_proccing = true

	# Optional initial visual zap from muzzle -> first enemy (used by turrets)
	if start_pos != null and typeof(start_pos) == TYPE_VECTOR3 and start_enemy and is_instance_valid(start_enemy):
		_spawn_beam(start_pos, (start_enemy as Node3D).global_position)

	_do_chain(start_enemy as Node3D, owner, dmg, jumps, radius)
	_is_proccing = false

# Back-compat helper: same order you used in your force-test
func zap_chain(start_pos: Vector3, start_enemy: Node3D, base_final_damage: int, owner: Node) -> void:
	try_proc(start_enemy, base_final_damage, owner, start_pos)

# Force a chain (ignores chance); useful for testing.
func force_chain(start_enemy: Node3D, base_final_damage: int, by: Node = null, start_pos: Variant = null) -> void:
	var owner := (by if by != null else self)
	# Reuse the same logic via try_proc (no chance gate): set _is_proccing and call core
	var pct := (PowerUps.chain_damage_percent_value() if PowerUps and PowerUps.has_method("chain_damage_percent_value") else 0.0)
	var dmg := int(round(maxf(0.0, float(base_final_damage) * (pct * 0.01))))
	if dmg < 1: dmg = 1
	var jumps := (PowerUps.chain_jumps_value() if PowerUps and PowerUps.has_method("chain_jumps_value") else 0)
	var radius := (PowerUps.chain_radius_value() if PowerUps and PowerUps.has_method("chain_radius_value") else 5.0)

	_is_proccing = true
	if start_pos != null and typeof(start_pos) == TYPE_VECTOR3 and start_enemy and is_instance_valid(start_enemy):
		_spawn_beam(start_pos, start_enemy.global_position)
	_do_chain(start_enemy, owner, dmg, jumps, radius)
	_is_proccing = false

# =========================================================
# Core chain logic
# =========================================================
func _do_chain(start_enemy: Node3D, owner: Node, dmg_per_jump: int, jumps: int, radius: float) -> void:
	if start_enemy == null or not is_instance_valid(start_enemy):
		return
	if jumps <= 0 or dmg_per_jump <= 0:
		return

	var visited: Dictionary = {}
	visited[start_enemy.get_instance_id()] = true

	var prev: Node3D = start_enemy
	for _i in range(jumps):
		var nxt := _find_next_target(prev, visited, radius)
		if nxt == null:
			break

		# apply damage and show a blue zap
		if nxt.has_method("take_damage"):
			nxt.call("take_damage", {"final": dmg_per_jump, "source": "chain", "by": owner})
		_spawn_beam(prev.global_position, nxt.global_position)

		visited[nxt.get_instance_id()] = true
		prev = nxt

func _find_next_target(from_enemy: Node3D, visited: Dictionary, radius: float) -> Node3D:
	if from_enemy == null or not is_instance_valid(from_enemy):
		return null

	var origin: Vector3 = from_enemy.global_transform.origin
	var best: Node3D = null
	var best_d := INF

	for n in get_tree().get_nodes_in_group(ENEMY_GROUP):
		var e := n as Node3D
		if e == null or not is_instance_valid(e):
			continue
		if visited.has(e.get_instance_id()):
			continue
		var d := origin.distance_to(e.global_transform.origin)
		if d <= radius and d < best_d:
			best_d = d
			best = e

	return best

# =========================================================
# Visuals (blue lightning beam)
# =========================================================
func _spawn_beam(a: Vector3, b: Vector3) -> void:
	if use_polyline:
		_spawn_polyline_beam(a, b)
	else:
		_spawn_box_beam(a, b)

# Cheap single box segment
func _spawn_box_beam(start_pos: Vector3, end_pos: Vector3) -> void:
	var length := maxf(0.05, start_pos.distance_to(end_pos))
	var mid := (start_pos + end_pos) * 0.5

	var root := Node3D.new()
	root.name = "ChainBeam"
	var parent: Node = get_tree().current_scene
	if parent == null:
		parent = get_tree().root
	parent.add_child(root)
	root.global_position = mid
	root.look_at(end_pos, Vector3.UP)   # +Z toward target

	# Core
	var core := MeshInstance3D.new()
	var core_mesh := BoxMesh.new()
	core_mesh.size = Vector3(beam_width * 0.33, beam_width * 0.33, length)
	core.mesh = core_mesh
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var core_mat := StandardMaterial3D.new()
	core_mat.resource_local_to_scene = true
	core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	core_mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	core_mat.albedo_color = color_core
	core_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	core.material_override = core_mat
	root.add_child(core)

	# Glow
	var glow := MeshInstance3D.new()
	var glow_mesh := BoxMesh.new()
	glow_mesh.size = Vector3(beam_width, beam_width, length)
	glow.mesh = glow_mesh
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var glow_mat := StandardMaterial3D.new()
	glow_mat.resource_local_to_scene = true
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow_mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	glow_mat.albedo_color = color_glow
	glow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	glow.material_override = glow_mat
	root.add_child(glow)

	var tw := get_tree().create_tween()
	tw.tween_property(glow_mat, "albedo_color:a", 0.0, beam_duration)
	tw.tween_property(core_mat, "albedo_color:a", 0.0, beam_duration)
	tw.tween_callback(root.queue_free)

# Segmented polyline (optional ziggy look)
func _spawn_polyline_beam(a: Vector3, b: Vector3) -> void:
	var n: int = max(2, jitter_segments)
	var pts: Array[Vector3] = []
	for i in n + 1:
		var t := float(i) / float(n)
		var p := a.lerp(b, t)
		if i > 0 and i < n:
			p += (Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)).normalized() * jitter_amount
		pts.append(p)
	for i in range(pts.size() - 1):
		_spawn_box_beam(pts[i], pts[i + 1])
