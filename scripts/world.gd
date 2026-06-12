class_name GameWorld
extends Node2D
## Greybox raid map + the HOST-OWNED half of the split-authority model:
## who exists, all damage resolution (friendly fire included), player hp,
## loadouts (guns/ammo/grenades), projectiles, lasers, grenades, fire, smoke,
## the scoreboard, and enemy hearing. Clients render and request.

const PLAYER_SCENE: PackedScene = preload("res://scenes/player.tscn")
const PROJECTILE_SCENE: PackedScene = preload("res://scenes/projectile.tscn")
const MENU_SCENE: String = "res://scenes/main_menu.tscn"
const ENEMY_PROJECTILE_DAMAGE: int = 10
const RESPAWN_SECONDS: float = 3.0
const HEAL_AMOUNT: int = 40
const HEAL_INTERVAL_MS: int = 500
const TEAM_SIGHT_RANGE: float = 560.0
const HEARING_RANGE: float = 380.0

# Item types (indices into a loadout counts array).
const ITEM_SCRAP: int = 0
const ITEM_MEDKIT: int = 1
const ITEM_VALUABLE: int = 2
const ITEM_AMMO: int = 3
const ITEM_FRAG: int = 4
const ITEM_SMOKE: int = 5
const ITEM_FLASH: int = 6
const ITEM_TYPES: int = 7
const AMMO_PER_PICKUP: int = 6
const START_MEDKITS: int = 2
const START_RESERVE: int = 30
const LASER_AMMO_COST: int = 2
const LASER_DAMAGE: int = 30
const LASER_MAX_RANGE: float = 900.0
const FRAG_RADIUS: float = 110.0
const FRAG_DAMAGE: int = 45
const SMOKE_RADIUS: float = 90.0
const SMOKE_DURATION: float = 7.0
const FLASH_RADIUS: float = 160.0
const FLASH_STUN: float = 2.5
# Locker rolls (grenades are rare); enemies drop ammo-heavy loot.
const LOOT_POOL: Array[int] = [0, 0, 1, 1, 2, 2, 3, 3, 3, 4, 5, 6]
const LOOT_POOL_ENEMY: Array[int] = [3, 3, 3, 3, 0, 1, 2]

const FLOOR_COLOR := Color(0.21, 0.215, 0.235)
const WALL_COLOR := Color(0.42, 0.40, 0.37)
const FLOOR_RECT := Rect2(-2200, -1600, 4400, 3200)

const WALL_RECTS: Array[Rect2] = [
	# outer border
	Rect2(-2200, -1600, 4400, 40),
	Rect2(-2200, 1560, 4400, 40),
	Rect2(-2200, -1560, 40, 3120),
	Rect2(2160, -1560, 40, 3120),
	# central compound (the original map)
	Rect2(-500, -380, 320, 40),
	Rect2(-500, -380, 40, 240),
	Rect2(-260, -200, 200, 40),
	Rect2(120, -420, 40, 300),
	Rect2(300, -60, 280, 40),
	Rect2(420, 160, 40, 260),
	Rect2(-560, 220, 260, 40),
	Rect2(-140, 360, 40, 180),
	Rect2(-60, 140, 120, 120),
	# inner ring
	Rect2(700, -560, 40, 260),
	Rect2(740, -560, 220, 40),
	Rect2(820, 180, 240, 40),
	Rect2(600, 520, 40, 240),
	Rect2(160, 600, 280, 40),
	Rect2(-760, 560, 40, 200),
	Rect2(-980, 420, 220, 40),
	Rect2(-980, -200, 260, 40),
	Rect2(-820, -560, 40, 220),
	Rect2(-700, -360, 200, 40),
	Rect2(-200, -680, 360, 40),
	# outer ring (the x4 expansion)
	Rect2(-1900, -1300, 400, 40),
	Rect2(-1900, -1300, 40, 300),
	Rect2(-1540, -1300, 40, 180),
	Rect2(-1900, -860, 300, 40),
	Rect2(-600, -1240, 40, 300),
	Rect2(-300, -1100, 500, 40),
	Rect2(1300, -1300, 40, 400),
	Rect2(1340, -1300, 360, 40),
	Rect2(1500, -940, 300, 40),
	Rect2(1500, -200, 40, 400),
	Rect2(1540, -200, 400, 40),
	Rect2(1540, 160, 260, 40),
	Rect2(1300, 800, 400, 40),
	Rect2(1300, 840, 40, 300),
	Rect2(1660, 1000, 40, 300),
	Rect2(-200, 1100, 500, 40),
	Rect2(-600, 940, 40, 300),
	Rect2(-1700, 800, 40, 400),
	Rect2(-1660, 800, 300, 40),
	Rect2(-1900, 1160, 400, 40),
	Rect2(-1800, -300, 40, 500),
	Rect2(-1760, -300, 300, 40),
	Rect2(-1500, 100, 40, 260),
]

