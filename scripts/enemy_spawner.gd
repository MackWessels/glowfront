extends Node3D
class_name EnemySpawner

# ---------------- Setup ----------------
@export var tile_board_path: NodePath
@export var enemy_scene: PackedScene                   # basic UFO

# ----- Carrier config (all passed at spawn time) -----
@export var carrier_scene: PackedScene                 # e.g. res://scenes/enemy_carrier.tscn
@export var spawn_carriers: bool = true
@export_range(0.0, 1.0, 0.001) var carrier_chance: float = 0.10

# Defaults pushed into the carrier instance at spawn:
@export var carrier_hover_offset: float = 0.6
@export var carrier_drop_every_tiles: float = 1.5
@export var carrier_minions_per_drop: int = 1
@export var carrier_max_drops: int = 6
@export var carrier_max_per_tile: int = 3
@export var carrier_drop_spread: float = 0.35
@export var carrier_search_radius_tiles: int = 2
@export var carrier_landing_time: float = 0.20

# pacing (slowed down a bit)
@export var auto_start: bool = true
@export var spawn_interval: float = 0.35
@export var burst_count: int = 3
@export var max_alive: int = 250

# placement / jitter
@export var span_override: int = 0
@export var spawn_outward_tiles: float = 1.0
@export var nudge_on_spawn: float = 0.35

# guided first step
@export var use_entry_step: bool = true
@export var entry_step_radius_tiles: float = 0.9

# ---------------- Waves ----------------
@export var wave_index: int = 1
@export var wave_time_sec: float = 12.0           # longer waves
@export var wave_cooldown_sec: float = 3.0
@export var base_wave_count: int = 8              # fewer enemies at start
@export var per_wave_count: int = 1               # gentler increase
@export var wave_frontload_frac: float = 0.15     # fewer front-loaded

# Setup pause before the very first wave
@export var start_setup_delay_sec: float = 3.0

# ---------------- Levels (HP only) ----------------
# Base HP per level (unchanged), but scale per wave more gently
@export var lvl1_base_hp: int = 3
@export var lvl2_base_hp: int = 7
@export var lvl3_base_hp: int = 14
@export var lvl4_base_hp: int = 22
@export var hp_per_wave_pct: float = 0.10         # was 0.22

# (Weights no longer used; kept for inspector compatibility)
@export var lvl1_w_start: float = 70.0
@export var lvl2_w_start: float = 20.0
@export var lvl3_w_start: float = 9.0
@export var lvl4_w_start: float = 1.0
@export var lvl2_w_per_wave: float = 0.6
@export var lvl3_w_per_wave: float = 0.35
@export var lvl4_w_per_wave: float = 0.15

# ---------------- Speed control (ONLY 'speed') ----------------
@export var base_speed: float = 1.6               # was 2.0
@export var speed_per_wave_pct: float = 0.04      # was 0.08
@export var lvl2_speed_mult: float = 1.05
@export var lvl3_speed_mult: float = 1.12
@export var lvl4_speed_mult: float = 1.20
@export var speed_jitter_pct: float = 0.0
@export var clamp_speed_min: float = 0.25
@export var clamp_speed_max: float = 20.0

# ---------------- Debug ----------------
@export var debug_waves: bool = false

# ---------------- State ----------------
var _board: Node = null
var _timer: Timer
var _phase_timer: Timer
var _phase: String = "idle"          # "setup" | "spawning" | "cooldown" | "idle"
var _paused: bool = false
var _alive: int = 0
var _wave_remaining: int = 0

# Per-wave bookkeeping (for stipend & perfect bonus)
var _wave_total_spawned: int = 0
var _wave_resolved: int = 0
var _wave_leaks: int = 0
var _wave_kill_payout: int = 0
var _wave_awarded: bool = false

# =====================================================================
# Lifecycle
# =====================================================================
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

	if auto_start:
		_queue_autostart_when_board_ready()

# Start only after TileBoard signals its first computed path (race-safe)
func _queue_autostart_when_board_ready() -> void:
	if _board != null and _board.has_signal("global_path_changed"):
		_board.connect("global_path_changed", Callable(self, "_on_board_ready_autostart"), Object.CONNECT_ONE_SHOT)
	else:
		call_deferred("_on_board_ready_autostart")

func _on_board_ready_autostart() -> void:
	if _phase == "idle":
		start_spawning()

# =====================================================================
# Public API
# =====================================================================
func start_spawning() -> void:
	_paused = false
	_timer.wait_time = maxf(0.05, spawn_interval)
	if _timer.is_stopped():
		_timer.start()

	# Enter a one-time setup pause before the first wave
	if _phase == "idle":
		_phase = "setup"
		_phase_timer.start(maxf(0.1, start_setup_delay_sec))
		return

	# Normal wave start
	if _phase != "spawning":
		_phase = "spawning"
		_begin_wave()
		_wave_remaining = _calc_wave_total()
		_frontload_wave()
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

