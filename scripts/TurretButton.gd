extends Button

@export var action_name: String = "turret"  # turret, wall, miner, mortar, tesla

# --- Minimal, clean visuals you can tune in the Inspector ---
@export var on_bg: Color = Color(0.20, 0.60, 1.00, 1.0)   # ON fill
@export var off_bg: Color = Color(0.12, 0.13, 0.15, 1.0)  # OFF fill
@export var on_border: Color = Color(1, 1, 1, 0.95)
@export var off_border: Color = Color(1, 1, 1, 0.18)
@export var on_font: Color = Color(1, 1, 1, 1.0)
@export var off_font: Color = Color(0.86, 0.89, 0.93, 1.0)
@export var corner_radius: int = 8
@export var border_w_off: int = 1
@export var border_w_on: int = 2
@export var hover_boost: float = 0.06      # how much to lighten on hover (0..0.2 recommended)
@export var pulse_when_armed: bool = false # off by default for a “clean” look

var _mgr: Node = null

# cached styleboxes
var _sb_off_normal: StyleBoxFlat
var _sb_off_hover: StyleBoxFlat
var _sb_on_normal: StyleBoxFlat
var _sb_on_hover: StyleBoxFlat
var _sb_focus: StyleBoxFlat

func _ready() -> void:
	toggle_mode = true
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_make_styles()
	disconnect_old_handlers()

	_mgr = get_tree().root.find_child("BuildManager", true, false)
	if not is_connected("toggled", Callable(self, "_on_toggled")):
		toggled.connect(_on_toggled)
	if _mgr and _mgr.has_signal("build_mode_changed"):
		_mgr.build_mode_changed.connect(_on_build_mode_changed)

	_apply_visual(button_pressed)

func disconnect_old_handlers() -> void:
	if is_connected("button_down", Callable(self, "_on_button_down")):
		disconnect("button_down", Callable(self, "_on_button_down"))
	if is_connected("pressed", Callable(self, "_on_pressed")):
		disconnect("pressed", Callable(self, "_on_pressed"))

func _on_toggled(pressed: bool) -> void:
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
	button_pressed = pressed
	_apply_visual(pressed)

# ----------------- visuals -----------------
func _make_styles() -> void:
	_sb_off_normal = _style(off_bg, off_border, border_w_off)
	_sb_off_hover  = _style(off_bg.lerp(Color(1,1,1,1), hover_boost), off_border, border_w_off)

	_sb_on_normal  = _style(on_bg, on_border, border_w_on)
	_sb_on_hover   = _style(on_bg.lerp(Color(1,1,1,1), hover_boost + 0.02), on_border, border_w_on)

	_sb_focus = _style(Color(0,0,0,0), on_border, 1)
	_sb_focus.draw_center = false

func _style(bg: Color, border: Color, bw: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(bw)          # no drop shadow; clean outline only
	sb.border_color = border
	sb.corner_radius_top_left = corner_radius
	sb.corner_radius_top_right = corner_radius
	sb.corner_radius_bottom_left = corner_radius
	sb.corner_radius_bottom_right = corner_radius
	sb.set_content_margin_all(8.0)
	sb.shadow_size = 0                   # ensure no shadow
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
