extends Node3D
class_name ShardMiner

@export var building_id: String = "shard_miner"
@export var minerals_cost: int = 35
@export var footprint: Vector2i = Vector2i(2, 2)
@export var shards_per_minute: float = 6.0
@export var start_delay_sec: float = 2.0
@export var enabled_on_ready: bool = true
@export var popup_scene: PackedScene

@onready var _building_mesh: MeshInstance3D   = $"shard_building/Building"
@onready var _dome_mesh: MeshInstance3D       = $"shard_building/Dome"
@onready var _roof_tile_mesh: MeshInstance3D  = $"shard_building/RoofTile"
@onready var _smokestack_mesh: MeshInstance3D = $"shard_building/SmokeStack"
@onready var _smoke_point: Node3D             = $"SmokePoint"

const FLASH_SECS: float = 0.15
const FLASH_BOOST: float = 1.7

var _active: bool = false
var _accum: float = 0.0
var _start_delay_left: float = 0.0
var _glow_mesh: MeshInstance3D
var _flash_left: float = 0.0
var _idle_glow_time: float = 0.0

var _board: Node
var _anchor_cell: Vector2i = Vector2i.ZERO

func set_tile_context(board: Node, anchor_cell: Vector2i) -> void:
	_board = board
	_anchor_cell = anchor_cell
	if _board:
		if _board.has_method("on_tiles_blocked_changed"):
			_board.call("on_tiles_blocked_changed", _anchor_cell, Vector2i(2, 2), true)
		else:
			for m in ["recompute_flow","recompute_paths","rebuild_flow_field","recompute_board_dirs","recompute"]:
				if _board.has_method(m):
					_board.call(m); break

func _ready() -> void:
	add_to_group("shard_generators", true)
	_start_delay_left = max(0.0, start_delay_sec)
	_style_building()
	_glow_mesh = _dome_mesh
	set_active(enabled_on_ready)

func set_active(on: bool) -> void:
	_active = on
	set_process(on or _flash_left > 0.0 or _glow_mesh != null)

func is_active() -> bool:
	return _active

func _process(delta: float) -> void:
	_update_flash(delta)
	_update_idle_glow(delta)
	if get_tree().paused or not _active: return
	if _start_delay_left > 0.0:
		_start_delay_left -= delta
		return
	var rate_per_sec: float = max(0.0, shards_per_minute) / 60.0
	_accum += rate_per_sec * delta
	if _accum >= 1.0:
		var whole: int = int(floor(_accum))
		_accum -= float(whole)
		_pay_out(whole)

func _pay_out(amount: int) -> void:
	if amount <= 0: return
	if typeof(Shards) == TYPE_NIL: return
	Shards.add(amount, "generator")
	_flash()
	_spawn_popup(amount)

func _spawn_popup(amount: int) -> void:
	if popup_scene == null: return
	var n: Node = popup_scene.instantiate()
	if n == null: return
	if n.has_method("set_text"): n.call("set_text", "+" + str(amount))
	elif "text" in n: n.set("text", "+" + str(amount))
	if n is Node3D: (n as Node3D).global_position = global_position + Vector3(0, 1.4, 0)
	get_tree().current_scene.add_child(n)

func _flash() -> void:
	_flash_left = FLASH_SECS
	set_process(true)

func _update_flash(delta: float) -> void:
	if _flash_left <= 0.0: return
	_flash_left -= delta
	if _glow_mesh and _glow_mesh.mesh:
		var mat: Material = _get_any_material(_glow_mesh)
		if mat is StandardMaterial3D:
			var m: StandardMaterial3D = mat as StandardMaterial3D
			var t: float = clamp(_flash_left / max(0.001, FLASH_SECS), 0.0, 1.0)
			m.emission_enabled = true
			m.emission_energy = 1.0 + t * FLASH_BOOST
	if _flash_left <= 0.0 and not _active: set_process(false)

func _update_idle_glow(delta: float) -> void:
	if _glow_mesh == null: return
	var mat: Material = _get_any_material(_glow_mesh)
	if not (mat is StandardMaterial3D): return
	var m: StandardMaterial3D = mat as StandardMaterial3D
	_idle_glow_time += delta
	var wave: float = sin(_idle_glow_time * TAU * 0.6) * 0.5 + 0.5
	if _flash_left <= 0.0:
		m.emission_enabled = true
		m.emission_energy = 0.9 + 0.25 * wave

