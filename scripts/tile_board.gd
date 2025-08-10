extends Node3D

@export var board_size: int = 10
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

# Pending/blue
var closing: Dictionary = {}   
var pending_action: Dictionary = {}   
var _pending_mat_cache: Dictionary = {}

# Grid
var _grid_origin: Vector3 = Vector3.ZERO
var _step: float = 1.0

# Shared neighbor offsets
const ORTHO_DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0),
	Vector2i(0, 1), Vector2i(0, -1)
	]

func _ready() -> void:
	generate_board()

	var t00: Node3D = tiles.get(Vector2i(0, 0), null)
	if t00:
		_grid_origin = t00.global_position
	_step = tile_size

	position_portal(goal_node, "right")
	position_portal(spawner_node, "left")

	_recompute_flow()
	if placement_menu:
		placement_menu.connect("place_selected", Callable(self, "_on_place_selected"))

func _physics_process(_delta: float) -> void:
	# Finalize any blue/pending tiles once no enemy is standing on them
	if closing.size() == 0:
		return

	var to_finalize: Array[Vector2i] = []
	for k in closing.keys():
		var cell: Vector2i = k
		if not _any_enemy_on(cell):
			to_finalize.append(cell)

	for c: Vector2i in to_finalize:
		if pending_action.has(c) and tiles.has(c):
			_clear_pending_visual(tiles[c])
			var action: String = pending_action[c]
			pending_action.erase(c)
			closing.erase(c)
			tiles[c].apply_placement(action)
			_recompute_flow()
			emit_signal("global_path_changed")

# Board generation / portals
func generate_board() -> void:
	for x in board_size:
		for z in board_size:
			var tile := tile_scene.instantiate()
			if tile is Node3D:
				var t3d := tile as Node3D
				t3d.global_position = Vector3(x * tile_size, 0, z * tile_size)
			tile.grid_x = x
			tile.grid_z = z
			tile.tile_board = self
			tile.placement_menu = placement_menu
			add_child(tile)
			tiles[Vector2i(x, z)] = tile

func position_portal(portal: Node3D, side: String) -> void:
	var tile_pos := Vector2i()
	var rotation_y := 0.0
	match side:
		"left":
			tile_pos = Vector2i(0, board_size / 2); rotation_y = deg_to_rad(90)
		"right":
			tile_pos = Vector2i(board_size - 1, board_size / 2); rotation_y = deg_to_rad(-90)
		"top":
			tile_pos = Vector2i(board_size / 2, 0); rotation_y = deg_to_rad(0)
		"bottom":
			tile_pos = Vector2i(board_size / 2, board_size - 1); rotation_y = deg_to_rad(180)
	var tile = tiles.get(tile_pos)
	if tile and tile is Node3D:
		var t3d := tile as Node3D
		portal.global_position = t3d.global_position
		portal.rotation.y = rotation_y

# For spawner/enemies
func get_spawn_position() -> Vector3: return spawner_node.global_position
func get_goal_position() -> Vector3:  return goal_node.global_position

# Grid helpers
func in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < board_size and cell.y >= 0 and cell.y < board_size

func is_blocked(cell: Vector2i) -> bool:
	if not in_bounds(cell):
		return true
	# Blue/pending tiles are treated as blocked for routing
	if closing.get(cell, false):
		return true
	if tiles.has(cell):
		var t = tiles[cell]
		if t and t.has_method("is_walkable"):
			return not t.is_walkable()
	return true

func cell_to_world(cell: Vector2i) -> Vector3:
	return Vector3(
		_grid_origin.x + float(cell.x) * _step,
		_grid_origin.y,
		_grid_origin.z + float(cell.y) * _step
	)

func world_to_cell(pos: Vector3) -> Vector2i:
	var x: int = int(round((pos.x - _grid_origin.x) / _step))
	var z: int = int(round((pos.z - _grid_origin.z) / _step))
	return Vector2i(clamp(x, 0, board_size - 1), clamp(z, 0, board_size - 1))

# Flow-field
func _goal_cell() -> Vector2i:
	return world_to_cell(goal_node.global_position)

