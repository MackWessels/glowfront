extends Node
@export var starting_balance: int = 50

func _ready() -> void:
	# Initialize the wallet once per run from this node.
	Economy.setup(starting_balance)
	Economy.balance_changed.connect(_on_balance_changed)
	print("[Minerals] Linked. start =", Economy.balance())

func _on_balance_changed(bal: int) -> void:
	print("[Minerals] balance_changed ->", bal)