var _spawned_ids: Array[int] = []
var _slots: Dictionary[int, int] = {}
var _next_slot: int = 1
var _player_hp: Dictionary[int, int] = {}
var _loadouts: Dictionary[int, PackedInt32Array] = {}
var _mags: Dictionary[int, PackedInt32Array] = {}  # per-gun magazines
var _stats: Dictionary[int, PackedInt32Array] = {}  # kills, dmg, pkills, deaths
var _names: Dictionary[int, String] = {}
var _fire_ready_at: Dictionary[int, int] = {}
var _heal_ready_at: Dictionary[int, int] = {}
var _next_projectile: int = 0
var _next_loot: int = 0
var _next_fire_zone: int = 0
var _next_grenade: int = 0
var _next_smoke: int = 0
var _hear_left: float = 0.4
var _local_pawn: Player

@onready var _players: Node2D = $Players
@onready var _enemies: Node2D = $Enemies
@onready var _projectiles: Node2D = $Projectiles
@onready var _loot: Node2D = $Loot
@onready var _fires: Node2D = $Fires
@onready var _smokes: Node2D = $Smokes
@onready var _quick_bar: Label = $Hud/QuickBar
@onready var _bag_panel: PanelContainer = $Hud/BagPanel
@onready var _backpack_label: Label = $Hud/BagPanel/Backpack
@onready var _stamina_fill: ColorRect = $Hud/StaminaFill
@onready var _scoreboard: PanelContainer = $Hud/Scoreboard
@onready var _score_label: Label = $Hud/Scoreboard/Scores
@onready var _menu_panel: PanelContainer = $Hud/MenuPanel
@onready var _flash_overlay: ColorRect = $Hud/FlashOverlay


func _enter_tree() -> void:
	add_to_group(&"game_world")


func _ready() -> void:
	_build_map()
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	($Hud/MenuPanel/Menu/Resume as Button).pressed.connect(_close_menu)
	($Hud/MenuPanel/Menu/Leave as Button).pressed.connect(_leave_to_menu)
	var dash_check := $Hud/MenuPanel/Menu/DashCheck as CheckButton
	dash_check.set_pressed_no_signal(Game.dash_to_mouse)
	dash_check.toggled.connect(func(on: bool) -> void: Game.set_dash_to_mouse(on))
	if multiplayer.is_server():
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		_slots[1] = 0
		_local_spawn(1, 0)
		_spawned_ids.append(1)
		_player_hp[1] = Player.MAX_HEALTH
		_stats[1] = PackedInt32Array([0, 0, 0, 0])
		_sync_player_hp.rpc(1, Player.MAX_HEALTH)
		_init_loadout(1)
		host_set_name(1, SteamLobby.persona() if SteamLobby.available else "Host")
	else:
		_request_join.rpc_id(1)
		_register_name.rpc_id(1, SteamLobby.persona() if SteamLobby.available else "Player")


func _process(_delta: float) -> void:
	_scoreboard.visible = Input.is_action_pressed(&"scoreboard")
	if _scoreboard.visible:
		_rebuild_scoreboard()


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	# Enemies HEAR sprinting players.
	_hear_left -= delta
	if _hear_left <= 0.0:
		_hear_left = 0.4
		for pawn: Player in alive_pawns():
			if pawn.is_running():
				host_alert_enemies(pawn.global_position, pawn.global_position, HEARING_RANGE)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		_menu_panel.visible = not _menu_panel.visible
	elif event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).physical_keycode == KEY_F1:
		SteamLobby.invite_friends()


func _close_menu() -> void:
	_menu_panel.visible = false


# --- lookups -------------------------------------------------------------------

func pawn_for(id: int) -> Player:
	return _players.get_node_or_null(str(id)) as Player


func alive_pawns() -> Array[Player]:
	var result: Array[Player] = []
	for child: Node in _players.get_children():
		var pawn := child as Player
		if pawn != null and not pawn.dead:
			result.append(pawn)
	return result


func local_pawn() -> Player:
	if _local_pawn != null and is_instance_valid(_local_pawn):
		return _local_pawn
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var pawn := node as Player
		if pawn != null and pawn.is_multiplayer_authority():
			_local_pawn = pawn
			return pawn
	return null