# =====================================================================
# Phase timer
# =====================================================================
func _on_phase_timer() -> void:
	if _phase == "setup":
		# After setup pause, begin the first wave
		_phase = "spawning"
		_begin_wave()
		_wave_remaining = _calc_wave_total()
		_frontload_wave()
		_phase_timer.start(maxf(0.1, wave_time_sec))
	elif _phase == "spawning":
		_phase = "cooldown"
		_phase_timer.start(maxf(0.1, wave_cooldown_sec))
	elif _phase == "cooldown":
		wave_index += 1
		_phase = "spawning"
		_begin_wave()
		_wave_remaining = _calc_wave_total()
		_frontload_wave()
		_phase_timer.start(maxf(0.1, wave_time_sec))

# =====================================================================
# Spawning
# =====================================================================
func _on_spawn_tick() -> void:
	if _paused or _board == null:
		return
	if _alive >= max_alive:
		return
	if _phase != "spawning" or _wave_remaining <= 0:
		return

	var cap: int = max_alive - _alive
	var to_spawn: int = min(burst_count, min(_wave_remaining, cap))
	if to_spawn <= 0:
		return

	for _i in range(to_spawn):
		_spawn_one()
		_wave_remaining -= 1

func _frontload_wave() -> void:
	var want: int = int(round(float(_calc_wave_total()) * clampf(wave_frontload_frac, 0.0, 1.0)))
	if want <= 0:
		return
	var cap: int = max(0, max_alive - _alive)
	var n: int = min(want, min(_wave_remaining, cap))
	for _i in range(n):
		_spawn_one()
	_wave_remaining -= n

func _spawn_one() -> void:
	if _board == null or not _board.has_method("get_spawn_pen"):
		return

	var span: int = span_override
	if span <= 0:
		span = _get_board_int("spawner_span", 3)

	var info: Dictionary = _board.get_spawn_pen(span)
	var exits: Array = info.get("entry_targets", [])
	var fwd: Vector3 = info.get("forward", Vector3.FORWARD)
	var lat: Vector3 = info.get("lateral", Vector3.RIGHT)
	if exits.is_empty():
		return

	var tile_w: float = _tile_w()
	var exit_radius: float = float(info.get("exit_radius", 0.35 * tile_w))

	# pick random spot across the opening, then offset outward
	var p_edge: Vector3 = _pick_random_on_span(exits, lat)
	var outward: float = maxf(0.0, spawn_outward_tiles) * tile_w
	var p: Vector3 = p_edge - fwd * outward
	p += lat.normalized() * randf_range(-0.15 * tile_w, 0.15 * tile_w)
	p += fwd * randf_range(-0.10 * tile_w, 0.10 * tile_w)

	# choose scene: carrier vs basic
	var use_carrier: bool = false
	var scene_to_spawn: PackedScene = enemy_scene
	# carriers only start at wave 20+
	if spawn_carriers and carrier_scene != null and wave_index >= 20 and randf() < carrier_chance:
		use_carrier = true
		scene_to_spawn = carrier_scene

	var inst: Node = scene_to_spawn.instantiate()
	if inst == null:
		return

	# ---- wire shared refs BEFORE add_child (runs before _ready) ----
	if _board != null:
		inst.set("tile_board_path", _board.get_path())
		var g: Variant = _board.get("goal_node")
		if typeof(g) == TYPE_OBJECT and g != null and g is Node3D:
			inst.set("goal_node_path", g.get_path())

	# carrier-specific config (all passed here)
	if use_carrier:
		_prime_carrier(inst, p, tile_w)

	add_child(inst)

	# signals
	if inst.has_signal("died"):
		inst.died.connect(_on_enemy_died)

	# level + stats
	var lvl: int = _pick_level_for_wave(wave_index)
	if inst.has_method("set_level"):
		inst.call("set_level", lvl)
	else:
		inst.set("level", lvl)

	var stats: Dictionary = _compute_stats_for_level_and_wave(lvl, wave_index)
	if inst.has_method("apply_stats"):
		inst.call("apply_stats", stats)
	else:
		for k in stats.keys():
			inst.set(k, stats[k])

	var inst3 := inst as Node3D
	if inst3 != null:
		inst3.global_position = p
		if inst3.has_method("lock_y_to"):
			inst3.call("lock_y_to", p.y)
		if use_entry_step and inst3.has_method("set_entry_target"):
			var r := maxf(exit_radius, entry_step_radius_tiles * tile_w)
			inst3.call("set_entry_target", p_edge, r)
		if nudge_on_spawn > 0.0:
			var nudge: float = tile_w * 0.12 * clampf(nudge_on_spawn, 0.0, 1.0)
			inst3.global_position += fwd * nudge
		inst3.look_at(inst3.global_position + fwd, Vector3.UP)

	_alive += 1
	_wave_total_spawned += 1

