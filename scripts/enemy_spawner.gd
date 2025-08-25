extends Node3D
class_name EnemySpawner

# -------------------- Setup --------------------
@export var tile_board_path: NodePath
@export var enemy_scene: PackedScene

# pacing
@export var auto_start: bool = true
@export var spawn_interval: float = 1.0      # seconds between ticks
@export var burst_count: int = 1             # enemies per tick
@export var max_alive: int = 250

# lanes
@export var use_round_robin: bool = true     # else random selection per spawn
@export var span_override: int = 0           # if >0, overrides TileBoard.spawner_span

# movement priming
@export var nudge_on_spawn: float = 0.35     # tiny translate into board (0..1 of a tile)

# spawn spreading (prevents stacking)
@export var spawn_spread_tiles: float = 0.35            # lateral jitter (in tiles)
@export var spawn_forward_jitter_tiles: float = 0.15    # jitter along pen forward axis (in tiles)

# Short guided “first step” into the grid (recommended on)
@export var use_entry_step: bool = true
@export var entry_step_radius_tiles: float = 0.9

# -------------------- State --------------------
var _board: Node = null
var _timer: Timer
var _paused: bool = false
var _alive: int = 0
var _lane_idx: int = -1

# -------------------- Lifecycle --------------------
func _ready() -> void:
	_timer = Timer.new()
	_timer.one_shot = false
	_timer.wait_time = maxf(0.05, spawn_interval)
	add_child(_timer)
	_timer.timeout.connect(_on_spawn_tick)

	if tile_board_path != NodePath(""):
		_board = get_node_or_null(tile_board_path)
	if _board == null:
		_board = get_tree().get_first_node_in_group("TileBoard")  # optional fallback

	_build_pool_generic() # stub for future pooling

	if auto_start:
		start_spawning()

# -------------------- Public API --------------------
func start_spawning() -> void:
	_paused = false
	_timer.wait_time = maxf(0.05, spawn_interval)
	if _timer.is_stopped():
		_timer.start()

func stop_spawning() -> void:
	if not _timer.is_stopped():
		_timer.stop()

func pause_spawning(on: bool) -> void:
	_paused = on
	if on:
		stop_spawning()
	else:
		start_spawning()

func set_rate(seconds_per_spawn: float) -> void:
	spawn_interval = maxf(0.05, seconds_per_spawn)
	if not _paused:
		start_spawning()

# Called by TileBoard during soft-block sequences. Return duration to wait.
func shoot_tile(_world_pos: Vector3) -> float:
	var t := create_tween()
	t.tween_property(self, "rotation:y", rotation.y + 0.25, 0.15)
	t.tween_property(self, "rotation:y", rotation.y, 0.15)
	return 0.35

# -------------------- Spawning --------------------
func _on_spawn_tick() -> void:
	if _paused or _board == null or enemy_scene == null:
		return
	if _alive >= max_alive:
		return

	var to_spawn: int = mini(burst_count, max_alive - _alive)
	for _i in range(to_spawn):
		_spawn_one()

