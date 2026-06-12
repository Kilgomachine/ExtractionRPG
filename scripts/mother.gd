class_name MotherHugger
extends CharacterBody2D
## The Mother Hugger. HOST-OWNED boss — nests with a brood of Huggers.
## Giant and fast, INVULNERABLE except while it SUCKS: a periodic vacuum that
## drags nearby players toward its maw (sprint or dash against the pull!) —
## and exposes its glowing weak core to damage. No respawn: kill it once.

enum State { IDLE, CHASE, SUCK, RECOVER, DEAD }

@export var max_health: int = 400
@export var move_speed: float = 240.0
@export var aggro_range: float = 320.0
@export var suck_range: float = 300.0
@export var suck_trigger_range: float = 260.0
@export var suck_duration: float = 2.6
@export var suck_pull: float = 250.0  # vs walk 230 — sprint (333) or dash escapes
@export var chomp_range: float = 48.0
@export var chomp_damage: int = 30
@export var suck_cooldown: float = 6.0
@export var recover_time: float = 1.5

## Read by player pawns on every peer to apply the pull client-side
## (movement is client-owned — the host can't push remote pawns directly).
var suction_active: bool = false

var _state: State = State.IDLE
var _health: int = 400
var _target_id: int = 0
var _state_time: float = 0.0
var _retarget_left: float = 0.0
var _acquire_delay_left: float = 0.0
var _suck_cd_left: float = 3.0
var _chomp_left: float = 0.0
var _seen: bool = false
var _vis_poll_left: float = 0.0
var _reveal_left: float = 0.0
var _remote_position := Vector2.ZERO
var _remote_rotation: float = 0.0
var _last_sync_tick: int = -1

@onready var _body: Polygon2D = $Body
@onready var _core: Polygon2D = $Core
@onready var _glow: PointLight2D = $Glow
@onready var _health_bar: HealthBar = $HealthBar
@onready var _world: GameWorld = get_tree().get_first_node_in_group(&"game_world") as GameWorld


func _ready() -> void:
	add_to_group(&"suckers")
	_glow.texture = Game.glow_texture()
	_health = max_health
	_remote_position = position
	_health_bar.set_health(_health, max_health)
	_core.visible = false
	_vis_poll_left = randf() * 0.1


func _process(delta: float) -> void:
	_reveal_left = maxf(0.0, _reveal_left - delta)
	_vis_poll_left -= delta
	if _vis_poll_left <= 0.0:
		_vis_poll_left = 0.1
		_seen = _state != State.DEAD and _world.sees_point(global_position)
	if suction_active:
		_reveal_left = maxf(_reveal_left, 0.3)  # the suck always shows
		queue_redraw()
	visible = _reveal_left > 0.0 or (_state != State.DEAD and _seen)


func _draw() -> void:
	if not suction_active:
		return
	# The pull radius is unmistakable: filled disc + hard boundary + rings.
	draw_circle(Vector2.ZERO, suck_range, Color(0.85, 0.4, 0.9, 0.10))
	draw_arc(Vector2.ZERO, suck_range, 0.0, TAU, 56, Color(0.95, 0.55, 0.95, 0.85), 3.5)
	var t: float = fposmod(Time.get_ticks_msec() * 0.001, 0.8) / 0.8
	for i: int in 4:
		var ring_t: float = fposmod(t + float(i) / 4.0, 1.0)
		var r: float = suck_range * (1.0 - ring_t)
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 40, Color(0.9, 0.5, 0.9, 0.55 * ring_t), 2.5)


func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		_run_ai(delta)
		_stream_state()
	elif _state != State.DEAD:
		var blend: float = 1.0 - exp(-14.0 * delta)
		position = position.lerp(_remote_position, blend)
		rotation = lerp_angle(rotation, _remote_rotation, blend)


