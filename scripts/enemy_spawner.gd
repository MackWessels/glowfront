extends Node3D
class_name EnemySpawner

# Setup
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

# spawn location (0 = on the first in-grid cell center)
@export var spawn_outward_tiles: float = 1.0

# movement priming
@export var nudge_on_spawn: float = 0.0

# anti-stacking
@export var spawn_spread_tiles: float = 0.35
@export var spawn_forward_jitter_tiles: float = 0.15

# optional entry glide
@export var use_entry_step: bool = true
@export var entry_step_radius_tiles: float = 0.9

# ---------- Waves (basic + tank only) ----------
@export var tier: int = 1
@export var wave_index: int = 1
@export var wave_time_sec: float = 26.0
@export var wave_cooldown_sec: float = 9.0
@export var base_wave_count: int = 11
@export var per_wave_count: int = 2
@export var per_tier_bonus: int = 5

@export var tank_weight_start: float = 5.0
@export var tank_weight_per_wave: float = 1.0
@export var tank_weight_per_tier: float = 4.0

const BASE := {
	"basic": {"hp": 3,  "atk": 1, "spd": 1.00, "mass": 1.05},
	"tank":  {"hp": 17, "atk": 1, "spd": 0.60, "mass": 5.10},
}

# --- State ---
var _board: Node = null
var _timer: Timer
var _phase_timer: Timer
var _phase := "idle"          # "spawning" | "cooldown" | "idle"
var _paused := false
var _alive := 0
var _lane_idx := -1
var _wave_remaining := 0

func _ready() -> void:
	_timer = Timer.new()
	_timer.one_shot = false
	_timer.wait_time = maxf(0.05, spawn_interval)
	add_child(_timer)
	_timer.timeout.connect(_on_spawn_tick)

	_phase_timer = Timer.new()
	_phase_timer.one_shot = true
	add_child(_phase_timer)
	_phase_timer.timeout.connect(_on_phase_timer)

	if tile_board_path != NodePath(""):
		_board = get_node_or_null(tile_board_path)
	if _board == null:
		_board = get_tree().get_first_node_in_group("TileBoard")

	_build_pool_generic()
	if auto_start:
		start_spawning()

# --- Public API ---
func start_spawning() -> void:
	_paused = false
	_timer.wait_time = maxf(0.05, spawn_interval)
	if _timer.is_stopped():
		_timer.start()
	if _phase != "spawning":
		_phase = "spawning"
		_wave_remaining = _calc_wave_count()
		_phase_timer.start(maxf(0.1, wave_time_sec))

func stop_spawning() -> void:
	if not _timer.is_stopped():
		_timer.stop()
	_phase_timer.stop()
	_phase = "idle"

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

func shoot_tile(_world_pos: Vector3) -> float:
	var t := create_tween()
	t.tween_property(self, "rotation:y", rotation.y + 0.25, 0.15)
	t.tween_property(self, "rotation:y", rotation.y, 0.15)
	return 0.35

# --- Wave phase timer ---
func _on_phase_timer() -> void:
	if _phase == "spawning":
		_phase = "cooldown"
		_phase_timer.start(maxf(0.1, wave_cooldown_sec))
	elif _phase == "cooldown":
		wave_index += 1
		_phase = "spawning"
		_wave_remaining = _calc_wave_count()
		_phase_timer.start(maxf(0.1, wave_time_sec))

# --- Spawning ---
func _on_spawn_tick() -> void:
	if _paused or _board == null or enemy_scene == null:
		return
	if _alive >= max_alive:
		return
	if _phase != "spawning" or _wave_remaining <= 0:
		return

	var cap := max_alive - _alive
	var to_spawn: int = min(burst_count, min(_wave_remaining, cap))
	if to_spawn <= 0:
		return

	for _i in range(to_spawn):
		_spawn_one()
		_wave_remaining -= 1

