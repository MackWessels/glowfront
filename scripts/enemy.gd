extends CharacterBody3D

@export var speed := 5.0

var distance := 0.0
var curve: Curve3D
var total_length := 0.0

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

	var current_pos = curve.sample_baked(distance, true)
	global_position = current_pos

	var lookahead_distance = min(distance + 0.1, total_length)
	var ahead_pos = curve.sample_baked(lookahead_distance, true)
	var direction = (ahead_pos - current_pos).normalized()

	look_at(current_pos + direction, Vector3.UP)