## Invulnerable except while sucking — the maw IS the weakness.
func host_take_damage(amount: int, attacker: int = 0) -> void:
	if not multiplayer.is_server() or _state == State.DEAD:
		return
	if _state != State.SUCK:
		return  # armored shell: shots ping off
	_health = maxi(0, _health - amount)
	_sync_hp.rpc(_health)
	if _health == 0:
		_enter(State.DEAD)
		_die.rpc()
		_world.host_record_kill(attacker)
		_world.host_drop_enemy_loot(global_position, 8)
		print("[combat] %s has fallen" % name)


func host_alert(_focus: Vector2) -> void:
	pass  # the Mother does not startle


func host_stun(_duration: float) -> void:
	pass  # boss: immune to flashbangs


func host_full_sync_to(peer_id: int) -> void:
	_full_sync.rpc_id(peer_id, _health, global_position, _state == State.DEAD)
	if _state == State.SUCK:
		_suck_fx.rpc_id(peer_id, true)


# --- host AI -----------------------------------------------------------------

func _run_ai(delta: float) -> void:
	_suck_cd_left = maxf(0.0, _suck_cd_left - delta)
	_state_time += delta
	match _state:
		State.IDLE:
			_retarget_left -= delta
			if _retarget_left <= 0.0:
				_retarget_left = 0.25
				_target_id = _pick_target()
				if _target_id != 0:
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
			if to_target.length() > aggro_range * 1.6 \
					or not _world.sight_clear(global_position, target.global_position):
				_target_id = 0
				_enter(State.IDLE)
				return
			var heading: Vector2 = _world.steer_dir(global_position, to_target.normalized())
			velocity = heading * move_speed
			move_and_slide()
			rotation = heading.angle()
			if to_target.length() <= suck_trigger_range and _suck_cd_left == 0.0 \
					and _acquire_delay_left == 0.0:
				_enter(State.SUCK)
				_suck_fx.rpc(true)
		State.SUCK:
			_chomp_left -= delta
			if _chomp_left <= 0.0:
				_chomp_left = 0.5
				for pawn: Player in _world.alive_pawns():
					if pawn.global_position.distance_to(global_position) <= chomp_range:
						_world.host_damage_player(str(pawn.name).to_int(), chomp_damage, 0)
			if _state_time >= suck_duration:
				_suck_cd_left = suck_cooldown
				_suck_fx.rpc(false)
				_enter(State.RECOVER)
		State.RECOVER:
			if _state_time >= recover_time:
				_enter(State.CHASE if _target_id != 0 else State.IDLE)
		State.DEAD:
			pass  # bosses stay dead


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
	if position.distance_to(remote_position) > 250.0:
		position = remote_position
		reset_physics_interpolation()


@rpc("authority", "call_local", "reliable")
func _suck_fx(on: bool) -> void:
	suction_active = on
	_core.visible = on  # the weak spot shows only while it feeds
	_glow.enabled = on
	_glow.energy = 1.2 if on else 0.0
	_glow.color = Color(0.95, 0.5, 0.95)
	if on:
		_reveal_left = maxf(_reveal_left, suck_duration)
	queue_redraw()


@rpc("authority", "call_local", "reliable")
func _sync_hp(hp: int) -> void:
	var dropped: bool = hp < _health
	_health = hp
	_health_bar.set_health(_health, max_health)
	if dropped:
		var tween := create_tween()
		_core.modulate = Color(3.0, 1.2, 1.2)
		tween.tween_property(_core, ^"modulate", Color.WHITE, 0.15)
		Game.play_sfx("hit", global_position)


@rpc("authority", "call_local", "reliable")
func _die() -> void:
	_state = State.DEAD
	suction_active = false
	_core.visible = false
	_glow.enabled = false
	_reveal_left = 1.2
	set_deferred(&"collision_layer", 0)
	Game.play_sfx("boom", global_position)


@rpc("authority", "call_remote", "reliable")
func _full_sync(hp: int, at: Vector2, is_dead: bool) -> void:
	_health = hp
	_health_bar.set_health(_health, max_health)
	position = at
	_remote_position = at
	reset_physics_interpolation()
	_state = State.DEAD if is_dead else State.IDLE
	set_deferred(&"collision_layer", 0 if is_dead else 4)