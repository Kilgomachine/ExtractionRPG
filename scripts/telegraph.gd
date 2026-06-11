class_name Telegraph
extends Node2D
## Red ground marker for a telegraphed attack: outline shows the full danger
## zone immediately, the fill + a red light grow over the windup, then a brief
## impact flash. Purely visual and local — damage is resolved on the host.

var _radius: float = 90.0
var _duration: float = 1.0
var _elapsed: float = 0.0
var _light: PointLight2D


func setup(center: Vector2, radius: float, duration: float) -> void:
	position = center
	_radius = radius
	_duration = duration


func _ready() -> void:
	# The red light makes the marker read even in darkness — danger is always
	# visible. Overscaled 1.4x so the RIM is lit too (the glow falloff hits
	# zero exactly at texture edge). Counts against the ≤16 lights budget.
	_light = PointLight2D.new()
	_light.texture = Game.glow_texture()
	_light.texture_scale = (_radius * 1.4) / float(Game.GLOW_RADIUS_PX)
	_light.color = Color(1.0, 0.25, 0.2)
	_light.energy = 0.4
	_light.shadow_enabled = true  # danger doesn't leak through walls
	_light.shadow_filter = 1
	add_child(_light)


func _process(delta: float) -> void:
	_elapsed += delta
	_light.energy = 0.4 + clampf(_elapsed / _duration, 0.0, 1.0)
	if _elapsed >= _duration + 0.18:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	if _elapsed < _duration:
		var t: float = clampf(_elapsed / _duration, 0.0, 1.0)
		draw_arc(Vector2.ZERO, _radius - 2.0, 0.0, TAU, 48, Color(1.0, 0.25, 0.2, 0.9), 3.5)
		draw_circle(Vector2.ZERO, _radius * t, Color(1.0, 0.2, 0.15, 0.3))
	else:
		draw_circle(Vector2.ZERO, _radius, Color(1.0, 0.5, 0.4, 0.55))