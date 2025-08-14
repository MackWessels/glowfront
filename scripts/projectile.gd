extends Node3D

@export var min_life: float = 0.05

func setup(start_pos: Vector3, end_pos: Vector3, speed: float) -> void:
	global_position = start_pos
	look_at(end_pos, Vector3.UP)

	# play any AnimationPlayer child if present
	var ap := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if ap != null:
		if ap.has_animation("shoot"):
			ap.play("shoot")
		elif ap.has_animation("fire"):
			ap.play("fire")
		elif ap.get_animation_list().size() > 0:
			ap.play(ap.get_animation_list()[0])

	# tween to the end and free
	var dist: float = start_pos.distance_to(end_pos)
	var dur: float = min_life
	if speed > 0.0:
		dur = max(dist / speed, min_life)

	var tw := get_tree().create_tween()
	tw.tween_property(self, "global_position", end_pos, dur)
	tw.tween_callback(queue_free)
