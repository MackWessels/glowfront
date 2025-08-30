extends Panel

# ---------- Layout / sizing ----------
const OPEN_HEIGHT_FRACTION := 0.70
const OPEN_MIN_SIZE        := Vector2(560, 420)
const OPEN_SIDE_MARGIN     := 24.0
const OPEN_VPAD_TOP        := 24.0
const OPEN_VPAD_BOTTOM     := 24.0
const INNER_MARGIN         := 20.0

# ---------- Drag + Resize ----------
const DRAG_STRIP_H := 40.0
const RESIZE_GRIP  := 16.0
const DRAG_MARGIN  := 6.0

# ---------- Fallback board (used if TileBoard not found) ----------
const FALLBACK_BASE_COLS := 11   # left→right (TileBoard Z)
const FALLBACK_BASE_ROWS := 10   # top→bottom (TileBoard X)

# ---------- Map upgrade IDs ----------
const MAP_IDS := ["board_add_left", "board_add_right", "board_push_back"]

# ---------- Dev/Testing ----------
@export var grant_test_amount: int = 1000

# ---------- Scene refs ----------
var _margin: MarginContainer
var _root_vbox: VBoxContainer
var _balance_label: Label
var _close_button: Button
var _reset_shards_btn: Button
var _reset_upgrades_btn: Button

# ---------- Tabs / rows ----------
var _tabs: TabContainer
var _rows_by_id: Dictionary = {}    # id -> row widgets
var _map_preview: Control           # MapPreview instance

# ---------- Drag/Resize state ----------
var _dragging := false
var _drag_mouse_start := Vector2.ZERO
var _drag_panel_start := Vector2.ZERO
var _resizing := false
var _resize_mouse_start := Vector2.ZERO
var _resize_start_size := Vector2.ZERO

# ---------- Local fallback for "applied" counts (if Shards lacks API) ----------
var _applied_local: Dictionary = {}  # id -> int

# ============================================================
#                        Map preview
# ============================================================
class MapPreview:
	extends Control

	var base_cols: int = FALLBACK_BASE_COLS  # Z from TileBoard
	var base_rows: int = FALLBACK_BASE_ROWS  # X from TileBoard

	var left_cols: int = 0
	var right_cols: int = 0
	var top_rows: int = 0

	func set_base(c: int, r: int) -> void:
		base_cols = maxi(1, c)
		base_rows = maxi(1, r)
		queue_redraw()

	func set_levels(left_in: int, right_in: int, top_in: int) -> void:
		left_cols  = max(0, left_in)
		right_cols = max(0, right_in)
		top_rows   = max(0, top_in)
		queue_redraw()

	func cur_width() -> int:  return base_cols + left_cols + right_cols
	func cur_height() -> int: return base_rows + top_rows

	func _draw() -> void:
		var cols := cur_width()
		var rows := cur_height()

		var r := get_rect()
		var pad := 12.0
		var area := r.size - Vector2(pad * 2.0, pad * 2.0)
		var cell := minf(area.x / float(cols), area.y / float(rows))
		if cell < 1.0: cell = 1.0

		var board_px := Vector2(float(cols) * cell, float(rows) * cell)
		var origin := r.position + (r.size - board_px) * 0.5

		# Base origin inside expanded grid (anchored by left/top expansions)
		var base_origin := origin + Vector2(float(left_cols) * cell, float(top_rows) * cell)
		var base_px     := Vector2(float(base_cols) * cell, float(base_rows) * cell)

		# Colors
		var col_bg      := Color(0.12, 0.12, 0.12, 0.10)
		var col_grid    := Color(1, 1, 1, 0.12)
		var col_border  := Color(1, 1, 1, 0.25)
		var col_top     := Color8(200, 130, 255, 60)  # push_back rows (top)
		var col_left    := Color8(130, 200, 255, 60)  # left columns
		var col_right   := Color8(130, 255, 160, 60)  # right columns
		var col_goal    := Color8(255, 205, 90, 255)
		var col_spawn   := Color8(90, 210, 255, 255)

		# Backdrop (whole upgraded board)
		draw_rect(Rect2(origin, board_px), col_bg, true)

		# Expansion overlays
		if left_cols > 0:
			draw_rect(Rect2(origin, Vector2(cell * float(left_cols), board_px.y)), col_left, true)
		if right_cols > 0:
			draw_rect(Rect2(origin + Vector2(board_px.x - cell * float(right_cols), 0.0),
							Vector2(cell * float(right_cols), board_px.y)), col_right, true)
		if top_rows > 0:
			draw_rect(Rect2(origin, Vector2(board_px.x, cell * float(top_rows))), col_top, true)

		# Grid
		for i in range(cols + 1):
			var x := origin.x + float(i) * cell
			draw_line(Vector2(x, origin.y), Vector2(x, origin.y + board_px.y), col_grid, 1.0)
		for j in range(rows + 1):
			var y := origin.y + float(j) * cell
			draw_line(Vector2(origin.x, y), Vector2(origin.x + board_px.x, y), col_grid, 1.0)

		# Base border (subtle)
		draw_rect(Rect2(base_origin, base_px), col_border, false, 2.0)

		# Spawner/Goal anchored to BASE mid column
		var base_mid_col := int(floor(float(base_cols) * 0.5))
		var spawn_col_x := origin.x + float(left_cols + base_mid_col) * cell

		var cell_px := Vector2(cell - 2.0, cell - 2.0)
		var spawn_rect := Rect2(Vector2(spawn_col_x + 1.0, origin.y + 1.0), cell_px)
		var goal_rect  := Rect2(Vector2(spawn_col_x + 1.0, origin.y + board_px.y - cell + 1.0), cell_px)

		draw_rect(spawn_rect, col_spawn, true)
		draw_rect(goal_rect,  col_goal,  true)

