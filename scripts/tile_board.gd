extends Node3D

# ---------------- Inspector ----------------
@export var spawner_span: int = 3
@export var goal_span: int = 1
@export var board_size_x: int = 10
@export var board_size_z: int = 11
@export var tile_scene: PackedScene
@export var tile_size: float = 2.0
@export var goal_node: Node3D
@export var spawner_node: Node3D
@export var placement_menu: PopupMenu

# Costs
@export var turret_cost: int = 10
@export var mortar_cost: int = 20

# Bounds & pens
@export var use_bounds: bool = true
@export var carve_openings_for_portals: bool = true
@export var wall_thickness: float = 0.35
@export var wall_height: float = 2.5

var _debug_mesh_enabled := false
@export var render_debug_wall_mesh := false:
	set(value):
		_debug_mesh_enabled = value
		if is_inside_tree() and use_bounds:
			_create_bounds()
	get:
		return _debug_mesh_enabled

# Collision (Enemy on Layer 3, mask includes 2)
@export var wall_collision_layer: int = 1 << 1
@export var wall_collision_mask:  int = 1 << 2

# Pens
@export var build_spawn_pen: bool = true
@export var build_goal_pen: bool = true
@export var pen_depth_cells: int = 2
@export var pen_wing_cells: int = 0
@export var pen_thickness: float = 0.35
@export var pen_height: float = 2.5
@export var pen_entry_inset: float = 0.30

# Flow
@export var goal_points_outward: bool = true

# Off-board spawner anchoring
@export var anchor_spawner_offboard: bool = true
@export var offboard_distance_tiles: float = 1.0

# Groups / polling
const ENEMY_GROUP: String = "enemy"
const PENDING_POLL_HZ := 6.0

# ---------------- Signals ----------------
signal global_path_changed

# ---------------- State ----------------
var tiles: Dictionary = {}                    # Vector2i -> Node3D
var active_tile: Node = null

var _pending_tile: Node = null
var _reserved_cells: Dictionary = {}          # Vector2i -> true
# item = {"cell":Vector2i,"cells":Array[Vector2i], "tile":Node, "action":String, "cost":int}
var _pending_builds: Array[Dictionary] = []

var cost: Dictionary = {}                     # Vector2i -> int
var dir_field: Dictionary = {}                # Vector2i -> Vector3

var _grid_origin: Vector3 = Vector3.ZERO
var _step: float = 1.0
var _poll_accum: float = 0.0

var path_version: int = 0

const ORTHO_DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0),
	Vector2i(0, 1), Vector2i(0, -1)
]
const EPS := 0.0001

# ---------------- Lifecycle ----------------
func _ready() -> void:
	add_to_group("TileBoard")
	generate_board()

	var origin_tile := tiles.get(Vector2i(0, 0), null) as Node3D
	_grid_origin = (origin_tile.global_position if origin_tile != null else global_position)
	_step = tile_size

	position_portal(goal_node, "right")
	position_portal(spawner_node, "left")
	_place_spawner_offboard_strip()

	_apply_initial_board_from_powerups()
	if use_bounds:
		_create_bounds()

	_recompute_flow()
	_emit_path_changed()

	if placement_menu and not placement_menu.is_connected("place_selected", Callable(self, "_on_place_selected")):
		placement_menu.connect("place_selected", Callable(self, "_on_place_selected"))

	call_deferred("_connect_powerups")

func _physics_process(delta: float) -> void:
	if _pending_builds.size() > 0:
		_poll_accum += delta
		var interval := 1.0 / PENDING_POLL_HZ
		if _poll_accum >= interval:
			_poll_accum = 0.0
			_poll_pending_builds()

func rebuild_bounds() -> void:
	if use_bounds:
		_create_bounds()

# ---------------- PowerUps hookup ----------------
func _connect_powerups() -> void:
	var pu := get_node_or_null("/root/PowerUps")
	if pu == null:
		return
	if pu.has_signal("upgrade_purchased") and not pu.is_connected("upgrade_purchased", Callable(self, "_on_upgrade_purchased")):
		pu.connect("upgrade_purchased", Callable(self, "_on_upgrade_purchased"))

func _on_upgrade_purchased(id: String, _lvl: int, _next_cost: int) -> void:
	match id:
		"board_add_left":  _add_row_at_top()
		"board_add_right": _add_row_at_bottom()
		"board_push_back": _add_column_at_spawner_edge()

# ---------------- Public helpers (Enemy) ----------------
func tile_world_size() -> float: return _step
func cell_center(c: Vector2i) -> Vector3: return cell_to_world(c)
func is_in_bounds(c: Vector2i) -> bool: return _in_bounds(c)

# ---------------- Pending/highlight ----------------
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

# ---------------- Economy ----------------
func _econ_balance() -> int:
	if Economy.has_method("balance"): return int(Economy.call("balance"))
	var v: Variant = Economy.get("minerals")
	return int(v) if typeof(v) == TYPE_INT else 0

func _econ_can_afford(cost_val: int) -> bool:
	if cost_val <= 0: return true
	if Economy.has_method("can_afford"):
		return bool(Economy.call("can_afford", cost_val))
	return cost_val <= _econ_balance()

