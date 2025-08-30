# res://autoloads/turret_inspector.gd
extends Node

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # run even when paused

func _input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_RIGHT:
		return

	# Only take over when the game is paused (defeat screen, etc.)
	if not get_tree().paused:
		return

	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return

	# Ray-pick into the 3D world at the mouse position
	var from := cam.project_ray_origin(mb.position)
	var to   := from + cam.project_ray_normal(mb.position) * 10000.0

	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_bodies = true
	q.collide_with_areas  = false

	var space_state := get_viewport().world_3d.direct_space_state
	var hit: Dictionary = space_state.intersect_ray(q)
	if hit.is_empty() or not hit.has("collider"):
		return

	var n := hit["collider"] as Node
	var turret := _find_turret_root(n)
	if turret != null and turret.has_method("toggle_stats_panel"):
		# Show/update the stats
		turret.call("toggle_stats_panel")
		# Consume the click properly in Godot 4:
		get_viewport().set_input_as_handled()

func _find_turret_root(n: Node) -> Node:
	var cur := n
	while cur != null:
		if cur.is_in_group("turret"):
			return cur
		cur = cur.get_parent()
	return null
