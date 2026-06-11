extends Node
## Session bootstrap (autoload "Game").
## ENet transport for the walking skeleton — SteamMultiplayerPeer swaps in HERE
## later; the high-level multiplayer code everywhere else stays unchanged.

const DEFAULT_PORT: int = 24565
const MAX_CLIENTS: int = 4

# Light-shape tuning (cone width is a core feel parameter for this genre).
const CONE_RADIUS_PX: int = 128
const CONE_HALF_ANGLE_DEG: float = 50.0
const GLOW_RADIUS_PX: int = 40
const FALLOFF_EXP: float = 0.55
const EDGE_FADE_DEG: float = 14.0

## Peers whose world is loaded and may receive gameplay RPCs. Host-owned;
## lives on this always-present autoload so the broadcast can never miss.
var ready_peers: PackedInt32Array = PackedInt32Array()

## Headless-harness flag: pawn walks at Brute1 firing, to exercise combat in CI.
var auto_walk: bool = false

var _cone_texture: ImageTexture
var _glow_texture: ImageTexture


func _ready() -> void:
	_register_input_actions()
	auto_walk = "--auto-walk" in OS.get_cmdline_user_args()


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


## The player's sight: a forward cone light (~100 degrees). Generated once, shared.
func cone_texture() -> ImageTexture:
	if _cone_texture == null:
		_cone_texture = _make_light_texture(CONE_RADIUS_PX, CONE_HALF_ANGLE_DEG)
	return _cone_texture


## Small personal glow so you can see your own body and immediate surroundings.
func glow_texture() -> ImageTexture:
	if _glow_texture == null:
		_glow_texture = _make_light_texture(GLOW_RADIUS_PX, 180.0)
	return _glow_texture


func _make_light_texture(radius_px: int, half_angle_deg: float) -> ImageTexture:
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
			var strength: float = pow(1.0 - dist, FALLOFF_EXP) * edge_fade
			img.set_pixel(x, y, Color(strength, strength, strength, 1.0))
	return ImageTexture.create_from_image(img)


func _register_input_actions() -> void:
	_add_key_action(&"move_up", KEY_W)
	_add_key_action(&"move_down", KEY_S)
	_add_key_action(&"move_left", KEY_A)
	_add_key_action(&"move_right", KEY_D)
	_add_key_action(&"dodge", KEY_SPACE)
	_add_key_action(&"interact", KEY_E)
	_add_key_action(&"slot_1", KEY_1)
	_add_key_action(&"slot_2", KEY_2)
	_add_key_action(&"slot_3", KEY_3)
	_add_key_action(&"slot_4", KEY_4)
	_add_key_action(&"reload", KEY_R)
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
