extends Node3D

@export var board_size_x: int = 10
@export var board_size_z: int = 10

@export var tile_scene: PackedScene
@export var tile_size: float = 2.0
@export var goal_node: Node3D
@export var spawner_node: Node3D
@export var placement_menu: PopupMenu
@export var enemy_spawner: Node3D

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
	var origin_tile = tiles.get(Vector2i(0, 0), null) as Node3D
	if origin_tile:
		_grid_origin = origin_tile.global_position
	_step = tile_size
	position_portal(goal_node, "right")
	position_portal(spawner_node, "left")
	_recompute_flow()
	placement_menu.connect("place_selected", Callable(self, "_on_place_selected"))

# blue/pending build state
func _physics_process(_delta: float) -> void:
	if closing.is_empty():
		return

	var changed := false
	for pos: Vector2i in closing.keys():
		if _any_enemy_on(pos):
			continue
		if pending_action.has(pos) and tiles.has(pos):
			tiles[pos].set_pending_blue(false)
			tiles[pos].apply_placement(pending_action[pos])
			pending_action.erase(pos)
			closing.erase(pos)
			changed = true

	if changed:
		_recompute_flow()
		emit_signal("global_path_changed")

# Board generation
func generate_board() -> void:
	for x in board_size_x:
		for z in board_size_z:
			var tile = tile_scene.instantiate()
			add_child(tile)

			var pos = Vector2i(x, z)
			tile.position = Vector3(x * tile_size, 0.0, z * tile_size)
			tile.grid_position = pos
			tile.tile_board = self
			tile.placement_menu = placement_menu

			tiles[pos] = tile

func position_portal(portal: Node3D, side: String) -> void:
	var mid_x = board_size_x >> 1
	var mid_z = board_size_z >> 1

	var pos: Vector2i
	var rotation_y := 0.0
	match side:
		"left":
			pos = Vector2i(0, mid_z);                 rotation_y = PI / 2
		"right":
			pos = Vector2i(board_size_x - 1, mid_z);  rotation_y = -PI / 2
		"top":
			pos = Vector2i(mid_x, 0);                 rotation_y = 0.0
		"bottom":
			pos = Vector2i(mid_x, board_size_z - 1);  rotation_y = PI

	var tile = tiles[pos] as Node3D
	portal.global_position = tile.global_position
	portal.rotation.y = rotation_y

# For spawner/enemies
func get_spawn_position() -> Vector3: return spawner_node.global_position
func get_goal_position() -> Vector3:  return goal_node.global_position

# translate grid <-> world
func cell_to_world(pos: Vector2i) -> Vector3:
	return _grid_origin + Vector3(pos.x * _step, 0.0, pos.y * _step)

func world_to_cell(world_pos: Vector3) -> Vector2i:
	var gx := roundi((world_pos.x - _grid_origin.x) / _step)
	var gz := roundi((world_pos.z - _grid_origin.z) / _step)
	return Vector2i(clamp(gx, 0, board_size_x - 1), clamp(gz, 0, board_size_z - 1))

func _goal_cell() -> Vector2i:
	return world_to_cell(goal_node.global_position)

func _recompute_flow() -> bool:
	var new_cost = {}
	var new_dir = {}

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
	var goal_world = goal_node.global_position
	var eps := 0.0001

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
			for o2 in ORTHO_DIRS:
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
	var blocks := (action == "turret" or action == "wall")

	if blocks:
		var gate_cells: Array[Vector2i] = spawn_lane_cells(3)
		if gate_cells.has(pos):
			# Break via the same sequence you use for path blocks.
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
		# Mark blue + defer finalization to _physics_process
		closing[pos] = true
		pending_action[pos] = action
		tiles[pos].set_pending_blue(true)

		var path_ok := _recompute_flow()
		emit_signal("global_path_changed")

		# If the block disconnects the path, run the edge handler (no shooting)
		if not path_ok:
			await _wait_enemy_clear_then_break(pos)
		active_tile = null
		return

	# No enemy on the tile: place immediately
	closing[pos] = true
	pending_action[pos] = action
	tiles[pos].set_pending_blue(true)

	active_tile.apply_placement(action)
	var ok := _recompute_flow()
	if not ok:
		await _soft_block_sequence(active_tile, action, true)
	else:
		tiles[pos].set_pending_blue(false)
		closing.erase(pos)
		pending_action.erase(pos)
		emit_signal("global_path_changed")
	active_tile = null

func _any_enemy_on(pos: Vector2i) -> bool:
	var center = cell_to_world(pos)
	var half = _step * 0.49
	var min_x = center.x - half
	var max_x = center.x + half
	var min_z = center.z - half
	var max_z = center.z + half

	for e: Node3D in get_tree().get_nodes_in_group("enemy"):
		var p = e.global_position
		if p.x >= min_x and p.x <= max_x and p.z >= min_z and p.z <= max_z:
			return true
	return false

