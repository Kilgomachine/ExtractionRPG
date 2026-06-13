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
const TEAM_SIGHT_RANGE: float = 500.0
const HEARING_RANGE: float = 380.0

# --- Raid Zero loop tuning (knobs — expect to tune these from playtests) -------
const RAID_DURATION: float = 600.0   # 10 minutes; at 0 everyone still in dies
const BLEED_OUT: float = 30.0        # downed -> death if not revived in time
const REVIVE_TIME: float = 4.0       # teammate must hold the revive this long
const REVIVE_HP: int = 40            # health you come back with
const REVIVE_RANGE: float = 80.0     # how close a reviver must be
# Anti-flood clamps on the (untrusted, friend-trust) camp kit — a modified
# client can't mint 999-of-everything into world state or the stash. Generous
# enough for any legit loadout; a true ledger needs a host-side stash (backlog).
const LOADOUT_ITEM_CAP: int = 50     # per-type
const LOADOUT_TOTAL_CAP: int = 200   # total items

# Item types (indices into a loadout counts array).
const ITEM_SCRAP: int = 0
const ITEM_MEDKIT: int = 1
const ITEM_VALUABLE: int = 2
const ITEM_AMMO: int = 3
const ITEM_FRAG: int = 4
const ITEM_SMOKE: int = 5
const ITEM_FLASH: int = 6
const ITEM_RIFLE: int = 7
const ITEM_SMG: int = 8
const ITEM_SHOTGUN: int = 9
const ITEM_LASER: int = 10
const ITEM_AMMO_SMALL: int = 11  # enemy drops: half a case
const ITEM_TYPES: int = 12
const AMMO_PER_PICKUP: int = 6
const AMMO_SMALL_PICKUP: int = 3
const START_MEDKITS: int = 2
const START_RESERVE: int = 30
const SHIELD_MAX: int = 40
const SHIELD_REGEN: float = 8.0  # per second, after the delay
const SHIELD_DELAY: float = 3.0
const LASER_AMMO_COST: int = 2
const LASER_DAMAGE: int = 30
const LASER_MAX_RANGE: float = 900.0
const FRAG_RADIUS: float = 110.0
const FRAG_DAMAGE: int = 45
const SMOKE_RADIUS: float = 90.0
const SMOKE_DURATION: float = 7.0
const FLASH_RADIUS: float = 160.0
const FLASH_STUN: float = 2.5

# Gun specs keyed by ITEM type. The laser is special-cased (charge weapon).
# kick = camera punch px; knockback = body shove px/s. Each gun has a feel.
const GUN_SPECS: Dictionary[int, Dictionary] = {
	7: {"name": "Rifle", "mag": 8, "dmg": 12, "interval_ms": 280, "pellets": 1, "spread_deg": 0.0, "sfx": "shot", "mag_index": 0, "kick": 7.0, "knockback": 45.0},
	8: {"name": "SMG", "mag": 24, "dmg": 6, "interval_ms": 110, "pellets": 1, "spread_deg": 5.0, "sfx": "shot_smg", "mag_index": 1, "kick": 3.0, "knockback": 14.0},
	9: {"name": "Shotgun", "mag": 4, "dmg": 8, "interval_ms": 900, "pellets": 5, "spread_deg": 11.0, "sfx": "shot_shotgun", "mag_index": 2, "kick": 16.0, "knockback": 190.0},
}

# Locker rolls (grenades uncommon, guns RARE — rarer than ammo).
const LOOT_POOL: Array[int] = [0, 0, 1, 1, 2, 2, 3, 3, 3, 4, 5, 6, 0, 1, 2, 3, 3, 4, 5, 6, 7, 8, 9, 10]
# Corpse loot: small ammo packs, no guns.
const LOOT_POOL_ENEMY: Array[int] = [11, 11, 11, 0, 1, 2]


static func gun_spec(item_type: int) -> Dictionary:
	return GUN_SPECS.get(item_type, {})


static func mag_index_for(item_type: int) -> int:
	if GUN_SPECS.has(item_type):
		return int(GUN_SPECS[item_type]["mag_index"])
	return -1

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
# Peers whose WORLD is loaded — distinct from "has a pawn": an extracted
# player still renders and must keep receiving streams (esp. the HOST).
var _world_ready_ids: Array[int] = []
var _slots: Dictionary[int, int] = {}
var _next_slot: int = 1
var _player_hp: Dictionary[int, int] = {}
var _player_shield: Dictionary[int, float] = {}
var _shield_delay: Dictionary[int, float] = {}
var _loadouts: Dictionary[int, PackedInt32Array] = {}
var _mags: Dictionary[int, PackedInt32Array] = {}  # per-gun magazines
var _equipped: Dictionary[int, int] = {}  # peer id -> equipped gun ITEM type (-1 none)
var _next_corpse: int = 0
var _stats: Dictionary[int, PackedInt32Array] = {}  # kills, dmg, pkills, deaths
var _names: Dictionary[int, String] = {}
var _fire_ready_at: Dictionary[int, int] = {}
var _heal_ready_at: Dictionary[int, int] = {}
# Downed / revive (host-owned). A downed player is NOT dead: they crawl, can't
# shoot, bleed out, and enemies ignore them. A teammate's E revives them.
var _downed: Dictionary[int, bool] = {}
var _bleed_left: Dictionary[int, float] = {}
var _revive_by: Dictionary[int, int] = {}        # downed id -> reviver id
var _revive_progress: Dictionary[int, float] = {}
var _last_damager: Dictionary[int, int] = {}     # for PK credit at true death
# Raid timer (host-owned, global). Counts down once; at 0, everyone still in
# the raid dies. Broadcast on whole-second changes only (no per-frame spam).
var _raid_time_left: float = 0.0
var _raid_running: bool = false
var _raid_last_sec: int = -1
var _next_projectile: int = 0
var _next_loot: int = 0
var _next_fire_zone: int = 0
var _next_grenade: int = 0
var _next_smoke: int = 0
var _hear_left: float = 0.4
var _join_attempts: int = 0
var _local_pawn: Player

