class_name Hugger
extends CharacterBody2D
## Skittering leech. HOST-OWNED. Charges in a weaving ZIGZAG (hard to hit),
## LATCHES onto a player on contact — slowing them and draining hp — until the
## victim DASHES it off (it tumbles away stunned). One of the few enemies
## that's more annoying than lethal... unless three are on you.

enum State { IDLE, CHASE, LATCHED, STUNNED, DEAD }

@export var max_health: int = 20
@export var move_speed: float = 300.0
@export var aggro_range: float = 320.0
@export var zigzag_strength: float = 0.7  # radians of weave swing
@export var zigzag_rate: float = 6.0
@export var latch_range: float = 26.0
@export var latch_damage: int = 4
@export var latch_tick: float = 0.6
@export var stun_after_shake: float = 1.2
@export var respawn_delay: float = 14.0

var _state: State = State.IDLE
var _health: int = 20
var _home := Vector2.ZERO
var _target_id: int = 0
var _state_time: float = 0.0
var _retarget_left: float = 0.0
var _acquire_delay_left: float = 0.0
var _alert_pos := Vector2.INF
var _alert_time_left: float = 0.0
var _stun_left: float = 0.0
var _latch_tick_left: float = 0.0
var _seen: bool = false
var _vis_poll_left: float = 0.0
var _reveal_left: float = 0.0
var _remote_position := Vector2.ZERO
var _remote_rotation: float = 0.0
var _last_sync_tick: int = -1

@onready var _body: Polygon2D = $Body
@onready var _health_bar: HealthBar = $HealthBar
@onready var _world: GameWorld = get_tree().get_first_node_in_group(&"game_world") as GameWorld


func _ready() -> void:
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


func host_take_damage(amount: int, attacker: int = 0) -> void:
	if not multiplayer.is_server() or _state == State.DEAD:
		return
	if attacker > 0 and _state == State.IDLE:
		_target_id = attacker  # getting shot IS awareness
		_acquire_delay_left = 0.0
		_enter(State.CHASE)
	_health = maxi(0, _health - amount)
	_sync_hp.rpc(_health)
	if _health == 0:
		if _state == State.LATCHED:
			_latch.rpc(_target_id, false)
		_enter(State.DEAD)
		_die.rpc()
		_world.host_record_kill(attacker)
		_world.host_drop_enemy_loot(global_position, 1)


func host_alert(focus: Vector2) -> void:
	if _state == State.IDLE:
		_alert_pos = focus
		_alert_time_left = 8.0
		_retarget_left = 0.0


func host_stun(duration: float) -> void:
	if _state == State.DEAD:
		return
	if _state == State.LATCHED:
		_latch.rpc(_target_id, false)
		_enter(State.STUNNED)
	_stun_left = maxf(_stun_left, duration)
	_stunned_fx.rpc(duration)


func host_full_sync_to(peer_id: int) -> void:
	_full_sync.rpc_id(peer_id, _health, global_position, _state == State.DEAD)
	if _state == State.LATCHED:
		_latch.rpc_id(peer_id, _target_id, true)


# --- host AI -----------------------------------------------------------------

func _run_ai(delta: float) -> void:
	if _stun_left > 0.0:
		_stun_left -= delta
		return
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
					velocity = to_home.normalized() * (move_speed * 0.5)
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
			if target == null or target.dead:
				_target_id = 0
				_enter(State.IDLE)
				return
			var to_target: Vector2 = target.global_position - global_position
			if to_target.length() > aggro_range * 1.4 \
					or not _world.sight_clear(global_position, target.global_position):
				_target_id = 0
				_enter(State.IDLE)
				return
			# Zigzag: weave the heading so straight shots whiff (walls respected).
			var weave: float = to_target.angle() \
					+ sin(_state_time * zigzag_rate) * zigzag_strength
			var heading: Vector2 = _world.steer_dir(global_position, Vector2.from_angle(weave))
			velocity = heading * move_speed
			move_and_slide()
			rotation = heading.angle()
			if to_target.length() <= latch_range and _acquire_delay_left == 0.0 \
					and not target.is_invulnerable():
				_enter(State.LATCHED)
				_latch_tick_left = latch_tick
				_latch.rpc(_target_id, true)
		State.LATCHED:
			var victim: Player = _world.pawn_for(_target_id)
			if victim == null or victim.dead:
				if victim != null:
					_latch.rpc(_target_id, false)
				_target_id = 0
				_enter(State.IDLE)
				return
			# Ride the victim; their DASH shakes us off.
			global_position = victim.global_position
			if victim.dodge_active():
				_latch.rpc(_target_id, false)
				_stun_left = stun_after_shake
				_enter(State.STUNNED)
				return
			_latch_tick_left -= delta
			if _latch_tick_left <= 0.0:
				_latch_tick_left = latch_tick
				_world.host_damage_player(str(victim.name).to_int(), latch_damage, 0)
		State.STUNNED:
			if _state_time >= stun_after_shake:
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
func _latch(target_id: int, on: bool) -> void:
	var pawn: Player = _world.pawn_for(target_id)
	if pawn != null:
		pawn.add_latcher(1 if on else -1)
	set_deferred(&"collision_layer", 0 if on else 4)
	_body.color = Color(0.95, 0.4, 0.75) if on else Color(0.8, 0.45, 0.65)
	if on:
		_reveal_left = maxf(_reveal_left, 0.6)
		Game.play_sfx("latch", global_position)


@rpc("authority", "call_local", "reliable")
func _stunned_fx(duration: float) -> void:
	_reveal_left = maxf(_reveal_left, duration)
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