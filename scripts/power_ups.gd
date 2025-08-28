extends Node

signal changed()
signal upgrade_purchased(id: String, new_level: int, next_cost: int)

# ---------- Minerals / run currency ----------
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

# ---------- CONFIG ----------
@export var upgrades_config: Dictionary = {
	# Offense
	"turret_damage":     { "cost_sequence": [10, 12, 14, 17, 20, 24, 29, 35], "max_level": 0 },
	"turret_rate":       { "cost_sequence": [15, 18, 22, 27, 33, 40, 48, 57, 67, 78], "max_level": 0 },
	"turret_range":      { "cost_sequence": [12, 15, 19, 24, 30, 37, 45, 54, 64, 75], "max_level": 0 },
	"crit_chance":       { "cost_sequence": [20, 25, 30, 38, 48, 60, 75, 95, 120],     "max_level": 0 },
	"crit_mult":         { "cost_sequence": [18, 24, 30, 38, 48, 60, 75, 95, 120],     "max_level": 0 },
	# NEW: Multi-Shot (overflow >100% gives chance for +1 target, etc.)
	"turret_multishot":  { "cost_sequence": [25, 30, 36, 43, 51, 60, 70, 81, 93, 106], "max_level": 0 },

	# Base / utility
	"base_max_hp":       { "cost_sequence": [20, 25, 32, 40, 49, 59, 70, 82, 95, 109], "max_level": 0 },
	"base_regen":        { "cost_sequence": [15, 20, 26, 33, 41, 50, 60, 72, 85, 99],  "max_level": 0 }
}

# Attack speed (global multiplier on interval; <1 = faster)
@export var rate_mult_per_step: float = 0.95
@export var turret_base_fire_rate_default: float = 1.0
@export var turret_min_fire_interval_default: float = 0.05

# Range (global additive bonus in world units)
@export var turret_base_acquire_range_default: float = 12.0
@export var turret_range_add_per_step: float = 2.0

# Crit tuning
@export var crit_chance_base: float = 0.0
@export var crit_chance_per_step: float = 0.02
@export var crit_chance_cap: float = 0.95

@export var crit_mult_base: float = 2.0
@export var crit_mult_per_step: float = 0.05
@export var crit_mult_cap: float = 4.0

# Health preview defaults for HUD fallbacks (match Health autoload)
@export var base_max_hp_default: int = 5
@export var hp_per_level_default: int = 10
@export var base_regen_per_sec_default: float = 0.0
@export var regen_per_level_default: float = 0.5

# NEW: Multi-Shot tuning (percent can exceed 100)
@export var multishot_base_percent: float = 0.0
@export var multishot_percent_per_step: float = 20.0

# Meta (shards) – keep damage + health; (skip multishot for now, easy to add later)
const _SHARDS_COSTS: Dictionary = {
	"turret_damage": [30, 55, 88, 128, 177],
	"base_max_hp":   [25, 45, 72, 106, 147],
	"base_regen":    [25, 45, 72, 106, 147]
}
const META_SAVE_PATH := "user://powerups_meta.cfg"

# ---------- STATE ----------
var _upgrades_state: Dictionary = {}  # id -> {"level": int}
var _meta_state: Dictionary = {}      # id -> int

func _ready() -> void:
	_load_meta()
	# Ping listeners (e.g., Health) once meta is loaded.
	call_deferred("_emit_initial_changed")

func _emit_initial_changed() -> void:
	changed.emit()

# ---------- LEVEL QUERIES ----------
# Compatibility aliases (callers may probe any of these)
func level(id: String) -> int:     return total_level(id)
func get_level(id: String) -> int: return total_level(id)
func level_of(id: String) -> int:  return total_level(id)

func upgrade_level(id: String) -> int:
	var e: Dictionary = _upgrades_state.get(id, {}) as Dictionary
	if e.is_empty():
		return 0
	var v: Variant = e.get("level", 0)
	if typeof(v) == TYPE_INT:
		return int(v)
	return 0

func meta_level(id: String) -> int:
	return int(_meta_state.get(id, 0))

func total_level(id: String) -> int:
	return upgrade_level(id) + meta_level(id)

func begin_run() -> void:
	_upgrades_state.clear()
	changed.emit()

# ---------- SHOP (minerals) ----------
func upgrade_cost(id: String) -> int:
	var conf: Dictionary = upgrades_config.get(id, {}) as Dictionary
	if conf.is_empty():
		return -1
	var lvl_run: int = upgrade_level(id)

	if conf.has("cost_sequence"):
		var seq: Array = conf.get("cost_sequence", []) as Array
		return _sequence_cost(seq, lvl_run)

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
	var cost: int = int(seq[n - 1])
	var inc: int = 5
	if n >= 2:
		inc = int(seq[n - 1]) - int(seq[n - 2])
	var extra_levels: int = lvl_index - n + 1
	for _i in range(extra_levels):
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
	var lvl_run: int = upgrade_level(id)
	if max_level > 0 and lvl_run >= max_level:
		return false

	var cost: int = upgrade_cost(id)
	if cost < 0:
		return false
	if not _try_spend(cost, "upgrade:" + id):
		return false

	_upgrades_state[id] = {"level": lvl_run + 1}
	var next_cost: int = upgrade_cost(id)
	changed.emit()
	upgrade_purchased.emit(id, total_level(id), next_cost)
	return true

