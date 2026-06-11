class_name Shooter
extends CharacterBody2D
## Small bandit gunner. HOST-OWNED, stationary: holds its post and periodically
## fires a slow, dodgeable projectile at the nearest player in range with line
## of sight. A short glow flare telegraphs each shot.

@export var max_health: int = 30
@export var engage_range: float = 300.0  # < camera half-HEIGHT (324): never engages off-screen
@export var alert_range: float = 320.0  # while alerted — still under the off-screen cap
@export var alert_memory_ms: int = 6000
@export var fire_interval: float = 1.8
@export var aim_time: float = 0.35
@export var respawn_delay: float = 8.0

var _health: int = 30
var _dead: bool = false
var _dead_time: float = 0.0
var _cooldown_left: float = 1.0
var _aim_left: float = 0.0
var _retarget_left: float = 0.0
var _target_id: int = 0
var _alert_until_ms: int = 0
var _seen: bool = false
var _vis_poll_left: float = 0.0
var _reveal_left: float = 0.0
var _remote_rotation: float = 0.0
var _last_sync_tick: int = -1

@onready var _body: Polygon2D = $Body
@onready var _glow: PointLight2D = $Glow
@onready var _health_bar: HealthBar = $HealthBar
@onready var _world: GameWorld = get_tree().get_first_node_in_group(&"game_world") as GameWorld


func _ready() -> void:
	_glow.texture = Game.glow_texture()
	_health = max_health
	_health_bar.set_health(_health, max_health)
	_vis_poll_left = randf() * 0.1  # stagger visibility polls across enemies


func _process(delta: float) -> void:
	# LoS-gated visibility (all peers), with a forced reveal during the windup.
	_reveal_left = maxf(0.0, _reveal_left - delta)
	_vis_poll_left -= delta
	if _vis_poll_left <= 0.0:
		_vis_poll_left = 0.1
		_seen = not _dead and _world.team_sees(global_position)
	# Reveal wins even when dead — kills must be seen wherever they happen.
	visible = _reveal_left > 0.0 or (not _dead and _seen)


func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		_run_ai(delta)
		_stream_state()
	elif not _dead:
		rotation = lerp_angle(rotation, _remote_rotation, 1.0 - exp(-14.0 * delta))


## A loud noise nearby — stay on high alert (wider range, instant retarget).
func host_alert(_focus: Vector2) -> void:
	_alert_until_ms = Time.get_ticks_msec() + alert_memory_ms
	_retarget_left = 0.0


## Host-only entry point for taking damage (called by GameWorld on projectile hit).
func host_take_damage(amount: int) -> void:
	if not multiplayer.is_server() or _dead:
		return
	_health = maxi(0, _health - amount)
	_sync_hp.rpc(_health)
	if _health == 0:
		_die.rpc()
		print("[combat] %s died" % name)


## Host-only: push full state to a late joiner.
func host_full_sync_to(peer_id: int) -> void:
	_full_sync.rpc_id(peer_id, _health, _dead)


# --- host AI -----------------------------------------------------------------

func _run_ai(delta: float) -> void:
	if _dead:
		_dead_time += delta
		if _dead_time >= respawn_delay:
			_respawn.rpc()
		return
	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	if _aim_left > 0.0:
		_aim_left -= delta
		var target: Player = _world.pawn_for(_target_id)
		if target != null and not target.dead:
			rotation = (target.global_position - global_position).angle()
		if _aim_left <= 0.0:
			_fire_at_target()
		return
	if _cooldown_left > 0.0:
		return
	# Throttled like the Brute's retarget — _pick_target raycasts per pawn.
	_retarget_left -= delta
	if _retarget_left > 0.0:
		return
	_retarget_left = 0.25
	_target_id = _pick_target()
	if _target_id != 0:
		# Spotting someone keeps this gunner on alert — it won't shrug off
		# a target that drifts to the range edge for a while.
		_alert_until_ms = Time.get_ticks_msec() + alert_memory_ms
		_aim_left = aim_time
		_cooldown_left = fire_interval
		_windup.rpc()


func _fire_at_target() -> void:
	var target: Player = _world.pawn_for(_target_id)
	if target == null or target.dead:
		return
	if not _has_los(target.global_position):
		return
	# Airtight off-screen rule: never let the muzzle event itself originate
	# beyond what the target could have on screen.
	if global_position.distance_to(target.global_position) > alert_range * 1.15:
		return
	var direction: Vector2 = (target.global_position - global_position).normalized()
	rotation = direction.angle()
	_world.host_fire_enemy_projectile(global_position + direction * 18.0, direction)


func _pick_target() -> int:
	var best_id: int = 0
	var best_dist: float = alert_range if Time.get_ticks_msec() < _alert_until_ms else engage_range
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


func _stream_state() -> void:
	if _dead:
		return
	var tick: int = Engine.get_physics_frames()
	for peer_id: int in Game.ready_peers:
		if peer_id != 1:
			_sync_motion.rpc_id(peer_id, tick, rotation)


# --- replication -------------------------------------------------------------

@rpc("authority", "call_remote", "unreliable")
func _sync_motion(tick: int, remote_rotation: float) -> void:
	if tick <= _last_sync_tick:
		return
	_last_sync_tick = tick
	_remote_rotation = remote_rotation


@rpc("authority", "call_local", "reliable")
func _windup() -> void:
	# Telegraph + reveal: the gunner flares into view while drawing a bead.
	# Glow enabled only for the pulse (energy-0 lights still eat light slots).
	_reveal_left = aim_time + 0.35
	_glow.enabled = true
	var tween := create_tween()
	tween.tween_property(_glow, ^"energy", 1.5, aim_time)
	tween.tween_property(_glow, ^"energy", 0.0, 0.25)
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


@rpc("authority", "call_local", "reliable")
func _die() -> void:
	_dead = true
	_dead_time = 0.0
	_reveal_left = 0.6  # the kill is shown even if the corpse was unseen
	set_deferred(&"collision_layer", 0)


@rpc("authority", "call_local", "reliable")
func _respawn() -> void:
	_dead = false
	_health = max_health
	_health_bar.set_health(_health, max_health)
	set_deferred(&"collision_layer", 4)
	_cooldown_left = 1.0
	_aim_left = 0.0
	_target_id = 0
	_alert_until_ms = 0


@rpc("authority", "call_remote", "reliable")
func _full_sync(hp: int, is_dead: bool) -> void:
	_health = hp
	_health_bar.set_health(_health, max_health)
	_dead = is_dead
	set_deferred(&"collision_layer", 0 if is_dead else 4)