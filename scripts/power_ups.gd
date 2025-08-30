extends Node

signal changed()
signal upgrade_purchased(id: String, new_level: int, next_cost: int)

# ---------- Minerals / run currency ----------
func balance() -> int:
	if Economy.has_method("balance"):
		return int(Economy.call("balance"))
	var v: Variant = Economy.get("minerals")
	return (int(v) if typeof(v) == TYPE_INT else 0)

func _try_spend(cost: int, reason: String = "") -> bool:
	if cost <= 0: return true
	if Economy.has_method("try_spend"): return bool(Economy.call("try_spend", cost, reason))
	if Economy.has_method("spend"):     return bool(Economy.call("spend", cost))
	if Economy.has_method("set_amount"):
		var b := balance()
		if b < cost: return false
		Economy.call("set_amount", b - cost)
		return true
	return balance() >= cost

# ---------- CONFIG (per-run mineral upgrades) ----------
@export var upgrades_config: Dictionary = {
	# Offense
	"turret_damage":     {"cost_sequence":[10,12,14,17,20,24,29,35], "max_level":0},
	"turret_rate":       {"cost_sequence":[15,18,22,27,33,40,48,57,67,78], "max_level":0},
	"turret_range":      {"cost_sequence":[12,15,19,24,30,37,45,54,64,75], "max_level":0},
	"crit_chance":       {"cost_sequence":[20,25,30,38,48,60,75,95,120], "max_level":0},
	"crit_mult":         {"cost_sequence":[18,24,30,38,48,60,75,95,120], "max_level":0},
	"turret_multishot":  {"cost_sequence":[25,30,36,43,51,60,70,81,93,106], "max_level":0},

	# Base / utility
	"base_max_hp":       {"cost_sequence":[20,25,32,40,49,59,70,82,95,109], "max_level":0},
	"base_regen":        {"cost_sequence":[15,20,26,33,41,50,60,72,85,99],  "max_level":0},

	# Map expansions
	"board_add_left":    {"cost_sequence":[40,55,70,90,115,145], "max_level":0},
	"board_add_right":   {"cost_sequence":[40,55,70,90,115,145], "max_level":0},
	"board_push_back":   {"cost_sequence":[60,80,105,135,170,210], "max_level":0},
}

# ---------- Gameplay tuning ----------
@export var rate_mult_per_step: float = 0.95
@export var turret_base_fire_rate_default: float = 1.0
@export var turret_min_fire_interval_default: float = 0.05

@export var turret_base_acquire_range_default: float = 12.0
@export var turret_range_add_per_step: float = 2.0

@export var crit_chance_base: float = 0.0
@export var crit_chance_per_step: float = 0.02
@export var crit_chance_cap: float = 0.95

@export var crit_mult_base: float = 2.0
@export var crit_mult_per_step: float = 0.05
@export var crit_mult_cap: float = 4.0

@export var base_max_hp_default: int = 5
@export var hp_per_level_default: int = 10
@export var base_regen_per_sec_default: float = 0.0
@export var regen_per_level_default: float = 0.5

@export var multishot_base_percent: float = 0.0
@export var multishot_percent_per_step: float = 20.0

# ---------- STATE ----------
var _upgrades_state: Dictionary = {}   # per-run (minerals) levels

func _ready() -> void:
	# When shards change, bump our derived totals so HUD/game refresh.
	var shards := get_node_or_null("/root/Shards")
	if shards:
		if shards.has_signal("changed"):
			shards.changed.connect(func(_b:int): changed.emit())
		if shards.has_signal("meta_changed"):
			shards.meta_changed.connect(func(_id:String, _lvl:int): changed.emit())
	# small defer so dependents (HUD, Health, TileBoard) can bind first
	call_deferred("_emit_initial_changed")

func _emit_initial_changed() -> void:
	changed.emit()

# ---------- LEVEL QUERIES ----------
func upgrade_level(id: String) -> int:
	var e: Dictionary = _upgrades_state.get(id, {}) as Dictionary
	return (int(e.get("level", 0)) if not e.is_empty() else 0)

# *** meta comes from the Shards autoload now ***
func meta_level(id: String) -> int:
	var shards := get_node_or_null("/root/Shards")
	if shards and shards.has_method("get_meta_level"):
		return int(shards.get_meta_level(id))
	return 0

func total_level(id: String) -> int:
	return upgrade_level(id) + meta_level(id)

func begin_run() -> void:
	_upgrades_state.clear()
	changed.emit()

