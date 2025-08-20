extends Control

@export_file("*.tscn") var main_scene_path: String = "res://Main.tscn"
@export var upgrades_panel_path: NodePath   # assign this to ShardUpgradesPane in the Inspector

@onready var play_btn: Button      = $CenterContainer/Panel/MarginContainer/VBoxContainer/PlayButton
@onready var quit_btn: Button      = $CenterContainer/Panel/MarginContainer/VBoxContainer/QuitButton
@onready var upgrades_btn: Button  = $CenterContainer/Panel/MarginContainer/VBoxContainer/UpgradesButton
@onready var fade: ColorRect       = $Fade

var upgrades_panel: Control = null

func _ready() -> void:
	# full-screen anchors
	anchor_left = 0.0;  anchor_top = 0.0
	anchor_right = 1.0; anchor_bottom = 1.0
	offset_left = 0; offset_top = 0; offset_right = 0; offset_bottom = 0

	# fade should not eat clicks
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# connect buttons
	play_btn.pressed.connect(_on_start_pressed)
	quit_btn.pressed.connect(_on_quit_pressed)
	upgrades_btn.pressed.connect(_on_upgrades_pressed)

	# resolve upgrades panel via exported NodePath (drag/drop in Inspector)
	if upgrades_panel_path != NodePath():
		upgrades_panel = get_node_or_null(upgrades_panel_path) as Control
	# fallback by name if not set
	if upgrades_panel == null:
		upgrades_panel = find_child("ShardUpgradesPane", true, false) as Control
	if upgrades_panel:
		upgrades_panel.hide()

	# fade in
	fade.modulate.a = 1.0
	create_tween().tween_property(fade, "modulate:a", 0.0, 0.35)

func _on_upgrades_pressed() -> void:
	if upgrades_panel == null:
		return
	if upgrades_panel.visible:
		upgrades_panel.hide()
	elif upgrades_panel.has_method("open"):
		upgrades_panel.call("open")  # shard_upgrades_panel.gd
	else:
		upgrades_panel.show()

func _unhandled_input(event: InputEvent) -> void:
	# Esc closes the upgrades panel if open
	if upgrades_panel and upgrades_panel.visible and event.is_action_pressed("ui_cancel"):
		upgrades_panel.hide()
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("ui_accept") and not play_btn.disabled:
		_on_start_pressed()
	elif event.is_action_pressed("ui_cancel") and OS.has_feature("pc"):
		_on_quit_pressed()

func _on_start_pressed() -> void:
	play_btn.disabled = true
	quit_btn.disabled = true
	var t := create_tween()
	t.tween_property(fade, "modulate:a", 1.0, 0.25)
	t.tween_callback(Callable(self, "_go"))

func _go() -> void:
	get_tree().change_scene_to_file(main_scene_path)

func _on_quit_pressed() -> void:
	if OS.has_feature("pc"):
		get_tree().quit()
