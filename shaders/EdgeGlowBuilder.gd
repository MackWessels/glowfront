@tool
extends MeshInstance3D
class_name EdgeGlowBuilder

# ------------ Geometry / visibility ------------
@export var line_width: float = 0.06          # thicker by default
@export var push_out: float = 0.008           # pushed farther to avoid z-fighting
@export var angle_threshold_deg: float = 20   # include edges sharper than this

# Shader material used on the generated strips
@export var glow_material: Material

# Build automatically when the scene runs
@export var build_at_runtime: bool = true

# Editor button: flick ON to rebuild (auto-resets)
@export var build_lines: bool = false:
	set(value):
		build_lines = false
		if Engine.is_editor_hint():
			_build_edge_lines()

# ------------ Brightness controls (auto-applied) ------------
@export var outline_color: Color = Color.WHITE
@export var outline_glow: float = 4.0
@export var outline_albedo_boost: float = 0.35
@export var override_material_params: bool = true  # set to false if you want to keep the .tres as-is

const CHILD_NAME := "EdgeLines"  # child renderer

# Public helper (you can call this after instancing from tile code if you want)
func rebuild_now() -> void:
	_build_edge_lines()

func _ready() -> void:
	if !Engine.is_editor_hint() and build_at_runtime:
		_build_edge_lines()

# -------------------------------------------------------------
#                        CORE BUILDER
# -------------------------------------------------------------
func _build_edge_lines() -> void:
	if mesh == null:
		push_warning("EdgeGlowBuilder: no mesh on this MeshInstance3D.")
		return

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var total_edges := 0
	var total_quads := 0

	for s: int in range(mesh.get_surface_count()):
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue

		var mdt := MeshDataTool.new()
		if mdt.create_from_surface(mesh, s) != OK:
			continue

		# key -> {"n": Array[Vector3], "a": int, "b": int}
		var edges: Dictionary = {}

		for f: int in range(mdt.get_face_count()):
			var n: Vector3 = mdt.get_face_normal(f).normalized()
			var a: int = mdt.get_face_vertex(f, 0)
			var b: int = mdt.get_face_vertex(f, 1)
			var c: int = mdt.get_face_vertex(f, 2)
			_add_edge(edges, a, b, n)
			_add_edge(edges, b, c, n)
			_add_edge(edges, c, a, n)

		for key in edges.keys():
			var info: Dictionary = edges[key]
			var normals: Array = info["n"] as Array
			var a_i: int = int(info["a"])
			var b_i: int = int(info["b"])

			var include := false
			var n_avg: Vector3

			if normals.size() == 1:
				include = true
				n_avg = (normals[0] as Vector3).normalized()
			else:
				var n0: Vector3 = (normals[0] as Vector3).normalized()
				var n1: Vector3 = (normals[1] as Vector3).normalized()
				var ang: float = rad_to_deg(acos(clamp(n0.dot(n1), -1.0, 1.0)))
				if ang >= angle_threshold_deg:
					include = true
				n_avg = (n0 + n1).normalized()

			if not include:
				continue

			var p0: Vector3 = mdt.get_vertex(a_i)
			var p1: Vector3 = mdt.get_vertex(b_i)

			var dir: Vector3 = (p1 - p0).normalized()
			var side: Vector3 = dir.cross(n_avg).normalized()
			var w: float = max(0.0001, line_width * 0.5)
			var off: Vector3 = n_avg * push_out

			var A := p0 + side * w + off
			var B := p1 + side * w + off
			var C := p1 - side * w + off
			var D := p0 - side * w + off
			var N := n_avg

			# Godot 4 API: set_normal() then add_vertex()
			st.set_normal(N); st.add_vertex(A)
			st.set_normal(N); st.add_vertex(B)
			st.set_normal(N); st.add_vertex(C)
			st.set_normal(N); st.add_vertex(C)
			st.set_normal(N); st.add_vertex(D)
			st.set_normal(N); st.add_vertex(A)

			total_edges += 1
			total_quads += 1

		mdt.clear()

	var out_mesh := ArrayMesh.new()
	st.commit(out_mesh)

	var child := get_node_or_null(CHILD_NAME) as MeshInstance3D
	if child == null:
		child = MeshInstance3D.new()
		child.name = CHILD_NAME
		add_child(child)

	child.mesh = out_mesh
	child.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_assign_and_tune_material(child)

	print("[EdgeGlow] built  strips=", total_edges, "  quads=", total_quads,
		"  width=", line_width, "  threshold=", angle_threshold_deg)

# Make a local material, assign it, and apply bright params
func _assign_and_tune_material(mi: MeshInstance3D) -> void:
	var mat: Material = glow_material
	if mat == null:
		mi.material_override = null
		return

	# Duplicate so each turret can have its own color/brightness
	if !mat.resource_local_to_scene:
		mat = mat.duplicate()
		mat.resource_local_to_scene = true

	mi.material_override = mat

	if override_material_params and mi.material_override is ShaderMaterial:
		var sm := mi.material_override as ShaderMaterial
		if sm.shader != null:
			# These parameter names match the provided shader
			sm.set_shader_parameter("color", outline_color)
			sm.set_shader_parameter("glow", outline_glow)
			sm.set_shader_parameter("albedo_boost", outline_albedo_boost)

# Record up to two face normals per undirected edge
func _add_edge(edges: Dictionary, a_i: int, b_i: int, n: Vector3) -> void:
	var k := Vector2i(min(a_i, b_i), max(a_i, b_i))
	if not edges.has(k):
		edges[k] = {"n": [n], "a": a_i, "b": b_i}
	else:
		var arr: Array = edges[k]["n"] as Array
		if arr.size() < 2:
			arr.append(n)
		edges[k]["n"] = arr
