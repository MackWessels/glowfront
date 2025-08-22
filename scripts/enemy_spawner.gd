extends Node3D

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
@export var nudge_on_spawn: float = 0.75     # 0..1 of enemy speed (0 disables)

# spawn spreading inside the pen (prevents stacking)
@export var spawn_spread_tiles: float = 0.35            # lateral jitter within a lane (in tiles)
@export var spawn_forward_jitter_tiles: float = 0.15    # jitter along pen forward axis (in tiles)

# Optional: short "first step" to the lane center on the board.
# Disable this if you see queuing at the opening (recommended = false).
@export var use_entry_step: bool = false
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
	_timer.wait_time = max(0.05, spawn_interval)
	add_child(_timer)
	_timer.timeout.connect(_on_spawn_tick)

	if tile_board_path != NodePath(""):
		_board = get_node_or_null(tile_board_path)
	if _board == null:
		_board = get_tree().get_first_node_in_group("TileBoard")  # optional fallback

	_build_pool_generic() # stub, for compatibility

	if auto_start:
		start_spawning()

# -------------------- Public API --------------------
func start_spawning() -> void:
	_paused = false
	_timer.wait_time = max(0.05, spawn_interval)
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
	spawn_interval = max(0.05, seconds_per_spawn)
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

	var to_spawn: int = min(burst_count, max_alive - _alive)
	for _i in range(to_spawn):
		_spawn_one()

func _spawn_one() -> void:
	if not _board or not _board.has_method("get_spawn_pen"):
		push_warning("EnemySpawner: TileBoard missing get_spawn_pen().")
		return

	var span: int = span_override if span_override > 0 else int(_board.get("spawner_span"))
	var info: Dictionary = _board.get_spawn_pen(span)

	var pens: Array = info.get("pen_centers", [])
	var exits: Array = info.get("entry_targets", [])
	var fwd: Vector3 = info.get("forward", Vector3.FORWARD)
	var lat: Vector3 = info.get("lateral", Vector3.RIGHT)
	var spawn_radius: float = float(info.get("spawn_radius", 0.6 * float(_board.get("tile_size"))))
	var exit_radius_default: float = float(info.get("exit_radius", 0.35 * float(_board.get("tile_size"))))

	if pens.is_empty():
		return

	var lane: int
	if use_round_robin:
		_lane_idx = (_lane_idx + 1) % pens.size()
		lane = _lane_idx
	else:
		lane = randi() % pens.size()

	# --- Instantiate and configure BEFORE add_child so Enemy._ready() sees the board ---
	var e := enemy_scene.instantiate() as CharacterBody3D

	# Set absolute NodePath so _ready() can resolve it immediately
	if _board != null:
		e.set("tile_board_path", _board.get_path())

	# Now add to the tree (Enemy._ready() will run here and bind _board)
	add_child(e)

	# decrement alive when enemy dies
	if e.has_signal("died"):
		e.died.connect(_on_enemy_died)

	# Compute jitter inside the pen (keep within the provided safe radius)
	var lat_mag: float = min(spawn_radius, spawn_spread_tiles * float(_board.get("tile_size")))
	var fwd_mag: float = spawn_forward_jitter_tiles * float(_board.get("tile_size"))

	var p: Vector3 = pens[lane]
	if lat_mag > 0.0:
		p += lat * randf_range(-lat_mag, lat_mag)
	if fwd_mag > 0.0:
		p += fwd * randf_range(-fwd_mag, fwd_mag)

	# place + lock Y
	e.global_position = p
	if e.has_method("lock_y_to"):
		e.lock_y_to(p.y)

	# reset per-enemy transient state if provided
	if e.has_method("reset_for_spawn"):
		e.reset_for_spawn()

	# face into the board
	e.look_at(e.global_position + fwd, Vector3.UP)

	# optional nudge so they start moving instantly
	if nudge_on_spawn > 0.0:
		var spd: float = 2.0
		var v: Variant = e.get("speed")
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			spd = float(v)
		e.velocity = fwd * (spd * nudge_on_spawn)

	# OPTIONAL short "first step" onto the first in-bounds lane center (disabled by default)
	if use_entry_step and e.has_method("set_entry_target") and lane < exits.size():
		var exit_radius: float = max(exit_radius_default, entry_step_radius_tiles * float(_board.get("tile_size")))
		e.set_entry_target(exits[lane], exit_radius)

	_alive += 1

# -------------------- Callbacks --------------------
func _on_enemy_died() -> void:
	_alive = max(0, _alive - 1)

# -------------------- Compatibility / stubs --------------------
func _build_pool_generic() -> void:
	# Implement pooling here if you want it later.
	pass
