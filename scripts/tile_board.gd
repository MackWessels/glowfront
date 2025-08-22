extends Node3D

# =============================================================================
# Inspector
# =============================================================================
@export var spawner_span: int = 3
@export var board_size_x: int = 10
@export var board_size_z: int = 11
@export var tile_scene: PackedScene
@export var tile_size: float = 2.0
@export var goal_node: Node3D
@export var spawner_node: Node3D
@export var placement_menu: PopupMenu
@export var enemy_spawner: Node3D

# Economy
@export var turret_cost: int = 10

# =============================================================================
# Bounds / Portals
# =============================================================================
const BOUNDS_THICKNESS: float = 0.35
const BOUNDS_HEIGHT: float = 4.0
const SHOW_BOUNDS_DEBUG := true
const BOUNDS_COLLISION_LAYER: int = 1 << 1  # layer 2
const BOUNDS_COLLISION_MASK: int = 0

const CARVE_OPENINGS_FOR_PORTALS := true
const GOAL_OPENING_TILES: int = 1
const OPENING_EXTRA_MARGIN_TILES: float = 0.0   # <— as requested

const PORTAL_PEN_ENABLED := true
const PORTAL_PEN_DEPTH_TILES: float = 1.0

# Single enemy group used for occupancy checks
const ENEMY_GROUP: String = "enemy"

# =============================================================================
# Signals
# =============================================================================
signal global_path_changed

# =============================================================================
# State
# =============================================================================
var tiles: Dictionary = {}
var active_tile: Node = null

# highlight/pending
var _pending_tile: Node = null

# soft reservations (temporarily non-walkable)
var _reserved_cells: Dictionary = {}          # Vector2i -> true
var _reserved_counts: Dictionary = {}         # Vector2i -> int

# builds waiting for enemies to step off
var _pending_builds: Array[Dictionary] = []   # {"cell":Vector2i,"tile":Node,"action":String,"cost":int}

# legacy compat (not used for paint)
var closing: Dictionary = {}

# flow-field
var cost: Dictionary = {}
var dir_field: Dictionary = {}

# grid
var _grid_origin: Vector3 = Vector3.ZERO
var _step: float = 1.0

# 4-connected
const ORTHO_DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0),
	Vector2i(0, 1), Vector2i(0, -1)
]

const EPS := 0.0001

# =============================================================================
# Lifecycle
# =============================================================================
func _ready() -> void:
	generate_board()

	var origin_tile := tiles.get(Vector2i(0, 0), null) as Node3D
	_grid_origin = origin_tile.global_position
	_step = tile_size

	position_portal(goal_node, "right")
	position_portal(spawner_node, "left")

	_create_bounds()
	_recompute_flow()

	# Placement menu
	placement_menu.connect("place_selected", Callable(self, "_on_place_selected"))

	if not get_tree().is_connected("node_added", Callable(self, "_on_tree_node_added")):
		get_tree().connect("node_added", Callable(self, "_on_tree_node_added"))

func _on_tree_node_added(n: Node) -> void:
	if n != null and n.is_in_group(ENEMY_GROUP):
		_wire_enemy(n)

func _wire_enemy(n: Node) -> void:
	if n == null:
		return
	if n.has_signal("cell_changed") and not n.is_connected("cell_changed", Callable(self, "_on_enemy_cell_changed_signal")):
		n.connect("cell_changed", Callable(self, "_on_enemy_cell_changed_signal").bind(n))
	if n.has_signal("died") and not n.is_connected("died", Callable(self, "_on_enemy_died_signal")):
		n.connect("died", Callable(self, "_on_enemy_died_signal").bind(n))

# =============================================================================
# Pending/highlight manager
# =============================================================================
func set_active_tile(tile: Node) -> void:
	if tile == _pending_tile:
		active_tile = tile
		return

	_clear_pending()
	if tile and is_instance_valid(tile) and tile.has_method("set_pending_blue"):
		_pending_tile = tile
		active_tile   = tile
		tile.call("set_pending_blue", true)

func clear_active_tile(tile: Node = null) -> void:
	if tile != null and tile != _pending_tile:
		return
	_clear_pending()

func _clear_pending() -> void:
	if _pending_tile and is_instance_valid(_pending_tile) and _pending_tile.has_method("set_pending_blue"):
		_pending_tile.call("set_pending_blue", false)
	_pending_tile = null
	active_tile = null