func _spawn_one() -> void:
	if _board == null or not _board.has_method("get_spawn_pen"):
		return

	var span := _get_board_int("spawner_span", 3)
	if span_override > 0:
		span = span_override

	var info: Dictionary = _board.get_spawn_pen(span)
	var exits: Array = info.get("entry_targets", [])
	var fwd: Vector3 = info.get("forward", Vector3.FORWARD)
	var lat: Vector3 = info.get("lateral", Vector3.RIGHT)
	if exits.is_empty():
		return

	var tile_w := _tile_w()
	var spawn_radius := float(info.get("spawn_radius", 0.6 * tile_w))
	var exit_radius := float(info.get("exit_radius", 0.35 * tile_w))

	# lane pick
	var lane: int
	if use_round_robin:
		_lane_idx = (_lane_idx + 1) % exits.size()
		lane = _lane_idx
	else:
		lane = randi() % exits.size()

	var sig := _lane_signature_for_lane(lane, exits.size())

	# lateral offset target for first tile
	var base: Vector3 = exits[lane]  # first in-grid cell center
	var c0: Vector2i = _board.call("world_to_cell", base)
	var lane_world := _predict_lane_offset_world(sig, c0, tile_w)

	var lat_cap := minf(spawn_radius, spawn_spread_tiles * tile_w)
	lane_world = clampf(lane_world, -lat_cap, lat_cap)

	# spawn at the first in-grid cell (no backward offset)
	var outward := maxf(0.0, spawn_outward_tiles)  # default 0
	var p: Vector3 = base - fwd * (tile_w * outward) + lat * lane_world

	# small forward-only jitter to avoid stacking (never backwards)
	var fwd_mag := spawn_forward_jitter_tiles * tile_w
	if fwd_mag > 0.0:
		p += fwd * randf_range(0.0, fwd_mag)

	# instance
	var inst := enemy_scene.instantiate()
	if inst == null:
		return

	# wire refs before _ready
	if _board != null:
		inst.set("tile_board_path", _board.get_path())
		var g: Variant = _board.get("goal_node")
		if typeof(g) == TYPE_OBJECT and g != null and g is Node3D:
			inst.set("goal_node_path", g.get_path())
	inst.set("lane_spread_tiles", spawn_spread_tiles)

	add_child(inst)
	if inst.has_signal("died"):
		inst.died.connect(_on_enemy_died)

	# seed lane signature to align with our lane offset
	inst.set("_lane_signature", sig)

	# place first
	inst.global_position = p
	if inst.has_method("lock_y_to"):
		inst.lock_y_to(p.y)

	# plan from this position
	if inst.has_method("reset_for_spawn"):
		inst.reset_for_spawn()

	# optional entry glide
	if use_entry_step and inst.has_method("set_entry_target"):
		inst.set_entry_target(base, maxf(exit_radius, entry_step_radius_tiles * tile_w))

	# no default nudge (kept configurable)
	if nudge_on_spawn > 0.0:
		var nudge := tile_w * 0.12 * clampf(nudge_on_spawn, 0.0, 1.0)
		inst.global_position += fwd * nudge

	# stats
	var typ := _pick_type()
	var stats := _compute_stats(typ, wave_index, tier)
	if inst.has_method("apply_stats"):
		inst.apply_stats(stats)
	else:
		for k in stats.keys():
			inst.set(k, stats[k])

	if inst.has_method("look_at"):
		inst.look_at(inst.global_position + fwd, Vector3.UP)

	_alive += 1

# --- Callbacks ---
func _on_enemy_died() -> void:
	_alive = max(0, _alive - 1)

# --- Stubs / helpers ---
func _build_pool_generic() -> void:
	pass

func _tile_w() -> float:
	if _board and _board.has_method("tile_world_size"):
		return float(_board.call("tile_world_size"))
	var tv: Variant = _board.get("tile_size") if _board else 1.0
	if typeof(tv) == TYPE_FLOAT or typeof(tv) == TYPE_INT:
		return float(tv)
	return 1.0

func _get_board_int(prop: String, def: int) -> int:
	if _board == null:
		return def
	var v: Variant = _board.get(prop)
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		return int(v)
	return def

# ---------- Waves helpers ----------
func _calc_wave_count() -> int:
	return int(base_wave_count + per_wave_count * max(0, wave_index - 1) + per_tier_bonus * max(0, tier - 1))

func _weights_for_wave() -> Dictionary:
	var tank := clampf(
		tank_weight_start
		+ tank_weight_per_wave * max(0, wave_index - 1)
		+ tank_weight_per_tier * max(0, tier - 1),
		0.0, 100.0
	)
	return {"basic": 100.0 - tank, "tank": tank}

func _pick_type() -> String:
	var w := _weights_for_wave()
	var tank_w := float(w["tank"])
	var t := "basic"
	if (randf() * 100.0) < tank_w:
		t = "tank"
	return t

func _compute_stats(kind: String, wave: int, t: int) -> Dictionary:
	var b: Dictionary = BASE.get(kind, BASE["basic"])
	var base_hp:   int   = int(b.get("hp",   3))
	var base_atk:  int   = int(b.get("atk",  1))
	var base_spd:  float = float(b.get("spd", 1.0))
	var base_mass: float = float(b.get("mass", 1.0))

	var hp   := int(round(base_hp * (1.0 + 0.22 * (wave - 1)) * (1.0 + 0.25 * (t - 1))))
	var atk  := int(base_atk + floor((wave - 1) / 2.0) + (t - 1))
	var spd  := base_spd  * (1.0 + 0.03 * (wave - 1))
	var mass := base_mass * (1.0 + 0.02 * (t - 1))

	return {"type": kind, "health": hp, "attack": atk, "speed": spd, "mass": mass}

# ---------- Lane alignment helpers ----------
func _lane_signature_for_lane(lane: int, lanes: int) -> float:
	if lanes <= 1:
		return 0.0
	return clampf((float(lane) / float(lanes - 1)) * 2.0 - 1.0, -1.0, 1.0)

func _predict_lane_offset_world(sig: float, c: Vector2i, tile_w: float) -> float:
	var lane_spread := spawn_spread_tiles
	var lane_bias := 0.6
	var lane_jitter := 0.06
	var num_lanes := 0

	var max_off := minf(tile_w * 0.45, lane_spread * tile_w)
	var lane := lane_bias * sig * max_off
	lane += _hash2f(c) * (lane_jitter * tile_w)
	lane = _quantize_lane(lane, max_off, num_lanes)
	return lane

func _hash2f(c: Vector2i) -> float:
	var h: int = int(c.x) * 374761393 + int(c.y) * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	var u: float = float(h & 0x7fffffff) / float(0x7fffffff)
	return u * 2.0 - 1.0

func _quantize_lane(x: float, max_off: float, num_lanes: int) -> float:
	if num_lanes >= 2:
		var span := 2.0 * max_off
		var step := span / float(num_lanes - 1)
		var idx := int(round((x + max_off) / step))
		var q := float(idx) * step - max_off
		return clampf(q, -max_off, max_off)
	return x
