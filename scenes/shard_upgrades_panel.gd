extends Panel

# --- layout knobs you can tweak ---
const OPEN_HEIGHT_FRACTION := 0.70          # ~70% of screen height on open
const OPEN_MIN_SIZE        := Vector2(560, 380)
const OPEN_SIDE_MARGIN     := 24.0          # distance from screen left
const OPEN_VPAD_TOP        := 24.0
const OPEN_VPAD_BOTTOM     := 24.0
const INNER_MARGIN         := 20            # padding inside the panel

# scene refs
var _margin: MarginContainer
var _root_vbox: VBoxContainer
var _balance_label: Label
var _close_button: Button
var _reset_shards_btn: Button
var _reset_upgrades_btn: Button

# dynamic
var _tabs: TabContainer
var _rows_by_id: Dictionary = {}  # id -> {value:Label, cost:Label, btn:Button}

func _ready() -> void:
	hide()
	custom_minimum_size = OPEN_MIN_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 100

	# find nodes already in your scene
	_margin = get_node_or_null("MarginContainer") as MarginContainer
	_root_vbox = get_node_or_null("MarginContainer/VBoxContainer") as VBoxContainer
	_balance_label = get_node_or_null("MarginContainer/VBoxContainer/BalanceLabel") as Label
	_close_button = get_node_or_null("MarginContainer/VBoxContainer/CloseButton") as Button
	_reset_shards_btn = _find_first([
		"MarginContainer/VBoxContainer/ResetShardsButton",
		"MarginContainer/VBoxContainer/ResetShardsButt"
	]) as Button
	_reset_upgrades_btn = _find_first([
		"MarginContainer/VBoxContainer/ResetUpgradesButton",
		"MarginContainer/VBoxContainer/ResetUpgradesB"
	]) as Button

	# make the container fill the panel with comfortable padding
	if _margin:
		_margin.anchor_left = 0.0; _margin.anchor_top = 0.0
		_margin.anchor_right = 1.0; _margin.anchor_bottom = 1.0
		_margin.offset_left = INNER_MARGIN
		_margin.offset_right = -INNER_MARGIN
		_margin.offset_top = INNER_MARGIN
		_margin.offset_bottom = -INNER_MARGIN
		_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_margin.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	if _root_vbox:
		_root_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_root_vbox.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		_root_vbox.add_theme_constant_override("separation", 10)

	# buttons
	if _close_button:
		_close_button.text = "Close"
		_close_button.pressed.connect(hide)

	if _reset_shards_btn:
		_reset_shards_btn.text = "Reset Shards"
		_reset_shards_btn.pressed.connect(func():
			if Shards and Shards.has_method("reset_for_testing"):
				Shards.reset_for_testing(0)
			_refresh_all()
		)

	if _reset_upgrades_btn:
		_reset_upgrades_btn.text = "Reset Upgrades"
		_reset_upgrades_btn.pressed.connect(func():
			if Shards and Shards.has_method("reset_meta_for_testing"):
				Shards.reset_meta_for_testing()
			_refresh_all()
		)

	# tabs + rows
	_build_tabs()

	# live updates
	if Shards:
		if Shards.has_signal("changed"):
			Shards.changed.connect(func(_b:int): _refresh_all())
		if Shards.has_signal("meta_changed"):
			Shards.meta_changed.connect(func(id:String, _lvl:int): _refresh_row(id))

	_refresh_all()


# ================= UI build =================

func _build_tabs() -> void:
	if _root_vbox == null: return
	var old := _root_vbox.get_node_or_null("Tabs")
	if old: old.queue_free()

	_tabs = TabContainer.new()
	_tabs.name = "Tabs"
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_root_vbox.add_child(_tabs)
	_root_vbox.move_child(_tabs, 1)  # after BalanceLabel

	var defs: Dictionary = Shards.get_meta_defs()
	var tab_boxes := {}  # tab_name -> VBoxContainer inside ScrollContainer

	for id in defs.keys():
		var def: Dictionary = defs[id]
		var tab_name := String(def.get("tab", "Other"))

		if not tab_boxes.has(tab_name):
			var sc := ScrollContainer.new()
			sc.name = tab_name
			sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sc.size_flags_vertical   = Control.SIZE_EXPAND_FILL
			_tabs.add_child(sc)

			var vb := VBoxContainer.new()
			vb.name = "VBox"
			vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			vb.size_flags_vertical   = Control.SIZE_EXPAND_FILL
			vb.add_theme_constant_override("separation", 8)
			sc.add_child(vb)
			tab_boxes[tab_name] = vb

		var vb2: VBoxContainer = tab_boxes[tab_name]
		vb2.add_child(_make_row(id, String(def.get("label", id))))

		var sep := ColorRect.new()
		sep.color = Color(1,1,1,0.04)
		sep.custom_minimum_size = Vector2(0, 1)
		vb2.add_child(sep)

	for i in range(_tabs.get_child_count()):
		_tabs.set_tab_title(i, _tabs.get_child(i).name)