@onready var _players: Node2D = $Players
@onready var _enemies: Node2D = $Enemies
@onready var _projectiles: Node2D = $Projectiles
@onready var _loot: Node2D = $Loot
@onready var _fires: Node2D = $Fires
@onready var _smokes: Node2D = $Smokes
@onready var _quick_bar: Label = $Hud/QuickBar
@onready var _bag_panel: PanelContainer = $Hud/BagPanel
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
	($Hud/Console/Box/Input as LineEdit).text_submitted.connect(_on_console_submitted)
	($Hud/DeathPanel/Col/LeaveDead as Button).pressed.connect(_leave_to_menu)
	($Hud/ExtractPanel/Col/BackExtract as Button).pressed.connect(_leave_to_menu)
	($Hud/ExtractPanel/Col/Note as Label).visible = true
	for skill: int in 3:
		var btn := $Hud/SkillPanel/Skills.get_child(skill + 1) as Button
		btn.pressed.connect(_ui_spend_point.bind(skill))
	if multiplayer.is_server():
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		_raid_time_left = RAID_DURATION
		_raid_running = true
		_slots[1] = 0
		_local_spawn(1, 0)
		_spawned_ids.append(1)
		_world_ready_ids.append(1)
		_player_hp[1] = Player.MAX_HEALTH
		_stats[1] = PackedInt32Array([0, 0, 0, 0])
		_sync_player_hp.rpc(1, Player.MAX_HEALTH)
		_apply_deploy_loadout(1)
		host_set_name(1, Game.display_name())
		update_raid_timer(int(ceil(_raid_time_left)))
	else:
		# The host enters the raid first, but if this client deploys before the
		# host's world exists, the join RPC lands on nothing. Retry until spawned.
		_join_attempts = 0
		_send_join_request()
		var retry := Timer.new()
		retry.name = "JoinRetry"
		retry.wait_time = 0.75
		add_child(retry)
		retry.timeout.connect(_join_retry)
		retry.start()


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
	# Shields regenerate after a quiet spell (fire bypasses them entirely).
	for id: int in _player_shield:
		_shield_delay[id] = maxf(0.0, float(_shield_delay.get(id, 0.0)) - delta)
		if _shield_delay[id] == 0.0 and _player_shield[id] < float(SHIELD_MAX) \
				and _player_hp.get(id, 0) > 0 and not bool(_downed.get(id, false)):
			_player_shield[id] = minf(float(SHIELD_MAX), _player_shield[id] + SHIELD_REGEN * delta)
			var whole: int = int(_player_shield[id])
			var pawn := pawn_for(id)
			if pawn != null and whole != pawn._displayed_shield:
				_sync_shield.rpc(id, whole)
	_tick_raid_timer(delta)
	_tick_downed(delta)
	_tick_revives(delta)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		_menu_panel.visible = not _menu_panel.visible
	elif event.is_action_pressed(&"skills"):
		($Hud/SkillPanel as PanelContainer).visible = \
				not ($Hud/SkillPanel as PanelContainer).visible
	elif event is InputEventKey and event.pressed and not event.echo:
		var key: Key = (event as InputEventKey).physical_keycode
		if key == KEY_F1:
			SteamLobby.invite_friends()
		elif key == KEY_F2:
			var console := $Hud/Console as PanelContainer
			console.visible = not console.visible
			if console.visible:
				($Hud/Console/Box/Input as LineEdit).grab_focus()


func _on_console_submitted(text: String) -> void:
	var box := $Hud/Console/Box/Input as LineEdit
	box.clear()
	var out := $Hud/Console/Box/Output as Label
	var parts: PackedStringArray = text.strip_edges().split(" ", false)
	if parts.is_empty():
		return
	if not multiplayer.is_server():
		out.text = "console commands are host-only (for now)"
		return
	var cmd: String = parts[0].to_lower()
	match cmd:
		"help":
			out.text = "give <type 0-11> <n> · heal · xp <n> · die · extract · killenemies"
		"give":
			if parts.size() >= 3 and _loadouts.has(1):
				_loadouts[1][clampi(int(parts[1]), 0, ITEM_TYPES - 1)] += int(parts[2])
				_push_loadout(1)
				out.text = "given"
		"heal":
			_player_hp[1] = Player.MAX_HEALTH
			_sync_player_hp.rpc(1, Player.MAX_HEALTH)
			out.text = "healed"
		"xp":
			if parts.size() >= 2:
				host_award_xp(1, int(parts[1]))
				out.text = "xp granted"
		"die":
			host_damage_player(1, 9999, 0, true)
			out.text = "oof"
		"extract":
			host_extract_player(1)
			out.text = "gone"
		"killenemies":
			for child: Node in _enemies.get_children():
				if child.has_method(&"host_take_damage"):
					child.call(&"host_take_damage", 99999, 1)
			out.text = "silence"
		_:
			out.text = "unknown command — try help"


func _close_menu() -> void:
	_menu_panel.visible = false


# --- lookups -------------------------------------------------------------------

func pawn_for(id: int) -> Player:
	return _players.get_node_or_null(str(id)) as Player


## Pawns that are live targets: not dead and NOT downed. Enemies, AoE, hearing
## and the extraction zone all read this — so a downed player is ignored by
## enemies and cannot extract, without ever setting the `dead` flag.
func alive_pawns() -> Array[Player]:
	var result: Array[Player] = []
	for child: Node in _players.get_children():
		var pawn := child as Player
		if pawn != null and not pawn.dead and not pawn.downed:
			result.append(pawn)
	return result


## Pawns that environmental HAZARDS can hurt: not dead, INCLUDING downed. Fire
## and frag use this so a downed body is no safe hiding spot — hazard damage
## eats the bleed-out clock (see host_damage_player). Enemy AI still uses
## alive_pawns(), so enemies keep ignoring the downed.
func vulnerable_pawns() -> Array[Player]:
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


## Vision is PERSONAL — each peer sees only what their own pawn can see.
## Strict: the center ray AND a flanking ray must both clear, which kills the
## one-pixel corner squeezes that revealed enemies through walls.
func sees_point(point: Vector2) -> bool:
	var pawn: Player = local_pawn()
	if pawn == null or pawn.dead:
		return false
	var eye: Vector2 = pawn.global_position
	if eye.distance_to(point) > TEAM_SIGHT_RANGE:
		return false
	if not sight_clear(eye, point):
		return false
	var side: Vector2 = (point - eye).orthogonal().normalized() * 7.0
	return sight_clear(eye, point + side) or sight_clear(eye, point - side)


## Blast/explosion LoS: WALLS stop shrapnel; smoke does not.
func blast_clear(from: Vector2, to: Vector2) -> bool:
	var space := get_world_2d().direct_space_state
	var query := PhysicsRayQueryParameters2D.create(from, to, 1)
	return space.intersect_ray(query).is_empty()


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

## Client: send the join handshake (name + camp-chosen kit). Re-sent by the
## retry timer until our pawn appears, so a deploy that races ahead of the
## host's world still lands once the host is in the raid.
func _send_join_request() -> void:
	_register_name.rpc_id(1, Game.display_name())
	_request_join.rpc_id(1, Game.chosen_loadout, Game.chosen_equipped)


func _join_retry() -> void:
	if multiplayer.is_server():
		return
	var retry := get_node_or_null("JoinRetry") as Timer
	if pawn_for(multiplayer.get_unique_id()) != null:
		if retry != null:
			retry.queue_free()  # joined — stop retrying
		return
	_join_attempts += 1
	if _join_attempts > 16:  # ~12s of trying; give up rather than spam forever
		if retry != null:
			retry.queue_free()
		print("[world] join timed out — host never came up; returning to menu")
		_leave_to_menu()  # don't strand the player (or CI) in an empty world; re-banks the kit
		return
	_send_join_request()


