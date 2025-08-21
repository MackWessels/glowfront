extends Node3D

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

# --- Bounds config (constants; tweak here if needed) --------------------------
const BOUNDS_THICKNESS: float = 0.35
const BOUNDS_HEIGHT: float = 4.0
const SHOW_BOUNDS_DEBUG := true
const BOUNDS_COLLISION_LAYER: int = 1 << 1     # layer 2; ensure enemies' MASK includes this
const BOUNDS_COLLISION_MASK: int = 0           # static walls don't need a mask

const CARVE_OPENINGS_FOR_PORTALS := true
const GOAL_OPENING_TILES: int = 1
const OPENING_EXTRA_MARGIN_TILES: float = 0.25

const PORTAL_PEN_ENABLED := true
const PORTAL_PEN_DEPTH_TILES: float = 1.0

signal global_path_changed

var tiles: Dictionary = {}
var active_tile: Node = null

# Flow-field
var cost: Dictionary = {}
var dir_field: Dictionary = {}

# Pending/blue state
var closing: Dictionary = {}
var pending_action: Dictionary = {}

# Grid
var _grid_origin: Vector3 = Vector3.ZERO
var _step: float = 1.0

# Shared neighbor offsets (4-connected)
const ORTHO_DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0),
	Vector2i(0, 1), Vector2i(0, -1)
]

func _ready() -> void:
	generate_board()
	var origin_tile: Node3D = tiles.get(Vector2i(0, 0), null) as Node3D
	if origin_tile:
		_grid_origin = origin_tile.global_position
	_step = tile_size

	# Place portals
	position_portal(goal_node, "right")
	position_portal(spawner_node, "left")

	# Build perimeter collisions (just outside the board) with gaps at portals
	_create_bounds()

	_recompute_flow()

	if placement_menu and not placement_menu.is_connected("place_selected", Callable(self, "_on_place_selected")):
		placement_menu.connect("place_selected", Callable(self, "_on_place_selected"))

# blue/pending build state
func _physics_process(_delta: float) -> void:
	if closing.is_empty():
		return

	var changed: bool = false
	for pos: Vector2i in closing.keys():
		if _any_enemy_on(pos):
			continue
		if pending_action.has(pos) and tiles.has(pos):
			var act: String = pending_action[pos]
			var cost_now: int = _power_cost_for(act)

			if cost_now > 0 and not _econ_can_afford(cost_now):
				tiles[pos].set_pending_blue(false)
				pending_action.erase(pos)
				closing.erase(pos)
				changed = true
				continue

			tiles[pos].set_pending_blue(false)
			tiles[pos].apply_placement(act)

			var placed_ok: bool = _placement_succeeded(tiles[pos], act)
			if placed_ok and cost_now > 0:
				var paid: bool = _econ_spend(cost_now)
				if not paid and tiles[pos].has_method("break_tile"):
					tiles[pos].break_tile()

			pending_action.erase(pos)
			closing.erase(pos)
			changed = true

	if changed:
		_recompute_flow()
		emit_signal("global_path_changed")

# --------- Economy (via autoload `Economy`) ---------
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
	var ok: bool = true
	if Economy.has_method("try_spend"):
		ok = bool(Economy.call("try_spend", cost_val, "tileboard_build"))
	elif Economy.has_method("spend"):
		ok = bool(Economy.call("spend", cost_val))
	elif Economy.has_method("set_amount"):
		var bal: int = _econ_balance()
		if bal < cost_val:
			ok = false
		else:
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
			if tile.has_method("has_turret"):
				return bool(tile.call("has_turret"))
			var v: Variant = tile.get("has_turret")
			if typeof(v) == TYPE_BOOL:
				return bool(v)
			var tower: Node = tile.find_child("Tower", true, false)
			return tower != null
		_:
			return true

# --------- Board generation ---------
func generate_board() -> void:
	if tile_scene == null:
		push_error("TileBoard: 'tile_scene' is not assigned in the Inspector.")
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