# =============================================================================
# Economy helpers
# =============================================================================
func _econ_balance() -> int:
	if Economy.has_method("balance"):
		return int(Economy.call("balance"))
	var v: Variant = Economy.get("minerals")
	if typeof(v) == TYPE_INT:
		return int(v)
	return 0

func _econ_can_afford(cost_val: int) -> bool:
	if cost_val <= 0:
		return true
	if Economy.has_method("can_afford"):
		return bool(Economy.call("can_afford", cost_val))
	return cost_val <= _econ_balance()

func _econ_spend(cost_val: int) -> bool:
	if cost_val <= 0:
		return true
	var ok := true
	if Economy.has_method("try_spend"):
		ok = bool(Economy.call("try_spend", cost_val, "tileboard_build"))
	elif Economy.has_method("spend"):
		ok = bool(Economy.call("spend", cost_val))
	elif Economy.has_method("set_amount"):
		var bal := _econ_balance()
		ok = bal >= cost_val
		if ok:
			Economy.call("set_amount", bal - cost_val)
	else:
		ok = _econ_balance() >= cost_val
	return ok

func _cost_for_action(action: String) -> int:
	match action:
		"turret":
			return turret_cost
		_:
			return 0

func _placement_succeeded(tile: Node, action: String) -> bool:
	match action:
		"turret":
			if tile and tile.has_method("has_turret"):
				return bool(tile.call("has_turret"))
			var v: Variant = tile.get("has_turret")
			if typeof(v) == TYPE_BOOL:
				return bool(v)
			var tower: Node = tile.find_child("Tower", true, false)
			return tower != null
		_:
			return true

# =============================================================================
# Board generation
# =============================================================================
func generate_board() -> void:
	if tile_scene == null:
		push_error("TileBoard: 'tile_scene' is not assigned.")
		return
	tiles.clear()

	for x in board_size_x:
		for z in board_size_z:
			var tile := tile_scene.instantiate() as Node3D
			add_child(tile)

			var pos := Vector2i(x, z)
			tile.position = Vector3(x * tile_size, 0.0, z * tile_size)
			tile.set("grid_position", pos)
			tile.set("tile_board", self)
			tile.set("placement_menu", placement_menu)

			tiles[pos] = tile

# =============================================================================
# Bounds (walls) with portal openings + pens
# =============================================================================
func _create_bounds() -> void:
	var old := get_node_or_null("BoardBounds")
	if old:
		old.queue_free()

	var container := Node3D.new()
	container.name = "BoardBounds"
	add_child(container)

	var left   := _grid_origin.x - _step * 0.5
	var right  := _grid_origin.x + (board_size_x - 0.5) * _step
	var top    := _grid_origin.z - _step * 0.5
	var bottom := _grid_origin.z + (board_size_z - 0.5) * _step

	var y_size := BOUNDS_HEIGHT
	var y_pos  := y_size * 0.5

	var openings: Dictionary = {"left": [], "right": [], "top": [], "bottom": []}

	if CARVE_OPENINGS_FOR_PORTALS:
		var bounds := _grid_bounds()
		if is_instance_valid(spawner_node):
			var sp_cell := world_to_cell(spawner_node.global_position)
			var sp_side := _side_of_cell(sp_cell, bounds)
			var sp_half: float = _step * (float(max(1, spawner_span)) * 0.5 + OPENING_EXTRA_MARGIN_TILES)
			if sp_side == "left" or sp_side == "right":
				openings[sp_side].append({"center": cell_to_world(sp_cell).z, "half": sp_half})
			else:
				openings[sp_side].append({"center": cell_to_world(sp_cell).x, "half": sp_half})

		if is_instance_valid(goal_node):
			var g_cell := world_to_cell(goal_node.global_position)
			var g_side := _side_of_cell(g_cell, bounds)
			var g_half: float = _step * (float(max(1, GOAL_OPENING_TILES)) * 0.5 + OPENING_EXTRA_MARGIN_TILES)
			if g_side == "left" or g_side == "right":
				openings[g_side].append({"center": cell_to_world(g_cell).z, "half": g_half})
			else:
				openings[g_side].append({"center": cell_to_world(g_cell).x, "half": g_half})

	_build_wall_x(container, top - BOUNDS_THICKNESS * 0.5, left, right, y_pos, y_size, BOUNDS_THICKNESS, openings["top"])
	_build_wall_x(container, bottom + BOUNDS_THICKNESS * 0.5, left, right, y_pos, y_size, BOUNDS_THICKNESS, openings["bottom"])
	_build_wall_z(container, left - BOUNDS_THICKNESS * 0.5, top, bottom, y_pos, y_size, BOUNDS_THICKNESS, openings["left"])
	_build_wall_z(container, right + BOUNDS_THICKNESS * 0.5, top, bottom, y_pos, y_size, BOUNDS_THICKNESS, openings["right"])

	if PORTAL_PEN_ENABLED:
		_add_portal_pens(container, left, right, top, bottom, y_pos, y_size, BOUNDS_THICKNESS, openings)