@rpc("any_peer", "call_remote", "reliable")
func _request_join(kit: PackedInt32Array, equipped: int) -> void:
	if not multiplayer.is_server():
		return
	var new_id: int = multiplayer.get_remote_sender_id()
	if new_id in _spawned_ids:
		return
	if not _raid_running:
		# The clock already hit 0 — the extraction window is closed. Don't spawn
		# a live pawn into a finished raid; bounce them back to the menu.
		_raid_closed.rpc_id(new_id)
		return
	for existing_id: int in _spawned_ids:
		_spawn.rpc_id(new_id, existing_id, _slots[existing_id])
	var slot: int = _next_slot
	_next_slot += 1
	_slots[new_id] = slot
	_spawned_ids.append(new_id)
	_world_ready_ids.append(new_id)
	_spawn.rpc(new_id, slot)
	_local_spawn(new_id, slot)
	_broadcast_ready_peers()
	_player_hp[new_id] = Player.MAX_HEALTH
	_stats[new_id] = PackedInt32Array([0, 0, 0, 0])
	_sync_player_hp.rpc(new_id, Player.MAX_HEALTH)
	# Untrusted client kit: _apply_loadout sanitizes it. Empty => default kit.
	if kit.is_empty():
		_apply_loadout(new_id, _default_loadout_counts(), ITEM_RIFLE)
	else:
		_apply_loadout(new_id, kit, equipped)
	# Late-join replay: the countdown and any downed teammates (with TRUE elapsed
	# time so the bleed/revive bars don't restart from full on the joiner).
	_sync_raid_time.rpc_id(new_id, int(ceil(_raid_time_left)))
	for down_id: int in _downed:
		if bool(_downed[down_id]):
			var bleed_elapsed: int = int((BLEED_OUT - float(_bleed_left.get(down_id, BLEED_OUT))) * 1000.0)
			_sync_downed.rpc_id(new_id, down_id, true, bleed_elapsed)
			if int(_revive_by.get(down_id, 0)) != 0:
				var rev_elapsed: int = int(float(_revive_progress.get(down_id, 0.0)) * 1000.0)
				_sync_reviving.rpc_id(new_id, down_id, true, rev_elapsed)
				_sync_reviver_busy.rpc_id(new_id, int(_revive_by[down_id]), true)
	for existing_id: int in _spawned_ids:
		if existing_id != new_id:
			_sync_player_hp.rpc_id(new_id, existing_id, _player_hp[existing_id])
			_sync_stats.rpc_id(new_id, existing_id, _stats[existing_id])
			_sync_shield.rpc_id(new_id, existing_id, int(_player_shield.get(existing_id, 0.0)))
			_sync_xp.rpc_id(new_id, existing_id, int(_xp.get(existing_id, 0)),
					int(_level.get(existing_id, 1)), int(_skill_points.get(existing_id, 0)))
			# Existing teammates' loadouts were broadcast before this peer joined
			# — replay so the joiner has correct host-truth (equipped gun, ammo).
			if _loadouts.has(existing_id):
				_sync_loadout.rpc_id(new_id, existing_id, _loadouts[existing_id],
						_mags.get(existing_id, PackedInt32Array([0, 0, 0])),
						int(_equipped.get(existing_id, -1)))
			# A teammate who died (hp 0, not downed) renders as a fresh pawn on
			# the joiner unless we replay the dead visual explicitly.
			if _player_hp[existing_id] == 0 and not bool(_downed.get(existing_id, false)):
				_sync_dead.rpc_id(new_id, existing_id, true)
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
		elif zone.safe_cone:
			# Waller bursts carry the safe cone — replaying as a plain circle
			# would show the joiner a no-escape flood.
			_spawn_burst.rpc_id(new_id, fire_id, zone.position, zone.safe_direction,
					zone.radius, zone.remaining())
		else:
			_spawn_fire.rpc_id(new_id, fire_id, zone.position, zone.radius, zone.remaining())
	# Corpses: the permadeath gear-recovery mechanic must survive a late join.
	for child: Node in $Corpses.get_children():
		var corpse := child as Corpse
		if corpse == null or corpse.is_queued_for_deletion():
			continue
		var cid: int = int(String(corpse.name).trim_prefix("c"))
		_spawn_corpse.rpc_id(new_id, cid, corpse.position, corpse.loot_count)
		if not corpse.inventory.is_empty():
			_set_corpse_inventory.rpc_id(new_id, cid, corpse.inventory)
	# Active Waller rings: the joiner must collide with (and not see through)
	# the same walls as everyone else.
	for child: Node in $Rings.get_children():
		var ring := child as RingWalls
		if ring == null or ring.is_queued_for_deletion():
			continue
		_spawn_ring.rpc_id(new_id, int(String(ring.name).trim_prefix("r")),
				ring.position, ring.radius, ring.remaining(), ring.skip_mask)
	# Active smoke: opaque for everyone or no one.
	for child: Node in _smokes.get_children():
		var cloud := child as SmokeZone
		if cloud == null or cloud.is_queued_for_deletion():
			continue
		_spawn_smoke.rpc_id(new_id, int(String(cloud.name).trim_prefix("s")), cloud.position)


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
	if _names.has(id):
		pawn.set_display_name(_names[id])
	print("[world] spawned player %d in slot %d (%d in raid)" % [id, slot, _players.get_child_count()])


func _local_despawn(id: int) -> void:
	var pawn: Node = _players.get_node_or_null(str(id))
	if pawn != null:
		pawn.queue_free()
		print("[world] despawned player %d" % id)


func _on_peer_disconnected(id: int) -> void:
	_spawned_ids.erase(id)
	_world_ready_ids.erase(id)
	_player_hp.erase(id)
	_player_shield.erase(id)
	_shield_delay.erase(id)
	_loadouts.erase(id)
	_mags.erase(id)
	_equipped.erase(id)
	_stats.erase(id)
	_names.erase(id)
	_fire_ready_at.erase(id)
	_heal_ready_at.erase(id)
	# XP teardown was missing — matches the rest of the per-peer cleanup. (NOT
	# done on extract: an extracted peer stays in _world_ready_ids and may
	# re-deploy, so its progression must persist there.)
	_xp.erase(id)
	_level.erase(id)
	_skill_points.erase(id)
	_clear_downed_state(id)
	_despawn.rpc(id)
	_local_despawn(id)
	_broadcast_ready_peers()


func _broadcast_ready_peers() -> void:
	Game.ready_peers = PackedInt32Array(_world_ready_ids)
	Game._set_ready_peers.rpc(Game.ready_peers)


func _on_server_disconnected() -> void:
	print("[world] server disconnected — leaving to menu")
	_leave_to_menu()


func _leave_to_menu() -> void:
	# Left the raid alive without extracting or dying (menu Leave, host drop, or
	# a join that never landed) — re-bank the kit so it isn't lost. No-op after
	# extract/death (which already cleared it). Bank the CURRENT loadout (the
	# pawn's host-synced _counts, net of drops/pickups) if we made it into the
	# raid; otherwise the deploy snapshot (never spawned, e.g. join timeout).
	if not Game.pending_kit.is_empty():
		var pawn := local_pawn()
		Game.settle_pending_kit(pawn._counts if pawn != null else Game.pending_kit)
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
	var pawn := pawn_for(id)
	if pawn != null:
		pawn.set_display_name(display_name)


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


func update_stamina(pct: float) -> void:
	_stamina_fill.size.x = 180.0 * clampf(pct, 0.0, 1.0)


func toggle_bag() -> void:
	_bag_panel.visible = not _bag_panel.visible


