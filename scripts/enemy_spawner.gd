extends Node3D

@export var enemy_scene: PackedScene
@export var tile_board_path: NodePath = ^".."
@export var spawn_every: float = 1.5            

# Waves 
@export var auto_start: bool = true
@export var wave_size_base: int = 8
@export var wave_size_inc: int = 2
@export var intermission: float = 4.0
@export var spawn_every_min: float = 0.25
@export var spawn_every_decay: float = 0.02

# spawn behavior 
const ENTRY_OFFSET: float            = 1.2    
const ENTRY_DEPTH_FACTOR: float      = 0.12    
const LATERAL_JITTER_FACTOR: float   = 0.22     
const LATERAL_JITTER_MIN: float      = 0.10
const LATERAL_JITTER_MAX: float      = 0.45
const INITIAL_DESYNC: float          = 0.35  

# Crowd gate, skip if too many in the entry cell
const ENTRY_CROWD_LIMIT: int   = 2
const BLOCKED_RETRY_MIN: float = 0.06
const BLOCKED_RETRY_MAX: float = 0.18

# blockage-shoot animation rig
@export var projectile_scene: PackedScene
@export var turret_path: NodePath = ^"mortar_tower_model/Turret"
@export var barrel_path: NodePath = ^"mortar_tower_model/Turret/Barrel"
@export var muzzle_path: NodePath = ^"mortar_tower_model/Turret/Barrel/MuzzlePoint"

signal wave_started(wave: int)
signal all_enemies_spawned(wave: int)

var _board: Node = null
var _spawn_timer: Timer
var _between: Timer
var _turret: Node3D = null
var _barrel: Node3D = null
var _muzzle: Node3D = null
var _recoil_tw: Tween = null

var _wave: int = 0
var _to_spawn_in_wave: int = 0
var _cur_interval: float = 1.0
var _sent_all_spawned: bool = false

# --- Pause support ---
var _paused: bool = false
var _spawn_remaining: float = 0.0
var _between_remaining: float = 0.0


func _ready() -> void:
	randomize()
	_board = get_node_or_null(tile_board_path)
	if _board == null:
		push_error("EnemySpawner: tile_board_path is invalid or missing.")
		return

	_spawn_timer = Timer.new()
	_spawn_timer.one_shot = true
	add_child(_spawn_timer)
	_spawn_timer.timeout.connect(_on_spawn_tick)

	_between = Timer.new()
	_between.one_shot = true
	add_child(_between)
	_between.timeout.connect(_start_next_wave)
	_cache_rig()
	if auto_start:
		_start_next_wave()
	else:
		_schedule_between()

# waves
func _start_next_wave() -> void:
	_wave += 1
	_to_spawn_in_wave = _calc_wave_size(_wave)
	_sent_all_spawned = false
	emit_signal("wave_started", _wave)
	_cur_interval = _calc_interval(_wave)
	_schedule_next_spawn(true)


func _calc_wave_size(wave: int) -> int:
	var steps: int = wave - 1
	if steps < 0:
		steps = 0
	var size: int = wave_size_base + steps * wave_size_inc
	if size < 1:
		size = 1
	return size


func _calc_interval(wave: int) -> float:
	var steps: int = wave - 1
	if steps < 0:
		steps = 0
	var interval: float = spawn_every - spawn_every_decay * float(steps)
	if interval < spawn_every_min:
		interval = spawn_every_min
	return interval


func _schedule_between() -> void:
	var delay: float = max(0.0, intermission) # or: float(max(0.0, intermission))
	if _paused:
		_between_remaining = delay
	else:
		_between.start(delay)


func _schedule_next_spawn(first: bool = false) -> void:
	if _to_spawn_in_wave <= 0:
		return
	var mean: float = max(spawn_every_min, _cur_interval)
	var delay: float = max(spawn_every_min, _sample_exp(mean))

	if _paused:
		_spawn_remaining = delay
	else:
		_spawn_timer.start(delay)

func _sample_exp(mean: float) -> float:
	var u: float = clamp(randf(), 1e-6, 1.0 - 1e-6)
	return -log(1.0 - u) * mean

func _on_spawn_tick() -> void:
	_spawn()
	_schedule_next_spawn()

# spawning 
func _spawn() -> void:
	if _to_spawn_in_wave <= 0 or enemy_scene == null or _board == null:
		_maybe_finish_wave()
		return

	# Basis at portal
	var basis := _portal_spawn_basis()
	var origin: Vector3 = basis[0]
	var forward: Vector3 = basis[1]
	var right: Vector3 = basis[2]

	# Tile size
	var ts: float = 2.0
	var sz = _board.get("tile_size")
	if typeof(sz) == TYPE_FLOAT or typeof(sz) == TYPE_INT:
		ts = float(sz)

	# Entry depth + crowd gate
	var entry_depth: float = clamp(ts * ENTRY_DEPTH_FACTOR, 0.08, 0.35)
	var entry_world: Vector3 = origin + forward * entry_depth
	var entry_cell: Vector2i = _board.world_to_cell(entry_world)

	var in_cell := 0
	for n in get_tree().get_nodes_in_group("enemy"):
		var en := n as Node3D
		if en != null and _board.world_to_cell(en.global_position) == entry_cell:
			in_cell += 1
			if in_cell >= ENTRY_CROWD_LIMIT:
				_spawn_timer.start(randf_range(BLOCKED_RETRY_MIN, BLOCKED_RETRY_MAX))
				return

	# Lateral jitter
	var lateral_amt: float = clamp(ts * LATERAL_JITTER_FACTOR, LATERAL_JITTER_MIN, LATERAL_JITTER_MAX)
	var lateral: Vector3 = right * randf_range(-lateral_amt, lateral_amt)

	# Instantiate
	var enemy := enemy_scene.instantiate() as CharacterBody3D

	# Give data needed by Enemy._ready() BEFORE it enters the tree
	enemy.tile_board_path = _board.get_path()
	var entry_point: Vector3 = entry_world + lateral
	var arrive_radius: float = max(entry_depth * 1.4, 0.32)
	enemy.set_entry_target(entry_point, arrive_radius)

	# Now add to tree, THEN set transforms (preserve scale!)
	add_child(enemy)

	var s: Vector3 = enemy.scale  # preserve any scene-scale
	var start_pos: Vector3 = origin - forward * ENTRY_OFFSET + lateral
	enemy.global_position = start_pos
	enemy.look_at(start_pos + forward, Vector3.UP)
	enemy.scale = s
	enemy.lock_y_to(start_pos.y)

	_to_spawn_in_wave -= 1
	_maybe_finish_wave()


