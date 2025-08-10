extends CharacterBody3D

@export var speed: float = 4.0
@export var acceleration: float = 18.0
@export var goal_radius: float = 0.6
@export var tile_board_path: NodePath

var _board: Node = null

func _ready() -> void:
	if has_node(tile_board_path):
		_board = get_node(tile_board_path)
	else:
		_board = null
	add_to_group("enemy")

func _physics_process(delta: float) -> void:
	if _board == null:
		velocity = Vector3.ZERO
		move_and_slide()
		return

	var goal_pos: Vector3 = _board.get_goal_position()
	if global_position.distance_to(goal_pos) <= goal_radius:
		queue_free()
		return

	var dir: Vector3 = _board.get_dir_for_world(global_position)
	var target_vel: Vector3 = Vector3.ZERO
	if dir != Vector3.ZERO:
		target_vel = dir * speed
	target_vel.y = 0.0

	velocity = velocity.move_toward(target_vel, acceleration * delta)
	move_and_slide()
