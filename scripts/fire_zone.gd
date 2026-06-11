class_name FireZone
extends Node2D
## Burning ground. Spawned on every peer via world broadcast; each peer
## renders and self-despawns after the (shared) duration. ONLY the host ticks
## damage — i-frames apply per tick via host_damage_player.

const TICK_INTERVAL: float = 0.5
const TICK_DAMAGE: int = 8

var radius: float = 80.0
var duration: float = 4.0

var _elapsed: float = 0.0
var _tick_left: float = TICK_INTERVAL
var _light: PointLight2D

@onready var _world: GameWorld = get_tree().get_first_node_in_group(&"game_world") as GameWorld


func setup(center: Vector2, fire_radius: float, fire_duration: float) -> void:
	position = center
	radius = fire_radius
	duration = fire_duration


func _ready() -> void:
	_light = PointLight2D.new()
	_light.texture = Game.glow_texture()
	_light.texture_scale = (radius * 1.3) / float(Game.GLOW_RADIUS_PX)
	_light.color = Color(1.0, 0.55, 0.15)
	_light.energy = 0.9
	_light.shadow_enabled = true
	_light.shadow_filter = 1
	add_child(_light)


func _physics_process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= duration:
		queue_free()
		return
	# Flicker (deterministic, looks the same everywhere).
	_light.energy = 0.8 + 0.25 * sin(_elapsed * 17.0) * sin(_elapsed * 7.3)
	queue_redraw()
	if not multiplayer.is_server():
		return
	_tick_left -= delta
	if _tick_left > 0.0:
		return
	_tick_left = TICK_INTERVAL
	for pawn: Player in _world.alive_pawns():
		if pawn.global_position.distance_to(global_position) <= radius + 10.0:
			_world.host_damage_player(str(pawn.name).to_int(), TICK_DAMAGE)


func _draw() -> void:
	var fade: float = clampf((duration - _elapsed) / 0.6, 0.0, 1.0)
	var pulse: float = 0.22 + 0.06 * sin(_elapsed * 9.0)
	draw_circle(Vector2.ZERO, radius, Color(1.0, 0.42, 0.1, pulse * fade))
	draw_arc(Vector2.ZERO, radius - 2.0, 0.0, TAU, 40, Color(1.0, 0.6, 0.2, 0.7 * fade), 2.5)