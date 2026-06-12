class_name Player
extends CharacterBody2D
## One player pawn. The OWNING peer simulates its own movement (split authority:
## clients own their avatars, the host owns the world) and streams position,
## rotation, dodge and running state to everyone else. Health, ammo, and items
## are HOST-owned and arrive via GameWorld RPCs.
##
## QUICK BAR: [1] primary gun (press 1 again to cycle Rifle/SMG/Shotgun),
## [2] medkit (LMB = heal cast), [3] charge laser (LMB = 1s charge, pierces,
## blocked by walls), [4] grenade (press 4 again to cycle Frag/Smoke/Flash,
## LMB throws). R reloads. SHIFT sprints on stamina — and leaves a light trail
## others can see, and enemies can HEAR. Casting slows you (reload least).

const SNAP_DISTANCE: float = 200.0
const MAX_HEALTH: int = 100
const SPAWN_GRACE: float = 2.0
const REMOTE_DODGE_GRACE_MS: int = 120
const HEAL_CAST_TIME: float = 1.4
const RELOAD_CAST_TIME: float = 1.5
const LASER_CHARGE_TIME: float = 1.0
const SPRINT_FACTOR: float = 1.45
const STAMINA_MAX: float = 100.0
const STAMINA_DRAIN: float = 28.0
const STAMINA_REGEN: float = 16.0
const STAMINA_REGEN_DELAY: float = 0.8
const TRAIL_INTERVAL: float = 0.28
const GRENADE_THROW_RANGE: float = 380.0

enum CastKind { NONE, HEAL, RELOAD, LASER }

# All spots verified > enemy aggro/engage ranges (or wall-occluded) — keep it that way.
const SPAWN_SPOTS: Array[Vector2] = [
	Vector2(0, -40), Vector2(-40, 80), Vector2(-100, 0), Vector2(0, -120),
]

@export var move_speed: float = 230.0
@export var dodge_speed: float = 525.0  # -25%: dash covers ~84px now
@export_range(0.05, 0.5) var dodge_duration: float = 0.16
@export var dodge_cooldown: float = 0.9
@export var remote_lerp_rate: float = 14.0

var spawn_slot: int = 0
var dead: bool = false
var active_slot: int = 1
var current_gun: int = 0  # index into Game.GUNS
var grenade_sel: int = 0  # 0 frag / 1 smoke / 2 flash
var latched_count: int = 0  # huggers riding you

var _displayed_hp: int = MAX_HEALTH
# Seeded with the starting kit (matches GameWorld._init_loadout).
var _counts: PackedInt32Array = PackedInt32Array([0, 2, 0, 30, 1, 1, 1])
var _mags: PackedInt32Array = PackedInt32Array([8, 24, 4])
var _reload_pending: bool = false
var _cast_kind: CastKind = CastKind.NONE
var _cast_left: float = 0.0
var _searching: bool = false
var _light_tween: Tween
var _spawn_grace_left: float = 0.0
var _stamina: float = STAMINA_MAX
var _stamina_delay: float = 0.0
var _running: bool = false
var _trail_left: float = 0.0
var _last_aim := Vector2.RIGHT
var _dodge_time_left: float = 0.0
var _dodge_cooldown_left: float = 0.0
var _fire_cooldown_left: float = 0.0
var _dodge_direction := Vector2.ZERO
var _remote_position := Vector2.ZERO
var _remote_rotation: float = 0.0
var _remote_dodging: bool = false
var _remote_running: bool = false
var _remote_dodge_rise_ms: int = -100000
var _has_remote_state: bool = false
var _last_sync_tick: int = -1

@onready var _camera: Camera2D = $Camera2D
@onready var _vision_cone: PointLight2D = $VisionCone
@onready var _glow: PointLight2D = $Glow
@onready var _body: Polygon2D = $Body
@onready var _health_bar: HealthBar = $HealthBar
@onready var _cast_bar: CastBar = $CastBar
@onready var _world: GameWorld = get_tree().get_first_node_in_group(&"game_world") as GameWorld


func _enter_tree() -> void:
	set_multiplayer_authority(str(name).to_int())


