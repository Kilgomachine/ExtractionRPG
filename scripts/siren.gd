class_name Siren
extends CharacterBody2D
## The Siren. HOST-OWNED. Drifts near treasure and SINGS — a telegraphed
## 0.8s charm cast (pink flare). Anyone in range with line of sight when the
## song lands is CHARMED: weapons lower and their own feet carry them toward
## her. DASH breaks the trance; killing her frees everyone instantly. Getting
## all the way into her embrace hurts. A lot.

enum State { IDLE, SING, RECOVER, DEAD }

@export var max_health: int = 40
@export var move_speed: float = 80.0
@export var charm_range: float = 300.0  # < camera half-height: no off-screen charms
@export var sing_time: float = 0.8
@export var charm_duration: float = 2.0
@export var embrace_range: float = 44.0
@export var embrace_damage: int = 25
@export var sing_cooldown: float = 4.0
@export var recover_time: float = 1.0
@export var respawn_delay: float = 14.0

var _state: State = State.IDLE
var _health: int = 40
var _home := Vector2.ZERO
var _state_time: float = 0.0
var _retarget_left: float = 0.0
var _acquire_delay_left: float = 0.0
var _sing_cd_left: float = 2.0
var _embrace_left: float = 0.0
var _stun_left: float = 0.0
var _alert_pos := Vector2.INF
var _alert_time_left: float = 0.0
var _wander_goal := Vector2.ZERO
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
	add_to_group(&"sirens")
	_glow.texture = Game.glow_texture()
	_home = global_position
	_wander_goal = global_position
	_health = max_health
	_remote_position = position
	_health_bar.set_health(_health, max_health)
	_vis_poll_left = randf() * 0.1


func _process(delta: float) -> void:
	_reveal_left = maxf(0.0, _reveal_left - delta)
	_vis_poll_left -= delta
	if _vis_poll_left <= 0.0:
		_vis_poll_left = 0.1
		_seen = _state != State.DEAD and _world.sees_point(global_position)
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
		_enter(State.DEAD)
		_die.rpc()
		_world.host_record_kill(attacker)
		_world.host_drop_enemy_loot(global_position, 2)
		print("[combat] %s silenced" % name)


func host_alert(focus: Vector2) -> void:
	if _state == State.IDLE:
		_alert_pos = focus
		_alert_time_left = 8.0
		_retarget_left = 0.0


func host_stun(duration: float) -> void:
	if _state == State.DEAD:
		return
	if _state == State.SING:
		_enter(State.RECOVER)
		_cast_bar.stop()
	_stun_left = maxf(_stun_left, duration)
	_stunned_fx.rpc(duration)


func host_full_sync_to(peer_id: int) -> void:
	_full_sync.rpc_id(peer_id, _health, global_position, _state == State.DEAD)
	if _state == State.SING:
		_sing_fx.rpc_id(peer_id, maxf(0.05, sing_time - _state_time))


# --- host AI -----------------------------------------------------------------

func _run_ai(delta: float) -> void:
	if _stun_left > 0.0:
		_stun_left -= delta
		return
	_sing_cd_left = maxf(0.0, _sing_cd_left - delta)
	_state_time += delta
	# Embrace: anyone (charmed or foolish) inside her arms takes heavy damage.
	if _state != State.DEAD:
		_embrace_left -= delta
		if _embrace_left <= 0.0:
			_embrace_left = 0.5
			for pawn: Player in _world.alive_pawns():
				if pawn.global_position.distance_to(global_position) <= embrace_range:
					_world.host_damage_player(str(pawn.name).to_int(), embrace_damage, 0)
	match _state:
		State.IDLE:
			_acquire_delay_left = maxf(0.0, _acquire_delay_left - delta)
			if _alert_pos.is_finite():
				_alert_time_left -= delta
				var to_alert: Vector2 = _alert_pos - global_position
				if _alert_time_left <= 0.0 or to_alert.length() <= 60.0:
					_alert_pos = Vector2.INF
				else:
					velocity = to_alert.normalized() * (move_speed * 1.6)
					move_and_slide()
					rotation = to_alert.angle()
			else:
				_wander()
			_retarget_left -= delta
			if _retarget_left <= 0.0:
				_retarget_left = 0.25
				var target_id: int = _pick_target()
				if target_id != 0 and _acquire_delay_left == 0.0 \
						and _sing_cd_left == 0.0:
					_enter(State.SING)
					_sing_fx.rpc(sing_time)
				elif target_id != 0 and _acquire_delay_left == 0.0:
					pass  # waiting out the cooldown, keep drifting
				elif target_id != 0:
					pass  # acquire grace ticking
				else:
					_acquire_delay_left = 0.5  # reset grace while nobody is near
		State.SING:
			if _state_time >= sing_time:
				_resolve_song()
				_sing_cd_left = sing_cooldown
				_enter(State.RECOVER)
		State.RECOVER:
			if _state_time >= recover_time:
				_enter(State.IDLE)
		State.DEAD:
			if _state_time >= respawn_delay:
				_respawn.rpc(_home)


