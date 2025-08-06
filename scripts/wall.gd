extends StaticBody3D

var tile: Node = null

func set_tile(tile_ref: Node) -> void:
	tile = tile_ref
	if tile:
		tile.is_wall = true

func _exit_tree():
	if tile:
		tile.is_wall = false