func _ready() -> void:
	add_to_group(&"players")
	_vision_cone.texture = Game.cone_texture()
	_glow.texture = Game.glow_texture()
	position = SPAWN_SPOTS[spawn_slot % SPAWN_SPOTS.size()]
	_remote_position = position
	reset_physics_interpolation()
	_health_bar.set_health(_displayed_hp, MAX_HEALTH)
	var is_local: bool = is_multiplayer_authority()
	_camera.enabled = is_local
	if not is_local:
		_body.color = Color(0.55, 0.95, 0.65)
	elif _world != null:
		_refresh_hud()


func _physics_process(delta: float) -> void:
	_spawn_grace_left = maxf(0.0, _spawn_grace_left - delta)
	if dead:
		return
	if is_multiplayer_authority():
		var input: Dictionary = _gather_input()
		_handle_slots(input)
		_apply_movement(input, delta)
		_advance_cast(delta)
		_handle_fire(input, delta)
		_handle_interact(input)
		_apply_dodge_visual(_dodge_time_left > 0.0)
		_emit_trail(delta, _running)
		if _world != null:
			_world.update_stamina(_stamina / STAMINA_MAX)
		var my_id: int = multiplayer.get_unique_id()
		var tick: int = Engine.get_physics_frames()
		for peer_id: int in Game.ready_peers:
			if peer_id != my_id:
				_sync_state.rpc_id(peer_id, tick, position, rotation,
						_dodge_time_left > 0.0, _running)
	else:
		var blend: float = 1.0 - exp(-remote_lerp_rate * delta)
		position = position.lerp(_remote_position, blend)
		rotation = lerp_angle(rotation, _remote_rotation, blend)
		_apply_dodge_visual(_remote_dodging)
		_emit_trail(delta, _remote_running)


func is_invulnerable() -> bool:
	if _spawn_grace_left > 0.0:
		return true
	return dodge_active()


## Dodge i-frames specifically (huggers watch this to get shaken off).
func dodge_active() -> bool:
	if is_multiplayer_authority():
		return _dodge_time_left > 0.0
	var window_ms: int = int(dodge_duration * 1000.0) + REMOTE_DODGE_GRACE_MS
	return Time.get_ticks_msec() - _remote_dodge_rise_ms < window_ms


## The host's hearing check: is this pawn sprinting right now?
func is_running() -> bool:
	return _running if is_multiplayer_authority() else _remote_running


func update_displayed_health(hp: int) -> void:
	var dropped: bool = hp < _displayed_hp
	var rose: bool = hp > _displayed_hp
	_displayed_hp = hp
	_health_bar.set_health(hp, MAX_HEALTH)
	if dropped and hp > 0:
		var tween := create_tween()
		_body.modulate = Color(2.2, 0.55, 0.55)
		tween.tween_property(_body, ^"modulate", Color.WHITE, 0.18)
	elif rose and hp > 0:
		var tween := create_tween()
		_body.modulate = Color(0.6, 2.0, 0.7)
		tween.tween_property(_body, ^"modulate", Color.WHITE, 0.25)
		Game.play_sfx("heal", global_position)


func update_loadout(counts: PackedInt32Array, mags: PackedInt32Array) -> void:
	# duplicate(): on the HOST, call_local passes host truth by reference.
	var mag_rose: bool = current_gun < mags.size() and current_gun < _mags.size() \
			and mags[current_gun] > _mags[current_gun]
	_counts = counts.duplicate()
	_mags = mags.duplicate()
	_reload_pending = false
	if is_multiplayer_authority():
		if mag_rose and _cast_kind == CastKind.RELOAD:
			_cancel_cast()
		_refresh_hud()


func set_searching(value: bool) -> void:
	if _searching == value:
		return
	_searching = value
	if _light_tween != null and _light_tween.is_valid():
		_light_tween.kill()
	_light_tween = create_tween().set_parallel(true)
	_light_tween.tween_property(_vision_cone, ^"energy", 0.3 if value else 1.3, 0.35)
	_light_tween.tween_property(_glow, ^"energy", 0.25 if value else 0.7, 0.35)


func add_latcher(delta_count: int) -> void:
	latched_count = maxi(0, latched_count + delta_count)


func set_dead(value: bool) -> void:
	if dead == value:
		return
	dead = value
	visible = not value
	set_deferred(&"collision_layer", 0 if value else 2)
	if value:
		set_searching(false)
		_cancel_cast()
		latched_count = 0
		if is_multiplayer_authority():
			print("[combat] you died — respawning shortly")


