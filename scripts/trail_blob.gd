class_name TrailBlob
extends Node2D
## Brief pulsing light left behind by a sprinting player. Spawned locally on
## every peer from the running flag in the position stream — no RPCs needed.

const LIFETIME: float = 1.1

var _elapsed: float = 0.0
var _light: PointLight2D


func _ready() -> void:
	_light = PointLight2D.new()
	_light.texture = Game.glow_texture()
	_light.texture_scale = 0.8
	_light.color = Color(0.7, 0.8, 1.0)
	_light.energy = 0.5
	# No shadows: it's an ember, and shadowless lights are cheaper.
	add_child(_light)


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= LIFETIME:
		queue_free()
		return
	var fade: float = 1.0 - _elapsed / LIFETIME
	_light.energy = (0.35 + 0.2 * sin(_elapsed * 18.0)) * fade