## Vision is PERSONAL now — each peer sees only what their own pawn can see.
func sees_point(point: Vector2) -> bool:
	var pawn: Player = local_pawn()
	if pawn == null or pawn.dead:
		return false
	if pawn.global_position.distance_to(point) > TEAM_SIGHT_RANGE:
		return false
	return sight_clear(pawn.global_position, point)


## Line of sight: blocked by walls AND smoke clouds.
func sight_clear(from: Vector2, to: Vector2) -> bool:
	var space := get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(from, to, 1)
	if not space.intersect_ray(query).is_empty():
		return false
	for node: Node in get_tree().get_nodes_in_group(&"smoke"):
		var cloud := node as SmokeZone
		if cloud == null:
			continue
		if _segment_hits_circle(from, to, cloud.global_position, cloud.radius * 0.9):
			return false
	return true


func _segment_hits_circle(a: Vector2, b: Vector2, center: Vector2, radius: float) -> bool:
	var closest: Vector2 = Geometry2D.get_closest_point_to_segment(center, a, b)
	return closest.distance_to(center) <= radius


## Host-only: a loud event puts nearby enemies on alert.
func host_alert_enemies(origin: Vector2, focus: Vector2, radius: float) -> void:
	if not multiplayer.is_server():
		return
	for child: Node in _enemies.get_children():
		if child is Node2D and child.has_method(&"host_alert") \
				and (child as Node2D).global_position.distance_to(origin) <= radius:
			child.call(&"host_alert", focus)


# --- join / leave ----------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _request_join() -> void:
	if not multiplayer.is_server():
		return
	var new_id: int = multiplayer.get_remote_sender_id()
	if new_id in _spawned_ids:
		return
	for existing_id: int in _spawned_ids:
		_spawn.rpc_id(new_id, existing_id, _slots[existing_id])
	var slot: int = _next_slot
	_next_slot += 1
	_slots[new_id] = slot
	_spawned_ids.append(new_id)
	_spawn.rpc(new_id, slot)
	_local_spawn(new_id, slot)
	_broadcast_ready_peers()
	_player_hp[new_id] = Player.MAX_HEALTH
	_stats[new_id] = PackedInt32Array([0, 0, 0, 0])
	_sync_player_hp.rpc(new_id, Player.MAX_HEALTH)
	_init_loadout(new_id)
	for existing_id: int in _spawned_ids:
		if existing_id != new_id:
			_sync_player_hp.rpc_id(new_id, existing_id, _player_hp[existing_id])
			_sync_stats.rpc_id(new_id, existing_id, _stats[existing_id])
	for id: int in _names:
		_sync_name.rpc_id(new_id, id, _names[id])
	for child: Node in _enemies.get_children():
		if child.has_method(&"host_full_sync_to"):
			child.call(&"host_full_sync_to", new_id)
	for node: Node in get_tree().get_nodes_in_group(&"lockers"):
		var locker := node as Locker
		if locker != null:
			locker.host_full_sync_to(new_id)
	for child: Node in _loot.get_children():
		var item := child as LootItem
		if item != null and not item.is_queued_for_deletion():
			_spawn_loot.rpc_id(new_id, item.loot_id, item.loot_type, item.position)
	for child: Node in _fires.get_children():
		var zone := child as FireZone
		if zone == null or zone.is_queued_for_deletion():
			continue
		var fire_id: int = int(String(zone.name).trim_prefix("f"))
		if zone.cone:
			_spawn_flame.rpc_id(new_id, fire_id, zone.position, zone.direction,
					zone.radius, zone.half_angle_deg, zone.remaining())
		else:
			_spawn_fire.rpc_id(new_id, fire_id, zone.position, zone.radius, zone.remaining())


@rpc("authority", "call_remote", "reliable")
func _spawn(id: int, slot: int) -> void:
	_local_spawn(id, slot)


@rpc("authority", "call_remote", "reliable")
func _despawn(id: int) -> void:
	_local_despawn(id)


func _local_spawn(id: int, slot: int) -> void:
	if _players.has_node(str(id)):
		return
	var pawn: Player = PLAYER_SCENE.instantiate()
	pawn.name = str(id)
	pawn.spawn_slot = slot
	_players.add_child(pawn)
	print("[world] spawned player %d in slot %d (%d in raid)" % [id, slot, _players.get_child_count()])


func _local_despawn(id: int) -> void:
	var pawn: Node = _players.get_node_or_null(str(id))
	if pawn != null:
		pawn.queue_free()
		print("[world] despawned player %d" % id)


func _on_peer_disconnected(id: int) -> void:
	_spawned_ids.erase(id)
	_player_hp.erase(id)
	_loadouts.erase(id)
	_mags.erase(id)
	_stats.erase(id)
	_names.erase(id)
	_fire_ready_at.erase(id)
	_heal_ready_at.erase(id)
	_despawn.rpc(id)
	_local_despawn(id)
	_broadcast_ready_peers()


