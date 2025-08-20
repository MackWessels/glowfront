extends Node

# ---------- signals ----------
signal changed()
signal upgrade_purchased(id: String, new_level: int, next_cost: int)

# ---------- economy helpers (minerals/run currency) ----------
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

# ---------- config ----------
# In-run (minerals) costs and max levels.
@export var upgrades_config: Dictionary = {
	"turret_damage": {
		"cost_sequence": [10, 12, 14, 17, 20, 24, 29, 35],
		"max_level": 0
	}
}

# Meta (shards) costs per permanent step.
const _SHARDS_COSTS: Dictionary = {
	"turret_damage": [30, 55, 88, 128, 177]
}

# Save file for permanent (meta) levels
const META_SAVE_PATH := "user://powerups_meta.cfg"

# ---------- state ----------
# Run-only levels (reset every game)
var _upgrades_state: Dictionary = {}  # id -> {"level": int}

# Permanent levels (purchased with shards from main menu)
var _meta_state: Dictionary = {}      # id -> int

func _ready() -> void:
	_load_meta()

# ---------- levels ----------
func upgrade_level(id: String) -> int:
	# Run level (minerals)
	var e: Dictionary = _upgrades_state.get(id, {}) as Dictionary
	if e.is_empty():
		return 0
	var v: Variant = e.get("level", 0)
	return (int(v) if typeof(v) == TYPE_INT else 0)

func meta_level(id: String) -> int:
	return int(_meta_state.get(id, 0))

func total_level(id: String) -> int:
	return upgrade_level(id) + meta_level(id)

# Call at the start of a new gameplay run
func begin_run() -> void:
	_upgrades_state.clear()
	changed.emit()

# ---------- minerals cost helpers ----------
func upgrade_cost(id: String) -> int:
	# Cost for the NEXT in-run purchase; depends only on run level.
	var conf: Dictionary = upgrades_config.get(id, {}) as Dictionary
	if conf.is_empty():
		return -1
	var lvl_run: int = upgrade_level(id)
	if conf.has("cost_sequence"):
		return _sequence_cost(conf.get("cost_sequence", []) as Array, lvl_run)

	# Optional parametric fallback (kept for compatibility)
	var base_cost: int = int(conf.get("base_cost", 0))
	var factor: float = float(conf.get("cost_factor", 1.0))
	var step: int = int(conf.get("cost_round_to", 1))
	var raw: float = float(base_cost) * pow(factor, float(lvl_run))
	return _round_to(raw, step)

func _sequence_cost(seq: Array, lvl_index: int) -> int:
	var n: int = seq.size()
	if n == 0:
		return -1
	if lvl_index < n:
		return int(seq[lvl_index])

	# soft tail if sequence runs out
	var cost: int = int(seq[n - 1])
	var inc: int = (int(seq[n - 1]) - int(seq[n - 2])) if n >= 2 else 5
	var extra_levels: int = lvl_index - n + 1
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
	# In-run purchase (minerals)
	var conf: Dictionary = upgrades_config.get(id, {}) as Dictionary
	if conf.is_empty():
		return false

	var max_level: int = int(conf.get("max_level", 0))
	var lvl_run: int = upgrade_level(id)
	if max_level > 0 and lvl_run >= max_level:
		return false

	var cost: int = upgrade_cost(id)
	if cost < 0 or not _try_spend(cost, "upgrade:" + id):
		return false

	_upgrades_state[id] = {"level": lvl_run + 1}

	# Next minerals cost depends on *new* run level
	var next_cost: int = upgrade_cost(id)
	changed.emit()
	upgrade_purchased.emit(id, total_level(id), next_cost)
	return true

# ---------- shards (meta) shop ----------
func get_next_meta_offer(id: String) -> Dictionary:
	if not _SHARDS_COSTS.has(id):
		return {"available": false}
	var m_lvl := meta_level(id)
	var next_value := _value_for(id, m_lvl + 1)  # what buying with shards will give you
	var costs: Array = _SHARDS_COSTS[id]
	var cost := (int(costs[m_lvl]) if m_lvl < costs.size() else int(round(float(costs.back()) * 1.33)))
	return {"available": true, "next_value": next_value, "cost_shards": cost}

func purchase_meta(id: String) -> bool:
	if not _SHARDS_COSTS.has(id):
		return false
	# read current meta step and cost
	var offer := get_next_meta_offer(id)
	if not offer.available:
		return false
	var cost: int = int(offer.cost_shards)
	if not Shards.try_spend(cost, "meta_upgrade:" + id):
		return false

	_meta_state[id] = meta_level(id) + 1
	_save_meta()

	# Emit with the new total level to help HUDs refresh
	changed.emit()
	upgrade_purchased.emit(id, total_level(id), upgrade_cost(id))
	return true

# ---------- run UI helper (minerals) ----------
func get_next_run_offer(id: String) -> Dictionary:
	var t_lvl := total_level(id)
	var next_value := _value_for(id, t_lvl + 1)   # value after the next *run* purchase
	var cost := upgrade_cost(id)                  # cost depends only on run level
	if cost < 0:
		return {"available": false}
	return {"available": true, "next_value": next_value, "cost_minerals": cost}

# ---------- value paths ----------
# DAMAGE pattern (you supplied): 3, 6, 9, 12, 15, 19, 23, 26, 30, ...
# We'll treat "step n" as the value after n total purchases (meta+run).
func _value_for(id: String, step: int) -> int:
	if step <= 0:
		return 0
	if id == "turret_damage":
		return _damage_formula(step)  # step is 1-indexed
	return 0

# damage(n) = 3*n + max(0, floor((n - 4) * 2 / 3))
func _damage_formula(n: int) -> int:
	var t: int = n - 4
	var bonus: int = (int(floor(t * 2.0 / 3.0)) if t > 0 else 0)
	return 3 * n + max(0, bonus)

# ---------- public helpers for damage ----------
# Current bonus applied in gameplay (0 if you haven’t bought any, meta or run)
func turret_damage_bonus() -> int:
	return _value_for("turret_damage", total_level("turret_damage"))

# For legacy UI: "current" and "next" values now include meta+run levels.
func turret_damage_value() -> int:
	return turret_damage_bonus()

func next_turret_damage_value() -> int:
	return _value_for("turret_damage", total_level("turret_damage") + 1)

func turret_damage_multiplier() -> float:
	return 1.0

func damage_multiplier(kind: String = "") -> float:
	return 1.0

# ---------- misc utils ----------
func _round_to(value: float, step: int) -> int:
	if step <= 1:
		return int(round(value))
	return int(round(value / float(step))) * step

# ---------- persistence for meta ----------
func _save_meta() -> void:
	var cfg := ConfigFile.new()
	for id in _SHARDS_COSTS.keys():
		cfg.set_value("meta", id, meta_level(id))
	cfg.save(META_SAVE_PATH)

func _load_meta() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(META_SAVE_PATH) == OK:
		for id in _SHARDS_COSTS.keys():
			_meta_state[id] = int(cfg.get_value("meta", id, 0))

# Clear permanent (shards) upgrades and save
func reset_meta_for_testing() -> void:
	_meta_state.clear()
	_save_meta()
	changed.emit()