# ---------- SHARDS (meta) ----------
func get_next_meta_offer(id: String) -> Dictionary:
	if not _SHARDS_COSTS.has(id):
		return {"available": false}
	var m_lvl: int = meta_level(id)
	var costs: Array = _SHARDS_COSTS[id]
	var cost: int
	if m_lvl < costs.size():
		cost = int(costs[m_lvl])
	else:
		cost = int(round(float(costs.back()) * 1.33))
	var next_value: int = _value_for(id, m_lvl + 2)
	return {"available": true, "next_value": next_value, "cost_shards": cost}

func purchase_meta(id: String) -> bool:
	if not _SHARDS_COSTS.has(id):
		return false
	var offer: Dictionary = get_next_meta_offer(id)
	var available: bool = bool(offer.get("available", false))
	if not available:
		return false
	var cost: int = int(offer.get("cost_shards", 0))
	if not Shards.try_spend(cost, "meta_upgrade:" + id):
		return false
	_meta_state[id] = meta_level(id) + 1
	_save_meta()
	changed.emit()
	upgrade_purchased.emit(id, total_level(id), upgrade_cost(id))
	return true

# ---------- HUD HELPERS ----------
func get_next_run_offer(id: String) -> Dictionary:
	var t_lvl: int = total_level(id)
	var next_value: int = _value_for(id, t_lvl + 2)
	var cost: int = upgrade_cost(id)
	if cost < 0:
		return {"available": false}
	return {"available": true, "next_value": next_value, "cost_minerals": cost}

# Attack speed (for HUD + math)
func turret_rate_info(reference_turret: Node = null) -> Dictionary:
	var steps: int = total_level("turret_rate")
	var cost: int = upgrade_cost("turret_rate")

	var global_mult_now: float = pow(maxf(0.01, rate_mult_per_step), float(steps))
	var global_mult_next: float = global_mult_now * maxf(0.01, rate_mult_per_step)

	var base: float = turret_base_fire_rate_default
	var local_mult: float = 1.0
	var min_rate: float = turret_min_fire_interval_default
	var current_interval: float = 0.0

	if reference_turret != null:
		if reference_turret.has_method("get_base_fire_rate"):
			base = float(reference_turret.get_base_fire_rate())
		if reference_turret.has_method("get_rate_mult_per_level") and reference_turret.has_method("get_rate_level"):
			local_mult = pow(maxf(0.01, float(reference_turret.get_rate_mult_per_level())), float(reference_turret.get_rate_level()))
		if reference_turret.has_method("get_min_fire_interval"):
			min_rate = float(reference_turret.get_min_fire_interval())
		if reference_turret.has_method("get_current_fire_interval"):
			current_interval = float(reference_turret.get_current_fire_interval())

	if current_interval <= 0.0:
		current_interval = clampf(base * local_mult * global_mult_now, min_rate, 999.0)
	var next_interval: float = clampf(base * local_mult * global_mult_next, min_rate, 999.0)

	var cur_sps: float = 0.0
	if current_interval > 0.0:
		cur_sps = 1.0 / current_interval

	return {
		"level_total": steps,
		"cost_minerals": cost,
		"current_interval": current_interval,
		"current_sps": cur_sps,
		"next_interval": next_interval,
		"available": cost >= 0
	}

func find_any_turret() -> Node:
	var ts: Array = get_tree().get_nodes_in_group("turret")
	if ts.size() > 0:
		return ts[0]
	return null

# Range (for HUD + math)
func turret_range_bonus() -> float:
	var steps: int = total_level("turret_range")
	return maxf(0.0, float(steps) * turret_range_add_per_step)

func next_turret_range_bonus() -> float:
	var steps_next: int = total_level("turret_range") + 1
	return maxf(0.0, float(steps_next) * turret_range_add_per_step)

func turret_range_info(reference_turret: Node = null) -> Dictionary:
	var cost: int = upgrade_cost("turret_range")

	var base: float = turret_base_acquire_range_default
	var local_add: float = 0.0
	var current_range: float = 0.0

	if reference_turret != null:
		if reference_turret.has_method("get_base_acquire_range"):
			base = float(reference_turret.get_base_acquire_range())
		if reference_turret.has_method("get_range_per_level") and reference_turret.has_method("get_range_level"):
			local_add = float(reference_turret.get_range_per_level()) * float(reference_turret.get_range_level())
		if reference_turret.has_method("get_current_acquire_range"):
			current_range = float(reference_turret.get_current_acquire_range())

	if current_range <= 0.0:
		current_range = maxf(0.5, base + local_add + turret_range_bonus())
	var next_range: float = maxf(0.5, base + local_add + next_turret_range_bonus())

	return {
		"cost_minerals": cost,
		"current_range": current_range,
		"next_range": next_range
	}