# ---------- SHOP (minerals / in-run) ----------
func upgrade_cost(id: String) -> int:
	var conf: Dictionary = upgrades_config.get(id, {}) as Dictionary
	if conf.is_empty(): return -1
	var lvl_run := upgrade_level(id)
	if conf.has("cost_sequence"):
		var seq: Array = conf.get("cost_sequence", []) as Array
		return _sequence_cost(seq, lvl_run)
	var base_cost := int(conf.get("base_cost", 0))
	var factor := float(conf.get("cost_factor", 1.0))
	var step := int(conf.get("cost_round_to", 1))
	return _round_to(float(base_cost) * pow(factor, float(lvl_run)), step)

func _sequence_cost(seq: Array, lvl_index: int) -> int:
	var n := seq.size()
	if n == 0: return -1
	if lvl_index < n: return int(seq[lvl_index])
	var cost := int(seq[n - 1])
	var inc := (int(seq[n - 1]) - int(seq[n - 2])) if n >= 2 else 5
	var extra := lvl_index - n + 1
	for _i in extra:
		inc += 1
		cost += inc
	return cost

func can_purchase(id: String) -> bool:
	var conf: Dictionary = upgrades_config.get(id, {}) as Dictionary
	if conf.is_empty(): return false
	var max_level := int(conf.get("max_level", 0))
	if max_level > 0 and upgrade_level(id) >= max_level: return false
	return balance() >= upgrade_cost(id)

func purchase(id: String) -> bool:
	var conf: Dictionary = upgrades_config.get(id, {}) as Dictionary
	if conf.is_empty(): return false
	var max_level := int(conf.get("max_level", 0))
	var lvl_run := upgrade_level(id)
	if max_level > 0 and lvl_run >= max_level: return false
	var cost := upgrade_cost(id)
	if cost < 0 or not _try_spend(cost, "upgrade:" + id): return false

	_upgrades_state[id] = {"level": lvl_run + 1}
	var next_cost := upgrade_cost(id)
	changed.emit()
	upgrade_purchased.emit(id, total_level(id), next_cost)
	return true

# ---------- SHARDS (meta) helpers ----------
# Panel calls shards directly, but these helpers let HUDs query.
func get_next_meta_offer(id: String) -> Dictionary:
	var shards := get_node_or_null("/root/Shards")
	if shards == null: return {"available": false}
	if not shards.has_method("get_meta_next_cost"): return {"available": false}
	var cost := int(shards.get_meta_next_cost(id))
	if cost < 0: return {"available": false}
	var next_value := _value_for(id, total_level(id) + 2)
	return {"available": true, "cost_shards": cost, "next_value": next_value}

func purchase_meta(id: String) -> bool:
	var shards := get_node_or_null("/root/Shards")
	if shards and shards.has_method("try_buy_meta"):
		var ok := bool(shards.try_buy_meta(id))
		if ok:
			changed.emit()
			upgrade_purchased.emit(id, total_level(id), upgrade_cost(id))
		return ok
	return false

# Called by the panel after a successful shards buy (safe no-op if unused).
func _apply_shards_meta() -> void:
	changed.emit()

# ---------- HUD HELPERS ----------
func get_next_run_offer(id: String) -> Dictionary:
	var next_value := _value_for(id, total_level(id) + 2)
	var cost := upgrade_cost(id)
	return {"available": cost >= 0, "next_value": next_value, "cost_minerals": cost}

# Attack speed (global)
func turret_rate_info(reference_turret: Node = null) -> Dictionary:
	var steps := total_level("turret_rate")
	var cost := upgrade_cost("turret_rate")

	var global_mult_now := pow(maxf(0.01, rate_mult_per_step), float(steps))
	var global_mult_next := global_mult_now * maxf(0.01, rate_mult_per_step)

	var base := turret_base_fire_rate_default
	var local_mult := 1.0
	var min_rate := turret_min_fire_interval_default
	var current_interval := 0.0

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
	var next_interval := clampf(base * local_mult * global_mult_next, min_rate, 999.0)

	var cur_sps := (0.0 if current_interval <= 0.0 else 1.0 / current_interval)
	return {
		"level_total": steps,
		"cost_minerals": cost,
		"current_interval": current_interval,
		"current_sps": cur_sps,
		"next_interval": next_interval,
		"available": cost >= 0
	}

func find_any_turret() -> Node:
	var ts := get_tree().get_nodes_in_group("turret")
	return (ts[0] if ts.size() > 0 else null)

# Range
func turret_range_bonus() -> float:
	return maxf(0.0, float(total_level("turret_range")) * turret_range_add_per_step)

func next_turret_range_bonus() -> float:
	return maxf(0.0, float(total_level("turret_range") + 1) * turret_range_add_per_step)

