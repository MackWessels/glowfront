extends Node3D

# =============================================================================
# Inspector
# =============================================================================
@export var spawner_span: int = 3        # width (in cells) across the spawner edge
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

# Single enemy group used for occupancy checks
const ENEMY_GROUP: String = "enemy"

# Pending polling rate
const PENDING_POLL_HZ := 6.0

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

# builds waiting for enemies to step off
var _pending_builds: Array[Dictionary] = []   # {"cell":Vector2i,"tile":Node,"action":String,"cost":int}

# legacy compat (not used for paint)
var closing: Dictionary = {}

# flow-field
var cost: Dictionary = {}      # Vector2i -> int (BFS distance from goal)
var dir_field: Dictionary = {} # Vector2i -> Vector3 (unit dir toward lower cost)

# grid
var _grid_origin: Vector3 = Vector3.ZERO
var _step: float = 1.0

# polling accumulator
var _poll_accum: float = 0.0

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

	# keep portal placement intact
	position_portal(goal_node, "right")
	position_portal(spawner_node, "left")

	_recompute_flow()

	# Placement menu
	if placement_menu and not placement_menu.is_connected("place_selected", Callable(self, "_on_place_selected")):
		placement_menu.connect("place_selected", Callable(self, "_on_place_selected"))

func _physics_process(delta: float) -> void:
	# Poll pending builds at a gentle rate to avoid per-frame work
	if _pending_builds.size() > 0:
		_poll_accum += delta
		var interval := 1.0 / PENDING_POLL_HZ
		if _poll_accum >= interval:
			_poll_accum = 0.0
			_poll_pending_builds()

# =============================================================================
# Public helpers needed by Enemy
# =============================================================================
func tile_world_size() -> float:
	return _step

func cell_center(c: Vector2i) -> Vector3:
	return cell_to_world(c)

# Back-compat name if you use it elsewhere
func tile_center(c: Vector2i) -> Vector3:
	return cell_to_world(c)

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
# Portals positioning (no pens/walls) — KEEPING INTACT
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
	return goal_node.global_position

# =============================================================================
# Grid helpers
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

func _in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.x < board_size_x and c.y >= 0 and c.y < board_size_z

# Which edge a cell sits on (relative to board bounds)
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

# =============================================================================
# Spawner helpers (pen-less, conveyor-friendly)
# =============================================================================
func get_spawn_pen(span: int = -1) -> Dictionary:
	if span <= 0:
		span = spawner_span
	var b := _grid_bounds()

	# snap spawner to the nearest edge cell
	var sp_world: Vector3 = spawner_node.global_position
	var sp_cell: Vector2i = world_to_cell(sp_world)
	var side := _side_of_cell(sp_cell, b)

	var edge_cell := sp_cell
	if side == "left":
		edge_cell.x = b.position.x
	elif side == "right":
		edge_cell.x = b.position.x + b.size.x - 1
	elif side == "top":
		edge_cell.y = b.position.y
	else:
		edge_cell.y = b.position.y + b.size.y - 1

	var normal := Vector2i.ZERO
	var lateral := Vector2i.ZERO
	if side == "left":
		normal = Vector2i(1, 0);  lateral = Vector2i(0, 1)
	elif side == "right":
		normal = Vector2i(-1, 0); lateral = Vector2i(0, 1)
	elif side == "top":
		normal = Vector2i(0, 1);  lateral = Vector2i(1, 0)
	else:
		normal = Vector2i(0, -1); lateral = Vector2i(1, 0)

	@warning_ignore("integer_division")
	var half_i: int = int(span / 2)

	# collect a centered run of edge cells
	var board_cells: Array[Vector2i] = []
	for i in range(-half_i, half_i + 1):
		var c := edge_cell + lateral * i
		c.x = clampi(c.x, b.position.x, b.position.x + b.size.x - 1)
		c.y = clampi(c.y, b.position.y, b.position.y + b.size.y - 1)
		board_cells.append(c)

	# dedupe (in case of clamps)
	var seen: Dictionary = {}
	var entry_targets: Array[Vector3] = []
	for c in board_cells:
		var key := str(c.x, ",", c.y)
		if not seen.has(key):
			seen[key] = true
			entry_targets.append(cell_to_world(c))

	# forward/lateral in world space
	var base_w := cell_to_world(edge_cell)
	var fwd3 := cell_to_world(edge_cell + normal) - base_w
	var lat3 := cell_to_world(edge_cell + lateral) - base_w
	if fwd3.length() < 0.001:
		fwd3 = Vector3.FORWARD
	else:
		fwd3 = fwd3.normalized()
	if lat3.length() < 0.001:
		lat3 = Vector3.RIGHT
	else:
		lat3 = lat3.normalized()

	# No outside pen; spawn right on the edge cells
	var pen_centers := entry_targets.duplicate()

	return {
		"pen_centers": pen_centers,
		"entry_targets": entry_targets,
		"forward": fwd3,
		"lateral": lat3,
		"spawn_radius": tile_size * 0.35,
		"exit_radius":  tile_size * 0.35
	}

