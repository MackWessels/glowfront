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

func _ready() -> void:
	randomize()
	_board = get_node(tile_board_path)

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
	_to_spawn_in_wave = wave_size_base + max(0, _wave - 1) * wave_size_inc
	_sent_all_spawned = false
	emit_signal("wave_started", _wave)

	_cur_interval = max(spawn_every_min, spawn_every - spawn_every_decay * float(_wave - 1))
	_schedule_next_spawn(true)

func _schedule_between() -> void:
	_between.start(max(0.0, intermission))

func _schedule_next_spawn(first: bool = false) -> void:
	if _to_spawn_in_wave <= 0:
		return
	var mean: float = max(spawn_every_min, _cur_interval)
	var delay: float = max(spawn_every_min, _sample_exp(mean))
	if first and INITIAL_DESYNC > 0.0:
		delay += randf_range(0.0, INITIAL_DESYNC)
	_spawn_timer.start(delay)

func _sample_exp(mean: float) -> float:
	var u: float = clamp(randf(), 1e-6, 1.0 - 1e-6)
	return -log(1.0 - u) * mean


func _on_spawn_tick() -> void:
	_spawn_one()
	_schedule_next_spawn()

# spawning 
func _spawn_one() -> void:
	if _to_spawn_in_wave <= 0 or enemy_scene == null or _board == null:
		_maybe_finish_wave()
		return

	# Portal basis + tile metrics
	var basis: Array = _portal_spawn_basis()
	var origin: Vector3 = basis[0]
	var forward: Vector3 = basis[1]
	var right: Vector3 = basis[2]

	var ts: float = 2.0
	var maybe_size = _board.get("tile_size")
	if typeof(maybe_size) == TYPE_FLOAT or typeof(maybe_size) == TYPE_INT:
		ts = float(maybe_size)

	# Depth just inside the first tile
	var entry_depth: float = clamp(ts * ENTRY_DEPTH_FACTOR, 0.08, 0.35)

	# Crowd gate, if entry cell has too many retry shortly
	var entry_cell: Vector2i = _board.world_to_cell(origin + forward * entry_depth)
	var count := 0
	for e in get_tree().get_nodes_in_group("enemy"):
		if _board.world_to_cell(e.global_position) == entry_cell:
			count += 1
			if count >= ENTRY_CROWD_LIMIT:
				_spawn_timer.start(randf_range(BLOCKED_RETRY_MIN, BLOCKED_RETRY_MAX))
				return

	# jitter spawn so paths aren't identical
	var lateral_amt: float = clamp(ts * LATERAL_JITTER_FACTOR, LATERAL_JITTER_MIN, LATERAL_JITTER_MAX)
	var lateral: Vector3 = right * randf_range(-lateral_amt, lateral_amt)

	# Instantiate outside the portal
	var e: CharacterBody3D = enemy_scene.instantiate()
	e.tile_board_path = _board.get_path()
	add_child(e)

	var pos: Vector3 = origin - forward * ENTRY_OFFSET + lateral
	e.global_position = pos
	e.look_at(pos + forward, Vector3.UP)
	e.lock_y_to(pos.y)

	var entry_point: Vector3 = origin + forward * entry_depth + lateral
	e.set_entry_target(entry_point, max(entry_depth * 1.4, 0.32))

	_to_spawn_in_wave -= 1
	_maybe_finish_wave()

# Basis aligned to portal rotation
func _portal_spawn_basis() -> Array:
	var t: Transform3D
	if _board.spawner_node.has_node("SpawnPoint"):
		t = _board.spawner_node.get_node("SpawnPoint").global_transform
	else:
		t = _board.spawner_node.global_transform

	var origin: Vector3 = t.origin
	var forward: Vector3 = (-t.basis.z).normalized() 

	# Make sure "forward" points toward the goal
	var goal_pos: Vector3 = _board.get_goal_position() if _board.has_method("get_goal_position") else origin + Vector3.FORWARD
	var to_goal: Vector3 = (goal_pos - origin).normalized()
	if forward.dot(to_goal) < 0.0:
		forward = -forward

	var right: Vector3 = Vector3.UP.cross(forward).normalized()
	return [origin, forward, right]

func _maybe_finish_wave() -> void:
	if _to_spawn_in_wave > 0:
		return
	_spawn_timer.stop()
	if not _sent_all_spawned:
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
	_cache_rig()
	if projectile_scene == null or _muzzle == null:
		return 1.0

	if _turret:
		var dir := target_world - _turret.global_transform.origin
		dir.y = 0.0
		if dir.length() > 0.001:
			_turret.look_at(_turret.global_transform.origin + dir, Vector3.UP)

	_recoil_barrel()

	var p: Node3D = projectile_scene.instantiate()
	add_child(p)
	p.global_position = _muzzle.global_position

	var flight_t: float = 1.0
	if p.has_method("get"):
		var ft = p.get("flight_time")
		if typeof(ft) == TYPE_FLOAT or typeof(ft) == TYPE_INT:
			flight_t = float(ft)

	if p.has_method("launch"):
		p.call("launch", target_world)

	return flight_t

func _recoil_barrel() -> void:
	if _barrel == null:
		return
	if _recoil_tw and _recoil_tw.is_running():
		_recoil_tw.kill()

	var start := _barrel.global_position
	var back := start - _barrel.global_transform.basis.z * 0.25

	_recoil_tw = create_tween()
	_recoil_tw.tween_property(_barrel, "global_position", back, 0.08).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_recoil_tw.tween_property(_barrel, "global_position", start, 0.12).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
