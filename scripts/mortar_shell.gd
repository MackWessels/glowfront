extends Node3D
class_name MortarShell

# --- Tunables ---
@export var gravity: float = 30.0
@export var enemy_group: String = "enemy"
@export var ground_mask: int = 0          # optional raycast mask for floor/tiles (0 = no filter)
@export var floor_y_offset: float = 0.10  # lift explosion above floor a bit
@export var max_flight_time: float = 6.0  # safety fuse
@export var splash_duration: float = 0.50

# Falloff: damage scales by (1 - d/R)^2 toward the edge of the radius.
@export var use_quadratic_falloff: bool = true

# --- Visual splash (simple, cheap) ---
@export var show_splash_mesh: bool = true

# runtime
var _vel: Vector3 = Vector3.ZERO
var _damage: int = 1
var _radius: float = 2.0
var _owner: Node = null
var _age: float = 0.0
var _done: bool = false

func setup(start: Vector3, initial_velocity: Vector3, radius: float, damage: int, owner: Node) -> void:
	global_position = start
	_vel = initial_velocity
	_radius = max(0.2, radius)
	_damage = max(1, damage)
	_owner = owner
	# if very slow, nudge so it never "freezes" visually
	if _vel.length() < 0.05:
		_vel += Vector3(0.2, 0.2, 0.0)
	set_physics_process(true)

func set_gravity(g: float) -> void:
	gravity = g

func _ready() -> void:
	set_physics_process(true)

func _physics_process(dt: float) -> void:
	if _done:
		return
	_age += dt
	if _age > max_flight_time:
		_explode(global_position)
		return

	# integrate motion
	_vel.y -= gravity * dt
	var next_pos: Vector3 = global_position + _vel * dt

	# ground check: if we cross/are below floor while descending, explode slightly above it
	var gy: float = _ground_y_at(next_pos)
	if _vel.y <= 0.0 and next_pos.y <= gy + floor_y_offset:
		next_pos.y = gy + floor_y_offset
		global_position = next_pos
		_explode(next_pos)
		return

	global_position = next_pos

# ---------------------------------------------------------
# Explosion + AoE
# ---------------------------------------------------------
func _explode(at: Vector3) -> void:
	if _done:
		return
	_done = true

	# visual splash (optional)
	if show_splash_mesh:
		_spawn_splash(at)

	# AoE damage
	var enemies := get_tree().get_nodes_in_group(enemy_group)
	for e in enemies:
		if not is_instance_valid(e):
			continue
		if not (e is Node3D):
			continue
		var pos: Vector3 = (e as Node3D).global_transform.origin
		var d: float = pos.distance_to(at)
		if d <= _radius:
			var final_dmg: int = _damage
			if use_quadratic_falloff and _radius > 0.0:
				var scale: float = clampf(1.0 - (d / _radius), 0.0, 1.0)
				final_dmg = int(round(float(_damage) * (scale * scale)))
			if final_dmg <= 0:
				continue
			# accept either take_damage(dict) or apply_damage(int)
			if e.has_method("take_damage"):
				e.call("take_damage", {"final": final_dmg, "source":"mortar", "by": _owner})
			elif e.has_method("apply_damage"):
				e.call("apply_damage", final_dmg)

	queue_free()

func _spawn_splash(at: Vector3) -> void:
	var splash := Node3D.new()
	get_tree().current_scene.add_child(splash)
	splash.global_transform.origin = at

	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = max(0.2, _radius * 0.4)
	m.height = m.radius * 2.0
	mi.mesh = m

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0,0,0,0.85)   # black for high visibility
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat

	splash.add_child(mi)

	# quick grow + fade then free
	var tw := get_tree().create_tween()
	tw.tween_property(mi, "scale", Vector3.ONE * 2.0, splash_duration * 0.5)
	tw.parallel().tween_property(mat, "albedo_color:a", 0.0, splash_duration)
	tw.tween_callback(splash.queue_free)

# ---------------------------------------------------------
# Ground helpers
# ---------------------------------------------------------
func _ground_y_at(world_pos: Vector3) -> float:
	# Try a downward ray; if nothing hit, assume y=0 plane.
	var from: Vector3 = world_pos + Vector3.UP * 2.0
	var to: Vector3 = world_pos + Vector3.DOWN * 50.0
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.new()
	params.from = from
	params.to = to
	if ground_mask != 0:
		params.collision_mask = ground_mask
	var hit := space.intersect_ray(params)
	if hit.has("position"):
		return (hit["position"] as Vector3).y
	return 0.0
