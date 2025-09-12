extends PopupMenu

signal place_selected(action: String)

const ID_TURRET := 0
const ID_WALL   := 1
const ID_REPAIR := 2
const ID_MORTAR := 3
const ID_MINER  := 4
const ID_TESLA  := 5
const ID_SHARD_MINER := 6   # NEW

func _ready() -> void:
	# Items are populated by the Tile right-click; we just relay selections.
	if not id_pressed.is_connected(_on_item_selected):
		id_pressed.connect(_on_item_selected)

func _on_item_selected(id: int) -> void:
	match id:
		ID_TURRET:      emit_signal("place_selected", "turret")
		ID_WALL:        emit_signal("place_selected", "wall")
		ID_REPAIR:      emit_signal("place_selected", "repair")
		ID_MORTAR:      emit_signal("place_selected", "mortar")
		ID_MINER:       emit_signal("place_selected", "miner")
		ID_TESLA:       emit_signal("place_selected", "tesla")
		ID_SHARD_MINER: emit_signal("place_selected", "shard_miner")  # NEW
		_:              pass
