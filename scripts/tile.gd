extends StaticBody3D

@export var turret_scene: PackedScene
@export var wall_scene: PackedScene
@export var placement_menu: PopupMenu
@onready var crack_overlay = $CrackOverlay
@onready var _tile_mesh: MeshInstance3D = $"TileMesh"
var _orig_mat: Material = null

# --- Pending (blue) overlay ---
const PENDING_COLOR := Color(0.25, 0.55, 1.0)
var _pending_mat: StandardMaterial3D = null
var _pending_saved_mat: Material = null
var _pending_on: bool = false

func _get_pending_mat() -> StandardMaterial3D:
	if _pending_mat == null:
		_pending_mat = StandardMaterial3D.new()
		_pending_mat.albedo_color = PENDING_COLOR
		_pending_mat.metallic = 0.0
		_pending_mat.roughness = 1.0
	return _pending_mat

# Toggle temporary blue overlay; restores whatever was there (orig or red)
func set_pending_blue(on: bool) -> void:
	if not is_instance_valid(_tile_mesh):
		return
	if on:
		if not _pending_on:
			_pending_saved_mat = _tile_mesh.material_override
			_tile_mesh.material_override = _get_pending_mat()
			_pending_on = true
	else:
		if _pending_on:
			_tile_mesh.material_override = _pending_saved_mat
			_pending_saved_mat = null
			_pending_on = false

# --- Grid/meta state ---
var has_turret = false
var grid_x: int
var grid_z: int

var grid_position: Vector2i:
	get: return Vector2i(grid_x, grid_z)
	set(value):
		grid_x = value.x
		grid_z = value.y

var tile_board: Node
var is_wall = false
var blocked := false
var is_broken := false
var placed_object: Node = null

func _ready() -> void:
	if is_instance_valid(_tile_mesh) and _orig_mat == null:
		_orig_mat = _tile_mesh.material_override

func _input_event(camera: Camera3D, event: InputEvent, position: Vector3, normal: Vector3, shape_idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		if tile_board:
			tile_board.active_tile = self
		if placement_menu:
			placement_menu.clear()
			if is_broken:
				placement_menu.add_item("Repair", 2)
			elif not has_turret and not is_wall:
				placement_menu.add_item("Place Turret", 0)
				placement_menu.add_item("Place Wall", 1)
			if placement_menu.item_count > 0:
				placement_menu.position = get_viewport().get_mouse_position()
				placement_menu.popup()

func place_turret():
	if is_broken or turret_scene == null:
		return
	_clear_existing_object()
	var turret = turret_scene.instantiate()
	add_child(turret)
	if turret is Node3D:
		turret.global_transform = global_transform
	placed_object = turret
	has_turret = true
	set_wall(true)
	blocked = true
	is_broken = false
	set_pending_blue(false)
	_show_crack(false)

func place_wall():
	if is_broken or wall_scene == null:
		return
	_clear_existing_object()
	var wall = wall_scene.instantiate()
	add_child(wall)
	if wall is Node3D:
		wall.global_transform = global_transform
	placed_object = wall
	set_wall(true)
	blocked = true
	is_broken = false
	set_pending_blue(false)
	_show_crack(false)

func set_wall(value: bool):
	is_wall = value

func is_walkable() -> bool:
	return not blocked

func apply_placement(action: String):
	match action:
		"turret": place_turret()
		"wall":   place_wall()
		"repair": repair_tile()

func break_tile():
	blocked = false
	is_wall = false
	has_turret = false
	is_broken = true
	_clear_existing_object()
	set_pending_blue(false)
	_show_crack(true)
	_tint_tile_red()

func repair_tile():
	is_broken = false
	blocked = false
	is_wall = false
	has_turret = false
	set_pending_blue(false)
	_show_crack(false)
	_restore_tile_material()

func _clear_existing_object() -> void:
	if is_instance_valid(placed_object):
		placed_object.queue_free()
	placed_object = null

func _show_crack(v: bool) -> void:
	if is_instance_valid(crack_overlay):
		crack_overlay.visible = v

func _tint_tile_red() -> void:
	if is_instance_valid(_tile_mesh):
		if _orig_mat == null:
			_orig_mat = _tile_mesh.material_override
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(1, 0, 0)
		_tile_mesh.material_override = m

func _restore_tile_material() -> void:
	if is_instance_valid(_tile_mesh):
		_tile_mesh.material_override = _orig_mat
