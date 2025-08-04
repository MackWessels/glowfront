extends Node3D

@export var board_size: int = 10
@export var tile_scene: PackedScene
@export var tile_size: float = 2.0
@export var spacing: float = 0.2

@export var goal_node: Node3D
@export var spawner_node: Node3D

var tiles = {}
var cached_path: Array = []

func _ready():
	generate_board()
	position_portal(goal_node, "right")
	position_portal(spawner_node, "left")
	update_path()

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
			add_child(tile)
			tiles[Vector2i(x, z)] = tile

func position_portal(portal: Node3D, side: String):
	var tile_pos = Vector2i()
	var rotation_y = 0.0

	match side:
		"left":
			tile_pos = Vector2i(0, board_size / 2)
			rotation_y = deg_to_rad(90)  # Faces +X
		"right":
			tile_pos = Vector2i(board_size - 1, board_size / 2)
			rotation_y = deg_to_rad(-90)  # Faces -X
		"top":
			tile_pos = Vector2i(board_size / 2, 0)
			rotation_y = deg_to_rad(0)  # Faces -Z
		"bottom":
			tile_pos = Vector2i(board_size / 2, board_size - 1)
			rotation_y = deg_to_rad(180)  # Faces +Z

	var tile = tiles.get(tile_pos)
	if tile:
		portal.global_position = tile.global_position
		portal.rotation.y = rotation_y


func find_path(start: Vector2i, goal: Vector2i) -> Array:
	var open_set = [start]
	var came_from = {}
	var g_score = {start: 0}
	var f_score = {start: start.distance_to(goal)}

	while open_set.size() > 0:
		open_set.sort_custom(func(a, b): return f_score.get(a, INF) < f_score.get(b, INF))
		var current = open_set[0]

		if current == goal:
			var path = [current]
			while current in came_from:
				current = came_from[current]
				path.insert(0, current)
			return path.map(func(p): return tiles[p].global_position)

		open_set.remove_at(0)
		for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var neighbor = current + offset
			var tile = tiles.get(neighbor)
			if tile and tile.is_walkable():
				var tentative_g = g_score.get(current, INF) + 1
				if tentative_g < g_score.get(neighbor, INF):
					came_from[neighbor] = current
					g_score[neighbor] = tentative_g
					f_score[neighbor] = tentative_g + neighbor.distance_to(goal)
					if not neighbor in open_set:
						open_set.append(neighbor)
	return []

func update_path():
	if not is_instance_valid(spawner_node) or not is_instance_valid(goal_node):
		cached_path = []
		return
	var start_tile = world_to_tile(spawner_node.global_position)
	var end_tile = world_to_tile(goal_node.global_position)
	cached_path = find_path(start_tile, end_tile)
	print("Updated path: ", cached_path)

func world_to_tile(pos: Vector3) -> Vector2i:
	var x = int(round(pos.x / (tile_size + spacing)))
	var z = int(round(pos.z / (tile_size + spacing)))
	return Vector2i(x, z)

func get_path_from(world_pos: Vector3) -> Array:
	var from_tile = world_to_tile(world_pos)
	var end_tile = world_to_tile(goal_node.global_position)
	return find_path(from_tile, end_tile)
