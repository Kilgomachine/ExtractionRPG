class_name GameWorld
extends Node2D
## Greybox raid map + the HOST-OWNED half of the split-authority model:
## who exists (spawn/despawn), all damage resolution, player hp, projectiles.
## Clients render and request; the host adjudicates and broadcasts.
## Join-in-progress is allowed here for testing ease — real raids are
## lobby-locked per the roadmap.

const PLAYER_SCENE: PackedScene = preload("res://scenes/player.tscn")
const PROJECTILE_SCENE: PackedScene = preload("res://scenes/projectile.tscn")
const MENU_SCENE: String = "res://scenes/main_menu.tscn"
const PROJECTILE_DAMAGE: int = 12
const ENEMY_PROJECTILE_DAMAGE: int = 10
const FIRE_INTERVAL_MS: int = 280
const RESPAWN_SECONDS: float = 3.0
const HEAL_AMOUNT: int = 40
const HEAL_INTERVAL_MS: int = 500

# Item types (indices into a loadout counts array) + weapon constants.
const ITEM_SCRAP: int = 0
const ITEM_MEDKIT: int = 1
const ITEM_VALUABLE: int = 2
const ITEM_AMMO: int = 3
const MAG_SIZE: int = 8
const AMMO_PER_PICKUP: int = 6
const START_MEDKITS: int = 2
const START_RESERVE: int = 16
# Locker roll weights: scrap, medkit, valuables, ammo (ammo drops "sometimes").
const LOOT_POOL: Array[int] = [0, 0, 0, 1, 1, 2, 2, 3, 3, 3]
const TEAM_SIGHT_RANGE: float = 560.0
const FLOOR_COLOR := Color(0.21, 0.215, 0.235)
const WALL_COLOR := Color(0.42, 0.40, 0.37)
const FLOOR_RECT := Rect2(-1100, -800, 2200, 1600)

# Greybox layout, Rect2(x, y, w, h) in world units.
const WALL_RECTS: Array[Rect2] = [
	# outer border
	Rect2(-1100, -800, 2200, 40),
	Rect2(-1100, 760, 2200, 40),
	Rect2(-1100, -760, 40, 1520),
	Rect2(1060, -760, 40, 1520),
	# central buildings / cover (original layout)
	Rect2(-500, -380, 320, 40),
	Rect2(-500, -380, 40, 240),
	Rect2(-260, -200, 200, 40),
	Rect2(120, -420, 40, 300),
	Rect2(300, -60, 280, 40),
	Rect2(420, 160, 40, 260),
	Rect2(-560, 220, 260, 40),
	Rect2(-140, 360, 40, 180),
	Rect2(-60, 140, 120, 120),
	# expansion ring
	Rect2(700, -560, 40, 260),     # NE corner room
	Rect2(740, -560, 220, 40),
	Rect2(820, 180, 240, 40),      # E
	Rect2(600, 520, 40, 240),      # SE
	Rect2(160, 600, 280, 40),      # S
	Rect2(-760, 560, 40, 200),     # SW
	Rect2(-980, 420, 220, 40),
	Rect2(-980, -200, 260, 40),    # W
	Rect2(-820, -560, 40, 220),    # NW
	Rect2(-700, -360, 200, 40),
	Rect2(-200, -680, 360, 40),    # N
]

var _spawned_ids: Array[int] = []
var _slots: Dictionary[int, int] = {}  # peer id -> spawn slot (host-assigned)
var _next_slot: int = 1
var _player_hp: Dictionary[int, int] = {}  # host-owned truth
var _loadouts: Dictionary[int, PackedInt32Array] = {}  # host-owned item counts
var _mags: Dictionary[int, int] = {}  # host-owned bullets in the magazine
var _fire_ready_at: Dictionary[int, int] = {}  # peer id -> Time.get_ticks_msec gate
var _heal_ready_at: Dictionary[int, int] = {}
var _next_projectile: int = 0
var _next_loot: int = 0
var _next_fire_zone: int = 0

@onready var _players: Node2D = $Players
@onready var _enemies: Node2D = $Enemies
@onready var _projectiles: Node2D = $Projectiles
@onready var _loot: Node2D = $Loot
@onready var _fires: Node2D = $Fires
@onready var _quick_bar: Label = $Hud/QuickBar
@onready var _backpack_label: Label = $Hud/Backpack


func _enter_tree() -> void:
	# Group set before children _ready so pawns/enemies can resolve us.
	add_to_group(&"game_world")


func _ready() -> void:
	_build_map()
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	if multiplayer.is_server():
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		_slots[1] = 0
		_local_spawn(1, 0)
		_spawned_ids.append(1)
		_player_hp[1] = Player.MAX_HEALTH
		_sync_player_hp.rpc(1, Player.MAX_HEALTH)
		_init_loadout(1)
	else:
		# Our scene is loaded and ready to receive spawns — tell the host.
		_request_join.rpc_id(1)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		_leave_to_menu()
	elif event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).physical_keycode == KEY_F1:
		SteamLobby.invite_friends()


