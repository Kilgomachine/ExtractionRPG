class_name Player
extends CharacterBody2D
## One player pawn. The OWNING peer simulates its own movement (split authority:
## clients own their avatars, the host owns the world) and streams position,
## rotation, and dodge state to everyone else, who interpolate toward it.
## Health, ammo, and items are HOST-owned and arrive via GameWorld RPCs — this
## script never mutates its own resources. Input-gathering stays separate from
## state-mutation so a later rollback (netfox) retrofit is a refactor.
##
## QUICK BAR: slot 1 = weapon (LMB shoots, costs ammo, R reloads), slot 2 =
## medkit (LMB starts a heal CAST), slots 3-4 reserved. Any cast (heal, reload,
## locker search) slows you to 30% speed — committing is dangerous.

const SNAP_DISTANCE: float = 200.0
const MAX_HEALTH: int = 100
const SPAWN_GRACE: float = 2.0  # post-respawn invulnerability vs spawn camping
# Lag grace: a remote pawn's dodge registers on the host ~RTT late, so the host
# credits the full i-frame window from the flag's rise edge plus this margin.
const REMOTE_DODGE_GRACE_MS: int = 120
const CAST_SPEED_FACTOR: float = 0.3  # casting slows you by 70%
const HEAL_CAST_TIME: float = 1.4
const RELOAD_CAST_TIME: float = 1.5

enum CastKind { NONE, HEAL, RELOAD }

# All spots verified > enemy aggro/engage ranges (or wall-occluded) — keep it that way.
const SPAWN_SPOTS: Array[Vector2] = [
	Vector2(0, -40), Vector2(-40, 80), Vector2(-100, 0), Vector2(0, -120),
]

@export var move_speed: float = 230.0
@export var dodge_speed: float = 700.0
@export_range(0.05, 0.5) var dodge_duration: float = 0.16  # = the i-frame window
@export var dodge_cooldown: float = 0.9
@export var fire_rate: float = 0.3
@export var remote_lerp_rate: float = 14.0

## Assigned by World (host-orchestrated, by join order) before add_child.
var spawn_slot: int = 0
## Host-synced via GameWorld._sync_player_hp — never set locally.
var dead: bool = false
## Quick-bar slot the local player has active (1 weapon, 2 medkit, 3-4 reserved).
var active_slot: int = 1

var _displayed_hp: int = MAX_HEALTH
# Seeded with the starting kit (matches GameWorld._init_loadout) so the HUD
# doesn't flash 0/0 for one RTT before the first authoritative sync arrives.
var _counts: PackedInt32Array = PackedInt32Array([0, 2, 0, 16])  # scrap/medkit/valuable/ammo
var _mag: int = 8
var _reload_pending: bool = false
var _cast_kind: CastKind = CastKind.NONE
var _cast_left: float = 0.0
var _searching: bool = false
var _light_tween: Tween
var _spawn_grace_left: float = 0.0
var _dodge_time_left: float = 0.0
var _dodge_cooldown_left: float = 0.0
var _fire_cooldown_left: float = 0.0
var _dodge_direction := Vector2.ZERO
var _remote_position := Vector2.ZERO
var _remote_rotation: float = 0.0
var _remote_dodging: bool = false
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
	# The node name is the owning peer's id (set by World when spawning).
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
		_body.color = Color(0.55, 0.95, 0.65)  # friends read green
	elif _world != null:
		_refresh_hud()


func _physics_process(delta: float) -> void:
	# Grace runs on every peer's copy (started by the same respawn RPC), so the
	# host's copy of a remote pawn reports it correctly in is_invulnerable().
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
		# Only stream to peers whose world is loaded (host-owned ready list).
		var my_id: int = multiplayer.get_unique_id()
		var tick: int = Engine.get_physics_frames()
		for peer_id: int in Game.ready_peers:
			if peer_id != my_id:
				_sync_state.rpc_id(peer_id, tick, position, rotation, _dodge_time_left > 0.0)
	else:
		var blend: float = 1.0 - exp(-remote_lerp_rate * delta)
		position = position.lerp(_remote_position, blend)
		rotation = lerp_angle(rotation, _remote_rotation, blend)
		_apply_dodge_visual(_remote_dodging)


## True while dodge i-frames are active. The HOST consults this when resolving
## damage: its own pawn reports live state, remote pawns the last-synced flag
## (friend-trust accepted per the architecture).
func is_invulnerable() -> bool:
	if _spawn_grace_left > 0.0:
		return true
	if is_multiplayer_authority():
		return _dodge_time_left > 0.0
	# Remote pawns: credit the full window from the dodge's rise edge — robust
	# to sync staleness and fairer to high-ping clients than the raw flag.
	var window_ms: int = int(dodge_duration * 1000.0) + REMOTE_DODGE_GRACE_MS
	return Time.get_ticks_msec() - _remote_dodge_rise_ms < window_ms