# ============================================================
#                           Lifecycle
# ============================================================
func _ready() -> void:
	hide()
	custom_minimum_size = OPEN_MIN_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 100
	clip_contents = true

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

	# Stretch layout
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

	# Buttons
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
			_applied_local.clear()
			_refresh_all()
		)

	# Grant shards button
	if _root_vbox:
		var grant_btn := Button.new()
		grant_btn.text = "Grant %d Shards" % grant_test_amount
		grant_btn.pressed.connect(func():
			if Shards:
				Shards.add(grant_test_amount, "dev_grant")
			_refresh_all()
		)
		_root_vbox.add_child(grant_btn)

	_build_tabs()

	if Shards:
		if Shards.has_signal("changed"):
			Shards.changed.connect(func(_b:int): _refresh_all())
		if Shards.has_signal("meta_changed"):
			Shards.meta_changed.connect(func(_id:String, _lvl:int): _refresh_all())

	_refresh_all()

# ============================================================
#                        Build tabs / rows
# ============================================================
func _build_tabs() -> void:
	if _root_vbox == null: return
	var old := _root_vbox.get_node_or_null("Tabs")
	if old: old.queue_free()

	_tabs = TabContainer.new()
	_tabs.name = "Tabs"
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_root_vbox.add_child(_tabs)
	_root_vbox.move_child(_tabs, 1)

	var defs: Dictionary = Shards.get_meta_defs()
	var tab_boxes := {}  # tab -> VBox in a ScrollContainer

	# Map tab
	var sc_map := ScrollContainer.new()
	sc_map.name = "Map"
	sc_map.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	sc_map.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	sc_map.clip_contents = true
	sc_map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc_map.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_tabs.add_child(sc_map)

	var vb_map := VBoxContainer.new()
	vb_map.name = "VBox"
	vb_map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb_map.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	vb_map.add_theme_constant_override("separation", 8)
	sc_map.add_child(vb_map)
	tab_boxes["Map"] = vb_map

	_map_preview = MapPreview.new()
	_map_preview.custom_minimum_size = Vector2(0, 240)
	_map_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map_preview.size_flags_vertical   = Control.SIZE_EXPAND
	(_map_preview as Control).clip_contents = true
	vb_map.add_child(_map_preview)

	# Other tabs
	for id in defs.keys():
		var def: Dictionary = defs[id]
		var tab_name := String(def.get("tab", "Other"))

		var vb: VBoxContainer = tab_boxes.get(tab_name, null)
		if vb == null:
			var sc := ScrollContainer.new()
			sc.name = tab_name
			sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
			sc.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
			sc.clip_contents = true
			sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sc.size_flags_vertical   = Control.SIZE_EXPAND_FILL
			_tabs.add_child(sc)

			vb = VBoxContainer.new()
			vb.name = "VBox"
			vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			vb.size_flags_vertical   = Control.SIZE_EXPAND_FILL
			vb.add_theme_constant_override("separation", 8)
			sc.add_child(vb)
			tab_boxes[tab_name] = vb

		if String(id) in MAP_IDS:
			vb.add_child(_make_map_row(String(id), String(def.get("label", id))))
		else:
			vb.add_child(_make_standard_row(String(id), String(def.get("label", id))))

		var sep := ColorRect.new()
		sep.color = Color(1,1,1,0.04)
		sep.custom_minimum_size = Vector2(0, 1)
		vb.add_child(sep)

	for i in range(_tabs.get_child_count()):
		_tabs.set_tab_title(i, _tabs.get_child(i).name)