func _side_of_cell(cell: Vector2i, b: Rect2i) -> String:
	var left_i := b.position.x
	var top_i := b.position.y
	var right_i := b.position.x + b.size.x - 1
	var bottom_i := b.position.y + b.size.y - 1
	if cell.x <= left_i:
		return "left"
	elif cell.x >= right_i:
		return "right"
	elif cell.y <= top_i:
		return "top"
	else:
		return "bottom"

func _build_wall_x(parent: Node, z_pos: float, left: float, right: float,
	y_pos: float, y_size: float, thickness: float, openings: Array) -> void:
	var start := left - thickness
	var end := right + thickness
	for seg in _segments_along(start, end, openings):
		var cx: float = float(seg["center"])
		var L: float = float(seg["len"])
		if L <= 0.001:
			continue
		_make_wall(parent, Vector3(cx, y_pos, z_pos), Vector3(L, y_size, thickness))

func _build_wall_z(parent: Node, x_pos: float, top: float, bottom: float,
	y_pos: float, y_size: float, thickness: float, openings: Array) -> void:
	var start := top - thickness
	var end := bottom + thickness
	for seg in _segments_along(start, end, openings):
		var cz: float = float(seg["center"])
		var L: float = float(seg["len"])
		if L <= 0.001:
			continue
		_make_wall(parent, Vector3(x_pos, y_pos, cz), Vector3(thickness, y_size, L))

func _segments_along(start: float, end: float, openings: Array) -> Array:
	var segs: Array = []
	var cur := start
	var ops := openings.duplicate()
	ops.sort_custom(func(a, b): return a["center"] < b["center"])

	for op in ops:
		var half: float = float(op["half"])
		var c: float = float(op["center"])
		var o_start := c - half
		var o_end := c + half
		var s := o_start - cur
		if s > 0.001:
			segs.append({"center": (cur + o_start) * 0.5, "len": s})
		cur = max(cur, o_end)

	var tail := end - cur
	if tail > 0.001:
		segs.append({"center": (cur + end) * 0.5, "len": tail})
	return segs

