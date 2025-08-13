extends Area3D

@export var speed: float = 100.0
@export var damage: int = 1
@export var hit_mask: int = 0xFFFFFFFF
@export var turret_group: StringName = "turrets"   # ignore turrets
@export var lifetime: float = 4.0                  # optional safety timer
@export var max_range: float = 120.0               # how far the bullet can travel

var direction: Vector3 = Vector3.FORWARD           # set by tower
var shooter: Node = null                           # set by tower
var _range_left: float = 0.0

func _ready() -> void:
	monitoring = true
	monitorable = true
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)
	_range_left = max_range

func _physics_process(delta: float) -> void:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var excludes: Array = [self]
	if shooter != null:
		excludes.append(shooter)

	var move_dist: float = min(speed * delta, _range_left)
	var from: Vector3 = global_position
	var max_steps := 4  # allows skipping multiple turret colliders in one frame

	while max_steps > 0 and move_dist > 0.0:
		var to: Vector3 = from + direction * move_dist
		var params := PhysicsRayQueryParameters3D.create(from, to)
		params.collision_mask = hit_mask
		params.exclude = excludes

		var hit: Dictionary = space.intersect_ray(params)
		if hit.is_empty():
			# no hit, just move
			global_position = to
			_range_left -= move_dist
			move_dist = 0.0
			break

		var collider: Object = hit["collider"]
		var hit_pos: Vector3 = hit["position"]
		var traveled: float = (hit_pos - from).length()

		# Ignore turrets (and their child colliders)
		if collider is Node and _is_turret(collider as Node):
			excludes.append(collider)
			from = hit_pos + direction * 0.01
			move_dist -= traveled
			_range_left -= traveled
			max_steps -= 1
			continue

		# Valid hit: apply damage if supported, then despawn
		if is_instance_valid(collider) and collider.has_method("take_damage"):
			collider.call("take_damage", damage)
		queue_free()
		return

	# range or lifetime guards
	if _range_left <= 0.0:
		queue_free()
		return

	if lifetime > 0.0:
		lifetime -= delta
		if lifetime <= 0.0:
			queue_free()

func _on_body_entered(body: Node) -> void:
	if body == shooter or _is_turret(body):
		return
	if body.has_method("take_damage"):
		body.call("take_damage", damage)
	queue_free()

func _on_area_entered(area: Area3D) -> void:
	if area == shooter or _is_turret(area):
		return
	queue_free()

func _is_turret(n: Node) -> bool:
	var p := n
	while p:
		if p.is_in_group(turret_group):
			return true
		p = p.get_parent()
	return false