# ---------------- Map row (minimal: name, -, +, cost, Upgrade) ----------------
func _make_map_row(id: String, label_text: String) -> Control:
	var row := HBoxContainer.new()
	row.name = "row_" + id
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.clip_contents = true
	row.add_theme_constant_override("separation", 10)

	var name := Label.new()
	name.text = label_text
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name.size_flags_stretch_ratio = 2.0
	row.add_child(name)

	var minus_btn := Button.new()
	minus_btn.text = "–"
	minus_btn.custom_minimum_size = Vector2(30, 0)
	minus_btn.pressed.connect(func(): _map_apply_delta(id, -1))
	row.add_child(minus_btn)

	var plus_btn := Button.new()
	plus_btn.text = "+"
	plus_btn.custom_minimum_size = Vector2(30, 0)
	plus_btn.pressed.connect(func(): _map_apply_delta(id, +1))
	row.add_child(plus_btn)

	var cost_lbl := Label.new()
	cost_lbl.text = "Cost: -"
	cost_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cost_lbl.size_flags_stretch_ratio = 0.9
	row.add_child(cost_lbl)

	var btn := Button.new()
	btn.text = "Upgrade"
	btn.custom_minimum_size = Vector2(96, 0)
	btn.size_flags_horizontal = 0
	btn.pressed.connect(func():
		if Shards and Shards.try_buy_meta(id):
			_ensure_default_applied_to_owned(id)
			_apply_powerups()
			_refresh_all()
	)
	row.add_child(btn)

	_rows_by_id[id] = {"minus": minus_btn, "plus": plus_btn, "cost": cost_lbl, "btn": btn}
	return row

# ---------------- Standard row (Offense/Defense unchanged) ----------------
func _make_standard_row(id: String, label_text: String) -> Control:
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
	value.text = ""
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
	btn.size_flags_horizontal = 0
	btn.pressed.connect(func():
		if Shards and Shards.try_buy_meta(id):
			_apply_powerups()
			_refresh_all()
	)
	row.add_child(btn)

	_rows_by_id[id] = {"value": value, "cost": cost, "btn": btn}
	return row

# ============================================================
#                          Behavior
# ============================================================
func open() -> void:
	_refresh_all()
	show()
	await get_tree().process_frame

	var vp: Vector2 = get_viewport().get_visible_rect().size
	var target_h: float = clampf(vp.y * OPEN_HEIGHT_FRACTION, OPEN_MIN_SIZE.y, vp.y - (OPEN_VPAD_TOP + OPEN_VPAD_BOTTOM))
	var target_w: float = clampf(OPEN_MIN_SIZE.x, OPEN_MIN_SIZE.x, vp.x - (OPEN_SIDE_MARGIN + 24.0))
	size = Vector2(target_w, target_h)

	_place_left(OPEN_SIDE_MARGIN, OPEN_VPAD_TOP, OPEN_VPAD_BOTTOM)
	move_to_front()

func _refresh_all() -> void:
	_refresh_balance()
	_refresh_map_base_from_board()
	_sync_local_applied_from_system()
	for id in _rows_by_id.keys():
		_refresh_row(String(id))
	_update_map_preview()

func _refresh_balance() -> void:
	if _balance_label:
		var bal: int = (Shards.get_balance() if Shards and Shards.has_method("get_balance") else 0)
		_balance_label.text = "Shards: %d" % bal

