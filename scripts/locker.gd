class_name Locker
extends StaticBody2D
## Searchable container, HOST-OWNED, lives in the world scene. TWO-step search:
## E to INVESTIGATE (long cast), then E again to RETRIEVE (shorter cast) which
## drops the loot. Searching dims the searcher's vision hard — bring a friend.
## Walking away or dying cancels the active cast (progress on that step lost).

const INVESTIGATE_TIME: float = 2.0
const RETRIEVE_TIME: float = 1.5
const SEARCH_RANGE: float = 70.0
const BAR_SIZE := Vector2(40, 6)

enum LockerState { FULL, INVESTIGATING, INVESTIGATED, RETRIEVING, EMPTY }

var _state: LockerState = LockerState.FULL
var _searcher_id: int = 0
var _progress: float = 0.0  # host decides completion; clients animate the bar

@onready var _body: Polygon2D = $Body
@onready var _world: GameWorld = get_tree().get_first_node_in_group(&"game_world") as GameWorld


func _ready() -> void:
	add_to_group(&"lockers")
	_apply_visual()


func _physics_process(delta: float) -> void:
	if not _is_casting():
		return
	_progress += delta
	queue_redraw()
	if not multiplayer.is_server():
		return
	var pawn: Player = _world.pawn_for(_searcher_id)
	if pawn == null or pawn.dead \
			or pawn.global_position.distance_to(global_position) > SEARCH_RANGE + 14.0:
		# Cancelled — fall back to the last stable state.
		_set_state.rpc(LockerState.FULL if _state == LockerState.INVESTIGATING
				else LockerState.INVESTIGATED, 0)
		return
	if _state == LockerState.INVESTIGATING and _progress >= INVESTIGATE_TIME:
		_set_state.rpc(LockerState.INVESTIGATED, 0)
		print("[loot] locker %s investigated by player %d — something's inside" % [name, _searcher_id])
	elif _state == LockerState.RETRIEVING and _progress >= RETRIEVE_TIME:
		_world.host_spawn_locker_loot(global_position)
		_set_state.rpc(LockerState.EMPTY, 0)
		print("[loot] locker %s emptied by player %d" % [name, _searcher_id])


func can_search() -> bool:
	return _state == LockerState.FULL or _state == LockerState.INVESTIGATED


## Host-only validation; clients arrive here via _request_search.
func host_request_search(id: int) -> void:
	if not multiplayer.is_server() or not can_search():
		return
	var pawn: Player = _world.pawn_for(id)
	if pawn == null or pawn.dead:
		return
	# +14 lag margin: the host sees remote pawns ~16px behind their true spot.
	if pawn.global_position.distance_to(global_position) > SEARCH_RANGE + 14.0:
		return
	# One search at a time per player — two overlapping casts would corrupt
	# the single _searching dim flag on the pawn.
	for node: Node in get_tree().get_nodes_in_group(&"lockers"):
		var other := node as Locker
		if other != null and other != self and other._is_casting() and other._searcher_id == id:
			return
	var next: LockerState = LockerState.INVESTIGATING if _state == LockerState.FULL \
			else LockerState.RETRIEVING
	_set_state.rpc(next, id)


@rpc("any_peer", "call_remote", "reliable")
func _request_search() -> void:
	if multiplayer.is_server():
		host_request_search(multiplayer.get_remote_sender_id())


## Host-only: catch a late joiner up (an active cast shows as a fresh bar — fine).
func host_full_sync_to(peer_id: int) -> void:
	_set_state.rpc_id(peer_id, _state, _searcher_id)


@rpc("authority", "call_local", "reliable")
func _set_state(state: int, searcher: int) -> void:
	# Un-dim the previous searcher before switching.
	if _searcher_id != 0 and _searcher_id != searcher:
		var prev: Player = _world.pawn_for(_searcher_id)
		if prev != null and is_instance_valid(prev):
			prev.set_searching(false)
	_state = state as LockerState
	_searcher_id = searcher
	_progress = 0.0
	if _searcher_id != 0:
		var pawn: Player = _world.pawn_for(_searcher_id)
		if pawn != null:
			pawn.set_searching(_is_casting())
	_apply_visual()
	queue_redraw()


func _is_casting() -> bool:
	return _state == LockerState.INVESTIGATING or _state == LockerState.RETRIEVING


func _cast_duration() -> float:
	return INVESTIGATE_TIME if _state == LockerState.INVESTIGATING else RETRIEVE_TIME


func _apply_visual() -> void:
	match _state:
		LockerState.FULL:
			_body.color = Color(0.62, 0.46, 0.26)
		LockerState.INVESTIGATING:
			_body.color = Color(0.78, 0.64, 0.32)
		LockerState.INVESTIGATED:
			_body.color = Color(0.75, 0.68, 0.45)  # lighter: "something's inside"
		LockerState.RETRIEVING:
			_body.color = Color(0.88, 0.6, 0.3)
		LockerState.EMPTY:
			_body.color = Color(0.3, 0.27, 0.23)


func _draw() -> void:
	if not _is_casting():
		return
	var origin := Vector2(-BAR_SIZE.x * 0.5, -24.0)
	var t: float = clampf(_progress / _cast_duration(), 0.0, 1.0)
	var fill := Color(0.95, 0.85, 0.35) if _state == LockerState.INVESTIGATING \
			else Color(1.0, 0.62, 0.25)
	draw_rect(Rect2(origin, BAR_SIZE), Color(0.05, 0.05, 0.05, 0.85))
	draw_rect(Rect2(origin + Vector2(1, 1), Vector2((BAR_SIZE.x - 2.0) * t, BAR_SIZE.y - 2.0)), fill)