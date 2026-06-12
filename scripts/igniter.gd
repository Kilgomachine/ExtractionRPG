class_name Igniter
extends CharacterBody2D
## Fast bandit pyro. HOST-OWNED. Outruns players (330 vs 230) but must STOP
## and visibly charge a cast bar before attacking — the rooted cast IS the
## counterplay window. The cast sets the ground around it on fire (DoT zone);
## dying sets it on fire too. LoS-gated visibility like all enemies.

enum State { IDLE, CHASE, CAST, RECOVER, DEAD }

# Glass cannon: dies in 3 hits, but the flame jet is a monster.
@export var max_health: int = 30
@export var move_speed: float = 330.0
@export var aggro_range: float = 320.0  # < camera half-height: no off-screen aggro
@export var cast_range: float = 240.0  # roots well inside flame range
@export var cast_time: float = 0.9
@export var flame_range: float = 640.0  # ENORMOUS cone jet — clipped by walls
@export var flame_half_angle: float = 32.0
@export var flame_duration: float = 2.5
@export var death_fire_radius: float = 70.0
@export var death_fire_duration: float = 3.0
@export var recover_time: float = 0.6
@export var cast_cooldown: float = 3.0
@export var respawn_delay: float = 10.0

var _state: State = State.IDLE
var _health: int = 30
var _acquire_delay_left: float = 0.0
var _stun_left: float = 0.0
var _home := Vector2.ZERO
var _target_id: int = 0
var _alert_pos := Vector2.INF
var _alert_time_left: float = 0.0
var _state_time: float = 0.0
var _cast_cd_left: float = 0.0
var _retarget_left: float = 0.0
var _seen: bool = false
var _vis_poll_left: float = 0.0
var _reveal_left: float = 0.0
var _remote_position := Vector2.ZERO
var _remote_rotation: float = 0.0
var _last_sync_tick: int = -1

@onready var _body: Polygon2D = $Body
@onready var _glow: PointLight2D = $Glow
@onready var _health_bar: HealthBar = $HealthBar
@onready var _cast_bar: CastBar = $CastBar
@onready var _world: GameWorld = get_tree().get_first_node_in_group(&"game_world") as GameWorld


func _ready() -> void:
	_glow.texture = Game.glow_texture()
	_home = global_position
	_health = max_health
	_remote_position = position
	_health_bar.set_health(_health, max_health)
	_vis_poll_left = randf() * 0.1  # stagger visibility polls across enemies


func _process(delta: float) -> void:
	# LoS-gated visibility (all peers): unseen enemies don't render, except
	# for the forced reveal while an attack is charging.
	_reveal_left = maxf(0.0, _reveal_left - delta)
	_vis_poll_left -= delta
	if _vis_poll_left <= 0.0:
		_vis_poll_left = 0.1
		_seen = _state != State.DEAD and _world.sees_point(global_position)
	# Reveal wins even when dead — kills must be seen wherever they happen.
	visible = _reveal_left > 0.0 or (_state != State.DEAD and _seen)


func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		_run_ai(delta)
		_stream_state()
	elif _state != State.DEAD:
		var blend: float = 1.0 - exp(-14.0 * delta)
		position = position.lerp(_remote_position, blend)
		rotation = lerp_angle(rotation, _remote_rotation, blend)


func host_take_damage(amount: int, attacker: int = 0) -> void:
	if not multiplayer.is_server() or _state == State.DEAD:
		return
	_health = maxi(0, _health - amount)
	_sync_hp.rpc(_health)
	if _health == 0:
		_world.host_spawn_fire(global_position, death_fire_radius, death_fire_duration)
		_enter(State.DEAD)
		_die.rpc()
		_world.host_record_kill(attacker)
		_world.host_drop_enemy_loot(global_position, 1)
		print("[combat] %s died (and ignited)" % name)


func host_stun(duration: float) -> void:
	if _state == State.DEAD:
		return
	_stun_left = maxf(_stun_left, duration)
	if _state == State.CAST:
		_enter(State.RECOVER)
		_cast_bar.stop()
	_stunned_fx.rpc(duration)


@rpc("authority", "call_local", "reliable")
func _stunned_fx(duration: float) -> void:
	_reveal_left = maxf(_reveal_left, duration)
	_cast_bar.stop()
	var tween := create_tween()
	_body.modulate = Color(1.6, 1.6, 2.2)
	tween.tween_property(_body, ^"modulate", Color.WHITE, duration)


func host_alert(focus: Vector2) -> void:
	if _state == State.IDLE:
		_retarget_left = 0.0
		# Sprint toward the noise; normal aggro takes over on arrival.
		_alert_pos = focus
		_alert_time_left = 8.0  # timeout so a wedged walker can't stick forever