func _refresh_row(id: String) -> void:
	if not _rows_by_id.has(id) or Shards == null:
		return

	var widgets: Dictionary = _rows_by_id[id]
	var cost_lbl := widgets.get("cost", null) as Label
	var btn := widgets.get("btn", null) as Button

	var next_cost := Shards.get_meta_next_cost(id)
	if next_cost < 0:
		if cost_lbl: cost_lbl.text = "Maxed"
		if btn: btn.disabled = true
	else:
		if cost_lbl: cost_lbl.text = "Cost: %d" % next_cost
		if btn:
			var bal: int = Shards.get_balance()
			btn.disabled = (bal < next_cost)

	# Map rows: gate +/- by applied range (always enabled logic-wise)
	if String(id) in MAP_IDS:
		var owned := _owned(id)
		var applied := _applied(id)
		var minus_btn := widgets.get("minus", null) as Button
		var plus_btn  := widgets.get("plus", null)  as Button
		if minus_btn: minus_btn.disabled = (applied <= 0)
		if plus_btn:  plus_btn.disabled  = (applied >= owned)

	# Standard rows can still show “value” if present
	if widgets.has("value"):
		(widgets["value"] as Label).text = _preview_text_for(id)

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

# ============================================================
#                       Preview helpers
# ============================================================
func _refresh_map_base_from_board() -> void:
	var cols := FALLBACK_BASE_COLS
	var rows := FALLBACK_BASE_ROWS

	var boards := get_tree().get_nodes_in_group("TileBoard")
	if boards.size() > 0:
		var tb := boards[0]
		if tb.has_method("get"):
			var bx: Variant = tb.get("board_size_x")  # rows
			var bz: Variant = tb.get("board_size_z")  # cols
			if typeof(bx) == TYPE_INT and typeof(bz) == TYPE_INT:
				rows = int(bx)
				cols = int(bz)

	(_map_preview as MapPreview).set_base(cols, rows)

func _owned(id: String) -> int:
	return (Shards.get_meta_level(id) if Shards and Shards.has_method("get_meta_level") else 0)

func _applied(id: String) -> int:
	# Prefer Shards API if present, otherwise local fallback (default to owned)
	if Shards and Shards.has_method("get_meta_applied"):
		return int(Shards.get_meta_applied(id))
	return int(_applied_local.get(id, _owned(id)))

func _set_applied(id: String, val: int) -> void:
	_applied_local[id] = val
	if Shards and Shards.has_method("set_meta_applied"):
		Shards.set_meta_applied(id, val)
	_push_applied_to_powerups(id, val)

func _ensure_default_applied_to_owned(id: String) -> void:
	var owned := _owned(id)
	_set_applied(id, owned)

func _sync_local_applied_from_system() -> void:
	for id in MAP_IDS:
		if Shards and Shards.has_method("get_meta_applied"):
			_applied_local[id] = int(Shards.get_meta_applied(id))
		else:
			_applied_local[id] = _applied_local.get(id, _owned(id))

func _collect_applied_map() -> Dictionary:
	var out := {}
	for id in MAP_IDS:
		out[id] = _applied(id)
	return out

func _push_applied_to_powerups(id: String, val: int) -> void:
	var pu := get_node_or_null("/root/PowerUps")
	if pu == null: return
	# Best-effort: support either per-id or map-based override APIs if they exist
	if pu.has_method("set_applied_override"):
		pu.call("set_applied_override", id, val)
	elif pu.has_method("set_applied_override_map"):
		pu.call("set_applied_override_map", _collect_applied_map())

func _apply_powerups() -> void:
	var pu := get_node_or_null("/root/PowerUps")
	if pu:
		if pu.has_method("set_applied_override_map"):
			pu.call("set_applied_override_map", _collect_applied_map())
		if pu.has_method("_apply_shards_meta"):
			pu.call("_apply_shards_meta")

func _update_map_preview() -> void:
	if _map_preview == null:
		return
	# Use APPLIED values so the preview matches the toggle state.
	# Mapping preserved to match your rotated visual:
	var left_cols:  int = _applied("board_add_right")
	var right_cols: int = _applied("board_add_left")
	var top_rows:   int = _applied("board_push_back")
	(_map_preview as MapPreview).set_levels(left_cols, right_cols, top_rows)