# reachability / pause helper
func _cells_reachable_from(start: Vector2i) -> Dictionary:
	var seen: Dictionary = {}

	# Start must exist, not be blue/pending, and be walkable
	if not tiles.has(start) or closing.has(start) or not tiles[start].is_walkable():
		return seen

	var q: Array[Vector2i] = [start]
	seen[start] = true

	while q.size() > 0:
		var cur: Vector2i = q.pop_front()
		for o: Vector2i in ORTHO_DIRS:
			var nb: Vector2i = cur + o
			if not tiles.has(nb): continue       # out of bounds/missing
			if closing.has(nb): continue         # temporarily blocked (blue)
			if not tiles[nb].is_walkable(): continue
			if seen.has(nb): continue           
			seen[nb] = true
			q.push_back(nb)
	return seen

func _pause_enemies_subset(reach: Dictionary, pause: bool) -> Array[Node]:
	var affected: Array[Node] = []
	for e: Node3D in get_tree().get_nodes_in_group("enemy"):
		if reach.has(world_to_cell(e.global_position)):
			e.set_paused(pause)
			e.set_physics_process(not pause)
			affected.append(e)
	return affected

func _pause_enemies_outside(reach: Dictionary, pause: bool) -> Array[Node]:
	var affected: Array[Node] = []
	for e: Node3D in get_tree().get_nodes_in_group("enemy"):
		var cell: Vector2i = world_to_cell(e.global_position)
		if not reach.has(cell):
			e.set_paused(pause)
			e.set_physics_process(not pause)
			affected.append(e)
	return affected

func _wait_enemy_clear_then_break(pos: Vector2i) -> void:
	# Pause spawns + only enemies that cannot reach the goal right now
	enemy_spawner.pause_spawning(true)
	var goal_reach: Dictionary = _cells_reachable_from(_goal_cell())
	var paused: Array = _pause_enemies_outside(goal_reach, true)

	# Let the enemy currently on the tile pass
	while _any_enemy_on(pos):
		await get_tree().process_frame

	# Clear blue and break the tile (no shooting)
	var tile = tiles.get(pos, null)
	if tile:
		tile.set_pending_blue(false)
	closing.erase(pos)
	pending_action.erase(pos)
	tile.break_tile()
	_recompute_flow()
	emit_signal("global_path_changed")

	# Resume only those we paused
	for e in paused:
		if is_instance_valid(e):
			e.set_paused(false)
			e.set_physics_process(true)

	enemy_spawner.pause_spawning(false)


func _soft_block_sequence(tile: Node, action: String, already_placed: bool) -> void:
	# If not placed yet, place so routing reflects the block.
	if not already_placed:
		tile.apply_placement(action)
		_recompute_flow()

	# Pause spawns + only enemies that cannot reach the goal
	enemy_spawner.pause_spawning(true)
	var goal_reach: Dictionary = _cells_reachable_from(_goal_cell())
	var paused: Array = _pause_enemies_outside(goal_reach, true)

	# Fire the breaker shot and wait for its flight time
	var wait_t: float = 1.0
	if enemy_spawner.has_method("shoot_tile"):
		wait_t = float(enemy_spawner.shoot_tile(tile.global_position))
	await get_tree().create_timer(wait_t).timeout

	# Clear blue state and break the tile
	tile.set_pending_blue(false)
	var pos: Vector2i = world_to_cell(tile.global_position)
	if closing.has(pos): closing.erase(pos)
	if pending_action.has(pos): pending_action.erase(pos)

	if tile.has_method("break_tile"):
		tile.break_tile()

	_recompute_flow()
	emit_signal("global_path_changed")

	# Resume only those paused, and resume spawning
	for e in paused:
		if is_instance_valid(e):
			e.set_paused(false)
			e.set_physics_process(true)

	enemy_spawner.pause_spawning(false)


# Add near your other exports:
@export var spawner_span: int = 3


# Computes grid bounds from your tiles dict so we don't depend on board_size.
func _grid_bounds() -> Rect2i:
	var minx := 1_000_000
	var maxx := -1_000_000
	var miny := 1_000_000
	var maxy := -1_000_000
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

	var sp_world := spawner_node.global_transform.origin
	var sp_cell: Vector2i = world_to_cell(sp_world)

	var bounds := _grid_bounds()
	var left := bounds.position.x
	var top := bounds.position.y
	var right := bounds.position.x + bounds.size.x - 1
	var bottom := bounds.position.y + bounds.size.y - 1

	# Which edge are we on?
	var normal := Vector2i.ZERO
	var lateral := Vector2i.ZERO
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

	var half_i: int = int(span / 2)
	var cells: Array[Vector2i] = []
	for i in range(-half_i, half_i + 1):
		var c := sp_cell + lateral * i
		c.x = clampi(c.x, left, right)
		c.y = clampi(c.y, top, bottom)
		cells.append(c)

	# Dedupe after clamping
	var seen := {}
	var lane_centers: Array[Vector3] = []
	for c in cells:
		var key := str(c.x, ",", c.y)
		if not seen.has(key):
			seen[key] = true
			lane_centers.append(cell_to_world(c))

	# Forward/lateral world-space vectors
	var origin_world := cell_to_world(sp_cell)
	var fwd3 := (cell_to_world(sp_cell + normal) - origin_world)
	var lat3 := (cell_to_world(sp_cell + lateral) - origin_world)
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
