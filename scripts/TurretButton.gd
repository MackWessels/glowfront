extends Button

@export var action_name: String = "turret"  # turret, wall, miner, mortar, tesla, shard_miner, sniper
@export var show_cost: bool = true
@export var cost_prefix: String = "$ "
@export var default_cost: int = 0          # fallback if TileBoard doesn’t expose a cost

# --- visuals (unchanged) ---
@export var on_bg: Color = Color(0.20, 0.60, 1.00, 1.0)
@export var off_bg: Color = Color(0.12, 0.13, 0.15, 1.0)
@export var on_border: Color = Color(1, 1, 1, 0.95)
@export var off_border: Color = Color(1, 1, 1, 0.18)
@export var on_font: Color = Color(1, 1, 1, 1.0)
@export var off_font: Color = Color(0.86, 0.89, 0.93, 1.0)
@export var corner_radius: int = 8
@export var border_w_off: int = 1
@export var border_w_on: int = 2
@export var hover_boost: float = 0.06
@export var pulse_when_armed: bool = false

var _mgr: Node = null
var _tileboard: Node = null
var _base_label: String = ""

var _sb_off_normal: StyleBoxFlat
var _sb_off_hover: StyleBoxFlat
var _sb_on_normal: StyleBoxFlat
var _sb_on_hover: StyleBoxFlat
var _sb_focus: StyleBoxFlat

var _syncing_from_manager := false

func _ready() -> void:
	toggle_mode = true
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_make_styles()
	disconnect_old_handlers()

	_mgr = get_tree().root.find_child("BuildManager", true, false)
	_tileboard = _find_tileboard()

	if not is_connected("toggled", Callable(self, "_on_toggled")):
		toggled.connect(_on_toggled)
	if _mgr and _mgr.has_signal("build_mode_changed"):
		_mgr.build_mode_changed.connect(_on_build_mode_changed)

	_base_label = (text.strip_edges() if text != "" else action_name.capitalize())

	# If costs can change at runtime, refresh label on these:
	if typeof(PowerUps) != TYPE_NIL and PowerUps.has_signal("changed"):
		PowerUps.changed.connect(func(): _refresh_label())
	if typeof(Economy) != TYPE_NIL and Economy.has_signal("balance_changed"):
		Economy.balance_changed.connect(func(_b:int): _refresh_label())

	_apply_visual(button_pressed)
	_refresh_label()

func disconnect_old_handlers() -> void:
	if is_connected("button_down", Callable(self, "_on_button_down")):
		disconnect("button_down", Callable(self, "_on_button_down"))
	if is_connected("pressed", Callable(self, "_on_pressed")):
		disconnect("pressed", Callable(self, "_on_pressed"))

# ----------------- toggle / sync -----------------
func _on_toggled(pressed: bool) -> void:
	if _syncing_from_manager:
		return
	if _mgr == null:
		_apply_visual(pressed)
		return
	if pressed:
		_mgr.call("arm_build", action_name)
		_mgr.call("set_sticky", true)
	else:
		_mgr.call("set_sticky", false)
		_mgr.call("cancel_build")
	_apply_visual(pressed)

func _on_build_mode_changed(armed_action: String, sticky: bool) -> void:
	var pressed := (sticky and armed_action == action_name)
	_syncing_from_manager = true
	if has_method("set_pressed_no_signal"):
		set_pressed_no_signal(pressed)
	else:
		button_pressed = pressed
	_syncing_from_manager = false
	_apply_visual(pressed)

# ----------------- label / cost -----------------
func _refresh_label() -> void:
	if not show_cost:
		text = _base_label
		return
	var c := _current_cost()
	text = "%s\n%s%d" % [_base_label, cost_prefix, c]

func _current_cost() -> int:
	var base := _lookup_base_cost()
	if typeof(PowerUps) != TYPE_NIL and PowerUps.has_method("modified_cost"):
		return int(PowerUps.modified_cost(action_name, base))
	return base

func _lookup_base_cost() -> int:
	if _tileboard == null:
		return max(0, default_cost)

	# Prefer helper methods if the board provides them
	var method_names := [
		"get_action_cost", "get_cost_for_action", "get_build_cost", "cost_for"
	]
	for m in method_names:
		if _tileboard.has_method(m):
			var v: Variant = _tileboard.call(m, action_name)
			if typeof(v) == TYPE_INT:
				return int(v)

	# Try direct property: "<action>_cost"
	var key := action_name + "_cost"
	var vprop: Variant = _tileboard.get(key)
	if typeof(vprop) == TYPE_INT:
		return int(vprop)

	# Legacy/explicit property names for all known actions (ADDED sniper)
	var legacy := {
		"turret":       "turret_cost",
		"mortar":       "mortar_cost",
		"wall":         "wall_cost",
		"miner":        "miner_cost",
		"tesla":        "tesla_cost",
		"shard_miner":  "shard_miner_cost",
		"sniper":       "sniper_cost",   # NEW
	}
	if legacy.has(action_name):
		var lv: Variant = _tileboard.get(String(legacy[action_name]))
		if typeof(lv) == TYPE_INT:
			return int(lv)

	return max(0, default_cost)

func _find_tileboard() -> Node:
	var boards := get_tree().get_nodes_in_group("TileBoard")
	if boards.size() > 0:
		return boards[0]
	return get_tree().root.find_child("TileBoard", true, false)

# ----------------- visuals -----------------
func _make_styles() -> void:
	_sb_off_normal = _style(off_bg, off_border, border_w_off)
	_sb_off_hover  = _style(off_bg.lerp(Color(1,1,1,1), hover_boost), off_border, border_w_off)
	_sb_on_normal  = _style(on_bg, on_border, border_w_on)
	_sb_on_hover   = _style(on_bg.lerp(Color(1,1,1,1), hover_boost + 0.02), on_border, border_w_on)
	_sb_focus = _style(Color(0,0,0,0), on_border, 1); _sb_focus.draw_center = false

func _style(bg: Color, border: Color, bw: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(bw)
	sb.border_color = border
	sb.corner_radius_top_left = corner_radius
	sb.corner_radius_top_right = corner_radius
	sb.corner_radius_bottom_left = corner_radius
	sb.corner_radius_bottom_right = corner_radius
	sb.set_content_margin_all(8.0)
	sb.shadow_size = 0
	sb.shadow_color = Color(0,0,0,0)
	return sb

func _apply_visual(pressed: bool) -> void:
	if pressed:
		add_theme_stylebox_override("normal", _sb_on_normal)
		add_theme_stylebox_override("hover", _sb_on_hover)
		add_theme_stylebox_override("pressed", _sb_on_normal)
		add_theme_stylebox_override("hover_pressed", _sb_on_hover)
	else:
		add_theme_stylebox_override("normal", _sb_off_normal)
		add_theme_stylebox_override("hover", _sb_off_hover)
		add_theme_stylebox_override("pressed", _sb_off_hover)
		add_theme_stylebox_override("hover_pressed", _sb_off_hover)

	add_theme_stylebox_override("focus", _sb_focus)

	var fc := (on_font if pressed else off_font)
	add_theme_color_override("font_color", fc)
	add_theme_color_override("font_hover_color", fc)
	add_theme_color_override("font_pressed_color", fc)
	add_theme_color_override("font_focus_color", fc)

	if pressed and pulse_when_armed:
		var tw := create_tween()
		tw.tween_property(self, "modulate", Color(1,1,1,1), 0.0)
		tw.tween_property(self, "modulate", Color(1,1,1,0.88), 0.06)
		tw.tween_property(self, "modulate", Color(1,1,1,1.0), 0.12)
