class_name Enemy
extends CharacterBody2D
## "Brute" bandit. HOST-OWNED (authority 1, lives in the world scene): the host
## runs the state machine and resolves damage; clients render streamed position
## and locally-spawned telegraph visuals. Attacks are heavily telegraphed and
## always dodgeable: the slam zone LOCKS where the target stood at windup start.

enum State { IDLE, CHASE, WINDUP, RECOVER, DEAD }

@export var max_health: int = 150
@export var move_speed: float = 100.0  # slow artillery — the slam IS the threat
@export var aggro_range: float = 320.0  # < camera half-HEIGHT (324): no off-screen aggro, ever
@export var slam_range: float = 320.0  # = aggro: casts the moment it sees you
@export var alert_radius_factor: float = 2.0  # slams alert enemies within aggro x this
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
var _alert_pos := Vector2.INF
var _alert_time_left: float = 0.0
var _acquire_delay_left: float = 0.0
var _stun_left: float = 0.0
var _seen: bool = false
var _vis_poll_left: float = 0.0
var _reveal_left: float = 0.0
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
	_vis_poll_left = randf() * 0.1  # stagger visibility polls across enemies


func _process(delta: float) -> void:
	# LoS-gated visibility (all peers): unseen enemies don't render, except
	# for the forced reveal while an attack telegraph is running.
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


## A loud noise nearby (e.g. another Brute's slam) — investigate it.
func host_alert(focus: Vector2) -> void:
	if _state == State.IDLE:
		_alert_pos = focus
		_alert_time_left = 8.0  # timeout so a wedged walker can't stick forever
		_retarget_left = 0.0


## Host-only entry point for taking damage (called by GameWorld on projectile hit).
func host_take_damage(amount: int, attacker: int = 0) -> int:
	if not multiplayer.is_server() or _state == State.DEAD:
		return 0
	if attacker > 0 and _state != State.WINDUP:
		_target_id = attacker  # getting shot IS awareness
		_acquire_delay_left = 0.0
		if _state == State.IDLE:
			_enter(State.CHASE)
	var applied: int = mini(amount, _health)
	_health = maxi(0, _health - amount)
	_sync_hp.rpc(_health)
	if _health == 0:
		_enter(State.DEAD)
		_die.rpc()
		_world.host_record_kill(attacker)
		_world.host_drop_enemy_loot(global_position, 3)
		print("[combat] %s died" % name)
	return applied


## Flashbang etc.: freeze the brain for a while.
func host_stun(duration: float) -> void:
	if _state == State.DEAD:
		return
	if _state == State.WINDUP:
		# Stun CANCELS a charging slam — a frozen telegraph that later lands
		# unannounced would be the unfairest hit in the game.
		_enter(State.RECOVER)
		_slam_cd_left = slam_cooldown * 0.5
	_stun_left = maxf(_stun_left, duration)
	_stunned_fx.rpc(duration)


@rpc("authority", "call_local", "reliable")
func _stunned_fx(duration: float) -> void:
	_reveal_left = maxf(_reveal_left, duration)
	if is_instance_valid(_marker):
		_marker.queue_free()  # cancelled slam takes its telegraph with it
	var tween := create_tween()
	_body.modulate = Color(1.6, 1.6, 2.2)
	tween.tween_property(_body, ^"modulate", Color.WHITE, duration)


## Host-only: push full state to a late joiner.
func host_full_sync_to(peer_id: int) -> void:
	_full_sync.rpc_id(peer_id, _health, global_position, _state == State.DEAD)
	# Mid-windup joiners must still see the danger zone — never an unsignaled hit.
	if _state == State.WINDUP:
		_telegraph.rpc_id(peer_id, _slam_center, slam_radius, maxf(0.05, slam_windup - _state_time))


# --- host AI ---------------------------------------------------------------

func _run_ai(delta: float) -> void:
	if _stun_left > 0.0:
		_stun_left -= delta
		return
	_slam_cd_left = maxf(0.0, _slam_cd_left - delta)
	_state_time += delta
	match _state:
		State.IDLE:
			if _alert_pos.is_finite():
				# Alerted: lumber toward the noise; aggro takes over en route.
				_alert_time_left -= delta
				var to_alert: Vector2 = _alert_pos - global_position
				if _alert_time_left <= 0.0 or to_alert.length() <= 60.0:
					_alert_pos = Vector2.INF
				else:
					velocity = to_alert.normalized() * move_speed
					move_and_slide()
					rotation = to_alert.angle()
			else:
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
					_alert_pos = Vector2.INF
					_acquire_delay_left = 0.5  # grace before the first slam
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
			var heading: Vector2 = _world.steer_dir(global_position, to_target.normalized())
			velocity = heading * move_speed
			move_and_slide()
			rotation = heading.angle()
			if to_target.length() <= slam_range and _slam_cd_left == 0.0 \
					and _acquire_delay_left == 0.0:
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
	return _world.sight_clear(global_position, point)  # walls + smoke


func _resolve_slam() -> void:
	for pawn: Player in _world.alive_pawns():
		if pawn.global_position.distance_to(_slam_center) <= slam_radius + 12.0:
			_world.host_damage_player(str(pawn.name).to_int(), slam_damage)
	_impact.rpc()
	# Slams are LOUD: everything nearby investigates the impact zone.
	_world.host_alert_enemies(global_position, _slam_center, aggro_range * alert_radius_factor)


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
	_slam_center = center  # all peers: the impact SFX plays HERE, not at origin
	# Split-second reveal: the caster shows itself while the attack charges.
	# Glow enabled only for the pulse — an energy-0 light still EATS a light
	# slot toward the 16-per-canvas-item cap; enabled=false does not.
	_reveal_left = windup + 0.35
	_glow.enabled = true
	_glow.texture_scale = 3.0  # big flare so you can LOCATE the artillery
	var tween := create_tween()
	tween.tween_property(_glow, ^"energy", 1.1, windup * 0.8)
	tween.tween_property(_glow, ^"energy", 0.0, 0.3)
	tween.tween_callback(func() -> void:
		_glow.enabled = false
		_glow.texture_scale = 1.6)


@rpc("authority", "call_local", "reliable")
func _impact() -> void:
	var tween := create_tween()
	tween.tween_property(_body, ^"scale", Vector2(1.45, 1.45), 0.05)
	tween.tween_property(_body, ^"scale", Vector2.ONE, 0.2)
	Game.play_sfx("boom", _slam_center)


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
	_reveal_left = 0.6  # the kill is shown even if the corpse was unseen
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
	set_deferred(&"collision_layer", 4)
	_state = State.IDLE
	_state_time = 0.0
	_target_id = 0
	_alert_pos = Vector2.INF


@rpc("authority", "call_remote", "reliable")
func _full_sync(hp: int, at: Vector2, is_dead: bool) -> void:
	_health = hp
	_health_bar.set_health(_health, max_health)
	position = at
	_remote_position = at
	reset_physics_interpolation()
	_state = State.DEAD if is_dead else State.IDLE
	set_deferred(&"collision_layer", 0 if is_dead else 4)
	if is_dead and is_instance_valid(_marker):
		_marker.queue_free()