func _econ_spend(cost_val: int) -> bool:
	if cost_val <= 0: return true
	var ok := true
	if Economy.has_method("try_spend"):
		ok = bool(Economy.call("try_spend", cost_val, "tileboard_build"))
	elif Economy.has_method("spend"):
		ok = bool(Economy.call("spend", cost_val))
	elif Economy.has_method("set_amount"):
		var bal := _econ_balance()
		ok = bal >= cost_val
		if ok: Economy.call("set_amount", bal - cost_val)
	else:
		ok = _econ_balance() >= cost_val
	return ok

func _cost_for_action(action: String) -> int:
	match action:
		"turret":  return turret_cost
		"mortar":  return mortar_cost
		_:         return 0

func _placement_succeeded(tile: Node, action: String) -> bool:
	match action:
		"turret", "mortar":
			if tile and tile.has_method("has_turret"):
				return bool(tile.call("has_turret"))
			var tower: Node = tile.find_child("Tower", true, false)
			return tower != null
		_:
			return true

# ---------------- Board generation ----------------
func generate_board() -> void:
	if tile_scene == null:
		push_error("TileBoard: 'tile_scene' not set.")
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

# ---------------- Portals ----------------
func position_portal(portal: Node3D, side: String) -> void:
	var mid_x: int = board_size_x >> 1
	var mid_z: int = board_size_z >> 1
	var pos := Vector2i.ZERO
	var rot_y := 0.0
	match side:
		"left":   pos = Vector2i(0, mid_z);                rot_y = PI / 2.0
		"right":  pos = Vector2i(board_size_x - 1, mid_z); rot_y = -PI / 2.0
		"top":    pos = Vector2i(mid_x, 0);                rot_y = 0.0
		"bottom": pos = Vector2i(mid_x, board_size_z - 1); rot_y = PI
	var tile := tiles.get(pos, null) as Node3D
	var target_pos: Vector3 = (tile.global_position if tile != null else cell_to_world(pos))
	portal.global_position = target_pos
	portal.rotation.y = rot_y

func get_spawn_position() -> Vector3: return spawner_node.global_position
func get_goal_position() -> Vector3:  return goal_node.global_position

# ---------------- Grid helpers ----------------
func cell_to_world(pos: Vector2i) -> Vector3:
	return _grid_origin + Vector3(pos.x * _step, 0.0, pos.y * _step)

func world_to_cell(world_pos: Vector3) -> Vector2i:
	var gx: int = roundi((world_pos.x - _grid_origin.x) / _step)
	var gz: int = roundi((world_pos.z - _grid_origin.z) / _step)
	return Vector2i(clamp(gx, 0, board_size_x - 1), clamp(gz, 0, board_size_z - 1))

func _goal_cell() -> Vector2i: return world_to_cell(goal_node.global_position)
func _grid_bounds() -> Rect2i: return Rect2i(Vector2i(0, 0), Vector2i(board_size_x, board_size_z))
func _in_bounds(c: Vector2i) -> bool: return c.x >= 0 and c.x < board_size_x and c.y >= 0 and c.y < board_size_z

func _side_of_cell(cell: Vector2i, b: Rect2i) -> String:
	var l := b.position.x
	var t := b.position.y
	var r := b.position.x + b.size.x - 1
	var d := b.position.y + b.size.y - 1
	if cell.x <= l: return "left"
	elif cell.x >= r: return "right"
	elif cell.y <= t: return "top"
	else: return "bottom"

func _outward_dir_for_cell(cell: Vector2i) -> Vector3:
	var b := _grid_bounds()
	var side := _side_of_cell(cell, b)
	var interior := Vector2i.ZERO
	match side:
		"left":   interior = Vector2i(1, 0)
		"right":  interior = Vector2i(-1, 0)
		"top":    interior = Vector2i(0, 1)
		"bottom": interior = Vector2i(0, -1)
	var base := cell_to_world(cell)
	var into_board := cell_to_world(cell + interior) - base
	if into_board.length() < 0.0001: return Vector3.ZERO
	return (-into_board).normalized()

func _outward_step_for_cell(cell: Vector2i) -> Vector2i:
	var b := _grid_bounds()
	match _side_of_cell(cell, b):
		"left": return Vector2i(-1, 0)
		"right": return Vector2i(1, 0)
		"top": return Vector2i(0, -1)
		"bottom": return Vector2i(0, 1)
	return Vector2i.ZERO

