extends Node

signal changed(new_balance: int)

const SAVE_PATH := "user://shards.cfg"
const CFG_SECTION := "meta"

var normal_drop_chance: float = 0.03      # 3% chance from normal enemies
var normal_drop_amount: int = 1
var elite_drop_amount: int = 5

var _balance: int = 0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.randomize()
	_load()

func get_balance() -> int:
	return _balance

func add(amount: int, reason: String = "") -> void:
	if amount <= 0:
		return
	_balance += amount
	emit_signal("changed", _balance)
	_save()

func try_spend(amount: int, reason: String = "") -> bool:
	if amount <= 0: # free
		return true
	if _balance < amount:
		return false
	_balance -= amount
	emit_signal("changed", _balance)
	_save()
	return true


func award_for_enemy(is_elite: bool, normal_chance_override: float = -1.0, amount_override: int = 0) -> int:
	var gained := 0
	if is_elite:
		gained = (amount_override if amount_override > 0 else elite_drop_amount)
	else:
		var chance := (normal_chance_override if normal_chance_override >= 0.0 else normal_drop_chance)
		if _rng.randf() < chance:
			gained = (amount_override if amount_override > 0 else normal_drop_amount)

	if gained > 0:
		add(gained, "enemy_drop")
	return gained

# ---- persistence ----
func _load() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(SAVE_PATH)
	if err == OK:
		_balance = int(cfg.get_value(CFG_SECTION, "shards", 0))
	else:
		_balance = 0

func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value(CFG_SECTION, "shards", _balance)
	var _err := cfg.save(SAVE_PATH)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_save()
