extends Node3D

func on_tile_clicked():
	print("Tile clicked!")

func _ready():
	add_to_group("Tile")
