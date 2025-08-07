extends PopupMenu

signal place_selected(action: String)

func _ready():
	clear()
	add_item("Place Turret", 0)
	add_item("Place Wall", 1)
	add_item("Repair Tile", 2)
	connect("id_pressed", Callable(self, "_on_item_selected"))

func _on_item_selected(id: int) -> void:
	match id:
		0: emit_signal("place_selected", "turret")
		1: emit_signal("place_selected", "wall")
		2: emit_signal("place_selected", "repair")
