extends Node

signal changed()
signal upgrade_purchased(id: String, new_level: int, next_cost: int)

# =========================================================
# Debug
# =========================================================
@export var debug_economy: bool = false

# =========================================================
# Minerals / run currency (wrappers around Economy autoload)
# =========================================================
func balance() -> int:
	if typeof(Economy) != TYPE_NIL and Economy.has_method("balance"):
		return int(Economy.balance())
	var v: Variant = Economy.get("minerals")
	return (int(v) if typeof(v) == TYPE_INT else 0)

func _try_spend(cost: int, reason: String = "") -> bool:
	if cost <= 0:
		return true
	if typeof(Economy) != TYPE_NIL:
		if Economy.has_method("try_spend"):
			return bool(Economy.try_spend(cost, reason))
		if Economy.has_method("spend"):
			return bool(Economy.spend(cost))
		if Economy.has_method("set_amount"):
			var b: int = balance()
			if b < cost:
				return false
			Economy.set_amount(b - cost)
			return true
	return balance() >= cost

# =========================================================
# CONFIG (per-run mineral upgrades)
# =========================================================
@export var upgrades_config: Dictionary = {
	# ---------- Offense ----------
	"turret_damage":     {"cost_sequence":[10,12,14,17,20,24,29,35], "max_level":0},
	"turret_rate":       {"cost_sequence":[15,18,22,27,33,40,48,57,67,78], "max_level":0},
	"turret_range":      {"cost_sequence":[12,15,19,24,30,37,45,54,64,75], "max_level":0},
	"crit_chance":       {"cost_sequence":[20,25,30,38,48,60,75,95,120], "max_level":0},
	"crit_mult":         {"cost_sequence":[18,24,30,38,48,60,75,95,120], "max_level":0},
	"turret_multishot":  {"cost_sequence":[25,30,36,43,51,60,70,81,93,106], "max_level":0},

	# --- Chain Lightning ---
	"chain_lightning_chance": {"cost_sequence":[20,25,30,38,48,60,75,95,120], "max_level":0},
	"chain_lightning_damage": {"cost_sequence":[15,20,26,33,41,50,60,72,85,99], "max_level":0},
	"chain_lightning_jumps":  {"cost_sequence":[18,24,30,38,48,60,75,95,120], "max_level":0},

	# ---------- Base / utility ----------
	"base_max_hp":       {"cost_sequence":[20,25,32,40,49,59,70,82,95,109], "max_level":0},
	"base_regen":        {"cost_sequence":[15,20,26,33,41,50,60,72,85,99],  "max_level":0},

	# ---------- Map expansions ----------
	"board_add_left":    {"cost_sequence":[40,55,70,90,115,145], "max_level":0},
	"board_add_right":   {"cost_sequence":[40,55,70,90,115,145], "max_level":0},
	"board_push_back":   {"cost_sequence":[60,80,105,135,170,210], "max_level":0},

	# =====================================================
	# ECONOMY TAB (new)
	# =====================================================
	# Miner: +yield per tick
	"miner_yield":  {"cost_sequence":[15,25,40,60,85], "max_level":3},
	# Miner: faster tick interval (global scale)
	"miner_speed":  {"cost_sequence":[18,30,48,75,115], "max_level":3},

	# Bounty: +% minerals on kill (supports fractional carry)
	"eco_bounty":        {"cost_sequence":[20,30,45,65,90,120,155], "max_level":0},
	# Stipend: flat minerals at the start of every wave
	"eco_wave_stipend":  {"cost_sequence":[15,25,40,60,90,130], "max_level":0},
	# Perfect: extra % minerals at end of wave if no leaks
	"eco_perfect":       {"cost_sequence":[25,35,50,70,95,125], "max_level":0},
}

# =========================================================
# Gameplay tuning (unchanged values you already had)
# =========================================================
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

# --- Chain lightning tuning (global) ---
@export var chain_chance_base: float = 0.0          # 0..1
@export var chain_chance_per_step: float = 0.05     # +5% per level
@export var chain_chance_cap: float = 1.0

@export var chain_damage_base_percent: float = 5.0  # starts at 5% of the triggering hit's final damage
@export var chain_damage_percent_per_step: float = 5.0
@export var chain_damage_cap_percent: float = 200.0

@export var chain_jumps_base: int = 1
@export var chain_jumps_per_step: int = 1
@export var chain_radius_default: float = 5.0

# =========================================================
# STATE (per-run levels)
# =========================================================
var _upgrades_state: Dictionary = {}   # id -> {"level":int}

# --- Economy runtime state ---
var _bounty_carry: float = 0.0