# --- Perimeter walls (colliders + optional debug mesh), with gaps for portals -
func _create_bounds() -> void:
	var old := get_node_or_null("BoardBounds")
	if old:
		old.queue_free()

	var container := Node3D.new()
	container.name = "BoardBounds"
	add_child(container)

	# world-space board edges (tile centers extend half a step to each side)
	var left   := _grid_origin.x - _step * 0.5
	var right  := _grid_origin.x + (board_size_x - 0.5) * _step
	var top    := _grid_origin.z - _step * 0.5
	var bottom := _grid_origin.z + (board_size_z - 0.5) * _step

	var width  := right - left
	var depth  := bottom - top

	var y_size := BOUNDS_HEIGHT
	var y_pos  := y_size * 0.5

	# openings map by side
	var openings := {
		"left": [], "right": [], "top": [], "bottom": []
	}

	if CARVE_OPENINGS_FOR_PORTALS:
		var bounds := _grid_bounds()

		# Spawner gap (use spawner_span)
		if is_instance_valid(spawner_node):
			var sp_cell := world_to_cell(spawner_node.global_position)
			var sp_side := _side_of_cell(sp_cell, bounds)
			var sp_half := _step * (float(max(1, spawner_span)) * 0.5 + OPENING_EXTRA_MARGIN_TILES)
			if sp_side == "left" or sp_side == "right":
				var cz := cell_to_world(sp_cell).z
				openings[sp_side].append({"center": cz, "half": sp_half})
			else:
				var cx := cell_to_world(sp_cell).x
				openings[sp_side].append({"center": cx, "half": sp_half})

		# Goal gap (usually 1 tile)
		if is_instance_valid(goal_node):
			var g_cell := world_to_cell(goal_node.global_position)
			var g_side := _side_of_cell(g_cell, bounds)
			var g_half := _step * (float(max(1, GOAL_OPENING_TILES)) * 0.5 + OPENING_EXTRA_MARGIN_TILES)
			if g_side == "left" or g_side == "right":
				var cz2 := cell_to_world(g_cell).z
				openings[g_side].append({"center": cz2, "half": g_half})
			else:
				var cx2 := cell_to_world(g_cell).x
				openings[g_side].append({"center": cx2, "half": g_half})

	# NORTH (top) wall — runs along X (thin in Z)
	_build_wall_x(
		container,
		top - BOUNDS_THICKNESS * 0.5,  # z_pos
		left,                           # left
		right,                          # right
		y_pos, y_size,
		BOUNDS_THICKNESS,
		openings["top"]
	)

	# SOUTH (bottom) wall
	_build_wall_x(
		container,
		bottom + BOUNDS_THICKNESS * 0.5,
		left, right,
		y_pos, y_size,
		BOUNDS_THICKNESS,
		openings["bottom"]
	)

	# WEST (left) wall — runs along Z (thin in X)
	_build_wall_z(
		container,
		left - BOUNDS_THICKNESS * 0.5,  # x_pos
		top, bottom,
		y_pos, y_size,
		BOUNDS_THICKNESS,
		openings["left"]
	)

	# EAST (right) wall
	_build_wall_z(
		container,
		right + BOUNDS_THICKNESS * 0.5,
		top, bottom,
		y_pos, y_size,
		BOUNDS_THICKNESS,
		openings["right"]
	)

	# Pens (short tunnels) outside openings to catch knockback
	if PORTAL_PEN_ENABLED:
		_add_portal_pens(
			container,
			left, right, top, bottom,
			y_pos, y_size,
			BOUNDS_THICKNESS,
			openings
		)

func _side_of_cell(cell: Vector2i, b: Rect2i) -> String:
	var left_i := b.position.x
	var top_i := b.position.y
	var right_i := b.position.x + b.size.x - 1
	var bottom_i := b.position.y + b.size.y - 1
	if cell.x <= left_i: return "left"
	elif cell.x >= right_i: return "right"
	elif cell.y <= top_i: return "top"
	else: return "bottom"

func _build_wall_x(parent: Node, z_pos: float, left: float, right: float, y_pos: float, y_size: float, thickness: float, openings: Array) -> void:
	var start := left - thickness
	var end := right + thickness
	var segments := _segments_along(start, end, openings)
	for seg in segments:
		var cx: float = seg["center"]
		var L: float = seg["len"]
		if L <= 0.001: continue
		_make_wall(parent, Vector3(cx, y_pos, z_pos), Vector3(L, y_size, thickness))

func _build_wall_z(parent: Node, x_pos: float, top: float, bottom: float, y_pos: float, y_size: float, thickness: float, openings: Array) -> void:
	var start := top - thickness
	var end := bottom + thickness
	var segments := _segments_along(start, end, openings)
	for seg in segments:
		var cz: float = seg["center"]
		var L: float = seg["len"]
		if L <= 0.001: continue
		_make_wall(parent, Vector3(x_pos, y_pos, cz), Vector3(thickness, y_size, L))