# Health HUD helpers (works with /root/Health if present)
func _get_health_node_if_any(passed: Node) -> Node:
	if passed != null:
		return passed
	var h: Node = get_node_or_null("/root/Health")
	return h

func health_max_info(health_node: Node = null) -> Dictionary:
	var cost: int = upgrade_cost("base_max_hp")
	var base_val: int = base_max_hp_default
	var per_step: int = hp_per_level_default

	var h: Node = _get_health_node_if_any(health_node)
	if h != null:
		if "base_max_hp" in h:
			base_val = int(h.base_max_hp)
		if "hp_per_level" in h:
			per_step = int(h.hp_per_level)

	var steps: int = total_level("base_max_hp")
	var current_max: int = max(1, base_val + per_step * steps)
	var next_max: int = max(1, base_val + per_step * (steps + 1))

	return {
		"cost_minerals": cost,
		"current_max_hp": current_max,
		"next_max_hp": next_max,
		"available": cost >= 0
	}

func health_regen_info(health_node: Node = null) -> Dictionary:
	var cost: int = upgrade_cost("base_regen")
	var base_val: float = base_regen_per_sec_default
	var per_step: float = regen_per_level_default

	var h: Node = _get_health_node_if_any(health_node)
	if h != null:
		if "base_regen_per_sec" in h:
			base_val = float(h.base_regen_per_sec)
		if "regen_per_level" in h:
			per_step = float(h.regen_per_level)

	var steps: int = total_level("base_regen")
	var current_regen: float = base_val + per_step * float(steps)
	var next_regen: float = base_val + per_step * float(steps + 1)

	return {
		"cost_minerals": cost,
		"current_regen_per_sec": current_regen,
		"next_regen_per_sec": next_regen,
		"available": cost >= 0
	}

# NEW: Multi-Shot HUD/math helpers
func multishot_percent_value() -> float:
	var steps: int = total_level("turret_multishot")
	return maxf(0.0, multishot_base_percent + multishot_percent_per_step * float(steps))

func next_multishot_percent_value() -> float:
	var steps_next: int = total_level("turret_multishot") + 1
	return maxf(0.0, multishot_base_percent + multishot_percent_per_step * float(steps_next))

# ---------- VALUE PATHS (for generic previews) ----------
func _value_for(id: String, step: int) -> int:
	if step <= 0:
		return 0
	if id == "turret_damage":
		return _damage_formula(step)
	if id == "base_max_hp":
		var base_val: int = base_max_hp_default
		var per_step: int = hp_per_level_default
		return max(1, base_val + per_step * (step - 1))
	if id == "base_regen":
		# integerized (×100) for generic displays
		var base_val_f: float = base_regen_per_sec_default
		var per_step_f: float = regen_per_level_default
		return int(round((base_val_f + per_step_f * float(step - 1)) * 100.0))
	return 0

# damage(n) = 3*n + max(0, floor((n - 4) * 2/3))
func _damage_formula(n: int) -> int:
	var t: int = n - 4
	var bonus: int = 0
	if t > 0:
		bonus = int(floor(t * 2.0 / 3.0))
	return 3 * n + max(0, bonus)

# public damage helpers
func turret_damage_value() -> int:
	return _value_for("turret_damage", total_level("turret_damage") + 1)

func next_turret_damage_value() -> int:
	return _value_for("turret_damage", total_level("turret_damage") + 2)

# attack speed
func turret_rate_mult() -> float:
	var steps: int = total_level("turret_rate")
	return pow(maxf(0.01, rate_mult_per_step), float(steps))

# crit
func crit_chance_value() -> float:
	var steps: int = total_level("crit_chance")
	return clampf(crit_chance_base + crit_chance_per_step * float(steps), 0.0, crit_chance_cap)

func next_crit_chance_value() -> float:
	var steps_next: int = total_level("crit_chance") + 1
	return clampf(crit_chance_base + crit_chance_per_step * float(steps_next), 0.0, crit_chance_cap)

func crit_mult_value() -> float:
	var steps: int = total_level("crit_mult")
	return clampf(crit_mult_base + crit_mult_per_step * float(steps), 1.0, crit_mult_cap)

func next_crit_mult_value() -> float:
	var steps_next: int = total_level("crit_mult") + 1
	return clampf(crit_mult_base + crit_mult_per_step * float(steps_next), 1.0, crit_mult_cap)

# ---------- Compatibility / hooks ----------
func turret_damage_bonus() -> int: return turret_damage_value()
func turret_damage_multiplier() -> float: return 1.0
func damage_multiplier(kind: String = "") -> float: return 1.0
func modified_cost(action: String, base: int) -> int: return base

# ---------- Utils ----------
func _round_to(value: float, step: int) -> int:
	if step <= 1:
		return int(round(value))
	return int(round(value / float(step))) * step

# ---------- Meta persistence ----------
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

func reset_meta_for_testing() -> void:
	_meta_state.clear()
	_save_meta()
	changed.emit()
