extends StaticBody3D

# ---------- Scenes / UI ----------
@export var turret_scene: PackedScene
@export var wall_scene: PackedScene
@export var mortar_scene: PackedScene            # 2×2 mortar
@export var placement_menu: PopupMenu

@onready var _tile_mesh: MeshInstance3D = $"TileMesh"
var _orig_mat: Material = null

# ---------- Pending highlight ----------
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

# ---------- Grid / state ----------
var grid_x: int = 0
var grid_z: int = 0
var grid_position: Vector2i:
	get: return Vector2i(grid_x, grid_z)
	set(v):
		grid_x = v.x
		grid_z = v.y

var tile_board: Node = null
var has_turret: bool = false
var is_wall: bool = false
var blocked: bool = false
var is_broken: bool = false
var placed_object: Node = null

# ---------- Multi-tile mortar ----------
const FP_NONE := Vector2i(-1, -1)
const MORTAR_FOOT := Vector2i(2, 2)              # (x, z)
var occupied_by_anchor: Vector2i = FP_NONE       # FP_NONE if not part of a mortar footprint

# ---------- Lifecycle ----------
func _ready() -> void:
	if is_instance_valid(_tile_mesh) and _orig_mat == null:
		_orig_mat = _tile_mesh.material_override

func _input_event(cam: Camera3D, e: InputEvent, _pos: Vector3, _n: Vector3, _shape: int) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_RIGHT and e.pressed:
		if tile_board:
			tile_board.set("active_tile", self)
		if placement_menu:
			placement_menu.clear()
			if is_broken:
				placement_menu.add_item("Repair", 2)
			elif not has_turret and not is_wall:
				placement_menu.add_item("Place Turret", 0)
				placement_menu.add_item("Place Wall", 1)
				if mortar_scene != null:
					placement_menu.add_item("Place Mortar (2x2)", 3)
			if placement_menu.item_count > 0:
				placement_menu.position = get_viewport().get_mouse_position()
				placement_menu.popup()

# ---------- 1×1 placements ----------
func place_turret() -> void:
	if is_broken or turret_scene == null:
		return
	_clear_existing_object()
	var t: Node = turret_scene.instantiate()
	add_child(t)
	if t is Node3D:
		(t as Node3D).global_transform = global_transform
	placed_object = t
	has_turret = true
	set_wall(true)
	blocked = true
	is_broken = false
	set_pending_blue(false)

func place_wall() -> void:
	if is_broken or wall_scene == null:
		return
	_clear_existing_object()
	var w: Node = wall_scene.instantiate()
	add_child(w)
	if w is Node3D:
		(w as Node3D).global_transform = global_transform
	placed_object = w
	set_wall(true)
	blocked = true
	is_broken = false
	set_pending_blue(false)

# ---------- 2×2 mortar placement ----------
func place_mortar() -> void:
	if is_broken or mortar_scene == null:
		return
	var board: Node = tile_board
	if board == null:
		return

	var tiles_v: Variant = board.get("tiles")
	if typeof(tiles_v) != TYPE_DICTIONARY:
		return
	var tiles: Dictionary = tiles_v

	var anchor: Vector2i = grid_position

	# Validate footprint
	for dx in range(MORTAR_FOOT.x):
		for dz in range(MORTAR_FOOT.y):
			var c := Vector2i(anchor.x + dx, anchor.y + dz)
			if not tiles.has(c):
				return
			var t: Node = tiles[c]
			if t == null: return
			if bool(t.get("is_broken")): return
			if bool(t.get("blocked")): return
			if bool(t.get("has_turret")): return
			var occ_v: Variant = t.get("occupied_by_anchor")
			if typeof(occ_v) == TYPE_VECTOR2I and Vector2i(occ_v) != FP_NONE:
				return

	# Claim footprint
	for dx in range(MORTAR_FOOT.x):
		for dz in range(MORTAR_FOOT.y):
			var c2 := Vector2i(anchor.x + dx, anchor.y + dz)
			var t2: Node = tiles[c2]
			if t2 != null:
				t2.set("blocked", true)
				t2.set("has_turret", true)
				t2.set("is_wall", true)
				t2.set("is_broken", false)
				t2.set("occupied_by_anchor", anchor)
				if t2.has_method("set_pending_blue"):
					t2.call("set_pending_blue", false)

	# Spawn mortar visual on the anchor and center over 2×2
	_clear_existing_object()
	var mortar: Node = mortar_scene.instantiate()
	add_child(mortar)
	if mortar is Node3D:
		var step: float = 0.0
		if board.has_method("tile_world_size"):
			step = float(board.call("tile_world_size"))
		elif board.has("tile_size"):
			step = float(board.get("tile_size"))
		if step > 0.0:
			(mortar as Node3D).global_position = global_position + Vector3(step * 0.5, 0.0, step * 0.5)
		else:
			(mortar as Node3D).global_transform = global_transform

	placed_object = mortar
	has_turret = true
	set_wall(true)
	blocked = true
	is_broken = false
	occupied_by_anchor = anchor

