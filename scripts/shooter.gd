class_name Shooter
extends CharacterBody2D
## Bandit gunner. HOST-OWNED. Patrols around its post; once it spots you it
## CHASES doggedly — losing it takes longer than losing a Brute (it pursues
## your last seen position for seconds after losing sight) — but it must STOP
## to take every shot, so it bleeds ground on a running target and you can
## eventually shake it. Glow flare telegraphs each shot; slow red projectile
## respects i-frames.

@export var max_health: int = 30
@export var patrol_speed: float = 110.0
@export var chase_speed: float = 210.0  # slower than a player: roots cost it ground
@export var engage_range: float = 300.0  # < camera half-HEIGHT (324): never engages off-screen
@export var alert_range: float = 320.0  # while alerted — still under the off-screen cap
@export var alert_memory_ms: int = 6000
@export var preferred_range: float = 220.0
@export var chase_memory: float = 3.0  # keeps hunting last-seen position this long
@export var fire_interval: float = 1.8
@export var aim_time: float = 0.85  # long, readable stand-still before the shot
@export var post_shot_root: float = 0.55  # and it stays planted after firing
@export var respawn_delay: float = 8.0

var _health: int = 30
var _dead: bool = false
var _dead_time: float = 0.0
var _home := Vector2.ZERO
var _patrol_goal := Vector2.ZERO
var _patrol_wait: float = 0.0
var _patrol_timeout: float = 0.0
var _target_id: int = 0
var _last_seen := Vector2.INF
var _lost_sight_for: float = 0.0
var _acquire_delay_left: float = 0.0
var _stun_left: float = 0.0
var _post_root_left: float = 0.0
var _cooldown_left: float = 1.0
var _aim_left: float = 0.0
var _retarget_left: float = 0.0
var _alert_until_ms: int = 0
var _seen: bool = false
var _vis_poll_left: float = 0.0
var _reveal_left: float = 0.0
var _remote_position := Vector2.ZERO
var _remote_rotation: float = 0.0
var _last_sync_tick: int = -1

@onready var _body: Polygon2D = $Body
@onready var _glow: PointLight2D = $Glow
@onready var _health_bar: HealthBar = $HealthBar
@onready var _world: GameWorld = get_tree().get_first_node_in_group(&"game_world") as GameWorld


func _ready() -> void:
	_glow.texture = Game.glow_texture()
	_home = global_position
	_patrol_goal = global_position
	_health = max_health
	_health_bar.set_health(_health, max_health)
	_vis_poll_left = randf() * 0.1  # stagger visibility polls across enemies


func _process(delta: float) -> void:
	_reveal_left = maxf(0.0, _reveal_left - delta)
	_vis_poll_left -= delta
	if _vis_poll_left <= 0.0:
		_vis_poll_left = 0.1
		_seen = not _dead and _world.sees_point(global_position)
	# Reveal wins even when dead — kills must be seen wherever they happen.
	visible = _reveal_left > 0.0 or (not _dead and _seen)


func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		_run_ai(delta)
		_stream_state()
	elif not _dead:
		var blend: float = 1.0 - exp(-14.0 * delta)
		position = position.lerp(_remote_position, blend)
		rotation = lerp_angle(rotation, _remote_rotation, blend)


## A loud noise nearby — stay on high alert (wider range, instant retarget).
func host_alert(focus: Vector2) -> void:
	_alert_until_ms = Time.get_ticks_msec() + alert_memory_ms
	_retarget_left = 0.0
	if _target_id == 0:
		_last_seen = focus
		_lost_sight_for = 0.0


func host_take_damage(amount: int, attacker: int = 0) -> void:
	if not multiplayer.is_server() or _dead:
		return
	_health = maxi(0, _health - amount)
	_sync_hp.rpc(_health)
	if _health == 0:
		_die.rpc()
		_world.host_record_kill(attacker)
		_world.host_drop_enemy_loot(global_position, 2)
		print("[combat] %s died" % name)


func host_stun(duration: float) -> void:
	if _dead:
		return
	_stun_left = maxf(_stun_left, duration)
	_aim_left = 0.0  # interrupted mid-aim
	_stunned_fx.rpc(duration)


@rpc("authority", "call_local", "reliable")
func _stunned_fx(duration: float) -> void:
	_reveal_left = maxf(_reveal_left, duration)
	var tween := create_tween()
	_body.modulate = Color(1.6, 1.6, 2.2)
	tween.tween_property(_body, ^"modulate", Color.WHITE, duration)


func host_full_sync_to(peer_id: int) -> void:
	_full_sync.rpc_id(peer_id, _health, global_position, _dead)


# --- host AI -----------------------------------------------------------------

