class_name Chamber
extends CharacterBody2D
## The WALLER. HOST-OWNED siege monster: corners you, casts — and a ring of
## REAL walls erupts around you both. A second later the arena floods with
## flame... except the cone of calm directly behind him. Stand in his shadow
## or die in the fire. The walls crumble; he recovers; you reconsider.

enum State { IDLE, CHASE, CAST, BURSTWAIT, RECOVER, DEAD }

@export var max_health: int = 300
@export var move_speed: float = 150.0  # fast enough to actually corner you
@export var aggro_range: float = 320.0
@export var trap_range: float = 240.0
@export var burst_delay: float = 1.4  # the readable window INSIDE the cage
@export var ring_radius: float = 260.0
@export var ring_duration: float = 6.0
@export var burst_duration: float = 3.0
@export var trap_cooldown: float = 9.0
@export var recover_time: float = 2.0
@export var respawn_delay: float = 20.0

var _state: State = State.IDLE
var _health: int = 300
var _home := Vector2.ZERO
var _target_id: int = 0
var _state_time: float = 0.0
var _retarget_left: float = 0.0
var _acquire_delay_left: float = 0.0
var _trap_cd_left: float = 4.0
var _stun_left: float = 0.0
var _alert_pos := Vector2.INF
var _alert_time_left: float = 0.0
var _ring_center := Vector2.ZERO
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


func host_take_damage(amount: int, attacker: int = 0) -> int:
	if not multiplayer.is_server() or _state == State.DEAD:
		return 0
	if attacker > 0 and _state == State.IDLE:
		_target_id = attacker
		_acquire_delay_left = 0.0
		_enter(State.CHASE)
	var applied: int = mini(amount, _health)
	_health = maxi(0, _health - amount)
	_sync_hp.rpc(_health)
	if _health == 0:
		_enter(State.DEAD)
		_die.rpc()
		_world.host_record_kill(attacker)
		_world.host_drop_enemy_loot(global_position, 4)
		print("[combat] %s crumbled" % name)
	return applied


func host_alert(focus: Vector2) -> void:
	if _state == State.IDLE:
		_alert_pos = focus
		_alert_time_left = 8.0
		_retarget_left = 0.0


func host_stun(duration: float) -> void:
	if _state == State.DEAD:
		return
	# Stunning him mid-burst-charge pauses the fire (state time freezes).
	_stun_left = maxf(_stun_left, duration)
	_stunned_fx.rpc(duration)


func host_full_sync_to(peer_id: int) -> void:
	_full_sync.rpc_id(peer_id, _health, global_position, _state == State.DEAD)
	if _state == State.BURSTWAIT:
		_cast_fx.rpc_id(peer_id, maxf(0.05, burst_delay - _state_time))


# --- host AI -----------------------------------------------------------------

