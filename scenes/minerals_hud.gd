extends CanvasLayer


@export var value_label_path: NodePath = ^"HBoxContainer/ValueLabel"
@export var upgrades_block_path: NodePath = ^"UpgradeBlock"         # VBoxContainer
@export var upgrades_label_path: NodePath = ^"UpgradeBlock/PowerLabel"
@export var upgrades_button_path: NodePath = ^"UpgradeBlock/BuyButton"
@export var economy_path: NodePath
@export var powerups_path: NodePath
@export var prefix_text: String = "Minerals: "
@export var show_upgrades: bool = true
@export var econ_debug: bool = false

var _label: Label                       # minerals label
var _up_label: Label = null             # "Upgrade: Turret Damage …"
var _buy_btn: Button = null             # Buy button
var _block: VBoxContainer = null        # vertical block under minerals
var _econ: Node = null
var _pu: Node = null
var _tween: Tween

func _ready() -> void:
	_label = get_node_or_null(value_label_path)
	if _label == null:
		push_error("[MineralsHUD] ValueLabel not found. Set value_label_path.")
		return

	_resolve_economy()
	_resolve_powerups()
	_bind_signals()

	if show_upgrades:
		_setup_upgrade_block()

	_refresh_text(_get_balance())
	_refresh_upgrades()

# ---------- resolve / signals ----------

func _resolve_economy() -> void:
	if economy_path != NodePath(""):
		_econ = get_node_or_null(economy_path)
	if _econ == null:
		_econ = get_node_or_null("/root/Economy")
	if _econ == null:
		_econ = get_node_or_null("/root/Minerals")
	if econ_debug and _econ:
		print("[MineralsHUD] Economy resolved -> ", _econ.name)

func _resolve_powerups() -> void:
	if powerups_path != NodePath(""):
		_pu = get_node_or_null(powerups_path)
	if _pu == null:
		_pu = get_node_or_null("/root/PowerUps")

func _bind_signals() -> void:
	if _econ and _econ.has_signal("balance_changed") and not _econ.is_connected("balance_changed", Callable(self, "_on_balance_changed")):
		_econ.connect("balance_changed", Callable(self, "_on_balance_changed"))
	if _econ and _econ.has_signal("added") and not _econ.is_connected("added", Callable(self, "_on_added")):
		_econ.connect("added", Callable(self, "_on_added"))
	if _econ and _econ.has_signal("spent") and not _econ.is_connected("spent", Callable(self, "_on_spent")):
		_econ.connect("spent", Callable(self, "_on_spent"))

	if _pu:
		if _pu.has_signal("changed") and not _pu.is_connected("changed", Callable(self, "_refresh_upgrades")):
			_pu.connect("changed", Callable(self, "_refresh_upgrades"))
		if _pu.has_signal("upgrade_purchased") and not _pu.is_connected("upgrade_purchased", Callable(self, "_on_upgrade")):
			_pu.connect("upgrade_purchased", Callable(self, "_on_upgrade"))

# ---------- layout: vertical block (label on 1st line, button on 2nd) ----------

func _setup_upgrade_block() -> void:
	_block = get_node_or_null(upgrades_block_path) as VBoxContainer
	_up_label = get_node_or_null(upgrades_label_path) as Label
	_buy_btn = get_node_or_null(upgrades_button_path) as Button

	if _block == null:
		_block = VBoxContainer.new()
		_block.name = "UpgradeBlock"

		# Place the block right under the HBoxContainer that holds the minerals label
		var container := _label.get_parent() as Control
		if container:
			_block.position = Vector2(container.position.x, container.position.y + container.size.y + 6)
		else:
			_block.position = Vector2(12, 28)

		add_child(_block)

	if _up_label == null:
		_up_label = Label.new()
		_up_label.name = "PowerLabel"
		_block.add_child(_up_label)

	if _buy_btn == null:
		_buy_btn = Button.new()
		_buy_btn.name = "BuyButton"
		_buy_btn.text = "Buy"
		_buy_btn.focus_mode = Control.FOCUS_NONE
		_block.add_child(_buy_btn)
		_buy_btn.pressed.connect(_on_buy_pressed)

# ---------- minerals ----------

func _get_balance() -> int:
	if _econ == null:
		return 0
	if _econ.has_method("balance"):
		return int(_econ.call("balance"))
	var v: Variant = _econ.get("minerals")
	return int(v) if typeof(v) == TYPE_INT else 0

func _refresh_text(bal: int) -> void:
	if _label:
		_label.text = "%s%d" % [prefix_text, bal]

func _on_balance_changed(new_balance: int) -> void:
	_refresh_text(new_balance)
	_refresh_upgrades()  # update affordability state

func _pulse(scale_to: float, duration: float = 0.15) -> void:
	if _label == null:
		return
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_label, "scale", Vector2(scale_to, scale_to), duration)
	_tween.tween_property(_label, "scale", Vector2.ONE, duration)

func _on_added(_amount: int, _source: String) -> void:
	_pulse(1.15)

func _on_spent(_amount: int, _reason: String) -> void:
	_pulse(0.92)

# ---------- upgrades readout + button state ----------

func _refresh_upgrades() -> void:
	if not show_upgrades or _up_label == null:
		return

	var lvl := 0
	var next_cost := 0
	var mult := 1.0
	var can_buy := false
	var maxed := false

	if _pu:
		if _pu.has_method("upgrade_level"):
			lvl = int(_pu.call("upgrade_level", "turret_damage"))
		if _pu.has_method("upgrade_cost"):
			next_cost = int(_pu.call("upgrade_cost", "turret_damage"))
		if _pu.has_method("turret_damage_multiplier"):
			mult = float(_pu.call("turret_damage_multiplier"))
		if _pu.has_method("can_purchase"):
			can_buy = bool(_pu.call("can_purchase", "turret_damage"))
		maxed = next_cost < 0

	_up_label.text = "Upgrade: Turret Damage   L:%d   Next:%d   x%.2f" % [lvl, next_cost, mult]

	if _buy_btn:
		if maxed:
			_buy_btn.text = "Maxed"
			_buy_btn.disabled = true
		else:
			_buy_btn.text = "Buy (+10%) " 
			_buy_btn.disabled = not can_buy

func _on_upgrade(_id: String, _new_level: int, _next_cost: int) -> void:
	_refresh_upgrades()

func _on_buy_pressed() -> void:
	if _pu and _pu.has_method("purchase"):
		var ok := bool(_pu.call("purchase", "turret_damage"))
		if not ok and _buy_btn:
			var t := create_tween()
			t.tween_property(_buy_btn, "scale", Vector2(1.05, 1.05), 0.08)
			t.tween_property(_buy_btn, "scale", Vector2.ONE, 0.08)
	_refresh_upgrades()
