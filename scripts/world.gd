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
const FIRE_INTERVAL_MS: int = 280
const RESPAWN_SECONDS: float = 3.0
const FLOOR_COLOR := Color(0.21, 0.215, 0.235)
const WALL_COLOR := Color(0.42, 0.40, 0.37)
const FLOOR_RECT := Rect2(-820, -620, 1640, 1240)

# Greybox layout, Rect2(x, y, w, h) in world units.
const WALL_RECTS: Array[Rect2] = [
	# outer border
	Rect2(-820, -620, 1640, 40),
	Rect2(-820, 580, 1640, 40),
	Rect2(-820, -580, 40, 1160),
	Rect2(780, -580, 40, 1160),
	# buildings / cover
	Rect2(-500, -380, 320, 40),
	Rect2(-500, -380, 40, 240),
	Rect2(-260, -200, 200, 40),
	Rect2(120, -420, 40, 300),
	Rect2(300, -60, 280, 40),
	Rect2(420, 160, 40, 260),
	Rect2(-560, 220, 260, 40),
	Rect2(-140, 360, 40, 180),
	Rect2(-60, 140, 120, 120),
]

var _spawned_ids: Array[int] = []
var _slots: Dictionary[int, int] = {}  # peer id -> spawn slot (host-assigned)
var _next_slot: int = 1
var _player_hp: Dictionary[int, int] = {}  # host-owned truth
var _fire_ready_at: Dictionary[int, int] = {}  # peer id -> Time.get_ticks_msec gate
var _next_projectile: int = 0

@onready var _players: Node2D = $Players
@onready var _enemies: Node2D = $Enemies
@onready var _projectiles: Node2D = $Projectiles


func _enter_tree() -> void:
	# Group set before children _ready so pawns/enemies can resolve us.
	add_to_group(&"game_world")


func _ready() -> void:
	_build_walls()
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	if multiplayer.is_server():
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		_slots[1] = 0
		_local_spawn(1, 0)
		_spawned_ids.append(1)
		_player_hp[1] = Player.MAX_HEALTH
		_sync_player_hp.rpc(1, Player.MAX_HEALTH)
	else:
		# Our scene is loaded and ready to receive spawns — tell the host.
		_request_join.rpc_id(1)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		_leave_to_menu()
	elif event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).physical_keycode == KEY_F1:
		SteamLobby.invite_friends()


func _draw() -> void:
	draw_rect(FLOOR_RECT, FLOOR_COLOR)
	for rect: Rect2 in WALL_RECTS:
		draw_rect(rect, WALL_COLOR)


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
	for existing_id: int in _spawned_ids:
		if existing_id != new_id:
			_sync_player_hp.rpc_id(new_id, existing_id, _player_hp[existing_id])
	for child: Node in _enemies.get_children():
		var enemy := child as Enemy
		if enemy != null:
			enemy.host_full_sync_to(new_id)


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
	var now: int = Time.get_ticks_msec()
	if now < int(_fire_ready_at.get(id, 0)):
		return
	_fire_ready_at[id] = now + FIRE_INTERVAL_MS
	var dir: Vector2 = direction.normalized()
	_next_projectile += 1
	_spawn_projectile.rpc(_next_projectile, pawn.global_position + dir * 22.0, dir)


@rpc("authority", "call_local", "reliable")
func _spawn_projectile(pid: int, from: Vector2, direction: Vector2) -> void:
	var shot: Projectile = PROJECTILE_SCENE.instantiate()
	shot.name = "p%d" % pid
	shot.setup(from, direction)
	_projectiles.add_child(shot)


@rpc("authority", "call_local", "reliable")
func _despawn_projectile(pid: int) -> void:
	var shot: Node = _projectiles.get_node_or_null("p%d" % pid)
	if shot != null:
		shot.queue_free()


## Host-only, called by a projectile when it overlaps a wall or an enemy.
func host_projectile_hit(pid: int, target: Node) -> void:
	if not multiplayer.is_server():
		return
	var enemy := target as Enemy
	if enemy != null:
		enemy.host_take_damage(PROJECTILE_DAMAGE)
	_despawn_projectile.rpc(pid)


# --- greybox map -------------------------------------------------------------

func _build_walls() -> void:
	for rect: Rect2 in WALL_RECTS:
		var body := StaticBody2D.new()
		body.position = rect.get_center()
		var shape := CollisionShape2D.new()
		var rect_shape := RectangleShape2D.new()
		rect_shape.size = rect.size
		shape.shape = rect_shape
		body.add_child(shape)
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