func _add_portal_pens(
	parent: Node,
	left: float, right: float, top: float, bottom: float,
	y_pos: float, y_size: float,
	thickness: float,
	openings: Dictionary
) -> void:
	var depth: float = _step * max(0.0, PORTAL_PEN_DEPTH_TILES)
	if depth <= 0.0:
		return

	for op in openings.get("left", []):
		var c: float = float(op["center"])
		var half: float = float(op["half"])
		var x_center := left - thickness * 0.5 - depth * 0.5
		_make_wall(parent, Vector3(x_center, y_pos, (c - half) - thickness * 0.5), Vector3(depth, y_size, thickness))
		_make_wall(parent, Vector3(x_center, y_pos, (c + half) + thickness * 0.5), Vector3(depth, y_size, thickness))
		_make_wall(parent, Vector3(left - thickness * 0.5 - depth, y_pos, c), Vector3(thickness, y_size, (half * 2.0) + thickness * 2.0))

	for op in openings.get("right", []):
		var c2: float = float(op["center"])
		var half2: float = float(op["half"])
		var x_center2 := right + thickness * 0.5 + depth * 0.5
		_make_wall(parent, Vector3(x_center2, y_pos, (c2 - half2) - thickness * 0.5), Vector3(depth, y_size, thickness))
		_make_wall(parent, Vector3(x_center2, y_pos, (c2 + half2) + thickness * 0.5), Vector3(depth, y_size, thickness))
		_make_wall(parent, Vector3(right + thickness * 0.5 + depth, y_pos, c2), Vector3(thickness, y_size, (half2 * 2.0) + thickness * 2.0))

	for op in openings.get("top", []):
		var c3: float = float(op["center"])
		var half3: float = float(op["half"])
		var z_center := top - thickness * 0.5 - depth * 0.5
		_make_wall(parent, Vector3((c3 - half3) - thickness * 0.5, y_pos, z_center), Vector3(thickness, y_size, depth))
		_make_wall(parent, Vector3((c3 + half3) + thickness * 0.5, y_pos, z_center), Vector3(thickness, y_size, depth))
		_make_wall(parent, Vector3(c3, y_pos, top - thickness * 0.5 - depth), Vector3((half3 * 2.0) + thickness * 2.0, y_size, thickness))

	for op in openings.get("bottom", []):
		var c4: float = float(op["center"])
		var half4: float = float(op["half"])
		var z_center2 := bottom + thickness * 0.5 + depth * 0.5
		_make_wall(parent, Vector3((c4 - half4) - thickness * 0.5, y_pos, z_center2), Vector3(thickness, y_size, depth))
		_make_wall(parent, Vector3((c4 + half4) + thickness * 0.5, y_pos, z_center2), Vector3(thickness, y_size, depth))
		_make_wall(parent, Vector3(c4, y_pos, bottom + thickness * 0.5 + depth), Vector3((half4 * 2.0) + thickness * 2.0, y_size, thickness))

func _make_wall(parent: Node, position: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = "BoundWall"
	parent.add_child(body)

	body.collision_layer = BOUNDS_COLLISION_LAYER
	body.collision_mask  = BOUNDS_COLLISION_MASK
	body.global_position = position

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)

	if SHOW_BOUNDS_DEBUG:
		var mesh_inst := MeshInstance3D.new()
		var cube := BoxMesh.new()
		cube.size = size
		mesh_inst.mesh = cube

		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(1.0, 0.2, 0.2, 0.25)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mesh_inst.material_override = mat

		body.add_child(mesh_inst)

# =============================================================================
# Spawn/goal helpers (pens)
# =============================================================================
func get_spawn_pen(span: int = -1) -> Dictionary:
	if span <= 0:
		span = spawner_span
	if not is_instance_valid(spawner_node):
		return {"pen_centers": [], "entry_targets": [], "forward": Vector3.FORWARD,
			"lateral": Vector3.RIGHT, "spawn_radius": tile_size * 0.6, "exit_radius": tile_size * 0.35}

	var sp_world: Vector3 = spawner_node.global_transform.origin
	var sp_cell: Vector2i = world_to_cell(sp_world)
	var bounds: Rect2i = _grid_bounds()

	var normal := Vector2i.ZERO
	var lateral := Vector2i.ZERO
	if sp_cell.x <= bounds.position.x:
		normal = Vector2i(1, 0);  lateral = Vector2i(0, 1)
	elif sp_cell.x >= bounds.position.x + bounds.size.x - 1:
		normal = Vector2i(-1, 0); lateral = Vector2i(0, 1)
	elif sp_cell.y <= bounds.position.y:
		normal = Vector2i(0, 1);  lateral = Vector2i(1, 0)
	else:
		normal = Vector2i(0, -1); lateral = Vector2i(1, 0)

	@warning_ignore("integer_division")
	var half_i: int = int(span / 2)

	var board_cells: Array[Vector2i] = []
	for i in range(-half_i, half_i + 1):
		var c := sp_cell + lateral * i
		c.x = clampi(c.x, bounds.position.x, bounds.position.x + bounds.size.x - 1)
		c.y = clampi(c.y, bounds.position.y, bounds.position.y + bounds.size.y - 1)
		board_cells.append(c)

	var seen: Dictionary = {}
	var exit_targets: Array[Vector3] = []
	for c in board_cells:
		var key := str(c.x, ",", c.y)
		if not seen.has(key):
			seen[key] = true
			exit_targets.append(cell_to_world(c))

	var origin_world: Vector3 = cell_to_world(sp_cell)
	var fwd3: Vector3 = cell_to_world(sp_cell + normal) - origin_world
	var lat3: Vector3 = cell_to_world(sp_cell + lateral) - origin_world
	if fwd3.length() < 0.001: fwd3 = Vector3.FORWARD
	else: fwd3 = fwd3.normalized()
	if lat3.length() < 0.001: lat3 = Vector3.RIGHT
	else: lat3 = lat3.normalized()

	var depth: float = _step * max(0.0, PORTAL_PEN_DEPTH_TILES)
	var pen_offset: float = (BOUNDS_THICKNESS * 0.5) + (depth * 0.5)

	var pen_centers: Array[Vector3] = []
	for t in exit_targets:
		pen_centers.append(t - fwd3 * pen_offset)

	return {
		"pen_centers": pen_centers,
		"entry_targets": exit_targets,
		"forward": fwd3,
		"lateral": lat3,
		"spawn_radius": tile_size * 0.6,
		"exit_radius":  tile_size * 0.35
	}

