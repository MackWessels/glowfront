extends CanvasLayer

@export var columns: int = 2
@export var card_min_size: Vector2 = Vector2(180, 64) # fits 3 lines
@export var margin_left: int = 16
@export var margin_bottom: int = 16
@export var grid_h_separation: int = 6
@export var grid_v_separation: int = 6

# show exactly this many full rows; extra content scrolls
@export var visible_rows: int = 3
# small padding on top of the 3 rows (helps show scroll thumb nicely)
@export var body_extra_px: int = 40

const TAB_OFFENSE := 0
const TAB_BASE := 1
const TAB_ECON := 2

const TAB_BAR_FALLBACK_H := 28.0

var _panel: Control
var _tabs: TabContainer

var _scroll_offense: ScrollContainer
var _scroll_base: ScrollContainer
var _scroll_econ: ScrollContainer

var _grid_offense: GridContainer
var _grid_base: GridContainer
var _grid_econ: GridContainer

# Per-tab card maps: id:String -> Button
var _cards_offense: Dictionary = {}
var _cards_base: Dictionary = {}
var _cards_econ: Dictionary = {}

# --- Collapse/expand state ---
var _collapsed: bool = false
var _selected_tab: int = 0   # tracks the currently-active tab index

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
	_scroll_offense = _make_scroller()
	_scroll_offense.add_child(_grid_offense)
	var offense_tab := MarginContainer.new()
	offense_tab.add_child(_scroll_offense)
	_tabs.add_child(offense_tab)
	_tabs.set_tab_title(TAB_OFFENSE, "Offense")

	# Base tab
	_grid_base = _make_grid()
	_scroll_base = _make_scroller()
	_scroll_base.add_child(_grid_base)
	var base_tab := MarginContainer.new()
	base_tab.add_child(_scroll_base)
	_tabs.add_child(base_tab)
	_tabs.set_tab_title(TAB_BASE, "Base")

	# Economy tab
	_grid_econ = _make_grid()
	_scroll_econ = _make_scroller()
	_scroll_econ.add_child(_grid_econ)
	var econ_tab := MarginContainer.new()
	econ_tab.add_child(_scroll_econ)
	_tabs.add_child(econ_tab)
	_tabs.set_tab_title(TAB_ECON, "Economy")

	# Build content
	_build_cards()
	_layout_panel()

	# Events
	get_viewport().size_changed.connect(_layout_panel)

	# Keep _selected_tab current (deferred avoids the “collapse on tab switch” race)
	_selected_tab = _tabs.current_tab
	_tabs.tab_changed.connect(_on_tab_changed, Object.CONNECT_DEFERRED)

	# Detect clicks on the TabBar so we only toggle when the SAME tab is clicked
	var tb: TabBar = _tabs.get_tab_bar()
	if tb and not tb.is_connected("tab_clicked", _on_tab_bar_clicked):
		tb.tab_clicked.connect(_on_tab_bar_clicked)

	if typeof(Economy) != TYPE_NIL and Economy.has_signal("balance_changed"):
		Economy.balance_changed.connect(_on_balance_changed)
	if typeof(PowerUps) != TYPE_NIL and PowerUps.has_signal("changed"):
		PowerUps.changed.connect(_refresh_all)
	if typeof(PowerUps) != TYPE_NIL and PowerUps.has_signal("upgrade_purchased"):
		PowerUps.upgrade_purchased.connect(_on_upgrade_purchased)

	_refresh_all()

# ---------- collapse/expand handlers ----------
func _on_tab_changed(i: int) -> void:
	_selected_tab = i
	_reset_scrolls()
	_layout_panel()

func _on_tab_bar_clicked(idx: int) -> void:
	# Toggle ONLY if clicking the tab that's already active.
	# We compare to _selected_tab (updated after real tab changes).
	if idx == _selected_tab:
		_collapsed = not _collapsed
		_layout_panel()
	# If a different tab was clicked, TabContainer will switch it;
	# our deferred _on_tab_changed will run next frame and just relayout.

