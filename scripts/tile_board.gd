extends Node3D

@export var tile_scene: PackedScene
@export var columns: int = 10
@export var rows: int = 10
@export var tile_spacing: float = 2.1

func _ready():
	for x in range(columns):
		for z in range(rows):
			var tile = tile_scene.instantiate()
			add_child(tile)
			tile.global_position = Vector3(x * tile_spacing, 0, z * tile_spacing)

			# Set grid coordinates
			tile.grid_x = x
			tile.grid_z = z