func _spawn_one() -> void:
	if _board == null or not _board.has_method("get_spawn_pen"):
		push_warning("EnemySpawner: TileBoard missing get_spawn_pen().")
		return

	# lane geometry from the board
	var span: int = (span_override if span_override > 0 else int(_board.get("spawner_span")))
	var info: Dictionary = _board.get_spawn_pen(span)

	var pens: Array = info.get("pen_centers", [])
	var exits: Array = info.get("entry_targets", [])
	var fwd: Vector3 = info.get("forward", Vector3.FORWARD)
	var lat: Vector3 = info.get("lateral", Vector3.RIGHT)

	if pens.is_empty():
		return

	# board sizes / tile width
	var tile_w: float = 1.0
	if _board.has_method("tile_world_size"):
		tile_w = float(_board.call("tile_world_size"))
	else:
		var tv: Variant = _board.get("tile_size")
		if typeof(tv) == TYPE_FLOAT or typeof(tv) == TYPE_INT:
			tile_w = float(tv)

	var bx: int = int(_board.get("board_size_x"))
	var bz: int = int(_board.get("board_size_z"))

	var spawn_radius: float = float(info.get("spawn_radius", 0.6 * tile_w))
	var exit_radius_default: float = float(info.get("exit_radius", 0.35 * tile_w))

	# pick a lane
	var lane: int
	if use_round_robin:
		_lane_idx = (_lane_idx + 1) % pens.size()
		lane = _lane_idx
	else:
		lane = randi() % pens.size()

	# --- Instance enemy & configure BEFORE add_child so _ready sees paths ---
	var inst := enemy_scene.instantiate()
	if inst == null:
		return

	# Always use dynamic set() so this works even if the scene isn’t typed as Enemy
	if _board != null:
		inst.set("tile_board_path", _board.get_path())
		var g: Variant = _board.get("goal_node")
		if typeof(g) == TYPE_OBJECT and g != null and g is Node3D:
			inst.set("goal_node_path", g.get_path())
	inst.set("lane_spread_tiles", spawn_spread_tiles)

	add_child(inst)

	# track alive
	if inst.has_signal("died"):
		inst.died.connect(_on_enemy_died)

	# --- choose a spawn point inside the pen (with jitter) ---
	var lat_mag: float = minf(spawn_radius, spawn_spread_tiles * tile_w)
	var fwd_mag: float = spawn_forward_jitter_tiles * tile_w

	var p: Vector3 = pens[lane]
	if lat_mag > 0.0:
		p += lat * randf_range(-lat_mag, lat_mag)
	if fwd_mag > 0.0:
		p += fwd * randf_range(-fwd_mag, fwd_mag)

	# place + lock Y
	inst.set("global_position", p)
	if inst.has_method("lock_y_to"):
		inst.lock_y_to(p.y)

	# force enemy to rebuild its segment from this position
	if inst.has_method("reset_for_spawn"):
		inst.reset_for_spawn()

	# --- first step into the grid (recommended) ---
	var needs_entry := use_entry_step
	if _board.has_method("world_to_cell"):
		var cc: Vector2i = _board.call("world_to_cell", p)
		if bx > 0 and bz > 0 and (cc.x < 0 or cc.x >= bx or cc.y < 0 or cc.y >= bz):
			needs_entry = true

	if needs_entry and inst.has_method("set_entry_target"):
		var entry: Vector3
		var radius: float = maxf(exit_radius_default, entry_step_radius_tiles * tile_w)

		if lane < exits.size():
			entry = exits[lane]  # preferred: board-supplied safe target
		else:
			# fallback: clamp to nearest border cell and offset inward
			var cc2: Vector2i = _board.call("world_to_cell", p)
			cc2.x = clampi(cc2.x, 0, max(0, bx - 1))
			cc2.y = clampi(cc2.y, 0, max(0, bz - 1))
			if _board.has_method("cell_center"):
				entry = _board.call("cell_center", cc2)
			elif _board.has_method("cell_to_world"):
				entry = _board.call("cell_to_world", cc2)
			entry += fwd * (tile_w * 0.33)

		inst.set_entry_target(entry, radius)

	# tiny translate-nudge so they don’t idle at the doorway
	if nudge_on_spawn > 0.0:
		var nudge := tile_w * 0.12 * clampf(nudge_on_spawn, 0.0, 1.0)
		inst.set("global_position", inst.global_position + fwd * nudge)

	# face into the board
	if inst.has_method("look_at"):
		inst.look_at(inst.global_position + fwd, Vector3.UP)

	_alive += 1

# -------------------- Callbacks --------------------
func _on_enemy_died() -> void:
	_alive = maxi(0, _alive - 1)

# -------------------- Compatibility / stubs --------------------
func _build_pool_generic() -> void:
	# Implement pooling here if you want it later.
	pass