# ---------- factories ----------
func _make_grid() -> GridContainer:
	var g := GridContainer.new()
	g.columns = max(1, columns)
	g.add_theme_constant_override("h_separation", grid_h_separation)
	g.add_theme_constant_override("v_separation", grid_v_separation)
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.size_flags_vertical = Control.SIZE_FILL
	return g

func _make_scroller() -> ScrollContainer:
	var s := ScrollContainer.new()
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	s.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return s

# ---------- signals ----------
func _on_balance_changed(_bal: int) -> void:
	_refresh_all()

func _on_upgrade_purchased(_id: String, _lvl: int, _next_cost: int) -> void:
	_refresh_all()

# ---------- helpers ----------
func _height_for_rows(rows: int) -> float:
	rows = max(1, rows)
	var h := float(rows) * card_min_size.y
	if rows > 1:
		h += float(rows - 1) * float(grid_v_separation)
	return h

func _tab_header_height() -> float:
	var tb: TabBar = _tabs.get_tab_bar()
	if tb:
		var min_h: float = tb.get_minimum_size().y
		var size_h: float = tb.size.y
		var h: float = max(min_h, size_h)
		return (h if h > 1.0 else TAB_BAR_FALLBACK_H)
	return TAB_BAR_FALLBACK_H

# ---------- layout ----------
func _layout_panel() -> void:
	# Active grid drives width calc (height is now unified across tabs)
	var active_grid := (
		_grid_offense if _tabs.current_tab == TAB_OFFENSE
		else (_grid_base if _tabs.current_tab == TAB_BASE else _grid_econ)
	)
	var active_count: int = int(active_grid.get_child_count())

	var cols: int = max(1, columns)
	var width: float = float(cols) * card_min_size.x
	if cols > 1:
		width += float(cols - 1) * float(grid_h_separation)

	# enforce per-card min size (all tabs)
	for btn in _cards_offense.values():
		(btn as Button).custom_minimum_size = card_min_size
	for btn in _cards_base.values():
		(btn as Button).custom_minimum_size = card_min_size
	for btn in _cards_econ.values():
		(btn as Button).custom_minimum_size = card_min_size

	# Header height (tab bar)
	var header_h: float = _tab_header_height()

	# === Unified body height across tabs ===
	var vp: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	var target_rows_px: float = _height_for_rows(visible_rows) + float(body_extra_px)
	var max_by_screen: float = max(card_min_size.y, vp.y - float(margin_bottom) - header_h - 8.0)
	var body_h: float = min(target_rows_px, max_by_screen)

	if _collapsed:
		_scroll_offense.custom_minimum_size = Vector2(width, 0.0)
		_scroll_base.custom_minimum_size    = Vector2(width, 0.0)
		_scroll_econ.custom_minimum_size    = Vector2(width, 0.0)

		_tabs.custom_minimum_size = Vector2(width, header_h)
		_panel.custom_minimum_size = _tabs.custom_minimum_size
		_panel.size = _tabs.custom_minimum_size
	else:
		_scroll_offense.custom_minimum_size = Vector2(width, body_h)
		_scroll_base.custom_minimum_size    = Vector2(width, body_h)
		_scroll_econ.custom_minimum_size    = Vector2(width, body_h)

		_tabs.custom_minimum_size = Vector2(width, body_h + header_h)
		_panel.custom_minimum_size = _tabs.custom_minimum_size
		_panel.size = _tabs.custom_minimum_size

	# Anchor bottom-left
	var x: float = float(margin_left)
	var y: float = vp.y - _panel.size.y - float(margin_bottom)
	_panel.position = Vector2(x, y)

func _reset_scrolls() -> void:
	if _scroll_offense: _scroll_offense.scroll_vertical = 0
	if _scroll_base:    _scroll_base.scroll_vertical = 0
	if _scroll_econ:    _scroll_econ.scroll_vertical = 0

