extends Node

# ---- signals ----
signal changed()
signal upgrade_purchased(id: String, new_level: int, next_cost: int)

# ---- economy helpers ----
func balance() -> int:
	if Economy.has_method("balance"):
		return int(Economy.call("balance"))
	var v: Variant = Economy.get("minerals")
	if typeof(v) == TYPE_INT:
		return int(v)
	return 0

func _try_spend(cost: int, reason: String = "") -> bool:
	if cost <= 0:
		return true
	if Economy.has_method("try_spend"):
		return bool(Economy.call("try_spend", cost, reason))
	if Economy.has_method("spend"):
		return bool(Economy.call("spend", cost))
	if Economy.has_method("set_amount"):
		var b: int = balance()
		if b < cost:
			return false
		Economy.call("set_amount", b - cost)
		return true
	return balance() >= cost

# ---- repeatable upgrades (CONFIG) ----
@export var upgrades_config: Dictionary = {
	"turret_damage": {
		# Level -> cost: 0.. -> 10, 12, 14, 17, 20, 24, 29, 35, then +7, +8, +9, ...
		"cost_sequence": [10, 12, 14, 17, 20, 24, 29, 35],
		"max_level": 0
	}
}

var _upgrades_state: Dictionary = {}

func upgrade_level(id: String) -> int:
	var e: Dictionary = _upgrades_state.get(id, {}) as Dictionary
	if e.is_empty():
		return 0
	var v: Variant = e.get("level", 0)
	if typeof(v) == TYPE_INT:
		return int(v)
	return 0

func _round_to(value: float, step: int) -> int:
	if step <= 1:
		return int(round(value))
	return int(round(value / float(step))) * step

# ---- cost logic ----
func upgrade_cost(id: String) -> int:
	var conf: Dictionary = upgrades_config.get(id, {}) as Dictionary
	if conf.is_empty():
		return -1

	var lvl: int = upgrade_level(id)

	if conf.has("cost_sequence"):
		var seq: Array = conf.get("cost_sequence", []) as Array
		return _sequence_cost(seq, lvl)

	# Fallback for other upgrades you add later
	var base_cost: int = int(conf.get("base_cost", 0))
	var factor: float = float(conf.get("cost_factor", 1.0))
	var step: int = int(conf.get("cost_round_to", 1))
	var raw: float = float(base_cost) * pow(factor, float(lvl))
	return _round_to(raw, step)

# Within sequence: exact value. Beyond: keep increasing the diff by +1 each level.
func _sequence_cost(seq: Array, lvl: int) -> int:
	var n: int = seq.size()
	if n == 0:
		return -1
	if lvl < n:
		return int(seq[lvl])

	var cost: int = int(seq[n - 1])
	var inc: int = (int(seq[n - 1]) - int(seq[n - 2])) if n >= 2 else 5
	var extra_levels: int = lvl - n + 1
	for i in range(extra_levels):
		inc += 1
		cost += inc
	return cost

func can_purchase(id: String) -> bool:
	var conf: Dictionary = upgrades_config.get(id, {}) as Dictionary
	if conf.is_empty():
		return false
	var max_level: int = int(conf.get("max_level", 0))
	if max_level > 0 and upgrade_level(id) >= max_level:
		return false
	return balance() >= upgrade_cost(id)

func purchase(id: String) -> bool:
	var conf: Dictionary = upgrades_config.get(id, {}) as Dictionary
	if conf.is_empty():
		return false
	var max_level: int = int(conf.get("max_level", 0))
	var lvl: int = upgrade_level(id)
	if max_level > 0 and lvl >= max_level:
		return false
	var cost: int = upgrade_cost(id)
	if cost < 0:
		return false
	if not _try_spend(cost, "upgrade:" + id):
		return false
	_upgrades_state[id] = {"level": lvl + 1}
	var next_cost: int = upgrade_cost(id)
	changed.emit()
	upgrade_purchased.emit(id, lvl + 1, next_cost)
	return true

# ---- DAMAGE: pattern value helpers ----
# damage(n) = 3*n + max(0, floor((n - 4) * 2 / 3))
# Map n = level + 1 so level 0 => n=1 => 3 dmg.
func _damage_formula(n: int) -> int:
	var t: int = n - 4
	var bonus: int = (int(floor(t * 2.0 / 3.0)) if t > 0 else 0)
	return 3 * n + max(0, bonus)

func turret_damage_value() -> int:
	var lvl: int = upgrade_level("turret_damage")
	var n: int = lvl + 1
	if n < 1:
		n = 1
	return _damage_formula(n)

func next_turret_damage_value() -> int:
	var lvl: int = upgrade_level("turret_damage")
	var n: int = lvl + 2
	if n < 1:
		n = 1
	return _damage_formula(n)

func turret_damage_multiplier() -> float:
	return 1.0

func damage_multiplier(kind: String = "") -> float:
	return 1.0
