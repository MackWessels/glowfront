extends Node3D

var speed := 10.0
var target_position: Vector3
var arc_height := 2.0
var duration := 0.5
var elapsed := 0.0
var start_position: Vector3

func setup(from: Vector3, to: Vector3):
	start_position = from
	global_position = from
	target_position = to
	look_at(to)

func _process(delta):
	elapsed += delta
	if elapsed > duration:
		queue_free()
		return

	var t = elapsed / duration
	var height = arc_height * 4 * t * (1 - t)
	global_position = start_position.lerp(target_position, t) + Vector3.UP * height
