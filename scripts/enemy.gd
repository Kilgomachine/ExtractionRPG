class_name Enemy
extends CharacterBody2D
## "Brute" bandit. HOST-OWNED (authority 1, lives in the world scene): the host
## runs the state machine and resolves damage; clients render streamed position
## and locally-spawned telegraph visuals. Attacks are heavily telegraphed and
## always dodgeable: the slam zone LOCKS where the target stood at windup start.

enum State { IDLE, CHASE, WINDUP, RECOVER, DEAD }

@export var max_health: int = 150
@export var move_speed: float = 130.0
@export var aggro_range: float = 320.0  # < camera half-HEIGHT (324): no off-screen aggro, ever
@export var slam_range: float = 150.0
@export var slam_radius: float = 95.0
@export var slam_damage: int = 70
@export var slam_windup: float = 0.66
@export var slam_recover: float = 0.55
@export var slam_cooldown: float = 2.0
@export var respawn_delay: float = 6.0

var _state: State = State.IDLE
var _health: int = 150
var _home := Vector2.ZERO
var _target_id: int = 0
var _slam_center := Vector2.ZERO
var _state_time: float = 0.0
var _slam_cd_left: float = 0.0
var _retarget_left: float = 0.0
var _remote_position := Vector2.ZERO
var _remote_rotation: float = 0.0
var _last_sync_tick: int = -1
var _marker: Telegraph

@onready var _body: Polygon2D = $Body
@onready var _glow: PointLight2D = $Glow
@onready var _health_bar: HealthBar = $HealthBar
@onready var _world: GameWorld = get_tree().get_first_node_in_group(&"game_world") as GameWorld


func _ready() -> void:
	_glow.texture = Game.glow_texture()
	_home = global_position
	_health = max_health
	_remote_position = position
	_health_bar.set_health(_health, max_health)


func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		_run_ai(delta)
		_stream_state()
	elif _state != State.DEAD:
		var blend: float = 1.0 - exp(-14.0 * delta)
		position = position.lerp(_remote_position, blend)
		rotation = lerp_angle(rotation, _remote_rotation, blend)


## Host-only entry point for taking damage (called by GameWorld on projectile hit).
func host_take_damage(amount: int) -> void:
	if not multiplayer.is_server() or _state == State.DEAD:
		return
	_health = maxi(0, _health - amount)
	_sync_hp.rpc(_health)
	if _health == 0:
		_enter(State.DEAD)
		_die.rpc()
		print("[combat] %s died" % name)


## Host-only: push full state to a late joiner.
func host_full_sync_to(peer_id: int) -> void:
	_full_sync.rpc_id(peer_id, _health, global_position, _state == State.DEAD)
	# Mid-windup joiners must still see the danger zone — never an unsignaled hit.
	if _state == State.WINDUP:
		_telegraph.rpc_id(peer_id, _slam_center, slam_radius, maxf(0.05, slam_windup - _state_time))


# --- host AI ---------------------------------------------------------------

func _run_ai(delta: float) -> void:
	_slam_cd_left = maxf(0.0, _slam_cd_left - delta)
	_state_time += delta
	match _state:
		State.IDLE:
			# Leash: drift back home so Brutes don't migrate to the spawn spots.
			var to_home: Vector2 = _home - global_position
			if to_home.length() > 24.0:
				velocity = to_home.normalized() * (move_speed * 0.8)
				move_and_slide()
				rotation = to_home.angle()
			_retarget_left -= delta
			if _retarget_left <= 0.0:
				_retarget_left = 0.25
				_target_id = _pick_target()
				if _target_id != 0:
					_enter(State.CHASE)
		State.CHASE:
			var target: Player = _world.pawn_for(_target_id)
			if target == null or target.dead:
				_target_id = 0
				_enter(State.IDLE)
				return
			var to_target: Vector2 = target.global_position - global_position
			if to_target.length() > aggro_range * 1.25 or not _has_los(target.global_position):
				_target_id = 0
				_enter(State.IDLE)
				return
			velocity = to_target.normalized() * move_speed
			move_and_slide()
			rotation = to_target.angle()
			if to_target.length() <= slam_range and _slam_cd_left == 0.0:
				# Lock the danger zone where the target stands NOW — moving
				# out (or i-framing through) during the windup dodges it.
				_slam_center = target.global_position
				_enter(State.WINDUP)
				_telegraph.rpc(_slam_center, slam_radius, slam_windup)
		State.WINDUP:
			if _state_time >= slam_windup:
				_resolve_slam()
				_slam_cd_left = slam_cooldown
				_enter(State.RECOVER)
		State.RECOVER:
			if _state_time >= slam_recover:
				_enter(State.CHASE if _target_id != 0 else State.IDLE)
		State.DEAD:
			if _state_time >= respawn_delay:
				_respawn.rpc(_home)


