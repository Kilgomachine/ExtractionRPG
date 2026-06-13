extends Node
## Session bootstrap (autoload "Game").
## ENet transport for local play — SteamMultiplayerPeer swaps in via SteamLobby;
## the high-level multiplayer code everywhere else stays unchanged.
## Also owns: input registration, user settings, weapon definitions, SFX.

const DEFAULT_PORT: int = 24565
const MAX_CLIENTS: int = 4
const SETTINGS_PATH: String = "user://settings.json"
const STASH_PATH: String = "user://stash.json"
const STASH_ITEM_TYPES: int = 12  # mirrors GameWorld.ITEM_TYPES
const STASH_ITEM_CAP: int = 999   # sane per-type ceiling (corrupt-file guard)
# Scav fallback so a broke player is never soft-locked: index = item type.
# [scrap, medkit, valuable, ammo, frag, smoke, flash, rifle, smg, shotgun, laser, ammo_small]
const STARTER_KIT: Array[int] = [0, 2, 0, 30, 1, 1, 0, 1, 0, 0, 0, 0]

# Light-shape tuning (cone width is a core feel parameter for this genre).
const CONE_RADIUS_PX: int = 128
const CONE_HALF_ANGLE_DEG: float = 50.0
const GLOW_RADIUS_PX: int = 40
const FALLOFF_EXP: float = 0.55
const EDGE_FADE_DEG: float = 14.0

# Primary gun definitions (host validates against these — keep in sync with HUD).
# pellets > 1 = spread shot; interval in ms; dmg per projectile.
const GUNS: Array[Dictionary] = [
	{"name": "Rifle", "mag": 8, "dmg": 12, "interval_ms": 280, "pellets": 1, "spread_deg": 0.0, "sfx": "shot"},
	{"name": "SMG", "mag": 24, "dmg": 6, "interval_ms": 110, "pellets": 1, "spread_deg": 5.0, "sfx": "shot_smg"},
	{"name": "Shotgun", "mag": 4, "dmg": 8, "interval_ms": 900, "pellets": 5, "spread_deg": 11.0, "sfx": "shot_shotgun"},
]
const GRENADES: Array[String] = ["Frag", "Smoke", "Flash"]

## Peers whose world is loaded and may receive gameplay RPCs. Host-owned;
## lives on this always-present autoload so the broadcast can never miss.
var ready_peers: PackedInt32Array = PackedInt32Array()

## Headless-harness flag: pawn walks at Brute1 firing, to exercise combat in CI.
var auto_walk: bool = false

## User settings (persisted to user://settings.json — JSON only, per rules).
var dash_to_mouse: bool = false
var player_name: String = "Mercenary"

## Per-client persistent stash (user://stash.json — JSON only). String item-key
## "0".."11" -> int count. This is the player's bank: extraction deposits here,
## the camp withdraws from here, death loses what was carried.
var stash: Dictionary = {}

## The kit the Camp scene chose to bring into the next raid. Length-12 counts +
## the gun to equip. Empty counts => world.gd seeds the default testing kit
## (keeps the headless harness working). Carried across the Camp->raid scene
## change because this autoload outlives both scenes.
var chosen_loadout: PackedInt32Array = PackedInt32Array()
var chosen_equipped: int = -1

## The kit currently AT RISK in the raid — withdrawn from the stash on Deploy.
## Cleared when its fate is decided (extract banks the survivors; death loses it
## to the corpse). If a raid is left ALIVE without either — menu-leave, host
## disconnect, or a join that never lands — this is re-banked so withdrawn gear
## is never silently destroyed. Lives on this autoload so even a host-drop (no
## host to arbitrate) can be made whole client-side.
var pending_kit: PackedInt32Array = PackedInt32Array()

var _cone_texture: ImageTexture
var _glow_texture: ImageTexture
var _sfx: Dictionary[String, AudioStream] = {}


func _ready() -> void:
	_register_input_actions()
	auto_walk = "--auto-walk" in OS.get_cmdline_user_args()
	_load_settings()
	_load_stash()
	for sfx_name: String in ["shot", "shot_smg", "shot_shotgun", "laser", "boom",
			"hit", "dodge", "heal", "flame", "flash", "latch"]:
		var stream := load("res://assets/sfx/%s.wav" % sfx_name) as AudioStream
		if stream != null:
			_sfx[sfx_name] = stream


