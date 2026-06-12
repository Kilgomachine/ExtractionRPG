class_name Grenade
extends Node2D
## Thrown grenade visual: flies to the target point, then sits for a short
## fuse. Deterministic on every peer (same args). The HOST resolves the
## effect when its copy's fuse ends and broadcasts the result (explosion
## damage / smoke spawn / flash) — this node itself is cosmetic + timing.

const FLIGHT_TIME: float = 0.45
const FUSE_TIME: float = 0.6
const TYPE_COLORS: Array[Color] = [
	Color(0.9, 0.35, 0.2),   # frag
	Color(0.7, 0.75, 0.85),  # smoke
	Color(1.0, 0.95, 0.5),   # flash
]

var grenade_id: int = 0
var grenade_type: int = 0
var thrower_id: int = 0

var _from := Vector2.ZERO
var _to := Vector2.ZERO
var _elapsed: float = 0.0
var _resolved: bool = false

@onready var _world: GameWorld = get_tree().get_first_node_in_group(&"game_world") as GameWorld


func setup(id: int, type: int, thrower: int, from: Vector2, to: Vector2) -> void:
	grenade_id = id
	grenade_type = type % TYPE_COLORS.size()
	thrower_id = thrower
	_from = from
	_to = to
	position = from


func _physics_process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < FLIGHT_TIME:
		var t: float = _elapsed / FLIGHT_TIME
		position = _from.lerp(_to, t)
		# Cheap arc: scale up then down mid-flight.
		var arc: float = 1.0 + 0.8 * sin(PI * t)
		scale = Vector2(arc, arc)
		queue_redraw()
		return
	position = _to
	scale = Vector2.ONE
	queue_redraw()
	if _elapsed >= FLIGHT_TIME + FUSE_TIME and not _resolved:
		_resolved = true
		if multiplayer.is_server():
			_world.host_resolve_grenade(grenade_id, grenade_type, thrower_id, _to)
		queue_free()


func _draw() -> void:
	draw_circle(Vector2.ZERO, 6.0, TYPE_COLORS[grenade_type])
	if _elapsed > FLIGHT_TIME:
		# Fuse blink.
		var blink: float = absf(sin(_elapsed * 22.0))
		draw_arc(Vector2.ZERO, 9.0, 0.0, TAU, 16, Color(1, 0.3, 0.2, blink), 1.5)