func _enter(state: State) -> void:
	_state = state
	_state_time = 0.0


func _pick_target() -> int:
	var best_id: int = 0
	var best_dist: float = aggro_range
	for pawn: Player in _world.alive_pawns():
		var dist: float = pawn.global_position.distance_to(global_position)
		if dist <= best_dist and _has_los(pawn.global_position):
			best_dist = dist
			best_id = str(pawn.name).to_int()
	return best_id


func _has_los(point: Vector2) -> bool:
	var space := get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(global_position, point, 1)  # walls only
	return space.intersect_ray(query).is_empty()


func _resolve_slam() -> void:
	for pawn: Player in _world.alive_pawns():
		if pawn.global_position.distance_to(_slam_center) <= slam_radius + 12.0:
			_world.host_damage_player(str(pawn.name).to_int(), slam_damage)
	_impact.rpc()


func _stream_state() -> void:
	if _state == State.DEAD:
		return
	var tick: int = Engine.get_physics_frames()
	for peer_id: int in Game.ready_peers:
		if peer_id != 1:
			_sync_motion.rpc_id(peer_id, tick, position, rotation)


# --- replication -----------------------------------------------------------

@rpc("authority", "call_remote", "unreliable")
func _sync_motion(tick: int, remote_position: Vector2, remote_rotation: float) -> void:
	if tick <= _last_sync_tick:
		return
	_last_sync_tick = tick
	_remote_position = remote_position
	_remote_rotation = remote_rotation
	if position.distance_to(remote_position) > 200.0:
		position = remote_position
		reset_physics_interpolation()


@rpc("authority", "call_local", "reliable")
func _telegraph(center: Vector2, radius: float, windup: float) -> void:
	if is_instance_valid(_marker):
		_marker.queue_free()
	_marker = Telegraph.new()
	_marker.setup(center, radius, windup)
	_world.add_child(_marker)


@rpc("authority", "call_local", "reliable")
func _impact() -> void:
	var tween := create_tween()
	tween.tween_property(_body, ^"scale", Vector2(1.45, 1.45), 0.05)
	tween.tween_property(_body, ^"scale", Vector2.ONE, 0.2)


@rpc("authority", "call_local", "reliable")
func _sync_hp(hp: int) -> void:
	var dropped: bool = hp < _health
	_health = hp
	_health_bar.set_health(_health, max_health)
	if dropped:
		var tween := create_tween()
		_body.modulate = Color(2.2, 0.6, 0.6)
		tween.tween_property(_body, ^"modulate", Color.WHITE, 0.18)


@rpc("authority", "call_local", "reliable")
func _die() -> void:
	_state = State.DEAD
	_state_time = 0.0
	visible = false
	set_deferred(&"collision_layer", 0)
	# Killed mid-windup: pull the marker so it can't show a phantom impact.
	if is_instance_valid(_marker):
		_marker.queue_free()


@rpc("authority", "call_local", "reliable")
func _respawn(at: Vector2) -> void:
	position = at
	_remote_position = at
	reset_physics_interpolation()
	_health = max_health
	_health_bar.set_health(_health, max_health)
	visible = true
	set_deferred(&"collision_layer", 4)
	_state = State.IDLE
	_state_time = 0.0
	_target_id = 0


@rpc("authority", "call_remote", "reliable")
func _full_sync(hp: int, at: Vector2, is_dead: bool) -> void:
	_health = hp
	_health_bar.set_health(_health, max_health)
	position = at
	_remote_position = at
	reset_physics_interpolation()
	_state = State.DEAD if is_dead else State.IDLE
	visible = not is_dead
	set_deferred(&"collision_layer", 0 if is_dead else 4)
	if is_dead and is_instance_valid(_marker):
		_marker.queue_free()