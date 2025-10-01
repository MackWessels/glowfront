extends Node3D

# ===================== Build / economy =====================
@export var build_cost: int = 20
@export var minerals_path: NodePath
@export var sell_refund_percent: int = 60

# ========================= Income ==========================
@export var minerals_per_tick: int = 1
@export var tick_interval: float = 2.0
@export var initial_delay: float = 0.0

# ======================= Optional nodes ====================
@export var click_body_path: NodePath
@export var tile_board_path: NodePath

# ===================== RING WAVE SETTINGS ===================
@export var ring_parent_path: NodePath = ^"mineral_building/Core"
@export var ring_name_prefix: String = "Ring"
@export var ring_emission_color: Color = Color(0.22, 0.75, 1.0)
@export var ring_base_energy: float = 0.05
@export var ring_peak_energy: float = 1.2
@export var wave_speed_rps: float = 2.0
@export var wave_window: int = 1
@export var wave_ping_pong: bool = true
@export var flash_hz: float = 2.0
@export var flash_duty: float = 0.6

# ===================== MATERIAL COLORS ======================
@export var building_mesh_path: NodePath = ^"mineral_building/building"
@export var core_node_path: NodePath     = ^"mineral_building/Core"

# building: mid gray, matte (not bright, not dark)
@export var building_albedo: Color = Color8(160, 170, 180)
@export var building_metallic: float = 0.10
@export var building_roughness: float = 0.60

# core/rings: metal-ish so glow pops
@export var core_albedo: Color = Color8(180, 185, 190)
@export var core_metallic: float = 0.85
@export var core_roughness: float = 0.25

# ========================== Runtime ========================
var _minerals: Node = null
var _running: bool = false
var _generated_total: int = 0
var _spent_local: int = 0
var _tile_board: Node = null
var _tile_cell: Vector2i = Vector2i(-9999, -9999)

var _rings: Array[MeshInstance3D] = []
var _ring_mats: Array[StandardMaterial3D] = []
var _wave_pos: float = 0.0
var _wave_dir: int = 1
var _flash_phase: float = 0.0

signal build_paid(cost: int)
signal build_denied(cost: int)

# ========================== Lifecycle ==========================
func _ready() -> void:
	add_to_group("building")
	add_to_group("generator")
	_resolve_minerals()
	if tile_board_path != NodePath(""):
		_tile_board = get_node_or_null(tile_board_path)

	var click_body: StaticBody3D = null
	if click_body_path != NodePath(""):
		click_body = get_node_or_null(click_body_path) as StaticBody3D
	else:
		click_body = find_child("StaticBody3D", true, false) as StaticBody3D
	if click_body and not click_body.is_connected("input_event", Callable(self, "_on_clickbody_input")):
		click_body.input_event.connect(_on_clickbody_input)

	_apply_materials()
	_setup_rings()

	if not _attempt_build_payment():
		build_denied.emit(build_cost)
		queue_free()
		return
	_spent_local += build_cost
	build_paid.emit(build_cost)
	_start_loop()

func _process(dt: float) -> void:
	_update_ring_wave(dt)

func _exit_tree() -> void:
	_running = false

# ========================= Generator ===========================
func _start_loop() -> void:
	if _running: return
	_running = true
	await get_tree().process_frame
	if initial_delay > 0.0:
		await get_tree().create_timer(maxf(0.0, initial_delay)).timeout
	while _running:
		_do_pulse()
		await get_tree().create_timer(maxf(0.05, tick_interval)).timeout

func _do_pulse() -> void:
	var amt: int = max(0, minerals_per_tick)
	if amt <= 0:
		return
	Economy.add(amt, "miner_tick")
	_generated_total += amt

# ====================== Economy helpers ========================
func _resolve_minerals() -> void:
	if minerals_path != NodePath(""):
		_minerals = get_node_or_null(minerals_path)
	if _minerals == null:
		_minerals = get_node_or_null("/root/Minerals")

func _attempt_build_payment() -> bool:
	if build_cost <= 0:
		return true
	if _minerals and _minerals.has_method("spend"):
		return bool(_minerals.call("spend", build_cost))
	return true

# ======================= Sell / Free tile ======================
func _on_clickbody_input(_camera: Node, event: InputEvent, _pos: Vector3, _norm: Vector3, _shape: int) -> void:
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
		queue_free()

# ===================== MATERIAL HELPERS ========================
func _apply_materials() -> void:
	var body: MeshInstance3D = get_node_or_null(building_mesh_path) as MeshInstance3D
	if body:
		_set_mat(body, building_albedo, building_metallic, building_roughness)

	var core: Node = get_node_or_null(core_node_path)
	if core:
		for c in core.get_children():
			if c is MeshInstance3D:
				_set_mat(c as MeshInstance3D, core_albedo, core_metallic, core_roughness)

func _set_mat(mi: MeshInstance3D, col: Color, metal: float, rough: float) -> void:
	if mi == null:
		return
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = col
	mat.metallic = metal
	mat.roughness = rough
	mat.emission_enabled = false
	var count: int = mi.mesh.get_surface_count() if mi.mesh else 0
	for i in count:
		mi.set_surface_override_material(i, mat.duplicate())

# ===================== RING HELPERS ============================
func _setup_rings() -> void:
	_rings.clear()
	_ring_mats.clear()
	var parent: Node = get_node_or_null(ring_parent_path)
	if parent == null:
		return
	for child in parent.get_children():
		if child is MeshInstance3D and String(child.name).begins_with(ring_name_prefix):
			var mi: MeshInstance3D = child as MeshInstance3D
			var mat: StandardMaterial3D = StandardMaterial3D.new()
			mat.albedo_color = core_albedo
			mat.metallic = core_metallic
			mat.roughness = core_roughness
			mat.emission_enabled = true
			mat.emission = ring_emission_color
			mat.emission_energy = ring_base_energy
			mi.set_surface_override_material(0, mat)
			_rings.append(mi)
			_ring_mats.append(mat)
	# left → right
	_rings.sort_custom(func(a, b): return a.global_transform.origin.x < b.global_transform.origin.x)

# ====== Simple side-to-side blinking wave (no gradients) =======
func _update_ring_wave(dt: float) -> void:
	if _rings.is_empty():
		return
	var n: int = _rings.size()

	# Move wave head
	_wave_pos += dt * wave_speed_rps * float(_wave_dir)
	if wave_ping_pong:
		if _wave_pos >= float(n - 1):
			_wave_pos = float(n - 1)
			_wave_dir = -1
		elif _wave_pos <= 0.0:
			_wave_pos = 0.0
			_wave_dir = 1
	else:
		_wave_pos = fposmod(_wave_pos, float(n))

	# Blink square wave
	_flash_phase = fposmod(_flash_phase + dt * flash_hz, 1.0)
	var is_on: bool = (_flash_phase < clampf(flash_duty, 0.0, 1.0))

	var center_idx: int = int(round(_wave_pos))
	var half_w: int = max(0, (wave_window - 1) / 2)

	for i in n:
		var lit: bool = (abs(i - center_idx) <= half_w)
		var energy: float = ring_peak_energy if (lit and is_on) else ring_base_energy  # <-- fixed ternary
		_ring_mats[i].emission_energy = energy