func _segments_along(start: float, end: float, openings: Array) -> Array:
	var segs: Array = []
	var cur := start

	var ops := openings.duplicate()
	ops.sort_custom(func(a, b): return a["center"] < b["center"])

	for op in ops:
		var half: float = op["half"]
		var c: float = op["center"]
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

# Build U-shaped pens around each opening so units can't be knocked OOB behind portals.
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

	# LEFT side pens (opening along Z, tunnel extends to -X)
	for op in openings.get("left", []):
		var c: float = float(op["center"])
		var half: float = float(op["half"])
		var x_center: float = left - thickness * 0.5 - depth * 0.5

		_make_wall(parent, Vector3(x_center, y_pos, (c - half) - thickness * 0.5), Vector3(depth, y_size, thickness))
		_make_wall(parent, Vector3(x_center, y_pos, (c + half) + thickness * 0.5), Vector3(depth, y_size, thickness))
		_make_wall(parent, Vector3(left - thickness * 0.5 - depth, y_pos, c), Vector3(thickness, y_size, (half * 2.0) + thickness * 2.0))

	# RIGHT side pens (tunnel extends to +X)
	for op in openings.get("right", []):
		var c2: float = float(op["center"])
		var half2: float = float(op["half"])
		var x_center2: float = right + thickness * 0.5 + depth * 0.5

		_make_wall(parent, Vector3(x_center2, y_pos, (c2 - half2) - thickness * 0.5), Vector3(depth, y_size, thickness))
		_make_wall(parent, Vector3(x_center2, y_pos, (c2 + half2) + thickness * 0.5), Vector3(depth, y_size, thickness))
		_make_wall(parent, Vector3(right + thickness * 0.5 + depth, y_pos, c2), Vector3(thickness, y_size, (half2 * 2.0) + thickness * 2.0))

	# TOP side pens (opening along X, tunnel extends to -Z)
	for op in openings.get("top", []):
		var c3: float = float(op["center"])
		var half3: float = float(op["half"])
		var z_center: float = top - thickness * 0.5 - depth * 0.5

		_make_wall(parent, Vector3((c3 - half3) - thickness * 0.5, y_pos, z_center), Vector3(thickness, y_size, depth))
		_make_wall(parent, Vector3((c3 + half3) + thickness * 0.5, y_pos, z_center), Vector3(thickness, y_size, depth))
		_make_wall(parent, Vector3(c3, y_pos, top - thickness * 0.5 - depth), Vector3((half3 * 2.0) + thickness * 2.0, y_size, thickness))

	# BOTTOM side pens (tunnel extends to +Z)
	for op in openings.get("bottom", []):
		var c4: float = float(op["center"])
		var half4: float = float(op["half"])
		var z_center2: float = bottom + thickness * 0.5 + depth * 0.5

		_make_wall(parent, Vector3((c4 - half4) - thickness * 0.5, y_pos, z_center2), Vector3(thickness, y_size, depth))
		_make_wall(parent, Vector3((c4 + half4) + thickness * 0.5, y_pos, z_center2), Vector3(thickness, y_size, depth))
		_make_wall(parent, Vector3(c4, y_pos, bottom + thickness * 0.5 + depth), Vector3((half4 * 2.0) + thickness * 2.0, y_size, thickness))


