extends CanvasLayer

@export var value_label_path: NodePath = NodePath("HBoxContainer/ValueLabel")
@export var economy_path: NodePath                 # optional override if not using autoload
@export var prefix_text: String = "Minerals: "
@export var econ_debug: bool = false

var _label: Label
var _econ: Node = null
var _tween: Tween

func _ready() -> void:
	_label = get_node_or_null(value_label_path)
	if _label == null:
		push_error("[MineralsHUD] ValueLabel not found. Set value_label_path.")
		return

	_resolve_economy()
	_bind_signals()
	_refresh_text(_get_balance())

func _retry_resolve_economy() -> void:
	# If the economy wasn't ready at _ready(), try once shortly after.
	await get_tree().create_timer(0.1).timeout
	_resolve_economy()
	_bind_signals()
	_refresh_text(_get_balance())

func _resolve_economy() -> void:
	# 1) explicit path (if provided)
	if economy_path != NodePath(""):
		_econ = get_node_or_null(economy_path)

	# 2) preferred autoload
	if _econ == null:
		_econ = get_node_or_null("/root/Economy")
	# 3) Minerals autoload or scene node
	if _econ == null:
		_econ = get_node_or_null("/root/Minerals")
	if _econ == null:
		var root := get_tree().root
		if root:
			_econ = root.find_child("Minerals", true, false)

	if econ_debug:
		if _econ:
			print("[MineralsHUD] Economy resolved -> ", _econ.name)
		else:
			print("[MineralsHUD] Economy NOT found; will retry once…")

	if _econ == null:
		_retry_resolve_economy()

func _bind_signals() -> void:
	if _econ == null:
		return
	# Connect once
	if _econ.has_signal("balance_changed") and not _econ.is_connected("balance_changed", Callable(self, "_on_balance_changed")):
		_econ.connect("balance_changed", Callable(self, "_on_balance_changed"))
	if _econ.has_signal("added") and not _econ.is_connected("added", Callable(self, "_on_added")):
		_econ.connect("added", Callable(self, "_on_added"))
	if _econ.has_signal("spent") and not _econ.is_connected("spent", Callable(self, "_on_spent")):
		_econ.connect("spent", Callable(self, "_on_spent"))

func _get_balance() -> int:
	if _econ == null:
		return 0
	# Economy API first
	if _econ.has_method("balance"):
		return int(_econ.call("balance"))
	# Fallback to a 'minerals' property
	var v: Variant = _econ.get("minerals")
	return int(v) if typeof(v) == TYPE_INT else 0

func _refresh_text(bal: int) -> void:
	if _label:
		_label.text = "%s%d" % [prefix_text, bal]

func _on_balance_changed(new_balance: int) -> void:
	_refresh_text(new_balance)

func _pulse(scale_to: float, duration: float = 0.15) -> void:
	if _label == null:
		return
	if _tween and _tween.is_valid():
		_tween.kill()

	_tween = create_tween()
	_tween.tween_property(_label, "scale", Vector2(scale_to, scale_to), duration)
	_tween.tween_property(_label, "scale", Vector2.ONE, duration)

func _on_added(amount: int, _source: String) -> void:
	_pulse(1.15)

func _on_spent(amount: int, _reason: String) -> void:
	_pulse(0.92)
