extends Button
@export var action_name: String = "turret"  # turret, wall, miner, mortar, tesla
var _mgr: Node = null

func _ready() -> void:
	toggle_mode = true
	disconnect_old_handlers()
	_mgr = get_tree().root.find_child("BuildManager", true, false)
	if not is_connected("toggled", Callable(self, "_on_toggled")):
		toggled.connect(_on_toggled)
	if _mgr and _mgr.has_signal("build_mode_changed"):
		_mgr.build_mode_changed.connect(_on_build_mode_changed)

func disconnect_old_handlers() -> void:
	if is_connected("button_down", Callable(self, "_on_button_down")):
		disconnect("button_down", Callable(self, "_on_button_down"))
	if is_connected("pressed", Callable(self, "_on_pressed")):
		disconnect("pressed", Callable(self, "_on_pressed"))

func _on_toggled(pressed: bool) -> void:
	if _mgr == null: return
	if pressed:
		_mgr.call("arm_build", action_name)
		_mgr.call("set_sticky", true)
	else:
		_mgr.call("set_sticky", false)
		_mgr.call("cancel_build")

func _on_build_mode_changed(armed_action: String, sticky: bool) -> void:
	button_pressed = (sticky and armed_action == action_name)
