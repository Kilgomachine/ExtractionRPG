class_name Projectile
extends Area2D
## Player shot. Flies deterministically on every peer (same spawn + direction);
## ONLY the host detects hits and broadcasts despawn/damage — split authority.

const SPEED: float = 760.0
const LIFETIME: float = 0.8

var _direction := Vector2.RIGHT
var _life: float = 0.0
var _consumed: bool = false


func setup(from: Vector2, direction: Vector2) -> void:
	position = from
	_direction = direction
	rotation = direction.angle()


func _ready() -> void:
	if multiplayer.is_server():
		body_entered.connect(_on_body_entered)


func _physics_process(delta: float) -> void:
	position += _direction * SPEED * delta
	_life += delta
	if _life > LIFETIME:
		queue_free()


func _on_body_entered(body: Node2D) -> void:
	if _consumed:
		return
	_consumed = true
	var world := get_tree().get_first_node_in_group(&"game_world") as GameWorld
	if world == null:
		return
	world.host_projectile_hit(int(String(name).trim_prefix("p")), body)