func host() -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err: Error = peer.create_server(DEFAULT_PORT, MAX_CLIENTS)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	ready_peers = PackedInt32Array([1])
	return OK


func join(address: String) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(address, DEFAULT_PORT)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	ready_peers = PackedInt32Array()
	return OK


func leave() -> void:
	ready_peers = PackedInt32Array()
	SteamLobby.on_session_left()
	# Order matters: close() the old peer FIRST, then assign the fresh offline
	# peer — set_multiplayer_peer rejects peers in DISCONNECTED state.
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()


@rpc("authority", "call_remote", "reliable")
func _set_ready_peers(ids: PackedInt32Array) -> void:
	ready_peers = ids


# --- settings ----------------------------------------------------------------

func set_dash_to_mouse(value: bool) -> void:
	dash_to_mouse = value
	_save_settings()


func set_player_name(value: String) -> void:
	player_name = value.strip_edges().substr(0, 24)
	if player_name.is_empty():
		player_name = "Mercenary"
	_save_settings()


## The name everyone sees: Steam persona when available, manual otherwise.
func display_name() -> String:
	if SteamLobby.available:
		return SteamLobby.persona()
	return player_name


func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		var dict := parsed as Dictionary
		dash_to_mouse = bool(dict.get("dash_to_mouse", false))
		player_name = String(dict.get("player_name", "Mercenary"))


func _save_settings() -> void:
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"dash_to_mouse": dash_to_mouse,
		"player_name": player_name,
	}))


# --- stash (per-client, JSON only — same security rules as settings) -----------

func _load_stash() -> void:
	stash = {}
	if FileAccess.file_exists(STASH_PATH):
		var file := FileAccess.open(STASH_PATH, FileAccess.READ)
		if file != null:
			var parsed: Variant = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary:
				var dict := parsed as Dictionary
				# Rebuild from the trusted key domain only — a hand-edited file
				# can't inject unknown keys, negatives, or absurd counts.
				for t: int in STASH_ITEM_TYPES:
					var key: String = str(t)
					var count: int = clampi(int(dict.get(key, 0)), 0, STASH_ITEM_CAP)
					if count > 0:
						stash[key] = count
	# Broke (or first launch): hand out the free scav kit so the loop never
	# soft-locks. You keep earned gear; lose everything and you fall back here.
	if _stash_total() == 0:
		for t: int in STASH_ITEM_TYPES:
			if STARTER_KIT[t] > 0:
				stash[str(t)] = STARTER_KIT[t]
		_save_stash()


func _save_stash() -> void:
	var file := FileAccess.open(STASH_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(stash))


func _stash_total() -> int:
	var total: int = 0
	for key: String in stash:
		total += int(stash[key])
	return total


## The stash as a length-12 counts array (item type index -> count).
func stash_counts() -> PackedInt32Array:
	var counts := PackedInt32Array()
	counts.resize(STASH_ITEM_TYPES)
	for t: int in STASH_ITEM_TYPES:
		counts[t] = int(stash.get(str(t), 0))
	return counts


## Add a deposit (length-12 counts, e.g. an extracted loadout) and persist.
func stash_add(counts: PackedInt32Array) -> void:
	for t: int in mini(counts.size(), STASH_ITEM_TYPES):
		if counts[t] > 0:
			stash[str(t)] = clampi(int(stash.get(str(t), 0)) + counts[t], 0, STASH_ITEM_CAP)
	_save_stash()


## Settle the at-risk kit when leaving a raid ALIVE (not extract/death): bank the
## given counts — the CURRENT host-synced loadout, net of drops/pickups/reloads,
## NOT the stale deploy-time snapshot (which would dupe items dropped to a friend
## who then extracts them). Idempotent: only fires while a kit is actually at risk.
func settle_pending_kit(current_counts: PackedInt32Array) -> void:
	if pending_kit.is_empty():
		return
	stash_add(current_counts)
	pending_kit = PackedInt32Array()


## The kit's fate is settled (extracted-and-deposited, or lost to a corpse).
func clear_pending_kit() -> void:
	pending_kit = PackedInt32Array()