# ---------------- Spawner helpers ----------------
func get_spawn_pen(span: int = -1) -> Dictionary:
	if span <= 0: span = spawner_span
	var b := _grid_bounds()

	var sp_world: Vector3 = spawner_node.global_position
	var sp_cell: Vector2i = world_to_cell(sp_world)
	var side := _side_of_cell(sp_cell, b)

	var edge := sp_cell
	if side == "left": edge.x = b.position.x
	elif side == "right": edge.x = b.position.x + b.size.x - 1
	elif side == "top": edge.y = b.position.y
	else: edge.y = b.position.y + b.size.y - 1

	var normal := Vector2i.ZERO
	var lateral := Vector2i.ZERO
	if side == "left": normal = Vector2i(1, 0);  lateral = Vector2i(0, 1)
	elif side == "right": normal = Vector2i(-1, 0); lateral = Vector2i(0, 1)
	elif side == "top": normal = Vector2i(0, 1);  lateral = Vector2i(1, 0)
	else: normal = Vector2i(0, -1); lateral = Vector2i(1, 0)

	@warning_ignore("integer_division")
	var half_i: int = int(span / 2)

	var board_cells: Array[Vector2i] = []
	for i in range(-half_i, half_i + 1):
		var c := edge + lateral * i
		c.x = clampi(c.x, b.position.x, b.position.x + b.size.x - 1)
		c.y = clampi(c.y, b.position.y, b.position.y + b.size.y - 1)
		board_cells.append(c)

	var seen: Dictionary = {}
	var entry_targets: Array[Vector3] = []
	for c2 in board_cells:
		var key := str(c2.x, ",", c2.y)
		if not seen.has(key):
			seen[key] = true
			entry_targets.append(cell_to_world(c2))

	var base_w := cell_to_world(edge)
	var fwd3 := cell_to_world(edge + normal) - base_w
	var lat3 := cell_to_world(edge + lateral) - base_w
	fwd3 = (Vector3.FORWARD if fwd3.length() < 0.001 else fwd3.normalized())
	lat3 = (Vector3.RIGHT   if lat3.length() < 0.001 else lat3.normalized())

	return {
		"pen_centers": entry_targets.duplicate(),
		"entry_targets": entry_targets,
		"forward": fwd3,
		"lateral": lat3,
		"spawn_radius": tile_size * 0.35,
		"exit_radius":  tile_size * 0.35
	}

func spawn_pen_cells(span: int = -1) -> Array[Vector2i]:
	var info := get_spawn_pen(span)
	var cells: Array[Vector2i] = []
	for p in info.get("entry_targets", []):
		var pw: Vector3 = p
		cells.append(world_to_cell(pw))
	return cells

func _is_in_spawn_opening(cell: Vector2i, span: int = -1) -> bool:
	for c in spawn_pen_cells(span):
		if c == cell:
			return true
	return false

# ---------------- Off-board spawner anchoring ----------------
func _place_spawner_offboard_strip() -> void:
	if not anchor_spawner_offboard or spawner_node == null:
		return
	var info := get_spawn_pen(spawner_span)
	var exits: Array = info.get("entry_targets", [])
	var fwd: Vector3 = info.get("forward", Vector3.FORWARD)
	if exits.is_empty(): return
	var dist := _step * maxf(0.0, offboard_distance_tiles)
	var mid := int(exits.size() / 2)
	spawner_node.global_position = (exits[mid] as Vector3) - fwd * dist

# ---------------- Flow-field + reservations ----------------
func _recompute_flow() -> bool:
	var new_cost: Dictionary = {}
	var new_dir: Dictionary = {}

	var goal_cell := _goal_cell()
	var spawn_cell := world_to_cell(spawner_node.global_position)

	if _tile_is_walkable(goal_cell):
		new_cost[goal_cell] = 0
		var q: Array[Vector2i] = [goal_cell]
		var head := 0
		while head < q.size():
			var cur: Vector2i = q[head]; head += 1
			var cur_cost: int = int(new_cost[cur])
			for o in ORTHO_DIRS:
				var nb := cur + o
				if not _tile_is_walkable(nb): continue
				if new_cost.has(nb): continue
				new_cost[nb] = cur_cost + 1
				q.append(nb)

	if not new_cost.has(spawn_cell):
		return false

	for key in new_cost.keys():
		var cell: Vector2i = key
		var dir_v := Vector3.ZERO
		if cell != goal_cell:
			var best := cell
			var best_val := int(new_cost[cell])
			for o2 in ORTHO_DIRS:
				var nb2 := cell + o2
				if new_cost.has(nb2) and int(new_cost[nb2]) < best_val:
					best_val = int(new_cost[nb2]); best = nb2
			if best != cell:
				var d := cell_to_world(best) - cell_to_world(cell)
				d.y = 0.0
				var L := d.length()
				if L > EPS: dir_v = d / L
		new_dir[cell] = dir_v

	if goal_points_outward:
		var outward := _outward_dir_for_cell(goal_cell)
		if outward.length_squared() > 1e-6:
			new_dir[goal_cell] = outward

	for r_key in _reserved_cells.keys():
		var r_cell: Vector2i = r_key
		if new_dir.has(r_cell): continue
		var found := false
		var best_nb := r_cell
		var best_val := 0x3fffffff
		for o3 in ORTHO_DIRS:
			var nb3 := r_cell + o3
			if new_cost.has(nb3):
				var v := int(new_cost[nb3])
				if not found or v < best_val:
					found = true; best_val = v; best_nb = nb3
		var dir_r := Vector3.ZERO
		if found:
			var d2 := cell_to_world(best_nb) - cell_to_world(r_cell)
			d2.y = 0.0
			var L2 := d2.length()
			if L2 > EPS: dir_r = d2 / L2
		new_dir[r_cell] = dir_r

	cost = new_cost
	dir_field = new_dir
	return true

func _tile_is_walkable(cell: Vector2i) -> bool:
	if _reserved_cells.has(cell): return false
	if not tiles.has(cell): return false
	var t: Node = tiles.get(cell, null)
	if t and t.has_method("is_walkable"): return bool(t.call("is_walkable"))
	var v: Variant = t.get("walkable")
	if typeof(v) == TYPE_BOOL: return v
	if t.has_method("has_turret"): return not bool(t.call("has_turret"))
	var tower: Node = t.find_child("Tower", true, false)
	return tower == null

