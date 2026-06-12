class_name FireZone
extends Node2D
## Burning ground: a circle (death bursts) or a CONE (Igniter flame jet).
## Spawned on every peer via world broadcast; each peer renders and
## self-despawns after the (shared) duration. The cone is built from raycasts
## clipped at walls, so flame NEVER reaches through cover — visually or
## mechanically. ONLY the host ticks damage; i-frames apply per tick.

const FAN_RAYS: int = 17

var radius: float = 80.0
var duration: float = 4.0
var cone: bool = false
var direction: float = 0.0
var half_angle_deg: float = 32.0
# The Igniter's cone is LETHAL (x4 damage at x4 rate); death fires stay mild.
var tick_interval: float = 0.5
var tick_damage: int = 8

var _elapsed: float = 0.0
var _tick_left: float = 0.5
var _light: PointLight2D
var _fan: PackedVector2Array = PackedVector2Array()

@onready var _world: GameWorld = get_tree().get_first_node_in_group(&"game_world") as GameWorld


func setup(center: Vector2, fire_radius: float, fire_duration: float) -> void:
	position = center
	radius = fire_radius
	duration = fire_duration


func setup_cone(origin: Vector2, dir_angle: float, fire_range: float,
		half_deg: float, fire_duration: float) -> void:
	position = origin
	cone = true
	direction = dir_angle
	radius = fire_range
	half_angle_deg = half_deg
	duration = fire_duration
	tick_interval = 0.125
	tick_damage = 32
	_tick_left = tick_interval


func _ready() -> void:
	_light = PointLight2D.new()
	_light.texture = Game.glow_texture()
	_light.color = Color(1.0, 0.55, 0.15)
	_light.energy = 0.9
	_light.shadow_enabled = true
	_light.shadow_filter = 1
	if cone:
		_light.position = Vector2.from_angle(direction) * radius * 0.45
		_light.texture_scale = (radius * 0.75) / float(Game.GLOW_RADIUS_PX)
	else:
		_light.texture_scale = (radius * 1.3) / float(Game.GLOW_RADIUS_PX)
	add_child(_light)


func _physics_process(delta: float) -> void:
	if cone and _fan.is_empty():
		_build_fan()  # needs the physics space — first physics frame, not _ready
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
	_tick_left = tick_interval
	for pawn: Player in _world.alive_pawns():
		if _covers(pawn.global_position):
			_world.host_damage_player(str(pawn.name).to_int(), tick_damage)


func _covers(point: Vector2) -> bool:
	var to_point: Vector2 = point - global_position
	if to_point.length() > radius + 10.0:
		return false
	if cone and absf(angle_difference(to_point.angle(), direction)) > deg_to_rad(half_angle_deg) + 0.06:
		return false
	# Flame does not go through walls.
	var space := get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(global_position, point, 1)
	return space.intersect_ray(query).is_empty()


## Remaining burn time — used to replay active zones to late joiners.
func remaining() -> float:
	return maxf(0.05, duration - _elapsed)


func _build_fan() -> void:
	var space := get_world_2d().direct_space_state
	var points: PackedVector2Array = PackedVector2Array([Vector2.ZERO])
	var half_rad: float = deg_to_rad(half_angle_deg)
	var center_dist: float = radius
	for i: int in FAN_RAYS:
		var angle: float = direction - half_rad + (2.0 * half_rad) * (float(i) / float(FAN_RAYS - 1))
		var dir: Vector2 = Vector2.from_angle(angle)
		var query := PhysicsRayQueryParameters2D.create(
				global_position, global_position + dir * radius, 1)
		var hit: Dictionary = space.intersect_ray(query)
		var dist: float = radius
		if not hit.is_empty():
			dist = (hit["position"] as Vector2 - global_position).length()
		if i == FAN_RAYS / 2:
			center_dist = dist
		points.append(dir * dist)
	_fan = points
	# Keep the light inside the CLIPPED cone — never inside (or beyond) a wall.
	_light.position = Vector2.from_angle(direction) * minf(radius * 0.45, center_dist * 0.6)


func _draw() -> void:
	var fade: float = clampf((duration - _elapsed) / 0.6, 0.0, 1.0)
	var pulse: float = 0.22 + 0.06 * sin(_elapsed * 9.0)
	if cone:
		if _fan.size() >= 3:
			draw_colored_polygon(_fan, Color(1.0, 0.42, 0.1, pulse * fade))
			var outline: PackedVector2Array = _fan.duplicate()
			outline.append(_fan[0])
			draw_polyline(outline, Color(1.0, 0.6, 0.2, 0.7 * fade), 2.0)
	else:
		draw_circle(Vector2.ZERO, radius, Color(1.0, 0.42, 0.1, pulse * fade))
		draw_arc(Vector2.ZERO, radius - 2.0, 0.0, TAU, 40, Color(1.0, 0.6, 0.2, 0.7 * fade), 2.5)