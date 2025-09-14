# sniper_tower.gd
# Make sure this path matches your project
extends "res://scripts/tower.gd"
class_name SniperTower

func _ready() -> void:
	# --- Sniper balance knobs (APPLY BEFORE super._ready) ---
	# End-of-pipeline multipliers (already exist in tower.gd)
	rate_mult_end   = 1.80   # slower fire
	range_mult_end  = 2.00   # much longer reach
	damage_mult_end = 1.20   # small damage bump

	# Build/economy (already exist in tower.gd)
	build_cost = 16

	# Beam clamp helper from base (already exists in tower.gd)
	max_range = 120.0

	# Visual feel (already exist in tower.gd)
	laser_width      = 0.08
	laser_duration   = 0.09
	range_ring_color = Color(0.2, 0.8, 1.0, 0.30)

	# Run the normal turret setup (payment, signals, recompute, etc.)
	super._ready()

	# Cosmetic: if stats dialog is already created, rename it
	if _stats_window != null:
		_stats_window.title = "Sniper Tower"

# (Optional) If you want the dialog title to always be "Sniper Tower"
# even when opened later, you can override the creator lightly:
func _ensure_stats_dialog() -> AcceptDialog:
	var dlg := super._ensure_stats_dialog()
	dlg.title = "Sniper Tower"
	return dlg
