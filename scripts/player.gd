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

@export var move_speed: float = 195.0  # walking is deliberate; SHIFT is speed
@export var dodge_speed: float = 525.0
@export_range(0.05, 0.5) var dodge_duration: float = 0.16
@export var dodge_cooldown: float = 0.15  # no real cooldown — stamina is the cost
@export var dodge_stamina_cost: float = 30.0
@export var remote_lerp_rate: float = 14.0

var spawn_slot: int = 0
var dead: bool = false
var active_slot: int = 1
var equipped_gun: int = -1  # ITEM type of the equipped weapon (host-synced)
var grenade_sel: int = 0  # 0 frag / 1 smoke / 2 flash
var latched_count: int = 0  # huggers riding you

var _displayed_hp: int = MAX_HEALTH
var _displayed_shield: int = 0
# Seeded with the starting kit (matches GameWorld._init_loadout).
var _counts: PackedInt32Array = PackedInt32Array([0, 2, 0, 30, 1, 1, 1, 1, 1, 1, 1])
var _mags: PackedInt32Array = PackedInt32Array([8, 24, 4])
var _shoot_slow_left: float = 0.0
var _recoil := Vector2.ZERO
var _reload_pending: bool = false
var _cast_kind: CastKind = CastKind.NONE
var _cast_left: float = 0.0
var _searching: bool = false
var _light_tween: Tween
var _spawn_grace_left: float = 0.0
var _stamina: float = STAMINA_MAX
var _stamina_delay: float = 0.0
var _charm_left: float = 0.0
var _charm_source: String = ""
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
@onready var _name_tag: NameTag = $NameTag
@onready var _world: GameWorld = get_tree().get_first_node_in_group(&"game_world") as GameWorld


## Shown above the pawn so everyone can tell who is who (hidden on your own).
func set_display_name(value: String) -> void:
	if _name_tag != null:
		_name_tag.set_text(value)
	else:
		_pending_name = value


var _pending_name: String = ""


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
	if not _pending_name.is_empty():
		_name_tag.set_text(_pending_name)
	_name_tag.visible = not is_local  # you know your own name
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
		# Teammates are NOT wallhacks: hidden unless your pawn has line of sight.
		_vis_poll_left -= delta
		if _vis_poll_left <= 0.0:
			_vis_poll_left = 0.1
			visible = not dead and _world != null and _world.sees_point(global_position)


var _vis_poll_left: float = 0.0


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


## Siren song hit us: feet walk toward her, weapons lower. Dash breaks it.
func set_charmed(siren_name: String, duration: float) -> void:
	if not is_multiplayer_authority() or dead:
		return
	_charm_source = siren_name
	_charm_left = duration
	_cancel_cast()
	var tween := create_tween()
	_body.modulate = Color(1.8, 0.8, 1.6)  # swooning pink
	tween.tween_property(_body, ^"modulate", Color.WHITE, duration)


func break_charm_from(siren_name: String) -> void:
	if _charm_source == siren_name:
		_charm_left = 0.0
		_charm_source = ""


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


func update_loadout(counts: PackedInt32Array, mags: PackedInt32Array, equipped: int) -> void:
	# duplicate(): on the HOST, call_local passes host truth by reference.
	var mag_idx: int = GameWorld.mag_index_for(equipped)
	var mag_rose: bool = mag_idx >= 0 and mag_idx < mags.size() and mag_idx < _mags.size() \
			and mags[mag_idx] > _mags[mag_idx]
	var gun_changed: bool = equipped != equipped_gun
	_counts = counts.duplicate()
	_mags = mags.duplicate()
	equipped_gun = equipped
	_reload_pending = false
	if is_multiplayer_authority():
		# Cancel a running reload when the mag fills OR the gun itself changed
		# mid-cast — finishing would request a reload for the WRONG weapon.
		if _cast_kind == CastKind.RELOAD and (mag_rose or gun_changed):
			_cancel_cast()
		_refresh_hud()


