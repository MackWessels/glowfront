extends Node3D

@export var board_size: int = 10
@export var tile_scene: PackedScene
@export var tile_size: float = 2.0
@export var spacing: float = 0.2
@export var goal_node: Node3D
@export var spawner_node: Node3D
@export var placement_menu: PopupMenu
@export var enemy_spawner: Node3D

signal path_updated(curve: Curve3D)
signal global_path_changed

var tiles = {}
var active_tile: Node = null
var cached_path: Array = []
var blocked_tile: Vector2i = Vector2i(-1, -1)

func _ready():
	generate_board()
	position_portal(goal_node, "right")
	position_portal(spawner_node, "left")
	update_path()
	placement_menu.connect("place_selected", Callable(self, "_on_place_selected"))


func generate_board():
	for x in board_size:
		for z in board_size:
			var tile = tile_scene.instantiate()
			var pos = Vector3(
				x * (tile_size + spacing),
				0,
				z * (tile_size + spacing)
			)
			tile.global_position = pos
			tile.grid_position = Vector2i(x, z)
			tile.tile_board = self
			tile.placement_menu = placement_menu
			add_child(tile)
			tiles[Vector2i(x, z)] = tile


func position_portal(portal: Node3D, side: String):
	var tile_pos = Vector2i()
	var rotation_y = 0.0

	match side:
		"left":
			tile_pos = Vector2i(0, board_size / 2)
			rotation_y = deg_to_rad(90)
		"right":
			tile_pos = Vector2i(board_size - 1, board_size / 2)
			rotation_y = deg_to_rad(-90)
		"top":
			tile_pos = Vector2i(board_size / 2, 0)
			rotation_y = deg_to_rad(0)
		"bottom":
			tile_pos = Vector2i(board_size / 2, board_size - 1)
			rotation_y = deg_to_rad(180)

	var tile = tiles.get(tile_pos)
	if tile:
		portal.global_position = tile.global_position
		portal.rotation.y = rotation_y


func find_path(start: Vector2i, goal: Vector2i) -> Array:
	var open_set = [start]
	var came_from = {}
	var g_score = {start: 0}
	var f_score = {start: start.distance_to(goal)}
	var INF = 9999999

	while open_set.size() > 0:
		open_set.sort_custom(func(a, b): return f_score.get(a, INF) < f_score.get(b, INF))
		var current = open_set[0]

		if current == goal:
			var path = [current]
			while current in came_from:
				current = came_from[current]
				path.insert(0, current)

			var world_path = []
			for p in path:
				if tiles.has(p):
					world_path.append(tiles[p].global_position)
			return world_path

		open_set.remove_at(0)

		for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var neighbor = current + offset
			if not tiles.has(neighbor):
				continue
			var tile = tiles[neighbor]
			if not tile.is_walkable():
				continue

			var tentative_g = g_score.get(current, INF) + 1
			if tentative_g < g_score.get(neighbor, INF):
				came_from[neighbor] = current
				g_score[neighbor] = tentative_g
				f_score[neighbor] = tentative_g + neighbor.distance_to(goal)
				if neighbor not in open_set:
					open_set.append(neighbor)
	return []


func update_path():
	if not is_instance_valid(spawner_node) or not is_instance_valid(goal_node):
		cached_path = []
		return

	var from_tile = world_to_tile(spawner_node.global_position)
	var end_tile = world_to_tile(goal_node.global_position)
	cached_path = find_path(from_tile, end_tile)

	var curve := Curve3D.new()
	for point in cached_path:
		curve.add_point(point)

	$Path3D.curve = curve
	emit_signal("path_updated", curve)
	emit_signal("global_path_changed")


func world_to_tile(pos: Vector3) -> Vector2i:
	return Vector2i(round(pos.x / 2.2), round(pos.z / 2.2))


func get_path_from(world_pos: Vector3) -> Array:
	var from_tile = world_to_tile(world_pos)
	var end_tile = world_to_tile(goal_node.global_position)
	return find_path(from_tile, end_tile)


func get_curve_for_path(path: Array) -> Curve3D:
	var curve := Curve3D.new()
	for point in path:
		curve.add_point(point)
	return curve


func _on_place_selected(action: String):
	if active_tile and is_instance_valid(active_tile):
		var coords = active_tile.grid_position
		active_tile.apply_placement(action)

		var from_tile = world_to_tile(spawner_node.global_position)
		var end_tile = world_to_tile(goal_node.global_position)
		var test_path = find_path(from_tile, end_tile)

		if test_path.is_empty():
			blocked_tile = coords

			if enemy_spawner and enemy_spawner.has_method("shoot_tile"):
				enemy_spawner.shoot_tile(tiles[blocked_tile].global_position)

			await get_tree().create_timer(1.0).timeout

			if tiles.has(blocked_tile):
				tiles[blocked_tile].break_tile()
				update_path()

			blocked_tile = Vector2i(-1, -1)
		else:
			update_path()

	active_tile = null