# ---------- build & refresh ----------
func _build_cards() -> void:
	_cards_offense.clear()
	_cards_base.clear()
	_cards_econ.clear()
	_clear_children(_grid_offense)
	_clear_children(_grid_base)
	_clear_children(_grid_econ)

	# Partition ids by category, but only include what exists in config
	for k in PowerUps.upgrades_config.keys():
		var id := String(k)
		var cat := _category_for(id)
		match cat:
			TAB_OFFENSE: _add_card_for(id, _grid_offense, _cards_offense)
			TAB_BASE:    _add_card_for(id, _grid_base, _cards_base)
			TAB_ECON:    _add_card_for(id, _grid_econ, _cards_econ)

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
	for id in _cards_econ.keys():
		_refresh_card(String(id))
	_layout_panel()

func _refresh_card(id: String) -> void:
	var btn: Button = (_cards_offense.get(id, null) as Button)
	if btn == null: btn = (_cards_base.get(id, null) as Button)
	if btn == null: btn = (_cards_econ.get(id, null) as Button)
	if btn == null: return

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
	if id.begins_with("eco_") or id.begins_with("miner_"):
		return TAB_ECON
	if id.begins_with("turret_") or id.begins_with("crit_") or id.begins_with("chain_lightning"):
		return TAB_OFFENSE
	if id.begins_with("spawner_") or id.begins_with("base_") or id.begins_with("board_"):
		return TAB_BASE
	return TAB_OFFENSE