func _recompute_flow() -> bool:
	var new_cost: Dictionary = {}
	var new_dir: Dictionary = {}

	var goal_cell: Vector2i  = _goal_cell()
	var spawn_cell: Vector2i = world_to_cell(spawner_node.global_position)

	var q: Array[Vector2i] = []
	if in_bounds(goal_cell) and not is_blocked(goal_cell):
		new_cost[goal_cell] = 0
		q.append(goal_cell)

	while q.size() > 0:
		var cur: Vector2i = q.pop_front()
		var cur_cost: int = new_cost[cur]
		for o: Vector2i in ORTHO_DIRS:
			var nb: Vector2i = cur + o
			if not in_bounds(nb) or is_blocked(nb):
				continue
			if not new_cost.has(nb):
				new_cost[nb] = cur_cost + 1
				q.append(nb)

	# If spawn unreachable, keep previous field
	if not new_cost.has(spawn_cell):
		return false

	# Directions toward lowest-cost neighbor
	for x in board_size:
		for z in board_size:
			var g := Vector2i(x, z)
			if not new_cost.has(g):
				continue
			var best := g
			var best_val: int = new_cost[g]
			for o2: Vector2i in ORTHO_DIRS:
				var nb2: Vector2i = g + o2
				if new_cost.has(nb2) and new_cost[nb2] < best_val:
					best_val = new_cost[nb2]
					best = nb2
			var dir_vec: Vector3 = Vector3.ZERO
			if g == goal_cell:
				dir_vec = goal_node.global_position - cell_to_world(g)
				dir_vec.y = 0.0
				if dir_vec.length() > 0.0001:
					dir_vec = dir_vec.normalized()
			elif best != g:
				var a: Vector3 = cell_to_world(g)
				var b: Vector3 = cell_to_world(best)
				dir_vec = b - a
				dir_vec.y = 0.0
				if dir_vec.length() > 0.0001:
					dir_vec = dir_vec.normalized()
			new_dir[g] = dir_vec

	cost = new_cost
	dir_field = new_dir
	return true

func get_dir_for_world(world_pos: Vector3) -> Vector3:
	var g: Vector2i = world_to_cell(world_pos)
	if g == _goal_cell():
		var v_goal: Vector3 = goal_node.global_position - world_pos
		v_goal.y = 0.0
		if v_goal.length() > 0.0001:
			return v_goal.normalized()
		return Vector3.ZERO

	# If standing on a blocked/pending tile, escape to best neighbor
	if is_blocked(g):
		var best := g
		var best_val := 1000000
		for o: Vector2i in ORTHO_DIRS:
			var nb := g + o
			if cost.has(nb) and cost[nb] < best_val:
				best_val = cost[nb]
				best = nb
		if best != g:
			var v2: Vector3 = cell_to_world(best) - world_pos
			v2.y = 0.0
			if v2.length() > 0.0001:
				return v2.normalized()
		return Vector3.ZERO

	return dir_field.get(g, Vector3.ZERO)

func _on_place_selected(action: String) -> void:
	if active_tile == null or not is_instance_valid(active_tile):
		return

	var coords: Vector2i = active_tile.grid_position
	var blocks: bool = (action == "turret" or action == "wall")

	# Non-blocking actions (e.g., repair)
	if not blocks:
		if closing.has(coords):
			closing.erase(coords)
		if pending_action.has(coords):
			pending_action.erase(coords)
		if tiles.has(coords):
			_set_pending_visual(tiles[coords], false)
		active_tile.apply_placement(action)
		_recompute_flow()
		emit_signal("global_path_changed")
		active_tile = null
		return

	if _any_enemy_on(coords):
		closing[coords] = true
		pending_action[coords] = action
		_set_pending_visual(tiles[coords], true)

		# Recompute with the tile treated as blocked
		var path_ok: bool = _recompute_flow()
		emit_signal("global_path_changed")

		# If path becomes disconnected, handle the edge (no shooting)
		if not path_ok:
			await _edge_wait_enemy_off_then_break(coords)
		active_tile = null
		return

	closing[coords] = true
	pending_action[coords] = action
	_set_pending_visual(tiles[coords], true)
	_recompute_flow()
	emit_signal("global_path_changed")

	active_tile.apply_placement(action)
	var ok: bool = _recompute_flow()
	if not ok:
		await _soft_block_sequence(active_tile, action, true) 
	else:
		_clear_pending_visual(tiles[coords])
		closing.erase(coords)
		pending_action.erase(coords)
		emit_signal("global_path_changed")

	active_tile = null

func _any_enemy_on(cell: Vector2i) -> bool:
	var center: Vector3 = cell_to_world(cell)
	var half: float = _step * 0.49
	var min_x: float = center.x - half
	var max_x: float = center.x + half
	var min_z: float = center.z - half
	var max_z: float = center.z + half

	for e in get_tree().get_nodes_in_group("enemy"):
		var px: float = e.global_position.x
		var pz: float = e.global_position.z
		if px >= min_x and px <= max_x and pz >= min_z and pz <= max_z:
			return true
	return false