## Called on every peer by GameWorld when the host syncs hp.
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
		_body.modulate = Color(0.6, 2.0, 0.7)  # heal flash
		tween.tween_property(_body, ^"modulate", Color.WHITE, 0.25)


## Called on every peer by GameWorld when the host syncs items/ammo.
func update_loadout(counts: PackedInt32Array, mag: int) -> void:
	# duplicate(): on the HOST, call_local passes the authoritative array by
	# reference — the pawn must never alias (let alone mutate) host truth.
	var mag_rose: bool = mag > _mag
	_counts = counts.duplicate()
	_mag = mag
	_reload_pending = false
	if is_multiplayer_authority():
		# The reload landed — kill any spurious second reload cast started on
		# stale data while the sync was in flight.
		if mag_rose and _cast_kind == CastKind.RELOAD:
			_cancel_cast()
		_refresh_hud()


## Searching a locker is a commitment: your lights drop hard. Friends keep
## their own cones — overwatch becomes their job.
func set_searching(value: bool) -> void:
	if _searching == value:
		return
	_searching = value
	if _light_tween != null and _light_tween.is_valid():
		_light_tween.kill()
	_light_tween = create_tween().set_parallel(true)
	_light_tween.tween_property(_vision_cone, ^"energy", 0.3 if value else 1.3, 0.35)
	_light_tween.tween_property(_glow, ^"energy", 0.25 if value else 0.7, 0.35)


func set_dead(value: bool) -> void:
	if dead == value:
		return
	dead = value
	visible = not value
	set_deferred(&"collision_layer", 0 if value else 2)
	if value:
		set_searching(false)  # death un-dims; the locker cancels host-side
		_cancel_cast()
		if is_multiplayer_authority():
			print("[combat] you died — respawning shortly")


## Called on every peer by GameWorld right before the hp refill on respawn.
func respawn_to_slot() -> void:
	position = SPAWN_SPOTS[spawn_slot % SPAWN_SPOTS.size()]
	_remote_position = position
	_spawn_grace_left = SPAWN_GRACE
	# Death freezes the stream mid-state — clear dodge leftovers on every copy
	# so respawn can't start with stale i-frames or an involuntary dodge burst.
	_dodge_time_left = 0.0
	_dodge_cooldown_left = 0.0
	_remote_dodging = false
	_remote_dodge_rise_ms = -100000
	reset_physics_interpolation()
	if _camera.enabled:
		_camera.reset_smoothing()  # no cross-map glide while already vulnerable


# --- input -------------------------------------------------------------------

func _gather_input() -> Dictionary:
	if Game.auto_walk:
		# Headless harness: march at Brute1's post, guns blazing.
		var to_brute: Vector2 = Vector2(380, -160) - global_position
		return {
			"move": to_brute.normalized() if to_brute.length() > 60.0 else Vector2.ZERO,
			"aim": to_brute,
			"dodge": false,
			"fire": true,
			"fire_pressed": false,
			"interact": false,
			"reload": false,
			"slot": 0,
		}
	var slot: int = 0
	if Input.is_action_just_pressed(&"slot_1"):
		slot = 1
	elif Input.is_action_just_pressed(&"slot_2"):
		slot = 2
	elif Input.is_action_just_pressed(&"slot_3"):
		slot = 3
	elif Input.is_action_just_pressed(&"slot_4"):
		slot = 4
	return {
		"move": Input.get_vector(&"move_left", &"move_right", &"move_up", &"move_down"),
		"aim": get_global_mouse_position() - global_position,
		"dodge": Input.is_action_just_pressed(&"dodge"),
		"fire": Input.is_action_pressed(&"fire"),
		"fire_pressed": Input.is_action_just_pressed(&"fire"),
		"interact": Input.is_action_just_pressed(&"interact"),
		"reload": Input.is_action_just_pressed(&"reload"),
		"slot": slot,
	}


func _handle_slots(input: Dictionary) -> void:
	var slot: int = input["slot"]
	if slot != 0 and slot != active_slot:
		active_slot = slot
		_cancel_cast()  # switching hands interrupts whatever you were doing
		_refresh_hud()
	if input["reload"]:
		_try_start_reload()


# --- movement ------------------------------------------------------------------

