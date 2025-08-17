extends Control

@export var value_label_path: NodePath
var _label: Label

func _ready() -> void:
	_label = get_node_or_null(value_label_path) as Label
	Economy.balance_changed.connect(_on_balance_changed)
	_on_balance_changed(Economy.balance())

func _on_balance_changed(bal: int) -> void:
	_label.text = str(bal)
