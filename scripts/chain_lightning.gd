extends Node


# =========================
# Config / tuning
# =========================
@export var enemy_group: String = "enemy"

# Visuals (blue lightning)
@export var beam_width: float = 0.09
@export var beam_duration: float = 0.08
@export var beam_color_core: Color = Color(0.55, 0.85, 1.0, 0.95)
@export var beam_color_glow: Color = Color(0.35, 0.70, 1.0, 0.65)

# Safety
@export var max_beams_per_chain: int = 32

# Damage floor (applies once a proc happens)
@export var min_chain_damage: int = 1

# Optional logging
@export var debug_trace: bool = false


# =========================
# Public API
# =========================
# Call this when a hit lands to *attempt* a chain proc.
# - start_enemy: the enemy that was just hit by the main attack
# - base_final_damage: the final damage of that main hit (after crits/mults)
# - by: the turret / source node (passed to take_damage "by" field for attribution)
# - start_pos (optional): if you want to draw the *first* segment from some point to
#   start_enemy, you could use this later—right now we draw from enemy->enemy only.
func try_proc(start_enemy: Node3D, base_final_damage: int, by: Node = null, start_pos: Vector3 = Vector3.ZERO) -> void:
	if start_enemy == null or not is_instance_valid(start_enemy):
		return

	var chance := (PowerUps.chain_chance_value() if PowerUps and PowerUps.has_method("chain_chance_value") else 0.0)
	if chance <= 0.0:
		return
	if randf() > chance:
		return

	_do_chain(start_enemy, base_final_damage, by)


# Force a chain (ignores proc chance); useful for testing.
func force_chain(start_enemy: Node3D, base_final_damage: int, by: Node = null) -> void:
	if start_enemy == null or not is_instance_valid(start_enemy):
		return
	_do_chain(start_enemy, base_final_damage, by)


# =========================
# Internals
# =========================
func _do_chain(start_enemy: Node3D, base_final_damage: int, by: Node) -> void:
	var jumps := (PowerUps.chain_jumps_value() if PowerUps and PowerUps.has_method("chain_jumps_value") else 0)
	if jumps <= 0:
		return

	var radius := (PowerUps.chain_radius_value() if PowerUps and PowerUps.has_method("chain_radius_value") else 5.0)
	var dmg := _calc_chain_damage(base_final_damage)
	if dmg <= 0:
		dmg = min_chain_damage

	var visited := {}
	visited[start_enemy.get_instance_id()] = true

	var prev: Node3D = start_enemy
	var beams := 0
	var made_any_link := false

	for _i in range(jumps):
		var nxt := _find_next_target(prev, visited, radius)
		if nxt == null:
			if not made_any_link:
				# "Must chain to at least 1 other" -> if no first link, do nothing
				if debug_trace:
					print("[Chain] no first neighbor found; abort")
			break

		# Apply damage and draw blue lightning segment
		_apply_damage(nxt, dmg, by)
		_spawn_beam(prev.global_position, nxt.global_position)
		made_any_link = true

		visited[nxt.get_instance_id()] = true
		prev = nxt
		beams += 1
		if beams >= max_beams_per_chain:
			break

	if debug_trace and made_any_link:
		print("[Chain] jumps=", beams, " dmg_each=", dmg)


func _calc_chain_damage(base_final_damage: int) -> int:
	var pct := (PowerUps.chain_damage_percent_value() if PowerUps and PowerUps.has_method("chain_damage_percent_value") else 0.0)
	var dmg := int(round(maxf(0.0, float(base_final_damage) * (pct * 0.01))))
	# Floor to at least 1 once a proc occurs:
	return max(min_chain_damage, dmg)


func _find_next_target(from_enemy: Node3D, visited: Dictionary, radius: float) -> Node3D:
	if from_enemy == null or not is_instance_valid(from_enemy):
		return null

	var origin: Vector3 = from_enemy.global_transform.origin
	var best: Node3D = null
	var best_d := INF

	for n in get_tree().get_nodes_in_group(enemy_group):
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


func _apply_damage(enemy: Node, amount: int, by: Node) -> void:
	if enemy and is_instance_valid(enemy) and enemy.has_method("take_damage"):
		enemy.call("take_damage", {"final": amount, "source": "chain", "by": by})


# =========================
# Blue beam FX (simple, fast)
# =========================
func _spawn_beam(start_pos: Vector3, end_pos: Vector3) -> void:
	var length: float = maxf(0.05, start_pos.distance_to(end_pos))
	var mid: Vector3 = (start_pos + end_pos) * 0.5

	var root := Node3D.new()
	root.name = "ChainLightning"
	var parent: Node = get_tree().current_scene
	if parent == null:
		parent = get_tree().root
	parent.add_child(root)
	root.global_position = mid
	root.look_at(end_pos, Vector3.UP)  # +Z points toward end_pos

	# Core (thin)
	var core := MeshInstance3D.new()
	var core_mesh := BoxMesh.new()
	core_mesh.size = Vector3(beam_width * 0.33, beam_width * 0.33, length)
	core.mesh = core_mesh
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var core_mat := StandardMaterial3D.new()
	core_mat.resource_local_to_scene = true
	core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	core_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	core_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	core_mat.albedo_color = beam_color_core
	core_mat.emission_enabled = true
	core_mat.emission = beam_color_core
	core_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	core.material_override = core_mat
	root.add_child(core)

	# Glow (fatter)
	var glow := MeshInstance3D.new()
	var glow_mesh := BoxMesh.new()
	glow_mesh.size = Vector3(beam_width, beam_width, length)
	glow.mesh = glow_mesh
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var glow_mat := StandardMaterial3D.new()
	glow_mat.resource_local_to_scene = true
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	glow_mat.albedo_color = beam_color_glow
	glow_mat.emission_enabled = true
	glow_mat.emission = beam_color_glow
	glow_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	glow.material_override = glow_mat
	root.add_child(glow)

	# Fade + cleanup
	var tw := get_tree().create_tween()
	tw.tween_property(glow_mat, "albedo_color:a", 0.0, beam_duration)
	tw.tween_property(core_mat, "albedo_color:a", 0.0, beam_duration)
	tw.tween_property(glow_mat, "emission:a", 0.0, beam_duration)
	tw.tween_property(core_mat, "emission:a", 0.0, beam_duration)
	tw.tween_callback(root.queue_free)
