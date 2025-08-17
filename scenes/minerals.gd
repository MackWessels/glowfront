extends Node

@export var starting_balance: int = 50

func _ready() -> void:
	Economy.setup(starting_balance)
