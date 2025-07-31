extends Area3D

@export var speed: float = 10.0
@export var lifetime: float = 3.0
var direction: Vector3 = Vector3.FORWARD

func _ready():
	connect("body_entered", _on_body_entered)

func _process(delta):
	translate(direction * speed * delta)
	lifetime -= delta
	if lifetime <= 0:
		queue_free()

func _on_body_entered(body):
	if body.has_method("take_damage"):
		body.take_damage(1)
	queue_free()
