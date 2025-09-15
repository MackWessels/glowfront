# res://scripts/sniper_tower.gd
extends "res://scripts/tower.gd"
class_name SniperTower

func _ready() -> void:
	# ---- Wire required nodes (do this BEFORE super._ready) ----
	DetectionArea = get_node_or_null("DetectionArea") as Area3D
	ClickBody     = get_node_or_null("StaticBody3D") as StaticBody3D

	# Aim pivot: prefer TurretPivot; fall back to Turret; then recursive search
	var pivot: Node3D = get_node_or_null("sniper_tower_model/TurretPivot") as Node3D
	if pivot == null:
		pivot = get_node_or_null("sniper_tower_model/Turret") as Node3D
	if pivot == null:
		pivot = find_child("TurretPivot", true, false) as Node3D
	if pivot == null:
		pivot = find_child("Turret", true, false) as Node3D
	Turret = pivot

	# Muzzle point at the barrel tip (try pivoted and non-pivoted paths, then fallback search)
	var mp: Node3D = get_node_or_null("sniper_tower_model/TurretPivot/TurretModel/Barrel/MuzzlePoint") as Node3D
	if mp == null:
		mp = get_node_or_null("sniper_tower_model/Turret/Barrel/MuzzlePoint") as Node3D
	if mp == null:
		mp = find_child("MuzzlePoint", true, false) as Node3D
	if mp != null:
		MuzzlePoint = mp

	# ---- Sniper tuning ----
	rate_mult_end   = 1.80      # slower fire
	range_mult_end  = 2.00      # longer acquire
	damage_mult_end = 1.20
	build_cost      = 16
	max_range       = 120.0

	# visuals
	laser_width      = 0.08
	laser_duration   = 0.09
	range_ring_color = Color(0.2, 0.8, 1.0, 0.30)

	# Allow pitch for sniper only (base turret defaults to yaw_only = true)
	yaw_only = false

	# ---- Run base setup ----
	super._ready()

	# Some scenes might have reassigned Turret in super._ready(); ensure our pivot wins
	if Turret == null:
		Turret = pivot

	# cosmetics
	if _stats_window != null:
		_stats_window.title = "Sniper Tower"


func _ensure_stats_dialog() -> AcceptDialog:
	var dlg := super._ensure_stats_dialog()
	dlg.title = "Sniper Tower"
	return dlg