func _preview_text_for(id: String) -> String:
	if PowerUps == null:
		return ""
	if String(id) in MAP_IDS:
		return ""  # minimal map rows: no value text

	match id:
		"turret_damage":
			return "%d → %d" % [PowerUps.turret_damage_value(), PowerUps.next_turret_damage_value()]
		"turret_rate":
			var info := PowerUps.turret_rate_info(null)
			var cur_sps := float(info.get("current_sps", 0.0))
			var next_interval := float(info.get("next_interval", 0.0))
			var next_sps := (0.0 if next_interval <= 0.0 else 1.0 / next_interval)
			return "%0.2f/s → %0.2f/s" % [cur_sps, next_sps]
		"turret_range":
			var r1 := PowerUps.turret_range_info(null)
			return "%0.1f → %0.1f" % [float(r1.get("current_range", 0.0)), float(r1.get("next_range", 0.0))]
		"crit_chance":
			return "%0.1f%% → %0.1f%%" % [PowerUps.crit_chance_value() * 100.0, PowerUps.next_crit_chance_value() * 100.0]
		"crit_mult":
			return "%0.2fx → %0.2fx" % [PowerUps.crit_mult_value(), PowerUps.next_crit_mult_value()]
		"turret_multishot":
			return "%0.0f%% → %0.0f%%" % [PowerUps.multishot_percent_value(), PowerUps.next_multishot_percent_value()]
		"base_max_hp":
			var h := PowerUps.health_max_info(null)
			return "%d → %d" % [int(h.get("current_max_hp", 0)), int(h.get("next_max_hp", 0))]
		"base_regen":
			var rg := PowerUps.health_regen_info(null)
			return "%0.2f → %0.2f hp/s" % [float(rg.get("current_regen_per_sec", 0.0)), float(rg.get("next_regen_per_sec", 0.0))]
		_:
			return ""

# ============================================================
#            Map toggle helpers (apply within owned)
# ============================================================
func _map_apply_delta(id: String, delta: int) -> void:
	var owned := _owned(id)
	var applied := _applied(id)
	var target := clampi(applied + delta, 0, owned)
	if target != applied:
		_set_applied(id, target)
		_apply_powerups()
		_refresh_all()

# ============================================================
#                 Dragging / Resizing interactions
# ============================================================
func _drag_rect() -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(size.x, DRAG_STRIP_H))

func _grip_rect() -> Rect2:
	return Rect2(size - Vector2(RESIZE_GRIP, RESIZE_GRIP), Vector2(RESIZE_GRIP, RESIZE_GRIP))

func _clamp_to_viewport(p: Vector2) -> Vector2:
	var vp := get_viewport().get_visible_rect().size
	var max_x := maxf(DRAG_MARGIN, vp.x - size.x - DRAG_MARGIN)
	var max_y := maxf(DRAG_MARGIN, vp.y - size.y - DRAG_MARGIN)
	return Vector2(clampf(p.x, DRAG_MARGIN, max_x), clampf(p.y, DRAG_MARGIN, max_y))

func _gui_input(event: InputEvent) -> void:
	# Cursor feedback
	if event is InputEventMouseMotion:
		if _grip_rect().has_point(event.position):
			mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
		elif _drag_rect().has_point(event.position) and not _resizing:
			mouse_default_cursor_shape = Control.CURSOR_MOVE
		else:
			mouse_default_cursor_shape = Control.CURSOR_ARROW

	# Begin drag/resize
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _grip_rect().has_point(event.position):
				_resizing = true
				_resize_mouse_start = event.position
				_resize_start_size = size
				accept_event()
			elif _drag_rect().has_point(event.position):
				_dragging = true
				_drag_mouse_start = get_viewport().get_mouse_position()
				_drag_panel_start = position
				accept_event()
		else:
			_resizing = false
			_dragging = false

	# Perform drag/resize
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _resizing:
			var delta: Vector2 = mm.position - _resize_mouse_start
			var vp: Vector2 = get_viewport().get_visible_rect().size
			size = Vector2(
				clampf(_resize_start_size.x + delta.x, OPEN_MIN_SIZE.x, vp.x - 2.0 * OPEN_SIDE_MARGIN),
				clampf(_resize_start_size.y + delta.y, OPEN_MIN_SIZE.y, vp.y - (OPEN_VPAD_TOP + OPEN_VPAD_BOTTOM))
			)
			accept_event()
		elif _dragging:
			var cur_mouse: Vector2 = get_viewport().get_mouse_position()
			var delta2: Vector2 = cur_mouse - _drag_mouse_start
			position = _clamp_to_viewport(_drag_panel_start + delta2)
			accept_event()
