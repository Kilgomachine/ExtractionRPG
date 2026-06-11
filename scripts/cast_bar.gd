class_name CastBar
extends Node2D
## Floating cast bar above a pawn/enemy. top_level follower like HealthBar.
## Purely visual — start() animates locally; the host owns actual completion.

const SIZE := Vector2(38, 5)

@export var offset := Vector2(0, -40)
@export var fill_color := Color(1.0, 0.62, 0.2)

var _duration: float = 0.0
var _elapsed: float = 0.0


func _ready() -> void:
	top_level = true
	z_index = 10
	visible = false


func start(duration: float) -> void:
	_duration = duration
	_elapsed = 0.0
	visible = true


func stop() -> void:
	_duration = 0.0
	visible = false


func _process(delta: float) -> void:
	var holder := get_parent() as Node2D
	if holder == null:
		return
	global_position = holder.global_position + offset
	global_rotation = 0.0
	if _duration <= 0.0:
		return
	_elapsed += delta
	if _elapsed >= _duration:
		stop()
		return
	queue_redraw()


func _draw() -> void:
	if _duration <= 0.0:
		return
	var origin := Vector2(-SIZE.x * 0.5, -SIZE.y * 0.5)
	var t: float = clampf(_elapsed / _duration, 0.0, 1.0)
	draw_rect(Rect2(origin, SIZE), Color(0.05, 0.05, 0.05, 0.85))
	draw_rect(Rect2(origin + Vector2(1, 1), Vector2((SIZE.x - 2.0) * t, SIZE.y - 2.0)), fill_color)