func _enter(state: State) -> void:
	_state = state
	_state_time = 0.0


func _wander() -> void:
	var to_goal: Vector2 = _wander_goal - global_position
	if to_goal.length() <= 14.0:
		for attempt: int in 6:
			var candidate: Vector2 = _home + Vector2.from_angle(randf() * TAU) * (30.0 + randf() * 90.0)
			if not _world.point_in_wall(candidate, 14.0):
				_wander_goal = candidate
				break
		return
	velocity = to_goal.normalized() * move_speed
	move_and_slide()
	rotation = to_goal.angle()


func _resolve_song() -> void:
	var charmed := PackedInt32Array()
	for pawn: Player in _world.alive_pawns():
		if pawn.global_position.distance_to(global_position) <= charm_range \
				and _world.sight_clear(global_position, pawn.global_position) \
				and not pawn.is_invulnerable():
			charmed.append(str(pawn.name).to_int())
	if not charmed.is_empty():
		_charm.rpc(charmed, charm_duration)
		# Smitten hands can't hold a weapon — it drops at their feet.
		for id: int in charmed:
			_world.host_force_drop_gun(id)


func _pick_target() -> int:
	var best_id: int = 0
	var best_dist: float = charm_range
	for pawn: Player in _world.alive_pawns():
		var dist: float = pawn.global_position.distance_to(global_position)
		if dist <= best_dist and _world.sight_clear(global_position, pawn.global_position):
			best_dist = dist
			best_id = str(pawn.name).to_int()
	return best_id


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
func _sing_fx(duration: float) -> void:
	_reveal_left = maxf(_reveal_left, duration + 0.4)
	_cast_bar.start(duration, Color(1.0, 0.5, 0.85))
	_glow.enabled = true
	var tween := create_tween()
	tween.tween_property(_glow, ^"energy", 1.4, duration)
	tween.tween_property(_glow, ^"energy", 0.0, 0.3)
	tween.tween_callback(func() -> void: _glow.enabled = false)


@rpc("authority", "call_local", "reliable")
func _charm(ids: PackedInt32Array, duration: float) -> void:
	if multiplayer.get_unique_id() in ids:
		var pawn: Player = _world.local_pawn()
		if pawn != null:
			pawn.set_charmed(String(name), duration)


@rpc("authority", "call_local", "reliable")
func _stunned_fx(duration: float) -> void:
	_reveal_left = maxf(_reveal_left, duration)
	_cast_bar.stop()
	var tween := create_tween()
	_body.modulate = Color(1.6, 1.6, 2.2)
	tween.tween_property(_body, ^"modulate", Color.WHITE, duration)


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
	_reveal_left = 0.6
	_cast_bar.stop()
	set_deferred(&"collision_layer", 0)
	# Her death frees everyone she held.
	var pawn: Player = _world.local_pawn()
	if pawn != null:
		pawn.break_charm_from(String(name))


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
	_alert_pos = Vector2.INF
	_stun_left = 0.0


@rpc("authority", "call_remote", "reliable")
func _full_sync(hp: int, at: Vector2, is_dead: bool) -> void:
	_health = hp
	_health_bar.set_health(_health, max_health)
	position = at
	_remote_position = at
	reset_physics_interpolation()
	_state = State.DEAD if is_dead else State.IDLE
	set_deferred(&"collision_layer", 0 if is_dead else 4)