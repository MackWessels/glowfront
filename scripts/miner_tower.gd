extends Node3D

# ---- Build / economy ----
@export var build_cost: int = 20
@export var minerals_path: NodePath
@export var sell_refund_percent: int = 60

# ---- Income ----
@export var minerals_per_tick: int = 1
@export var tick_interval: float = 2.0
@export var initial_delay: float = 0.0

# ---- Optional nodes ----
@export var click_body_path: NodePath    # StaticBody3D for right-click

# ---- TileBoard context ----
@export var tile_board_path: NodePath
var _tile_board: Node = null
var _tile_cell: Vector2i = Vector2i(-9999, -9999)
func set_tile_context(board: Node, cell: Vector2i) -> void:
	_tile_board = board
	_tile_cell  = cell

# ---- Runtime ----
var _minerals: Node = null
var _running: bool = false
var _generated_total: int = 0
var _spent_local: int = 0

# ---- Stats UI ----
var _stats_layer: CanvasLayer = null
var _stats_window: AcceptDialog = null
var _stats_label: Label = null
var _ui_refresh_accum: float = 0.0

signal build_paid(cost: int)
signal build_denied(cost: int)

# ========================== Lifecycle ==========================
func _ready() -> void:
	add_to_group("building")
	add_to_group("generator")

	_resolve_minerals()
	if tile_board_path != NodePath(""):
		_tile_board = get_node_or_null(tile_board_path)

	# right-click hookup
	var click_body := (get_node_or_null(click_body_path) as StaticBody3D) if click_body_path != NodePath("") else (find_child("StaticBody3D", true, false) as StaticBody3D)
	if click_body and not click_body.is_connected("input_event", Callable(self, "_on_clickbody_input")):
		click_body.input_event.connect(_on_clickbody_input)

	# pay to build
	if not _attempt_build_payment():
		build_denied.emit(build_cost)
		queue_free()
		return
	_spent_local += max(0, build_cost)
	build_paid.emit(build_cost)

	_start_loop()

func _process(dt: float) -> void:
	if _stats_window != null and _stats_window.visible:
		_ui_refresh_accum += dt
		if _ui_refresh_accum > 0.25:
			_ui_refresh_accum = 0.0
			_refresh_stats_text()

func _exit_tree() -> void:
	_running = false

# ========================= Generator ===========================
func _start_loop() -> void:
	if _running: return
	_running = true
	await get_tree().process_frame
	if initial_delay > 0.0:
		await get_tree().create_timer(max(0.0, initial_delay)).timeout
	while _running:
		_do_pulse()
		await get_tree().create_timer(max(0.05, tick_interval)).timeout

func _do_pulse() -> void:
	var amt: int = max(0, minerals_per_tick)
	if amt <= 0: return
	_add_minerals(amt)
	_generated_total += amt

# ====================== Economy helpers ========================
func _resolve_minerals() -> void:
	if minerals_path != NodePath(""):
		_minerals = get_node_or_null(minerals_path)
	if _minerals == null:
		_minerals = get_node_or_null("/root/Minerals")
	if _minerals == null:
		var root := get_tree().root
		if root != null:
			_minerals = root.find_child("Minerals", true, false)

func _attempt_build_payment() -> bool:
	if build_cost <= 0: return true
	return _try_spend(build_cost)

func _try_spend(amount: int) -> bool:
	if amount <= 0 or _minerals == null:
		return amount <= 0

	# Preferred API paths
	if _minerals.has_method("spend"):
		return bool(_minerals.call("spend", amount))

	var ok: bool = false
	if _minerals.has_method("can_afford"):
		ok = bool(_minerals.call("can_afford", amount))

	if ok:
		if _minerals.has_method("set_amount"):
			var cur: int = _get_balance()
			_minerals.call("set_amount", max(0, cur - amount))
			return true
		# Fallback: direct int property
		var v: Variant = _minerals.get("minerals")
		if typeof(v) == TYPE_INT:
			var cur2: int = int(v)
			_minerals.set("minerals", max(0, cur2 - amount))
			return true

	return false


func _add_minerals(amount: int) -> void:
	if amount <= 0 or _minerals == null:
		return
	# Preferred API paths
	if _minerals.has_method("add"):
		_minerals.call("add", amount)
		return
	if _minerals.has_method("set_amount"):
		var cur: int = _get_balance()
		_minerals.call("set_amount", cur + amount)
		return
	# Fallback: direct int property
	var v: Variant = _minerals.get("minerals")
	if typeof(v) == TYPE_INT:
		var cur2: int = int(v)
		_minerals.set("minerals", cur2 + amount)


