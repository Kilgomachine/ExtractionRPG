class_name SmokeZone
extends Node2D
## Smoke cloud: blocks SIGHT both ways. A circular LightOccluder2D blacks it
## out visually (player lights can't penetrate), and GameWorld.sight_clear
## checks segment-vs-cloud so enemy AI can't see through it either.

const SEGMENTS: int = 20

var radius: float = 90.0
var duration: float = 7.0

var _elapsed: float = 0.0


func setup(center: Vector2, smoke_radius: float, smoke_duration: float) -> void:
	position = center
	radius = smoke_radius
	duration = smoke_duration


func _ready() -> void:
	add_to_group(&"smoke")
	var occluder := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	var points := PackedVector2Array()
	for i: int in SEGMENTS:
		points.append(Vector2.from_angle(TAU * float(i) / SEGMENTS) * (radius * 0.9))
	poly.polygon = points
	occluder.occluder = poly
	add_child(occluder)


func _physics_process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= duration:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var fade: float = clampf((duration - _elapsed) / 0.8, 0.0, 1.0)
	var swirl: float = 0.5 + 0.08 * sin(_elapsed * 3.0)
	draw_circle(Vector2.ZERO, radius, Color(0.75, 0.78, 0.85, swirl * fade))
	draw_circle(Vector2.ZERO, radius * 0.6, Color(0.85, 0.88, 0.95, 0.45 * fade))