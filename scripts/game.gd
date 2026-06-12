extends Node
## Session bootstrap (autoload "Game").
## ENet transport for local play — SteamMultiplayerPeer swaps in via SteamLobby;
## the high-level multiplayer code everywhere else stays unchanged.
## Also owns: input registration, user settings, weapon definitions, SFX.

const DEFAULT_PORT: int = 24565
const MAX_CLIENTS: int = 4
const SETTINGS_PATH: String = "user://settings.json"

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

var _cone_texture: ImageTexture
var _glow_texture: ImageTexture
var _sfx: Dictionary[String, AudioStream] = {}


func _ready() -> void:
	_register_input_actions()
	auto_walk = "--auto-walk" in OS.get_cmdline_user_args()
	_load_settings()
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


func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		dash_to_mouse = bool((parsed as Dictionary).get("dash_to_mouse", false))


func _save_settings() -> void:
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"dash_to_mouse": dash_to_mouse}))


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