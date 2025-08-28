# res://scripts/power_ups_hud.gd
extends CanvasLayer

@export var columns: int = 2
@export var card_min_size: Vector2 = Vector2(180, 64) # fits 3 lines
@export var margin_left: int = 16
@export var margin_bottom: int = 16
@export var grid_h_separation: int = 6
@export var grid_v_separation: int = 6

const TAB_OFFENSE := 0
const TAB_BASE := 1

var _panel: Control
var _tabs: TabContainer
var _grid_offense: GridContainer
var _grid_base: GridContainer

# Per-tab card maps: id:String -> Button
var _cards_offense: Dictionary = {}
var _cards_base: Dictionary = {}

func _ready() -> void:
	# Root panel positioned bottom-left
	_panel = Control.new()
	_panel.name = "Panel"
	add_child(_panel)

	# Tabs
	_tabs = TabContainer.new()
	_tabs.clip_tabs = true
	_tabs.tab_alignment = TabBar.ALIGNMENT_LEFT
	_panel.add_child(_tabs)

	# Offense tab
	_grid_offense = _make_grid()
	var offense_tab := MarginContainer.new()
	offense_tab.add_child(_grid_offense)
	_tabs.add_child(offense_tab)
	_tabs.set_tab_title(TAB_OFFENSE, "Offense")

	# Base/Utility tab
	_grid_base = _make_grid()
	var base_tab := MarginContainer.new()
	base_tab.add_child(_grid_base)
	_tabs.add_child(base_tab)
	_tabs.set_tab_title(TAB_BASE, "Base")

	# Build content
	_build_cards()
	_layout_panel()

	# Events
	get_viewport().size_changed.connect(_layout_panel)
	_tabs.tab_changed.connect(func(_i: int) -> void: _layout_panel())
	if Economy.has_signal("balance_changed"):
		Economy.balance_changed.connect(_on_balance_changed)
	if PowerUps.has_signal("changed"):
		PowerUps.changed.connect(_refresh_all)
	if PowerUps.has_signal("upgrade_purchased"):
		PowerUps.upgrade_purchased.connect(_on_upgrade_purchased)

	_refresh_all()

func _make_grid() -> GridContainer:
	var g := GridContainer.new()
	g.columns = max(1, columns)
	g.add_theme_constant_override("h_separation", grid_h_separation)
	g.add_theme_constant_override("v_separation", grid_v_separation)
	return g

# ---------- signals ----------
func _on_balance_changed(_bal: int) -> void:
	_refresh_all()

func _on_upgrade_purchased(_id: String, _lvl: int, _next_cost: int) -> void:
	_refresh_all()

# ---------- layout ----------
func _layout_panel() -> void:
	# Active grid drives size
	var active_grid := (_grid_offense if _tabs.current_tab == TAB_OFFENSE else _grid_base)
	var active_count: int = int(active_grid.get_child_count())

	var cols: int = max(1, columns)
	var rows: int = (active_count + cols - 1) / cols if active_count > 0 else 0

	var width: float = float(cols) * card_min_size.x
	if cols > 1:
		width += float(cols - 1) * float(grid_h_separation)

	var height: float = float(rows) * card_min_size.y
	if rows > 1:
		height += float(rows - 1) * float(grid_v_separation)

	# enforce per-card min size
	for btn in _cards_offense.values():
		(btn as Button).custom_minimum_size = card_min_size
	for btn in _cards_base.values():
		(btn as Button).custom_minimum_size = card_min_size

	_tabs.custom_minimum_size = Vector2(width, height + 28) # +tab bar height
	_panel.custom_minimum_size = _tabs.custom_minimum_size
	_panel.size = _tabs.custom_minimum_size

	var vp: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	var x: float = float(margin_left)
	var y: float = vp.y - _panel.size.y - float(margin_bottom)
	_panel.position = Vector2(x, y)