## Rebuild the bag rows: name ×count [Equip] [Drop].
func refresh_bag(counts: PackedInt32Array, equipped: int) -> void:
	var list := $Hud/BagPanel/Items as VBoxContainer
	for child: Node in list.get_children():
		child.queue_free()
	var header := Label.new()
	header.text = "BACKPACK  (B to close)"
	list.add_child(header)
	var equipped_label := Label.new()
	var weapon_name: String = "nothing"
	if equipped >= 0 and equipped < LootItem.NAMES.size():
		weapon_name = LootItem.NAMES[equipped]
	equipped_label.text = "EQUIPPED — Weapon: %s · Belt: Medkit / %s" % [
			weapon_name, Game.GRENADES[0]]
	list.add_child(equipped_label)
	list.add_child(HSeparator.new())
	for item_type: int in counts.size():
		if counts[item_type] <= 0:
			continue
		var row := HBoxContainer.new()
		var label := Label.new()
		var item_name: String = LootItem.NAMES[item_type] if item_type < LootItem.NAMES.size() else "?"
		var is_gun: bool = GUN_SPECS.has(item_type) or item_type == ITEM_LASER
		label.text = "%s ×%d%s" % [item_name, counts[item_type],
				"   [equipped]" if is_gun and item_type == equipped else ""]
		label.custom_minimum_size.x = 220
		row.add_child(label)
		if is_gun and item_type != equipped:
			var equip := Button.new()
			equip.text = "Equip"
			equip.pressed.connect(_ui_equip.bind(item_type))
			row.add_child(equip)
		var drop := Button.new()
		drop.text = "Drop"
		drop.pressed.connect(_ui_drop.bind(item_type))
		row.add_child(drop)
		list.add_child(row)


func _ui_spend_point(skill: int) -> void:
	if _my_points <= 0:
		return
	if multiplayer.is_server():
		host_spend_point(1, skill)
	else:
		_request_spend_point.rpc_id(1, skill)


func _ui_equip(item_type: int) -> void:
	if multiplayer.is_server():
		host_handle_equip(1, item_type)
	else:
		_request_equip.rpc_id(1, item_type)


func _ui_drop(item_type: int) -> void:
	if multiplayer.is_server():
		host_handle_drop(1, item_type)
	else:
		_request_drop.rpc_id(1, item_type)


# --- combat: hp, damage, death -------------------------------------------------------

## The single place player damage is decided. source > 0 = another player (FF).
## pierce_shield: fire damage ignores shields entirely.
func host_damage_player(id: int, amount: int, source: int = 0, pierce_shield: bool = false) -> void:
	if not multiplayer.is_server() or not _player_hp.has(id):
		return
	var pawn := pawn_for(id)
	if pawn == null or pawn.is_invulnerable():
		return
	if bool(_downed.get(id, false)):
		# A downed body still burns/bleeds from hazards (fire, frag) — crawling
		# into fire is NOT a safe hiding spot. HP is already 0, so the damage
		# eats the bleed-out clock instead, hastening (or causing) death.
		_bleed_left[id] = float(_bleed_left.get(id, BLEED_OUT)) - float(amount)
		if _bleed_left[id] <= 0.0:
			_host_player_death(id)
		return
	if _player_hp[id] <= 0:
		return
	_shield_delay[id] = SHIELD_DELAY
	if not pierce_shield:
		var shield: float = float(_player_shield.get(id, 0.0))
		var absorbed: float = minf(shield, float(amount))
		if absorbed > 0.0:
			_player_shield[id] = shield - absorbed
			amount -= int(absorbed)
			_sync_shield.rpc(id, int(_player_shield[id]))
		if amount <= 0:
			return
	if source > 0 and source != id:
		_last_damager[id] = source  # remembered for PK credit at true death
	_player_hp[id] = maxi(0, _player_hp[id] - amount)
	_sync_player_hp.rpc(id, _player_hp[id])
	if source > 0 and source != id and _stats.has(source):
		_stats[source][1] += amount
		_sync_stats.rpc(source, _stats[source])
	if _player_hp[id] == 0:
		# Not instant death anymore: drop them into DOWNED (unless solo, where
		# no revive is possible). Death + kill credit happen in _host_player_death.
		_enter_downed(id)


## PERMADEATH: your corpse keeps your bag; no respawn (harness excepted).
func _host_player_death(id: int) -> void:
	print("[combat] player %d died — gear stays on the corpse" % id)
	_clear_downed_state(id)
	_sync_dead.rpc(id, true)
	# Death + PK credit happen HERE (not at the down event) so a revive never
	# inflates the count. PK goes to whoever last damaged them, if a player.
	if _stats.has(id):
		_stats[id][3] += 1
		_sync_stats.rpc(id, _stats[id])
	var killer: int = int(_last_damager.get(id, 0))
	if killer > 0 and killer != id and _stats.has(killer):
		_stats[killer][2] += 1
		_sync_stats.rpc(killer, _stats[killer])
	_last_damager.erase(id)
	var pawn := pawn_for(id)
	if pawn != null and _loadouts.has(id):
		_next_corpse += 1
		_spawn_corpse.rpc(_next_corpse, pawn.global_position, 0)
		var corpse := $Corpses.get_node_or_null("c%d" % _next_corpse) as Corpse
		if corpse != null:
			corpse.inventory = _loadouts[id].duplicate()
			_set_corpse_inventory.rpc(_next_corpse, corpse.inventory)
		var empty := PackedInt32Array()
		empty.resize(ITEM_TYPES)
		_loadouts[id] = empty
		_equipped[id] = -1
		_mags[id] = PackedInt32Array([0, 0, 0])  # chambered rounds die with you
		_push_loadout(id)
	if id == 1:
		_show_death_local()
	else:
		_show_death.rpc_id(id)
	if Game.auto_walk:
		_schedule_respawn(id)  # headless harness still cycles
	# This death may have removed the last possible reviver — anyone now downed
	# with nobody left to save them dies immediately rather than bleeding out
	# hopelessly for 30s. (Snapshot keys; _host_player_death erases _downed.)
	for down_id: int in _downed.keys():
		if bool(_downed.get(down_id, false)) and not _has_potential_reviver(down_id):
			_host_player_death(down_id)


@rpc("authority", "call_local", "reliable")
func _set_corpse_inventory(cid: int, inv: PackedInt32Array) -> void:
	var corpse := $Corpses.get_node_or_null("c%d" % cid) as Corpse
	if corpse != null:
		corpse.inventory = inv.duplicate()


@rpc("authority", "call_remote", "reliable")
func _show_death() -> void:
	_show_death_local()


func _show_death_local() -> void:
	($Hud/DeathPanel as PanelContainer).visible = true
	Game.clear_pending_kit()  # your kit is on the corpse now — fate settled (lost)


## Headless-harness respawn cycle ONLY (Game.auto_walk). The human-facing
## testing respawn was removed for Raid Zero — permadeath + downed/revive is the
## real loop now. _host_player_death only schedules this when auto_walk is set.
func _schedule_respawn(id: int) -> void:
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = RESPAWN_SECONDS
	add_child(timer)
	timer.timeout.connect(_on_respawn_timer.bind(id, timer))
	timer.start()


