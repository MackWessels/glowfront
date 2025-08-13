# EnemySpawner.gd — pool-based, crowd-gated waves
extends Node3D

@export var enemy_scene: PackedScene
@export var tile_board_path: NodePath = ^".."

# ---------- Pool / population ----------
@export var pool_size: int = 24
@export var max_active: int = 16
@export var entry_crowd_limit: int = 2

# ---------- Wave settings ----------
@export var auto_start: bool = true
@export var intermission: float = 4.0        # seconds between waves
@export var wave_size_base: int = 8          # wave 1 size
@export var wave_size_inc: int = 1           # +N each wave
@export var wave_first_spawn_delay: float = 0.35  # delay before first spawn in each wave
@export var spawn_gap: float = 0.2          # spacing between spawns within a wave (0 = none)


@export var hp_growth_per_wave: float = 1.10   # 10% more HP per wave
@export var speed_growth_per_wave: float = 1.02

# ---------- Spawn placement tuning ----------
const ENTRY_OFFSET: float            = 1.2
const ENTRY_DEPTH_FACTOR: float      = 0.12
const LATERAL_JITTER_FACTOR: float   = 0.22
const LATERAL_JITTER_MIN: float      = 0.10
const LATERAL_JITTER_MAX: float      = 0.45

# ---------- Signals ----------
signal wave_started(wave: int, size: int)
signal wave_cleared(wave: int)

# ---------- Internals ----------
var _board: Node3D = null
var _pool: Array[CharacterBody3D] = []
var _active: Array[CharacterBody3D] = []

var _ts: float = 2.0
var _paused: bool = false

enum { BETWEEN, SPAWNING, WAITING }
var _state: int = BETWEEN
var _wave: int = 0
var _to_spawn: int = 0
var _between_t: float = 0.0
var _spawn_cooldown: float = 0.0

func _ready() -> void:
	randomize()

	_board = get_node_or_null(tile_board_path) as Node3D
	if _board == null:
		push_error("EnemySpawner: tile_board_path is invalid or missing.")
		return

	var ts_any: Variant = _board.get("tile_size")
	if typeof(ts_any) == TYPE_FLOAT or typeof(ts_any) == TYPE_INT:
		_ts = float(ts_any)

	_build_pool()

	if auto_start:
		_state = BETWEEN
		_between_t = max(0.0, wave_first_spawn_delay)  # delay before wave 1
	else:
		_state = BETWEEN
		_between_t = 0.0

	set_physics_process(true)

# -------------------------------------------------------------------
# Pool lifecycle
# -------------------------------------------------------------------
func _build_pool() -> void:
	if enemy_scene == null:
		push_error("EnemySpawner: enemy_scene is null.")
		return

	for i in range(pool_size):
		var e := enemy_scene.instantiate() as CharacterBody3D
		if e == null:
			push_error("EnemySpawner: enemy_scene must be a CharacterBody3D.")
			return

		if _board != null:
			e.set("tile_board_path", _board.get_path())

		add_child(e)

		if e.has_signal("released"):
			e.connect("released", Callable(self, "_on_enemy_released").bind(e))
		e.tree_exited.connect(Callable(self, "_on_enemy_tree_exited").bind(e))

		if not e.has_meta("orig_layer"):
			e.set_meta("orig_layer", e.collision_layer)
		if not e.has_meta("orig_mask"):
			e.set_meta("orig_mask", e.collision_mask)

		_deactivate_enemy(e)
		_pool.append(e)

func _acquire_enemy() -> CharacterBody3D:
	if _pool.size() > 0:
		return _pool.pop_back()

	var e := enemy_scene.instantiate() as CharacterBody3D
	if e != null:
		if _board != null:
			e.set("tile_board_path", _board.get_path())
		add_child(e)
		if e.has_signal("released"):
			e.connect("released", Callable(self, "_on_enemy_released").bind(e))
		e.tree_exited.connect(Callable(self, "_on_enemy_tree_exited").bind(e))
		if not e.has_meta("orig_layer"):
			e.set_meta("orig_layer", e.collision_layer)
		if not e.has_meta("orig_mask"):
			e.set_meta("orig_mask", e.collision_mask)
		_deactivate_enemy(e)
	return e