func _apply_movement(input: Dictionary, delta: float) -> void:
	_dodge_cooldown_left = maxf(0.0, _dodge_cooldown_left - delta)
	var move: Vector2 = input["move"]
	if input["dodge"] and _dodge_cooldown_left == 0.0:
		_cancel_cast()  # the escape valve interrupts casts
		_dodge_time_left = dodge_duration
		_dodge_cooldown_left = dodge_cooldown
		# Standing still? Dodge toward where you're aiming.
		_dodge_direction = move.normalized() if move != Vector2.ZERO \
				else Vector2.RIGHT.rotated(rotation)
	if _dodge_time_left > 0.0:
		_dodge_time_left -= delta
		velocity = _dodge_direction * dodge_speed
	else:
		var speed: float = move_speed
		if _cast_kind != CastKind.NONE or _searching:
			speed *= CAST_SPEED_FACTOR  # committing slows you by 70%
		velocity = move * speed
	move_and_slide()
	var aim: Vector2 = input["aim"]
	if aim.length_squared() > 4.0:
		rotation = aim.angle()


# --- casting (heal, reload) ----------------------------------------------------

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
			_reload_pending = true  # blocks a stale-data re-cast until sync lands
			if multiplayer.is_server():
				_world.host_handle_reload(1)
			else:
				_world._request_reload.rpc_id(1)


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
	if _mag >= GameWorld.MAG_SIZE or _counts[GameWorld.ITEM_AMMO] <= 0:
		return
	_start_cast(CastKind.RELOAD, RELOAD_CAST_TIME, Color(0.55, 0.75, 1.0))


# --- weapon / medkit use ---------------------------------------------------------

func _handle_fire(input: Dictionary, delta: float) -> void:
	_fire_cooldown_left = maxf(0.0, _fire_cooldown_left - delta)
	if not input["fire"] or _world == null:
		return
	# A fresh click on nearby ground loot is a PICKUP, not a shot.
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
		return  # hands are busy
	match active_slot:
		1:
			if _fire_cooldown_left > 0.0:
				return
			if _mag <= 0:
				_try_start_reload()  # dry click auto-racks a reload
				return
			var aim: Vector2 = input["aim"]
			if aim.length_squared() < 4.0:
				return
			_fire_cooldown_left = fire_rate
			var direction: Vector2 = aim.normalized()
			if multiplayer.is_server():
				_world.host_handle_fire(1, direction)
			else:
				_world._request_fire.rpc_id(1, direction)
		2:
			if input["fire_pressed"] and _counts[GameWorld.ITEM_MEDKIT] > 0 \
					and _displayed_hp < MAX_HEALTH:
				_start_cast(CastKind.HEAL, HEAL_CAST_TIME, Color(0.45, 0.9, 0.55))


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
	var slots: Array[String] = [
		"[1] Rifle %d/%d" % [_mag, _counts[GameWorld.ITEM_AMMO]],
		"[2] Medkit ×%d" % _counts[GameWorld.ITEM_MEDKIT],
		"[3] —",
		"[4] —",
	]
	slots[active_slot - 1] = "▶" + slots[active_slot - 1]
	_world.update_quickbar("   ".join(slots))
	_world.update_backpack("Backpack: Scrap ×%d · Valuables ×%d" %
			[_counts[GameWorld.ITEM_SCRAP], _counts[GameWorld.ITEM_VALUABLE]])


# --- visuals / replication -------------------------------------------------------

func _apply_dodge_visual(active: bool) -> void:
	if active:
		_body.scale = Vector2(1.3, 0.72)
		_body.self_modulate = Color(1.7, 1.7, 1.9)  # i-frame shimmer
	elif _spawn_grace_left > 0.0:
		_body.scale = Vector2.ONE
		_body.self_modulate = Color(1, 1, 1, 0.55)  # translucent = spawn grace
	else:
		_body.scale = Vector2.ONE
		_body.self_modulate = Color.WHITE


# Plain "unreliable" + tick guard: per-pawn freshness without the cross-stream
# drops of a shared sequenced channel. Stale/duplicate packets are ignored.
@rpc("authority", "call_remote", "unreliable")
func _sync_state(tick: int, remote_position: Vector2, remote_rotation: float, dodging: bool) -> void:
	if tick <= _last_sync_tick:
		return
	_last_sync_tick = tick
	_remote_position = remote_position
	_remote_rotation = remote_rotation
	if dodging and not _remote_dodging:
		_remote_dodge_rise_ms = Time.get_ticks_msec()
	_remote_dodging = dodging
	# First packet (late join) or a huge gap: snap, don't glide across the map.
	if not _has_remote_state or position.distance_to(remote_position) > SNAP_DISTANCE:
		_has_remote_state = true
		position = remote_position
		rotation = remote_rotation
		reset_physics_interpolation()