func _broadcast_ready_peers() -> void:
	Game.ready_peers = PackedInt32Array(_spawned_ids)
	Game._set_ready_peers.rpc(Game.ready_peers)


func _on_server_disconnected() -> void:
	print("[world] server disconnected — leaving to menu")
	_leave_to_menu()


func _leave_to_menu() -> void:
	Game.leave()
	get_tree().change_scene_to_file(MENU_SCENE)


# --- names & scoreboard ------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _register_name(display_name: String) -> void:
	if multiplayer.is_server():
		host_set_name(multiplayer.get_remote_sender_id(), display_name)


func host_set_name(id: int, display_name: String) -> void:
	_names[id] = display_name.substr(0, 24)
	_sync_name.rpc(id, _names[id])


@rpc("authority", "call_local", "reliable")
func _sync_name(id: int, display_name: String) -> void:
	_names[id] = display_name


@rpc("authority", "call_local", "reliable")
func _sync_stats(id: int, stats: PackedInt32Array) -> void:
	_stats[id] = stats


func host_record_kill(attacker: int) -> void:
	if not multiplayer.is_server() or attacker <= 0 or not _stats.has(attacker):
		return
	_stats[attacker][0] += 1
	_sync_stats.rpc(attacker, _stats[attacker])


func _rebuild_scoreboard() -> void:
	var lines: Array[String] = ["NAME                 KILLS   DMG   PK   DEATHS"]
	for id: int in _stats:
		var s: PackedInt32Array = _stats[id]
		var display: String = _names.get(id, "Player %d" % id)
		if id == multiplayer.get_unique_id():
			display += " (you)"
		lines.append("%-20s %5d %5d %4d %8d" % [display, s[0], s[1], s[2], s[3]])
	_score_label.text = "\n".join(lines)


# --- HUD bridges --------------------------------------------------------------------

func update_quickbar(text: String) -> void:
	_quick_bar.text = text


func update_backpack(text: String) -> void:
	_backpack_label.text = text


func update_stamina(pct: float) -> void:
	_stamina_fill.size.x = 180.0 * clampf(pct, 0.0, 1.0)


func toggle_bag() -> void:
	_bag_panel.visible = not _bag_panel.visible


# --- combat: hp, damage, death -------------------------------------------------------

## The single place player damage is decided. source > 0 = another player (FF).
func host_damage_player(id: int, amount: int, source: int = 0) -> void:
	if not multiplayer.is_server() or not _player_hp.has(id) or _player_hp[id] <= 0:
		return
	var pawn := pawn_for(id)
	if pawn == null:
		return
	if pawn.is_invulnerable():
		return
	_player_hp[id] = maxi(0, _player_hp[id] - amount)
	_sync_player_hp.rpc(id, _player_hp[id])
	if source > 0 and source != id and _stats.has(source):
		_stats[source][1] += amount
		_sync_stats.rpc(source, _stats[source])
	if _player_hp[id] == 0:
		if _stats.has(id):
			_stats[id][3] += 1
			_sync_stats.rpc(id, _stats[id])
		if source > 0 and source != id and _stats.has(source):
			_stats[source][2] += 1
			_sync_stats.rpc(source, _stats[source])
		_schedule_respawn(id)


func _schedule_respawn(id: int) -> void:
	print("[combat] player %d died" % id)
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = RESPAWN_SECONDS
	add_child(timer)
	timer.timeout.connect(_on_respawn_timer.bind(id, timer))
	timer.start()


func _on_respawn_timer(id: int, timer: Timer) -> void:
	timer.queue_free()
	if not multiplayer.is_server() or not _player_hp.has(id) or pawn_for(id) == null:
		return
	_player_respawned.rpc(id)
	_player_hp[id] = Player.MAX_HEALTH
	_sync_player_hp.rpc(id, Player.MAX_HEALTH)
	_init_loadout(id)


@rpc("authority", "call_local", "reliable")
func _sync_player_hp(id: int, hp: int) -> void:
	var pawn := pawn_for(id)
	if pawn == null:
		return
	pawn.update_displayed_health(hp)
	pawn.set_dead(hp <= 0)


@rpc("authority", "call_local", "reliable")
func _player_respawned(id: int) -> void:
	var pawn := pawn_for(id)
	if pawn != null:
		pawn.respawn_to_slot()


# --- loadout -------------------------------------------------------------------------

