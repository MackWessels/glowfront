extends Node
signal changed(current: int, max: int)
signal defeated()

@export var debug_prints: bool = true

@export var base_max_hp: int = 500
@export var hp_per_level: int = 10         
@export var base_regen_per_sec: float = 0.0
@export var regen_per_level: float = 0.5   

var max_hp: int
var hp: float
var _regen: float

func _ready() -> void:
	_recompute_from_powerups()
	reset()
	set_process(true)
	_try_connect_powerups()
	_log("ready   -> hp=%d/%d regen=%.2f" % [int(ceil(hp)), max_hp, _regen])

func reset() -> void:
	hp = float(max_hp)
	emit_signal("changed", int(ceil(hp)), max_hp)
	_log("reset   -> hp=%d/%d" % [int(ceil(hp)), max_hp])

func damage(amount: int, reason: String = "") -> void:
	if amount <= 0 or hp <= 0.0: return
	var before := int(ceil(hp))
	hp = max(0.0, hp - float(amount))
	var after := int(ceil(hp))
	emit_signal("changed", after, max_hp)
	_log("damage  -> -%d (%s)  %d → %d / %d" % [amount, reason, before, after, max_hp])
	if hp <= 0.0:
		_log("defeat!")
		emit_signal("defeated")

func heal(amount: int) -> void:
	if amount <= 0 or hp <= 0.0: return
	var before := int(ceil(hp))
	hp = min(float(max_hp), hp + float(amount))
	var after := int(ceil(hp))
	emit_signal("changed", after, max_hp)
	_log("heal    -> +%d       %d → %d / %d" % [amount, before, after, max_hp])

func _process(delta: float) -> void:
	if _regen > 0.0 and hp > 0.0 and hp < float(max_hp):
		var before := int(ceil(hp))
		hp = min(float(max_hp), hp + _regen * delta)
		var after := int(ceil(hp))
		if after != before:
			emit_signal("changed", after, max_hp)
			_log("regen   -> +%.2f/s  %d → %d / %d" % [_regen, before, after, max_hp])

# PowerUps 
func _try_connect_powerups() -> void:
	if Engine.has_singleton("PowerUps") and PowerUps.has_signal("changed"):
		PowerUps.changed.connect(_on_powerups_changed)

func _on_powerups_changed() -> void:
	var old_max := max_hp
	var old_regen := _regen
	_recompute_from_powerups()
	if max_hp != old_max and hp > float(max_hp):
		hp = float(max_hp)
	emit_signal("changed", int(ceil(hp)), max_hp)
	_log("powerup -> max %d→%d regen %.2f→%.2f hp now %d/%d"
		% [old_max, max_hp, old_regen, _regen, int(ceil(hp)), max_hp])

func _lvl(id: String) -> int:
	if not Engine.has_singleton("PowerUps"): return 0
	if PowerUps.has_method("level"):
		return int(PowerUps.call("level", id))
	if PowerUps.has_method("get_level"):
		return int(PowerUps.call("get_level", id))
	if PowerUps.has_method("level_of"):
		return int(PowerUps.call("level_of", id))
	return 0

func _recompute_from_powerups() -> void:
	var hp_lvl := _lvl("base_max_hp")
	var regen_lvl := _lvl("base_regen")
	max_hp = max(1, base_max_hp + hp_lvl * hp_per_level)
	_regen = base_regen_per_sec + regen_lvl * regen_per_level

func _log(msg: String) -> void:
	if debug_prints:
		print("[Health] ", msg)
