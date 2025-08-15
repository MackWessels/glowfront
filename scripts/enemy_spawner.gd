extends Node3D

@export var enemy_scene: PackedScene
@export var elite_enemy_scene: PackedScene
@export var tile_board_path: NodePath = ^".."

#  Pool / population 
@export var pool_size: int = 24
@export var elite_pool_size: int = 8
@export var max_active: int = 16
@export var entry_crowd_limit: int = 2  

#  Wave settings 
@export var auto_start: bool = true
@export var intermission: float = 4.0
@export var wave_size_base: int = 8
@export var wave_size_inc: int = 1
@export var wave_first_spawn_delay: float = 0.35
@export var spawn_gap: float = 0.2

# Elite schedule (linear growth)
@export var elite_start_wave: int = 2
@export var elite_every_n_waves: int = 3
@export var elite_cap_per_wave: int = 4

@export var hp_growth_per_wave: float = 1.10
@export var speed_growth_per_wave: float = 1.02

# Spawn placement tuning 
const ENTRY_MARGIN: float            = 0.18
const LATERAL_JITTER_RATIO: float    = 0.20
const LATERAL_JITTER_MIN: float      = 0.06
const LATERAL_JITTER_MAX: float      = 0.35
const SPAWN_BEHIND_TILE_RATIO: float = 0.65
const ENTRY_DEPTH_TILE_RATIO: float  = 0.3

#  Signals 
signal wave_started(wave: int, size: int)
signal wave_cleared(wave: int)

# Internals 
var _board: Node3D = null
var _pool_basic: Array[CharacterBody3D] = []
var _pool_elite: Array[CharacterBody3D] = []
var _active: Array[CharacterBody3D] = []

var _ts: float = 2.0
var _paused: bool = false

enum { BETWEEN, SPAWNING, WAITING }
var _state: int = BETWEEN
var _wave: int = 0
var _to_spawn: int = 0
var _between_t: float = 0.0
var _spawn_cooldown: float = 0.0

# Wave plan: true = elite, false = basic
var _plan: Array[bool] = []

func _ready() -> void:
	randomize()

	if has_node(tile_board_path):
		var n := get_node(tile_board_path)
		if n is Node3D:
			_board = n as Node3D
	if _board == null:
		push_error("EnemySpawner: tile_board_path is invalid or missing.")
		return

	var ts_any: Variant = _board.get("tile_size")
	if typeof(ts_any) == TYPE_FLOAT or typeof(ts_any) == TYPE_INT:
		_ts = float(ts_any)

	_build_pool_generic(enemy_scene, pool_size, _pool_basic)
	if elite_enemy_scene:
		_build_pool_generic(elite_enemy_scene, elite_pool_size, _pool_elite)

	_state = BETWEEN
	if auto_start:
		_between_t = float(max(0.0, wave_first_spawn_delay))
	else:
		_between_t = 0.0

	set_physics_process(true)

# -----------------------------
# Pool lifecycle
# -----------------------------
func _build_pool_generic(scene: PackedScene, count: int, into: Array) -> void:
	if scene == null:
		return
	for i in range(count):
		var e := scene.instantiate() as CharacterBody3D
		if e == null:
			push_error("EnemySpawner: scene must be a CharacterBody3D.")
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
		into.append(e)

func _acquire_enemy(is_elite: bool) -> CharacterBody3D:
	var pool: Array = _pool_basic
	if is_elite:
		pool = _pool_elite

	while pool.size() > 0:
		var e: CharacterBody3D = pool.pop_back()
		if is_instance_valid(e):
			return e

	# expand pool on demand
	var scene: PackedScene = enemy_scene
	if is_elite and elite_enemy_scene:
		scene = elite_enemy_scene
	if scene == null:
		return null

	var e2: CharacterBody3D = scene.instantiate() as CharacterBody3D
	if e2 != null:
		if _board != null:
			e2.set("tile_board_path", _board.get_path())
		add_child(e2)
		if e2.has_signal("released"):
			e2.connect("released", Callable(self, "_on_enemy_released").bind(e2))
		e2.tree_exited.connect(Callable(self, "_on_enemy_tree_exited").bind(e2))
		if not e2.has_meta("orig_layer"):
			e2.set_meta("orig_layer", e2.collision_layer)
		if not e2.has_meta("orig_mask"):
			e2.set_meta("orig_mask", e2.collision_mask)
		_deactivate_enemy(e2)
	return e2