func _style_building() -> void:
	if _building_mesh:
		var base: StandardMaterial3D = StandardMaterial3D.new()
		base.albedo_color = Color(0.68, 0.69, 0.74)
		base.metallic = 0.25
		base.roughness = 0.75
		_apply_to_all_surfaces(_building_mesh, base)

	if _dome_mesh:
		var dome: StandardMaterial3D = StandardMaterial3D.new()
		dome.albedo_color = Color(0.92, 0.93, 1.0)
		dome.metallic = 0.45
		dome.roughness = 0.35
		dome.emission_enabled = true
		dome.emission = Color(0.55, 0.75, 1.0)
		dome.emission_energy = 0.9
		_apply_to_all_surfaces(_dome_mesh, dome)

	if _roof_tile_mesh:
		var roof_mat: ShaderMaterial = _make_roof_tile_shader(
			Color(0.78, 0.80, 0.86),
			Color(0.92, 0.95, 1.00),
			0.14, 0.03, 0.45
		)
		_apply_to_all_surfaces(_roof_tile_mesh, roof_mat)

	if _smokestack_mesh:
		var steel: StandardMaterial3D = StandardMaterial3D.new()
		steel.albedo_color = Color(0.72, 0.74, 0.78)
		steel.metallic = 0.25
		steel.roughness = 0.75
		steel.emission_enabled = true
		steel.emission = Color(0.72, 0.74, 0.78)
		steel.emission_energy = 0.08
		_apply_to_all_surfaces(_smokestack_mesh, steel)

	_install_smoke()

func _install_smoke() -> void:
	if _smoke_point == null: return
	for c in _smoke_point.get_children():
		if c is GPUParticles3D: return
	var particles: GPUParticles3D = GPUParticles3D.new()
	particles.amount = 80
	particles.lifetime = 2.2
	particles.one_shot = false
	particles.emitting = true
	particles.local_coords = true
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2(0.6, 0.6)
	particles.draw_pass_1 = quad
	var pm: ParticleProcessMaterial = ParticleProcessMaterial.new()
	pm.gravity = Vector3(0, 0.45, 0)
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 12.0
	pm.initial_velocity_min = 0.6
	pm.initial_velocity_max = 1.2
	pm.angular_velocity_min = -0.5
	pm.angular_velocity_max = 0.5
	pm.damping = Vector2(0.05, 0.05)
	pm.color = Color(0.8, 0.8, 0.8, 0.6)
	particles.process_material = pm
	_smoke_point.add_child(particles)

func _make_roof_tile_shader(base: Color, inner: Color, border: float, corner: float, inset: float) -> ShaderMaterial:
	var sh: Shader = Shader.new()
	sh.code = """
shader_type spatial;
varying vec3 LOCAL_POS;
void vertex(){ LOCAL_POS = VERTEX; }

uniform vec3 base_color   = vec3(0.78,0.80,0.86);
uniform vec3 inner_color  = vec3(0.92,0.95,1.00);
uniform float border      = 0.14;
uniform float corner      = 0.03;
uniform float inset_amt   = 0.45;
uniform float edge_glow   = 0.05;
uniform float rough_center= 0.42;
uniform float rough_edge  = 0.82;
uniform float metallic_v  = 0.22;

void fragment(){
	vec2 uv = UV;
	if (uv == vec2(0.0)) { uv = fract(LOCAL_POS.xz * 0.1) * 0.98 + 0.01; }
	float d = min(min(uv.x,1.0-uv.x), min(uv.y,1.0-uv.y));
	float rim = smoothstep(border+corner, border, d);
	vec3 col = mix(inner_color, base_color, rim);
	vec3 n = normalize(NORMAL);
	n = normalize(mix(n, vec3(0.0,-1.0,0.0), (1.0 - rim) * inset_amt));
	NORMAL = n;
	ALBEDO = col;
	METALLIC = metallic_v;
	ROUGHNESS = mix(rough_center, rough_edge, rim);
	float seam = smoothstep(border, border - 0.01, d);
	EMISSION = vec3(edge_glow) * seam;
}
"""
	var m: ShaderMaterial = ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("base_color", base)
	m.set_shader_parameter("inner_color", inner)
	m.set_shader_parameter("border", border)
	m.set_shader_parameter("corner", corner)
	m.set_shader_parameter("inset_amt", inset)
	return m

func _apply_to_all_surfaces(mi: MeshInstance3D, mat: Material) -> void:
	if mi == null or mi.mesh == null: return
	var sc: int = mi.mesh.get_surface_count()
	for i in range(sc):
		mi.set_surface_override_material(i, mat)

func _get_any_material(mi: MeshInstance3D) -> Material:
	if mi == null or mi.mesh == null: return null
	var mat: Material = mi.get_surface_override_material(0)
	if mat == null and mi.mesh.get_surface_count() > 0:
		mat = mi.mesh.surface_get_material(0)
	return mat

func get_build_id() -> String: return building_id
func get_cost_minerals() -> int: return minerals_cost
func get_footprint_size() -> Vector2i: return footprint

func get_occupied_cells(anchor_cell: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for dz in range(footprint.y):
		for dx in range(footprint.x):
			cells.append(anchor_cell + Vector2i(dx, dz))
	return cells

func on_placed() -> void: pass
func set_rate_per_minute(new_rate: float) -> void: shards_per_minute = max(0.0, new_rate)
func add_rate_bonus(delta_rate: float) -> void: shards_per_minute = max(0.0, shards_per_minute + delta_rate)