# =====================================================================
# Carrier helpers
# =====================================================================

func _has_prop(o: Object, name: String) -> bool:
	for p in o.get_property_list():
		if typeof(p) == TYPE_DICTIONARY and p.has("name") and p["name"] == name:
			return true
	return false

func _prime_carrier(inst: Node, spawn_pos: Vector3, tile_w: float) -> void:
	if enemy_scene != null and _has_prop(inst, "minion_scene"):
		inst.set("minion_scene", enemy_scene)

	if inst.has_method("set_spawner"):
		inst.call("set_spawner", self)
	elif _has_prop(inst, "spawner_path"):
		inst.set("spawner_path", get_path())

	if _has_prop(inst, "tile_size"):
		inst.set("tile_size", tile_w)
	if _has_prop(inst, "ground_y"):
		inst.set("ground_y", spawn_pos.y)

	if _has_prop(inst, "hover_offset"):
		inst.set("hover_offset", carrier_hover_offset)
	if _has_prop(inst, "drop_every_tiles"):
		inst.set("drop_every_tiles", carrier_drop_every_tiles)
	if _has_prop(inst, "minions_per_drop"):
		inst.set("minions_per_drop", carrier_minions_per_drop)
	if _has_prop(inst, "max_drops"):
		inst.set("max_drops", carrier_max_drops)
	if _has_prop(inst, "max_per_tile"):
		inst.set("max_per_tile", carrier_max_per_tile)
	if _has_prop(inst, "drop_spread"):
		inst.set("drop_spread", carrier_drop_spread)
	if _has_prop(inst, "search_radius_tiles"):
		inst.set("search_radius_tiles", carrier_search_radius_tiles)
	if _has_prop(inst, "landing_time"):
		inst.set("landing_time", carrier_landing_time)

# =====================================================================
# Carrier/child spawn hook  ← used by CarrierEnemy
# =====================================================================
func request_child_spawn(
		scene: PackedScene,
		xform: Transform3D,
		counts_toward_cap := true,
		tags := []
	) -> Node:
	if scene == null or _board == null:
		return null
	if counts_toward_cap and _alive >= max_alive:
		return null

	var inst: Node = scene.instantiate()
	if inst == null:
		return null

	# Wire refs before _ready
	inst.set("tile_board_path", _board.get_path())
	var g: Variant = _board.get("goal_node")
	if typeof(g) == TYPE_OBJECT and g != null and g is Node3D:
		inst.set("goal_node_path", g.get_path())

	add_child(inst)
	if inst.has_signal("died"):
		inst.died.connect(_on_enemy_died)

	var lvl: int = _pick_level_for_wave(wave_index)
	if inst.has_method("set_level"):
		inst.call("set_level", lvl)
	else:
		inst.set("level", lvl)

	var stats: Dictionary = _compute_stats_for_level_and_wave(lvl, wave_index)
	if inst.has_method("apply_stats"):
		inst.call("apply_stats", stats)
	else:
		for k in stats.keys():
			inst.set(k, stats[k])

	var inst3 := inst as Node3D
	if inst3 != null:
		inst3.global_transform = xform

	if counts_toward_cap:
		_alive += 1

	if tags is Array and not tags.is_empty():
		inst.set_meta("spawn_tags", tags)

	return inst

# =====================================================================
# Callbacks
# =====================================================================
func _on_enemy_died() -> void:
	_alive = max(0, _alive - 1)
	_wave_resolved += 1
	_maybe_award_wave_end()

func notify_leak(enemy: Node = null) -> void:
	var count_this_leak: bool = true
	if enemy != null:
		var tags: Variant = enemy.get_meta("spawn_tags")
		if typeof(tags) == TYPE_ARRAY and "carrier" in tags:
			count_this_leak = false

	if count_this_leak:
		_wave_leaks += 1

	_wave_resolved += 1
	if debug_waves:
		if count_this_leak:
			print("[Wave] leak registered; leaks=", _wave_leaks)
		else:
			print("[Wave] leak ignored (carrier-child).")
	_maybe_award_wave_end()

func notify_kill_payout(amount: int) -> void:
	if amount > 0:
		_wave_kill_payout += amount
		if debug_waves:
			print("[Wave] kill payout +", amount, "  wave_kill_payout=", _wave_kill_payout)