func _on_respawn_timer(id: int, timer: Timer) -> void:
	if timer != null:
		timer.queue_free()
	if not multiplayer.is_server() or not _player_hp.has(id) or pawn_for(id) == null:
		return
	_sync_dead.rpc(id, false)  # hp sync no longer un-deads; do it explicitly
	_player_respawned.rpc(id)
	_player_hp[id] = Player.MAX_HEALTH
	_sync_player_hp.rpc(id, Player.MAX_HEALTH)
	_init_loadout(id)
	if id == 1:
		_hide_death_local()
	else:
		_hide_death.rpc_id(id)


@rpc("authority", "call_remote", "reliable")
func _hide_death() -> void:
	_hide_death_local()


func _hide_death_local() -> void:
	($Hud/DeathPanel as PanelContainer).visible = false


# --- extraction ----------------------------------------------------------------

## Host-only, called by an ExtractionZone when a player's timer completes.
func host_extract_player(id: int) -> void:
	if not multiplayer.is_server() or not _loadouts.has(id) or not _raid_running:
		return  # no banking after the extraction window has closed
	# Snapshot the haul BEFORE the erase below — this is the stash deposit.
	var deposit: PackedInt32Array = _loadouts[id].duplicate()
	var carried: int = 0
	for n: int in deposit:
		carried += n
	print("[raid] player %d EXTRACTED with %d items" % [id, carried])
	# Bank it into the OWNING peer's per-client stash. The host writes its own
	# user:// file directly; a remote extractor persists its own via this RPC
	# (the host must never write another peer's stash file).
	if id == 1:
		Game.stash_add(deposit)
	else:
		_deposit_stash.rpc_id(id, deposit)
	_extracted_fx.rpc(id, carried)
	# Out of the raid: despawn the pawn and CLEAR combat state so a same-frame
	# death can't mint a corpse of already-extracted items. The peer stays in
	# _world_ready_ids — they're still rendering (and the HOST must keep
	# receiving everyone's streams).
	_clear_downed_state(id)
	_spawned_ids.erase(id)
	_player_hp.erase(id)
	_player_shield.erase(id)
	_shield_delay.erase(id)
	_loadouts.erase(id)
	_mags.erase(id)
	_equipped.erase(id)
	_despawn.rpc(id)
	_local_despawn(id)


## Runs on the OWNING client: persist an extracted haul to this machine's stash.
@rpc("authority", "call_remote", "reliable")
func _deposit_stash(counts: PackedInt32Array) -> void:
	Game.stash_add(counts)


# --- downed / revive / raid timer ----------------------------------------------

## Tick the raid clock (host). Broadcast on whole-second changes only. At 0,
## everyone still in the raid (not extracted) dies.
func _tick_raid_timer(delta: float) -> void:
	if not _raid_running:
		return
	_raid_time_left = maxf(0.0, _raid_time_left - delta)
	var sec: int = int(ceil(_raid_time_left))
	if sec != _raid_last_sec:
		_raid_last_sec = sec
		_sync_raid_time.rpc(sec)
	if _raid_time_left <= 0.0:
		_raid_running = false
		print("[raid] time up — the extraction window has closed")
		for id: int in _spawned_ids.duplicate():
			# Skip the already-dead (still in _spawned_ids) so we don't mint a
			# second corpse; kill the living and the downed alike.
			if _player_hp.get(id, 0) > 0 or bool(_downed.get(id, false)):
				_last_damager.erase(id)  # the clock is nobody's player-kill
				_host_player_death(id)


@rpc("authority", "call_local", "reliable")
func _sync_raid_time(seconds: int) -> void:
	update_raid_timer(seconds)


## Host told a would-be joiner the raid is already over — go back to the menu
## (re-banking the kit they withdrew at camp; they never entered).
@rpc("authority", "call_remote", "reliable")
func _raid_closed() -> void:
	print("[world] the raid was already over — returning to menu")
	_leave_to_menu()


func update_raid_timer(seconds: int) -> void:
	var label := $Hud/RaidTimer as Label
	if label == null:
		return
	label.text = "RAID OVER" if seconds <= 0 else "RAID  %d:%02d" % [seconds / 60, seconds % 60]


## HP hit 0: go DOWNED instead of dying — unless nobody could revive (solo, or
## everyone else is already down/dead), in which case it's just death.
func _enter_downed(id: int) -> void:
	if bool(_downed.get(id, false)):
		return
	if not _has_potential_reviver(id):
		_host_player_death(id)
		return
	_downed[id] = true
	_bleed_left[id] = BLEED_OUT
	print("[combat] player %d is DOWNED — a teammate can revive them" % id)
	_sync_downed.rpc(id, true, 0)


## Is anyone alive (not this player, not dead, not downed) able to come revive?
func _has_potential_reviver(id: int) -> bool:
	for child: Node in _players.get_children():
		var pawn := child as Player
		if pawn == null or str(pawn.name).to_int() == id:
			continue
		if not pawn.dead and not pawn.downed:
			return true
	return false


## Bleed-out (host): downed players lose the clock; at 0 they truly die.
func _tick_downed(delta: float) -> void:
	for id: int in _downed.keys():
		if not bool(_downed[id]):
			continue
		_bleed_left[id] = float(_bleed_left.get(id, 0.0)) - delta
		if _bleed_left[id] <= 0.0:
			print("[combat] player %d bled out" % id)
			_host_player_death(id)


## A teammate's E reached a downed player — begin (or keep) the revive cast.
func host_request_revive(reviver_id: int, target_id: int) -> void:
	if not multiplayer.is_server() or not bool(_downed.get(target_id, false)):
		return
	var reviver := pawn_for(reviver_id)
	var target := pawn_for(target_id)
	if reviver == null or target == null or reviver.dead or reviver.downed:
		return
	if reviver.global_position.distance_to(target.global_position) > REVIVE_RANGE + 14.0:
		return
	# First reviver wins: a second teammate pressing E doesn't hijack or reset
	# the cast (which would also orphan the first reviver's busy state).
	if _revive_by.has(target_id):
		return
	_revive_by[target_id] = reviver_id
	_revive_progress[target_id] = 0.0
	# call_local RPC so the reviver's OWN client gets _revive_busy=true too —
	# otherwise a remote reviver could sprint/fire/reload through the channel.
	_sync_reviver_busy.rpc(reviver_id, true)
	_sync_reviving.rpc(target_id, true, 0)


@rpc("authority", "call_local", "reliable")
func _sync_reviver_busy(reviver_id: int, on: bool) -> void:
	var pawn := pawn_for(reviver_id)
	if pawn != null:
		pawn.set_reviver_busy(on)


@rpc("any_peer", "call_remote", "reliable")
func _request_revive(target_id: int) -> void:
	if multiplayer.is_server():
		host_request_revive(multiplayer.get_remote_sender_id(), target_id)


## Advance in-progress revives (host); cancel if the reviver bails / dies / walks
## off, or the target stops being downed. Complete -> back up at REVIVE_HP.
func _tick_revives(delta: float) -> void:
	for target_id: int in _revive_by.keys():
		var reviver_id: int = int(_revive_by[target_id])
		var reviver := pawn_for(reviver_id)
		var target := pawn_for(target_id)
		var valid: bool = bool(_downed.get(target_id, false)) \
				and reviver != null and target != null \
				and not reviver.dead and not reviver.downed \
				and reviver.global_position.distance_to(target.global_position) <= REVIVE_RANGE + 14.0
		if not valid:
			_cancel_revive(target_id)
			continue
		_revive_progress[target_id] = float(_revive_progress.get(target_id, 0.0)) + delta
		if _revive_progress[target_id] >= REVIVE_TIME:
			_complete_revive(target_id, reviver_id)