func _make_wall(parent: Node, position: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = "BoundWall"
	body.global_position = position
	body.collision_layer = BOUNDS_COLLISION_LAYER
	body.collision_mask  = BOUNDS_COLLISION_MASK
	parent.add_child(body)

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
		mat.albedo_color = Color(1.0, 0.2, 0.2, 0.25) # translucent red
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mesh_inst.material_override = mat

		body.add_child(mesh_inst)

func position_portal(portal: Node3D, side: String) -> void:
	var mid_x: int = board_size_x >> 1
	var mid_z: int = board_size_z >> 1

	var pos: Vector2i
	var rotation_y: float = 0.0
	match side:
		"left":
			pos = Vector2i(0, mid_z);                 rotation_y = PI / 2.0
		"right":
			pos = Vector2i(board_size_x - 1, mid_z);  rotation_y = -PI / 2.0
		"top":
			pos = Vector2i(mid_x, 0);                 rotation_y = 0.0
		"bottom":
			pos = Vector2i(mid_x, board_size_z - 1);  rotation_y = PI

	var tile: Node3D = tiles[pos] as Node3D
	portal.global_position = tile.global_position
	portal.rotation.y = rotation_y

# For spawner/enemies
func get_spawn_position() -> Vector3: return spawner_node.global_position
func get_goal_position() -> Vector3:  return goal_node.global_position

# translate grid <-> world
func cell_to_world(pos: Vector2i) -> Vector3:
	return _grid_origin + Vector3(pos.x * _step, 0.0, pos.y * _step)

func world_to_cell(world_pos: Vector3) -> Vector2i:
	var gx: int = roundi((world_pos.x - _grid_origin.x) / _step)
	var gz: int = roundi((world_pos.z - _grid_origin.z) / _step)
	return Vector2i(clamp(gx, 0, board_size_x - 1), clamp(gz, 0, board_size_z - 1))

func _goal_cell() -> Vector2i:
	return world_to_cell(goal_node.global_position)

func _recompute_flow() -> bool:
	var new_cost: Dictionary = {}
	var new_dir: Dictionary = {}

	var goal_cell: Vector2i  = _goal_cell()
	var spawn_cell: Vector2i = world_to_cell(spawner_node.global_position)

	var q: Array[Vector2i] = []
	# Seed from goal if the goal tile exists, isn't blue, and is walkable.
	if tiles.has(goal_cell) and not closing.get(goal_cell, false) and tiles[goal_cell].is_walkable():
		new_cost[goal_cell] = 0
		q.append(goal_cell)

	# BFS over 4-neighbors
	while q.size() > 0:
		var cur: Vector2i = q.pop_front()
		var cur_cost: int = int(new_cost[cur])
		for o: Vector2i in ORTHO_DIRS:
			var nb: Vector2i = cur + o
			if not tiles.has(nb): continue
			if closing.get(nb, false): continue
			if not tiles[nb].is_walkable(): continue
			if not new_cost.has(nb):
				new_cost[nb] = cur_cost + 1
				q.append(nb)

	# If spawn unreachable, keep previous field
	if not new_cost.has(spawn_cell):
		return false

	# Build directions only for reachable cells
	var goal_world: Vector3 = goal_node.global_position
	var eps: float = 0.0001

	for key in new_cost.keys():
		var g: Vector2i = key as Vector2i
		var dir_vec: Vector3 = Vector3.ZERO

		if g == goal_cell:
			dir_vec = goal_world - cell_to_world(g)
			dir_vec.y = 0.0
			var L0: float = dir_vec.length()
			if L0 > eps:
				dir_vec = dir_vec / L0
		else:
			var best: Vector2i = g
			var best_val: int = int(new_cost[g])
			for o2: Vector2i in ORTHO_DIRS:
				var nb2: Vector2i = g + o2
				if new_cost.has(nb2) and int(new_cost[nb2]) < best_val:
					best_val = int(new_cost[nb2])
					best = nb2

			if best != g:
				var from: Vector3 = cell_to_world(g)
				var to: Vector3 = cell_to_world(best)
				var d: Vector3 = to - from
				d.y = 0.0
				var L: float = d.length()
				if L > eps:
					dir_vec = d / L

		new_dir[g] = dir_vec

	cost = new_cost
	dir_field = new_dir
	return true

# Placement / pending flow
func _on_place_selected(action: String) -> void:
	if active_tile == null or not is_instance_valid(active_tile):
		return

	var pos: Vector2i = active_tile.grid_position
	var blocks: bool = (action == "turret" or action == "wall")

	# ECON pre-check (uses discounted/modified cost)
	var action_cost: int = _power_cost_for(action)
	if action_cost > 0 and not _econ_can_afford(action_cost):
		return

	if blocks:
		var gate_cells: Array[Vector2i] = spawn_lane_cells(3)
		if gate_cells.has(pos):
			await _soft_block_sequence(active_tile, action, false)
			active_tile = null
			return

	# Non-blocking actions
	if not blocks:
		if closing.has(pos): closing.erase(pos)
		if pending_action.has(pos): pending_action.erase(pos)
		if tiles.has(pos): tiles[pos].set_pending_blue(false)
		active_tile.apply_placement(action)
		if _recompute_flow():
			emit_signal("global_path_changed")
		active_tile = null
		return

	# Blocking actions (turret/wall)
	if _any_enemy_on(pos):
		closing[pos] = true
		pending_action[pos] = action
		tiles[pos].set_pending_blue(true)

		var path_ok: bool = _recompute_flow()
		emit_signal("global_path_changed")

		if not path_ok:
			await _wait_enemy_clear_then_break(pos)
		active_tile = null
		return

	# No enemy on the tile: place immediately, but charge only if final OK
	closing[pos] = true
	pending_action[pos] = action
	tiles[pos].set_pending_blue(true)

	active_tile.apply_placement(action)
	var ok: bool = _recompute_flow()
	if not ok:
		await _soft_block_sequence(active_tile, action, true)
	else:
		var placed_ok: bool = _placement_succeeded(active_tile, action)
		if placed_ok:
			var cost_to_charge: int = _power_cost_for(action)
			if cost_to_charge > 0:
				var paid: bool = _econ_spend(cost_to_charge)
				if not paid and active_tile.has_method("break_tile"):
					active_tile.break_tile()

		tiles[pos].set_pending_blue(false)
		closing.erase(pos)
		pending_action.erase(pos)
		emit_signal("global_path_changed")
	active_tile = null

func _any_enemy_on(pos: Vector2i) -> bool:
	var center: Vector3 = cell_to_world(pos)
	var half: float = _step * 0.49
	var min_x: float = center.x - half
	var max_x: float = center.x + half
	var min_z: float = center.z - half
	var max_z: float = center.z + half

	for e: Node3D in get_tree().get_nodes_in_group("enemy"):
		var p: Vector3 = e.global_position
		if p.x >= min_x and p.x <= max_x and p.z >= min_z and p.z <= max_z:
			return true
	return false

# reachability / idle helper
func _cells_reachable_from(start: Vector2i) -> Dictionary:
	var seen: Dictionary = {}
	if not tiles.has(start) or closing.has(start) or not tiles[start].is_walkable():
		return seen

	var q: Array[Vector2i] = [start]
	seen[start] = true

	while q.size() > 0:
		var cur: Vector2i = q.pop_front()
		for o: Vector2i in ORTHO_DIRS:
			var nb: Vector2i = cur + o
			if not tiles.has(nb): continue
			if closing.has(nb): continue
			if not tiles[nb].is_walkable(): continue
			if seen.has(nb): continue
			seen[nb] = true
			q.push_back(nb)
	return seen

func _idle_enemies_outside(reach: Dictionary, idle_on: bool, skip_cells: Array = []) -> Array[Node]:
	var affected: Array[Node] = []
	for e: Node3D in get_tree().get_nodes_in_group("enemy"):
		var cell: Vector2i = world_to_cell(e.global_position)
		if skip_cells.has(cell):
			continue
		if not reach.has(cell):
			if e.has_method("set_idle"):
				e.call("set_idle", idle_on)
			affected.append(e)
	return affected

func _wait_enemy_clear_then_break(pos: Vector2i) -> void:
	enemy_spawner.pause_spawning(true)
	var goal_reach: Dictionary = _cells_reachable_from(_goal_cell())

	var idled: Array = _idle_enemies_outside(goal_reach, true, [pos])

	while _any_enemy_on(pos):
		await get_tree().process_frame

	var tile: Node = tiles.get(pos, null)
	if tile:
		tile.set_pending_blue(false)
	closing.erase(pos)
	pending_action.erase(pos)
	tile.break_tile()
	_recompute_flow()
	emit_signal("global_path_changed")

	for e in idled:
		if is_instance_valid(e):
			if e.has_method("set_idle"):
				e.call("set_idle", false)

	enemy_spawner.pause_spawning(false)

func _soft_block_sequence(tile: Node, action: String, already_placed: bool) -> void:
	if not already_placed:
		tile.apply_placement(action)
		_recompute_flow()

	enemy_spawner.pause_spawning(true)
	var goal_reach: Dictionary = _cells_reachable_from(_goal_cell())
	var pos: Vector2i = world_to_cell(tile.global_position)

	var idled: Array = _idle_enemies_outside(goal_reach, true, [pos])

	var wait_t: float = 1.0
	if enemy_spawner.has_method("shoot_tile"):
		wait_t = float(enemy_spawner.shoot_tile(tile.global_position))
	await get_tree().create_timer(wait_t).timeout

	tile.set_pending_blue(false)
	if closing.has(pos): closing.erase(pos)
	if pending_action.has(pos): pending_action.erase(pos)

	if tile.has_method("break_tile"):
		tile.break_tile()

	_recompute_flow()
	emit_signal("global_path_changed")

	for e in idled:
		if is_instance_valid(e):
			if e.has_method("set_idle"):
				e.call("set_idle", false)

	enemy_spawner.pause_spawning(false)

# Computes grid bounds from your tiles dict so we don't depend on board_size.
func _grid_bounds() -> Rect2i:
	var minx: int = 1000000
	var maxx: int = -1000000
	var miny: int = 1000000
	var maxy: int = -1000000
	for c in tiles.keys():
		var cc: Vector2i = c
		if cc.x < minx: minx = cc.x
		if cc.x > maxx: maxx = cc.x
		if cc.y < miny: miny = cc.y
		if cc.y > maxy: maxy = cc.y
	if maxx < minx or maxy < miny:
		return Rect2i(Vector2i.ZERO, Vector2i(1, 1))
	return Rect2i(Vector2i(minx, miny), Vector2i(maxx - minx + 1, maxy - miny + 1))

# Provide multi-lane spawn geometry to the spawner.
func get_spawn_gate(span: int = -1) -> Dictionary:
	if span <= 0:
		span = spawner_span

	var sp_world: Vector3 = spawner_node.global_transform.origin
	var sp_cell: Vector2i = world_to_cell(sp_world)

	var bounds: Rect2i = _grid_bounds()
	var left: int = bounds.position.x
	var top: int = bounds.position.y
	var right: int = bounds.position.x + bounds.size.x - 1
	var bottom: int = bounds.position.y + bounds.size.y - 1

	# Which edge are we on?
	var normal: Vector2i = Vector2i.ZERO
	var lateral: Vector2i = Vector2i.ZERO
	if sp_cell.x <= left:
		normal = Vector2i(1, 0)
		lateral = Vector2i(0, 1)
	elif sp_cell.x >= right:
		normal = Vector2i(-1, 0)
		lateral = Vector2i(0, 1)
	elif sp_cell.y <= top:
		normal = Vector2i(0, 1)
		lateral = Vector2i(1, 0)
	else:
		normal = Vector2i(0, -1)
		lateral = Vector2i(1, 0)

	@warning_ignore("integer_division")
	var half_i: int = int(span / 2)
	var cells: Array[Vector2i] = []
	for i in range(-half_i, half_i + 1):
		var c: Vector2i = sp_cell + lateral * i
		c.x = clampi(c.x, left, right)
		c.y = clampi(c.y, top, bottom)
		cells.append(c)

	# Dedupe after clamping
	var seen: Dictionary = {}
	var lane_centers: Array[Vector3] = []
	for c in cells:
		var key: String = str(c.x, ",", c.y)
		if not seen.has(key):
			seen[key] = true
			lane_centers.append(cell_to_world(c))

	# Forward/lateral world-space vectors
	var origin_world: Vector3 = cell_to_world(sp_cell)
	var fwd3: Vector3 = (cell_to_world(sp_cell + normal) - origin_world)
	var lat3: Vector3 = (cell_to_world(sp_cell + lateral) - origin_world)
	if fwd3.length() < 0.001: fwd3 = Vector3.FORWARD
	else: fwd3 = fwd3.normalized()
	if lat3.length() < 0.001: lat3 = Vector3.RIGHT
	else: lat3 = lat3.normalized()

	return {
		"lane_centers": lane_centers,
		"forward": fwd3,
		"lateral": lat3,
		"gate_radius": tile_size * 0.7
	}

func spawn_lane_cells(span: int = -1) -> Array[Vector2i]:
	if span <= 0:
		span = spawner_span
	var info: Dictionary = get_spawn_gate(span)
	var centers: Array = []
	if info.has("lane_centers"):
		centers = info["lane_centers"]

	var cells: Array[Vector2i] = []
	for p in centers:
		var pw: Vector3 = p
		cells.append(world_to_cell(pw))
	return cells

# PowerUps cost adapter
func _power_cost_for(action: String) -> int:
	var base: int = _cost_for_action(action)
	var pu: Node = get_node_or_null("/root/PowerUps")
	if pu and pu.has_method("modified_cost"):
		return int(pu.call("modified_cost", action, base))
	return base