func spawn_pen_cells(span: int = -1) -> Array[Vector2i]:
	if span <= 0:
		span = spawner_span
	var info := get_spawn_pen(span)
	var targets: Array = info.get("entry_targets", [])
	var cells: Array[Vector2i] = []
	for p in targets:
		var pw: Vector3 = p
		cells.append(world_to_cell(pw))
	return cells

func _goal_pen_target_world() -> Vector3:
	var g_cell: Vector2i = _goal_cell()
	var bounds: Rect2i = _grid_bounds()

	var normal_in := Vector2i.ZERO
	if g_cell.x <= bounds.position.x:
		normal_in = Vector2i(1, 0)
	elif g_cell.x >= bounds.position.x + bounds.size.x - 1:
		normal_in = Vector2i(-1, 0)
	elif g_cell.y <= bounds.position.y:
		normal_in = Vector2i(0, 1)
	else:
		normal_in = Vector2i(0, -1)

	var center_w := cell_to_world(g_cell)
	var into_w := cell_to_world(g_cell + normal_in) - center_w
	if into_w.length() < 0.001:
		into_w = Vector3.FORWARD
	else:
		into_w = into_w.normalized()
	var outward := -into_w

	var depth: float = 0.0
	if PORTAL_PEN_ENABLED:
		depth = _step * max(0.0, PORTAL_PEN_DEPTH_TILES)
	var pen_offset: float = (BOUNDS_THICKNESS * 0.5) + (depth * 0.5)
	return center_w + outward * pen_offset

# =============================================================================
# Portals positioning
# =============================================================================
func position_portal(portal: Node3D, side: String) -> void:
	var mid_x: int = board_size_x >> 1
	var mid_z: int = board_size_z >> 1

	var pos := Vector2i.ZERO
	var rotation_y := 0.0
	match side:
		"left":
			pos = Vector2i(0, mid_z);                 rotation_y = PI / 2.0
		"right":
			pos = Vector2i(board_size_x - 1, mid_z);  rotation_y = -PI / 2.0
		"top":
			pos = Vector2i(mid_x, 0);                 rotation_y = 0.0
		"bottom":
			pos = Vector2i(mid_x, board_size_z - 1);  rotation_y = PI

	var tile := tiles.get(pos, null) as Node3D
	var target_pos: Vector3
	if tile != null:
		target_pos = tile.global_position
	else:
		target_pos = cell_to_world(pos)
	portal.global_position = target_pos
	portal.rotation.y = rotation_y

# Simple getters
func get_spawn_position() -> Vector3:
	return spawner_node.global_position
func get_goal_position()  -> Vector3:
	return _goal_pen_target_world()

# =============================================================================
# Grid conversion helpers
# =============================================================================
func cell_to_world(pos: Vector2i) -> Vector3:
	return _grid_origin + Vector3(pos.x * _step, 0.0, pos.y * _step)

func world_to_cell(world_pos: Vector3) -> Vector2i:
	var gx: int = roundi((world_pos.x - _grid_origin.x) / _step)
	var gz: int = roundi((world_pos.z - _grid_origin.z) / _step)
	return Vector2i(clamp(gx, 0, board_size_x - 1), clamp(gz, 0, board_size_z - 1))

func _goal_cell() -> Vector2i:
	return world_to_cell(goal_node.global_position)

func _grid_bounds() -> Rect2i:
	return Rect2i(Vector2i(0, 0), Vector2i(board_size_x, board_size_z))

