extends Node

signal balance_changed(new_balance: int)
signal added(amount: int, source: String)
signal spent(amount: int, reason: String)

var _balance: int = 0
var _ready_called := false

func setup(starting: int = 50) -> void:
	_balance = max(0, starting)
	_ready_called = true
	print("[Economy] Ready. Starting =", _balance)
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
		print("[Economy] SPEND %d (%s) -> bal=%d" % [cost, reason, _balance])
		spent.emit(cost, reason)
		balance_changed.emit(_balance)
		return true
	print("[Economy] DENY  %d (%s) need=%d have=%d" % [cost, reason, cost, _balance])
	return false

func add(amount: int, source: String = "") -> void:
	if amount == 0:
		return
	_balance += amount
	print("[Economy] ADD   %d (%s) -> bal=%d" % [amount, source, _balance])
	added.emit(amount, source)
	balance_changed.emit(_balance)