func _init_loadout(id: int) -> void:
	var counts := PackedInt32Array([0, 0, 0, 0, 0, 0, 0])
	counts[ITEM_MEDKIT] = START_MEDKITS
	counts[ITEM_AMMO] = START_RESERVE
	counts[ITEM_FRAG] = 1
	counts[ITEM_SMOKE] = 1
	counts[ITEM_FLASH] = 1
	_loadouts[id] = counts
	var mags := PackedInt32Array()
	for gun: Dictionary in Game.GUNS:
		mags.append(int(gun["mag"]))
	_mags[id] = mags
	_push_loadout(id)


func _push_loadout(id: int) -> void:
	_sync_loadout.rpc(id, _loadouts[id], _mags[id])


@rpc("authority", "call_local", "reliable")
func _sync_loadout(id: int, counts: PackedInt32Array, mags: PackedInt32Array) -> void:
	var pawn := pawn_for(id)
	if pawn != null:
		pawn.update_loadout(counts, mags)


@rpc("any_peer", "call_remote", "reliable")
func _request_heal() -> void:
	if multiplayer.is_server():
		host_handle_heal(multiplayer.get_remote_sender_id())


func host_handle_heal(id: int) -> void:
	if not multiplayer.is_server() or not _player_hp.has(id) or not _loadouts.has(id):
		return
	if _player_hp[id] <= 0 or _player_hp[id] >= Player.MAX_HEALTH:
		return
	if _loadouts[id][ITEM_MEDKIT] <= 0:
		return
	var now: int = Time.get_ticks_msec()
	if now < int(_heal_ready_at.get(id, 0)):
		return
	_heal_ready_at[id] = now + HEAL_INTERVAL_MS
	_loadouts[id][ITEM_MEDKIT] -= 1
	_player_hp[id] = mini(Player.MAX_HEALTH, _player_hp[id] + HEAL_AMOUNT)
	_sync_player_hp.rpc(id, _player_hp[id])
	_push_loadout(id)


@rpc("any_peer", "call_remote", "reliable")
func _request_reload(gun: int) -> void:
	if multiplayer.is_server():
		host_handle_reload(multiplayer.get_remote_sender_id(), gun)


func host_handle_reload(id: int, gun: int) -> void:
	if not multiplayer.is_server() or not _loadouts.has(id) or _player_hp.get(id, 0) <= 0:
		return
	if gun < 0 or gun >= Game.GUNS.size():
		return
	var mag_size: int = int(Game.GUNS[gun]["mag"])
	var take: int = mini(mag_size - _mags[id][gun], _loadouts[id][ITEM_AMMO])
	if take <= 0:
		return
	_mags[id][gun] += take
	_loadouts[id][ITEM_AMMO] -= take
	_push_loadout(id)


# --- weapons -----------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _request_fire(direction: Vector2, gun: int) -> void:
	if multiplayer.is_server():
		host_handle_fire(multiplayer.get_remote_sender_id(), direction, gun)


func host_handle_fire(id: int, direction: Vector2, gun: int) -> void:
	if not multiplayer.is_server() or not _player_hp.has(id) or _player_hp[id] <= 0:
		return
	if gun < 0 or gun >= Game.GUNS.size():
		return
	var pawn := pawn_for(id)
	if pawn == null or direction == Vector2.ZERO:
		return
	if _mags[id][gun] <= 0:
		return
	var spec: Dictionary = Game.GUNS[gun]
	var now: int = Time.get_ticks_msec()
	if now < int(_fire_ready_at.get(id, 0)):
		return
	_fire_ready_at[id] = now + int(spec["interval_ms"]) - 15  # small lag tolerance
	_mags[id][gun] -= 1
	_push_loadout(id)
	var dir: Vector2 = direction.normalized()
	var pellets: int = int(spec["pellets"])
	var spread: float = deg_to_rad(float(spec["spread_deg"]))
	for i: int in pellets:
		var pellet_dir: Vector2 = dir
		if spread > 0.0:
			pellet_dir = dir.rotated(randf_range(-spread, spread))
		_next_projectile += 1
		_spawn_projectile.rpc(_next_projectile, pawn.global_position + pellet_dir * 22.0,
				pellet_dir, false, int(spec["dmg"]), id)
	_shot_fx.rpc(String(spec["sfx"]), pawn.global_position)


@rpc("authority", "call_local", "reliable")
func _shot_fx(sfx: String, at: Vector2) -> void:
	Game.play_sfx(sfx, at)


## Host-only, called by enemies that shoot.
func host_fire_enemy_projectile(from: Vector2, direction: Vector2) -> void:
	if not multiplayer.is_server():
		return
	_next_projectile += 1
	_spawn_projectile.rpc(_next_projectile, from, direction, true, ENEMY_PROJECTILE_DAMAGE, 0)
	_shot_fx.rpc("shot", from)