func _set_pending_visual(tile: Node, on: bool) -> void:
	var mesh: MeshInstance3D = _find_mesh(tile)
	if mesh == null:
		return

	if on:
		if not _pending_mat_cache.has(mesh):
			_pending_mat_cache[mesh] = mesh.material_override
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.25, 0.55, 1.0) # blue
		m.metallic = 0.0
		m.roughness = 1.0
		mesh.material_override = m
	else:
		_clear_pending_visual(tile)

func _clear_pending_visual(tile: Node) -> void:
	var mesh: MeshInstance3D = _find_mesh(tile)
	if mesh == null:
		return
	if _pending_mat_cache.has(mesh):
		mesh.material_override = _pending_mat_cache[mesh]
		_pending_mat_cache.erase(mesh)

func _find_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for c in node.get_children():
		if c is MeshInstance3D:
			return c as MeshInstance3D
	return null


func _cells_reachable_from(start: Vector2i) -> Dictionary:
	var seen := {}
	if not in_bounds(start) or is_blocked(start):
		return seen
	var q: Array[Vector2i] = [start]
	seen[start] = true
	while q.size() > 0:
		var cur: Vector2i = q.pop_front()
		for o in ORTHO_DIRS:
			var nb: Vector2i = cur + o
			if not in_bounds(nb) or is_blocked(nb):
				continue
			if not seen.has(nb):
				seen[nb] = true
				q.push_back(nb)
	return seen

func _pause_enemies_subset(reach: Dictionary, p: bool) -> Array:
	var paused := []
	for e in get_tree().get_nodes_in_group("enemy"):
		var c := world_to_cell(e.global_position)
		if reach.has(c):
			if e.has_method("set_paused"):
				e.set_paused(p)
			if e is Node:
				e.set_physics_process(not p)
			paused.append(e)
	return paused

func _pause_spawner(p: bool) -> void:
	if enemy_spawner == null:
		return
	if enemy_spawner.has_node("Timer"):
		var t: Timer = enemy_spawner.get_node("Timer")
		if p:
			t.stop()
		else:
			t.start()

func _edge_wait_enemy_off_then_break(cell: Vector2i) -> void:
	# Pause upstream enemies/spawner with the BLUE (blocked) cell in place
	var spawn_cell: Vector2i = world_to_cell(spawner_node.global_position)
	var reach: Dictionary = _cells_reachable_from(spawn_cell)
	_pause_spawner(true)
	var paused: Array = _pause_enemies_subset(reach, true)

	# Let the enemy currently on the tile pass
	while _any_enemy_on(cell):
		await get_tree().process_frame

	# Clear BLUE and break the tile (no shooting)
	var tile: Node = tiles.get(cell, null)
	if tile:
		_clear_pending_visual(tile)
	closing.erase(cell)
	pending_action.erase(cell)

	if tile and tile.has_method("break_tile"):
		tile.break_tile()

	_recompute_flow()
	emit_signal("global_path_changed")

	# Resume only those paused
	for e in paused:
		if is_instance_valid(e):
			if e.has_method("set_paused"):
				e.set_paused(false)
			if e is Node:
				e.set_physics_process(true)
	_pause_spawner(false)

func _soft_block_sequence(tile: Node, action: String, already_placed: bool) -> void:
	if not already_placed:
		tile.apply_placement(action)
		_recompute_flow()

	_pause_spawner(true)

	# Compute upstream region with the block present, pause only those enemies
	var spawn_cell: Vector2i = world_to_cell(spawner_node.global_position)
	var reach: Dictionary = _cells_reachable_from(spawn_cell)
	var paused: Array = _pause_enemies_subset(reach, true)

	# Shoot, Sync the break to the projectile flight time.
	var wait_t: float = 1.0
	if enemy_spawner and enemy_spawner.has_method("shoot_tile"):
		wait_t = float(enemy_spawner.shoot_tile(tile.global_position))

	await get_tree().create_timer(wait_t).timeout

	# Clear blue pending on this tile, then break it
	_clear_pending_visual(tile)
	var cell: Vector2i = world_to_cell(tile.global_position)
	if closing.has(cell):
		closing.erase(cell)
	if pending_action.has(cell):
		pending_action.erase(cell)

	if tile.has_method("break_tile"):
		tile.break_tile()

	_recompute_flow()
	emit_signal("global_path_changed")

	# Resume only those paused
	for e in paused:
		if is_instance_valid(e):
			if e.has_method("set_paused"):
				e.set_paused(false)
			if e is Node:
				e.set_physics_process(true)
	_pause_spawner(false)