# ---------- build & refresh ----------
func _build_cards() -> void:
	_cards_offense.clear()
	_cards_base.clear()
	_clear_children(_grid_offense)
	_clear_children(_grid_base)

	# Partition ids by category, but only include what exists in config
	for k in PowerUps.upgrades_config.keys():
		var id := String(k)
		var cat := _category_for(id)
		if cat == TAB_OFFENSE:
			_add_card_for(id, _grid_offense, _cards_offense)
		else:
			_add_card_for(id, _grid_base, _cards_base)

func _add_card_for(id: String, grid: GridContainer, bucket: Dictionary) -> void:
	var btn := Button.new()
	btn.custom_minimum_size = card_min_size
	btn.focus_mode = Control.FOCUS_NONE
	btn.text = ""

	# snug padding so 3 lines fit
	btn.add_theme_constant_override("content_margin_left", 8)
	btn.add_theme_constant_override("content_margin_right", 8)
	btn.add_theme_constant_override("content_margin_top", 6)
	btn.add_theme_constant_override("content_margin_bottom", 6)

	btn.set_meta("id", id)
	btn.pressed.connect(_on_card_pressed.bind(btn))

	grid.add_child(btn)
	bucket[id] = btn

func _on_card_pressed(btn: Button) -> void:
	var id: String = str(btn.get_meta("id"))
	if PowerUps.purchase(id):
		_refresh_card(id)
		_layout_panel()

func _refresh_all() -> void:
	for id in _cards_offense.keys():
		_refresh_card(String(id))
	for id in _cards_base.keys():
		_refresh_card(String(id))
	_layout_panel()

func _refresh_card(id: String) -> void:
	var btn: Button = (_cards_offense.get(id, null) as Button)
	if btn == null:
		btn = (_cards_base.get(id, null) as Button)
	if btn == null:
		return

	var lvl: int = PowerUps.upgrade_level(id)
	var conf: Dictionary = PowerUps.upgrades_config.get(id, {}) as Dictionary
	var max_level: int = int(conf.get("max_level", 0))
	var at_max: bool = (max_level > 0 and lvl >= max_level)

	var title: String = _pretty_name(id)
	var value_line: String = _value_line(id, lvl)

	var cost: int = PowerUps.upgrade_cost(id)
	var can_buy: bool = (not at_max and cost >= 0 and Economy.balance() >= cost)

	var cost_line: String
	if at_max:
		cost_line = "MAX"
	elif cost >= 0:
		cost_line = "$ " + str(cost)
	else:
		cost_line = "—"

	btn.text = title + "\n" + value_line + "\n" + cost_line
	btn.disabled = at_max or not can_buy
	btn.modulate = (Color(0.9, 0.9, 0.9) if btn.disabled else Color(1, 1, 1))

# ---------- category / naming ----------
func _category_for(id: String) -> int:
	# Offense: turret_* and crit_*; Base: spawner_* and base_* (health, regen)
	if id.begins_with("turret_") or id.begins_with("crit_"):
		return TAB_OFFENSE
	if id.begins_with("spawner_") or id.begins_with("base_"):
		return TAB_BASE
	# Fallback: treat unknowns as Offense (keeps them visible)
	return TAB_OFFENSE

func _pretty_name(id: String) -> String:
	match id:
		# Offense
		"turret_damage":     return "Damage"
		"turret_rate":       return "Attack Speed"
		"turret_range":      return "Range"
		"crit_chance":       return "Crit Chance"
		"crit_mult":         return "Crit Damage"
		"turret_multishot":  return "Multi-Shot"
		# Base
		"base_max_hp":       return "Max Health"
		"base_regen":        return "Health Regen"
		"spawner_health":    return "Spawner Health"
		_:                   return id.capitalize()

