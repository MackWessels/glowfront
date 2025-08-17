extends Node

# signals 
signal changed()
signal upgrade_purchased(id: String, new_level: int, next_cost: int)

# economy
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

# repeatable upgrades 
@export var upgrades_config: Dictionary = {
	"turret_damage": {
		"base_cost": 20,      
		"cost_factor": 1.25, 
		"cost_round_to": 1,   
		"per_level_pct": 10.0,
		"max_level": 0        # 0 = unlimited
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

func upgrade_cost(id: String) -> int:
	var conf: Dictionary = upgrades_config.get(id, {}) as Dictionary
	if conf.is_empty():
		return -1
	var base_cost: int = int(conf.get("base_cost", 0))
	var factor: float = float(conf.get("cost_factor", 1.0))
	var step: int = int(conf.get("cost_round_to", 1))
	var lvl: int = upgrade_level(id)
	var raw: float = float(base_cost) * pow(factor, float(lvl))
	return _round_to(raw, step)

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

# effects
func turret_damage_multiplier() -> float:
	var conf: Dictionary = upgrades_config.get("turret_damage", {}) as Dictionary
	var lvl: int = upgrade_level("turret_damage")
	if conf.is_empty() or lvl <= 0:
		return 1.0
	var per: float = float(conf.get("per_level_pct", 0.0)) / 100.0
	return pow(1.0 + per, float(lvl))


func damage_multiplier(kind: String = "") -> float:
	var mult: float = 1.0
	if kind == "turret" or kind == "":
		mult *= turret_damage_multiplier()
	return mult
