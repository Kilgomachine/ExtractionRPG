class_name BeamFx
extends Node2D
## One-shot laser beam visual: bright line that fades fast. Purely cosmetic —
## the host resolved the damage before broadcasting this.

const LIFETIME: float = 0.28

var _from := Vector2.ZERO
var _to := Vector2.ZERO
var _elapsed: float = 0.0


func setup(from: Vector2, to: Vector2) -> void:
	_from = from
	_to = to


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= LIFETIME:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var fade: float = 1.0 - _elapsed / LIFETIME
	draw_line(to_local(_from), to_local(_to), Color(0.5, 0.9, 1.0, 0.9 * fade), 4.0 * fade + 1.0)
	draw_line(to_local(_from), to_local(_to), Color(1, 1, 1, 0.7 * fade), 1.5)