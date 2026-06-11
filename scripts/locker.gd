class_name Locker
extends StaticBody2D
## Searchable container, HOST-OWNED, lives in the world scene. Searching takes
## time (cast bar drawn over the locker); walking away or dying cancels it.
## On completion the host rolls placeholder loot that pops onto the ground.

const SEARCH_TIME: float = 2.5
const SEARCH_RANGE: float = 70.0
const BAR_SIZE := Vector2(40, 6)

enum LockerState { FULL, SEARCHING, EMPTY }

var _state: LockerState = LockerState.FULL
var _searcher_id: int = 0
var _progress: float = 0.0  # host decides completion; clients animate the bar

@onready var _body: Polygon2D = $Body
@onready var _world: GameWorld = get_tree().get_first_node_in_group(&"game_world") as GameWorld


func _ready() -> void:
	add_to_group(&"lockers")
	_apply_visual()


func _physics_process(delta: float) -> void:
	if _state != LockerState.SEARCHING:
		return
	_progress += delta
	queue_redraw()
	if not multiplayer.is_server():
		return
	var pawn: Player = _world.pawn_for(_searcher_id)
	if pawn == null or pawn.dead \
			or pawn.global_position.distance_to(global_position) > SEARCH_RANGE + 14.0:
		_set_state.rpc(LockerState.FULL, 0)  # cancelled — locker stays full
		return
	if _progress >= SEARCH_TIME:
		_world.host_spawn_locker_loot(global_position)
		_set_state.rpc(LockerState.EMPTY, 0)
		print("[loot] locker %s searched by player %d" % [name, _searcher_id])


func can_search() -> bool:
	return _state == LockerState.FULL


## Host-only validation; clients arrive here via _request_search.
func host_request_search(id: int) -> void:
	if not multiplayer.is_server() or _state != LockerState.FULL:
		return
	var pawn: Player = _world.pawn_for(id)
	if pawn == null or pawn.dead:
		return
	# +14 lag margin: the host sees remote pawns ~16px behind their true spot,
	# so a clean client-side E at the range edge must not be silently rejected.
	if pawn.global_position.distance_to(global_position) > SEARCH_RANGE + 14.0:
		return
	_set_state.rpc(LockerState.SEARCHING, id)


@rpc("any_peer", "call_remote", "reliable")
func _request_search() -> void:
	if multiplayer.is_server():
		host_request_search(multiplayer.get_remote_sender_id())


## Host-only: catch a late joiner up (SEARCHING shows as a fresh bar — fine).
func host_full_sync_to(peer_id: int) -> void:
	_set_state.rpc_id(peer_id, _state, _searcher_id)


@rpc("authority", "call_local", "reliable")
func _set_state(state: int, searcher: int) -> void:
	_state = state as LockerState
	_searcher_id = searcher
	_progress = 0.0
	_apply_visual()
	queue_redraw()


func _apply_visual() -> void:
	match _state:
		LockerState.FULL:
			_body.color = Color(0.62, 0.46, 0.26)
		LockerState.SEARCHING:
			_body.color = Color(0.8, 0.65, 0.32)
		LockerState.EMPTY:
			_body.color = Color(0.3, 0.27, 0.23)


func _draw() -> void:
	if _state != LockerState.SEARCHING:
		return
	# Cast bar above the locker.
	var origin := Vector2(-BAR_SIZE.x * 0.5, -24.0)
	var t: float = clampf(_progress / SEARCH_TIME, 0.0, 1.0)
	draw_rect(Rect2(origin, BAR_SIZE), Color(0.05, 0.05, 0.05, 0.85))
	draw_rect(Rect2(origin + Vector2(1, 1), Vector2((BAR_SIZE.x - 2.0) * t, BAR_SIZE.y - 2.0)),
			Color(0.95, 0.85, 0.35))