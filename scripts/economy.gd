extends Node

signal balance_changed(new_balance: int)
signal added(amount: int, source: String)
signal spent(amount: int, reason: String)

var _balance: int = 0
var _ready_called: bool = false

# --- optional state for bounty when no base kill reward is used ---
var _bounty_kill_counter: int = 0

func setup(starting: int = 50) -> void:
	_balance = max(0, starting)
	_ready_called = true
	balance_changed.emit(_balance)

func balance() -> int:
	return _balance

func can_afford(cost: int) -> bool:
	return cost <= _balance

func try_spend(cost: int, reason: String = "") -> bool:
	if cost <= 0:
		return true
	if _balance >= cost:
		_balance -= cost
		spent.emit(cost, reason)
		balance_changed.emit(_balance)
		return true
	return false

func add(amount: int, source: String = "") -> void:
	if amount == 0:
		return
	_balance += amount
	added.emit(amount, source)
	balance_changed.emit(_balance)

# ================= PowerUps helpers =================
func _pu() -> Node:
	return get_node_or_null("/root/PowerUps")

func _pu_level(id: String) -> int:
	var pu := _pu()
	if pu == null: return 0
	if pu.has_method("level"): return int(pu.call("level", id))
	if pu.has_method("meta_level"): return int(pu.call("meta_level", id))
	if pu.has_method("get_level"): return int(pu.call("get_level", id))
	return 0

# ================= Economy upgrade values =================
func stipend_amount() -> int:
	match _pu_level("eco_wave_stipend"):
		1: return 10
		2: return 15
		3: return 20
		4: return 25
		_: return 0

func perfect_bonus_amount() -> int:
	match _pu_level("eco_perfect_bonus"):
		1: return 15
		2: return 25
		3: return 40
		_: return 0

func bounty_percent() -> float:
	match _pu_level("eco_bounty"):
		1: return 0.10
		2: return 0.15
		3: return 0.20
		_: return 0.0

# ================= Hooks you call from your wave/enemy code =================
func on_wave_start() -> void:
	var s := stipend_amount()
	if s > 0:
		add(s, "wave_stipend")

func on_wave_end(no_leaks: bool) -> void:
	if no_leaks:
		var b := perfect_bonus_amount()
		if b > 0:
			add(b, "perfect_bonus")

# If your enemy already yields a base mineral reward, pass it in (we’ll add %).
# If not, leave base_reward = 0 and we’ll pay small flats every few kills.
func on_enemy_killed(base_reward: int = 0) -> void:
	var pct := bounty_percent()
	if pct > 0.0 and base_reward > 0:
		var bonus := int(round(float(base_reward) * pct))
		if bonus > 0:
			add(bonus, "bounty_pct")
		return

	# Fallback: no base kill reward. Pay small flats based on kill count stride.
	var lvl := _pu_level("eco_bounty")
	if lvl <= 0:
		return
	_bounty_kill_counter += 1
	var stride := (5 if lvl == 1 else 3 if lvl == 2 else 2)
	if _bounty_kill_counter >= stride:
		var batches := int(_bounty_kill_counter / stride)
		_bounty_kill_counter -= batches * stride
		add(batches, "bounty_flat")