func respawn_to_slot() -> void:
	position = SPAWN_SPOTS[spawn_slot % SPAWN_SPOTS.size()]
	_remote_position = position
	_spawn_grace_left = SPAWN_GRACE
	_stamina = STAMINA_MAX
	_dodge_time_left = 0.0
	_dodge_cooldown_left = 0.0
	_remote_dodging = false
	_remote_dodge_rise_ms = -100000
	latched_count = 0
	reset_physics_interpolation()
	if _camera.enabled:
		_camera.reset_smoothing()


# --- input -------------------------------------------------------------------

func _gather_input() -> Dictionary:
	if Game.auto_walk:
		var to_brute: Vector2 = Vector2(380, -160) - global_position
		return {
			"move": to_brute.normalized() if to_brute.length() > 60.0 else Vector2.ZERO,
			"aim": to_brute, "dodge": false, "sprint": false,
			"fire": true, "fire_pressed": false,
			"interact": false, "reload": false, "bag": false, "slot": 0,
		}
	var slot: int = 0
	for s: int in 4:
		if Input.is_action_just_pressed("slot_%d" % (s + 1)):
			slot = s + 1
	return {
		"move": Input.get_vector(&"move_left", &"move_right", &"move_up", &"move_down"),
		"aim": get_global_mouse_position() - global_position,
		"dodge": Input.is_action_just_pressed(&"dodge"),
		"sprint": Input.is_action_pressed(&"sprint"),
		"fire": Input.is_action_pressed(&"fire"),
		"fire_pressed": Input.is_action_just_pressed(&"fire"),
		"interact": Input.is_action_just_pressed(&"interact"),
		"reload": Input.is_action_just_pressed(&"reload"),
		"bag": Input.is_action_just_pressed(&"bag"),
		"slot": slot,
	}


func _handle_slots(input: Dictionary) -> void:
	var slot: int = input["slot"]
	if slot != 0:
		if slot == active_slot:
			# Re-press cycles within the slot (guns on 1, grenade type on 4).
			if slot == 1:
				current_gun = (current_gun + 1) % Game.GUNS.size()
			elif slot == 4:
				grenade_sel = (grenade_sel + 1) % Game.GRENADES.size()
		else:
			active_slot = slot
			_cancel_cast()
		_refresh_hud()
	if input["reload"]:
		_try_start_reload()
	if input["bag"] and _world != null:
		_world.toggle_bag()


# --- movement ------------------------------------------------------------------

func _apply_movement(input: Dictionary, delta: float) -> void:
	_dodge_cooldown_left = maxf(0.0, _dodge_cooldown_left - delta)
	var move: Vector2 = input["move"]
	var aim: Vector2 = input["aim"]
	if aim.length_squared() > 4.0:
		_last_aim = aim.normalized()
	if input["dodge"] and _dodge_cooldown_left == 0.0:
		_cancel_cast()
		_dodge_time_left = dodge_duration
		_dodge_cooldown_left = dodge_cooldown
		# Options: dash toward the mouse, or along movement (default).
		if Game.dash_to_mouse:
			_dodge_direction = _last_aim
		else:
			_dodge_direction = move.normalized() if move != Vector2.ZERO \
					else Vector2.RIGHT.rotated(rotation)
		Game.play_sfx("dodge", global_position)
	if _dodge_time_left > 0.0:
		_dodge_time_left -= delta
		velocity = _dodge_direction * dodge_speed
		_running = false
	else:
		var speed: float = move_speed
		var busy: bool = _cast_kind != CastKind.NONE or _searching
		# Sprint: shift + stamina + actually moving + hands free.
		var wants_run: bool = input["sprint"] and move != Vector2.ZERO \
				and _stamina > 0.0 and not busy
		if wants_run:
			speed *= SPRINT_FACTOR
			_stamina = maxf(0.0, _stamina - STAMINA_DRAIN * delta)
			_stamina_delay = STAMINA_REGEN_DELAY
		else:
			_stamina_delay = maxf(0.0, _stamina_delay - delta)
			if _stamina_delay == 0.0:
				_stamina = minf(STAMINA_MAX, _stamina + STAMINA_REGEN * delta)
		_running = wants_run
		if _cast_kind == CastKind.RELOAD:
			speed *= 0.7  # reload is a lighter commitment
		elif busy:
			speed *= 0.3
		if latched_count > 0:
			speed *= pow(0.65, latched_count)  # huggers drag you down
		velocity = move * speed
		# The Mother's vacuum: client-side pull (movement is client-owned).
		for node: Node in get_tree().get_nodes_in_group(&"suckers"):
			var mother := node as MotherHugger
			if mother == null or not mother.suction_active:
				continue
			var to_maw: Vector2 = mother.global_position - global_position
			if to_maw.length() <= mother.suck_range:
				velocity += to_maw.normalized() * mother.suck_pull
	move_and_slide()
	if aim.length_squared() > 4.0:
		rotation = aim.angle()


