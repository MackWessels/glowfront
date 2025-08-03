extends Area3D

signal goal_reached(enemy)

func _ready():
	connect("body_entered", Callable(self, "_on_body_entered"))

func _on_body_entered(body):
	if body.is_in_group("enemies"):
		emit_signal("goal_reached", body)
		body.queue_free()