# ---------- Queries / actions ----------
func set_wall(v: bool) -> void:
	is_wall = v

func is_walkable() -> bool:
	# Any tile that is blocked OR part of a claimed footprint is non-walkable
	if occupied_by_anchor != FP_NONE:
		return false
	return not blocked

func apply_placement(action: String) -> void:
	match action:
		"turret": place_turret()
		"wall":   place_wall()
		"mortar": place_mortar()
		"repair": repair_tile()

func break_tile() -> void:
	blocked = false
	is_wall = false
	has_turret = false
	is_broken = true
	_clear_existing_object()
	set_pending_blue(false)
	_tint_tile_red()

# Called by “Repair” and by sell logic to free any footprint.
func repair_tile() -> void:
	var board: Node = tile_board
	if board == null:
		_reset_single()
		return

	var tiles_v: Variant = board.get("tiles")
	if typeof(tiles_v) != TYPE_DICTIONARY:
		_reset_single()
		return
	var tiles: Dictionary = tiles_v

	var anchor: Vector2i = (occupied_by_anchor if occupied_by_anchor != FP_NONE else grid_position)
	var is_mortar := (occupied_by_anchor != FP_NONE) or _is_mortar_anchor(tiles, anchor)
	var sx: int = (MORTAR_FOOT.x if is_mortar else 1)
	var sz: int = (MORTAR_FOOT.y if is_mortar else 1)

	for dx in range(sx):
		for dz in range(sz):
			var c := Vector2i(anchor.x + dx, anchor.y + dz)
			if tiles.has(c):
				var t: Node = tiles[c]
				if t != null:
					t.set("blocked", false)
					t.set("is_wall", false)
					t.set("has_turret", false)
					t.set("occupied_by_anchor", FP_NONE)
					if t.has_method("set_pending_blue"):
						t.call("set_pending_blue", false)

	_clear_existing_object()
	_reset_single()

# ---------- helpers ----------
func _reset_single() -> void:
	is_broken = false
	blocked = false
	is_wall = false
	has_turret = false
	occupied_by_anchor = FP_NONE
	set_pending_blue(false)
	_restore_tile_material()

func _clear_existing_object() -> void:
	if is_instance_valid(placed_object):
		placed_object.queue_free()
	placed_object = null

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

func _is_mortar_anchor(tiles: Dictionary, a: Vector2i) -> bool:
	# If any cell in the 2×2 points its 'occupied_by_anchor' to 'a' (and isn't a),
	# consider 'a' the anchor cell.
	for dx in range(MORTAR_FOOT.x):
		for dz in range(MORTAR_FOOT.y):
			var c := Vector2i(a.x + dx, a.y + dz)
			if tiles.has(c):
				var t: Node = tiles[c]
				var v: Variant = t.get("occupied_by_anchor")
				if typeof(v) == TYPE_VECTOR2I and Vector2i(v) == a and c != a:
					return true
	return false