# ---------------- Enemy-facing API ----------------
func next_cell_from(c: Vector2i) -> Vector2i:
	var g := _goal_cell()
	if c == g:
		if goal_points_outward:
			var step := _outward_step_for_cell(g)
			if step != Vector2i.ZERO: return g + step
		return g
	if not _in_bounds(c): return c

	var have_best := false
	var best := c
	var best_val := 0
	if cost.has(c):
		var cur_val := int(cost[c])
		for o in ORTHO_DIRS:
			var nb := c + o
			if cost.has(nb):
				var nv := int(cost[nb])
				if nv < cur_val and (not have_best or nv < best_val):
					have_best = true; best = nb; best_val = nv
	if have_best: return best

	if dir_field.has(c):
		var v: Vector3 = dir_field[c]
		if v.length_squared() > 0.0:
			var step2 := Vector2i.ZERO
			if absf(v.x) >= absf(v.z): step2.x = signi(v.x)
			else: step2.y = signi(v.z)
			var n := c + step2
			n.x = clampi(n.x, 0, board_size_x - 1)
			n.y = clampi(n.y, 0, board_size_z - 1)
			return n

	var gg := _goal_cell()
	var dx := signi(gg.x - c.x)
	var dz := signi(gg.y - c.y)
	if abs(gg.x - c.x) >= abs(gg.y - c.y):
		return Vector2i(clampi(c.x + dx, 0, board_size_x - 1), c.y)
	else:
		return Vector2i(c.x, clampi(c.y + dz, 0, board_size_z - 1))

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
	return Vector3.ZERO if blended.length_squared() < 1e-6 else blended.normalized()

# ---------------- Enemy detection & reservations ----------------
func _enemies_on_cell(cell: Vector2i) -> Array:
	var out: Array = []
	for n in get_tree().get_nodes_in_group(ENEMY_GROUP):
		var n3 := n as Node3D
		if n3 == null: continue
		if world_to_cell(n3.global_position) == cell:
			out.append(n3)
	return out

func is_cell_reserved(cell: Vector2i) -> bool: return _reserved_cells.has(cell)
func _reserve_cell(cell: Vector2i, enable: bool) -> void:
	if enable: _reserved_cells[cell] = true
	elif _reserved_cells.has(cell): _reserved_cells.erase(cell)

func _poll_pending_builds() -> void:
	for i in range(_pending_builds.size() - 1, -1, -1):
		var item: Dictionary = _pending_builds[i]
		var cells: Array[Vector2i] = []
		if item.has("cells"):
			cells = item["cells"]
		else:
			cells = [Vector2i(item["cell"])]
		var clear := true
		for c in cells:
			if _enemies_on_cell(c).size() > 0:
				clear = false
				break
		if clear:
			_commit_pending_item(i)

func _commit_pending_item(index: int) -> void:
	if index < 0 or index >= _pending_builds.size(): return
	var item: Dictionary = _pending_builds[index]
	var anchor: Vector2i = item["cell"]
	var tile: Node = item["tile"]
	var action_str: String = String(item["action"])
	var cval: int = int(item["cost"])
	var cells: Array[Vector2i] = []
	if item.has("cells"): cells = item["cells"]
	else: cells = [anchor]

	for c in cells:
		var t: Node = tiles.get(c, null)
		if t and t.has_method("set_pending_blue"):
			t.call("set_pending_blue", false)
		_reserved_cells.erase(c)

	if tile and tile.has_method("apply_placement"):
		tile.call("apply_placement", action_str)

	var ok := _recompute_flow()
	if not ok:
		if tile and tile.has_method("break_tile"): tile.call("break_tile")
		_recompute_flow()
	else:
		var placed_ok := _placement_succeeded(tile, action_str)
		if placed_ok and cval > 0:
			var paid := _econ_spend(cval)
			if not paid and tile and tile.has_method("break_tile"):
				tile.call("break_tile")

	_emit_path_changed()
	_pending_builds.remove_at(index)

