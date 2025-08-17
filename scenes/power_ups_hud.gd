extends CanvasLayer

@export var columns: int = 2
@export var card_min_size: Vector2 = Vector2(130, 50)  # half-size tiles
@export var margin_left: int = 16
@export var margin_bottom: int = 16
@export var grid_h_separation: int = 6
@export var grid_v_separation: int = 6

var _panel: Control
var _grid: GridContainer
var _cards: Dictionary = {}   # id -> Button

func _ready() -> void:
	# Panel that we position bottom-left in screen space
	_panel = Control.new()
	_panel.name = "Panel"
	add_child(_panel)

	# Grid of cards
	_grid = GridContainer.new()
	_grid.columns = max(1, columns)
	_grid.add_theme_constant_override("h_separation", grid_h_separation)
	_grid.add_theme_constant_override("v_separation", grid_v_separation)
	_panel.add_child(_grid)

	_build_cards()
	_layout_panel()

	# Relayout/refresh on changes
	get_viewport().size_changed.connect(_layout_panel)
	Economy.balance_changed.connect(_on_balance_changed)
	PowerUps.changed.connect(_refresh_all)
	PowerUps.upgrade_purchased.connect(_on_upgrade_purchased)

	_refresh_all()

func _on_balance_changed(_bal: int) -> void:
	_refresh_all()

func _on_upgrade_purchased(_id: String, _lvl: int, _next_cost: int) -> void:
	_refresh_all()

# ---------- layout ----------
func _layout_panel() -> void:
	var count: int = PowerUps.upgrades_config.size()
	var cols: int = max(1, columns)
	var rows: int = 0
	if count > 0:
		rows = int(ceil(float(count) / float(cols)))

	var width: float = float(cols) * card_min_size.x
	if cols > 1:
		width += float(cols - 1) * float(grid_h_separation)

	var height: float = float(rows) * card_min_size.y
	if rows > 1:
		height += float(rows - 1) * float(grid_v_separation)

	_grid.custom_minimum_size = Vector2(width, height)
	_panel.custom_minimum_size = Vector2(width, height)
	_panel.size = Vector2(width, height)

	var vp: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	var x: float = float(margin_left)
	var y: float = vp.y - height - float(margin_bottom)
	_panel.position = Vector2(x, y)

# ---------- build & refresh ----------
func _build_cards() -> void:
	_cards.clear()
	_clear_grid_children()
	for id in PowerUps.upgrades_config.keys():
		_add_card_for(id)

func _add_card_for(id: String) -> void:
	var btn := Button.new()
	btn.custom_minimum_size = card_min_size
	btn.focus_mode = Control.FOCUS_NONE
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	btn.text = ""  # we use child labels; the whole tile is clickable

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	btn.add_child(root)

	var row_top := HBoxContainer.new()
	row_top.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(row_top)

	var title := Label.new()
	title.text = _pretty_name(id)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_top.add_child(title)

	var value := Label.new()
	value.text = ""
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row_top.add_child(value)

	var cost := Label.new()
	cost.text = ""
	root.add_child(cost)

	btn.set_meta("id", id)
	btn.set_meta("value_label", value)
	btn.set_meta("cost_label", cost)
	btn.pressed.connect(_on_card_pressed.bind(btn))

	_grid.add_child(btn)
	_cards[id] = btn

func _on_card_pressed(btn: Button) -> void:
	var id: String = str(btn.get_meta("id"))
	PowerUps.purchase(id)
	_refresh_card(id)

func _refresh_all() -> void:
	for id in _cards.keys():
		_refresh_card(id)
	_layout_panel()

func _refresh_card(id: String) -> void:
	var btn := _cards.get(id, null) as Button
	if btn == null:
		return
	var value_label := btn.get_meta("value_label") as Label
	var cost_label := btn.get_meta("cost_label") as Label

	var lvl: int = PowerUps.upgrade_level(id)
	var conf: Dictionary = PowerUps.upgrades_config.get(id, {}) as Dictionary
	var max_level: int = int(conf.get("max_level", 0))
	var at_max: bool = (max_level > 0 and lvl >= max_level)

	value_label.text = _next_value_text(id, lvl)

	var cost: int = PowerUps.upgrade_cost(id)
	var can_buy: bool = (not at_max and cost >= 0 and Economy.balance() >= cost)
	if at_max:
		cost_label.text = "MAX"
		btn.disabled = true
	else:
		cost_label.text = "$ " + str(cost)
		btn.disabled = not can_buy

	if btn.disabled:
		btn.modulate = Color(0.9, 0.9, 0.9)
	else:
		btn.modulate = Color(1, 1, 1)

# ---------- formatting ----------
func _pretty_name(id: String) -> String:
	match id:
		"turret_damage":
			return "Damage"
		"attack_speed":
			return "Attack Speed"
		"crit_chance":
			return "Critical Chance"
		"crit_mult":
			return "Critical Factor"
		_:
			return id.capitalize()

func _next_value_text(id: String, current_level: int) -> String:
	if id == "turret_damage":
		var conf: Dictionary = PowerUps.upgrades_config.get(id, {}) as Dictionary
		var per: float = float(conf.get("per_level_pct", 0.0)) / 100.0
		var next_mult: float = pow(1.0 + per, float(current_level + 1))
		return "x" + ("%.2f" % next_mult)
	return "Lv " + str(current_level + 1)

# ---------- utilities ----------
func _clear_grid_children() -> void:
	for c in _grid.get_children():
		(c as Node).queue_free()
