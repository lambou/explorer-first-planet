class_name Boot
extends Node
## The first scene: the main menu, then the loading screen while the game builds the world, then the game itself.
## The game (main.tscn) is a whole by itself; Boot only decides when it starts (`playing` is off until the ground around the explorer is built).
## Launched with options (the debugging aids of main.gd: --pos, --shot ...) it skips the menu and the loading screen and starts at once;
## `--menu` keeps them, and `--autoclick=SECONDS` presses Start after that long (to test the whole way in). `--savefile=NAME` uses another
## save file (tests never touch the player's), `--continue` loads the save without the menu.

const GAME := "res://src/main.tscn"
const MIN_LOADING := 0.8              # seconds the loading screen shows at least (it never just flashes)

var _menu: MainMenu
var _loading: LoadingScreen
var _game: Node
var _t := 0.0

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--savefile="):
			SaveGame.path = "user://" + a.substr(11)
	if args.has("--continue") and not SaveGame.exists():
		var worlds := SaveGame.list()                    # no --savefile: the most recently played world
		if not worlds.is_empty():
			SaveGame.select(worlds[0].id)
	if args.has("--continue") and SaveGame.exists():
		SaveGame.pending = SaveGame.read()
		WorldConfig.world_seed = SaveGame.pending.seed
		_start_game(false)
		return
	if not args.is_empty() and not args.has("--menu"):
		_start_game(false)
		return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_menu = MainMenu.new()
	add_child(_menu)
	_menu.start_requested.connect(_on_start)
	_menu.continue_requested.connect(_on_continue)
	for a in args:
		if a.begins_with("--autoclick="):
			get_tree().create_timer(float(a.substr(12))).timeout.connect(func() -> void: _menu._on_start() if _menu != null else null)

func _on_start(world_title: String, seed_text: String) -> void:
	SaveGame.create(world_title)                    # a new world gets its own slot; the others stay untouched
	SaveGame.pending = {}
	if seed_text.strip_edges() != "":
		WorldConfig.world_seed = WorldConfig.parse_seed(seed_text)           # a number or any text
	_begin()

func _on_continue(id: String) -> void:
	SaveGame.select(id)
	var data := SaveGame.read()
	if data.is_empty():
		return
	SaveGame.pending = data                         # the game applies it as it starts
	WorldConfig.world_seed = data.seed
	_begin()

func _begin() -> void:
	_menu.queue_free()
	_menu = null
	_loading = LoadingScreen.new()
	add_child(_loading)
	await get_tree().process_frame                  # let the loading screen be drawn before the world's setup keeps the thread busy
	await get_tree().process_frame
	_start_game(true)

func _start_game(with_loading: bool) -> void:
	_game = (load(GAME) as PackedScene).instantiate()
	_game.playing = not with_loading
	add_child(_game)

func _process(delta: float) -> void:
	if _game == null or _loading == null:
		return
	_t += delta
	_loading.set_progress(_game.loading_progress())
	if _t >= MIN_LOADING and _game.is_ready_to_play():
		_loading.set_progress(1.0)
		_game.begin_play()
		_loading.finish()
		_loading = null