@rpc("authority", "call_local", "reliable")
func _spawn_projectile(pid: int, from: Vector2, direction: Vector2, hostile: bool,
		dmg: int, shooter: int) -> void:
	var shot: Projectile = PROJECTILE_SCENE.instantiate()
	shot.name = "p%d" % pid
	shot.setup(from, direction, hostile, dmg, shooter)
	_projectiles.add_child(shot)


@rpc("authority", "call_local", "reliable")
func _despawn_projectile(pid: int) -> void:
	var shot: Node = _projectiles.get_node_or_null("p%d" % pid)
	if shot != null:
		shot.queue_free()


## Host-only. Returns true if the projectile was consumed.
func host_projectile_hit(pid: int, target: Node, hostile: bool, dmg: int, shooter: int) -> bool:
	if not multiplayer.is_server():
		return true
	var pawn := target as Player
	if pawn != null:
		var victim: int = str(pawn.name).to_int()
		if not hostile and victim == shooter:
			return false  # your own bullet doesn't bite you
		if pawn.is_invulnerable():
			print("[combat] player %s phased through a shot" % pawn.name)
			return false
		host_damage_player(victim, dmg, shooter)
	elif target.has_method(&"host_take_damage"):
		target.call(&"host_take_damage", dmg, shooter)
	_despawn_projectile.rpc(pid)
	return true


@rpc("any_peer", "call_remote", "reliable")
func _request_laser(direction: Vector2) -> void:
	if multiplayer.is_server():
		host_handle_laser(multiplayer.get_remote_sender_id(), direction)


func host_handle_laser(id: int, direction: Vector2) -> void:
	if not multiplayer.is_server() or _player_hp.get(id, 0) <= 0 or not _loadouts.has(id):
		return
	if _loadouts[id][ITEM_AMMO] < LASER_AMMO_COST or direction == Vector2.ZERO:
		return
	var pawn := pawn_for(id)
	if pawn == null:
		return
	_loadouts[id][ITEM_AMMO] -= LASER_AMMO_COST
	_push_loadout(id)
	var from: Vector2 = pawn.global_position
	var dir: Vector2 = direction.normalized()
	# Beam stops at the first wall — never through cover.
	var space := get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(from, from + dir * LASER_MAX_RANGE, 1)
	var hit: Dictionary = space.intersect_ray(query)
	var to: Vector2 = from + dir * LASER_MAX_RANGE
	if not hit.is_empty():
		to = hit["position"] as Vector2
	# Pierces EVERYTHING fleshy along the line (friendly fire included).
	for child: Node in _enemies.get_children():
		if child is Node2D and child.has_method(&"host_take_damage") \
				and _near_segment((child as Node2D).global_position, from, to, 18.0):
			child.call(&"host_take_damage", LASER_DAMAGE, id)
	for victim: Player in alive_pawns():
		var vid: int = str(victim.name).to_int()
		if vid != id and _near_segment(victim.global_position, from, to, 16.0):
			host_damage_player(vid, LASER_DAMAGE, id)
	_beam_fx.rpc(from, to)


func _near_segment(point: Vector2, a: Vector2, b: Vector2, margin: float) -> bool:
	return Geometry2D.get_closest_point_to_segment(point, a, b).distance_to(point) <= margin


@rpc("authority", "call_local", "reliable")
func _beam_fx(from: Vector2, to: Vector2) -> void:
	var beam := BeamFx.new()
	beam.setup(from, to)
	add_child(beam)
	Game.play_sfx("laser", from)


# --- grenades ------------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _request_grenade(type: int, target: Vector2) -> void:
	if multiplayer.is_server():
		host_handle_grenade(multiplayer.get_remote_sender_id(), type, target)


func host_handle_grenade(id: int, type: int, target: Vector2) -> void:
	if not multiplayer.is_server() or _player_hp.get(id, 0) <= 0 or not _loadouts.has(id):
		return
	if type < 0 or type > 2:
		return
	var item_type: int = ITEM_FRAG + type
	if _loadouts[id][item_type] <= 0:
		return
	var pawn := pawn_for(id)
	if pawn == null:
		return
	var clamped: Vector2 = pawn.global_position \
			+ (target - pawn.global_position).limit_length(Player.GRENADE_THROW_RANGE)
	_loadouts[id][item_type] -= 1
	_push_loadout(id)
	_next_grenade += 1
	_spawn_grenade.rpc(_next_grenade, type, id, pawn.global_position, clamped)


