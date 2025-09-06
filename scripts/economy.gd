extends Node

signal balance_changed(new_balance: int)
signal added(amount: int, source: String)
signal spent(amount: int, reason: String)

var _balance: int = 0

func setup(starting: int = 50) -> void:
	_balance = max(0, starting)
	balance_changed.emit(_balance)

func balance() -> int:
	return _balance

func can_afford(cost: int) -> bool:
	return cost <= _balance

func try_spend(cost: int, reason: String = "") -> bool:
	if cost <= 0:
		return true
	if _balance >= cost:
		_balance -= cost
		spent.emit(cost, reason)
		balance_changed.emit(_balance)
		return true
	return false

# Sugar for callers that expect 'spend' instead of 'try_spend'
func spend(cost: int, reason: String = "") -> bool:
	return try_spend(cost, reason)

func add(amount: int, source: String = "") -> void:
	if amount == 0:
		return
	_balance += amount
	added.emit(amount, source)
	balance_changed.emit(_balance)

# Sugar for callers that expect 'earn'
func earn(amount: int, source: String = "") -> void:
	add(amount, source)

# Useful for debug / refunds / direct overrides
func set_amount(value: int) -> void:
	_balance = max(0, value)
	balance_changed.emit(_balance)

# Sugar for callers that expect 'set_balance'
func set_balance(value: int) -> void:
	set_amount(value)
