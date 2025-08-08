extends Node3D

@export var speed: float = 5.0   

static var next_id: int = 1
var enemy_id: int = 0
var distance: float = 0.0
var curve: Curve3D
var total_length: float = 0.0
var paused: bool = false
var tile_board: Node = null
var cur_speed: float = 0.0
var lane_offset: float = 0.0
var sway_phase: float = 0.0
var repath_timer: float = 0.0

const ACCEL: float = 10.0
const LOOKAHEAD: float = 0.45           
const LANE_MAG: float = 0.35
const SWAY_MAG: float = 0.10
const SWAY_HZ: float = 0.8
const POS_SMOOTH: float = 12.0          
const POS_SMOOTH_REPATH: float = 20.0    
const TURN_RATE_DEG: float = 540.0      

func _ready() -> void:
	var sign: int = (enemy_id % 2) * 2 - 1
	lane_offset = float(sign) * LANE_MAG
	sway_phase = float((enemy_id * 37) % 100) / 100.0 * TAU

func set_tile_board(board: Node) -> void:
	tile_board = board
	if is_instance_valid(tile_board):
		tile_board.connect("global_path_changed", Callable(self, "_on_global_path_changed"))

func set_path(new_curve: Curve3D) -> void:
	curve = new_curve
	if curve and curve.get_point_count() >= 2:
		total_length = curve.get_baked_length()
		distance = 0.0
		cur_speed = 0.0
		paused = false
	else:
		paused = true

func _process(delta: float) -> void:
	if paused or not curve or total_length <= 0.0:
		return

	cur_speed = move_toward(cur_speed, speed, ACCEL * delta)
	distance += cur_speed * delta

	if distance >= total_length:
		reach_goal()
		return

	var base_pos: Vector3 = curve.sample_baked(distance, true)
	var ahead: Vector3 = curve.sample_baked(min(distance + LOOKAHEAD, total_length), true)
	var tangent: Vector3 = (ahead - base_pos)
	if tangent.length() < 0.0001:
		tangent = -transform.basis.z 
	else:
		tangent = tangent.normalized()

	var side: Vector3 = Vector3(tangent.z, 0.0, -tangent.x).normalized()
	sway_phase += SWAY_HZ * TAU * delta
	var sway: float = sin(sway_phase) * SWAY_MAG
	var target_pos: Vector3 = base_pos + side * (lane_offset + sway)

	var k: float = (POS_SMOOTH_REPATH if repath_timer > 0.0 else POS_SMOOTH) * delta
	k = clamp(k, 0.0, 1.0)
	global_position = global_position.lerp(target_pos, k)

	var desired_dir: Vector3 = (ahead - global_position).normalized()
	var current_forward: Vector3 = -transform.basis.z.normalized()
	var angle_to: float = acos(clamp(current_forward.dot(desired_dir), -1.0, 1.0))
	var max_turn: float = deg_to_rad(TURN_RATE_DEG) * delta
	var t: float = (max_turn / max(angle_to, 0.00001))
	var new_forward: Vector3 = current_forward.slerp(desired_dir, clamp(t, 0.0, 1.0)).normalized()
	look_at(global_position + new_forward, Vector3.UP)

	if repath_timer > 0.0:
		repath_timer = max(0.0, repath_timer - delta)

func _on_global_path_changed() -> void:
	if tile_board == null:
		return

	var new_path_points: Array = tile_board.get_path_from(global_position)

	var goal_pos: Vector3 = tile_board.goal_node.global_position
	var goal_tile = tile_board.world_to_tile(goal_pos)
	var my_tile = tile_board.world_to_tile(global_position)

	if new_path_points.size() < 2:
		if my_tile == goal_tile:
			var final_curve := Curve3D.new()
			final_curve.add_point(global_position)
			final_curve.add_point(goal_pos)
			curve = final_curve
			total_length = curve.get_baked_length()
			distance = 0.0
			cur_speed = 0.0
			paused = false
		else:
			paused = true
		return

	var new_curve: Curve3D = tile_board.get_curve_for_path(new_path_points)

	var closest_distance: float = 0.0
	var min_dist: float = INF
	var steps: int = 160
	var new_len: float = new_curve.get_baked_length()
	for i in range(steps):
		var d: float = new_len * float(i) / float(steps)
		var sample_pos: Vector3 = new_curve.sample_baked(d, true)
		var dist_w: float = sample_pos.distance_to(global_position)
		if dist_w < min_dist:
			min_dist = dist_w
			closest_distance = d

	curve = new_curve
	total_length = new_len
	distance = clamp(closest_distance, 0.0, total_length)

	repath_timer = 0.20
	cur_speed = min(cur_speed, speed)

	paused = false

func reach_goal():
	paused = true
	var tween := create_tween()
	tween.tween_property(self, "scale", Vector3.ZERO, 0.5)
	tween.tween_callback(Callable(self, "queue_free"))
