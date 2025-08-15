extends Node
# Minerals.gd — simple economy manager with debug logs

@export var starting_minerals: int = 50
@export var debug_prints: bool = true

var minerals: int = 0
signal minerals_changed(current: int)

func _ready() -> void:
	minerals = max(0, starting_minerals)
	if debug_prints:
		print("[Minerals] Ready. Starting = ", minerals)
	emit_signal("minerals_changed", minerals)

func set_amount(v: int) -> void:
	minerals = max(0, v)
	if debug_prints:
		print("[Minerals] set_amount -> ", minerals)
	emit_signal("minerals_changed", minerals)

func add(amount: int) -> void:
	if amount == 0: return
	var before := minerals
	minerals = max(0, minerals + amount)
	if debug_prints:
		print("[Minerals] add +", amount, " | ", before, " -> ", minerals)
	emit_signal("minerals_changed", minerals)

func can_afford(cost: int) -> bool:
	var ok := cost <= minerals
	if debug_prints:
		print("[Minerals] can_afford? cost=", cost, " balance=", minerals, " -> ", ok)
	return ok

func spend(cost: int) -> bool:
	if cost <= 0:
		if debug_prints: print("[Minerals] spend cost<=0 -> allowed")
		return true
	if minerals < cost:
		if debug_prints: print("[Minerals] spend DENIED. cost=", cost, " balance=", minerals)
		return false
	var before := minerals
	minerals -= cost
	if debug_prints:
		print("[Minerals] spend -", cost, " | ", before, " -> ", minerals)
	emit_signal("minerals_changed", minerals)
	return true

func refund(cost: int) -> void:
	if cost <= 0: return
	var before := minerals
	minerals += cost
	if debug_prints:
		print("[Minerals] refund +", cost, " | ", before, " -> ", minerals)
	emit_signal("minerals_changed", minerals)