# ---------------- Building (UI + polling) ----------------
func _on_place_selected(action: String) -> void:
	if active_tile == null or not is_instance_valid(active_tile): return
	if action == "": return

	# Mortar (2×2)
	if action == "mortar":
		var anchor: Vector2i = active_tile.get("grid_position")
		var cells := _footprint_cells_for(anchor, Vector2i(2, 2))
		var action_cost := _power_cost_for("mortar")

		if action_cost > 0 and not _econ_can_afford(action_cost): return
		for c in cells:
			if _is_in_spawn_opening(c, spawner_span):
				if active_tile.has_method("break_tile"):
					active_tile.call("break_tile")
				_emit_path_changed()
				_clear_pending()
				return

		for c in cells: _reserved_cells[c] = true
		var ok_path := _recompute_flow()
		for c in cells: _reserved_cells.erase(c)
		_recompute_flow()
		if not ok_path:
			if active_tile.has_method("break_tile"): active_tile.call("break_tile")
			_emit_path_changed()
			_clear_pending()
			return

		var any_enemies := false
		for c in cells:
			if _enemies_on_cell(c).size() > 0:
				any_enemies = true
				break

		if any_enemies:
			for c in cells:
				var t: Node = tiles.get(c, null)
				if t and t.has_method("set_pending_blue"):
					t.call("set_pending_blue", true)
				_reserved_cells[c] = true
			_recompute_flow()
			_pending_builds.append({"cell": anchor, "cells": cells, "tile": active_tile, "action": "mortar", "cost": action_cost})
			_poll_accum = 0.0
			_emit_path_changed()
			return

		if _pending_tile and is_instance_valid(_pending_tile) and _pending_tile.has_method("set_pending_blue"):
			_pending_tile.call("set_pending_blue", false)
		if active_tile.has_method("apply_placement"):
			active_tile.call("apply_placement", "mortar")

		var ok2 := _recompute_flow()
		if not ok2:
			if active_tile.has_method("break_tile"): active_tile.call("break_tile")
			_recompute_flow()
			_emit_path_changed()
			_clear_pending()
			return

		var placed_ok := _placement_succeeded(active_tile, "mortar")
		if placed_ok and action_cost > 0:
			var paid := _econ_spend(action_cost)
			if not paid and active_tile.has_method("break_tile"):
				active_tile.call("break_tile")

		_emit_path_changed()
		_clear_pending()
		return

	# Standard blocking actions
	var pos: Vector2i = active_tile.get("grid_position")
	var blocks := (action == "turret" or action == "wall")
	var action_cost := _power_cost_for(action)
	if blocks and action_cost > 0 and not _econ_can_afford(action_cost): return
	if blocks and _is_in_spawn_opening(pos, spawner_span):
		if active_tile.has_method("break_tile"): active_tile.call("break_tile")
		_emit_path_changed(); _clear_pending(); return

	if blocks:
		_reserve_cell(pos, true)
		var ok_path2 := _recompute_flow()
		_reserve_cell(pos, false)
		_recompute_flow()
		if not ok_path2:
			if active_tile.has_method("break_tile"): active_tile.call("break_tile")
			_emit_path_changed(); _clear_pending(); return

		if _enemies_on_cell(pos).size() > 0:
			if active_tile.has_method("set_pending_blue"): active_tile.call("set_pending_blue", true)
			_reserve_cell(pos, true)
			_recompute_flow()
			_queue_pending_build(pos, active_tile, action, action_cost)
			_emit_path_changed()
			return

		if _pending_tile and is_instance_valid(_pending_tile) and _pending_tile.has_method("set_pending_blue"):
			_pending_tile.call("set_pending_blue", false)
		if active_tile.has_method("apply_placement"):
			active_tile.call("apply_placement", action)

		var ok3 := _recompute_flow()
		if not ok3:
			if active_tile.has_method("break_tile"): active_tile.call("break_tile")
			_recompute_flow(); _emit_path_changed(); _clear_pending(); return

		var placed_ok2 := _placement_succeeded(active_tile, action)
		if placed_ok2 and action_cost > 0:
			var paid2 := _econ_spend(action_cost)
			if not paid2 and active_tile.has_method("break_tile"):
				active_tile.call("break_tile")

		_emit_path_changed()
		_clear_pending()
		return

	# Non-blocking
	if _pending_tile and is_instance_valid(_pending_tile) and _pending_tile.has_method("set_pending_blue"):
		_pending_tile.call("set_pending_blue", false)
	if active_tile.has_method("apply_placement"):
		active_tile.call("apply_placement", action)
	_recompute_flow()
	_emit_path_changed()
	_clear_pending()

# ---------------- Helpers ----------------
func _power_cost_for(action: String) -> int:
	var base := _cost_for_action(action)
	var pu: Node = get_node_or_null("/root/PowerUps")
	if pu and pu.has_method("modified_cost"):
		return int(pu.call("modified_cost", action, base))
	return base

func _queue_pending_build(cell: Vector2i, tile: Node, action: String, cost_val: int) -> void:
	_pending_builds.append({"cell": cell, "tile": tile, "action": action, "cost": cost_val})
	_poll_accum = 0.0