func _run_ai(delta: float) -> void:
	if _dead:
		_dead_time += delta
		if _dead_time >= respawn_delay:
			_respawn.rpc()
		return
	if _stun_left > 0.0:
		_stun_left -= delta
		return
	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	_acquire_delay_left = maxf(0.0, _acquire_delay_left - delta)

	# Rooted while aiming AND for a beat after firing — your windows to run.
	if _aim_left > 0.0:
		_aim_left -= delta
		var aim_target: Player = _world.pawn_for(_target_id)
		if aim_target != null and not aim_target.dead:
			rotation = (aim_target.global_position - global_position).angle()
		if _aim_left <= 0.0:
			_fire_at_target()
			_post_root_left = post_shot_root
		return
	if _post_root_left > 0.0:
		_post_root_left -= delta
		return

	var target: Player = _world.pawn_for(_target_id)
	if target != null and not target.dead:
		_hunt(target, delta)
		return
	_target_id = 0
	_patrol(delta)
	_retarget_left -= delta
	if _retarget_left <= 0.0:
		_retarget_left = 0.25
		_target_id = _pick_target()
		if _target_id != 0:
			_acquire_delay_left = 0.5  # grace before the first shot
			_alert_until_ms = Time.get_ticks_msec() + alert_memory_ms
			_lost_sight_for = 0.0
			# Seed last-seen NOW — _hunt can run a frame later without LoS, and
			# pursuing an INF sentinel would NaN-poison position forever.
			var acquired: Player = _world.pawn_for(_target_id)
			if acquired != null:
				_last_seen = acquired.global_position


func _hunt(target: Player, delta: float) -> void:
	var to_target: Vector2 = target.global_position - global_position
	if to_target.length() > alert_range * 2.5:
		_target_id = 0  # dogged, not map-wide: a hard distance leash
		return
	var has_sight: bool = _has_los(target.global_position)
	if has_sight:
		_last_seen = target.global_position
		_lost_sight_for = 0.0
	else:
		if not _last_seen.is_finite():
			_last_seen = target.global_position  # NaN guard, belt-and-braces
		_lost_sight_for += delta
		if _lost_sight_for > chase_memory:
			_target_id = 0  # finally shaken
			return
	# Pursue: the target if visible, else their last seen position.
	var goal: Vector2 = target.global_position if has_sight else _last_seen
	var to_goal: Vector2 = goal - global_position
	if to_goal.length() > (preferred_range if has_sight else 30.0):
		velocity = to_goal.normalized() * chase_speed
		move_and_slide()
		rotation = to_goal.angle()
	elif has_sight:
		rotation = to_target.angle()
	# Take the shot: rooted, telegraphed, range-capped (off-screen rule).
	if has_sight and _cooldown_left == 0.0 and _acquire_delay_left == 0.0 \
			and to_target.length() <= alert_range:
		_aim_left = aim_time
		_cooldown_left = fire_interval
		_windup.rpc()


func _patrol(delta: float) -> void:
	if _patrol_wait > 0.0:
		_patrol_wait -= delta
		return
	_patrol_timeout -= delta
	var to_goal: Vector2 = _patrol_goal - global_position
	if to_goal.length() <= 16.0 or _patrol_timeout <= 0.0:
		_pick_patrol_goal()
		return
	velocity = to_goal.normalized() * patrol_speed
	move_and_slide()
	rotation = to_goal.angle()


func _pick_patrol_goal() -> void:
	# Reject goals inside walls; the timeout above re-rolls goals BEHIND walls
	# (sliding never reaches them) instead of shoving the wall forever.
	for attempt: int in 8:
		var candidate: Vector2 = _home + Vector2.from_angle(randf() * TAU) * (40.0 + randf() * 110.0)
		if not _world.point_in_wall(candidate, 14.0):
			_patrol_goal = candidate
			break
	_patrol_wait = 0.8 + randf() * 1.6
	_patrol_timeout = 4.0


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
	return _world.sight_clear(global_position, point)  # walls + smoke


func _stream_state() -> void:
	if _dead:
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
		Game.play_sfx("hit", global_position)


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
	position = _home
	_remote_position = _home
	reset_physics_interpolation()
	_patrol_goal = _home
	_cooldown_left = 1.0
	_aim_left = 0.0
	_target_id = 0
	_alert_until_ms = 0
	_lost_sight_for = 0.0


@rpc("authority", "call_remote", "reliable")
func _full_sync(hp: int, at: Vector2, is_dead: bool) -> void:
	_health = hp
	_health_bar.set_health(_health, max_health)
	position = at
	_remote_position = at
	reset_physics_interpolation()
	_dead = is_dead
	set_deferred(&"collision_layer", 0 if is_dead else 4)