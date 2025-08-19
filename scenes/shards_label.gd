extends Label

func _ready() -> void:
	_update_text()
	Shards.changed.connect(func(_b): _update_text())

func _update_text() -> void:
	text = "Shards: %d" % Shards.get_balance()