func _release_enemy(e: CharacterBody3D) -> void:
	if e == null:
		return
	if not is_instance_valid(e):
		return
	_active.erase(e)
	_deactivate_enemy(e)
	var is_elite := false
	if e.has_meta("elite"):
		is_elite = bool(e.get_meta("elite"))
	if is_elite:
		_pool_elite.append(e)
	else:
		_pool_basic.append(e)

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

# -----------------------------
# Wave FSM
# -----------------------------
func _physics_process(delta: float) -> void:
	if _paused or _board == null:
		return

	# Scrub references
	_active = _active.filter(func(n): return is_instance_valid(n))
	_pool_basic = _pool_basic.filter(func(n): return is_instance_valid(n))
	_pool_elite = _pool_elite.filter(func(n): return is_instance_valid(n))

	match _state:
		BETWEEN:
			if _between_t > 0.0:
				_between_t -= delta
			else:
				_start_next_wave()

		SPAWNING:
			if _spawn_cooldown > 0.0:
				_spawn_cooldown -= delta
			else:
				if _to_spawn > 0 and _active.size() < max_active:
					var lane := _choose_lane_with_room()
					if lane != 999:
						var is_elite := false
						if not _plan.is_empty():
							is_elite = _plan.pop_front()
						var e := _acquire_enemy(is_elite)
						if e != null:
							_spawn_enemy(e, lane, is_elite)
							_to_spawn -= 1
							_spawn_cooldown = float(max(0.0, spawn_gap))
				if _to_spawn <= 0:
					_state = WAITING

		WAITING:
			if _active.is_empty():
				emit_signal("wave_cleared", _wave)
				_state = BETWEEN
				_between_t = float(max(0.0, intermission))

func _start_next_wave() -> void:
	_wave += 1
	_plan = _build_wave_plan(_wave)
	_to_spawn = _plan.size()
	emit_signal("wave_started", _wave, _to_spawn)
	_state = SPAWNING
	_spawn_cooldown = float(max(0.0, wave_first_spawn_delay))

func _calc_wave_size(w: int) -> int:
	var steps: int = w - 1
	if steps < 0:
		steps = 0
	var size: int = wave_size_base + steps * wave_size_inc
	if size < 1:
		size = 1
	return size

func _build_wave_plan(wave: int) -> Array[bool]:
	var size := _calc_wave_size(wave)
	if size <= 0:
		return []

	var elites := 0
	if elite_enemy_scene and wave >= elite_start_wave:
		elites = int(floor(float(wave - elite_start_wave) / float(max(1, elite_every_n_waves)))) + 1
		elites = clamp(elites, 0, elite_cap_per_wave)
	elites = min(elites, size)

	var plan: Array[bool] = []
	if elites == 0:
		for i in range(size):
			plan.append(false)
		return plan

	var interval := float(size) / float(elites + 1)
	var next_elite_at := int(round(interval)) - 1
	var remaining := elites

	for i in range(size):
		if remaining > 0 and i == next_elite_at:
			plan.append(true)
			remaining -= 1
			next_elite_at += int(round(interval))
		else:
			plan.append(false)
	return plan