@rpc("authority", "call_local", "reliable")
func _spawn_grenade(gid: int, type: int, thrower: int, from: Vector2, to: Vector2) -> void:
	var nade := Grenade.new()
	nade.name = "g%d" % gid
	nade.setup(gid, type, thrower, from, to)
	add_child(nade)


## Host-only — called by the host's grenade copy when its fuse ends.
func host_resolve_grenade(_gid: int, type: int, thrower: int, at: Vector2) -> void:
	if not multiplayer.is_server():
		return
	match type:
		0:  # frag
			for child: Node in _enemies.get_children():
				if child is Node2D and child.has_method(&"host_take_damage") \
						and (child as Node2D).global_position.distance_to(at) <= FRAG_RADIUS \
						and sight_clear(at, (child as Node2D).global_position):
					child.call(&"host_take_damage", FRAG_DAMAGE, thrower)
			for victim: Player in alive_pawns():
				if victim.global_position.distance_to(at) <= FRAG_RADIUS \
						and sight_clear(at, victim.global_position):
					host_damage_player(str(victim.name).to_int(), FRAG_DAMAGE, thrower)
			_boom_fx.rpc(at)
		1:  # smoke
			_next_smoke += 1
			_spawn_smoke.rpc(_next_smoke, at)
		2:  # flash
			for child: Node in _enemies.get_children():
				if child is Node2D and child.has_method(&"host_stun") \
						and (child as Node2D).global_position.distance_to(at) <= FLASH_RADIUS + 10.0 \
						and sight_clear(at, (child as Node2D).global_position):
					child.call(&"host_stun", FLASH_STUN)
			var blinded := PackedInt32Array()
			for victim: Player in alive_pawns():
				if victim.global_position.distance_to(at) <= FLASH_RADIUS \
						and sight_clear(at, victim.global_position):
					blinded.append(str(victim.name).to_int())
			_flash_fx.rpc(at, blinded)


@rpc("authority", "call_local", "reliable")
func _boom_fx(at: Vector2) -> void:
	var flash := Telegraph.new()
	flash.setup(at, FRAG_RADIUS, 0.05)
	add_child(flash)
	Game.play_sfx("boom", at)


@rpc("authority", "call_local", "reliable")
func _spawn_smoke(sid: int, at: Vector2) -> void:
	var cloud := SmokeZone.new()
	cloud.name = "s%d" % sid
	cloud.setup(at, SMOKE_RADIUS, SMOKE_DURATION)
	_smokes.add_child(cloud)


@rpc("authority", "call_local", "reliable")
func _flash_fx(at: Vector2, blinded: PackedInt32Array) -> void:
	Game.play_sfx("flash", at)
	if multiplayer.get_unique_id() in blinded:
		_flash_overlay.modulate.a = 1.0
		var tween := create_tween()
		tween.tween_property(_flash_overlay, ^"modulate:a", 0.0, 1.5)


# --- fire zones ------------------------------------------------------------------------

func host_spawn_fire(at: Vector2, radius: float, duration: float) -> void:
	if not multiplayer.is_server():
		return
	_next_fire_zone += 1
	_spawn_fire.rpc(_next_fire_zone, at, radius, duration)


func host_spawn_flame_cone(origin: Vector2, dir_angle: float, fire_range: float,
		half_deg: float, duration: float) -> void:
	if not multiplayer.is_server():
		return
	_next_fire_zone += 1
	_spawn_flame.rpc(_next_fire_zone, origin, dir_angle, fire_range, half_deg, duration)


@rpc("authority", "call_local", "reliable")
func _spawn_fire(fire_id: int, at: Vector2, radius: float, duration: float) -> void:
	if _fires.has_node("f%d" % fire_id):
		return
	var zone := FireZone.new()
	zone.name = "f%d" % fire_id
	zone.setup(at, radius, duration)
	_fires.add_child(zone)


@rpc("authority", "call_local", "reliable")
func _spawn_flame(fire_id: int, origin: Vector2, dir_angle: float, fire_range: float,
		half_deg: float, duration: float) -> void:
	if _fires.has_node("f%d" % fire_id):
		return
	var zone := FireZone.new()
	zone.name = "f%d" % fire_id
	zone.setup_cone(origin, dir_angle, fire_range, half_deg, duration)
	_fires.add_child(zone)
	Game.play_sfx("flame", origin)


# --- loot -----------------------------------------------------------------------------

func host_spawn_locker_loot(at: Vector2) -> void:
	if not multiplayer.is_server():
		return
	var count: int = 2 + (randi() % 2)
	for i: int in count:
		_next_loot += 1
		_spawn_loot.rpc(_next_loot, LOOT_POOL[randi() % LOOT_POOL.size()], _scatter_point(at))


