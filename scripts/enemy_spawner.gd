extends Node3D

@export var enemy_scene: PackedScene
@export var tile_board_path: NodePath = ^".."
@export var spawn_every: float = 1.5

@export var projectile_scene: PackedScene
@export var turret_path: NodePath = ^"mortar_tower_model/Turret"
@export var barrel_path: NodePath = ^"mortar_tower_model/Turret/Barrel"
@export var muzzle_path: NodePath = ^"mortar_tower_model/Turret/Barrel/MuzzlePoint"

var _board: Node = null
var _timer: Timer = null
var _turret: Node3D = null
var _barrel: Node3D = null
var _muzzle: Node3D = null
var _recoil_tw: Tween = null

func _ready() -> void:
	_board = get_node(tile_board_path)
	_timer = $Timer
	_timer.wait_time = spawn_every
	_timer.timeout.connect(_spawn)
	_timer.start()
	_cache_rig()

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

func _spawn() -> void:
	if enemy_scene == null:
		return
	var e: CharacterBody3D = enemy_scene.instantiate()
	e.tile_board_path = _board.get_path()
	add_child(e)

	var spawn_pos: Vector3 = _board.spawner_node.global_position
	if _board.spawner_node.has_node("SpawnPoint"):
		spawn_pos = _board.spawner_node.get_node("SpawnPoint").global_position
	e.set_deferred("global_position", spawn_pos)


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