# -----------------------------
# Lane selection (TileBoard.get_spawn_gate to get exact three cells)
# -----------------------------
func _choose_lane_with_room() -> int:
	var info: Dictionary = _board.get_spawn_gate(3)

	var centers: Array = []
	if info.has("lane_centers"):
		centers = info["lane_centers"]
	if centers.is_empty():
		return 0

	var lanes: Array = []
	var mid := int(centers.size() / 2)
	for i in range(centers.size()):
		var p: Vector3 = centers[i]
		var c: Vector2i = _board.world_to_cell(p)
		lanes.append({ "lane": i - mid, "cell": c })

	var nodes_group := get_tree().get_nodes_in_group("enemies")
	if nodes_group.is_empty():
		nodes_group = get_tree().get_nodes_in_group("enemy")
	var nodes: Array = nodes_group
	if nodes.is_empty():
		nodes = []
		for en in _active:
			nodes.append(en)

	var best_lane := 999
	var best_basic := 999

	for item in lanes:
		var lane_i: int = item["lane"]
		var cell: Vector2i = item["cell"]

		# skip if tile is pending/blue 
		if _is_tile_blocked_for_spawn(cell):
			continue

		var basic_count := 0
		var elite_present := false

		for obj in nodes:
			var en := obj as Node3D
			if en == null:
				continue
			if not en.visible:
				continue
			if _board.world_to_cell(en.global_position) != cell:
				continue

			var is_elite := false
			if en.has_meta("elite"):
				is_elite = bool(en.get_meta("elite"))
			elif en.has_method("is_elite"):
				is_elite = bool(en.call("is_elite"))

			if is_elite:
				elite_present = true
				break
			else:
				basic_count += 1
				if basic_count >= entry_crowd_limit:
					break

		if elite_present:
			continue
		if basic_count >= entry_crowd_limit:
			continue

		if basic_count < best_basic:
			best_basic = basic_count
			best_lane = lane_i
		elif basic_count == best_basic and lane_i == 0:
			best_basic = basic_count
			best_lane = lane_i

	return best_lane

func _is_tile_blocked_for_spawn(cell: Vector2i) -> bool:
	var tiles_dict: Dictionary = _board.get("tiles")
	if not tiles_dict.has(cell):
		return true

	var closing_dict: Dictionary = _board.get("closing")
	if closing_dict.has(cell):
		return true

	var tile: Node = tiles_dict.get(cell, null)
	if tile == null:
		return true
	if tile.has_method("is_walkable"):
		return not bool(tile.call("is_walkable"))
	return false

# -----------------------------
# Spawn enemy into a chosen lane
# -----------------------------
func _spawn_enemy(enemy: CharacterBody3D, lane_i: int, is_elite: bool) -> void:
	var info: Dictionary = _board.get_spawn_gate(3)

	var centers: Array = []
	if info.has("lane_centers"):
		centers = info["lane_centers"]

	var forward: Vector3 = Vector3.FORWARD
	if info.has("forward"):
		forward = info["forward"]

	var right: Vector3 = Vector3.RIGHT
	if info.has("lateral"):
		right = info["lateral"]

	var mid: int = int(centers.size() / 2)
	var max_index: int = max(0, centers.size() - 1)
	var idx: int = clampi(mid + lane_i, 0, max_index)
	var lane_center: Vector3 = _board.get_spawn_position()
	if not centers.is_empty():
		lane_center = centers[idx]

	# placement & targets 
	var half: float = _ts * 0.5
	var max_lat: float = float(max(0.0, half - ENTRY_MARGIN))

	var jitter_span: float = float(clamp(_ts * LATERAL_JITTER_RATIO, LATERAL_JITTER_MIN, LATERAL_JITTER_MAX))
	var jitter_limit: float = float(min(max_lat * 0.85, jitter_span))
	var jitter: Vector3 = right * randf_range(-jitter_limit, jitter_limit)

	# Start OUTSIDE
	var spawn_back: float = float(clamp(_ts * SPAWN_BEHIND_TILE_RATIO, 0.05, _ts * 1.2))
	var start_pos: Vector3 = lane_center - forward * spawn_back + jitter

	# Walk to a deep entry target inside the lane
	var max_depth: float = half - ENTRY_MARGIN
	var entry_depth: float = float(clamp(_ts * ENTRY_DEPTH_TILE_RATIO, 0.04, max_depth))
	var entry_world: Vector3 = lane_center + forward * entry_depth + jitter
	var arrive_radius: float = float(clamp(_ts * 0.25, 0.08, entry_depth * 0.6))

	# place first at the spawner side
	var s: Vector3 = enemy.scale
	enemy.global_position = start_pos
	enemy.look_at(start_pos + forward, Vector3.UP)
	enemy.scale = s
	if enemy.has_method("lock_y_to"):
		enemy.call("lock_y_to", lane_center.y)

	# Mark elite/basic so lane crowding logic can see it
	enemy.set_meta("elite", is_elite)
	_set_if_has_property(enemy, "is_elite", is_elite)

	_apply_wave_scaling(enemy, _wave)

	# configure the entry
	if enemy.has_method("set_entry_target"):
		enemy.call("set_entry_target", entry_world, arrive_radius)
	if enemy.has_method("reset_for_spawn"):
		enemy.call("reset_for_spawn")
	if enemy.has_method("set_paused"):
		enemy.call("set_paused", false)

	_activate_enemy(enemy)
	_active.append(enemy)

