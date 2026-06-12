class_name Exploder
extends CharacterBody2D
## Suicide sprinter. HOST-OWNED. Fastest thing on the map, dies to a single
## hit — kill it before it reaches you. On contact it roots for a short fuse
## (red circle telegraph, your last dodge window) then detonates for heavy
## damage. Killing it during the fuse DEFUSES it. While charging, it streams
## a "chasing" flag so every peer keeps it revealed and flaring — you always
## see it coming.

enum State { IDLE, CHASE, FUSE, DEAD }

@export var max_health: int = 12  # one player shot
@export var move_speed: float = 360.0
@export var aggro_range: float = 320.0  # < camera half-height
@export var fuse_range: float = 34.0
@export var fuse_time: float = 0.9  # generous final window — kill it or move
@export var blast_radius: float = 187.0  # kill it or eat the hit
@export var blast_damage: int = 60
@export var respawn_delay: float = 12.0

var _state: State = State.IDLE
var _health: int = 12
var _home := Vector2.ZERO
var _target_id: int = 0
var _state_time: float = 0.0
var _retarget_left: float = 0.0
var _acquire_delay_left: float = 0.0
var _alert_pos := Vector2.INF
var _alert_time_left: float = 0.0
var _fusing: bool = false
var _stun_left: float = 0.0
var _seen: bool = false
var _vis_poll_left: float = 0.0
var _reveal_left: float = 0.0
var _remote_position := Vector2.ZERO
var _remote_rotation: float = 0.0
var _remote_chasing: bool = false
var _last_sync_tick: int = -1

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
	_vis_poll_left = randf() * 0.1


func _process(delta: float) -> void:
	_reveal_left = maxf(0.0, _reveal_left - delta)
	_vis_poll_left -= delta
	if _vis_poll_left <= 0.0:
		_vis_poll_left = 0.1
		_seen = _state != State.DEAD and _world.sees_point(global_position)
	var charging: bool = _is_charging()
	if _fusing:
		_reveal_left = maxf(_reveal_left, 0.2)
		# The _fuse tween owns the glow here — the ramp to 2.0 is the tell.
	elif charging:
		_reveal_left = maxf(_reveal_left, 0.3)  # always visible while it hunts you
		# Glow only while someone could see it — an enabled light eats a slot.
		_glow.enabled = _seen
		_glow.energy = 0.7 + 0.5 * sin(Time.get_ticks_msec() * 0.02)  # frantic pulse
	else:
		_glow.enabled = false
	visible = _reveal_left > 0.0 or (_state != State.DEAD and _seen)


func _is_charging() -> bool:
	if multiplayer.is_server():
		return _state == State.CHASE or _state == State.FUSE
	return _remote_chasing


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
	var applied: int = mini(amount, _health)
	_health = maxi(0, _health - amount)
	_sync_hp.rpc(_health)
	if _health == 0:
		# Shot down — defused, no blast. That's the reward for good aim.
		_enter(State.DEAD)
		_die.rpc()
		_world.host_record_kill(attacker)
		_world.host_drop_enemy_loot(global_position, 2)
		print("[combat] %s defused" % name)
	return applied


func host_stun(duration: float) -> void:
	if _state == State.DEAD or _state == State.FUSE:
		return  # a lit fuse doesn't care about flashbangs
	_stun_left = maxf(_stun_left, duration)


func _has_los(point: Vector2) -> bool:
	return _world.sight_clear(global_position, point)  # walls + smoke


func host_alert(focus: Vector2) -> void:
	if _state == State.IDLE:
		_alert_pos = focus
		_alert_time_left = 8.0
		_retarget_left = 0.0


func host_full_sync_to(peer_id: int) -> void:
	_full_sync.rpc_id(peer_id, _health, global_position, _state == State.DEAD)
	# Mid-fuse joiners still see the blast telegraph — never an unsignaled hit.
	if _state == State.FUSE:
		_fuse.rpc_id(peer_id, global_position)


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
			if to_target.length() > aggro_range * 1.4 or not _has_los(target.global_position):
				_target_id = 0
				_enter(State.IDLE)
				return
			var heading: Vector2 = _world.steer_dir(global_position, to_target.normalized())
			velocity = heading * move_speed
			move_and_slide()
			rotation = heading.angle()
			if to_target.length() <= fuse_range and _acquire_delay_left == 0.0:
				_enter(State.FUSE)
				_fuse.rpc(global_position)
		State.FUSE:
			if _state_time >= fuse_time:
				_explode()
		State.DEAD:
			if _state_time >= respawn_delay:
				_respawn.rpc(_home)


func _explode() -> void:
	for pawn: Player in _world.alive_pawns():
		if pawn.global_position.distance_to(global_position) > blast_radius + 12.0:
			continue
		if not _world.blast_clear(global_position, pawn.global_position):
			continue  # walls stop shrapnel — smoke does NOT
		_world.host_damage_player(str(pawn.name).to_int(), blast_damage)
	_world.host_alert_enemies(global_position, global_position, 400.0)
	_boom_fx.rpc()
	_enter(State.DEAD)
	_die.rpc()
	print("[combat] %s exploded" % name)


@rpc("authority", "call_local", "reliable")
func _boom_fx() -> void:
	Game.play_sfx("boom", global_position)


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


func _stream_state() -> void:
	if _state == State.DEAD:
		return
	var tick: int = Engine.get_physics_frames()
	var charging: bool = _state == State.CHASE or _state == State.FUSE
	for peer_id: int in Game.ready_peers:
		if peer_id != 1:
			_sync_motion.rpc_id(peer_id, tick, position, rotation, charging)


# --- replication -------------------------------------------------------------

@rpc("authority", "call_remote", "unreliable")
func _sync_motion(tick: int, remote_position: Vector2, remote_rotation: float, chasing: bool) -> void:
	if tick <= _last_sync_tick:
		return
	_last_sync_tick = tick
	_remote_position = remote_position
	_remote_rotation = remote_rotation
	_remote_chasing = chasing
	if position.distance_to(remote_position) > 200.0:
		position = remote_position
		reset_physics_interpolation()


@rpc("authority", "call_local", "reliable")
func _fuse(at: Vector2) -> void:
	_fusing = true
	_glow.enabled = true
	# Last-chance telegraph at the HOST's authoritative blast position — the
	# remote copy's lerped position can trail by ~50px at this speed.
	var marker := Telegraph.new()
	marker.setup(at, blast_radius, fuse_time)
	_world.add_child(marker)
	_reveal_left = fuse_time + 0.4
	_glow.enabled = true
	var tween := create_tween()
	tween.tween_property(_glow, ^"energy", 2.0, fuse_time)


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
	_reveal_left = 0.6
	_remote_chasing = false
	_fusing = false
	_glow.enabled = false
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
	_fusing = false


@rpc("authority", "call_remote", "reliable")
func _full_sync(hp: int, at: Vector2, is_dead: bool) -> void:
	_health = hp
	_health_bar.set_health(_health, max_health)
	position = at
	_remote_position = at
	reset_physics_interpolation()
	_state = State.DEAD if is_dead else State.IDLE
	set_deferred(&"collision_layer", 0 if is_dead else 4)