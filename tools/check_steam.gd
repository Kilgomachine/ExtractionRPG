extends SceneTree
## Dev tool: verify the GodotSteam GDExtension is loaded.
## Run: godot --headless -s res://tools/check_steam.gd

func _init() -> void:
	print("[check] Steam class exists: ", ClassDB.class_exists("Steam"))
	print("[check] SteamMultiplayerPeer exists: ", ClassDB.class_exists("SteamMultiplayerPeer"))
	print("[check] Steam singleton: ", Engine.has_singleton("Steam"))
	if ClassDB.class_exists("SteamMultiplayerPeer"):
		var methods: Array[Dictionary] = ClassDB.class_get_method_list("SteamMultiplayerPeer", true)
		var names: Array[String] = []
		for m: Dictionary in methods:
			names.append(m["name"])
		print("[check] SteamMultiplayerPeer methods: ", ", ".join(names))
	quit()
