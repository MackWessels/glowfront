extends StaticBody3D

# Scenes / UI
@export var turret_scene: PackedScene
@export var sniper_scene: PackedScene        # 1×1 sniper tower (NEW)

@export var wall_scene: PackedScene
@export var mortar_scene: PackedScene        # 2×2 mortar
@export var miner_scene: PackedScene         # 1×1 mineral generator
@export var tesla_scene: PackedScene
@export var shard_miner_scene: PackedScene   # 2×2 shard miner (NEW)
@export var placement_menu: PopupMenu

@onready var _tile_mesh: MeshInstance3D = $"TileMesh"
var _orig_mat: Material = null

# Hover highlight
const PENDING_COLOR := Color(0.25, 0.55, 1.0)
var _pending_mat: StandardMaterial3D
var _pending_saved_mat: Material
var _pending_on := false

func _get_pending_mat() -> StandardMaterial3D:
	if _pending_mat == null:
		_pending_mat = StandardMaterial3D.new()
		_pending_mat.albedo_color = PENDING_COLOR
		_pending_mat.metallic = 0.0
		_pending_mat.roughness = 1.0
	return _pending_mat

func set_pending_blue(on: bool) -> void:
	if not is_instance_valid(_tile_mesh): return
	if on and not _pending_on:
		_pending_saved_mat = _tile_mesh.material_override
		_tile_mesh.material_override = _get_pending_mat()
		_pending_on = true
	elif not on and _pending_on:
		_tile_mesh.material_override = _pending_saved_mat
		_pending_saved_mat = null
		_pending_on = false

# Grid / state
var grid_x := 0
var grid_z := 0
var grid_position: Vector2i:
	get: return Vector2i(grid_x, grid_z)
	set(v):
		grid_x = v.x
		grid_z = v.y

var tile_board: Node
var has_turret := false
var is_wall := false
var blocked := false
var is_broken := false
var placed_object: Node

# 2×2 footprint support
const FP_NONE := Vector2i(-1, -1)
const MORTAR_FOOT := Vector2i(2, 2)               # (x, z)
const SHARD_MINER_FOOT := Vector2i(2, 2)          # (x, z) (NEW)
var occupied_by_anchor: Vector2i = FP_NONE        # != FP_NONE if claimed by any 2×2

func _ready() -> void:
	if is_instance_valid(_tile_mesh) and _orig_mat == null:
		_orig_mat = _tile_mesh.material_override

func _input_event(_cam: Camera3D, e: InputEvent, _pos: Vector3, _n: Vector3, _shape: int) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_RIGHT and e.pressed:
		if tile_board:
			tile_board.set("active_tile", self)
		if placement_menu:
			placement_menu.clear()
			if is_broken:
				placement_menu.add_item("Repair", 2)
			elif not has_turret and not is_wall:
				placement_menu.add_item("Place Turret", 0)
				if tesla_scene != null:
					placement_menu.add_item("Place Tesla Tower", 5)
				# NEW: sniper 1×1
				if sniper_scene != null:
					placement_menu.add_item("Place Sniper Tower", 7)
				placement_menu.add_item("Place Wall", 1)
				if miner_scene != null:
					placement_menu.add_item("Place Miner", 4)
				if mortar_scene != null:
					placement_menu.add_item("Place Mortar (2x2)", 3)
				if shard_miner_scene != null:
					placement_menu.add_item("Place Shard Miner (2x2)", 6)
			if placement_menu.item_count > 0:
				placement_menu.position = get_viewport().get_mouse_position()
				placement_menu.popup()


# ---------- 1×1 placements ----------
func place_turret() -> void:
	if is_broken or turret_scene == null: return
	_clear_existing_object()
	var t := turret_scene.instantiate()
	add_child(t)
	if t is Node3D: (t as Node3D).global_transform = global_transform
	placed_object = t
	has_turret = true
	set_wall(true)
	blocked = true
	is_broken = false
	set_pending_blue(false)

func place_wall() -> void:
	if is_broken or wall_scene == null: return
	_clear_existing_object()
	var w := wall_scene.instantiate()
	add_child(w)
	if w is Node3D: (w as Node3D).global_transform = global_transform
	placed_object = w
	set_wall(true)
	blocked = true
	is_broken = false
	set_pending_blue(false)