## Enemies drop loot too (ammo-heavy pool).
func host_drop_enemy_loot(at: Vector2, count: int) -> void:
	if not multiplayer.is_server():
		return
	for i: int in count:
		_next_loot += 1
		_spawn_loot.rpc(_next_loot, LOOT_POOL_ENEMY[randi() % LOOT_POOL_ENEMY.size()],
				_scatter_point(at))


func _scatter_point(center: Vector2) -> Vector2:
	for attempt: int in 8:
		var candidate: Vector2 = center + Vector2.RIGHT.rotated(randf() * TAU) * (26.0 + randf() * 18.0)
		if not _inside_any_wall(candidate, 10.0):
			return candidate
	return center


## Public geometry helper for AI goal validation etc.
func point_in_wall(point: Vector2, margin: float) -> bool:
	return _inside_any_wall(point, margin)


func _inside_any_wall(point: Vector2, margin: float) -> bool:
	for rect: Rect2 in WALL_RECTS:
		if rect.grow(margin).has_point(point):
			return true
	return false


@rpc("any_peer", "call_remote", "reliable")
func _request_pickup(loot_id: int) -> void:
	if multiplayer.is_server():
		host_request_pickup(multiplayer.get_remote_sender_id(), loot_id)


func host_request_pickup(player_id: int, loot_id: int) -> void:
	if not multiplayer.is_server():
		return
	var item := _loot.get_node_or_null("l%d" % loot_id) as LootItem
	var pawn := pawn_for(player_id)
	if item == null or item.is_queued_for_deletion() or pawn == null or pawn.dead:
		return
	if pawn.global_position.distance_to(item.global_position) > 100.0:
		return
	if not _loadouts.has(player_id):
		return
	var gain: int = AMMO_PER_PICKUP if item.loot_type == ITEM_AMMO else 1
	_loadouts[player_id][item.loot_type] += gain
	_push_loadout(player_id)
	print("[loot] player %d picked up %s (+%d)" % [player_id, item.display_name(), gain])
	_despawn_loot.rpc(loot_id)


@rpc("authority", "call_local", "reliable")
func _spawn_loot(loot_id: int, loot_type: int, at: Vector2) -> void:
	if _loot.has_node("l%d" % loot_id):
		return
	var item := LootItem.new()
	item.name = "l%d" % loot_id
	item.setup(loot_id, loot_type, at)
	_loot.add_child(item)


@rpc("authority", "call_local", "reliable")
func _despawn_loot(loot_id: int) -> void:
	var item: Node = _loot.get_node_or_null("l%d" % loot_id)
	if item != null:
		item.queue_free()


# --- greybox map -------------------------------------------------------------------------

func _build_map() -> void:
	# Floor as 6x4 chunks — the 16-lights-per-canvas-item cap applies per area.
	var cell: Vector2 = Vector2(FLOOR_RECT.size.x / 6.0, FLOOR_RECT.size.y / 4.0)
	for ix: int in 6:
		for iy: int in 4:
			var quad := Polygon2D.new()
			var origin: Vector2 = FLOOR_RECT.position + Vector2(ix * cell.x, iy * cell.y)
			quad.polygon = PackedVector2Array([
				origin, origin + Vector2(cell.x, 0),
				origin + cell, origin + Vector2(0, cell.y),
			])
			quad.color = FLOOR_COLOR
			quad.z_index = -10
			add_child(quad)
	for rect: Rect2 in WALL_RECTS:
		var body := StaticBody2D.new()
		body.position = rect.get_center()
		var shape := CollisionShape2D.new()
		var rect_shape := RectangleShape2D.new()
		rect_shape.size = rect.size
		shape.shape = rect_shape
		body.add_child(shape)
		var visual := Polygon2D.new()
		var vh: Vector2 = rect.size * 0.5
		visual.polygon = PackedVector2Array([
			Vector2(-vh.x, -vh.y), Vector2(vh.x, -vh.y),
			Vector2(vh.x, vh.y), Vector2(-vh.x, vh.y),
		])
		visual.color = WALL_COLOR
		visual.z_index = -9
		body.add_child(visual)
		var occluder := LightOccluder2D.new()
		var poly := OccluderPolygon2D.new()
		# Inset (4px) so a lit wall rim catches the cone without big light leaks.
		var half: Vector2 = (rect.size * 0.5) - Vector2(4, 4)
		half = half.max(Vector2(2, 2))
		poly.polygon = PackedVector2Array([
			Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
			Vector2(half.x, half.y), Vector2(-half.x, half.y),
		])
		occluder.occluder = poly
		body.add_child(occluder)
		add_child(body)