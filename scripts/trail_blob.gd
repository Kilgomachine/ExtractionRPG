class_name TrailBlob
extends Node2D
## Brief pulsing ember left behind by a sprinting player. Spawned locally on
## every peer from the running flag in the position stream — no RPCs needed.
## DRAWN, not lit: sprinting can shed several per second and real lights count
## against the 16-per-canvas-item cap; a polygon costs nothing.

const LIFETIME: float = 1.1

var _elapsed: float = 0.0


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= LIFETIME:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var fade: float = 1.0 - _elapsed / LIFETIME
	var pulse: float = 0.35 + 0.2 * sin(_elapsed * 18.0)
	var glow := Color(0.7, 0.8, 1.0, 0.30 * pulse * fade)
	var core := Color(0.85, 0.9, 1.0, 0.55 * pulse * fade)
	draw_circle(Vector2.ZERO, 14.0 * (0.6 + 0.4 * fade), glow)
	draw_circle(Vector2.ZERO, 5.0 * (0.5 + 0.5 * fade), core)