func turret_range_info(reference_turret: Node = null) -> Dictionary:
	var cost := upgrade_cost("turret_range")
	var base := turret_base_acquire_range_default
	var local_add := 0.0
	var current_range := 0.0

	if reference_turret != null:
		if reference_turret.has_method("get_base_acquire_range"):
			base = float(reference_turret.get_base_acquire_range())
		if reference_turret.has_method("get_range_per_level") and reference_turret.has_method("get_range_level"):
			local_add = float(reference_turret.get_range_per_level()) * float(reference_turret.get_range_level())
		if reference_turret.has_method("get_current_acquire_range"):
			current_range = float(reference_turret.get_current_acquire_range())

	if current_range <= 0.0:
		current_range = maxf(0.5, base + local_add + turret_range_bonus())
	var next_range := maxf(0.5, base + local_add + next_turret_range_bonus())

	return {"cost_minerals": cost, "current_range": current_range, "next_range": next_range}

# Health HUD helpers
func _get_health_node_if_any(passed: Node) -> Node:
	return (passed if passed != null else get_node_or_null("/root/Health"))

func health_max_info(health_node: Node = null) -> Dictionary:
	var cost: int = upgrade_cost("base_max_hp")

	var base_val: int = base_max_hp_default
	var per_step: int = hp_per_level_default

	var h: Node = _get_health_node_if_any(health_node)
	if h != null:
		if "base_max_hp" in h: base_val = int(h.base_max_hp)
		if "hp_per_level" in h: per_step = int(h.hp_per_level)

	var steps: int = total_level("base_max_hp")
	var current_max: int = maxi(1, base_val + per_step * steps)
	var next_max:   int = maxi(1, base_val + per_step * (steps + 1))

	return {
		"cost_minerals": cost,
		"current_max_hp": current_max,
		"next_max_hp": next_max,
		"available": cost >= 0
	}

func health_regen_info(health_node: Node = null) -> Dictionary:
	var cost := upgrade_cost("base_regen")
	var base_val := base_regen_per_sec_default
	var per_step := regen_per_level_default

	var h := _get_health_node_if_any(health_node)
	if h != null:
		if "base_regen_per_sec" in h: base_val = float(h.base_regen_per_sec)
		if "regen_per_level" in h:   per_step = float(h.regen_per_level)

	var steps := total_level("base_regen")
	var current_regen := base_val + per_step * float(steps)
	var next_regen := base_val + per_step * float(steps + 1)
	return {"cost_minerals": cost, "current_regen_per_sec": current_regen, "next_regen_per_sec": next_regen, "available": cost >= 0}

# Multi-shot
func multishot_percent_value() -> float:
	return maxf(0.0, multishot_base_percent + multishot_percent_per_step * float(total_level("turret_multishot")))

func next_multishot_percent_value() -> float:
	return maxf(0.0, multishot_base_percent + multishot_percent_per_step * float(total_level("turret_multishot") + 1))

# ---------- VALUE PATHS ----------
func _value_for(id: String, step: int) -> int:
	if step <= 0: return 0
	match id:
		"turret_damage":
			return _damage_formula(step)
		"base_max_hp":
			return max(1, base_max_hp_default + hp_per_level_default * (step - 1))
		"base_regen":
			return int(round((base_regen_per_sec_default + regen_per_level_default * float(step - 1)) * 100.0))
		_:
			return 0

# damage(n) = 3*n + max(0, floor((n - 4) * 2/3))
func _damage_formula(n: int) -> int:
	var t := n - 4
	var bonus := (int(floor(t * 2.0 / 3.0)) if t > 0 else 0)
	return 3 * n + max(0, bonus)

# public damage helpers
func turret_damage_value() -> int:
	return _value_for("turret_damage", total_level("turret_damage") + 1)

func next_turret_damage_value() -> int:
	return _value_for("turret_damage", total_level("turret_damage") + 2)

# attack speed multiplier from global levels
func turret_rate_mult() -> float:
	return pow(maxf(0.01, rate_mult_per_step), float(total_level("turret_rate")))

# crit values
func crit_chance_value() -> float:
	return clampf(crit_chance_base + crit_chance_per_step * float(total_level("crit_chance")), 0.0, crit_chance_cap)

func next_crit_chance_value() -> float:
	return clampf(crit_chance_base + crit_chance_per_step * float(total_level("crit_chance") + 1), 0.0, crit_chance_cap)

func crit_mult_value() -> float:
	return clampf(crit_mult_base + crit_mult_per_step * float(total_level("crit_mult")), 1.0, crit_mult_cap)

func next_crit_mult_value() -> float:
	return clampf(crit_mult_base + crit_mult_per_step * float(total_level("crit_mult") + 1), 1.0, crit_mult_cap)

# ---------- Compatibility / hooks ----------
func turret_damage_bonus() -> int: return turret_damage_value()
func turret_damage_multiplier() -> float: return 1.0
func damage_multiplier(kind: String = "") -> float: return 1.0
func modified_cost(action: String, base: int) -> int: return base

# ---------- Utils ----------
func _round_to(value: float, step: int) -> int:
	if step <= 1: return int(round(value))
	return int(round(value / float(step))) * step
