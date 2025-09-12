extends Node3D
class_name ShardMiner

# ---------------- Inspector ----------------
@export var building_id: String = "shard_miner"
@export var minerals_cost: int = 35
@export var footprint: Vector2i = Vector2i(2, 2)  # 2x2

# Shard generation
@export var shards_per_minute: float = 6.0   # 6/min = 0.1/sec
@export var start_delay_sec: float = 2.0
@export var enabled_on_ready: bool = true

# Optional visuals
@export var glow_mesh_path: NodePath
@export var flash_seconds: float = 0.15
@export var flash_emission_boost: float = 1.7
@export var popup_scene: PackedScene

# Debug
@export var debug_prints: bool = false

# ---------------- Internals ----------------
var _active: bool = false
var _accum: float = 0.0
var _start_delay_left: float = 0.0
var _glow_mesh: MeshInstance3D = null
var _flash_left: float = 0.0

var _board: Node = null
var _anchor_cell: Vector2i = Vector2i.ZERO

func set_tile_context(board: Node, anchor_cell: Vector2i) -> void:
	_board = board
	_anchor_cell = anchor_cell
	# ping board just in case placement happened without tile helper
	if _board:
		if _board.has_method("on_tiles_blocked_changed"):
			_board.call("on_tiles_blocked_changed", _anchor_cell, Vector2i(2, 2), true)
		else:
			for m in ["recompute_flow", "recompute_paths", "rebuild_flow_field", "recompute_board_dirs", "recompute"]:
				if _board.has_method(m):
					_board.call(m)
					break



func _ready() -> void:
	if glow_mesh_path != NodePath("") and has_node(glow_mesh_path):
		_glow_mesh = get_node(glow_mesh_path) as MeshInstance3D
	add_to_group("shard_generators", true)
	_start_delay_left = max(0.0, start_delay_sec)
	set_active(enabled_on_ready)

func set_active(on: bool) -> void:
	_active = on
	set_process(on or _flash_left > 0.0)

func is_active() -> bool:
	return _active

func _process(delta: float) -> void:
	_update_flash(delta)
	if get_tree().paused or not _active:
		return
	if _start_delay_left > 0.0:
		_start_delay_left -= delta
		return

	var rate_per_sec: float = float(max(0.0, shards_per_minute)) / 60.0
	_accum += rate_per_sec * delta
	if _accum >= 1.0:
		var whole: int = int(floor(_accum))
		_accum -= float(whole)
		_pay_out(whole)

func _pay_out(amount: int) -> void:
	if amount <= 0:
		return
	if typeof(Shards) == TYPE_NIL:
		if debug_prints: print("[ShardMiner] Shards autoload missing.")
		return
	Shards.add(amount, "generator")
	if debug_prints: print("[ShardMiner] +", amount, " shards")
	_flash()
	_spawn_popup(amount)

func _spawn_popup(amount: int) -> void:
	if popup_scene == null:
		return
	var n: Node = popup_scene.instantiate()
	if n == null:
		return
	if n.has_method("set_text"):
		n.call("set_text", "+" + str(amount))
	elif "text" in n:
		n.set("text", "+" + str(amount))
	if n is Node3D:
		(n as Node3D).global_position = global_position + Vector3(0, 1.4, 0)
	get_tree().current_scene.add_child(n)

func _flash() -> void:
	_flash_left = flash_seconds
	set_process(true)

func _update_flash(delta: float) -> void:
	if _flash_left <= 0.0:
		return
	_flash_left -= delta
	if _glow_mesh and _glow_mesh.mesh:
		var mat: Material = _glow_mesh.get_surface_override_material(0)
		if mat == null and _glow_mesh.mesh.get_surface_count() > 0:
			mat = _glow_mesh.mesh.surface_get_material(0)
		if mat != null and (mat is StandardMaterial3D):
			var m: StandardMaterial3D = mat as StandardMaterial3D
			var t: float = clamp(_flash_left / max(0.001, flash_seconds), 0.0, 1.0)
			m.emission_enabled = true
			m.emission_energy = 1.0 + t * flash_emission_boost
	if _flash_left <= 0.0 and not _active:
		set_process(false)

# ---------------- BuildManager helpers ----------------
func get_build_id() -> String:
	return building_id

func get_cost_minerals() -> int:
	return minerals_cost

func get_footprint_size() -> Vector2i:
	return footprint

func get_occupied_cells(anchor_cell: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for dz in range(footprint.y):
		for dx in range(footprint.x):
			cells.append(anchor_cell + Vector2i(dx, dz))
	return cells

func on_placed() -> void:
	if debug_prints: print("[ShardMiner] placed; footprint=", footprint)

func set_rate_per_minute(new_rate: float) -> void:
	shards_per_minute = max(0.0, new_rate)

func add_rate_bonus(delta_rate: float) -> void:
	shards_per_minute = max(0.0, shards_per_minute + delta_rate)