func _run_ai(delta: float) -> void:
	if _stun_left > 0.0:
		_stun_left -= delta
		if _stun_left <= 0.0 and _state == State.BURSTWAIT:
			# Stun erased the cast bar (_stunned_fx stops it) while the burst
			# clock froze — restart the telegraph for the time still owed.
			_cast_fx.rpc(maxf(0.05, burst_delay - _state_time))
		return
	_trap_cd_left = maxf(0.0, _trap_cd_left - delta)
	_state_time += delta
	match _state:
		State.IDLE:
			if _alert_pos.is_finite():
				_alert_time_left -= delta
				var to_alert: Vector2 = _alert_pos - global_position
				if _alert_time_left <= 0.0 or to_alert.length() <= 60.0:
					_alert_pos = Vector2.INF
				else:
					velocity = to_alert.normalized() * move_speed
					move_and_slide()
					rotation = to_alert.angle()
			else:
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
					_alert_pos = Vector2.INF
					_acquire_delay_left = 0.5
					_enter(State.CHASE)
		State.CHASE:
			_acquire_delay_left = maxf(0.0, _acquire_delay_left - delta)
			var target: Player = _world.pawn_for(_target_id)
			if target == null or target.dead or target.downed:
				_target_id = 0
				_enter(State.IDLE)
				return
			var to_target: Vector2 = target.global_position - global_position
			if to_target.length() > aggro_range * 1.3 \
					or not _world.sight_clear(global_position, target.global_position):
				_target_id = 0
				_enter(State.IDLE)
				return
			var heading: Vector2 = _world.steer_dir(global_position, to_target.normalized())
			velocity = heading * move_speed
			move_and_slide()
			rotation = heading.angle()
			if to_target.length() <= trap_range and _trap_cd_left == 0.0 \
					and _acquire_delay_left == 0.0:
				# NO WARNING: the walls ARE the ambush. The fire is the telegraph.
				_raise_walls()
				_enter(State.BURSTWAIT)
				_cast_fx.rpc(burst_delay)
		State.BURSTWAIT:
			if _state_time >= burst_delay:
				# The flood: everything inside burns except the cone behind him.
				var safe_dir: float = (global_position - _ring_center).angle()
				_world.host_spawn_burst(_ring_center, safe_dir, ring_radius + 20.0, burst_duration)
				_trap_cd_left = trap_cooldown
				_enter(State.RECOVER)
		State.RECOVER:
			if _state_time >= recover_time:
				_enter(State.CHASE if _target_id != 0 else State.IDLE)
		State.DEAD:
			if _state_time >= respawn_delay:
				_respawn.rpc(_home)


func _raise_walls() -> void:
	var target: Player = _world.pawn_for(_target_id)
	_ring_center = global_position
	if target != null and not target.dead and not target.downed:
		_ring_center = (global_position + target.global_position) * 0.5
	# Spare ring segments that would crush someone standing there.
	var mask: int = 0
	for i: int in RingWalls.SEGMENTS:
		var seg_pos: Vector2 = _ring_center \
				+ Vector2.from_angle(TAU * float(i) / RingWalls.SEGMENTS) * ring_radius
		for pawn: Player in _world.alive_pawns():
			# Segment half-length 64 + wall thickness 9 + pawn radius 13:
			# anything under ~88 can pin or crush a standing player.
			if pawn.global_position.distance_to(seg_pos) < 88.0:
				mask |= 1 << i
		if global_position.distance_to(seg_pos) < 60.0:
			mask |= 1 << i  # he doesn't wall himself in half
	_world.host_spawn_ring(_ring_center, ring_radius, ring_duration, mask)


func _enter(state: State) -> void:
	_state = state
	_state_time = 0.0


func _pick_target() -> int:
	var best_id: int = 0
	var best_dist: float = aggro_range
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
	if position.distance_to(remote_position) > 220.0:
		position = remote_position
		reset_physics_interpolation()


@rpc("authority", "call_local", "reliable")
func _cast_fx(duration: float) -> void:
	_reveal_left = maxf(_reveal_left, duration + 0.4)
	_cast_bar.start(duration, Color(0.7, 0.55, 0.4))
	_glow.enabled = true
	var tween := create_tween()
	tween.tween_property(_glow, ^"energy", 1.5, duration)
	tween.tween_property(_glow, ^"energy", 0.0, 0.4)
	tween.tween_callback(func() -> void: _glow.enabled = false)


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
	_reveal_left = 0.8
	_cast_bar.stop()
	set_deferred(&"collision_layer", 0)
	Game.play_sfx("boom", global_position)


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
	_stun_left = 0.0
	_trap_cd_left = 4.0


@rpc("authority", "call_remote", "reliable")
func _full_sync(hp: int, at: Vector2, is_dead: bool) -> void:
	_health = hp
	_health_bar.set_health(_health, max_health)
	position = at
	_remote_position = at
	reset_physics_interpolation()
	_state = State.DEAD if is_dead else State.IDLE
	set_deferred(&"collision_layer", 0 if is_dead else 4)