extends Area3D
signal goal_reached(enemy)

@export var default_damage_per_enemy := 1
@export var use_enemy_override := true

func _ready() -> void:
	monitoring = true
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node) -> void:
	if body == null or not body.is_in_group("enemies"): return

	var dmg := default_damage_per_enemy
	if use_enemy_override and body.has_method("get_goal_damage"):
		dmg = int(body.call("get_goal_damage"))

	Health.damage(dmg, "goal_reached")
	emit_signal("goal_reached", body)

	if body.has_method("on_reach_goal"):
		body.call_deferred("on_reach_goal")
	else:
		body.call_deferred("queue_free")
