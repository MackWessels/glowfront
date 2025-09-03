extends Button
# Starts drag on mouse down; BuildManager handles the drop on release.

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

	# Resolve manager: explicit path → by group → by name
	if build_manager_path != NodePath(""):
		_mgr = get_node_or_null(build_manager_path)
	if _mgr == null:
		var by_group := get_tree().get_nodes_in_group("build_manager")
		if by_group.size() > 0:
			_mgr = by_group[0]
	if _mgr == null:
		_mgr = get_tree().root.find_child("BuildManager", true, false)

	button_down.connect(_on_button_down)  # begin drag immediately

func _on_button_down() -> void:
	print("[TurretButton] button_down; mgr =", _mgr)
	get_viewport().set_input_as_handled()   # don't leak this press to 3D
	if _mgr and _mgr.has_method("begin_drag"):
		_mgr.call("begin_drag", action_name)
	else:
		push_error("[TurretButton] BuildManager not found. Set build_manager_path, or add your manager to group 'build_manager', or name it 'BuildManager'.")
