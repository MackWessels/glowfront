extends Node3D

@export var flight_time: float = 1.0
@export var arc_height: float = 8.0

var start_position: Vector3
var target_position: Vector3
var timer := 0.0
var is_launched := false

func launch(to: Vector3):
	start_position = global_position
	target_position = to
	timer = 0.0
	is_launched = true

func _process(delta):
	if not is_launched:
		return

	timer += delta
	var t = timer / flight_time

	if t >= 1.0:
		global_position = target_position
		queue_free()
		return

	# Interpolate X and Z
	var horizontal_pos = start_position.lerp(target_position, t)

	# Compute arc: Y = parabolic height
	var arc = -4.0 * (t - 0.5) * (t - 0.5) + 1.0
	var y_pos = lerp(start_position.y, target_position.y, t) + arc * arc_height

	horizontal_pos.y = y_pos
	global_position = horizontal_pos