# =============================================================================
# Flow-field + reservations
# =============================================================================
func _recompute_flow() -> bool:
	var new_cost: Dictionary = {}
	var new_dir: Dictionary = {}

	var goal_cell: Vector2i  = _goal_cell()
	var spawn_cell: Vector2i = world_to_cell(spawner_node.global_position)

	if _tile_is_walkable(goal_cell):
		new_cost[goal_cell] = 0
		var q: Array[Vector2i] = [goal_cell]
		var head := 0
		while head < q.size():
			var cur: Vector2i = q[head]
			head += 1
			var cur_cost: int = int(new_cost[cur])

			for o in ORTHO_DIRS:
				var nb: Vector2i = cur + o
				if not _tile_is_walkable(nb):
					continue
				if new_cost.has(nb):
					continue
				new_cost[nb] = cur_cost + 1
				q.append(nb)

	if not new_cost.has(spawn_cell):
		return false

	var goal_world := _goal_pen_target_world()

	for key in new_cost.keys():
		var cell: Vector2i = key
		var dir_v := Vector3.ZERO

		if cell == goal_cell:
			dir_v = goal_world - cell_to_world(cell)
			dir_v.y = 0.0
			var L0 := dir_v.length()
			if L0 > EPS:
				dir_v = dir_v / L0
		else:
			var best := cell
			var best_val := int(new_cost[cell])
			for o2 in ORTHO_DIRS:
				var nb2 := cell + o2
				if new_cost.has(nb2) and int(new_cost[nb2]) < best_val:
					best_val = int(new_cost[nb2])
					best = nb2
			if best != cell:
				var d := cell_to_world(best) - cell_to_world(cell)
				d.y = 0.0
				var L := d.length()
				if L > EPS:
					dir_v = d / L

		new_dir[cell] = dir_v

	# Supply escape direction for reserved cells so enemies can leave
	for r_key in _reserved_cells.keys():
		var r_cell: Vector2i = r_key
		if new_dir.has(r_cell):
			continue
		var found := false
		var best_nb := r_cell
		var best_val := 0x3fffffff
		for o3 in ORTHO_DIRS:
			var nb3 := r_cell + o3
			if new_cost.has(nb3):
				var v := int(new_cost[nb3])
				if not found or v < best_val:
					found = true
					best_val = v
					best_nb = nb3
		var dir_r := Vector3.ZERO
		if found:
			var d2 := cell_to_world(best_nb) - cell_to_world(r_cell)
			d2.y = 0.0
			var L2 := d2.length()
			if L2 > EPS:
				dir_r = d2 / L2
		new_dir[r_cell] = dir_r

	cost = new_cost
	dir_field = new_dir
	return true

func _tile_is_walkable(cell: Vector2i) -> bool:
	if _reserved_cells.has(cell):
		return false
	if not tiles.has(cell):
		return false
	var t: Node = tiles.get(cell, null)
	if t and t.has_method("is_walkable"):
		return bool(t.call("is_walkable"))
	var v: Variant = t.get("walkable")
	if typeof(v) == TYPE_BOOL:
		return v
	if t.has_method("has_turret"):
		return not bool(t.call("has_turret"))
	var tower: Node = t.find_child("Tower", true, false)
	return tower == null

# =============================================================================
# Enemy steering API (sample dir for enemies)
# =============================================================================
func _outside_side(w: Vector3) -> String:
	var b := get_play_bounds_world()
	if w.x < float(b["left"]):
		return "left"
	if w.x > float(b["right"]):
		return "right"
	if w.z < float(b["top"]):
		return "top"
	if w.z > float(b["bottom"]):
		return "bottom"
	return "inside"

