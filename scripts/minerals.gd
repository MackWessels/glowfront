extends Node

@export var starting_balance: int = 50

func _ready() -> void:
	if typeof(Economy) != TYPE_NIL and Economy.has_method("setup"):
		Economy.setup(starting_balance)

# --- Thin wrappers so other scripts can talk to us or Economy interchangeably ---
func earn(amount: int) -> void:
	if amount <= 0: return
	if typeof(Economy) != TYPE_NIL and Economy.has_method("earn"):
		Economy.earn(amount)

func spend(amount: int) -> bool:
	if amount <= 0: return true
	if typeof(Economy) != TYPE_NIL:
		if Economy.has_method("try_spend"):
			return bool(Economy.try_spend(amount))
		if Economy.has_method("spend"):
			return bool(Economy.spend(amount))
	return false

func can_afford(amount: int) -> bool:
	if typeof(Economy) != TYPE_NIL and Economy.has_method("balance"):
		return int(Economy.balance()) >= amount
	return false

func balance() -> int:
	if typeof(Economy) != TYPE_NIL and Economy.has_method("balance"):
		return int(Economy.balance())
	return 0
