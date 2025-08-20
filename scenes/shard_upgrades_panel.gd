extends Panel

@onready var _balance_label: Label = $"MarginContainer/VBoxContainer/BalanceLabel"
@onready var _dmg_button: Button   = $"MarginContainer/VBoxContainer/DamageButton"
@onready var _close_button: Button = $"MarginContainer/VBoxContainer/CloseButton"

# Optional testing buttons (only if you added them)
@onready var _reset_shards_btn: Button   = get_node_or_null("MarginContainer/VBoxContainer/ResetShardsButton") as Button
@onready var _reset_upgrades_btn: Button = get_node_or_null("MarginContainer/VBoxContainer/ResetUpgradesButton") as Button

func _ready() -> void:
	hide()                                   # start closed
	custom_minimum_size = Vector2(420, 200)  # visible size
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 100

	_close_button.pressed.connect(hide)
	_dmg_button.pressed.connect(_on_buy_damage)

	# Optional testing helpers
	if _reset_shards_btn:
		_reset_shards_btn.text = "Reset Shards"
		_reset_shards_btn.pressed.connect(func():
			if Shards.has_method("reset_for_testing"):
				Shards.reset_for_testing()
			_refresh()
		)
	if _reset_upgrades_btn:
		_reset_upgrades_btn.text = "Reset Upgrades"
		_reset_upgrades_btn.pressed.connect(func():
			if PowerUps.has_method("reset_meta_for_testing"):
				PowerUps.reset_meta_for_testing()
			_refresh()
		)

	if Shards.has_signal("changed"):   Shards.changed.connect(_on_shards_changed)
	if PowerUps.has_signal("changed"): PowerUps.changed.connect(_refresh)

	_refresh()

func open() -> void:
	_refresh()
	show()
	await get_tree().process_frame   # ensure size is valid
	_place_left()                    # << left-side placement
	move_to_front()

# Put panel near the left edge, vertically centered (with margins)
func _place_left(x_margin: float = 24.0, y_margin_top: float = 24.0, y_margin_bottom: float = 24.0) -> void:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var sz: Vector2 = size
	if sz.x < 2.0 or sz.y < 2.0:
		sz = custom_minimum_size
		size = sz

	# absolute positioning
	anchor_left = 0; anchor_top = 0; anchor_right = 0; anchor_bottom = 0

	# use the float versions to avoid Variant inference
	var y: float = clampf((vp.y - sz.y) * 0.5, y_margin_top, maxf(0.0, vp.y - sz.y - y_margin_bottom))
	position = Vector2(x_margin, y)


func _on_shards_changed(_n: int) -> void:
	_refresh()

func _on_buy_damage() -> void:
	if PowerUps.purchase_meta("turret_damage"):
		_refresh()

func _refresh() -> void:
	var bal: int = Shards.get_balance() if Shards.has_method("get_balance") else 0
	_balance_label.text = "Shards: %d" % bal

	var offer: Dictionary = PowerUps.get_next_meta_offer("turret_damage")
	if not bool(offer.get("available", false)):
		_dmg_button.disabled = true
		_dmg_button.text = "Damage MAX"
		return

	var need := int(offer.get("cost_shards", 0))
	var next_val := int(offer.get("next_value", 0))
	_dmg_button.text = "Damage -> %d  (%d shards)" % [next_val, need]
	_dmg_button.disabled = (bal < need)

func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		hide()
		get_viewport().set_input_as_handled()
