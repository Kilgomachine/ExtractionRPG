extends Node
## Steam glue (GDScript only — project rule). Initializes Steamworks, owns the
## lobby lifecycle, and wires SteamMultiplayerPeer into Godot's high-level
## multiplayer. Local ENet play in game.gd is untouched; gameplay code never
## talks to Steam directly.

const APP_ID: int = 480  # SpaceWar dev AppID — replace when we own a real one
const LOBBY_ENTER_OK: int = 1  # k_EChatRoomEnterResponseSuccess
const MENU_SCENE: String = "res://scenes/main_menu.tscn"

signal session_ready
signal session_failed(reason: String)

var available: bool = false
var lobby_id: int = 0

var _is_host: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# embed_callbacks=true: GodotSteam pumps Steam callbacks itself — no
	# run_callbacks() loop to forget, no pausable-autoload foot-gun.
	var response: Dictionary = Steam.steamInitEx(APP_ID, true)
	available = int(response.get("status", -1)) == 0 and Steam.loggedOn()
	print("[steam] init %s — available: %s" % [response, available])
	if not available:
		return
	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)
	Steam.join_requested.connect(_on_join_requested)
	_check_command_line()


func persona() -> String:
	return Steam.getPersonaName() if available else ""


## Host a friends-only lobby; emits session_ready once the transport is live.
func host() -> void:
	if not available:
		session_failed.emit("Steam isn't running — use local play instead.")
		return
	if lobby_id != 0:
		_close_lobby()
	_is_host = true
	Steam.createLobby(Steam.LOBBY_TYPE_FRIENDS_ONLY, Game.MAX_CLIENTS)


## Join a friend's lobby (invite, friends-list "Join Game", or +connect_lobby).
func join(target_lobby_id: int) -> void:
	if not available:
		session_failed.emit("Steam isn't running — can't join a Steam raid.")
		return
	_is_host = false
	Steam.joinLobby(target_lobby_id)


## Opens the Steam overlay's invite dialog for the current lobby.
func invite_friends() -> void:
	if available and lobby_id != 0:
		Steam.activateGameOverlayInviteDialog(lobby_id)


## Called by Game.leave() so leaving a raid also leaves the Steam lobby.
func on_session_left() -> void:
	_close_lobby()


func _close_lobby() -> void:
	if available and lobby_id != 0:
		Steam.leaveLobby(lobby_id)
	lobby_id = 0
	_is_host = false


func _on_lobby_created(status: int, new_lobby_id: int) -> void:
	if status != 1:
		_is_host = false
		session_failed.emit("Couldn't create a Steam lobby (result %d)." % status)
		return
	lobby_id = new_lobby_id
	Steam.setLobbyJoinable(lobby_id, true)
	Steam.setLobbyData(lobby_id, "name", "%s's raid" % persona())
	Steam.allowP2PPacketRelay(true)
	var peer: SteamMultiplayerPeer = SteamMultiplayerPeer.new()
	peer.host_with_lobby(lobby_id)
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		_close_lobby()
		session_failed.emit("Steam transport failed to start hosting.")
		return
	multiplayer.multiplayer_peer = peer
	Game.ready_peers = PackedInt32Array([1])
	print("[steam] hosting lobby %d" % lobby_id)
	session_ready.emit()


func _on_lobby_joined(this_lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	if _is_host:
		return  # creators also receive lobby_joined for their own lobby
	if response != LOBBY_ENTER_OK:
		session_failed.emit("Couldn't enter the lobby (response %d)." % response)
		return
	lobby_id = this_lobby_id
	Steam.allowP2PPacketRelay(true)
	var peer: SteamMultiplayerPeer = SteamMultiplayerPeer.new()
	peer.connect_to_lobby(lobby_id)
	multiplayer.multiplayer_peer = peer
	Game.ready_peers = PackedInt32Array()
	print("[steam] joined lobby %d, connecting to host…" % lobby_id)
	session_ready.emit()
	# From here the normal flow takes over: multiplayer.connected_to_server
	# fires once the transport reaches the host, and the menu changes scene.


func _on_join_requested(this_lobby_id: int, friend_id: int) -> void:
	print("[steam] join requested: lobby %d (friend %d)" % [this_lobby_id, friend_id])
	var scene: Node = get_tree().current_scene
	if scene != null and scene.scene_file_path != MENU_SCENE:
		# Mid-raid invite accept: bail to the menu first so its listeners
		# (connected_to_server → enter world) are in place.
		Game.leave()
		get_tree().change_scene_to_file(MENU_SCENE)
		await get_tree().process_frame
	join(this_lobby_id)


func _check_command_line() -> void:
	# Accepting an invite with the game closed launches it with
	# `+connect_lobby <id>` (before any `--`, so get_cmdline_args).
	var args: PackedStringArray = OS.get_cmdline_args()
	var index: int = args.find("+connect_lobby")
	if index != -1 and index + 1 < args.size():
		var target: int = int(args[index + 1])
		if target > 0:
			print("[steam] +connect_lobby %d" % target)
			join.call_deferred(target)