func sample_flow_dir(world_pos: Vector3) -> Vector3:
	var gb := _grid_bounds()
	var sp_side: String = "none"
	var goal_side: String = "none"
	if is_instance_valid(spawner_node):
		var sp_cell := world_to_cell(spawner_node.global_position)
		sp_side = _side_of_cell(sp_cell, gb)
	if is_instance_valid(goal_node):
		var g_cell := world_to_cell(goal_node.global_position)
		goal_side = _side_of_cell(g_cell, gb)

	var where: String = _outside_side(world_pos)
	if where != "inside":
		if where == sp_side:
			var pen := get_spawn_pen(spawner_span)
			var targets: Array = pen.get("entry_targets", [])
			var best: Vector3 = world_pos
			var best_d2 := 1.0e30
			for t in targets:
				var tw: Vector3 = t
				var v := tw - world_pos
				v.y = 0.0
				var d2 := v.length_squared()
				if d2 < best_d2:
					best_d2 = d2
					best = tw
			var steer := best - world_pos
			steer.y = 0.0
			var L := steer.length()
			if L > EPS:
				return steer / L
			return Vector3.ZERO

		if where == goal_side:
			var tgt := _goal_pen_target_world()
			var to_goal := tgt - world_pos
			to_goal.y = 0.0
			var Lg := to_goal.length()
			if Lg > EPS:
				return to_goal / Lg
			return Vector3.ZERO

		var b := get_play_bounds_world()
		var clamp_x := clampf(world_pos.x, float(b["left"]), float(b["right"]))
		var clamp_z := clampf(world_pos.z, float(b["top"]),  float(b["bottom"]))
		var back_in := Vector3(clamp_x, world_pos.y, clamp_z)
		var to_inside := back_in - world_pos
		to_inside.y = 0.0
		var Li := to_inside.length()
		if Li > EPS:
			return to_inside / Li
		return Vector3.ZERO

	var cell := world_to_cell(world_pos)
	if dir_field.has(cell):
		return dir_field[cell]
	return Vector3.ZERO

# =============================================================================
# Enemy detection & reservations
# =============================================================================
func _enemies_on_cell(cell: Vector2i) -> Array:
	var out: Array = []
	var nodes: Array = get_tree().get_nodes_in_group(ENEMY_GROUP)
	for n in nodes:
		var n3 := n as Node3D
		if n3 == null:
			continue
		var c := world_to_cell(n3.global_position)
		if c == cell:
			out.append(n3)
	return out

func is_cell_reserved(cell: Vector2i) -> bool:
	return _reserved_cells.has(cell)

func _reserve_cell(cell: Vector2i, enable: bool) -> void:
	if enable:
		_reserved_cells[cell] = true
		_reserved_counts[cell] = _enemies_on_cell(cell).size()
		if int(_reserved_counts[cell]) == 0:
			_commit_reserved_if_possible(cell)
	else:
		if _reserved_cells.has(cell):
			_reserved_cells.erase(cell)
		if _reserved_counts.has(cell):
			_reserved_counts.erase(cell)

# Signal handler (enemy -> board)
func _on_enemy_cell_changed_signal(old_cell: Vector2i, new_cell: Vector2i, enemy: Node) -> void:
	_on_enemy_cell_changed(old_cell, new_cell, enemy)

# Enemy can also call this directly (deferred)
func _on_enemy_cell_changed(old_cell: Vector2i, new_cell: Vector2i, enemy: Node = null) -> void:
	if _reserved_counts.has(old_cell):
		var cur := int(_reserved_counts[old_cell]) - 1
		if cur < 0:
			cur = _enemies_on_cell(old_cell).size()
		_reserved_counts[old_cell] = max(0, cur)
		if int(_reserved_counts[old_cell]) == 0:
			_commit_reserved_if_possible(old_cell)
	if _reserved_counts.has(new_cell):
		_reserved_counts[new_cell] = int(_reserved_counts[new_cell]) + 1

func _on_enemy_died_signal(enemy: Node) -> void:
	if enemy == null:
		return
	var n3 := enemy as Node3D
	if n3 == null:
		return
	var cell := world_to_cell(n3.global_position)
	if _reserved_counts.has(cell):
		var cur := int(_reserved_counts[cell]) - 1
		if cur < 0:
			cur = _enemies_on_cell(cell).size()
		_reserved_counts[cell] = max(0, cur)
		if int(_reserved_counts[cell]) == 0:
			_commit_reserved_if_possible(cell)