# --- lookups used by pawns, enemies, projectiles ----------------------------

func pawn_for(id: int) -> Player:
	return _players.get_node_or_null(str(id)) as Player


func alive_pawns() -> Array[Player]:
	var result: Array[Player] = []
	for child: Node in _players.get_children():
		var pawn := child as Player
		if pawn != null and not pawn.dead:
			result.append(pawn)
	return result


## True if any living team member has line of sight to the point.
## Drives client-side enemy visibility (vision is shared between friends).
func team_sees(point: Vector2) -> bool:
	var space := get_world_2d().direct_space_state
	for pawn: Player in alive_pawns():
		if pawn.global_position.distance_to(point) > TEAM_SIGHT_RANGE:
			continue
		var query := PhysicsRayQueryParameters2D.create(pawn.global_position, point, 1)
		if space.intersect_ray(query).is_empty():
			return true
	return false


## Host-only: a loud event (Brute slam) puts nearby enemies on alert.
func host_alert_enemies(origin: Vector2, focus: Vector2, radius: float) -> void:
	if not multiplayer.is_server():
		return
	for child: Node in _enemies.get_children():
		if child is Node2D and child.has_method(&"host_alert") \
				and (child as Node2D).global_position.distance_to(origin) <= radius:
			child.call(&"host_alert", focus)


# --- join / leave orchestration (host decides who exists) -------------------

## A client's world is loaded; only the host acts on this.
@rpc("any_peer", "call_remote", "reliable")
func _request_join() -> void:
	if not multiplayer.is_server():
		return
	var new_id: int = multiplayer.get_remote_sender_id()
	if new_id in _spawned_ids:
		return
	# The newcomer first learns about everyone already in the raid...
	for existing_id: int in _spawned_ids:
		_spawn.rpc_id(new_id, existing_id, _slots[existing_id])
	# ...then everyone spawns the newcomer (host assigns the slot by join order).
	var slot: int = _next_slot
	_next_slot += 1
	_slots[new_id] = slot
	_spawned_ids.append(new_id)
	_spawn.rpc(new_id, slot)
	_local_spawn(new_id, slot)
	_broadcast_ready_peers()
	# Combat state for the newcomer: everyone's hp + every enemy's state.
	_player_hp[new_id] = Player.MAX_HEALTH
	_sync_player_hp.rpc(new_id, Player.MAX_HEALTH)
	_init_loadout(new_id)
	for existing_id: int in _spawned_ids:
		if existing_id != new_id:
			_sync_player_hp.rpc_id(new_id, existing_id, _player_hp[existing_id])
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
	# Active fire zones still burning — the joiner must SEE what can hurt them.
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


# --- combat: host-owned damage, hp, death/respawn ---------------------------

## Host-only. The single place player damage is decided — including i-frames.
func host_damage_player(id: int, amount: int) -> void:
	if not multiplayer.is_server() or not _player_hp.has(id) or _player_hp[id] <= 0:
		return
	var pawn := pawn_for(id)
	if pawn == null:
		return
	if pawn.is_invulnerable():
		print("[combat] player %d i-framed the hit" % id)
		return
	_player_hp[id] = maxi(0, _player_hp[id] - amount)
	_sync_player_hp.rpc(id, _player_hp[id])
	if _player_hp[id] == 0:
		_schedule_respawn(id)


func _schedule_respawn(id: int) -> void:
	print("[combat] player %d died" % id)
	# A child Timer (not an awaited SceneTreeTimer) dies with the world —
	# no coroutine resuming on a freed instance if the host quits mid-respawn.
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
	_init_loadout(id)  # fresh kit each life (gear-loss placeholder)


# --- loadout: backpack items + weapon magazine (host-owned truth) --------------

func _init_loadout(id: int) -> void:
	var counts := PackedInt32Array([0, 0, 0, 0])
	counts[ITEM_MEDKIT] = START_MEDKITS
	counts[ITEM_AMMO] = START_RESERVE
	_loadouts[id] = counts
	_mags[id] = MAG_SIZE
	_push_loadout(id)


func _push_loadout(id: int) -> void:
	_sync_loadout.rpc(id, _loadouts[id], _mags[id])


@rpc("authority", "call_local", "reliable")
func _sync_loadout(id: int, counts: PackedInt32Array, mag: int) -> void:
	var pawn := pawn_for(id)
	if pawn != null:
		pawn.update_loadout(counts, mag)


## HUD bridges (called by the LOCAL pawn).
func update_quickbar(text: String) -> void:
	_quick_bar.text = text


func update_backpack(text: String) -> void:
	_backpack_label.text = text


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
func _request_reload() -> void:
	if multiplayer.is_server():
		host_handle_reload(multiplayer.get_remote_sender_id())


func host_handle_reload(id: int) -> void:
	if not multiplayer.is_server() or not _loadouts.has(id) or _player_hp.get(id, 0) <= 0:
		return
	var take: int = mini(MAG_SIZE - int(_mags.get(id, 0)), _loadouts[id][ITEM_AMMO])
	if take <= 0:
		return
	_mags[id] += take
	_loadouts[id][ITEM_AMMO] -= take
	_push_loadout(id)


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


