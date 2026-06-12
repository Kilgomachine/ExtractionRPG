extends Control
## Entry point: host/join over Steam (friends, zero config) or ENet (local
## dev testing — two editor instances, or LAN by IP).

const WORLD_SCENE: String = "res://scenes/world.tscn"

@onready var _steam_label: Label = $Center/Column/SteamLabel
@onready var _name_edit: LineEdit = $Center/Column/NameEdit
@onready var _host_steam_button: Button = $Center/Column/HostSteamButton
@onready var _host_button: Button = $Center/Column/HostButton
@onready var _ip_edit: LineEdit = $Center/Column/IpEdit
@onready var _join_button: Button = $Center/Column/JoinButton
@onready var _status: Label = $Center/Column/Status


func _ready() -> void:
	_host_steam_button.pressed.connect(_on_host_steam_pressed)
	_host_button.pressed.connect(_on_host_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	# These auto-disconnect when this menu is freed on scene change.
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	SteamLobby.session_ready.connect(_on_steam_session_ready)
	SteamLobby.session_failed.connect(_on_steam_session_failed)
	_name_edit.text = Game.player_name
	_name_edit.text_changed.connect(func(value: String) -> void: Game.set_player_name(value))
	if SteamLobby.available:
		_steam_label.text = "Steam: %s" % SteamLobby.persona()
		_name_edit.visible = false  # Steam name wins
	else:
		_steam_label.text = "Steam not detected — pick a name below"
		_host_steam_button.disabled = true
	# Headless/CI hooks: `-- --auto-host` or `-- --auto-join` (local ENet).
	# Deferred: changing scenes from inside _ready is unsafe.
	var args := OS.get_cmdline_user_args()
	if "--auto-host" in args:
		_on_host_pressed.call_deferred()
	elif "--auto-join" in args:
		_on_join_pressed.call_deferred()


func _on_host_steam_pressed() -> void:
	_status.text = "Creating Steam lobby…"
	_set_buttons_enabled(false)
	SteamLobby.host()


func _on_steam_session_ready() -> void:
	if multiplayer.is_server():
		print("[menu] hosting via Steam")
		get_tree().change_scene_to_file(WORLD_SCENE)
	else:
		# Client transport is up; world entry happens on connected_to_server.
		_status.text = "Connecting to your friend's raid…"


func _on_steam_session_failed(reason: String) -> void:
	_status.text = reason
	_set_buttons_enabled(true)


func _on_host_pressed() -> void:
	var err: Error = Game.host()
	if err != OK:
		_status.text = "Couldn't host — is another host already running? (error %d)" % err
		return
	print("[menu] hosting on port %d" % Game.DEFAULT_PORT)
	get_tree().change_scene_to_file(WORLD_SCENE)


func _on_join_pressed() -> void:
	var address: String = _ip_edit.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1"
	var err: Error = Game.join(address)
	if err != OK:
		_status.text = "Couldn't start connecting (error %d)" % err
		return
	_status.text = "Connecting to %s…" % address
	print("[menu] connecting to %s" % address)
	_set_buttons_enabled(false)


func _on_connected() -> void:
	print("[menu] connected to host")
	get_tree().change_scene_to_file(WORLD_SCENE)


func _on_connection_failed() -> void:
	Game.leave()
	_status.text = "Connection failed. Host first in the other window, then Join."
	_set_buttons_enabled(true)


func _set_buttons_enabled(enabled: bool) -> void:
	_host_steam_button.disabled = not enabled or not SteamLobby.available
	_host_button.disabled = not enabled
	_join_button.disabled = not enabled
