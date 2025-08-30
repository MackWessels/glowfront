extends Node

signal changed(new_balance: int)
signal meta_changed(id: String, new_level: int)

const SAVE_PATH := "user://shards.cfg"
const CFG_SECTION := "meta"

var _balance: int = 50000
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.randomize()
	_load_balance()
	_load_meta_levels()

func get_balance() -> int: return _balance

func add(amount: int, reason: String = "") -> void:
	if amount <= 0: return
	_balance += amount
	_save_balance()
	changed.emit(_balance)

func try_spend(amount: int, reason: String = "") -> bool:
	if amount <= 0: return true
	if _balance < amount: return false
	_balance -= amount
	_save_balance()
	changed.emit(_balance)
	return true

# optional in-run drops
var normal_drop_chance: float = 0.03
var normal_drop_amount: int = 1
var elite_drop_amount: int = 5
func award_for_enemy(is_elite: bool, normal_chance_override: float = -1.0, amount_override: int = 0) -> int:
	var gained := 0
	if is_elite:
		gained = (amount_override if amount_override > 0 else elite_drop_amount)
	else:
		var chance := (normal_chance_override if normal_chance_override >= 0.0 else normal_drop_chance)
		if _rng.randf() < chance:
			gained = (amount_override if amount_override > 0 else normal_drop_amount)
	if gained > 0: add(gained, "enemy_drop")
	return gained

# ---------------- META DEFINITIONS ----------------
# Removed "spawner_health"
const META_DEFS := {
	# Offense
	"turret_damage":    {"label":"Damage",       "tab":"Offense", "costs":[30, 55, 88, 128, 177], "max":0},
	"turret_rate":      {"label":"Attack Speed", "tab":"Offense", "costs":[30, 55, 88, 128, 177], "max":0},
	"turret_range":     {"label":"Range",        "tab":"Offense", "costs":[25, 45, 72, 106, 147], "max":0},
	"crit_chance":      {"label":"Crit Chance",  "tab":"Offense", "costs":[25, 45, 72, 106, 147], "max":0},
	"crit_mult":        {"label":"Crit Damage",  "tab":"Offense", "costs":[25, 45, 72, 106, 147], "max":0},
	"turret_multishot": {"label":"Multi-Shot",   "tab":"Offense", "costs":[40, 65, 95, 130, 170], "max":0},

	# Defense
	"base_max_hp":      {"label":"Max Health",   "tab":"Defense", "costs":[25, 45, 72, 106, 147], "max":0},
	"base_regen":       {"label":"Health Regen", "tab":"Defense", "costs":[25, 45, 72, 106, 147], "max":0},

	# Map
	"board_add_left":   {"label":"Board Add Right", "tab":"Map", "costs":[60, 100, 150], "max":0},
	"board_add_right":  {"label":"Board Add Left",  "tab":"Map", "costs":[60, 100, 150], "max":0},
	"board_push_back":  {"label":"Board Push Back", "tab":"Map", "costs":[80, 120, 180], "max":0},
}

func get_meta_defs() -> Dictionary: return META_DEFS

const META_SAVE_PATH := "user://shards_meta.cfg"
var _meta_levels: Dictionary = {}  # id -> int

func get_meta_level(id: String) -> int: return int(_meta_levels.get(id, 0))

func get_meta_next_cost(id: String) -> int:
	if not META_DEFS.has(id): return -1
	var def: Dictionary = META_DEFS[id]
	var lvl: int = get_meta_level(id)
	var max: int = int(def.get("max", 0))
	if max > 0 and lvl >= max: return -1
	var costs: Array = def.get("costs", []) as Array
	if lvl < costs.size(): return int(costs[lvl])
	var last_cost: int = int(costs.back() if costs.size() > 0 else 50)
	return int(round(float(last_cost) * 1.33))

func try_buy_meta(id: String) -> bool:
	var cost := get_meta_next_cost(id)
	if cost < 0: return false
	if not try_spend(cost, "meta_upgrade:" + id): return false
	_meta_levels[id] = get_meta_level(id) + 1
	_save_meta_levels()
	meta_changed.emit(id, _meta_levels[id])
	return true

# -------- persistence
func _load_balance() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(SAVE_PATH)
	_balance = (int(cfg.get_value(CFG_SECTION, "shards", 0)) if err == OK else 0)

func _save_balance() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value(CFG_SECTION, "shards", _balance)
	cfg.save(SAVE_PATH)

func _load_meta_levels() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(META_SAVE_PATH) == OK:
		for id in META_DEFS.keys():
			_meta_levels[id] = int(cfg.get_value("meta", id, 0))
	else:
		_meta_levels.clear()

func _save_meta_levels() -> void:
	var cfg := ConfigFile.new()
	for id in META_DEFS.keys():
		cfg.set_value("meta", id, get_meta_level(id))
	cfg.save(META_SAVE_PATH)

# testing
func reset_for_testing(to: int = 0) -> void:
	_balance = max(0, to); _save_balance(); changed.emit(_balance)
func reset_meta_for_testing() -> void:
	_meta_levels.clear(); _save_meta_levels(); meta_changed.emit("", 0)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_save_balance(); _save_meta_levels()