# --- combat: projectiles (host-simulated, rendered everywhere) ---------------

@rpc("any_peer", "call_remote", "reliable")
func _request_fire(direction: Vector2) -> void:
	if not multiplayer.is_server():
		return
	host_handle_fire(multiplayer.get_remote_sender_id(), direction)


func host_handle_fire(id: int, direction: Vector2) -> void:
	if not multiplayer.is_server() or not _player_hp.has(id) or _player_hp[id] <= 0:
		return
	var pawn := pawn_for(id)
	if pawn == null or direction == Vector2.ZERO:
		return
	if int(_mags.get(id, 0)) <= 0:
		return  # dry — the client should be reloading
	var now: int = Time.get_ticks_msec()
	if now < int(_fire_ready_at.get(id, 0)):
		return
	_fire_ready_at[id] = now + FIRE_INTERVAL_MS
	_mags[id] -= 1
	_push_loadout(id)
	var dir: Vector2 = direction.normalized()
	_next_projectile += 1
	_spawn_projectile.rpc(_next_projectile, pawn.global_position + dir * 22.0, dir, false)


@rpc("authority", "call_local", "reliable")
func _spawn_projectile(pid: int, from: Vector2, direction: Vector2, hostile: bool) -> void:
	var shot: Projectile = PROJECTILE_SCENE.instantiate()
	shot.name = "p%d" % pid
	shot.setup(from, direction, hostile)
	_projectiles.add_child(shot)


@rpc("authority", "call_local", "reliable")
func _despawn_projectile(pid: int) -> void:
	var shot: Node = _projectiles.get_node_or_null("p%d" % pid)
	if shot != null:
		shot.queue_free()


## Host-only, called by enemies that shoot.
func host_fire_enemy_projectile(from: Vector2, direction: Vector2) -> void:
	if not multiplayer.is_server():
		return
	_next_projectile += 1
	_spawn_projectile.rpc(_next_projectile, from, direction, true)


## Host-only, called by a projectile when it overlaps something solid.
## Returns true if the projectile was consumed (false = it phases through).
func host_projectile_hit(pid: int, target: Node, hostile: bool) -> bool:
	if not multiplayer.is_server():
		return true
	if hostile:
		var pawn := target as Player
		if pawn != null:
			if pawn.is_invulnerable():
				# Dodge fantasy: you roll THROUGH bullets — they stay live
				# for anyone behind you, not absorbed by your i-frames.
				print("[combat] player %s phased through a shot" % pawn.name)
				return false
			host_damage_player(str(pawn.name).to_int(), ENEMY_PROJECTILE_DAMAGE)
	else:
		if target.has_method(&"host_take_damage"):
			target.call(&"host_take_damage", PROJECTILE_DAMAGE)
	_despawn_projectile.rpc(pid)
	return true


# --- fire zones (Igniter casts and death bursts) ------------------------------

## Host-only: spawn a burning ground circle on every peer.
func host_spawn_fire(at: Vector2, radius: float, duration: float) -> void:
	if not multiplayer.is_server():
		return
	_next_fire_zone += 1
	_spawn_fire.rpc(_next_fire_zone, at, radius, duration)


## Host-only: spawn a wall-clipped flame cone on every peer (Igniter jet).
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


# --- loot (placeholder: items pop on the ground, clicks despawn them) --------

## Host-only, called by a Locker when a search completes.
func host_spawn_locker_loot(at: Vector2) -> void:
	if not multiplayer.is_server():
		return
	var count: int = 2 + (randi() % 2)
	for i: int in count:
		_next_loot += 1
		_spawn_loot.rpc(_next_loot, LOOT_POOL[randi() % LOOT_POOL.size()], _scatter_point(at))


## A spot near the locker that isn't inside a wall (cosmetic — loot draws
## above wall visuals, but items sitting ON walls look broken).
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
	# is_queued_for_deletion: queue_free defers a frame — without this, two
	# clicks in one host frame both pass and become a dupe once inventory exists.
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


# --- greybox map -------------------------------------------------------------

func _build_map() -> void:
	# Floor as 3x3 quads — separate canvas items, so the engine's 16-lights-
	# per-item cap applies per area instead of to the whole map at once.
	var cell: Vector2 = FLOOR_RECT.size / 3.0
	for ix: int in 3:
		for iy: int in 3:
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
		# Each wall draws itself (own canvas item — see light-cap note above).
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
		# Inset the occluder so a lit rim of wall face catches the cone —
		# otherwise walls render as pure black silhouettes even in light.
		var half: Vector2 = (rect.size * 0.5) - Vector2(6, 6)
		half = half.max(Vector2(2, 2))
		poly.polygon = PackedVector2Array([
			Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
			Vector2(half.x, half.y), Vector2(-half.x, half.y),
		])
		occluder.occluder = poly
		body.add_child(occluder)
		add_child(body)