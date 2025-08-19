extends Control

const CENTER_PATH := ^"CenterContainer"

func _ready() -> void:
	_apply_layout()

func _apply_layout() -> void:
	_full_rect(self)
	var center := get_node_or_null(CENTER_PATH) as Control
	if center:
		_full_rect(center)

func _full_rect(c: Control) -> void:
	c.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	c.offset_left = 0
	c.offset_top = 0
	c.offset_right = 0
	c.offset_bottom = 0