func _cancel_revive(target_id: int) -> void:
	var reviver_id: int = int(_revive_by.get(target_id, 0))
	if reviver_id != 0:
		_sync_reviver_busy.rpc(reviver_id, false)
	_revive_by.erase(target_id)
	_revive_progress.erase(target_id)
	if bool(_downed.get(target_id, false)):
		_sync_reviving.rpc(target_id, false, 0)  # bar off, but still bleeding


func _complete_revive(target_id: int, reviver_id: int) -> void:
	_sync_reviver_busy.rpc(reviver_id, false)
	_revive_by.erase(target_id)
	_revive_progress.erase(target_id)
	_downed[target_id] = false
	_bleed_left.erase(target_id)
	_last_damager.erase(target_id)
	_player_hp[target_id] = REVIVE_HP
	_player_shield[target_id] = 0.0
	_shield_delay[target_id] = SHIELD_DELAY
	_sync_player_hp.rpc(target_id, REVIVE_HP)
	_sync_shield.rpc(target_id, 0)
	_sync_downed.rpc(target_id, false, 0)  # pawn.set_downed(false) grants brief grace
	print("[combat] player %d revived player %d" % [reviver_id, target_id])


## Wipe ALL downed/revive bookkeeping for a player (death, extract, disconnect),
## and cancel any revive THEY were performing on someone else.
func _clear_downed_state(id: int) -> void:
	# Free the reviver who was working on THIS player (now dead/extracted/gone).
	if _revive_by.has(id):
		_sync_reviver_busy.rpc(int(_revive_by[id]), false)
	_downed.erase(id)
	_bleed_left.erase(id)
	_revive_by.erase(id)
	_revive_progress.erase(id)
	# If this player was reviving SOMEONE ELSE, cancel that too.
	for other_id: int in _revive_by.keys():
		if int(_revive_by[other_id]) == id:
			_cancel_revive(other_id)


@rpc("authority", "call_local", "reliable")
func _sync_downed(id: int, on: bool, elapsed_ms: int = 0) -> void:
	var pawn := pawn_for(id)
	if pawn != null:
		pawn.set_downed(on, elapsed_ms)
	if id == multiplayer.get_unique_id():
		($Hud/DownedPanel as PanelContainer).visible = on


@rpc("authority", "call_local", "reliable")
func _sync_reviving(id: int, on: bool, elapsed_ms: int = 0) -> void:
	var pawn := pawn_for(id)
	if pawn != null:
		pawn.set_reviving(on, elapsed_ms)


@rpc("authority", "call_local", "reliable")
func _extracted_fx(id: int, carried: int) -> void:
	Game.play_sfx("heal", Vector2.ZERO)
	if id == multiplayer.get_unique_id():
		Game.clear_pending_kit()  # survivors were just deposited — fate settled
		var panel := $Hud/ExtractPanel as PanelContainer
		($Hud/ExtractPanel/Col/Note as Label).text = \
				"EXTRACTED!\nYou made it out with %d items.\nBanked in your stash — bring them back next raid." % carried
		panel.visible = true


# --- XP / levels / skill points (placeholder tree) --------------------------------

var _xp: Dictionary[int, int] = {}
var _level: Dictionary[int, int] = {}
var _skill_points: Dictionary[int, int] = {}


func host_award_xp(id: int, amount: int) -> void:
	if not multiplayer.is_server() or id <= 0 or amount <= 0 or not _player_hp.has(id):
		return  # amount 0 = damage that didn't apply (armor/overkill): no rpc spam
	_xp[id] = int(_xp.get(id, 0)) + amount
	var level: int = int(_level.get(id, 1))
	while _xp[id] >= level * 100:
		_xp[id] -= level * 100
		level += 1
		_skill_points[id] = int(_skill_points.get(id, 0)) + 1
		print("[xp] player %d reached level %d (+1 skill point)" % [id, level])
	_level[id] = level
	_sync_xp.rpc(id, _xp[id], level, int(_skill_points.get(id, 0)))


@rpc("authority", "call_local", "reliable")
func _sync_xp(id: int, xp: int, level: int, points: int) -> void:
	if id == multiplayer.get_unique_id():
		($Hud/XpLabel as Label).text = "Lv %d · XP %d/%d · Skill pts: %d" % [level, xp, level * 100, points]
		_my_points = points


var _my_points: int = 0


@rpc("any_peer", "call_remote", "reliable")
func _request_spend_point(skill: int) -> void:
	if multiplayer.is_server():
		host_spend_point(multiplayer.get_remote_sender_id(), skill)


func host_spend_point(id: int, skill: int) -> void:
	if not multiplayer.is_server() or int(_skill_points.get(id, 0)) <= 0:
		return
	if skill < 0 or skill > 2:
		return
	_skill_points[id] -= 1
	print("[xp] player %d invested in placeholder skill %d" % [id, skill])
	_sync_xp.rpc(id, int(_xp.get(id, 0)), int(_level.get(id, 1)), _skill_points[id])


@rpc("authority", "call_local", "reliable")
func _sync_player_hp(id: int, hp: int) -> void:
	# HP 0 no longer implies dead — it may mean DOWNED. The dead/downed visual
	# is driven explicitly by _sync_dead / _sync_downed instead.
	var pawn := pawn_for(id)
	if pawn == null:
		return
	pawn.update_displayed_health(hp)


@rpc("authority", "call_local", "reliable")
func _sync_dead(id: int, value: bool) -> void:
	var pawn := pawn_for(id)
	if pawn != null:
		pawn.set_dead(value)
	if value and id == multiplayer.get_unique_id():
		($Hud/DownedPanel as PanelContainer).visible = false  # dead > downed


@rpc("authority", "call_local", "reliable")
func _player_respawned(id: int) -> void:
	var pawn := pawn_for(id)
	if pawn != null:
		pawn.respawn_to_slot()


@rpc("authority", "call_local", "reliable")
func _sync_shield(id: int, value: int) -> void:
	var pawn := pawn_for(id)
	if pawn != null:
		pawn.update_displayed_shield(value)


# --- loadout -------------------------------------------------------------------------

## The default testing kit — used by the headless harness and as the fallback
## when no camp loadout was chosen (empty Game.chosen_loadout).
func _default_loadout_counts() -> PackedInt32Array:
	var counts := PackedInt32Array()
	counts.resize(ITEM_TYPES)
	counts[ITEM_MEDKIT] = START_MEDKITS
	counts[ITEM_AMMO] = START_RESERVE
	counts[ITEM_FRAG] = 1
	counts[ITEM_SMOKE] = 1
	counts[ITEM_FLASH] = 1
	counts[ITEM_RIFLE] = 1
	counts[ITEM_SMG] = 1
	counts[ITEM_SHOTGUN] = 1
	counts[ITEM_LASER] = 1
	return counts


