extends Node

@export_file("*.tscn") var main_menu_path := "res://MainMenu.tscn"
@onready var game_over: Control = $GameOver
@onready var retry_btn: Button  = $GameOver/CenterContainer/Panel/MarginContainer/VBoxContainer/RetryButton
@onready var menu_btn: Button   = $GameOver/CenterContainer/Panel/MarginContainer/VBoxContainer/MenuButton

func _ready() -> void:
	Health.reset()
	Health.defeated.connect(_on_defeated)
	game_over.process_mode = Node.PROCESS_MODE_ALWAYS
	retry_btn.pressed.connect(_on_retry_pressed)
	menu_btn.pressed.connect(_on_menu_pressed)

func _on_defeated() -> void:
	game_over.visible = true
	game_over.modulate.a = 0.0
	var t := game_over.create_tween()
	t.tween_property(game_over, "modulate:a", 1.0, 0.25)
	await t.finished
	get_tree().paused = true

func _on_retry_pressed() -> void:
	get_tree().paused = false
	var cur := get_tree().current_scene
	var path := cur.scene_file_path if cur else ""
	if path != "":
		get_tree().change_scene_to_file(path)

func _on_menu_pressed() -> void:
	get_tree().paused = false
	if not ResourceLoader.exists(main_menu_path):
		push_error("Main menu scene not found: " + main_menu_path)
		return
	get_tree().change_scene_to_file(main_menu_path)
