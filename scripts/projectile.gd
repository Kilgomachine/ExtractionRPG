class_name Projectile
extends Area2D
## A shot. Flies deterministically on every peer (same spawn + direction);
## ONLY the host detects hits and broadcasts despawn/damage — split authority.
## Player shots (fast, yellow) hit walls+enemies; hostile shots (slow, red,
## dodgeable — i-frames apply) hit walls+players.

const PLAYER_SPEED: float = 760.0
const PLAYER_LIFETIME: float = 0.8
const HOSTILE_SPEED: float = 330.0
const HOSTILE_LIFETIME: float = 1.7

var hostile: bool = false
var damage: int = 12
var shooter_id: int = 0

var _direction := Vector2.RIGHT
var _speed: float = PLAYER_SPEED
var _life_left: float = PLAYER_LIFETIME
var _consumed: bool = false

@onready var _body: Polygon2D = $Body


func setup(from: Vector2, direction: Vector2, is_hostile: bool, dmg: int, shooter: int) -> void:
	position = from
	_direction = direction
	rotation = direction.angle()
	hostile = is_hostile
	damage = dmg
	shooter_id = shooter
	_speed = HOSTILE_SPEED if hostile else PLAYER_SPEED
	_life_left = HOSTILE_LIFETIME if hostile else PLAYER_LIFETIME


func _ready() -> void:
	# Friendly fire: player bullets now hit walls+players+enemies (7).
	collision_mask = 3 if hostile else 7
	if hostile:
		_body.color = Color(1.0, 0.4, 0.32)
	if multiplayer.is_server():
		body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	position += _direction * _speed * delta
	_life_left -= delta
	if _life_left <= 0.0:
		queue_free()


func _on_body_entered(body: Node2D) -> void:
	if _consumed:
		return
	var world := get_tree().get_first_node_in_group(&"game_world") as GameWorld
	if world == null:
		return
	# Not consumed when a shot meets i-frames or its own shooter — it sails on.
	_consumed = world.host_projectile_hit(int(String(name).trim_prefix("p")), body,
			hostile, damage, shooter_id)