func _footprint_cells_for(anchor: Vector2i, size: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dx in size.x:
		for dz in size.y:
			var c := Vector2i(anchor.x + dx, anchor.y + dz)
			if _in_bounds(c): out.append(c)
	return out

# ---------------- BOUNDS & PENS (unchanged behavior) ----------------
func _create_bounds() -> void:
	while true:
		var old := get_node_or_null("BoardBounds")
		if old == null: break
		old.free()

	var container := Node3D.new()
	container.name = "BoardBounds"
	add_child(container)

	var left_x: float   = _grid_origin.x - _step * 0.5
	var right_x: float  = _grid_origin.x + (board_size_x - 0.5) * _step
	var top_z: float    = _grid_origin.z - _step * 0.5
	var bottom_z: float = _grid_origin.z + (board_size_z - 0.5) * _step

	var openings: Dictionary = {"left": [], "right": [], "top": [], "bottom": []}
	if carve_openings_for_portals:
		var b := _grid_bounds()
		var sp_cell := world_to_cell(spawner_node.global_position)
		var sp_side := _side_of_cell(sp_cell, b)
		var sp_edge := sp_cell
		if sp_side == "left": sp_edge.x = b.position.x
		elif sp_side == "right": sp_edge.x = b.position.x + b.size.x - 1
		elif sp_side == "top": sp_edge.y = b.position.y
		else: sp_edge.y = b.position.y + b.size.y - 1
		openings[sp_side].append(_opening_range_for(sp_side, sp_edge, spawner_span))

		var gl_cell := world_to_cell(goal_node.global_position)
		var gl_side := _side_of_cell(gl_cell, b)
		var gl_edge := gl_cell
		if gl_side == "left": gl_edge.x = b.position.x
		elif gl_side == "right": gl_edge.x = b.position.x + b.size.x - 1
		elif gl_side == "top": gl_edge.y = b.position.y
		else: gl_edge.y = b.position.y + b.size.y - 1
		openings[gl_side].append(_opening_range_for(gl_side, gl_edge, max(1, goal_span)))

	_build_side_walls(container, "top",    top_z,    left_x, right_x, openings["top"])
	_build_side_walls(container, "bottom", bottom_z, left_x, right_x, openings["bottom"])
	_build_side_walls(container, "left",   left_x,   top_z,  bottom_z, openings["left"])
	_build_side_walls(container, "right",  right_x,  top_z,  bottom_z, openings["right"])

	if build_spawn_pen or build_goal_pen:
		_build_pens_for(container, openings)

func _build_side_walls(parent: Node3D, side: String, side_line: float, min_lateral: float, max_lateral: float, open_list: Array) -> void:
	var cuts: Array[float] = []
	for o in open_list:
		var v2: Vector2 = o
		cuts.append(v2.x); cuts.append(v2.y)
	cuts.append(min_lateral); cuts.append(max_lateral)
	cuts.sort()

	for i in range(0, cuts.size() - 1):
		var a: float = cuts[i]
		var b: float = cuts[i + 1]
		var is_open := false
		for oo in open_list:
			var v: Vector2 = oo
			if absf(a - v.x) < 0.0001 and absf(b - v.y) < 0.0001:
				is_open = true; break
		if is_open: continue

		var center: Vector3
		var size_x: float
		var size_z: float

		if side == "top" or side == "bottom":
			if b - a <= 0.0001: continue
			center = Vector3((a + b) * 0.5, 0.0, side_line)
			size_x = (b - a)
			size_z = wall_thickness
		else:
			if b - a <= 0.0001: continue
			center = Vector3(side_line, 0.0, (a + b) * 0.5)
			size_x = wall_thickness
			size_z = (b - a)

		_make_wall(parent, center, size_x, size_z, wall_height, "Wall_%s_%d" % [side, i])

func _opening_range_for(side: String, edge_cell: Vector2i, span: int) -> Vector2:
	if span <= 0: span = 1
	@warning_ignore("integer_division")
	var half_i: int = int(span / 2)
	if side == "top" or side == "bottom":
		var start_x: float = _grid_origin.x + float(edge_cell.x - half_i) * _step - 0.5 * _step
		var end_x: float   = _grid_origin.x + float(edge_cell.x + half_i) * _step + 0.5 * _step
		return Vector2(start_x, end_x)
	else:
		var start_z: float = _grid_origin.z + float(edge_cell.y - half_i) * _step - 0.5 * _step
		var end_z: float   = _grid_origin.z + float(edge_cell.y + half_i) * _step + 0.5 * _step
		return Vector2(start_z, end_z)

func _build_pens_for(container: Node3D, openings: Dictionary) -> void:
	var left_x: float   = _grid_origin.x - _step * 0.5
	var right_x: float  = _grid_origin.x + (board_size_x - 0.5) * _step
	var top_z: float    = _grid_origin.z - _step * 0.5
	var bottom_z: float = _grid_origin.z + (board_size_z - 0.5) * _step

	var depth_w: float = float(max(0, pen_depth_cells)) * _step
	var wing_cells_i: int = int(max(0, pen_wing_cells))
	var inset: float = clampf(pen_entry_inset, 0.0, depth_w)

	# TOP
	for o in openings["top"]:
		var v: Vector2 = o
		var ext_a: float = max(left_x,  v.x - float(wing_cells_i) * _step)
		var ext_b: float = min(right_x, v.y + float(wing_cells_i) * _step)
		var inner_depth: float = depth_w - inset
		if inner_depth <= 0.001:
			continue
		var back_c: Vector3 = Vector3((ext_a + ext_b) * 0.5, 0.0, top_z - depth_w - 0.5 * pen_thickness)
		_make_wall(container, back_c, max(0.0, ext_b - ext_a), pen_thickness, pen_height, "PenTop_Back")
		var wing_z_center: float = top_z - (depth_w + inset) * 0.5
		_make_wall(container, Vector3(ext_a, 0.0, wing_z_center), pen_thickness, inner_depth, pen_height, "PenTop_WingL")
		_make_wall(container, Vector3(ext_b, 0.0, wing_z_center), pen_thickness, inner_depth, pen_height, "PenTop_WingR")

	# BOTTOM
	for o2 in openings["bottom"]:
		var v2: Vector2 = o2
		var ext_a2: float = max(left_x,  v2.x - float(wing_cells_i) * _step)
		var ext_b2: float = min(right_x, v2.y + float(wing_cells_i) * _step)
		var inner_depth2: float = depth_w - inset
		if inner_depth2 <= 0.001:
			continue
		var back_c2: Vector3 = Vector3((ext_a2 + ext_b2) * 0.5, 0.0, bottom_z + depth_w + 0.5 * pen_thickness)
		_make_wall(container, back_c2, max(0.0, ext_b2 - ext_a2), pen_thickness, pen_height, "PenBottom_Back")
		var wing_z_center2: float = bottom_z + (depth_w + inset) * 0.5
		_make_wall(container, Vector3(ext_a2, 0.0, wing_z_center2), pen_thickness, inner_depth2, pen_height, "PenBottom_WingL")
		_make_wall(container, Vector3(ext_b2, 0.0, wing_z_center2), pen_thickness, inner_depth2, pen_height, "PenBottom_WingR")

	# LEFT
	for o3 in openings["left"]:
		var v3: Vector2 = o3
		var ext_a3: float = max(top_z,    v3.x - float(wing_cells_i) * _step)
		var ext_b3: float = min(bottom_z, v3.y + float(wing_cells_i) * _step)
		var inner_depth3: float = depth_w - inset
		if inner_depth3 <= 0.001:
			continue
		var back_c3: Vector3 = Vector3(left_x - depth_w - 0.5 * pen_thickness, 0.0, (ext_a3 + ext_b3) * 0.5)
		_make_wall(container, back_c3, pen_thickness, max(0.0, ext_b3 - ext_a3), pen_height, "PenLeft_Back")
		var wing_x_center3: float = left_x - (depth_w + inset) * 0.5
		_make_wall(container, Vector3(wing_x_center3, 0.0, ext_a3), inner_depth3, pen_thickness, pen_height, "PenLeft_WingT")
		_make_wall(container, Vector3(wing_x_center3, 0.0, ext_b3), inner_depth3, pen_thickness, pen_height, "PenLeft_WingB")

	# RIGHT
	for o4 in openings["right"]:
		var v4: Vector2 = o4
		var ext_a4: float = max(top_z,    v4.x - float(wing_cells_i) * _step)
		var ext_b4: float = min(bottom_z, v4.y + float(wing_cells_i) * _step)
		var inner_depth4: float = depth_w - inset
		if inner_depth4 <= 0.001:
			continue
		var back_c4: Vector3 = Vector3(right_x + depth_w + 0.5 * pen_thickness, 0.0, (ext_a4 + ext_b4) * 0.5)
		_make_wall(container, back_c4, pen_thickness, max(0.0, ext_b4 - ext_a4), pen_height, "PenRight_Back")
		var wing_x_center4: float = right_x + (depth_w + inset) * 0.5
		_make_wall(container, Vector3(wing_x_center4, 0.0, ext_a4), inner_depth4, pen_thickness, pen_height, "PenRight_WingT")
		_make_wall(container, Vector3(wing_x_center4, 0.0, ext_b4), inner_depth4, pen_thickness, pen_height, "PenRight_WingB")

func _make_wall(parent: Node3D, center_on_ground: Vector3, size_x: float, size_z: float, height: float, name: String) -> void:
	if size_x <= 0.0001 or size_z <= 0.0001 or height <= 0.0001: return
	var sb := StaticBody3D.new(); sb.name = name; parent.add_child(sb)
	sb.collision_layer = wall_collision_layer
	sb.collision_mask  = wall_collision_mask
	sb.input_ray_pickable = false
	sb.global_position = center_on_ground + Vector3(0.0, height * 0.5, 0.0)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new(); box.size = Vector3(size_x, height, size_z)
	cs.shape = box; sb.add_child(cs)
	if render_debug_wall_mesh:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new(); bm.size = Vector3(size_x, height, size_z)
		mi.mesh = bm; mi.ray_pickable = false; sb.add_child(mi)

# ---------------- Path change helper ----------------
func _emit_path_changed() -> void:
	path_version += 1
	emit_signal("global_path_changed")

# ---------------- BOARD EXPANSION HELPERS ----------------
func _add_row_at_top() -> void:
	_grid_origin.z -= _step
	board_size_z += 1
	_retag_enemy_cells(0, 1)
	var new_tiles: Dictionary = {}
	for key in tiles.keys():
		var c: Vector2i = key
		var nkey := Vector2i(c.x, c.y + 1)
		var t: Node3D = tiles[key]
		t.set("grid_position", nkey)
		new_tiles[nkey] = t
	tiles = new_tiles
	for x in range(board_size_x):
		var c2 := Vector2i(x, 0)
		if tiles.has(c2): continue
		var tile := tile_scene.instantiate() as Node3D
		add_child(tile)
		tile.global_position = cell_to_world(c2)
		tile.set("grid_position", c2)
		tile.set("tile_board", self)
		tile.set("placement_menu", placement_menu)
		tiles[c2] = tile
	rebuild_bounds(); _recompute_flow(); _emit_path_changed()

func _add_row_at_bottom() -> void:
	var new_z := board_size_z
	board_size_z += 1
	for x in range(board_size_x):
		var c := Vector2i(x, new_z)
		var tile := tile_scene.instantiate() as Node3D
		add_child(tile)
		tile.global_position = cell_to_world(c)
		tile.set("grid_position", c)
		tile.set("tile_board", self)
		tile.set("placement_menu", placement_menu)
		tiles[c] = tile
	rebuild_bounds(); _recompute_flow(); _emit_path_changed()

func _add_column_at_spawner_edge() -> void:
	var b := _grid_bounds()
	var sp_cell := world_to_cell(spawner_node.global_position)
	var side := _side_of_cell(sp_cell, b)
	match side:
		"left":
			_translate_live_enemies(Vector3(_step, 0.0, 0.0), 1, 0)
			_grid_origin.x -= _step
			board_size_x += 1
			var new_tiles: Dictionary = {}
			for key in tiles.keys():
				var c: Vector2i = key
				var nkey := Vector2i(c.x + 1, c.y)
				var t: Node3D = tiles[key]
				t.set("grid_position", nkey)
				new_tiles[nkey] = t
			tiles = new_tiles
			for z in range(board_size_z):
				var c0 := Vector2i(0, z)
				if tiles.has(c0): continue
				var tile := tile_scene.instantiate() as Node3D
				add_child(tile)
				tile.global_position = cell_to_world(c0)
				tile.set("grid_position", c0)
				tile.set("tile_board", self)
				tile.set("placement_menu", placement_menu)
				tiles[c0] = tile
		"right":
			var new_x := board_size_x
			board_size_x += 1
			for z in range(board_size_z):
				var c1 := Vector2i(new_x, z)
				var tile1 := tile_scene.instantiate() as Node3D
				add_child(tile1)
				tile1.global_position = cell_to_world(c1)
				tile1.set("grid_position", c1)
				tile1.set("tile_board", self)
				tile1.set("placement_menu", placement_menu)
				tiles[c1] = tile1
		"top": pass
		"bottom": pass
	_place_spawner_offboard_strip()
	rebuild_bounds(); _recompute_flow(); _emit_path_changed()

# ---------------- Enemy retag/move ----------------
func _retag_enemy_cells(dx: int, dz: int) -> void:
	if dx == 0 and dz == 0: return
	for n in get_tree().get_nodes_in_group(ENEMY_GROUP):
		if n == null or not is_instance_valid(n): continue
		var cvar: Variant = n.get("current_cell")
		if typeof(cvar) == TYPE_VECTOR2I:
			var c: Vector2i = cvar
			n.set("current_cell", Vector2i(c.x + dx, c.y + dz))

func _translate_live_enemies(delta_world: Vector3, dx: int, dz: int) -> void:
	if delta_world == Vector3.ZERO and dx == 0 and dz == 0: return
	for n in get_tree().get_nodes_in_group(ENEMY_GROUP):
		var n3 := n as Node3D
		if n3 == null or not is_instance_valid(n3): continue
		if delta_world != Vector3.ZERO:
			n3.global_position += delta_world
			for k in ["target_world", "target_pos", "next_wp"]:
				var v: Variant = n3.get(k)
				if typeof(v) == TYPE_VECTOR3:
					n3.set(k, (v as Vector3) + delta_world)
		if dx != 0 or dz != 0:
			var cvar: Variant = n3.get("current_cell")
			if typeof(cvar) == TYPE_VECTOR2I:
				var c: Vector2i = cvar
				n3.set("current_cell", Vector2i(c.x + dx, c.y + dz))

# ---------------- Map meta ----------------
func _apply_map_meta_expansions() -> void:
	var left_rows  := _shard_meta_level_safe("board_add_left")
	var right_rows := _shard_meta_level_safe("board_add_right")
	var push_cols  := _shard_meta_level_safe("board_push_back")
	for i in left_rows:  _add_row_at_top()
	for i in right_rows: _add_row_at_bottom()
	for i in push_cols:  _add_column_at_spawner_edge()

func _shard_meta_level_safe(id: String) -> int:
	var s := get_node_or_null("/root/Shards")
	if s and s.has_method("get_meta_level"):
		return int(s.call("get_meta_level", id))
	var pu := get_node_or_null("/root/PowerUps")
	if pu and pu.has_method("meta_level"):
		return int(pu.call("meta_level", id))
	return 0

func _apply_initial_board_from_powerups() -> void:
	var pu := get_node_or_null("/root/PowerUps")
	if pu == null: return
	var add_left  := int(pu.call("applied_for", "board_add_left"))
	var add_right := int(pu.call("applied_for", "board_add_right"))
	var push_back := int(pu.call("applied_for", "board_push_back"))
	for i in add_left:  _add_row_at_top()
	for i in add_right: _add_row_at_bottom()
	for i in push_back: _add_column_at_spawner_edge()

# ---------------- Public helpers ----------------
func free_tile(cell: Vector2i) -> void:
	var t: Node = tiles.get(cell, null)
	if t and t.has_method("repair_tile"):
		t.call("repair_tile")
	_recompute_flow()
	_emit_path_changed()

func request_build_on_tile(tile: Node, action: String) -> void:
	if tile == null or not is_instance_valid(tile): return
	set_active_tile(tile)
	_on_place_selected(action)

func request_build_on_footprint(anchor_tile: Node, action: String, size: Vector2i) -> void:
	if anchor_tile == null or not is_instance_valid(anchor_tile): return
	set_active_tile(anchor_tile)
	# _on_place_selected knows how to handle "mortar" (2×2)
	_on_place_selected(action)
