extends Camera3D

@export var focus_node: NodePath                 # e.g., TileBoard or a Pivot
@export var focus_point: Vector3 = Vector3.ZERO  # used if focus_node is empty

# Orbit state
@export var distance: float = 20.0
@export var min_distance: float = 6.0
@export var max_distance: float = 80.0
@export var yaw_deg: float = 45.0
@export var pitch_deg: float = -45.0
@export var min_pitch_deg: float = -85.0
@export var max_pitch_deg: float = -10.0

# Feel
@export var rotate_sensitivity: float = 0.3    
@export var zoom_step: float = 2.0              
@export var keyboard_rotate_speed: float = 90.0  

# Panning 
@export var pan_speed: float = 20.0
@export var pan_fast_mult: float = 2.5         
@export var pan_slow_mult: float = 0.5          

var _rotating := false
var _pan_offset: Vector3 = Vector3.ZERO    

func _ready() -> void:
	current = true

func _process(delta: float) -> void:
	# Q/E yaw
	if Input.is_key_pressed(KEY_Q): yaw_deg -= keyboard_rotate_speed * delta
	if Input.is_key_pressed(KEY_E): yaw_deg += keyboard_rotate_speed * delta

	_pan_with_keyboard(delta)
	_clamp_state()
	_update_transform()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_rotating = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_apply_zoom(-zoom_step)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_apply_zoom(zoom_step)

	elif event is InputEventMouseMotion and _rotating:
		yaw_deg   += event.relative.x * rotate_sensitivity
		pitch_deg += event.relative.y * rotate_sensitivity

func _pan_with_keyboard(delta: float) -> void:
	var speed := pan_speed
	if Input.is_key_pressed(KEY_SHIFT): speed *= pan_fast_mult
	elif Input.is_key_pressed(KEY_CTRL): speed *= pan_slow_mult

	var v := Vector2.ZERO
	# WASD
	if Input.is_key_pressed(KEY_S): v.y -= 1
	if Input.is_key_pressed(KEY_W): v.y += 1
	if Input.is_key_pressed(KEY_A): v.x -= 1
	if Input.is_key_pressed(KEY_D): v.x += 1
	
	# Arrows
	if Input.is_key_pressed(KEY_DOWN): v.y -= 1
	if Input.is_key_pressed(KEY_UP): v.y += 1
	if Input.is_key_pressed(KEY_LEFT): v.x -= 1
	if Input.is_key_pressed(KEY_RIGHT): v.x += 1

	if v == Vector2.ZERO: return
	v = v.normalized()

	# Move in camera's local X/Z plane
	var right := global_transform.basis.x; right.y = 0; right = right.normalized()
	var fwd   := -global_transform.basis.z; fwd.y = 0;   fwd   = fwd.normalized()

	_pan_offset += (right * v.x + fwd * v.y) * speed * delta

func _apply_zoom(amount: float) -> void:
	if projection == PROJECTION_ORTHOGONAL:
		size = clamp(size + amount * 0.25, 1.0, 200.0)
	distance += amount

func _clamp_state() -> void:
	pitch_deg = clamp(pitch_deg, min_pitch_deg, max_pitch_deg)
	distance  = clamp(distance,  min_distance, max_distance)
	yaw_deg   = fmod(yaw_deg, 360.0)

func _get_focus() -> Vector3:
	var base := focus_point
	if focus_node != NodePath():
		var n := get_node_or_null(focus_node)
		if n is Node3D:
			base = (n as Node3D).global_position
	return base + _pan_offset

func _update_transform() -> void:
	var center := _get_focus()
	var yaw := deg_to_rad(yaw_deg)
	var pitch := deg_to_rad(pitch_deg)

	var dir := Vector3(
		cos(pitch) * cos(yaw),
		sin(pitch),
		cos(pitch) * sin(yaw)
	).normalized()

	global_position = center - dir * distance
	look_at(center, Vector3.UP)
