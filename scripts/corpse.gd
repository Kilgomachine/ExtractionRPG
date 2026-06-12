class_name Corpse
extends Node2D
## A dead bandit's body — lootable with the same two-step search as lockers
## (Investigate, then Retrieve drops the goods). Spawned on every peer by the
## world; the HOST owns the state. Fades away after a while.

const INVESTIGATE_TIME: float = 1.4
const RETRIEVE_TIME: float = 1.2
const SEARCH_RANGE: float = 70.0
const LIFETIME: float = 60.0
const BAR_SIZE := Vector2(40, 6)

enum CorpseState { FULL, INVESTIGATING, INVESTIGATED, RETRIEVING, EMPTY }

var loot_count: int = 1
## Player corpses carry their ACTUAL items (counts by type); empty = roll loot.
var inventory: PackedInt32Array = PackedInt32Array()

var _state: CorpseState = CorpseState.FULL
var _searcher_id: int = 0
var _progress: float = 0.0
var _age: float = 0.0

@onready var _world: GameWorld = get_tree().get_first_node_in_group(&"game_world") as GameWorld


func setup(at: Vector2, count: int) -> void:
	position = at
	loot_count = count


func _ready() -> void:
	add_to_group(&"lockers")  # joins the E-interact pool
	z_index = -4


func _physics_process(delta: float) -> void:
	_age += delta
	if _age >= LIFETIME:
		queue_free()
		return
	if not _is_casting():
		return
	_progress += delta
	queue_redraw()
	if not multiplayer.is_server():
		return
	var pawn: Player = _world.pawn_for(_searcher_id)
	if pawn == null or pawn.dead \
			or pawn.global_position.distance_to(global_position) > SEARCH_RANGE + 14.0:
		_set_state.rpc(CorpseState.FULL if _state == CorpseState.INVESTIGATING
				else CorpseState.INVESTIGATED, 0)
		return
	if _state == CorpseState.INVESTIGATING and _progress >= INVESTIGATE_TIME:
		_set_state.rpc(CorpseState.INVESTIGATED, 0)
	elif _state == CorpseState.RETRIEVING and _progress >= RETRIEVE_TIME:
		if inventory.is_empty():
			_world.host_corpse_loot(global_position, loot_count)
		else:
			_world.host_spill_inventory(global_position, inventory)
		_set_state.rpc(CorpseState.EMPTY, 0)


func can_search() -> bool:
	return _state == CorpseState.FULL or _state == CorpseState.INVESTIGATED


func host_request_search(id: int) -> void:
	if not multiplayer.is_server() or not can_search():
		return
	var pawn: Player = _world.pawn_for(id)
	if pawn == null or pawn.dead:
		return
	if pawn.global_position.distance_to(global_position) > SEARCH_RANGE + 14.0:
		return
	for node: Node in get_tree().get_nodes_in_group(&"lockers"):
		if node != self and node.has_method(&"can_search") \
				and node.get(&"_searcher_id") == id and bool(node.call(&"_is_casting")):
			return
	var next: CorpseState = CorpseState.INVESTIGATING if _state == CorpseState.FULL \
			else CorpseState.RETRIEVING
	_set_state.rpc(next, id)


@rpc("any_peer", "call_remote", "reliable")
func _request_search() -> void:
	if multiplayer.is_server():
		host_request_search(multiplayer.get_remote_sender_id())


@rpc("authority", "call_local", "reliable")
func _set_state(state: int, searcher: int) -> void:
	if _searcher_id != 0 and _searcher_id != searcher:
		var prev: Player = _world.pawn_for(_searcher_id)
		if prev != null and is_instance_valid(prev):
			prev.set_searching(false)
	_state = state as CorpseState
	_searcher_id = searcher
	_progress = 0.0
	if _searcher_id != 0:
		var pawn: Player = _world.pawn_for(_searcher_id)
		if pawn != null:
			pawn.set_searching(_is_casting())
	queue_redraw()


func _is_casting() -> bool:
	return _state == CorpseState.INVESTIGATING or _state == CorpseState.RETRIEVING


func _draw() -> void:
	var fade: float = clampf((LIFETIME - _age) / 6.0, 0.25, 1.0)
	var body_color := Color(0.45, 0.32, 0.3, fade)
	if _state == CorpseState.EMPTY:
		body_color = Color(0.3, 0.24, 0.23, fade * 0.7)
	elif _state == CorpseState.INVESTIGATED:
		body_color = Color(0.55, 0.42, 0.32, fade)
	# A slumped shape.
	draw_colored_polygon(PackedVector2Array([
		Vector2(14, 2), Vector2(6, 8), Vector2(-8, 10), Vector2(-15, 4),
		Vector2(-12, -4), Vector2(-2, -8), Vector2(10, -5),
	]), body_color)
	if _is_casting():
		var origin := Vector2(-BAR_SIZE.x * 0.5, -22.0)
		var total: float = INVESTIGATE_TIME if _state == CorpseState.INVESTIGATING else RETRIEVE_TIME
		var t: float = clampf(_progress / total, 0.0, 1.0)
		var fill := Color(0.95, 0.85, 0.35) if _state == CorpseState.INVESTIGATING \
				else Color(1.0, 0.62, 0.25)
		draw_rect(Rect2(origin, BAR_SIZE), Color(0.05, 0.05, 0.05, 0.85))
		draw_rect(Rect2(origin + Vector2(1, 1), Vector2((BAR_SIZE.x - 2.0) * t, BAR_SIZE.y - 2.0)), fill)