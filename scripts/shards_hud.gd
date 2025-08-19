extends HBoxContainer

@onready var amount_label: Label = $Amount

func _ready() -> void:
	_update_text(Shards.get_balance())
	Shards.changed.connect(_on_shards_changed)

func _on_shards_changed(new_balance: int) -> void:
	_update_text(new_balance)

func _update_text(v: int) -> void:
	amount_label.text = "Shards: %d" % v