func _ready() -> void:
	# Hook shards to refresh totals
	var shards: Node = get_node_or_null("/root/Shards")
	if shards:
		if shards.has_signal("changed"):
			shards.changed.connect(func(_b:int): changed.emit())
		if shards.has_signal("meta_changed"):
			shards.meta_changed.connect(func(_id:String, _lvl:int): changed.emit())
	call_deferred("_emit_initial_changed")

func _emit_initial_changed() -> void:
	changed.emit()

# =========================================================
# LEVEL QUERIES
# =========================================================
func upgrade_level(id: String) -> int:
	var e: Dictionary = _upgrades_state.get(id, {}) as Dictionary
	return (int(e.get("level", 0)) if not e.is_empty() else 0)

func meta_level(id: String) -> int:
	var shards: Node = get_node_or_null("/root/Shards")
	if shards and shards.has_method("get_meta_level"):
		return int(shards.get_meta_level(id))
	return 0

func total_level(id: String) -> int:
	return upgrade_level(id) + meta_level(id)

# Friendly alias used by Miner etc.
func level(id: String) -> int:
	return total_level(id)

func begin_run() -> void:
	_upgrades_state.clear()
	_bounty_carry = 0.0
	changed.emit()

# =========================================================
# SHOP (minerals / in-run)
# =========================================================
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
	return _round_to(float(base_cost) * pow(factor, float(lvl_run)), step)

func _sequence_cost(seq: Array, lvl_index: int) -> int:
	var n: int = seq.size()
	if n == 0:
		return -1
	if lvl_index < n:
		return int(seq[lvl_index])
	var cost: int = int(seq[n - 1])
	var inc: int = (int(seq[n - 1]) - int(seq[n - 2])) if n >= 2 else 5
	var extra: int = lvl_index - n + 1
	for _i in extra:
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
	if cost < 0 or not _try_spend(cost, "upgrade:" + id):
		return false

	_upgrades_state[id] = {"level": lvl_run + 1}
	var next_cost: int = upgrade_cost(id)
	changed.emit()
	upgrade_purchased.emit(id, total_level(id), next_cost)
	return true

# =========================================================
# SHARDS helpers (unchanged)
# =========================================================
func get_next_meta_offer(id: String) -> Dictionary:
	var shards: Node = get_node_or_null("/root/Shards")
	if shards == null:
		return {"available": false}
	if not shards.has_method("get_meta_next_cost"):
		return {"available": false}
	var cost: int = int(shards.get_meta_next_cost(id))
	if cost < 0:
		return {"available": false}
	var next_value: int = _value_for(id, total_level(id) + 2)
	return {"available": true, "cost_shards": cost, "next_value": next_value}

func purchase_meta(id: String) -> bool:
	var shards: Node = get_node_or_null("/root/Shards")
	if shards and shards.has_method("try_buy_meta"):
		var ok: bool = bool(shards.try_buy_meta(id))
		if ok:
			changed.emit()
			upgrade_purchased.emit(id, total_level(id), upgrade_cost(id))
		return ok
	return false

func _apply_shards_meta() -> void:
	changed.emit()

# ===== Economy value getters (used by the HUD) =====

# --- Wave Stipend ($ per wave) ---
func _stipend_for_level(l: int) -> int:
	match l:
		0: return 0
		1: return 3     # tune as you like
		2: return 5
		_: return 8

func eco_wave_stipend_value() -> int:
	return _stipend_for_level(total_level("eco_wave_stipend"))

func next_eco_wave_stipend_value() -> int:
	return _stipend_for_level(total_level("eco_wave_stipend") + 1)


func _perfect_pct_for_level(l: int) -> float:
	match l:
		0: return 0.0
		1: return 0.50   # 50% at Lv1
		2: return 0.75   # 75% at Lv2
		_: return 1.00   # 100% at Lv3+

func eco_perfect_bonus_pct_value() -> float:
	return _perfect_pct_for_level(total_level("eco_perfect_bonus"))

func next_eco_perfect_bonus_pct_value() -> float:
	return _perfect_pct_for_level(total_level("eco_perfect_bonus") + 1)

func _bounty_pct_for_level(l: int) -> float:
	return 0.05 * float(max(0, l))

func eco_bounty_bonus_pct_value() -> float:
	return _bounty_pct_for_level(total_level("eco_bounty_bonus"))

func next_eco_bounty_bonus_pct_value() -> float:
	return _bounty_pct_for_level(total_level("eco_bounty_bonus") + 1)

# --- Miner upgrades (already working in your HUD, shown for completeness) ---
func miner_yield_bonus_value() -> int:
	return total_level("miner_yield")  # +1/tick per level (tune if needed)

func next_miner_yield_bonus_value() -> int:
	return total_level("miner_yield") + 1