## CI / auto_walk respawn re-seeds the default kit.
func _init_loadout(id: int) -> void:
	_apply_loadout(id, _default_loadout_counts(), ITEM_RIFLE)


## The host's own deploy: read the camp choice (or the default kit if none).
func _apply_deploy_loadout(id: int) -> void:
	if Game.chosen_loadout.is_empty():
		_apply_loadout(id, _default_loadout_counts(), ITEM_RIFLE)
	else:
		_apply_loadout(id, Game.chosen_loadout, Game.chosen_equipped)


## Seed a player's host-owned kit from (untrusted) counts: clamp to the item
## domain, fill mags only for guns actually brought, validate the equipped gun.
func _apply_loadout(id: int, raw_counts: PackedInt32Array, raw_equipped: int) -> void:
	var counts := PackedInt32Array()
	counts.resize(ITEM_TYPES)
	var total: int = 0
	for t: int in ITEM_TYPES:
		var n: int = raw_counts[t] if t < raw_counts.size() else 0
		# Per-type clamp, then a running total clamp — a modified client cannot
		# flood world state / the stash with an absurd kit.
		n = clampi(n, 0, mini(LOADOUT_ITEM_CAP, LOADOUT_TOTAL_CAP - total))
		counts[t] = n
		total += n
	_loadouts[id] = counts
	var mags := PackedInt32Array([0, 0, 0])
	for g: int in [ITEM_RIFLE, ITEM_SMG, ITEM_SHOTGUN]:
		if counts[g] > 0:
			mags[mag_index_for(g)] = int(GUN_SPECS[g]["mag"])
	_mags[id] = mags
	_equipped[id] = _validate_equipped(counts, raw_equipped)
	_player_shield[id] = float(SHIELD_MAX)
	_shield_delay[id] = 0.0
	_sync_shield.rpc(id, SHIELD_MAX)
	_push_loadout(id)


## Equipped must be a gun the player actually brought; else the first owned gun,
## else none (-1, a naked run).
func _validate_equipped(counts: PackedInt32Array, equipped: int) -> int:
	if (GUN_SPECS.has(equipped) or equipped == ITEM_LASER) and counts[equipped] > 0:
		return equipped
	for g: int in [ITEM_RIFLE, ITEM_SMG, ITEM_SHOTGUN, ITEM_LASER]:
		if counts[g] > 0:
			return g
	return -1


func _push_loadout(id: int) -> void:
	_sync_loadout.rpc(id, _loadouts[id], _mags[id], _equipped[id])


@rpc("authority", "call_local", "reliable")
func _sync_loadout(id: int, counts: PackedInt32Array, mags: PackedInt32Array, equipped: int) -> void:
	var pawn := pawn_for(id)
	if pawn != null:
		pawn.update_loadout(counts, mags, equipped)


# --- equip / drop ---------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func _request_equip(item_type: int) -> void:
	if multiplayer.is_server():
		host_handle_equip(multiplayer.get_remote_sender_id(), item_type)


func host_handle_equip(id: int, item_type: int) -> void:
	if not multiplayer.is_server() or not _loadouts.has(id) or _player_hp.get(id, 0) <= 0:
		return
	if not (GUN_SPECS.has(item_type) or item_type == ITEM_LASER):
		return
	if _loadouts[id][item_type] <= 0:
		return
	_equipped[id] = item_type
	_push_loadout(id)


@rpc("any_peer", "call_remote", "reliable")
func _request_drop(item_type: int) -> void:
	if multiplayer.is_server():
		host_handle_drop(multiplayer.get_remote_sender_id(), item_type)


func host_handle_drop(id: int, item_type: int) -> void:
	if not multiplayer.is_server() or not _loadouts.has(id) or _player_hp.get(id, 0) <= 0:
		return
	if item_type < 0 or item_type >= ITEM_TYPES or _loadouts[id][item_type] <= 0:
		return
	var pawn := pawn_for(id)
	if pawn == null:
		return
	# Ammo drops as a bundle matching what's pickable — no quantum minting.
	var qty: int = 1
	if item_type == ITEM_AMMO:
		qty = mini(AMMO_PER_PICKUP, _loadouts[id][item_type])
	_loadouts[id][item_type] -= qty
	if _loadouts[id][item_type] <= 0 and _equipped.get(id, -1) == item_type:
		_equipped[id] = -1  # dropped the gun in your hands
	_push_loadout(id)
	_next_loot += 1
	_spawn_loot.rpc(_next_loot, item_type,
			pawn.global_position + Vector2.from_angle(randf() * TAU) * 24.0, qty, true)


## The Siren's doing: your weapon hits the dirt at your feet.
func host_force_drop_gun(id: int) -> void:
	if not multiplayer.is_server() or not _loadouts.has(id):
		return
	var gun: int = _equipped.get(id, -1)
	if gun == -1 or _loadouts[id][gun] <= 0:
		return
	_loadouts[id][gun] -= 1
	_equipped[id] = -1
	_push_loadout(id)
	var pawn := pawn_for(id)
	if pawn != null:
		_next_loot += 1
		_spawn_loot.rpc(_next_loot, gun,
				pawn.global_position + Vector2.from_angle(randf() * TAU) * 20.0, 1, true)


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
	if not GUN_SPECS.has(gun) or _equipped.get(id, -1) != gun:
		_push_loadout(id)  # nack: clears the client's _reload_pending flag
		return
	var idx: int = mag_index_for(gun)
	var take: int = mini(int(GUN_SPECS[gun]["mag"]) - _mags[id][idx], _loadouts[id][ITEM_AMMO])
	if take <= 0:
		_push_loadout(id)  # nack: full mag / no ammo — unstick the client
		return
	_mags[id][idx] += take
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
	if not GUN_SPECS.has(gun) or _equipped.get(id, -1) != gun:
		return
	var pawn := pawn_for(id)
	if pawn == null or direction == Vector2.ZERO:
		return
	var idx: int = mag_index_for(gun)
	if _mags[id][idx] <= 0:
		return
	var spec: Dictionary = GUN_SPECS[gun]
	var now: int = Time.get_ticks_msec()
	if now < int(_fire_ready_at.get(id, 0)):
		return
	_fire_ready_at[id] = now + int(spec["interval_ms"]) - 15  # small lag tolerance
	_mags[id][idx] -= 1
	_push_loadout(id)
	# Gunfire is LOUD — everything nearby gets suspicious.
	host_alert_enemies(pawn.global_position, pawn.global_position, 600.0)
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
		if hostile and bool(_downed.get(victim, false)):
			return false  # enemies ignore the downed — an in-flight round phases through
		if pawn.is_invulnerable():
			print("[combat] player %s phased through a shot" % pawn.name)
			return false
		host_damage_player(victim, dmg, shooter)
	elif target.has_method(&"host_take_damage"):
		# XP from damage actually APPLIED — no farming armored bosses/overkill.
		var applied: int = int(target.call(&"host_take_damage", dmg, shooter))
		host_award_xp(shooter, applied)
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
	if _equipped.get(id, -1) != ITEM_LASER:
		return
	_loadouts[id][ITEM_AMMO] -= LASER_AMMO_COST
	_push_loadout(id)
	host_alert_enemies(pawn.global_position, pawn.global_position, 600.0)
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
			host_award_xp(id, int(child.call(&"host_take_damage", LASER_DAMAGE, id)))
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
		0:  # frag — blast LoS is WALLS ONLY (smoke is concealment, not cover)
			for child: Node in _enemies.get_children():
				if child is Node2D and child.has_method(&"host_take_damage") \
						and (child as Node2D).global_position.distance_to(at) <= FRAG_RADIUS \
						and blast_clear(at, (child as Node2D).global_position):
					host_award_xp(thrower, int(child.call(&"host_take_damage", FRAG_DAMAGE, thrower)))
			# vulnerable_pawns(): a frag can finish a downed teammate/foe.
			for victim: Player in vulnerable_pawns():
				if victim.global_position.distance_to(at) <= FRAG_RADIUS \
						and blast_clear(at, victim.global_position):
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


