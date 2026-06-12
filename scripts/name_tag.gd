class_name NameTag
extends Node2D
## Floating player name above the health bar. top_level follower; hidden for
## your own pawn (you know who you are) and follows LoS visibility for others.

@export var offset := Vector2(0, -42)

var text: String = ""


func _ready() -> void:
	top_level = true
	z_index = 10


func set_text(value: String) -> void:
	text = value
	queue_redraw()


func _process(_delta: float) -> void:
	var holder := get_parent() as Node2D
	if holder == null:
		return
	global_position = holder.global_position + offset
	global_rotation = 0.0
	visible = holder.visible


func _draw() -> void:
	if text.is_empty():
		return
	draw_string(ThemeDB.fallback_font, Vector2(-60, 0), text,
			HORIZONTAL_ALIGNMENT_CENTER, 120, 11, Color(1, 1, 1, 0.85))