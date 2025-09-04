extends Node3D

# ---- Tuning ----
@export var gravity: float = 30.0
@export var drag: float = 1.4
@export var max_lifetime: float = 6.0

# Ray/mask settings
@export var ground_mask: int = 0            # flight sweep ray (0 = all)
@export var explode_ground_mask: int = 0    # sky-down ground probe for damage center (0 = all)
@export var splash_ground_mask: int = 0     # sky-down ground probe for splash (0 = all)
@export var enemy_group: String = "enemy"

# Sky-down probe heights (world units)
@export var probe_up_height: float = 200.0
@export var probe_down_height: float = 400.0

# Keep things above the surface
@export var explode_lift: float = 0.16      # nudge damage center above ground

# Splash FX (now forced on top for visibility)
@export var splash_time: float = 0.75
@export var splash_color: Color = Color(0, 0, 0, 0.95)
@export var splash_height: float = 0.06     # visual thickness of the disk
@export var splash_start_scale: float = 0.12
@export var splash_end_scale: float = 1.45
@export var splash_lift: float = 0.12       # base lift
@export var splash_extra_lift: float = 0.25 # EXTRA lift to guarantee it's above tiles
@export var force_splash_on_top: bool = true  # draw above depth
const EPS: float = 0.001

# ---- Runtime state ----
var _vel: Vector3 = Vector3.ZERO
var _damage: int = 1
var _radius: float = 3.5
var _by: Node = null
var _life: float = 0.0

func setup(start: Vector3, v: Vector3, radius: float, damage: int, by: Node) -> void:
	global_position = start
	_vel = v
	_radius = radius
	_damage = damage
	_by = by

func set_gravity(g: float) -> void:
	gravity = g

func _physics_process(dt: float) -> void:
	_life += dt
	if _life > max_lifetime:
		_explode(global_position)
		return

	var gvec := Vector3(0.0, -gravity, 0.0)
	var next_pos := global_position + _vel * dt + 0.5 * gvec * dt * dt

	# Sweep along path; skip enemies so we look for terrain/walls etc.
	var p := PhysicsRayQueryParameters3D.create(global_position, next_pos)
	p.collide_with_bodies = true
	p.collide_with_areas = false
	p.exclude = [self, _by]
	if ground_mask != 0:
		p.collision_mask = ground_mask

	var tries := 6
	while tries > 0:
		var hit := get_world_3d().direct_space_state.intersect_ray(p)
		if hit.is_empty():
			break
		var col := hit.get("collider") as Node
		if col != null and col.is_in_group(enemy_group):
			p.exclude.append(col) # ignore enemies
			tries -= 1
			continue
		_explode(hit.position)
		return

	# advance & integrate
	global_position = next_pos
	_vel += gvec * dt
	_vel -= _vel * drag * dt
	if _vel.length() > 0.01:
		look_at(global_position + _vel, Vector3.UP)

# --- Ground-first explosion ---
func _explode(raw_hit: Vector3) -> void:
	# Project to the *topmost* ground at this XZ by casting from "sky" down
	var ground: Dictionary = _project_sky_down(raw_hit, explode_ground_mask)
	var pos: Vector3 = (ground.get("pos", raw_hit) + ground.get("normal", Vector3.UP) * (explode_lift + EPS))

	# AoE damage centered at 'pos'
	var sphere := SphereShape3D.new()
	sphere.radius = _radius
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis(), pos)
	q.collide_with_bodies = true
	q.collide_with_areas = false

	for h in get_world_3d().direct_space_state.intersect_shape(q, 64):
		var c: Node = h.get("collider")
		if c and c.is_in_group(enemy_group) and c.has_method("take_damage"):
			c.call("take_damage", {"final": _damage, "source": "mortar", "by": _by})

	# Splash at ground-aligned spot (separate probe, same XZ)
	var splash_ground: Dictionary = _project_sky_down(raw_hit, splash_ground_mask)
	var s_base_pos: Vector3 = splash_ground.get("pos", pos)
	var s_nrm: Vector3 = splash_ground.get("normal", Vector3.UP)

	# Ensure the whole disk sits above the plane:
	# half thickness + small epsilon + extra lift, or splash_lift if that's larger.
	var needed: float = maxf(splash_lift, splash_height * 0.5 + EPS) + splash_extra_lift
	var s_pos: Vector3 = s_base_pos + s_nrm * needed

	_spawn_splash(s_pos, s_nrm)
	queue_free()

# Cast from high above straight down to get the *topmost* ground.
# Returns { ok: bool, pos: Vector3, normal: Vector3 }
func _project_sky_down(anchor: Vector3, mask: int) -> Dictionary:
	var from := Vector3(anchor.x, anchor.y + probe_up_height, anchor.z)
	var to   := Vector3(anchor.x, anchor.y - probe_down_height, anchor.z)
	var rp := PhysicsRayQueryParameters3D.create(from, to)
	rp.collide_with_bodies = true
	rp.collide_with_areas = false
	rp.exclude = [self, _by]
	if mask != 0:
		rp.collision_mask = mask

	# Skip enemies even if included by mistake
	var tries := 8
	while tries > 0:
		var hit := get_world_3d().direct_space_state.intersect_ray(rp)
		if hit.is_empty():
			return { "ok": false }
		var col := hit.get("collider") as Node
		if col != null and col.is_in_group(enemy_group):
			rp.exclude.append(col)
			tries -= 1
			continue
		return { "ok": true, "pos": hit.position, "normal": hit.get("normal", Vector3.UP) }
	return { "ok": false }

func _spawn_splash(pos: Vector3, normal: Vector3) -> void:
	var parent: Node = get_tree().current_scene
	if parent == null:
		parent = get_tree().root

	var root := Node3D.new()
	root.name = "SplashFX"
	parent.add_child(root)
	root.global_position = pos

	# Align disk so its +Y follows the ground normal
	var forward_hint := Vector3.FORWARD
	if abs(normal.dot(forward_hint)) > 0.95:
		forward_hint = Vector3.RIGHT
	root.look_at(root.global_position + forward_hint, normal)

	# High-visibility filled disk
	var fill := MeshInstance3D.new()
	var disk := CylinderMesh.new()
	disk.top_radius = 1.0
	disk.bottom_radius = 1.0
	disk.height = splash_height
	disk.radial_segments = 48
	fill.mesh = disk
	fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	mat.albedo_color = splash_color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Force to render on top for maximum visibility
	if force_splash_on_top:
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
		mat.render_priority = 20  # draw after most things

	fill.material_override = mat
	root.add_child(fill)

	var start_s := Vector3(_radius * splash_start_scale, 1.0, _radius * splash_start_scale)
	var end_s   := Vector3(_radius * splash_end_scale,   1.0, _radius * splash_end_scale)
	fill.scale = start_s

	var tw := get_tree().create_tween()
	tw.tween_property(fill, "scale", end_s, splash_time).from(start_s)
	tw.parallel().tween_property(mat, "albedo_color:a", 0.0, splash_time).from(splash_color.a)
	tw.tween_callback(root.queue_free)