## Host-only: the Waller's wall ring.
func host_spawn_ring(center: Vector2, radius: float, duration: float, skip_mask: int) -> void:
	if not multiplayer.is_server():
		return
	_next_fire_zone += 1
	_spawn_ring.rpc(_next_fire_zone, center, radius, duration, skip_mask)


@rpc("authority", "call_local", "reliable")
func _spawn_ring(ring_id: int, center: Vector2, radius: float, duration: float, skip_mask: int) -> void:
	var ring := RingWalls.new()
	ring.name = "r%d" % ring_id
	ring.setup(center, radius, duration, skip_mask)
	$Rings.add_child(ring)
	Game.play_sfx("boom", center)


## Host-only: the Waller's flame flood (circle with a safe cone).
func host_spawn_burst(center: Vector2, safe_dir: float, radius: float, duration: float) -> void:
	if not multiplayer.is_server():
		return
	_next_fire_zone += 1
	_spawn_burst.rpc(_next_fire_zone, center, safe_dir, radius, duration)


@rpc("authority", "call_local", "reliable")
func _spawn_burst(fire_id: int, center: Vector2, safe_dir: float, radius: float, duration: float) -> void:
	if _fires.has_node("f%d" % fire_id):
		return
	var zone := FireZone.new()
	zone.name = "f%d" % fire_id
	zone.setup(center, radius, duration)
	zone.safe_cone = true
	zone.safe_direction = safe_dir
	zone.tick_interval = 0.125
	zone.tick_damage = 4  # same flame as the Igniter's jet
	_fires.add_child(zone)
	Game.play_sfx("flame", center)


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
	var count: int = 3 + (randi() % 3)  # 3-5 items per locker
	for i: int in count:
		var rolled: int = LOOT_POOL[randi() % LOOT_POOL.size()]
		_next_loot += 1
		_spawn_loot.rpc(_next_loot, rolled, _scatter_point(at), _amount_for(rolled), false)


## Dead enemies leave a lootable CORPSE (same two-step search as lockers).
func host_drop_enemy_loot(at: Vector2, count: int) -> void:
	if not multiplayer.is_server():
		return
	_next_corpse += 1
	_spawn_corpse.rpc(_next_corpse, at, count)


@rpc("authority", "call_local", "reliable")
func _spawn_corpse(cid: int, at: Vector2, count: int) -> void:
	var corpse := Corpse.new()
	corpse.name = "c%d" % cid
	corpse.setup(at, count)
	$Corpses.add_child(corpse)


## Called by a Corpse when its retrieve completes (host only).
func host_corpse_loot(at: Vector2, count: int) -> void:
	if not multiplayer.is_server():
		return
	for i: int in count:
		var rolled: int = LOOT_POOL_ENEMY[randi() % LOOT_POOL_ENEMY.size()]
		_next_loot += 1
		_spawn_loot.rpc(_next_loot, rolled, _scatter_point(at), _amount_for(rolled), false)


## A dead PLAYER's actual belongings hit the floor. High value spills FIRST
## (guns before scrap), ammo re-bundles losslessly, cap keeps it sane.
func host_spill_inventory(at: Vector2, inv: PackedInt32Array) -> void:
	if not multiplayer.is_server():
		return
	var spilled: int = 0
	for item_type: int in range(inv.size() - 1, -1, -1):  # guns (high types) first
		var pile: int = inv[item_type]
		if pile <= 0:
			continue
		if item_type == ITEM_AMMO or item_type == ITEM_AMMO_SMALL:
			# Lossless re-bundle: full cases + one remainder pack.
			while pile > 0 and spilled < 20:
				var pack: int = mini(pile, AMMO_PER_PICKUP)
				pile -= pack
				spilled += 1
				_next_loot += 1
				_spawn_loot.rpc(_next_loot, ITEM_AMMO, _scatter_point(at), pack, false)
			continue
		for i: int in pile:
			if spilled >= 20:
				return
			spilled += 1
			_next_loot += 1
			_spawn_loot.rpc(_next_loot, item_type, _scatter_point(at), 1, false)


func _scatter_point(center: Vector2) -> Vector2:
	for attempt: int in 8:
		var candidate: Vector2 = center + Vector2.RIGHT.rotated(randf() * TAU) * (26.0 + randf() * 18.0)
		if not _inside_any_wall(candidate, 10.0):
			return candidate
	return center


## Obstacle-avoidance steering: probe ahead, swerve around walls instead of
## grinding into them. Cheap stand-in until real navmesh pathing (backlog).
func steer_dir(from: Vector2, desired: Vector2) -> Vector2:
	var space := get_world_2d().direct_space_state
	var look: float = 56.0
	var query := PhysicsRayQueryParameters2D.create(from, from + desired * look, 1)
	if space.intersect_ray(query).is_empty():
		return desired
	for angle: float in [0.6, -0.6, 1.2, -1.2]:
		var alt: Vector2 = desired.rotated(angle)
		query = PhysicsRayQueryParameters2D.create(from, from + alt * look, 1)
		if space.intersect_ray(query).is_empty():
			return alt
	return desired.rotated(2.2)  # boxed in — hard turn back out of the pocket


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
	var store_as: int = item.loot_type
	if item.loot_type == ITEM_AMMO_SMALL:
		store_as = ITEM_AMMO  # small packs pour into the same reserve
	var gain: int = item.amount  # the item says what it grants — no minting
	_loadouts[player_id][store_as] += gain
	_push_loadout(player_id)
	if not item.player_dropped:
		host_award_xp(player_id, 15)  # looter's instinct — found loot only
	print("[loot] player %d picked up %s (+%d)" % [player_id, item.display_name(), gain])
	_despawn_loot.rpc(loot_id)


@rpc("authority", "call_local", "reliable")
func _spawn_loot(loot_id: int, loot_type: int, at: Vector2, qty: int = 1, dropped: bool = false) -> void:
	if _loot.has_node("l%d" % loot_id):
		return
	var item := LootItem.new()
	item.name = "l%d" % loot_id
	item.setup(loot_id, loot_type, at, qty, dropped)
	_loot.add_child(item)


## What a freshly rolled loot diamond of this type contains.
func _amount_for(loot_type: int) -> int:
	if loot_type == ITEM_AMMO:
		return AMMO_PER_PICKUP
	if loot_type == ITEM_AMMO_SMALL:
		return AMMO_SMALL_PICKUP
	return 1


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