func _emit_trail(delta: float, running: bool) -> void:
	if not running or _world == null:
		return
	_trail_left -= delta
	if _trail_left > 0.0:
		return
	_trail_left = TRAIL_INTERVAL
	var blob := TrailBlob.new()
	blob.position = global_position
	_world.add_child(blob)


# --- casting -------------------------------------------------------------------

func _advance_cast(delta: float) -> void:
	if _cast_kind == CastKind.NONE:
		return
	_cast_left -= delta
	if _cast_left > 0.0:
		return
	var finished: CastKind = _cast_kind
	_cast_kind = CastKind.NONE
	match finished:
		CastKind.HEAL:
			if multiplayer.is_server():
				_world.host_handle_heal(1)
			else:
				_world._request_heal.rpc_id(1)
		CastKind.RELOAD:
			_reload_pending = true
			if multiplayer.is_server():
				_world.host_handle_reload(1, current_gun)
			else:
				_world._request_reload.rpc_id(1, current_gun)
		CastKind.LASER:
			var direction: Vector2 = _last_aim
			if multiplayer.is_server():
				_world.host_handle_laser(1, direction)
			else:
				_world._request_laser.rpc_id(1, direction)


func _start_cast(kind: CastKind, duration: float, color: Color) -> void:
	_cast_kind = kind
	_cast_left = duration
	_cast_bar.start(duration, color)


func _cancel_cast() -> void:
	if _cast_kind == CastKind.NONE:
		return
	_cast_kind = CastKind.NONE
	_cast_bar.stop()


func _try_start_reload() -> void:
	if _cast_kind != CastKind.NONE or _searching or _world == null or _reload_pending:
		return
	var gun: Dictionary = Game.GUNS[current_gun]
	if _mags[current_gun] >= int(gun["mag"]) or _counts[GameWorld.ITEM_AMMO] <= 0:
		return
	_start_cast(CastKind.RELOAD, RELOAD_CAST_TIME, Color(0.55, 0.75, 1.0))


# --- using the active slot --------------------------------------------------------

func _handle_fire(input: Dictionary, delta: float) -> void:
	_fire_cooldown_left = maxf(0.0, _fire_cooldown_left - delta)
	if not input["fire"] or _world == null:
		return
	if input["fire_pressed"]:
		var item: LootItem = _hovered_loot_in_range()
		if item != null:
			if multiplayer.is_server():
				_world.host_request_pickup(1, item.loot_id)
			else:
				_world._request_pickup.rpc_id(1, item.loot_id)
			_fire_cooldown_left = maxf(_fire_cooldown_left, 0.15)
			return
	if _cast_kind != CastKind.NONE or _searching:
		return
	match active_slot:
		1:
			if _fire_cooldown_left > 0.0:
				return
			if _mags[current_gun] <= 0:
				_try_start_reload()
				return
			var aim: Vector2 = input["aim"]
			if aim.length_squared() < 4.0:
				return
			var gun: Dictionary = Game.GUNS[current_gun]
			_fire_cooldown_left = float(gun["interval_ms"]) / 1000.0
			var direction: Vector2 = aim.normalized()
			if multiplayer.is_server():
				_world.host_handle_fire(1, direction, current_gun)
			else:
				_world._request_fire.rpc_id(1, direction, current_gun)
		2:
			if input["fire_pressed"] and _counts[GameWorld.ITEM_MEDKIT] > 0 \
					and _displayed_hp < MAX_HEALTH:
				_start_cast(CastKind.HEAL, HEAL_CAST_TIME, Color(0.45, 0.9, 0.55))
		3:
			if input["fire_pressed"] and _counts[GameWorld.ITEM_AMMO] >= GameWorld.LASER_AMMO_COST:
				_start_cast(CastKind.LASER, LASER_CHARGE_TIME, Color(0.5, 0.9, 1.0))
		4:
			if input["fire_pressed"]:
				var item_type: int = GameWorld.ITEM_FRAG + grenade_sel
				if _counts[item_type] > 0:
					var target: Vector2 = global_position \
							+ (input["aim"] as Vector2).limit_length(GRENADE_THROW_RANGE)
					if multiplayer.is_server():
						_world.host_handle_grenade(1, grenade_sel, target)
					else:
						_world._request_grenade.rpc_id(1, grenade_sel, target)
					_fire_cooldown_left = maxf(_fire_cooldown_left, 0.4)


