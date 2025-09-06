# ToolbarBuildButton.gd
extends TextureButton
@export var action: String = "turret"                  # "turret","wall","miner","mortar"
@export var build_manager_path: NodePath                # point to BuildManager
@export var drop_layer_path: NodePath                   # point to BuildDropLayer (optional, for capture)

func _ready() -> void:
	pressed.connect(_on_pressed)          # quick-click places on release
	button_down.connect(_on_button_down)  # click-and-hold starts drag

func _on_button_down() -> void:
	var dl := get_node_or_null(drop_layer_path)
	if dl and dl.has_method("enable_drag_capture"):
		dl.call("enable_drag_capture")

func _on_pressed() -> void:
	var bm := get_node_or_null(build_manager_path)
	if bm and bm.has_method("arm_build"):
		bm.call("arm_build", action)

func get_drag_data(at_position: Vector2) -> Variant:
	# Start a real Control drag so BuildDropLayer receives it.
	var bm := get_node_or_null(build_manager_path)
	if bm and bm.has_method("begin_drag"):
		bm.call("begin_drag", action)

	# Simple preview (use your icon if you have one)
	var preview := ColorRect.new()
	preview.color = Color(1,1,1,0.15)
	preview.custom_minimum_size = Vector2(32, 32)
	set_drag_preview(preview)

	return {"action": action}