func _make_row(id: String, label_text: String) -> Control:
	var row := HBoxContainer.new()
	row.name = "row_" + id
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 10)

	var name := Label.new()
	name.text = label_text
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name.size_flags_stretch_ratio = 2.6
	row.add_child(name)

	var value := Label.new()
	value.text = ""  # filled in by _refresh_row
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.size_flags_stretch_ratio = 2.0
	row.add_child(value)

	var cost := Label.new()
	cost.text = "Cost: -"
	cost.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cost.size_flags_stretch_ratio = 1.2
	row.add_child(cost)

	var btn := Button.new()
	btn.text = "Upgrade"
	btn.custom_minimum_size = Vector2(96, 0)
	btn.pressed.connect(func():
		if Shards and Shards.try_buy_meta(id):
			var pu := get_node_or_null("/root/PowerUps")
			if pu and pu.has_method("_apply_shards_meta"):
				pu.call("_apply_shards_meta")
			_refresh_row(id)
			_refresh_balance()
		)
	row.add_child(btn)

	_rows_by_id[id] = {"value": value, "cost": cost, "btn": btn}
	return row


# ================= Behavior =================

func open() -> void:
	_refresh_all()
	show()
	await get_tree().process_frame

	# Make the panel taller on open (more space up/down)
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var target_h: float = clampf(vp.y * OPEN_HEIGHT_FRACTION, OPEN_MIN_SIZE.y, vp.y - (OPEN_VPAD_TOP + OPEN_VPAD_BOTTOM))
	var target_w: float = clampf(OPEN_MIN_SIZE.x, OPEN_MIN_SIZE.x, vp.x - (OPEN_SIDE_MARGIN + 24.0))
	size = Vector2(target_w, target_h)

	_place_left(OPEN_SIDE_MARGIN, OPEN_VPAD_TOP, OPEN_VPAD_BOTTOM)
	move_to_front()

func _refresh_all() -> void:
	_refresh_balance()
	for id in _rows_by_id.keys():
		_refresh_row(String(id))

func _refresh_balance() -> void:
	if _balance_label:
		var bal: int = (Shards.get_balance() if Shards and Shards.has_method("get_balance") else 0)
		_balance_label.text = "Shards: %d" % bal

func _refresh_row(id: String) -> void:
	if not _rows_by_id.has(id) or Shards == null:
		return

	# cost + button
	var next_cost := Shards.get_meta_next_cost(id)
	var r: Dictionary = _rows_by_id[id]
	var cost_lbl := r["cost"] as Label
	var btn := r["btn"] as Button

	if next_cost < 0:
		cost_lbl.text = "Maxed"
		btn.disabled = true
	else:
		cost_lbl.text = "Cost: %d" % next_cost
		var bal: int = Shards.get_balance()
		btn.disabled = (bal < next_cost)

	# preview "current → next"
	(r["value"] as Label).text = _stat_preview_for(id)

# place panel near left edge, vertically centered with margins
func _place_left(x_margin: float, y_margin_top: float, y_margin_bottom: float) -> void:
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var sz: Vector2 = size
	if sz.x < 2.0 or sz.y < 2.0:
		sz = custom_minimum_size
		size = sz
	anchor_left = 0; anchor_top = 0; anchor_right = 0; anchor_bottom = 0
	var y: float = clampf((vp.y - sz.y) * 0.5, y_margin_top, maxf(0.0, vp.y - sz.y - y_margin_bottom))
	position = Vector2(x_margin, y)

func _find_first(paths: Array) -> Node:
	for p in paths:
		var n := get_node_or_null(p)
		if n != null: return n
	return null

func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		hide()
		get_viewport().set_input_as_handled()

# ================= Preview helpers =================

func _stat_preview_for(id: String) -> String:
	if PowerUps == null:
		return ""
	match id:
		"turret_damage":
			return "%d → %d" % [PowerUps.turret_damage_value(), PowerUps.next_turret_damage_value()]

		"turret_rate":
			var info := PowerUps.turret_rate_info(null)
			var cur_sps := float(info.get("current_sps", 0.0))
			var next_interval := float(info.get("next_interval", 0.0))
			var next_sps := (0.0 if next_interval <= 0.0 else 1.0 / next_interval)
			return "%s/s → %s/s" % [_fmtf(cur_sps, 2), _fmtf(next_sps, 2)]

		"turret_range":
			var info2 := PowerUps.turret_range_info(null)
			return "%s → %s" % [_fmtf(float(info2.get("current_range", 0.0)), 1),
								_fmtf(float(info2.get("next_range", 0.0)), 1)]

		"crit_chance":
			return "%s → %s" % [_pct(PowerUps.crit_chance_value(), 1),
								_pct(PowerUps.next_crit_chance_value(), 1)]

		"crit_mult":
			return "%sx → %sx" % [_fmtf(PowerUps.crit_mult_value(), 2),
								  _fmtf(PowerUps.next_crit_mult_value(), 2)]

		"turret_multishot":
			return "%s → %s" % [_pct(PowerUps.multishot_percent_value(), 0),
								_pct(PowerUps.next_multishot_percent_value(), 0)]

		"base_max_hp":
			var h := PowerUps.health_max_info(null)
			return "%d → %d" % [int(h.get("current_max_hp", 0)),
								int(h.get("next_max_hp", 0))]

		"base_regen":
			var r := PowerUps.health_regen_info(null)
			return "%s → %s hp/s" % [_fmtf(float(r.get("current_regen_per_sec", 0.0)), 2),
									  _fmtf(float(r.get("next_regen_per_sec", 0.0)), 2)]

		# Map expansions: leave specific preview for later
		"board_add_left", "board_add_right", "board_push_back":
			return "—"

		_:
			return ""

func _fmtf(v: float, d: int = 2) -> String:
	var fmt := "%0." + str(d) + "f"
	return fmt % v

func _pct(v: float, d: int = 1) -> String:
	return _fmtf(v * 100.0, d) + "%"