# Interval scale: ×0.92, ×0.88, ×0.82…
func miner_speed_scale_value() -> float:
	match total_level("miner_speed"):
		0: return 1.00
		1: return 0.92
		2: return 0.88
		_: return 0.82

func next_miner_speed_scale_value() -> float:
	match total_level("miner_speed") + 1:
		0: return 1.00
		1: return 0.92
		2: return 0.88
		_: return 0.82


# =========================================================
# HUD helpers (unchanged public surface)
# =========================================================
func get_next_run_offer(id: String) -> Dictionary:
	var next_value: int = _value_for(id, total_level(id) + 2)
	var cost: int = upgrade_cost(id)
	return {"available": cost >= 0, "next_value": next_value, "cost_minerals": cost}

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

	var cur_sps: float = (0.0 if current_interval <= 0.0 else 1.0 / current_interval)
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
	return (ts[0] if ts.size() > 0 else null)

func turret_range_bonus() -> float:
	return maxf(0.0, float(total_level("turret_range")) * turret_range_add_per_step)

func next_turret_range_bonus() -> float:
	return maxf(0.0, float(total_level("turret_range") + 1) * turret_range_add_per_step)

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

	return {"cost_minerals": cost, "current_range": current_range, "next_range": next_range}

func _get_health_node_if_any(passed: Node) -> Node:
	return (passed if passed != null else get_node_or_null("/root/Health"))

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
	var current_max: int = maxi(1, base_val + per_step * steps)
	var next_max: int = maxi(1, base_val + per_step * (steps + 1))

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
	return {"cost_minerals": cost, "current_regen_per_sec": current_regen, "next_regen_per_sec": next_regen, "available": cost >= 0}

func multishot_percent_value() -> float:
	return maxf(0.0, multishot_base_percent + multishot_percent_per_step * float(total_level("turret_multishot")))

func next_multishot_percent_value() -> float:
	return maxf(0.0, multishot_base_percent + multishot_percent_per_step * float(total_level("turret_multishot") + 1))

# ---------- VALUE PATHS & damage ----------
func _value_for(id: String, step: int) -> int:
	if step <= 0:
		return 0
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
	var t: int = n - 4
	var bonus: int = (int(floor(t * 2.0 / 3.0)) if t > 0 else 0)
	return 3 * n + max(0, bonus)

func turret_damage_value() -> int:
	return _value_for("turret_damage", total_level("turret_damage") + 1)

func next_turret_damage_value() -> int:
	return _value_for("turret_damage", total_level("turret_damage") + 2)

func turret_rate_mult() -> float:
	return pow(maxf(0.01, rate_mult_per_step), float(total_level("turret_rate")))

func crit_chance_value() -> float:
	return clampf(crit_chance_base + crit_chance_per_step * float(total_level("crit_chance")), 0.0, crit_chance_cap)

func next_crit_chance_value() -> float:
	return clampf(crit_chance_base + crit_chance_per_step * float(total_level("crit_chance") + 1), 0.0, crit_chance_cap)

func crit_mult_value() -> float:
	return clampf(crit_mult_base + crit_mult_per_step * float(total_level("crit_mult")), 1.0, crit_mult_cap)

func next_crit_mult_value() -> float:
	return clampf(crit_mult_base + crit_mult_per_step * float(total_level("crit_mult") + 1), 1.0, crit_mult_cap)

# ---------- Chain lightning getters ----------
func chain_chance_value() -> float:
	return clampf(chain_chance_base + chain_chance_per_step * float(total_level("chain_lightning_chance")), 0.0, chain_chance_cap)

func next_chain_chance_value() -> float:
	return clampf(chain_chance_base + chain_chance_per_step * float(total_level("chain_lightning_chance") + 1), 0.0, chain_chance_cap)

func chain_damage_percent_value() -> float:
	return clampf(chain_damage_base_percent + chain_damage_percent_per_step * float(total_level("chain_lightning_damage")), 0.0, chain_damage_cap_percent)

func next_chain_damage_percent_value() -> float:
	return clampf(chain_damage_base_percent + chain_damage_percent_per_step * float(total_level("chain_lightning_damage") + 1), 0.0, chain_damage_cap_percent)

func chain_jumps_value() -> int:
	return max(0, chain_jumps_base + chain_jumps_per_step * total_level("chain_lightning_jumps"))

func next_chain_jumps_value() -> int:
	return max(0, chain_jumps_base + chain_jumps_per_step * (total_level("chain_lightning_jumps") + 1))

func chain_radius_value() -> float:
	return maxf(0.1, chain_radius_default)