## Shield arrives from the host like hp (fire bypasses it server-side).
func update_displayed_shield(value: int) -> void:
	_displayed_shield = value
	_health_bar.set_shield(value, GameWorld.SHIELD_MAX)


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
	# Typing in the console (or any text field) must not drive the pawn —
	# the Input singleton ignores GUI focus, so we gate it ourselves.
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return {
			"move": Vector2.ZERO, "aim": _last_aim, "dodge": false, "sprint": false,
			"fire": false, "fire_pressed": false, "interact": false,
			"reload": false, "bag": false, "slot": 0,
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
		if slot == active_slot and slot == 4:
			grenade_sel = (grenade_sel + 1) % Game.GRENADES.size()  # cycle grenade type
		elif slot != active_slot:
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
	if input["dodge"] and _dodge_cooldown_left == 0.0 and _stamina >= dodge_stamina_cost:
		_stamina -= dodge_stamina_cost  # the dash bill is paid in stamina now
		_stamina_delay = STAMINA_REGEN_DELAY
		_cancel_cast()
		_charm_left = 0.0  # dashing snaps you out of the Siren's trance
		_charm_source = ""
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
		_shoot_slow_left = maxf(0.0, _shoot_slow_left - delta)
		if _shoot_slow_left > 0.0:
			speed *= 0.6  # firing plants your feet for a beat
		if latched_count > 0:
			speed *= pow(0.65, latched_count)  # huggers drag you down
		# Charmed: you SPRINT to her, smitten, weapon already in the dirt.
		_charm_left = maxf(0.0, _charm_left - delta)
		if _charm_left > 0.0:
			var siren: Node2D = _find_charm_source()
			if siren != null:
				move = (siren.global_position - global_position).normalized()
				speed = move_speed * SPRINT_FACTOR
				_running = true
			else:
				_charm_left = 0.0
		velocity = move * speed + _recoil
		_recoil = _recoil.lerp(Vector2.ZERO, 1.0 - exp(-10.0 * delta))
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
				_world.host_handle_reload(1, equipped_gun)
			else:
				_world._request_reload.rpc_id(1, equipped_gun)
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
	var mag_idx: int = GameWorld.mag_index_for(equipped_gun)
	if mag_idx < 0:
		return  # no mag weapon equipped
	var spec: Dictionary = GameWorld.gun_spec(equipped_gun)
	if _mags[mag_idx] >= int(spec["mag"]) or _counts[GameWorld.ITEM_AMMO] <= 0:
		return
	_start_cast(CastKind.RELOAD, RELOAD_CAST_TIME, Color(0.55, 0.75, 1.0))


# --- using the active slot --------------------------------------------------------

func _handle_fire(input: Dictionary, delta: float) -> void:
	_fire_cooldown_left = maxf(0.0, _fire_cooldown_left - delta)
	if not input["fire"] or _world == null:
		return
	# Clicking UI (bag, menu, skill tree) must never discharge a weapon.
	if get_viewport().gui_get_hovered_control() != null:
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
	if _charm_left > 0.0:
		return  # too busy swooning to shoot
	match active_slot:
		1:
			if equipped_gun == -1 or _fire_cooldown_left > 0.0:
				return
			if equipped_gun == GameWorld.ITEM_LASER:
				if input["fire_pressed"] and _counts[GameWorld.ITEM_AMMO] >= GameWorld.LASER_AMMO_COST:
					_start_cast(CastKind.LASER, LASER_CHARGE_TIME, Color(0.5, 0.9, 1.0))
				return
			var mag_idx: int = GameWorld.mag_index_for(equipped_gun)
			if _mags[mag_idx] <= 0:
				_try_start_reload()
				return
			var aim: Vector2 = input["aim"]
			if aim.length_squared() < 4.0:
				return
			var spec: Dictionary = GameWorld.gun_spec(equipped_gun)
			_fire_cooldown_left = float(spec["interval_ms"]) / 1000.0
			_shoot_slow_left = 0.3  # firing plants your feet
			var direction: Vector2 = aim.normalized()
			# Recoil feel: camera punch + body shove, per gun.
			_recoil = -direction * float(spec["knockback"])
			_camera.offset = -direction * float(spec["kick"])
			var kick_tween := create_tween()
			kick_tween.tween_property(_camera, ^"offset", Vector2.ZERO, 0.16)
			if multiplayer.is_server():
				_world.host_handle_fire(1, direction, equipped_gun)
			else:
				_world._request_fire.rpc_id(1, direction, equipped_gun)
		2:
			if input["fire_pressed"] and _counts[GameWorld.ITEM_MEDKIT] > 0 \
					and _displayed_hp < MAX_HEALTH:
				_start_cast(CastKind.HEAL, HEAL_CAST_TIME, Color(0.45, 0.9, 0.55))
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
	# Lockers AND corpses share the search interface (duck-typed group).
	var nearest: Node2D = null
	var nearest_dist: float = Locker.SEARCH_RANGE
	for node: Node in get_tree().get_nodes_in_group(&"lockers"):
		var searchable := node as Node2D
		if searchable == null or not node.has_method(&"can_search") \
				or not bool(node.call(&"can_search")):
			continue
		var dist: float = searchable.global_position.distance_to(global_position)
		if dist <= nearest_dist:
			nearest_dist = dist
			nearest = searchable
	if nearest == null:
		return
	if multiplayer.is_server():
		nearest.call(&"host_request_search", 1)
	else:
		nearest.rpc_id(1, &"_request_search")


func _find_charm_source() -> Node2D:
	for node: Node in get_tree().get_nodes_in_group(&"sirens"):
		if node is Node2D and String(node.name) == _charm_source and node.visible:
			return node as Node2D
	return null


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
	var weapon_text: String = "(no weapon — B to equip)"
	if equipped_gun == GameWorld.ITEM_LASER:
		weapon_text = "Laser (%d ammo)" % GameWorld.LASER_AMMO_COST
	elif equipped_gun != -1:
		var spec: Dictionary = GameWorld.gun_spec(equipped_gun)
		weapon_text = "%s %d/%d" % [spec["name"],
				_mags[GameWorld.mag_index_for(equipped_gun)], _counts[GameWorld.ITEM_AMMO]]
	var slots: Array[String] = [
		"[1] " + weapon_text,
		"[2] Medkit ×%d" % _counts[GameWorld.ITEM_MEDKIT],
		"[3] —",
		"[4] %s ×%d" % [Game.GRENADES[grenade_sel], _counts[GameWorld.ITEM_FRAG + grenade_sel]],
	]
	slots[active_slot - 1] = "▶" + slots[active_slot - 1]
	_world.update_quickbar("   ".join(slots))
	_world.refresh_bag(_counts, equipped_gun)


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