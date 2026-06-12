class_name RingWalls
extends Node2D
## The Waller's arena: a temporary ring of real walls (collision + occluders —
## they block sight, bullets, and feet). Deterministic from spawn args on every
## peer; crumbles after its duration. skip_mask spares segments that would
## spawn on top of someone.

const SEGMENTS: int = 12

var radius: float = 260.0
var duration: float = 6.0
var skip_mask: int = 0

var _elapsed: float = 0.0


func setup(center: Vector2, ring_radius: float, ring_duration: float, mask: int) -> void:
	position = center
	radius = ring_radius
	duration = ring_duration
	skip_mask = mask


func _ready() -> void:
	var seg_len: float = TAU * radius / float(SEGMENTS) - 8.0
	for i: int in SEGMENTS:
		if skip_mask & (1 << i):
			continue  # someone was standing here — mercy gap
		var angle: float = TAU * float(i) / float(SEGMENTS)
		var body := StaticBody2D.new()
		body.position = Vector2.from_angle(angle) * radius
		body.rotation = angle + PI / 2.0
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(seg_len, 18.0)
		shape.shape = rect
		body.add_child(shape)
		var visual := Polygon2D.new()
		visual.polygon = PackedVector2Array([
			Vector2(-seg_len / 2.0, -9), Vector2(seg_len / 2.0, -9),
			Vector2(seg_len / 2.0, 9), Vector2(-seg_len / 2.0, 9),
		])
		visual.color = Color(0.5, 0.44, 0.4)
		visual.z_index = -9
		body.add_child(visual)
		var occluder := LightOccluder2D.new()
		var poly := OccluderPolygon2D.new()
		poly.polygon = PackedVector2Array([
			Vector2(-seg_len / 2.0 + 4, -5), Vector2(seg_len / 2.0 - 4, -5),
			Vector2(seg_len / 2.0 - 4, 5), Vector2(-seg_len / 2.0 + 4, 5),
		])
		occluder.occluder = poly
		body.add_child(occluder)
		add_child(body)


func remaining() -> float:
	return maxf(0.1, duration - _elapsed)


func _physics_process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= duration:
		queue_free()