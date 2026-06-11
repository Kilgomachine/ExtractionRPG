extends SceneTree
## Dev tool: dump the exact GodotSteam API surface we ship (signatures + signals).
## Run: godot --headless -s res://tools/dump_steam_api.gd

const METHODS_OF_INTEREST: Array[String] = [
	"steamInitEx", "run_callbacks", "createLobby", "joinLobby", "leaveLobby",
	"allowP2PPacketRelay", "activateGameOverlayInviteDialog", "setLobbyData",
	"getLobbyData", "setLobbyJoinable", "loggedOn", "getPersonaName", "getSteamID",
]
const SIGNALS_OF_INTEREST: Array[String] = [
	"lobby_created", "lobby_joined", "join_requested", "lobby_invite",
	"persona_state_change",
]


func _init() -> void:
	for m: Dictionary in ClassDB.class_get_method_list("Steam", true):
		if m["name"] in METHODS_OF_INTEREST:
			print("METHOD ", m["name"], " args=", _args(m), " ret=", _type(m["return"]))
	for s: Dictionary in ClassDB.class_get_signal_list("Steam", true):
		if s["name"] in SIGNALS_OF_INTEREST:
			print("SIGNAL ", s["name"], " args=", _args(s))
	quit()


func _args(info: Dictionary) -> String:
	var parts: Array[String] = []
	var defaults: Array = info.get("default_args", [])
	var args: Array = info["args"]
	var first_default: int = args.size() - defaults.size()
	for i: int in args.size():
		var a: Dictionary = args[i]
		var piece: String = String(a["name"]) + ":" + _type(a)
		if i >= first_default:
			piece += "=" + str(defaults[i - first_default])
		parts.append(piece)
	return "(" + ", ".join(parts) + ")"


func _type(a: Dictionary) -> String:
	var t: int = a["type"]
	if t == TYPE_OBJECT:
		return String(a["class_name"])
	if t == TYPE_INT and a.get("class_name", "") != "":
		return String(a["class_name"])
	return type_string(t)
