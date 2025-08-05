extends Node3D

@export var speed := 5.0
var distance := 0.0
var curve: Curve3D
var total_length := 0.0

var tile_board: Node = null 

func set_tile_board(board: Node) -> void:
	tile_board = board
	if is_instance_valid(tile_board):
		tile_board.connect("path_updated", Callable(self, "_on_path_updated"))

func set_path(new_curve: Curve3D) -> void:
	curve = new_curve
	if curve:
		total_length = curve.get_baked_length()

func _process(delta: float) -> void:
	if not curve or total_length <= 0:
		return

	distance += speed * delta
	if distance >= total_length:
		queue_free()
		return

	var new_pos = curve.sample_baked(distance, true)
	global_position = new_pos

	var lookahead_distance = min(distance + 0.1, total_length)
	var ahead_pos = curve.sample_baked(lookahead_distance, true)
	var direction = (ahead_pos - new_pos).normalized()
	look_at(new_pos + direction, Vector3.UP)

func _on_path_updated(_dummy: Curve3D) -> void:
	if tile_board == null:
		return

	var new_path_points = tile_board.get_path_from(global_position)
	if new_path_points.size() < 2:
		return

	# Create new curve from updated path points
	var new_curve = Curve3D.new()
	for point in new_path_points:
		new_curve.add_point(point)

	# Find the closest distance on the NEW curve to current position
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

	# Swap in the new curve and distance without snapping
	curve = new_curve
	total_length = curve.get_baked_length()
	distance = min(closest_distance, total_length)