func _commit_reserved_if_possible(cell: Vector2i) -> void:
	# Find pending item for this cell
	for i in range(_pending_builds.size()):
		var item: Dictionary = _pending_builds[i]
		var icell: Vector2i = item["cell"]
		if icell != cell:
			continue

		var tile: Node = item["tile"] as Node
		if is_instance_valid(tile):
			if tile.has_method("set_pending_blue"):
				tile.call("set_pending_blue", false)

			_reserve_cell(cell, false)

			if tile.has_method("apply_placement"):
				tile.call("apply_placement", String(item["action"]))

			var ok := _recompute_flow()
			if not ok:
				if tile.has_method("break_tile"):
					tile.call("break_tile")
				_recompute_flow()
			else:
				var action_str: String = String(item["action"])
				var blocks := (action_str == "turret" or action_str == "wall")
				if blocks:
					var placed_ok := _placement_succeeded(tile, action_str)
					var cval: int = int(item["cost"])
					if placed_ok and cval > 0:
						var paid := _econ_spend(cval)
						if not paid and tile.has_method("break_tile"):
							tile.call("break_tile")

			emit_signal("global_path_changed")

		_pending_builds.remove_at(i)
		return

func _queue_pending_build(cell: Vector2i, tile: Node, action: String, cost_val: int) -> void:
	var item: Dictionary = {
		"cell": cell,
		"tile": tile,
		"action": action,
		"cost": cost_val
	}
	_pending_builds.append(item)

# =============================================================================
# Building – simplified logic (RED = break tile)
# =============================================================================
func _on_place_selected(action: String) -> void:
	if active_tile == null or not is_instance_valid(active_tile):
		return
	if action == "":
		return

	var pos: Vector2i = active_tile.get("grid_position")
	var blocks := (action == "turret" or action == "wall")
	var action_cost := _power_cost_for(action)

	if blocks and action_cost > 0 and not _econ_can_afford(action_cost):
		return

	if blocks:
		# 1) If it would block the path -> break (red) and stop
		_reserve_cell(pos, true)
		var ok_path := _recompute_flow()
		_reserve_cell(pos, false)
		_recompute_flow()
		if not ok_path:
			if active_tile.has_method("break_tile"):
				active_tile.call("break_tile")
			emit_signal("global_path_changed")
			_clear_pending()
			return

		# 2) Path OK but an enemy stands on it -> blue pending
		var occ := _enemies_on_cell(pos)
		if occ.size() > 0:
			if active_tile.has_method("set_pending_blue"):
				active_tile.call("set_pending_blue", true)
			_reserve_cell(pos, true)
			_recompute_flow()
			_queue_pending_build(pos, active_tile, action, action_cost)
			emit_signal("global_path_changed")
			return

		# 3) Clear -> build immediately
		if _pending_tile and is_instance_valid(_pending_tile) and _pending_tile.has_method("set_pending_blue"):
			_pending_tile.call("set_pending_blue", false)

		if active_tile.has_method("apply_placement"):
			active_tile.call("apply_placement", action)

		var ok := _recompute_flow()
		if not ok:
			if active_tile.has_method("break_tile"):
				active_tile.call("break_tile")
			_recompute_flow()
			emit_signal("global_path_changed")
			_clear_pending()
			return

		var placed_ok := _placement_succeeded(active_tile, action)
		if placed_ok and action_cost > 0:
			var paid := _econ_spend(action_cost)
			if not paid and active_tile.has_method("break_tile"):
				active_tile.call("break_tile")

		emit_signal("global_path_changed")
		_clear_pending()
		return

	# Non-blocking actions
	if _pending_tile and is_instance_valid(_pending_tile) and _pending_tile.has_method("set_pending_blue"):
		_pending_tile.call("set_pending_blue", false)
	if active_tile.has_method("apply_placement"):
		active_tile.call("apply_placement", action)
	_recompute_flow()
	emit_signal("global_path_changed")
	_clear_pending()

# =============================================================================
# PowerUps adapter (optional)
# =============================================================================
func _power_cost_for(action: String) -> int:
	var base := _cost_for_action(action)
	var pu: Node = get_node_or_null("/root/PowerUps")
	if pu and pu.has_method("modified_cost"):
		return int(pu.call("modified_cost", action, base))
	return base

# =============================================================================
# World-space inner play area (utility)
# =============================================================================
func get_play_bounds_world() -> Dictionary:
	var left   := _grid_origin.x - _step * 0.5
	var right  := _grid_origin.x + (board_size_x - 0.5) * _step
	var top    := _grid_origin.z - _step * 0.5
	var bottom := _grid_origin.z + (board_size_z - 0.5) * _step
	return {"left": left, "right": right, "top": top, "bottom": bottom}
