extends Node3D

@export var gravity: float = 30.0          # m/s^2 downward
@export var max_lifetime: float = 8.0      # safety cleanup
@export var ground_mask: int = 0           # 0 = hit all; set to a layer mask if you like

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

func _physics_process(dt: float) -> void:
	_life += dt
	if _life > max_lifetime:
		_explode(global_position)
		return

	# basic ballistic integration with sweep ray to detect impact this frame
	var gvec := Vector3(0.0, -gravity, 0.0)
	var next_pos := global_position + _vel * dt + 0.5 * gvec * dt * dt

	var p := PhysicsRayQueryParameters3D.create(global_position, next_pos)
	p.collide_with_bodies = true
	p.collide_with_areas = false
	p.exclude = [self, _by]   # don't hit our tower
	if ground_mask != 0:
		p.collision_mask = ground_mask

	var hit := get_world_3d().direct_space_state.intersect_ray(p)
	if not hit.is_empty():
		_explode(hit.position)
		return

	global_position = next_pos
	_vel += gvec * dt

	# orient shell along velocity (optional, looks nice)
	if _vel.length() > 0.01:
		look_at(global_position + _vel, Vector3.UP)

func _explode(at: Vector3) -> void:
	# AoE query for enemies within _radius
	var sphere := SphereShape3D.new()
	sphere.radius = _radius
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis(), at)
	q.collide_with_bodies = true
	q.collide_with_areas = false

	var hits := get_world_3d().direct_space_state.intersect_shape(q, 64)
	for h in hits:
		var c: Node = h.get("collider")
		if c and c.is_in_group("enemy") and c.has_method("take_damage"):
			c.call("take_damage", {"final": _damage, "source": "mortar", "by": _by})

	# TODO (optional): spawn explosion FX / decal / sound here

	queue_free()