func _release_enemy(e: CharacterBody3D) -> void:
	if e == null:
		return
	_active.erase(e)
	_deactivate_enemy(e)
	_pool.append(e)

func _deactivate_enemy(e: CharacterBody3D) -> void:
	e.visible = false
	e.set_process(false)
	e.set_physics_process(false)
	e.collision_layer = 0
	e.collision_mask  = 0
	var park_under: Vector3
	if _board != null:
		park_under = _board.global_transform.origin + Vector3(0, -1000.0, 0)
	else:
		park_under = global_transform.origin + Vector3(0, -1000.0, 0)
	e.global_position = park_under

func _activate_enemy(e: CharacterBody3D) -> void:
	e.visible = true
	e.set_process(true)
	e.set_physics_process(true)
	if e.has_meta("orig_layer"):
		e.collision_layer = int(e.get_meta("orig_layer"))
	if e.has_meta("orig_mask"):
		e.collision_mask  = int(e.get_meta("orig_mask"))

# -------------------------------------------------------------------
# Wave FSM
# -------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	if _paused or _board == null:
		return

	_active = _active.filter(func(n): return is_instance_valid(n))

	match _state:
		BETWEEN:
			if _between_t > 0.0:
				_between_t -= delta
				return
			_start_next_wave()

		SPAWNING:
			if _spawn_cooldown > 0.0:
				_spawn_cooldown -= delta
				return

			if _to_spawn > 0 and _active.size() < max_active and _entry_has_room():
				var e := _acquire_enemy()
				if e != null:
					_spawn_enemy(e)
					_to_spawn -= 1
					_spawn_cooldown = max(0.0, spawn_gap)

			if _to_spawn <= 0:
				_state = WAITING

		WAITING:
			# when field is clear, go to intermission
			if _active.is_empty():
				emit_signal("wave_cleared", _wave)
				_state = BETWEEN
				_between_t = max(0.0, intermission)

# Start / config
func _start_next_wave() -> void:
	_wave += 1
	_to_spawn = _calc_wave_size(_wave)
	emit_signal("wave_started", _wave, _to_spawn)
	_state = SPAWNING
	_spawn_cooldown = max(0.0, wave_first_spawn_delay)

func _calc_wave_size(w: int) -> int:
	var steps: int = w - 1
	if steps < 0:
		steps = 0
	var size: int = wave_size_base + steps * wave_size_inc
	if size < 1:
		size = 1
	return size

# -------------------------------------------------------------------
# Spawn one enemy (position, facing, entry target)
# -------------------------------------------------------------------
func _spawn_enemy(enemy: CharacterBody3D) -> void:
	var basis := _portal_spawn_basis()
	var origin: Vector3  = basis[0]
	var forward: Vector3 = basis[1]
	var right: Vector3   = basis[2]

	var entry_depth: float = clamp(_ts * ENTRY_DEPTH_FACTOR, 0.08, 0.35)
	var lateral_amt: float = clamp(_ts * LATERAL_JITTER_FACTOR, LATERAL_JITTER_MIN, LATERAL_JITTER_MAX)
	var lateral: Vector3 = right * randf_range(-lateral_amt, lateral_amt)

	var entry_world: Vector3 = origin + forward * entry_depth + lateral
	var arrive_radius: float = max(entry_depth * 1.4, 0.32)

	# 1) place first
	var s: Vector3 = enemy.scale
	var start_pos: Vector3 = origin - forward * ENTRY_OFFSET + lateral
	enemy.global_position = start_pos
	enemy.look_at(start_pos + forward, Vector3.UP)
	enemy.scale = s
	if enemy.has_method("lock_y_to"):
		enemy.call("lock_y_to", origin.y)

	# Optional wave scaling (works if your enemy has these properties)
	_apply_wave_scaling(enemy, _wave)

	# 2) then configure entry from placed position
	if enemy.has_method("set_entry_target"):
		enemy.call("set_entry_target", entry_world, arrive_radius)

	# 3) unpause/reset
	if enemy.has_method("reset_for_spawn"):
		enemy.call("reset_for_spawn")
	if enemy.has_method("set_paused"):
		enemy.call("set_paused", false)

	_activate_enemy(enemy)
	_active.append(enemy)