func _handle_interact(input: Dictionary) -> void:
	if _world == null or not input["interact"]:
		return
	if _cast_kind != CastKind.NONE:
		return
	var nearest: Locker = null
	var nearest_dist: float = Locker.SEARCH_RANGE
	for node: Node in get_tree().get_nodes_in_group(&"lockers"):
		var locker := node as Locker
		if locker == null or not locker.can_search():
			continue
		var dist: float = locker.global_position.distance_to(global_position)
		if dist <= nearest_dist:
			nearest_dist = dist
			nearest = locker
	if nearest == null:
		return
	if multiplayer.is_server():
		nearest.host_request_search(1)
	else:
		nearest._request_search.rpc_id(1)


func _hovered_loot_in_range() -> LootItem:
	var mouse: Vector2 = get_global_mouse_position()
	for node: Node in get_tree().get_nodes_in_group(&"loot"):
		var item := node as LootItem
		if item == null:
			continue
		if mouse.distance_to(item.global_position) <= LootItem.HOVER_RADIUS \
				and item.global_position.distance_to(global_position) <= LootItem.PICKUP_RANGE:
			return item
	return null


# --- HUD ----------------------------------------------------------------------

func _refresh_hud() -> void:
	if _world == null:
		return
	var gun: Dictionary = Game.GUNS[current_gun]
	var slots: Array[String] = [
		"[1] %s %d/%d" % [gun["name"], _mags[current_gun], _counts[GameWorld.ITEM_AMMO]],
		"[2] Medkit ×%d" % _counts[GameWorld.ITEM_MEDKIT],
		"[3] Laser (%d ammo)" % GameWorld.LASER_AMMO_COST,
		"[4] %s ×%d" % [Game.GRENADES[grenade_sel], _counts[GameWorld.ITEM_FRAG + grenade_sel]],
	]
	slots[active_slot - 1] = "▶" + slots[active_slot - 1]
	_world.update_quickbar("   ".join(slots))
	_world.update_backpack("Scrap ×%d · Medkit ×%d · Valuables ×%d · Ammo ×%d · Frag ×%d · Smoke ×%d · Flash ×%d" % [
		_counts[0], _counts[1], _counts[2], _counts[3], _counts[4], _counts[5], _counts[6]])


# --- visuals / replication -------------------------------------------------------

func _apply_dodge_visual(active: bool) -> void:
	if active:
		_body.scale = Vector2(1.3, 0.72)
		_body.self_modulate = Color(1.7, 1.7, 1.9)
	elif _spawn_grace_left > 0.0:
		_body.scale = Vector2.ONE
		_body.self_modulate = Color(1, 1, 1, 0.55)
	else:
		_body.scale = Vector2.ONE
		_body.self_modulate = Color.WHITE


@rpc("authority", "call_remote", "unreliable")
func _sync_state(tick: int, remote_position: Vector2, remote_rotation: float,
		dodging: bool, running: bool) -> void:
	if tick <= _last_sync_tick:
		return
	_last_sync_tick = tick
	_remote_position = remote_position
	_remote_rotation = remote_rotation
	if dodging and not _remote_dodging:
		_remote_dodge_rise_ms = Time.get_ticks_msec()
	_remote_dodging = dodging
	_remote_running = running
	if not _has_remote_state or position.distance_to(remote_position) > SNAP_DISTANCE:
		_has_remote_state = true
		position = remote_position
		rotation = remote_rotation
		reset_physics_interpolation()