func _pretty_name(id: String) -> String:
	match id:
		"turret_damage":            return "Damage"
		"turret_rate":              return "Attack Speed"
		"turret_range":             return "Range"
		"crit_chance":              return "Crit Chance"
		"crit_mult":                return "Crit Damage"
		"turret_multishot":         return "Multi-Shot"

		"chain_lightning_chance":   return "Chain Chance"
		"chain_lightning_damage":   return "Chain Damage"
		"chain_lightning_jumps":    return "Chain Jumps"

		"base_max_hp":              return "Max Health"
		"base_regen":               return "Health Regen"
		"spawner_health":           return "Spawner Health"

		"board_add_left":           return "Board Add Right"
		"board_add_right":          return "Board Add Left"
		"board_push_back":          return "Board Push Back"

		"eco_wave_stipend":         return "Wave Stipend"
		"eco_perfect":              return "Eco Perfect"
		"eco_bounty":               return "Eco Bounty"
		"miner_yield":              return "Miner Yield"
		"miner_speed":              return "Miner Speed"
		_:
			return id.capitalize()

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
			var cur_ms: float = (PowerUps.multishot_percent_value() if PowerUps.has_method("multishot_percent_value") else 0.0)
			var nxt_ms: float = (PowerUps.next_multishot_percent_value() if PowerUps.has_method("next_multishot_percent_value") else 0.0)
			var cur_base: int = 1 + int(floor(cur_ms / 100.0))
			var cur_rem: int = int(round(cur_ms - float(cur_base - 1) * 100.0)); if cur_rem < 0: cur_rem = 0
			var nxt_base: int = 1 + int(floor(nxt_ms / 100.0))
			var nxt_rem: int = int(round(nxt_ms - float(nxt_base - 1) * 100.0)); if nxt_rem < 0: nxt_rem = 0
			return "%d +%d%% → %d +%d%%" % [cur_base, cur_rem, nxt_base, nxt_rem]

		"chain_lightning_chance":
			var curc: float = (PowerUps.chain_chance_value() if PowerUps.has_method("chain_chance_value") else 0.0) * 100.0
			var nxtc: float = (PowerUps.next_chain_chance_value() if PowerUps.has_method("next_chain_chance_value") else 0.0) * 100.0
			return "%.0f%% → %.0f%%" % [curc, nxtc]

		"chain_lightning_damage":
			var curd: float = (PowerUps.chain_damage_percent_value() if PowerUps.has_method("chain_damage_percent_value") else 0.0)
			var nxtd: float = (PowerUps.next_chain_damage_percent_value() if PowerUps.has_method("next_chain_damage_percent_value") else 0.0)
			return "%.0f%% → %.0f%%" % [curd, nxtd]

		"chain_lightning_jumps":
			var curj: int = (PowerUps.chain_jumps_value() if PowerUps.has_method("chain_jumps_value") else 0)
			var nxtj: int = (PowerUps.next_chain_jumps_value() if PowerUps.has_method("next_chain_jumps_value") else 0)
			return "%d → %d" % [curj, nxtj]

		"base_max_hp":
			var hinfo: Dictionary = PowerUps.health_max_info()
			var cur_m: int = int(hinfo.get("current_max_hp", 0))
			var nxt_m: int = int(hinfo.get("next_max_hp", 0))
			return "%d → %d" % [cur_m, nxt_m]

		"base_regen":
			var rinfo2: Dictionary = PowerUps.health_regen_info()
			var cur_rg: float = float(rinfo2.get("current_regen_per_sec", 0.0))
			var nxt_rg: float = float(rinfo2.get("next_regen_per_sec", 0.0))
			return "%.2f/s → %.2f/s" % [cur_rg, nxt_rg]

		"board_add_left", "board_add_right", "board_push_back":
			return "%d → %d" % [current_level, current_level + 1]

		"eco_wave_stipend":
			var cur_stip: int = (PowerUps.eco_wave_stipend_value() if PowerUps.has_method("eco_wave_stipend_value") else current_level)
			var nxt_stip: int = (PowerUps.next_eco_wave_stipend_value() if PowerUps.has_method("next_eco_wave_stipend_value") else current_level + 1)
			return "%d → %d" % [cur_stip, nxt_stip]

		"eco_perfect":
			var cur_pb: float = (PowerUps.eco_perfect_bonus_pct_value() if PowerUps.has_method("eco_perfect_bonus_pct_value") else float(current_level) * 0.25) * 100.0
			var nxt_pb: float = (PowerUps.next_eco_perfect_bonus_pct_value() if PowerUps.has_method("next_eco_perfect_bonus_pct_value") else float(current_level + 1) * 0.25) * 100.0
			return "%.0f%% → %.0f%%" % [cur_pb, nxt_pb]

		"eco_bounty":
			var cur_bb: float = (PowerUps.eco_bounty_bonus_pct_value() if PowerUps.has_method("eco_bounty_bonus_pct_value") else float(current_level) * 0.15) * 100.0
			var nxt_bb: float = (PowerUps.next_eco_bounty_bonus_pct_value() if PowerUps.has_method("next_eco_bounty_bonus_pct_value") else float(current_level + 1) * 0.15) * 100.0
			return "%.0f%% → %.0f%%" % [cur_bb, nxt_bb]

		"miner_yield":
			var cur_y: int = (PowerUps.miner_yield_bonus_value() if PowerUps.has_method("miner_yield_bonus_value") else current_level)
			var nxt_y: int = (PowerUps.next_miner_yield_bonus_value() if PowerUps.has_method("next_miner_yield_bonus_value") else current_level + 1)
			return "+%d/tick → +%d/tick" % [cur_y, nxt_y]

		"miner_speed":
			var cur_s: float = (PowerUps.miner_speed_scale_value() if PowerUps.has_method("miner_speed_scale_value") else max(0.01, 1.0))
			var nxt_s: float = (PowerUps.next_miner_speed_scale_value() if PowerUps.has_method("next_miner_speed_scale_value") else max(0.01, 0.92))
			return "×%.2f → ×%.2f" % [cur_s, nxt_s]

		_:
			return "%d → %d" % [current_level, current_level + 1]

# ---------- utils ----------
func _clear_children(n: Node) -> void:
	for c in n.get_children():
		(c as Node).queue_free()
