extends Button
# Starts the drag on mouse down; BuildManager decides where to drop on release.

@export var action_name: String = "turret"
@export var build_manager_path: NodePath
@export var default_text: String = "Turret"
@export var min_size: Vector2i = Vector2i(120, 36)

var _mgr: Node = null

func _ready() -> void:
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(min_size.x, min_size.y)
	if text == "":
		text = default_text

	if build_manager_path != NodePath(""):
		_mgr = get_node_or_null(build_manager_path)

	button_down.connect(_on_button_down)  # begin drag immediately

func _on_button_down() -> void:
	# Eat the initial press so it doesn’t leak into world input
	get_viewport().set_input_as_handled()
	if _mgr and _mgr.has_method("begin_drag"):
		_mgr.call("begin_drag", action_name)
