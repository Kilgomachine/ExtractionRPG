class_name Player
extends CharacterBody2D
## One player pawn. The OWNING peer simulates its own movement (split authority:
## clients own their avatars, the host owns the world) and streams position and
## rotation to everyone else, who interpolate toward it. Input-gathering stays
## separate from state-mutation so a later rollback (netfox) retrofit is a
## refactor, not a rewrite.

const SNAP_DISTANCE: float = 200.0
const SPAWN_SPOTS: Array[Vector2] = [
	Vector2(0, -40), Vector2(100, 0), Vector2(-100, 0), Vector2(0, -120),
]

@export var move_speed: float = 230.0
@export var dodge_speed: float = 700.0
@export_range(0.05, 0.5) var dodge_duration: float = 0.16
@export var dodge_cooldown: float = 0.9
@export var remote_lerp_rate: float = 14.0

## Assigned by World (host-orchestrated, by join order) before add_child.
var spawn_slot: int = 0

var _dodge_time_left: float = 0.0
var _dodge_cooldown_left: float = 0.0
var _dodge_direction := Vector2.ZERO
var _remote_position := Vector2.ZERO
var _remote_rotation: float = 0.0
var _has_remote_state: bool = false
var _last_sync_tick: int = -1

@onready var _camera: Camera2D = $Camera2D
@onready var _vision_cone: PointLight2D = $VisionCone
@onready var _glow: PointLight2D = $Glow
@onready var _body: Polygon2D = $Body


func _enter_tree() -> void:
	# The node name is the owning peer's id (set by World when spawning).
	set_multiplayer_authority(str(name).to_int())


func _ready() -> void:
	_vision_cone.texture = Game.cone_texture()
	_glow.texture = Game.glow_texture()
	position = SPAWN_SPOTS[spawn_slot % SPAWN_SPOTS.size()]
	_remote_position = position
	reset_physics_interpolation()
	var is_local: bool = is_multiplayer_authority()
	_camera.enabled = is_local
	if not is_local:
		_body.color = Color(0.55, 0.95, 0.65)  # friends read green


func _physics_process(delta: float) -> void:
	if is_multiplayer_authority():
		var input: Dictionary = _gather_input()
		_apply_movement(input, delta)
		# Only stream to peers whose world is loaded (host-owned ready list).
		var my_id: int = multiplayer.get_unique_id()
		var tick: int = Engine.get_physics_frames()
		for peer_id: int in Game.ready_peers:
			if peer_id != my_id:
				_sync_state.rpc_id(peer_id, tick, position, rotation)
	else:
		var blend: float = 1.0 - exp(-remote_lerp_rate * delta)
		position = position.lerp(_remote_position, blend)
		rotation = lerp_angle(rotation, _remote_rotation, blend)


func _gather_input() -> Dictionary:
	return {
		"move": Input.get_vector(&"move_left", &"move_right", &"move_up", &"move_down"),
		"aim": get_global_mouse_position() - global_position,
		"dodge": Input.is_action_just_pressed(&"dodge"),
	}


func _apply_movement(input: Dictionary, delta: float) -> void:
	_dodge_cooldown_left = maxf(0.0, _dodge_cooldown_left - delta)
	var move: Vector2 = input["move"]
	if input["dodge"] and _dodge_cooldown_left == 0.0:
		_dodge_time_left = dodge_duration
		_dodge_cooldown_left = dodge_cooldown
		# Standing still? Dodge toward where you're aiming.
		_dodge_direction = move.normalized() if move != Vector2.ZERO \
				else Vector2.RIGHT.rotated(rotation)
	if _dodge_time_left > 0.0:
		_dodge_time_left -= delta
		velocity = _dodge_direction * dodge_speed
		_body.scale = Vector2(1.3, 0.72)  # readability cue while dodging
	else:
		velocity = move * move_speed
		_body.scale = Vector2.ONE
	move_and_slide()
	var aim: Vector2 = input["aim"]
	if aim.length_squared() > 4.0:
		rotation = aim.angle()


# Plain "unreliable" + tick guard: per-pawn freshness without the cross-stream
# drops of a shared sequenced channel. Stale/duplicate packets are ignored.
@rpc("authority", "call_remote", "unreliable")
func _sync_state(tick: int, remote_position: Vector2, remote_rotation: float) -> void:
	if tick <= _last_sync_tick:
		return
	_last_sync_tick = tick
	_remote_position = remote_position
	_remote_rotation = remote_rotation
	# First packet (late join) or a huge gap: snap, don't glide across the map.
	if not _has_remote_state or position.distance_to(remote_position) > SNAP_DISTANCE:
		_has_remote_state = true
		position = remote_position
		rotation = remote_rotation
		reset_physics_interpolation()