# Basis aligned to portal rotation, flattened on XZ
func _portal_spawn_basis() -> Array[Vector3]:
	var spawner: Node3D = _board.spawner_node
	var t: Transform3D

	var spawn_point: Node3D = spawner.get_node_or_null("SpawnPoint") as Node3D
	if spawn_point != null:
		t = spawn_point.global_transform
	else:
		t = spawner.global_transform

	var origin: Vector3 = t.origin
	var goal_pos: Vector3 = (_board.get_goal_position() as Vector3)

	# Forward from spawner, flattened
	var forward: Vector3 = -t.basis.z
	forward.y = 0.0
	var f_len: float = forward.length()
	if f_len > 0.0001:
		forward /= f_len
	else:
		# fallback: derive from goal
		forward = Vector3(goal_pos.x - origin.x, 0.0, goal_pos.z - origin.z).normalized()

	# Aim toward goal
	var goal_dir: Vector3 = Vector3(goal_pos.x - origin.x, 0.0, goal_pos.z - origin.z)
	var g_len: float = goal_dir.length()
	if g_len > 0.0001 and forward.dot(goal_dir / g_len) < 0.0:
		forward = -forward

	# Right-hand basis
	var right: Vector3 = forward.cross(Vector3.UP)
	var r_len: float = right.length()
	if r_len > 0.0001:
		right /= r_len
	else:
		right = Vector3.RIGHT

	var out: Array[Vector3] = [origin, forward, right]
	return out

func _maybe_finish_wave() -> void:
	# Only finish when we've spawned everything.
	if _to_spawn_in_wave > 0:
		return

	# Stop the spawn timer if it's running, clear any pending resume.
	if _spawn_timer != null and not _spawn_timer.is_stopped():
		_spawn_timer.stop()
	_spawn_remaining = 0.0

	# Emit once, then schedule the intermission.
	if _sent_all_spawned:
		return
	_sent_all_spawned = true
	emit_signal("all_enemies_spawned", _wave)
	_schedule_between()


# blockage shooting animation-
func _cache_rig() -> void:
	_turret = null
	_barrel = null
	_muzzle = null
	if turret_path != NodePath("") and has_node(turret_path):
		_turret = get_node(turret_path)
	if barrel_path != NodePath("") and has_node(barrel_path):
		_barrel = get_node(barrel_path)
	if muzzle_path != NodePath("") and has_node(muzzle_path):
		_muzzle = get_node(muzzle_path)
	if _turret == null:
		_turret = find_child("Turret", true, false)
	if _barrel == null:
		_barrel = find_child("Barrel", true, false)
	if _muzzle == null:
		_muzzle = find_child("MuzzlePoint", true, false)

func shoot_tile(target_world: Vector3) -> float:
	var turret := get_node_or_null(turret_path) as Node3D
	var barrel := get_node_or_null(barrel_path) as Node3D
	var muzzle := get_node_or_null(muzzle_path) as Node3D

	if projectile_scene == null || muzzle == null:
		return 1.0

	if turret != null:
		var tpos := turret.global_transform.origin
		var dir := target_world - tpos
		dir.y = 0.0
		if dir.length() > 0.001:
			turret.look_at(tpos + dir, Vector3.UP)

	var p := projectile_scene.instantiate() as Node3D
	add_child(p)
	p.global_position = muzzle.global_position

	var flight_t := 1.0
	var ft = p.get("flight_time")
	if typeof(ft) == TYPE_FLOAT or TYPE_INT == typeof(ft):
		flight_t = float(ft)
	if p.has_method("launch"):
		p.launch(target_world)

	return max(flight_t, 0.05)


func pause_spawning(pause: bool) -> void:
	if _paused == pause:
		return
	_paused = pause

	if pause:
		# stash remaining times, then stop.
		if _spawn_timer != null:
			_spawn_remaining = _spawn_timer.time_left
			_spawn_timer.stop()
		else:
			_spawn_remaining = 0.0

		if _between != null:
			_between_remaining = _between.time_left
			_between.stop()
		else:
			_between_remaining = 0.0
		return


	# if intermission was in progress, resume that first and clear spawn stash.
	if _between_remaining > 0.0:
		if _between != null:
			_between.start(_between_remaining)
		_between_remaining = 0.0
		_spawn_remaining = 0.0
		return

	# resume spawn countdown if mid-wave.
	if _spawn_remaining > 0.0 and _to_spawn_in_wave > 0:
		if _spawn_timer != null:
			_spawn_timer.start(_spawn_remaining)
		_spawn_remaining = 0.0
		return

	# Nothing stashed, mid-wave and the timer is stopped, schedule next.
	if _to_spawn_in_wave > 0 and _spawn_timer != null and _spawn_timer.is_stopped():
		_schedule_next_spawn()