func place_miner() -> void:
	if is_broken or miner_scene == null: return
	_clear_existing_object()
	var m := miner_scene.instantiate()
	add_child(m)
	if m is Node3D: (m as Node3D).global_transform = global_transform
	if m and m.has_method("set_tile_context"):
		m.call("set_tile_context", tile_board, grid_position)
	placed_object = m
	has_turret = true   # treated as blocking building
	set_wall(true)
	blocked = true
	is_broken = false
	set_pending_blue(false)

func place_tesla() -> void:
	if is_broken or tesla_scene == null: return
	_clear_existing_object()
	var t := tesla_scene.instantiate()
	add_child(t)
	if t is Node3D: (t as Node3D).global_transform = global_transform
	if t and t.has_method("set_tile_context"):
		t.call("set_tile_context", tile_board, grid_position)
	placed_object = t
	has_turret = true
	set_wall(true)
	blocked = true
	is_broken = false
	set_pending_blue(false)

func place_sniper() -> void:
	if is_broken or sniper_scene == null: return
	_clear_existing_object()
	var s := sniper_scene.instantiate()
	add_child(s)
	if s is Node3D: (s as Node3D).global_transform = global_transform
	placed_object = s
	has_turret = true
	set_wall(true)
	blocked = true
	is_broken = false
	set_pending_blue(false)
	# proactively notify board (keeps pathing correct even if base tower code changes)
	_recompute_after_block(grid_position, Vector2i(1, 1))


# ---------- 2×2 mortar placement ----------
func place_mortar() -> void:
	if is_broken or mortar_scene == null: return
	var board := tile_board
	if board == null: return

	var tiles_v: Variant = board.get("tiles")
	if typeof(tiles_v) != TYPE_DICTIONARY: return
	var tiles: Dictionary = tiles_v
	var anchor := grid_position

	# validate footprint
	for dx in range(MORTAR_FOOT.x):
		for dz in range(MORTAR_FOOT.y):
			var c := Vector2i(anchor.x + dx, anchor.y + dz)
			if not tiles.has(c): return
			var t: Node = tiles[c]
			if t == null: return
			if bool(t.get("is_broken")): return
			if bool(t.get("blocked")): return
			if bool(t.get("has_turret")): return
			var occ_v: Variant = t.get("occupied_by_anchor")
			if typeof(occ_v) == TYPE_VECTOR2I and Vector2i(occ_v) != FP_NONE: return

	# claim footprint
	for dx in range(MORTAR_FOOT.x):
		for dz in range(MORTAR_FOOT.y):
			var c2 := Vector2i(anchor.x + dx, anchor.y + dz)
			var t2: Node = tiles[c2]
			if t2:
				t2.set("blocked", true)
				t2.set("has_turret", true)
				t2.set("is_wall", true)
				t2.set("is_broken", false)
				t2.set("occupied_by_anchor", anchor)
				if t2.has_method("set_pending_blue"):
					t2.call("set_pending_blue", false)

	# spawn mortar centered on 2×2
	_clear_existing_object()
	var mortar := mortar_scene.instantiate()
	add_child(mortar)
	if mortar is Node3D:
		var step := 0.0
		if board.has_method("tile_world_size"): step = float(board.call("tile_world_size"))
		elif board.has("tile_size"):            step = float(board.get("tile_size"))
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

