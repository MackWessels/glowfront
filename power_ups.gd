extends Node

# ---------- signals ----------
signal changed()
signal upgrade_purchased(id: String, new_level: int, next_cost: int)
signal powerup_started(id: String)
signal powerup_ended(id: String)

@export var econ_path: NodePath
@export var debug: bool = true

# ---------- economy ----------
var _econ: Node = null

func _ready() -> void:
	_resolve_econ()
	set_process(true)

func _resolve_econ() -> void:
	if econ_path != NodePath(""):
		_econ = get_node_or_null(econ_path)
	if _econ == null:
		_econ = get_node_or_null("/root/Economy")
	if _econ == null:
		_econ = get_node_or_null("/root/Minerals")
	if debug:
		print("[PowerUps] economy resolved -> ", _econ)

func balance() -> int:
	if _econ == null: return 0
	if _econ.has_method("balance"): return int(_econ.call("balance"))
	var v: Variant = _econ.get("minerals")
	if typeof(v) == TYPE_INT: return int(v)
	return 0

func _try_spend(cost: int, reason: String = "") -> bool:
	if _econ == null: return false
	if _econ.has_method("try_spend"): return bool(_econ.call("try_spend", cost, reason))
	if _econ.has_method("spend"):     return bool(_econ.call("spend", cost))
	if _econ.has_method("set_amount"):
		var b: int = balance()
		if b < cost: return false
		_econ.call("set_amount", b - cost)
		return true
	return balance() >= cost

# ---------- optional: timed powerups ----------
var _time: float = 0.0
var _active: Dictionary = {}   # id -> {"expires_at": float, "data": Dictionary}

func _process(delta: float) -> void:
	_time += delta
	var ended: Array[String] = []
	for id in _active.keys():
		var exp: float = float((_active[id] as Dictionary).get("expires_at", 0.0))
		if exp > 0.0 and _time >= exp:
			ended.append(id)
	for id in ended:
		_active.erase(id)
		powerup_ended.emit(id)
	if ended.size() > 0:
		changed.emit()

func activate(id: String, duration_sec: float, data: Dictionary) -> void:
	var expires_at: float = ( _time + duration_sec ) if duration_sec > 0.0 else 0.0
	_active[id] = {"expires_at": expires_at, "data": data}
	powerup_started.emit(id)
	changed.emit()
	if debug:
		print("[PowerUps] activated '", id, "' for ", duration_sec, "s -> ", data)

# ---------- repeatable upgrades ----------
@export var upgrades_config: Dictionary = {
	"turret_damage": {
		"base_cost": 20,      # first purchase
		"cost_factor": 1.25,  # geometric growth per level
		"cost_round_to": 1,   # round to nearest N (1/5/10)
		"per_level_pct": 10.0,# +% damage per level
		"max_level": 0        # 0 = unlimited
	}
}

var _upgrades_state: Dictionary = {}   # id -> {"level": int}

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
		if debug:
			print("[PowerUps] purchase FAILED '", id, "' need=", cost, " bal=", balance())
		return false
	_upgrades_state[id] = {"level": lvl + 1}
	var next_cost: int = upgrade_cost(id)
	changed.emit()
	upgrade_purchased.emit(id, lvl + 1, next_cost)
	if debug:
		print("[PowerUps] purchased '", id, "' -> level=", (lvl + 1), " next_cost=", next_cost)
	return true

# ---------- effects ----------
func turret_damage_multiplier() -> float:
	var conf: Dictionary = upgrades_config.get("turret_damage", {}) as Dictionary
	var lvl: int = upgrade_level("turret_damage")
	if conf.is_empty() or lvl <= 0:
		return 1.0
	var per: float = float(conf.get("per_level_pct", 0.0)) / 100.0
	return pow(1.0 + per, float(lvl))

# Combine upgrades + any timed buffs (if you use them)
func damage_multiplier(kind: String = "") -> float:
	var mult: float = 1.0
	if kind == "turret" or kind == "":
		mult *= turret_damage_multiplier()
	for id in _active.keys():
		var data: Dictionary = (_active[id] as Dictionary).get("data", {}) as Dictionary
		var kinds: Array = data.get("damage_kinds", [])
		if kinds.is_empty() or kinds.has(kind) or kind == "":
			mult *= 1.0 + float(data.get("damage_pct", 0.0)) / 100.0
	return mult
