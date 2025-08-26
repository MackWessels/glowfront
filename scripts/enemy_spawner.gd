extends Node3D

# --- Setup ---
@export var tile_board_path: NodePath
@export var enemy_scene: PackedScene

# pacing
@export var auto_start: bool = true
@export var spawn_interval: float = 1.0
@export var burst_count: int = 1
@export var max_alive: int = 250

# lanes
@export var use_round_robin: bool = true
@export var span_override: int = 0

# spawn location: outside the grid, into the pen
@export var spawn_outward_tiles: float = 1.0   # 1.0 = one tile outside

# movement priming
@export var nudge_on_spawn: float = 0.35

# anti-stacking
@export var spawn_spread_tiles: float = 0.35
@export var spawn_forward_jitter_tiles: float = 0.15

# guided first step
@export var use_entry_step: bool = true
@export var entry_step_radius_tiles: float = 0.9

# --- State ---
var _board: Node = null
var _timer: Timer
var _paused := false
var _alive := 0
var _lane_idx := -1

func _ready() -> void:
	_timer = Timer.new()
	_timer.one_shot = false
	_timer.wait_time = maxf(0.05, spawn_interval)
	add_child(_timer)
	_timer.timeout.connect(_on_spawn_tick)

	if tile_board_path != NodePath(""):
		_board = get_node_or_null(tile_board_path)
	if _board == null:
		_board = get_tree().get_first_node_in_group("TileBoard") # optional fallback

	_build_pool_generic()
	if auto_start:
		start_spawning()

# --- Public API ---
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

# Called by TileBoard when “shot”; returns wait time.
func shoot_tile(_world_pos: Vector3) -> float:
	var t := create_tween()
	t.tween_property(self, "rotation:y", rotation.y + 0.25, 0.15)
	t.tween_property(self, "rotation:y", rotation.y, 0.15)
	return 0.35

# --- Spawning ---
func _on_spawn_tick() -> void:
	if _paused or _board == null or enemy_scene == null:
		return
	if _alive >= max_alive:
		return
	var to_spawn := mini(burst_count, max_alive - _alive)
	for _i in to_spawn:
		_spawn_one()

func _spawn_one() -> void:
	if _board == null or not _board.has_method("get_spawn_pen"):
		return

	var span := (span_override if span_override > 0 else _get_board_int("spawner_span", 3))
	var info: Dictionary = _board.get_spawn_pen(span)

	var exits: Array = info.get("entry_targets", [])
	var fwd: Vector3 = info.get("forward", Vector3.FORWARD)
	var lat: Vector3 = info.get("lateral", Vector3.RIGHT)
	if exits.is_empty():
		return

	var tile_w := _tile_w()
	var spawn_radius := float(info.get("spawn_radius", 0.6 * tile_w))
	var exit_radius := float(info.get("exit_radius", 0.35 * tile_w))

	var lane: int
	if use_round_robin:
		_lane_idx = (_lane_idx + 1) % exits.size()
		lane = _lane_idx
	else:
		lane = randi() % exits.size()

	var inst := enemy_scene.instantiate()
	if inst == null:
		return

	# wire references before _ready
	if _board != null:
		inst.set("tile_board_path", _board.get_path())
		var g: Variant = _board.get("goal_node")
		if typeof(g) == TYPE_OBJECT and g != null and g is Node3D:
			inst.set("goal_node_path", g.get_path())
	inst.set("lane_spread_tiles", spawn_spread_tiles)

	add_child(inst)
	if inst.has_signal("died"):
		inst.died.connect(_on_enemy_died)

	# spawn inside the pen (outside the grid)
	var outward := maxf(0.0, spawn_outward_tiles)
	var base: Vector3 = exits[lane]      # edge cell center
	var p: Vector3 = base - fwd * (tile_w * outward)

	# jitter
	var lat_mag := minf(spawn_radius, spawn_spread_tiles * tile_w)
	var fwd_mag := spawn_forward_jitter_tiles * tile_w
	if lat_mag > 0.0:
		p += lat * randf_range(-lat_mag, lat_mag)
	if fwd_mag > 0.0:
		p += fwd * randf_range(-fwd_mag, fwd_mag)

	inst.set("global_position", p)
	if inst.has_method("lock_y_to"):
		inst.lock_y_to(p.y)
	if inst.has_method("reset_for_spawn"):
		inst.reset_for_spawn()

	# entry glide to the doorway
	if use_entry_step and inst.has_method("set_entry_target"):
		inst.set_entry_target(base, maxf(exit_radius, entry_step_radius_tiles * tile_w))

	# slight nudge inward
	if nudge_on_spawn > 0.0:
		var nudge := tile_w * 0.12 * clampf(nudge_on_spawn, 0.0, 1.0)
		inst.set("global_position", inst.global_position + fwd * nudge)

	if inst.has_method("look_at"):
		inst.look_at(inst.global_position + fwd, Vector3.UP)

	_alive += 1

# --- Callbacks ---
func _on_enemy_died() -> void:
	_alive = maxi(0, _alive - 1)

# --- Stubs / helpers ---
func _build_pool_generic() -> void:
	pass

func _tile_w() -> float:
	if _board and _board.has_method("tile_world_size"):
		return float(_board.call("tile_world_size"))
	var tv: Variant = _board.get("tile_size") if _board else 1.0
	return float(tv) if (typeof(tv) == TYPE_FLOAT or typeof(tv) == TYPE_INT) else 1.0

func _get_board_int(prop: String, def: int) -> int:
	if _board == null:
		return def
	var v: Variant = _board.get(prop)
	return int(v) if typeof(v) in [TYPE_INT, TYPE_FLOAT] else def