# ---------- 2×2 shard_miner placement (NEW) ----------
func place_shard_miner() -> void:
	if is_broken or shard_miner_scene == null: return
	var board := tile_board
	if board == null: return

	var tiles_v: Variant = board.get("tiles")
	if typeof(tiles_v) != TYPE_DICTIONARY: return
	var tiles: Dictionary = tiles_v
	var anchor := grid_position

	# validate footprint
	for dx in range(SHARD_MINER_FOOT.x):
		for dz in range(SHARD_MINER_FOOT.y):
			var c := Vector2i(anchor.x + dx, anchor.y + dz)
			if not tiles.has(c): return
			var t: Node = tiles[c]
			if t == null: return
			if bool(t.get("is_broken")): return
			if bool(t.get("blocked")): return
			if bool(t.get("has_turret")): return
			var occ_v: Variant = t.get("occupied_by_anchor")
			if typeof(occ_v) == TYPE_VECTOR2I and Vector2i(occ_v) != FP_NONE: return

	# claim footprint
	for dx in range(SHARD_MINER_FOOT.x):
		for dz in range(SHARD_MINER_FOOT.y):
			var c2 := Vector2i(anchor.x + dx, anchor.y + dz)
			var t2: Node = tiles[c2]
			if t2:
				t2.set("blocked", true)
				t2.set("has_turret", true)
				t2.set("is_wall", true)
				t2.set("is_broken", false)
				t2.set("occupied_by_anchor", anchor)
				if t2.has_method("set_pending_blue"):
					t2.call("set_pending_blue", false)

	# spawn shard miner centered on 2×2
	_clear_existing_object()
	var sm := shard_miner_scene.instantiate()
	add_child(sm)
	if sm is Node3D:
		var step := 0.0
		if board.has_method("tile_world_size"): step = float(board.call("tile_world_size"))
		elif board.has("tile_size"):            step = float(board.get("tile_size"))
		if step > 0.0:
			(sm as Node3D).global_position = global_position + Vector3(step * 0.5, 0.0, step * 0.5)
		else:
			(sm as Node3D).global_transform = global_transform
	if sm and sm.has_method("set_tile_context"):
		sm.call("set_tile_context", tile_board, grid_position)
	if sm and sm.has_method("on_placed"):
		sm.call("on_placed")

	placed_object = sm
	has_turret = true
	set_wall(true)
	blocked = true
	is_broken = false
	occupied_by_anchor = anchor

	# tell the board the walkability changed
	_recompute_after_block(anchor, SHARD_MINER_FOOT)

func _recompute_after_block(anchor: Vector2i, size: Vector2i) -> void:
	if tile_board == null: return
	# Prefer explicit APIs if your TileBoard exposes them:
	if tile_board.has_method("on_tiles_blocked_changed"):
		tile_board.call("on_tiles_blocked_changed", anchor, size, true)
		return
	if tile_board.has_method("notify_blocked_rect"):
		tile_board.call("notify_blocked_rect", anchor, size, true)
		return
	# Fallbacks: try common recompute names; only the first that exists is called.
	for m in ["recompute_flow", "recompute_paths", "rebuild_flow_field", "recompute_board_dirs", "recompute"]:
		if tile_board.has_method(m):
			tile_board.call(m)
			return

# ---------- Queries / actions ----------
func set_wall(v: bool) -> void:
	is_wall = v

func is_walkable() -> bool:
	if occupied_by_anchor != FP_NONE: return false
	return not blocked

func apply_placement(action: String) -> void:
	match action:
		"turret":      place_turret()
		"tesla":       place_tesla()
		"sniper":      place_sniper()       # NEW
		"wall":        place_wall()
		"mortar":      place_mortar()
		"miner":       place_miner()
		"shard_miner": place_shard_miner()
		"repair":      repair_tile()


func break_tile() -> void:
	blocked = false
	is_wall = false
	has_turret = false
	is_broken = true
	_clear_existing_object()
	set_pending_blue(false)
	_tint_tile_red()

func repair_tile() -> void:
	var board := tile_board
	if board == null:
		_reset_single(); return

	var tiles_v: Variant = board.get("tiles")
	if typeof(tiles_v) != TYPE_DICTIONARY:
		_reset_single(); return
	var tiles: Dictionary = tiles_v

	var anchor := (occupied_by_anchor if occupied_by_anchor != FP_NONE else grid_position)
	var is_mortar := (occupied_by_anchor != FP_NONE) or _is_mortar_anchor(tiles, anchor)
	var sx := (MORTAR_FOOT.x if is_mortar else 1)
	var sz := (MORTAR_FOOT.y if is_mortar else 1)

	for dx in range(sx):
		for dz in range(sz):
			var c := Vector2i(anchor.x + dx, anchor.y + dz)
			if tiles.has(c):
				var t: Node = tiles[c]
				if t:
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

# Note: despite the name, this works for any 2×2 since it checks occupied_by_anchor
func _is_mortar_anchor(tiles: Dictionary, a: Vector2i) -> bool:
	for dx in range(MORTAR_FOOT.x):
		for dz in range(MORTAR_FOOT.y):
			var c := Vector2i(a.x + dx, a.y + dz)
			if tiles.has(c):
				var t: Node = tiles[c]
				var v: Variant = t.get("occupied_by_anchor")
				if typeof(v) == TYPE_VECTOR2I and Vector2i(v) == a and c != a:
					return true
	return false