func _get_balance() -> int:
	if _minerals == null:
		return 0
	if _minerals.has_method("balance"):
		return int(_minerals.call("balance"))
	var v: Variant = _minerals.get("minerals")
	if typeof(v) == TYPE_INT:
		return int(v)
	return 0

# ======================= Sell / Free tile ======================
func _on_sell_pressed() -> void:
	var refund := int(round(float(_spent_local) * float(sell_refund_percent) / 100.0))
	_add_minerals(refund)
	_free_tile_then_die()

func _free_tile_then_die() -> void:
	_running = false
	if _tile_board == null and tile_board_path != NodePath(""):
		_tile_board = get_node_or_null(tile_board_path)
	if _tile_board == null:
		var b := get_tree().root.find_child("TileBoard", true, false)
		if b is Node: _tile_board = b

	var cell := _tile_cell
	if (cell.x <= -9999 or cell.y <= -9999) and _tile_board and _tile_board.has_method("world_to_cell"):
		cell = _tile_board.call("world_to_cell", global_transform.origin)

	if _tile_board:
		if _tile_board.has_method("free_tile"):
			_tile_board.call("free_tile", cell)
		else:
			var tile: Node = null
			if _tile_board.has("tiles"):
				var d: Variant = _tile_board.get("tiles")
				if typeof(d) == TYPE_DICTIONARY:
					var dict: Dictionary = d
					if dict.has(cell):
						tile = dict[cell]
			if tile and tile.has_method("repair_tile"):
				tile.call("repair_tile")

		if _tile_board.has_method("_recompute_flow"): _tile_board.call("_recompute_flow")
		if _tile_board.has_method("_emit_path_changed"): _tile_board.call("_emit_path_changed")
		elif _tile_board.has_signal("global_path_changed"): _tile_board.emit_signal("global_path_changed")

	queue_free()

# =================== Right-click stats popup ===================
func _on_clickbody_input(_camera: Node, event: InputEvent, _pos: Vector3, _norm: Vector3, _shape: int) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
		var dlg := _ensure_stats_dialog()
		if dlg.visible: dlg.hide()
		else:
			_refresh_stats_text()
			var vp := get_viewport().get_visible_rect().size
			dlg.size = dlg.size.clamp(Vector2i(300, 180), Vector2i(vp.x - 80, vp.y - 80))
			dlg.popup_centered()

func toggle_stats_panel() -> void:
	var dlg := _ensure_stats_dialog()
	if dlg.visible: dlg.hide()
	else:
		_refresh_stats_text()
		dlg.popup_centered()

func _ensure_stats_dialog() -> AcceptDialog:
	if _stats_window != null: return _stats_window

	if _stats_layer == null:
		_stats_layer = CanvasLayer.new()
		_stats_layer.layer = 200
		_stats_layer.process_mode = Node.PROCESS_MODE_ALWAYS
		get_tree().root.add_child(_stats_layer)

	var dlg := AcceptDialog.new()
	dlg.title = "Miner Tower"
	dlg.unresizable = false
	dlg.min_size = Vector2i(320, 180)
	dlg.size = Vector2i(360, 200)
	dlg.exclusive = false
	dlg.always_on_top = true
	dlg.process_mode = Node.PROCESS_MODE_ALWAYS
	dlg.dialog_hide_on_ok = true
	dlg.confirmed.connect(Callable(dlg, "hide"))
	dlg.close_requested.connect(Callable(dlg, "hide"))
	dlg.canceled.connect(Callable(dlg, "hide"))

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	dlg.add_child(root)

	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	root.add_child(margin)

	_stats_label = Label.new()
	_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stats_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stats_label.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_stats_label.custom_minimum_size = Vector2(300, 0)
	margin.add_child(_stats_label)

	dlg.add_button("Sell", false, "sell")
	dlg.custom_action.connect(func(name):
		if name == "sell":
			_on_sell_pressed()
			dlg.hide()
	)
	dlg.get_ok_button().text = "Close"

	_stats_layer.add_child(dlg)
	_stats_window = dlg
	return dlg

func _refresh_stats_text() -> void:
	if _stats_label == null: return
	var rate_per_sec: float = float(minerals_per_tick) / float(max(0.0001, tick_interval))
	var refund_preview := int(round(float(_spent_local) * float(sell_refund_percent) / 100.0))

	var s := "Income\n"
	s += "  +" + str(minerals_per_tick) + " every " + String.num(tick_interval, 2) + "s (" + String.num(rate_per_sec, 2) + "/s)\n"
	s += "  Generated total: " + str(_generated_total) + "\n"
	s += "\nSell refund: " + str(refund_preview) + " (" + str(sell_refund_percent) + "% of local spend)"
	_stats_label.text = s