## Withdraw a loadout (length-12 counts) from the stash and persist. Clamps so
## you can never pull more of a type than you actually own.
func stash_remove(counts: PackedInt32Array) -> void:
	for t: int in mini(counts.size(), STASH_ITEM_TYPES):
		if counts[t] <= 0:
			continue
		var key: String = str(t)
		var left: int = int(stash.get(key, 0)) - counts[t]
		if left > 0:
			stash[key] = left
		else:
			stash.erase(key)
	_save_stash()


# --- audio ---------------------------------------------------------------------

## Fire-and-forget positional SFX. Safe to call on any peer, any time.
func play_sfx(sfx_name: String, at: Vector2) -> void:
	if not _sfx.has(sfx_name):
		return
	var scene: Node = get_tree().current_scene
	if scene == null:
		return
	var player := AudioStreamPlayer2D.new()
	player.stream = _sfx[sfx_name]
	player.position = at
	player.volume_db = -6.0
	player.max_distance = 1400.0
	player.finished.connect(player.queue_free)
	scene.add_child(player)
	player.play()


# --- light textures --------------------------------------------------------------

## The player's sight: a forward cone light (~100 degrees). Generated once, shared.
func cone_texture() -> ImageTexture:
	if _cone_texture == null:
		_cone_texture = _make_light_texture(CONE_RADIUS_PX, CONE_HALF_ANGLE_DEG, 1.0)
	return _cone_texture


## Personal glow: full circle but LOPSIDED — reach behind you is much weaker,
## so your back is genuinely more blind than your front.
func glow_texture() -> ImageTexture:
	if _glow_texture == null:
		_glow_texture = _make_light_texture(GLOW_RADIUS_PX, 180.0, 0.45)
	return _glow_texture


func _make_light_texture(radius_px: int, half_angle_deg: float, back_strength: float) -> ImageTexture:
	var size: int = radius_px * 2
	var img := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(radius_px, radius_px)
	var full_circle: bool = half_angle_deg >= 180.0
	for y: int in size:
		for x: int in size:
			var offset := Vector2(x, y) - center
			var dist: float = offset.length() / float(radius_px)
			if dist >= 1.0:
				continue
			var angle_deg: float = absf(rad_to_deg(offset.angle()))
			if not full_circle and angle_deg > half_angle_deg:
				continue
			# No angular fade on full circles — it would carve a dark wedge at ±180°.
			var edge_fade: float = 1.0 if full_circle \
					else clampf((half_angle_deg - angle_deg) / EDGE_FADE_DEG, 0.0, 1.0)
			# Lopsided falloff: shrink effective reach as the angle swings rearward.
			var rear: float = clampf(angle_deg / 180.0, 0.0, 1.0)
			var reach: float = lerpf(1.0, back_strength, rear * rear) if full_circle else 1.0
			var local_dist: float = clampf(dist / reach, 0.0, 1.0)
			if local_dist >= 1.0:
				continue
			var strength: float = pow(1.0 - local_dist, FALLOFF_EXP) * edge_fade
			img.set_pixel(x, y, Color(strength, strength, strength, 1.0))
	return ImageTexture.create_from_image(img)


# --- input ----------------------------------------------------------------------

func _register_input_actions() -> void:
	_add_key_action(&"move_up", KEY_W)
	_add_key_action(&"move_down", KEY_S)
	_add_key_action(&"move_left", KEY_A)
	_add_key_action(&"move_right", KEY_D)
	_add_key_action(&"dodge", KEY_SPACE)
	_add_key_action(&"sprint", KEY_SHIFT)
	_add_key_action(&"interact", KEY_E)
	_add_key_action(&"reload", KEY_R)
	_add_key_action(&"bag", KEY_B)
	_add_key_action(&"skills", KEY_K)
	_add_key_action(&"scoreboard", KEY_TAB)
	_add_key_action(&"slot_1", KEY_1)
	_add_key_action(&"slot_2", KEY_2)
	_add_key_action(&"slot_3", KEY_3)
	_add_key_action(&"slot_4", KEY_4)
	_add_mouse_action(&"fire", MOUSE_BUTTON_LEFT)


func _add_key_action(action: StringName, key: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var event := InputEventKey.new()
	event.physical_keycode = key
	InputMap.action_add_event(action, event)


func _add_mouse_action(action: StringName, button: MouseButton) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var event := InputEventMouseButton.new()
	event.button_index = button
	InputMap.action_add_event(action, event)