# ---------- values / formatting ----------
func _value_line(id: String, current_level: int) -> String:
	match id:
		"turret_damage":
			var cur_dmg: int = PowerUps.turret_damage_value()
			var nxt_dmg: int = PowerUps.next_turret_damage_value()
			return "%d → %d" % [cur_dmg, nxt_dmg]

		"turret_rate":
			var t: Node = PowerUps.find_any_turret()
			var info: Dictionary = PowerUps.turret_rate_info(t)
			var cur_sps: float = float(info.get("current_sps", 0.0))
			var nxt_interval: float = float(info.get("next_interval", 0.0))
			var nxt_sps: float = (1.0 / nxt_interval) if nxt_interval > 0.0 else 0.0
			return "%.2f/s → %.2f/s" % [cur_sps, nxt_sps]

		"turret_range":
			var t2: Node = PowerUps.find_any_turret()
			var rinfo: Dictionary = PowerUps.turret_range_info(t2)
			var cur_r: float = float(rinfo.get("current_range", 0.0))
			var nxt_r: float = float(rinfo.get("next_range", 0.0))
			return "%.1f → %.1f" % [cur_r, nxt_r]

		"crit_chance":
			var curp: float = PowerUps.crit_chance_value() * 100.0
			var nxtp: float = PowerUps.next_crit_chance_value() * 100.0
			return "%.0f%% → %.0f%%" % [curp, nxtp]

		"crit_mult":
			var curm: float = PowerUps.crit_mult_value()
			var nxtm: float = PowerUps.next_crit_mult_value()
			return "x%.2f → x%.2f" % [curm, nxtm]

		"turret_multishot":
			var cur_ms: float = 0.0
			var nxt_ms: float = 0.0
			if PowerUps.has_method("multishot_percent_value"):
				cur_ms = PowerUps.multishot_percent_value()
			if PowerUps.has_method("next_multishot_percent_value"):
				nxt_ms = PowerUps.next_multishot_percent_value()

			var cur_base: int = 1 + int(floor(cur_ms / 100.0))
			var cur_rem: int = int(round(cur_ms - float(cur_base - 1) * 100.0))
			if cur_rem < 0: cur_rem = 0

			var nxt_base: int = 1 + int(floor(nxt_ms / 100.0))
			var nxt_rem: int = int(round(nxt_ms - float(nxt_base - 1) * 100.0))
			if nxt_rem < 0: nxt_rem = 0

			# Example: "2 +70% → 2 +90%" (guaranteed 2 targets, 70% for a 3rd)
			return "%d +%d%% → %d +%d%%" % [cur_base, cur_rem, nxt_base, nxt_rem]

		"base_max_hp":
			# Use PowerUps helper; works even if Health autoload isn't passed in.
			var hinfo: Dictionary = PowerUps.health_max_info()
			var cur_m: int = int(hinfo.get("current_max_hp", 0))
			var nxt_m: int = int(hinfo.get("next_max_hp", 0))
			if cur_m > 0 and nxt_m > 0:
				return "%d → %d" % [cur_m, nxt_m]
			return "Lv " + str(current_level)

		"base_regen":
			var rinfo2: Dictionary = PowerUps.health_regen_info()
			var cur_rg: float = float(rinfo2.get("current_regen_per_sec", 0.0))
			var nxt_rg: float = float(rinfo2.get("next_regen_per_sec", 0.0))
			if cur_rg >= 0.0 and nxt_rg > 0.0:
				return "%.2f/s → %.2f/s" % [cur_rg, nxt_rg]
			return "Lv " + str(current_level)

		"spawner_health":
			# Kept for compatibility if you still use it.
			if PowerUps.has_method("spawner_health_value") and PowerUps.has_method("next_spawner_health_value"):
				var cur_h: int = int(PowerUps.spawner_health_value())
				var nxt_h: int = int(PowerUps.next_spawner_health_value())
				return "%d → %d" % [cur_h, nxt_h]
			return "Lv " + str(current_level)

		_:
			return "Lv " + str(current_level)

# ---------- utils ----------
func _clear_children(n: Node) -> void:
	for c in n.get_children():
		(c as Node).queue_free()
