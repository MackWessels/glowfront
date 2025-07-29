extends RigidBody3D

@export var speed = 25.0
var direction = Vector3.FORWARD

func _ready():
	# Optional: You can align the projectile mesh visually here if needed
	look_at(global_transform.origin + direction, Vector3.UP)

func _physics_process(delta):
	global_translate(direction * speed * delta)

func _on_body_entered(body):
	if body.name == "Enemy":
		queue_free()
		body.queue_free()
