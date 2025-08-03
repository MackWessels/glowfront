extends Node3D

@export var board_size: int = 10
@export var tile_scene: PackedScene
@export var tile_size: float = 2.0
@export var spacing: float = 0.2

@export var goal_node: Node3D
@export var spawner_node: Node3D

var tiles = {}

func _ready():
	generate_board()
	position_portal(goal_node, "right")
	position_portal(spawner_node, "left")

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
			tile.grid_x = x
			tile.grid_z = z
			add_child(tile)
			tiles[Vector2i(x, z)] = tile


func position_portal(node: Node3D, direction: String):
	var tile_x := 0
	var tile_z := board_size / 2  # Center row/column
	var rotation_y := 0.0

	match direction:
		"left":
			tile_x = 0
			rotation_y = deg_to_rad(90)
		"right":
			tile_x = board_size - 1
			rotation_y = deg_to_rad(-90)
		"top":
			tile_x = board_size / 2
			tile_z = 0
			rotation_y = 0
		"bottom":
			tile_x = board_size / 2
			tile_z = board_size - 1
			rotation_y = deg_to_rad(180)

	var tile_key = Vector2i(tile_x, tile_z)
	if tiles.has(tile_key):
		node.global_position = tiles[tile_key].global_position
		node.rotation.y = rotation_y
		print("%s tile: (%d, %d)" % [direction.capitalize(), tile_x, tile_z])
	else:
		print("Tile not found at (%d, %d)" % [tile_x, tile_z])
