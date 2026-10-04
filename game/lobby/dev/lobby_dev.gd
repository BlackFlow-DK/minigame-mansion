extends Node3D
## Dev view of the lobby hall: offline, you + bots, like the sandbox (the sandbox only takes
## registry ids). User args after `--`:
##   --players=N        total players 1..8 (default 8: you + 7 bots)
##   --scatter          start the players around the hall's toys instead of on the spawn arc
##   --warmup=S         run the first S seconds at --timescale=X (default 4) so bots spread out
##   --overview         hold a fixed camera over the whole hall instead of framing the players
##   --focus=x,y,z      hold a fixed camera on that point (close-ups of the toys), with
##   --distance=D       its distance (default 7)
##   --toy=<name>       stage a toy for a screenshot: goal (the ball in the red goal), bell (rung),
##                      photo (countdown started, blobs in the area), seesaw (blobs on it),
##                      trampoline (a blob bouncing), flare (the portal flares)
## Esc / Start (`pause`) quits.

const LOBBY: PackedScene = preload("res://lobby/lobby.tscn")
const SCATTER: Array[Vector3] = [
	Vector3(-5.9, 0.6, -3.0), Vector3(0.4, 2.0, -7.4), Vector3(8.0, 0.0, -3.4), Vector3(-8.2, 0.0, -1.8),
	Vector3(3.0, 0.0, 4.0), Vector3(-1.0, 1.0, -4.5), Vector3(10.3, 0.6, -1.0), Vector3(-6.5, 0.0, 6.0),
]

@onready var stage: Stage = $Stage

var _toy: String = ""
var _frame: int = 0
var _lobby: MansionLobby = null
var _players: Array[Player] = []


func _ready() -> void:
	var player_count := 8
	var scatter := false
	var warmup := 0.0
	var timescale := 4.0
	var overview := false
	var focus := Vector3.INF
	var distance := 7.0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--focus="):
			var v := arg.trim_prefix("--focus=").split(",")
			if v.size() == 3:
				focus = Vector3(v[0].to_float(), v[1].to_float(), v[2].to_float())
		elif arg.begins_with("--distance="):
			distance = arg.trim_prefix("--distance=").to_float()
		elif arg.begins_with("--toy="):
			_toy = arg.trim_prefix("--toy=")
		if arg.begins_with("--players="):
			player_count = clampi(arg.trim_prefix("--players=").to_int(), 1, Net.MAX_PLAYERS)
		elif arg == "--scatter":
			scatter = true
		elif arg.begins_with("--warmup="):
			warmup = arg.trim_prefix("--warmup=").to_float()
		elif arg.begins_with("--timescale="):
			timescale = arg.trim_prefix("--timescale=").to_float()
		elif arg == "--overview":
			overview = true
	Net.start_offline()
	for i in player_count - 1:
		Net.add_bot()
	var lobby := stage.load_minigame_scene(LOBBY)
	if lobby == null:
		return
	var players: Array[Player] = []
	players.assign(stage.players.values())
	lobby._setup(players)
	for p in players:
		p.frozen = false
	lobby._start()
	if scatter:
		for i in players.size():
			players[i].place_at(Transform3D(Basis(), SCATTER[i % SCATTER.size()]))
	if overview or focus != Vector3.INF:
		var cam := lobby.get_node(^"Camera") as ArenaCamera
		cam.mode = ArenaCamera.Mode.FIXED
		if focus != Vector3.INF:
			cam.fixed_focus = focus
			cam.fixed_distance = distance
			cam.distance = distance
	_lobby = lobby as MansionLobby
	_players = players
	if warmup > 0.0:
		Engine.time_scale = timescale
		get_tree().create_timer(warmup / maxf(timescale, 0.01), true, false, true).timeout.connect(func() -> void: Engine.time_scale = 1.0)
	print("lobby_dev: %d player(s)" % players.size())


func _physics_process(delta: float) -> void:
	if stage.minigame and not stage.minigame.is_finished():
		stage.minigame._host_tick(delta)
	_frame += 1
	if _lobby and _toy != "":
		_stage_toy()


## Sets a toy up for a screenshot (see --toy) on a schedule of physics frames.
func _stage_toy() -> void:
	var lb := _lobby
	var ps := _players
	match _toy:
		"goal":
			if _frame == 30:
				lb.football.ball.pos = Vector3(-9.6, 0.4, MansionLobby.Football.GOAL_Z)
				lb.football.ball.vel = Vector3(-6.0, 0.0, 0.0)
		"bell":
			if _frame % 100 == 30:
				lb.bell.host_ring(1.0, Vector3.BACK)
		"photo":
			if _frame == 20:
				for i in mini(4, ps.size()):
					ps[i].place_at(Transform3D(Basis(), lb.photo.position + Vector3(-0.9 + 0.6 * i, 0.0, 1.4)))
			if _frame == 40:
				lb.photo.host_press()
		"seesaw":
			if _frame == 20 and ps.size() >= 2:
				ps[0].place_at(Transform3D(Basis(), lb.seesaw.position + Vector3(1.7, 1.0, 0.0)))
				ps[1].place_at(Transform3D(Basis(), lb.seesaw.position + Vector3(-1.6, 2.5, 0.0)))
		"trampoline":
			if _frame == 20 and ps.size() >= 1:
				ps[0].place_at(Transform3D(Basis(), lb.trampoline.position + Vector3(0.2, 2.0, 0.0)))
		"flare":
			if _frame % 90 == 30:
				lb.portal_preview.flare()
	# hold the staged blobs still
	if _toy in ["photo", "seesaw", "trampoline"]:
		for i in mini(4, ps.size()):
			(ps[i].get_component(&"controller") as ControllerComponent).scripted = true
			ps[i].intent.clear()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause"):
		get_tree().quit()