# ---------- Compatibility / hooks ----------
func turret_damage_bonus() -> int: return turret_damage_value()
func turret_damage_multiplier() -> float: return 1.0
func damage_multiplier(kind: String = "") -> float: return 1.0
func modified_cost(action: String, base: int) -> int: return base

# =========================================================
# ECONOMY RUNTIME HELPERS (NEW)
# =========================================================

# --- Bounty ---
# Each level adds +15% bounty. Tweak if desired.
func bounty_multiplier() -> float:
	var lvl: int = total_level("eco_bounty")
	return 1.0 + 0.15 * float(lvl)

# Award bounty for a single enemy kill.
# Returns {"payout":int,"carry":float,"total":float,"mult":float}
func award_bounty(base_amount: int, source: String = "kill") -> Dictionary:
	var mult: float = bounty_multiplier()
	var total_f: float = float(base_amount) * mult
	var carry_in: float = _bounty_carry
	total_f += carry_in

	var payout: int = int(floor(total_f))
	var bounty_carry: float = total_f - float(payout)

	if debug_economy:
		var bal_before: int = -1
		if typeof(Economy) != TYPE_NIL and Economy.has_method("balance"):
			bal_before = int(Economy.balance())
		print("[Bounty] base=", base_amount,
			"  mult=", String.num(mult, 3),
			"  carry_in=", String.num(carry_in, 3),
			"  total=", String.num(total_f, 3),
			"  -> payout=", payout,
			"  carry_out=", String.num(bounty_carry, 3))
		if bal_before >= 0:
			print("    bal_before=", str(bal_before))

	if payout > 0:
		if typeof(Economy) != TYPE_NIL and Economy.has_method("earn"):
			Economy.earn(payout)
		elif typeof(Economy) != TYPE_NIL and Economy.has_method("add"):
			Economy.add(payout)

	_bounty_carry = bounty_carry

	return {
		"payout": payout,
		"carry": bounty_carry,
		"total": total_f,
		"mult": mult
	}

# --- Wave stipend ---
# Simple model: stipend = 2 * level minerals at the start of EVERY wave.
func stipend_value_per_wave() -> int:
	var lvl: int = total_level("eco_wave_stipend")
	return max(0, 2 * lvl)

func award_wave_stipend(wave_index: int) -> int:
	var amt: int = stipend_value_per_wave()
	if amt <= 0:
		return 0
	if debug_economy:
		print("[Stipend] wave=", wave_index, "  amount=", amt)
	if typeof(Economy) != TYPE_NIL and Economy.has_method("earn"):
		Economy.earn(amt)
	elif typeof(Economy) != TYPE_NIL and Economy.has_method("add"):
		Economy.add(amt)
	return amt

# --- Perfect wave bonus ---
# Each level adds +25% bonus on the wave's mineral payout if there were ZERO leaks.
func perfect_bonus_multiplier() -> float:
	var lvl: int = total_level("eco_perfect")
	return 1.0 + 0.25 * float(lvl)

# Apply perfect bonus to a known base wave payout (integer),
# return the extra minerals granted.
func award_perfect_bonus(base_wave_payout: int, source: String = "perfect_wave") -> int:
	var mult: float = perfect_bonus_multiplier()
	if mult <= 1.0 or base_wave_payout <= 0:
		return 0
	var extra_f: float = float(base_wave_payout) * (mult - 1.0)
	var extra: int = int(floor(extra_f))
	if extra <= 0:
		return 0
	if debug_economy:
		print("[Perfect] base_wave=", base_wave_payout,
			"  mult=", String.num(mult, 3),
			"  extra=", extra)
	if typeof(Economy) != TYPE_NIL and Economy.has_method("earn"):
		Economy.earn(extra)
	elif typeof(Economy) != TYPE_NIL and Economy.has_method("add"):
		Economy.add(extra)
	return extra

# =========================================================
# Utils
# =========================================================
func _round_to(value: float, step: int) -> int:
	if step <= 1:
		return int(round(value))
	return int(round(value / float(step))) * step

# id -> int (how many of this upgrade are currently *applied* to the board)
var _applied_override: Dictionary = {}

func set_applied_override(id: String, value: int) -> void:
	_applied_override[id] = max(0, value)

func set_applied_override_map(m: Dictionary) -> void:
	for k in m.keys():
		_applied_override[String(k)] = int(m[k])

func applied_for(id: String) -> int:
	if _applied_override.has(id):
		return int(_applied_override[id])

	if typeof(Shards) != TYPE_NIL and Shards.has_method("get_meta_applied"):
		return int(Shards.get_meta_applied(id))

	if typeof(Shards) != TYPE_NIL and Shards.has_method("get_meta_level"):
		return int(Shards.get_meta_level(id))

	return 0