# -----------------------------
# Wave scaling 
# -----------------------------
func _apply_wave_scaling(e: CharacterBody3D, wave: int) -> void:
	if wave <= 1:
		return

	if not e.has_meta("base_hp") and e.has_method("get"):
		var hp_any: Variant = e.get("max_health")
		if typeof(hp_any) == TYPE_INT:
			e.set_meta("base_hp", int(hp_any))

	if not e.has_meta("base_speed") and e.has_method("get"):
		var sp_any: Variant = e.get("speed")
		if typeof(sp_any) == TYPE_FLOAT or typeof(sp_any) == TYPE_INT:
			e.set_meta("base_speed", float(sp_any))

	if e.has_meta("base_hp"):
		var base_hp: int = int(e.get_meta("base_hp"))
		var steps: int = wave - 1
		if steps < 0:
			steps = 0
		var new_hp: int = int(round(float(base_hp) * pow(hp_growth_per_wave, steps)))
		e.set("max_health", new_hp)

	if e.has_meta("base_speed"):
		var base_sp: float = float(e.get_meta("base_speed"))
		var steps2: int = wave - 1
		if steps2 < 0:
			steps2 = 0
		var new_sp: float = base_sp * pow(speed_growth_per_wave, steps2)
		e.set("speed", new_sp)

# -----------------------------
# Basis fallback
# -----------------------------
func _portal_spawn_basis() -> Array[Vector3]:
	var info: Dictionary = _board.get_spawn_gate(3)
	if info.has("lane_centers") and info.has("forward") and info.has("lateral"):
		var centers: Array = info["lane_centers"]
		var mid := int(centers.size() / 2)
		var origin: Vector3 = _board.get_spawn_position()
		if not centers.is_empty():
			origin = centers[mid]
		var fwd: Vector3 = info["forward"]
		var lat: Vector3 = info["lateral"]
		return [origin, fwd, lat]

	var spawner: Node3D = _board.spawner_node
	var t: Transform3D = spawner.global_transform
	var origin2: Vector3 = t.origin
	var goal_pos: Vector3 = (_board.get_goal_position() as Vector3)

	var forward2: Vector3 = -t.basis.z
	forward2.y = 0.0
	if forward2.length() > 0.0001:
		forward2 = forward2.normalized()
	else:
		var toward_goal: Vector3 = goal_pos - origin2
		toward_goal.y = 0.0
		if toward_goal.length() > 0.0001:
			forward2 = toward_goal.normalized()
		else:
			forward2 = Vector3.FORWARD

	var goal_dir: Vector3 = goal_pos - origin2
	goal_dir.y = 0.0
	if goal_dir.length() > 0.0001 and forward2.dot(goal_dir.normalized()) < 0.0:
		forward2 = -forward2

	var right2: Vector3 = forward2.cross(Vector3.UP)
	if right2.length() > 0.0001:
		right2 = right2.normalized()
	else:
		right2 = Vector3.RIGHT
	return [origin2, forward2, right2]

# -----------------------------
# Signals from enemies
# -----------------------------
func _on_enemy_released(e: CharacterBody3D) -> void:
	_release_enemy(e)

func _on_enemy_tree_exited(e: CharacterBody3D) -> void:
	_active.erase(e)
	_pool_basic.erase(e)
	_pool_elite.erase(e)

func pause_spawning(p: bool) -> void:
	_paused = p

# -----------------------------
# Helpers
# -----------------------------
func _set_if_has_property(obj: Object, prop: String, value: Variant) -> void:
	for p in obj.get_property_list():
		if p.name == prop:
			obj.set(prop, value)
			return
