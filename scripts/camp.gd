extends Control
## Pre-raid camp. Pick what to bring from your persistent stash, then Deploy.
## Each peer runs its OWN camp locally; the chosen loadout rides on the Game
## autoload into the raid. Deploy WITHDRAWS the kit from the stash — extract to
## bank it back (plus loot), or die and it stays on your corpse. The host enters
## the raid first; a joining client's world.gd retries the join until the host's
## world exists, so no cross-peer camp coordination is needed.

const WORLD_SCENE: String = "res://scenes/world.tscn"
const ITEM_TYPES: int = 12
const GUN_TYPES: Array[int] = [7, 8, 9, 10]  # rifle, smg, shotgun, laser

var _stash_view: Dictionary = {}  # String key "0".."11" -> int; depletes as you pack
var _loadout: Dictionary = {}     # String key -> int; what you'll bring
var _equipped: int = -1

@onready var _stash_list: VBoxContainer = $Center/Column/Cols/StashCol/StashList
@onready var _loadout_list: VBoxContainer = $Center/Column/Cols/LoadoutCol/LoadoutList
@onready var _deploy: Button = $Center/Column/Deploy
@onready var _status: Label = $Center/Column/Status


func _ready() -> void:
	_stash_view = Game.stash.duplicate()
	_deploy.pressed.connect(_on_deploy)
	_refresh()
	# Headless/CI: skip the screen entirely and let world.gd seed the default
	# testing kit (empty chosen_loadout => default), without touching the stash.
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if Game.auto_walk or "--auto-host" in args or "--auto-join" in args:
		Game.chosen_loadout = PackedInt32Array()
		Game.chosen_equipped = -1
		_go_to_raid.call_deferred()


func _on_deploy() -> void:
	var counts := PackedInt32Array()
	counts.resize(ITEM_TYPES)
	for key: String in _loadout:
		counts[int(key)] = int(_loadout[key])
	Game.chosen_loadout = counts
	Game.chosen_equipped = _equipped
	Game.stash_remove(counts)  # the gear leaves the bank and rides into the raid
	Game.pending_kit = counts.duplicate()  # at risk until extract/death/leave settles it
	_go_to_raid()


func _go_to_raid() -> void:
	get_tree().change_scene_to_file(WORLD_SCENE)


# --- packing ------------------------------------------------------------------

func _bring(item_type: int) -> void:
	var key: String = str(item_type)
	var n: int = int(_stash_view.get(key, 0))
	if n <= 0:
		return
	_loadout[key] = int(_loadout.get(key, 0)) + n
	_stash_view.erase(key)
	if item_type in GUN_TYPES and _equipped < 0:
		_equipped = item_type  # auto-equip the first gun you pack
	_refresh()


func _return_item(item_type: int) -> void:
	var key: String = str(item_type)
	var n: int = int(_loadout.get(key, 0))
	if n <= 0:
		return
	_stash_view[key] = int(_stash_view.get(key, 0)) + n
	_loadout.erase(key)
	if _equipped == item_type:
		_equipped = _first_owned_gun()
	_refresh()


func _equip(item_type: int) -> void:
	_equipped = item_type
	_refresh()


func _first_owned_gun() -> int:
	for g: int in GUN_TYPES:
		if int(_loadout.get(str(g), 0)) > 0:
			return g
	return -1


func _count(data: Dictionary) -> int:
	var total: int = 0
	for key: String in data:
		total += int(data[key])
	return total


# --- rendering ----------------------------------------------------------------

func _refresh() -> void:
	_rebuild(_stash_list, _stash_view, true)
	_rebuild(_loadout_list, _loadout, false)
	var equipped_note: String = ""
	if _equipped >= 0 and _equipped < LootItem.NAMES.size():
		equipped_note = "  ·  equipped: %s" % LootItem.NAMES[_equipped]
	_status.text = "Deploying with %d items%s" % [_count(_loadout), equipped_note]


func _rebuild(list: VBoxContainer, data: Dictionary, is_stash: bool) -> void:
	for child: Node in list.get_children():
		child.queue_free()
	var any: bool = false
	for item_type: int in ITEM_TYPES:
		var key: String = str(item_type)
		var n: int = int(data.get(key, 0))
		if n <= 0:
			continue
		any = true
		var row := HBoxContainer.new()
		var label := Label.new()
		var item_name: String = LootItem.NAMES[item_type] if item_type < LootItem.NAMES.size() else "?"
		var tag: String = "   [equipped]" if (not is_stash and item_type == _equipped) else ""
		label.text = "%s ×%d%s" % [item_name, n, tag]
		label.custom_minimum_size.x = 180
		row.add_child(label)
		if is_stash:
			var bring := Button.new()
			bring.text = "Bring ▶"
			bring.pressed.connect(_bring.bind(item_type))
			row.add_child(bring)
		else:
			if item_type in GUN_TYPES and item_type != _equipped:
				var equip := Button.new()
				equip.text = "Equip"
				equip.pressed.connect(_equip.bind(item_type))
				row.add_child(equip)
			var back := Button.new()
			back.text = "◀ Stash"
			back.pressed.connect(_return_item.bind(item_type))
			row.add_child(back)
		list.add_child(row)
	if not any:
		var empty := Label.new()
		empty.text = "(empty)"
		list.add_child(empty)
