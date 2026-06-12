class_name LootItem
extends Node2D
## Placeholder ground loot: a colored diamond you click to pick up.
## Spawned/despawned only by host broadcasts; clicking sends a pickup request.
## (No inventory yet — the host just despawns picked items.)

# Index = item type. The earlier 3-entry table silently turned ammo (type 3)
# into scrap via the % clamp — keep this in sync with GameWorld item consts!
const COLORS: Array[Color] = [
	Color(0.72, 0.56, 0.4),   # scrap
	Color(0.45, 0.9, 0.55),   # medkit
	Color(1.0, 0.85, 0.3),    # valuables
	Color(0.55, 0.75, 1.0),   # ammo case
	Color(0.9, 0.35, 0.2),    # frag grenade
	Color(0.7, 0.75, 0.85),   # smoke grenade
	Color(1.0, 0.95, 0.5),    # flashbang
]
const NAMES: Array[String] = ["Scrap", "Medkit", "Valuables", "Ammo", "Frag", "Smoke", "Flash"]
const HOVER_RADIUS: float = 16.0
const PICKUP_RANGE: float = 90.0

var loot_id: int = 0
var loot_type: int = 0

var _hover: bool = false
var _local_pawn: Player


func setup(id: int, type: int, at: Vector2) -> void:
	loot_id = id
	loot_type = type % COLORS.size()
	position = at


func _ready() -> void:
	add_to_group(&"loot")


func _process(_delta: float) -> void:
	# Only show the clickable affordance when a click would actually work:
	# cursor on the item AND the local player close enough to grab it.
	if _local_pawn == null or not is_instance_valid(_local_pawn):
		_find_local_pawn()
	var in_range: bool = _local_pawn != null \
			and _local_pawn.global_position.distance_to(global_position) <= PICKUP_RANGE
	var hovered: bool = in_range \
			and get_global_mouse_position().distance_to(global_position) <= HOVER_RADIUS
	if hovered != _hover:
		_hover = hovered
		scale = Vector2(1.25, 1.25) if _hover else Vector2.ONE
		queue_redraw()


func _find_local_pawn() -> void:
	for node: Node in get_tree().get_nodes_in_group(&"players"):
		var pawn := node as Player
		if pawn != null and pawn.is_multiplayer_authority():
			_local_pawn = pawn
			return


func display_name() -> String:
	return NAMES[loot_type]


func _draw() -> void:
	var color: Color = COLORS[loot_type]
	draw_colored_polygon(PackedVector2Array([
		Vector2(0, -9), Vector2(8, 0), Vector2(0, 9), Vector2(-8, 0),
	]), color)
	if _hover:
		draw_arc(Vector2.ZERO, 13.0, 0.0, TAU, 24, Color(1, 1, 1, 0.9), 1.5)
		draw_string(ThemeDB.fallback_font, Vector2(-30, -16), display_name(),
				HORIZONTAL_ALIGNMENT_CENTER, 60, 11, Color(1, 1, 1, 0.95))