func _apply_wave_scaling(e: CharacterBody3D, wave: int) -> void:
	if wave <= 1:
		return
	# cache base values once
	if not e.has_meta("base_hp") and e.has_method("get"):
		var hp_any: Variant = e.get("max_health")
		if typeof(hp_any) == TYPE_INT:
			e.set_meta("base_hp", int(hp_any))
	if not e.has_meta("base_speed") and e.has_method("get"):
		var sp_any: Variant = e.get("speed")
		if typeof(sp_any) == TYPE_FLOAT:
			e.set_meta("base_speed", float(sp_any))

	# apply growth if bases exist
	if e.has_meta("base_hp"):
		var base_hp: int = int(e.get_meta("base_hp"))
		var new_hp: int = int(round(float(base_hp) * pow(hp_growth_per_wave, wave - 1)))
		e.set("max_health", new_hp)
		# if your enemy resets health = max_health inside reset_for_spawn, this will sync automatically

	if e.has_meta("base_speed"):
		var base_sp: float = float(e.get_meta("base_speed"))
		var new_sp: float = base_sp * pow(speed_growth_per_wave, wave - 1)
		e.set("speed", new_sp)

# -------------------------------------------------------------------
# Entry crowd gate
# -------------------------------------------------------------------
func _entry_has_room() -> bool:
	var basis := _portal_spawn_basis()
	var origin: Vector3  = basis[0]
	var forward: Vector3 = basis[1]

	var entry_depth: float = clamp(_ts * ENTRY_DEPTH_FACTOR, 0.08, 0.35)
	var entry_world: Vector3 = origin + forward * entry_depth
	var entry_cell: Vector2i = _board.world_to_cell(entry_world)

	var in_cell: int = 0
	for n in get_tree().get_nodes_in_group("enemies"):
		var en := n as Node3D
		if en == null:
			continue
		if not en.visible:
			continue
		if _board.world_to_cell(en.global_position) == entry_cell:
			in_cell += 1
			if in_cell >= entry_crowd_limit:
				return false
	return true

# -------------------------------------------------------------------
# Portal basis aligned to spawner rotation; flattened on XZ
# -------------------------------------------------------------------
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
	if forward.length() > 0.0001:
		forward = forward.normalized()
	else:
		var toward_goal: Vector3 = goal_pos - origin
		toward_goal.y = 0.0
		if toward_goal.length() > 0.0001:
			forward = toward_goal.normalized()
		else:
			forward = Vector3.FORWARD

	# Ensure it points toward goal
	var goal_dir: Vector3 = goal_pos - origin
	goal_dir.y = 0.0
	if goal_dir.length() > 0.0001:
		var gnorm: Vector3 = goal_dir.normalized()
		if forward.dot(gnorm) < 0.0:
			forward = -forward

	# Right-hand basis
	var right: Vector3 = forward.cross(Vector3.UP)
	if right.length() > 0.0001:
		right = right.normalized()
	else:
		right = Vector3.RIGHT

	return [origin, forward, right]

# -------------------------------------------------------------------
# Signals from enemies
# -------------------------------------------------------------------
func _on_enemy_released(e: CharacterBody3D) -> void:
	_release_enemy(e)

func _on_enemy_tree_exited(e: CharacterBody3D) -> void:
	_active.erase(e)

# -------------------------------------------------------------------
# Optional pause
# -------------------------------------------------------------------
func pause_spawning(p: bool) -> void:
	_paused = p
