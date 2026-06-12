class_name HealthBar
extends Node2D
## Floating bar above a pawn. top_level so it never rotates with the body;
## follows the parent's global position each frame.

const SIZE := Vector2(34, 5)

@export var offset := Vector2(0, -28)

var _value: int = 100
var _max_value: int = 100
var _shield: int = 0
var _shield_max: int = 1


func _ready() -> void:
	top_level = true
	z_index = 10


func _process(_delta: float) -> void:
	var holder := get_parent() as Node2D
	if holder == null:
		return
	global_position = holder.global_position + offset
	global_rotation = 0.0
	visible = holder.visible


func set_health(value: int, max_value: int) -> void:
	_value = clampi(value, 0, max_value)
	_max_value = maxi(1, max_value)
	queue_redraw()


func set_shield(value: int, max_value: int) -> void:
	_shield = clampi(value, 0, max_value)
	_shield_max = maxi(1, max_value)
	queue_redraw()


func _draw() -> void:
	var origin := Vector2(-SIZE.x * 0.5, -SIZE.y * 0.5)
	draw_rect(Rect2(origin, SIZE), Color(0.05, 0.05, 0.05, 0.85))
	var pct: float = float(_value) / float(_max_value)
	var fill := Color(0.85, 0.2, 0.15).lerp(Color(0.25, 0.85, 0.3), pct)
	draw_rect(Rect2(origin + Vector2(1, 1), Vector2((SIZE.x - 2.0) * pct, SIZE.y - 2.0)), fill)
	if _shield > 0:
		# Thin blue shield strip above the hp bar.
		var spct: float = float(_shield) / float(_shield_max)
		draw_rect(Rect2(origin + Vector2(1, -3), Vector2((SIZE.x - 2.0) * spct, 2.0)),
				Color(0.45, 0.7, 1.0))