func host_full_sync_to(peer_id: int) -> void:
	_full_sync.rpc_id(peer_id, _health, global_position, _state == State.DEAD)
	# Mid-cast joiners still see the charge — never an unsignaled attack.
	if _state == State.CAST:
		_cast.rpc_id(peer_id, maxf(0.05, cast_time - _state_time))


# --- host AI -----------------------------------------------------------------

func _run_ai(delta: float) -> void:
	if _stun_left > 0.0:
		_stun_left -= delta
		return
	_cast_cd_left = maxf(0.0, _cast_cd_left - delta)
	_state_time += delta
	match _state:
		State.IDLE:
			if _alert_pos.is_finite():
				_alert_time_left -= delta
				var to_alert: Vector2 = _alert_pos - global_position
				if _alert_time_left <= 0.0 or to_alert.length() <= 50.0:
					_alert_pos = Vector2.INF
				else:
					velocity = to_alert.normalized() * move_speed
					move_and_slide()
					rotation = to_alert.angle()
			else:
				var to_home: Vector2 = _home - global_position
				if to_home.length() > 24.0:
					velocity = to_home.normalized() * (move_speed * 0.6)
					move_and_slide()
					rotation = to_home.angle()
			_retarget_left -= delta
			if _retarget_left <= 0.0:
				_retarget_left = 0.25
				_target_id = _pick_target()
				if _target_id != 0:
					_alert_pos = Vector2.INF
					_acquire_delay_left = 0.5  # grace before the first attack
					_enter(State.CHASE)
		State.CHASE:
			_acquire_delay_left = maxf(0.0, _acquire_delay_left - delta)
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
			if to_target.length() <= cast_range and _cast_cd_left == 0.0 \
					and _acquire_delay_left == 0.0:
				# Flame direction locks NOW (rotation stops updating in CAST) —
				# sidestep during the charge to escape the jet.
				_enter(State.CAST)
				_cast.rpc(cast_time)
		State.CAST:
			if _state_time >= cast_time:
				_cast_cd_left = cast_cooldown
				_world.host_spawn_flame_cone(global_position, rotation,
						flame_range, flame_half_angle, flame_duration)
				_enter(State.RECOVER)
		State.RECOVER:
			if _state_time >= recover_time:
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
	return _world.sight_clear(global_position, point)  # walls + smoke


func _stream_state() -> void:
	if _state == State.DEAD:
		return
	var tick: int = Engine.get_physics_frames()
	for peer_id: int in Game.ready_peers:
		if peer_id != 1:
			_sync_motion.rpc_id(peer_id, tick, position, rotation)


# --- replication -------------------------------------------------------------

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
func _cast(duration: float) -> void:
	# Glow enabled only for the pulse (energy-0 lights still eat light slots).
	_reveal_left = duration + 0.4
	_cast_bar.start(duration)
	_glow.enabled = true
	var tween := create_tween()
	tween.tween_property(_glow, ^"energy", 1.3, duration)
	tween.tween_property(_glow, ^"energy", 0.0, 0.3)
	tween.tween_callback(func() -> void: _glow.enabled = false)


@rpc("authority", "call_local", "reliable")
func _sync_hp(hp: int) -> void:
	var dropped: bool = hp < _health
	_health = hp
	_health_bar.set_health(_health, max_health)
	if dropped:
		var tween := create_tween()
		_body.modulate = Color(2.2, 0.6, 0.6)
		tween.tween_property(_body, ^"modulate", Color.WHITE, 0.18)
		Game.play_sfx("hit", global_position)


@rpc("authority", "call_local", "reliable")
func _die() -> void:
	_state = State.DEAD
	_state_time = 0.0
	_reveal_left = 0.6  # the kill is shown (the death fire reveals it too)
	_cast_bar.stop()
	set_deferred(&"collision_layer", 0)


@rpc("authority", "call_local", "reliable")
func _respawn(at: Vector2) -> void:
	position = at
	_remote_position = at
	reset_physics_interpolation()
	_health = max_health
	_health_bar.set_health(_health, max_health)
	set_deferred(&"collision_layer", 4)
	_state = State.IDLE
	_state_time = 0.0
	_target_id = 0
	_alert_pos = Vector2.INF
	_alert_time_left = 0.0


@rpc("authority", "call_remote", "reliable")
func _full_sync(hp: int, at: Vector2, is_dead: bool) -> void:
	_health = hp
	_health_bar.set_health(_health, max_health)
	position = at
	_remote_position = at
	reset_physics_interpolation()
	_state = State.DEAD if is_dead else State.IDLE
	set_deferred(&"collision_layer", 0 if is_dead else 4)