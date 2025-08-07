extends Node3D

@export var speed := 5.0

static var next_id := 1
var enemy_id := 0

var distance := 0.0
var curve: Curve3D
var total_length := 0.0
var paused := false

var tile_board: Node = null

func _ready():
	enemy_id = next_id
	next_id += 1

func set_tile_board(board: Node) -> void:
	tile_board = board
	if is_instance_valid(tile_board):
		tile_board.connect("global_path_changed", Callable(self, "_on_global_path_changed"))

func set_path(new_curve: Curve3D) -> void:
	curve = new_curve
	if curve and curve.get_point_count() >= 2:
		total_length = curve.get_baked_length()
		distance = 0.0
		paused = false
	else:
		paused = true

func _process(delta: float) -> void:
	if paused or not curve or total_length <= 0:
		return

	distance += speed * delta
	if distance >= total_length:
		reach_goal()
		return

	var new_pos = curve.sample_baked(distance, true)
	global_position = new_pos

	var lookahead_distance = min(distance + 0.1, total_length)
	var ahead_pos = curve.sample_baked(lookahead_distance, true)
	var direction = (ahead_pos - new_pos).normalized()
	look_at(new_pos + direction, Vector3.UP)

func _on_global_path_changed() -> void:
	if tile_board == null:
		return

	var new_path_points = tile_board.get_path_from(global_position)

	var goal_pos = tile_board.goal_node.global_position
	var goal_tile = tile_board.world_to_tile(goal_pos)
	var my_tile = tile_board.world_to_tile(global_position)

	if new_path_points.size() < 2:
		if my_tile == goal_tile:
			var final_curve = Curve3D.new()
			final_curve.add_point(global_position)
			final_curve.add_point(goal_pos)
			curve = final_curve
			total_length = curve.get_baked_length()
			distance = 0.0
			paused = false
		else:
			paused = true
		return

	var new_curve = tile_board.get_curve_for_path(new_path_points)

	var closest_distance = 0.0
	var min_dist = INF
	var steps = 100
	for i in range(steps):
		var d = new_curve.get_baked_length() * i / float(steps)
		var sample_pos = new_curve.sample_baked(d, true)
		var dist = sample_pos.distance_to(global_position)
		if dist < min_dist:
			min_dist = dist
			closest_distance = d

	curve = new_curve
	total_length = curve.get_baked_length()
	distance = clamp(closest_distance, 0.0, total_length)
	paused = false

func reach_goal():
	paused = true

	var tween := create_tween()
	tween.tween_property(self, "scale", Vector3.ZERO, 0.5)
	tween.tween_callback(Callable(self, "queue_free"))
