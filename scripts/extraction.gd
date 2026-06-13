class_name ExtractionZone
extends Node2D
## Stand in the green circle to extract. It takes a while — and the machinery
## is LOUD: every few seconds it alerts everything in earshot. Hunt grammar:
## leaving resets you; extraction is per-player.

const RADIUS: float = 90.0
const EXTRACT_TIME: float = 15.0
const NOISE_INTERVAL: float = 2.0
const NOISE_RANGE: float = 900.0

var _progress: Dictionary[int, float] = {}
var _noise_left: float = 0.0
var _active: bool = false  # someone is extracting (drives the visuals/noise)

@onready var _world: GameWorld = get_tree().get_first_node_in_group(&"game_world") as GameWorld


func _ready() -> void:
	z_index = -5
	var light := PointLight2D.new()
	light.texture = Game.glow_texture()
	light.texture_scale = RADIUS / float(Game.GLOW_RADIUS_PX)
	light.color = Color(0.4, 1.0, 0.55)
	light.energy = 0.5
	add_child(light)


func _physics_process(delta: float) -> void:
	queue_redraw()
	if not multiplayer.is_server():
		return
	var someone: bool = false
	for pawn: Player in _world.alive_pawns():
		var id: int = str(pawn.name).to_int()
		if pawn.global_position.distance_to(global_position) <= RADIUS:
			someone = true
			_progress[id] = float(_progress.get(id, 0.0)) + delta
			if _progress[id] >= EXTRACT_TIME:
				_progress.erase(id)
				_world.host_extract_player(id)
		elif _progress.has(id):
			_progress.erase(id)  # stepped out — start over
	# Sweep progress that alive_pawns() can no longer see: a player who went
	# DOWNED, died, or despawned mid-extract. Without this their progress freezes
	# and a revive-in-zone would resume the head-start (skipping the bleed window).
	for id: int in _progress.keys():
		var holder: Player = _world.pawn_for(id)
		if holder == null or holder.dead or holder.downed \
				or holder.global_position.distance_to(global_position) > RADIUS:
			_progress.erase(id)
	if someone != _active:
		_active = someone
		_set_active.rpc(someone)
	if _active:
		_noise_left -= delta
		if _noise_left <= 0.0:
			_noise_left = NOISE_INTERVAL
			# The generator screams — everything comes to look.
			_world.host_alert_enemies(global_position, global_position, NOISE_RANGE)


@rpc("authority", "call_local", "reliable")
func _set_active(active: bool) -> void:
	_active = active


func _draw() -> void:
	draw_circle(Vector2.ZERO, RADIUS, Color(0.25, 0.8, 0.4, 0.12))
	draw_arc(Vector2.ZERO, RADIUS, 0.0, TAU, 48, Color(0.4, 1.0, 0.55, 0.8), 3.0)
	if _active:
		var t: float = fposmod(Time.get_ticks_msec() * 0.001, 1.2) / 1.2
		draw_arc(Vector2.ZERO, RADIUS * (1.0 + t * 0.5), 0.0, TAU, 48,
				Color(0.4, 1.0, 0.55, 0.6 * (1.0 - t)), 2.0)
	# Host draws per-player progress for whoever's inside (local view only needs own).
	var pawn: Player = _world.local_pawn() if _world != null else null
	if pawn != null and not pawn.dead \
			and pawn.global_position.distance_to(global_position) <= RADIUS:
		draw_arc(Vector2.ZERO, RADIUS - 10.0, -PI / 2.0,
				-PI / 2.0 + TAU * _local_progress_guess(), 48, Color(1, 1, 1, 0.9), 4.0)


# Clients don't get per-frame progress sync; they animate from entry time.
var _entered_at_ms: int = -1


func _local_progress_guess() -> float:
	var pawn: Player = _world.local_pawn()
	if pawn == null:
		return 0.0
	var inside: bool = pawn.global_position.distance_to(global_position) <= RADIUS
	if not inside:
		_entered_at_ms = -1
		return 0.0
	if _entered_at_ms < 0:
		_entered_at_ms = Time.get_ticks_msec()
	return clampf(float(Time.get_ticks_msec() - _entered_at_ms) / (EXTRACT_TIME * 1000.0), 0.0, 1.0)