# =====================================================================
# Helpers
# =====================================================================
func _maybe_award_wave_end() -> void:
	if _wave_awarded:
		return
	var spawned_all: bool = (_wave_remaining <= 0 and _phase != "spawning")
	var resolved_all: bool = (_wave_resolved >= _wave_total_spawned)
	if not (spawned_all and resolved_all):
		return

	_wave_awarded = true
	if _wave_leaks == 0 and _wave_kill_payout > 0:
		var bonus: int = 0
		if typeof(PowerUps) != TYPE_NIL and PowerUps.has_method("award_perfect_bonus"):
			bonus = int(PowerUps.award_perfect_bonus(_wave_kill_payout, "perfect_wave"))
		if debug_waves:
			print("[Wave] PERFECT! wave=", wave_index, " base=", _wave_kill_payout, " bonus=", bonus)
	else:
		if debug_waves:
			print("[Wave] resolved (not perfect). wave=", wave_index, " kills_base=", _wave_kill_payout, " leaks=", _wave_leaks)

func _begin_wave() -> void:
	_wave_total_spawned = 0
	_wave_resolved = 0
	_wave_leaks = 0
	_wave_kill_payout = 0
	_wave_awarded = false

	# Stipend at wave start
	if typeof(PowerUps) != TYPE_NIL and PowerUps.has_method("award_wave_stipend"):
		var amt: int = int(PowerUps.award_wave_stipend(wave_index))
		if debug_waves and amt > 0:
			print("[Wave] stipend paid: +", amt, " at start of wave ", wave_index)

func _tile_w() -> float:
	if _board and _board.has_method("tile_world_size"):
		return float(_board.call("tile_world_size"))
	var tv: Variant = 1.0
	if _board:
		tv = _board.get("tile_size")
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

func _pick_random_on_span(exits: Array, lat: Vector3) -> Vector3:
	var lat_n: Vector3 = lat.normalized()
	var origin: Vector3 = exits[0]
	var min_proj: float = INF
	var max_proj: float = -INF
	for i in exits:
		var e: Vector3 = i
		var pr: float = (e - origin).dot(lat_n)
		if pr < min_proj:
			min_proj = pr
		if pr > max_proj:
			max_proj = pr
	var t: float = randf()
	var along: float = lerpf(min_proj, max_proj, t)
	return origin + lat_n * along

# ---------------- Wave helpers ----------------
func _calc_wave_total() -> int:
	return int(base_wave_count + per_wave_count * max(0, wave_index - 1))

# Level unlocks + gentle odds:
# - waves 1–4: only L1
# - waves 5–24: mostly L1, sometimes L2
# - waves 25–34: mostly L1/L2, occasional L3
# - waves 35+: add L4 rarely
func _pick_level_for_wave(wave: int) -> int:
	if wave < 5:
		return 1
	elif wave < 25:
		return (2 if randf() < 0.20 else 1)
	elif wave < 35:
		var r := randf()
		if r < 0.60: return 1
		elif r < 0.85: return 2
		else: return 3
	else:
		var r2 := randf()
		if r2 < 0.50: return 1
		elif r2 < 0.80: return 2
		elif r2 < 0.85: return 4
		else: return 3

func _compute_stats_for_level_and_wave(level: int, wave: int) -> Dictionary:
	# --- HP ---
	var base_hp: int = lvl1_base_hp
	if level == 2: base_hp = lvl2_base_hp
	elif level == 3: base_hp = lvl3_base_hp
	elif level == 4: base_hp = lvl4_base_hp
	var hp_scale: float = 1.0 + hp_per_wave_pct * float(max(0, wave - 1))
	var hp: int = int(round(float(base_hp) * hp_scale))

	# --- Speed (only) ---
	var level_mult: float = 1.0
	if level == 2: level_mult = lvl2_speed_mult
	elif level == 3: level_mult = lvl3_speed_mult
	elif level == 4: level_mult = lvl4_speed_mult

	var wave_mult: float = 1.0 + speed_per_wave_pct * float(max(0, wave - 1))
	var jitter: float = 1.0
	if speed_jitter_pct > 0.0:
		jitter = 1.0 + randf_range(-speed_jitter_pct, speed_jitter_pct)

	var final_speed: float = base_speed * level_mult * wave_mult * jitter
	if final_speed < clamp_speed_min: final_speed = clamp_speed_min
	if final_speed > clamp_speed_max: final_speed = clamp_speed_max

	return {
		"health": hp,
		"attack": 1,
		"mass": 1.0,
		"speed": final_speed
	}
