extends Button
@export var action_name: String = "turret"  # "turret", "wall", "mortar"

var _mgr: Node = null

func _ready() -> void:
	_mgr = get_tree().root.find_child("BuildManager", true, false)
	# Start drag on press-and-hold
	button_down.connect(_on_button_down)
	# (optional) if you had pressed connected, disconnect it or remove its handler

func _on_button_down() -> void:
	if _mgr:
		_mgr.call("arm_build", action_name)  # arm + _drag_active auto-detected

func _on_pressed() -> void:
	if _mgr:
		print("[TurretButton] pressed -> arm ", action_name)
		_mgr.call("arm_build", action_name)
