extends Control

@export_file("*.tscn") var main_scene_path: String = "res://Main.tscn"
@onready var play_btn: Button   = $CenterContainer/Panel/MarginContainer/VBoxContainer/PlayButton
@onready var quit_btn: Button   = $CenterContainer/Panel/MarginContainer/VBoxContainer/QuitButton
@onready var fade: ColorRect    = $Fade

func _ready() -> void:
	anchor_left = 0.0;  anchor_top = 0.0
	anchor_right = 1.0; anchor_bottom = 1.0
	offset_left = 0; offset_top = 0; offset_right = 0; offset_bottom = 0

	play_btn.pressed.connect(_on_start_pressed)
	quit_btn.pressed.connect(_on_quit_pressed)

	fade.modulate.a = 1.0
	create_tween().tween_property(fade, "modulate:a", 0.0, 0.35)

func _unhandled_input(event: InputEvent) -> void:
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