func spawn_pen_cells(span: int = -1) -> Array[Vector2i]:
	var info := get_spawn_pen(span)
	var targets: Array = info.get("entry_targets", [])
	var cells: Array[Vector2i] = []
	for p in targets:
		var pw: Vector3 = p
		cells.append(world_to_cell(pw))
	return cells

# =============================================================================
# Flow-field + reservations
# =============================================================================
func _recompute_flow() -> bool:
	var new_cost: Dictionary = {}
	var new_dir: Dictionary = {}

	var goal_cell: Vector2i  = _goal_cell()
	var spawn_cell: Vector2i = world_to_cell(spawner_node.global_position)

	# BFS from goal across walkable tiles
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

	# At each cell, point toward a neighbor with lower cost (greedy gradient)
	for key in new_cost.keys():
		var cell: Vector2i = key
		var dir_v := Vector3.ZERO

		if cell != goal_cell:
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
		# goal cell keeps ZERO vector (arrival)

		new_dir[cell] = dir_v

	# Provide an escape direction for reserved cells so enemies can leave
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
# Enemy steering API (optional smooth sampling)
# =============================================================================
func sample_flow_dir_smooth(world_pos: Vector3) -> Vector3:
	var fx := (world_pos.x - _grid_origin.x) / _step
	var fz := (world_pos.z - _grid_origin.z) / _step

	var max_xf := float(board_size_x - 1) - 0.001
	var max_zf := float(board_size_z - 1) - 0.001
	fx = clampf(fx, 0.0, max_xf)
	fz = clampf(fz, 0.0, max_zf)

	var i := int(floor(fx))
	var j := int(floor(fz))
	var u := fx - float(i)
	var v := fz - float(j)

	var c00 := Vector2i(i, j)
	var c10 := Vector2i(i + 1, j)
	var c01 := Vector2i(i, j + 1)
	var c11 := Vector2i(i + 1, j + 1)

	var d00 := Vector3.ZERO
	var d10 := Vector3.ZERO
	var d01 := Vector3.ZERO
	var d11 := Vector3.ZERO

	if dir_field.has(c00): d00 = dir_field[c00]
	if dir_field.has(c10): d10 = dir_field[c10]
	if dir_field.has(c01): d01 = dir_field[c01]
	if dir_field.has(c11): d11 = dir_field[c11]

	var a := d00 * (1.0 - u) + d10 * u
	var b := d01 * (1.0 - u) + d11 * u
	var blended := a * (1.0 - v) + b * v

	if blended.length_squared() < 1e-6:
		return Vector3.ZERO
	return blended.normalized()

# Convert flow/cost to a reliable next grid cell (used by Enemy segment walker)
func next_cell_from(c: Vector2i) -> Vector2i:
	if c == _goal_cell():
		return c
	if not _in_bounds(c):
		return c

	var best := c
	var have_best := false
	var best_val := 0

	if cost.has(c):
		var cur_val := int(cost[c])
		for o in ORTHO_DIRS:
			var nb := c + o
			if cost.has(nb):
				var nb_val := int(cost[nb])
				if nb_val < cur_val:
					if not have_best or nb_val < best_val:
						best = nb
						best_val = nb_val
						have_best = true

	if have_best:
		return best

	# Fallback: use dir_field step if present (helps enemies leave reserved cells)
	if dir_field.has(c):
		var v: Vector3 = dir_field[c]
		if v.length_squared() > 0.0:
			var step := Vector2i.ZERO
			if absf(v.x) >= absf(v.z):
				step.x = signi(v.x)
			else:
				step.y = signi(v.z)
			var n := c + step
			n.x = clampi(n.x, 0, board_size_x - 1)
			n.y = clampi(n.y, 0, board_size_z - 1)
			return n

	# Final fallback: greedy toward goal by larger axis gap
	var g := _goal_cell()
	var dx := signi(g.x - c.x)
	var dz := signi(g.y - c.y)
	if abs(g.x - c.x) >= abs(g.y - c.y):
		return Vector2i(clampi(c.x + dx, 0, board_size_x - 1), c.y)
	else:
		return Vector2i(c.x, clampi(c.y + dz, 0, board_size_z - 1))

# =============================================================================
# Enemy detection & reservations (polling version)
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
	else:
		if _reserved_cells.has(cell):
			_reserved_cells.erase(cell)

# Check each pending build; if cell empty, commit
func _poll_pending_builds() -> void:
	# iterate from end so remove_at is safe
	for i in range(_pending_builds.size() - 1, -1, -1):
		var item: Dictionary = _pending_builds[i]
		var cell: Vector2i = item["cell"]
		var tile: Node = item["tile"]
		if not is_instance_valid(tile):
			_reserved_cells.erase(cell)
			_pending_builds.remove_at(i)
			continue

		var occ := _enemies_on_cell(cell)
		if occ.size() == 0:
			_commit_pending_item(i)

func _commit_pending_item(index: int) -> void:
	if index < 0 or index >= _pending_builds.size():
		return

	var item: Dictionary = _pending_builds[index]
	var cell: Vector2i = item["cell"]
	var tile: Node = item["tile"]
	var action_str: String = String(item["action"])
	var cval: int = int(item["cost"])

	# Clear blue highlight
	if tile and tile.has_method("set_pending_blue"):
		tile.call("set_pending_blue", false)

	# Release reservation (we’re about to place)
	_reserve_cell(cell, false)

	# Place
	if tile and tile.has_method("apply_placement"):
		tile.call("apply_placement", action_str)

	# Recompute path; if fails, break and restore flow
	var ok := _recompute_flow()
	if not ok:
		if tile and tile.has_method("break_tile"):
			tile.call("break_tile")
		_recompute_flow()
	else:
		# Charge if placement truly succeeded
		var placed_ok := _placement_succeeded(tile, action_str)
		if placed_ok and cval > 0:
			var paid := _econ_spend(cval)
			if not paid and tile and tile.has_method("break_tile"):
				tile.call("break_tile")

	emit_signal("global_path_changed")
	_pending_builds.remove_at(index)

# =============================================================================
# Building – polling version (RED = break tile, BLUE = pending)
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

		# 2) Path OK but an enemy stands on it -> blue pending (poll until clear)
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
# Queue helper
# =============================================================================
func _queue_pending_build(cell: Vector2i, tile: Node, action: String, cost_val: int) -> void:
	var item: Dictionary = {
		"cell": cell,
		"tile": tile,
		"action": action,
		"cost": cost_val
	}
	_pending_builds.append(item)
	_poll_accum = 0.0  # nudge poll soon after queuing
