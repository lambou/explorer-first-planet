class_name Autosave
extends Node
## Saves the game by itself, so nothing done in the world is lost: shortly after anything happens (`request()`: a dig, a harvest, a craft, a
## planted torch ...), every INTERVAL seconds whatever happens (his position, the burning torch), when the window loses focus, and
## when the game is closed. The snapshot is made on the main thread (cheap: the big terrain edits are copied only when they changed), the
## writing to disk happens on a worker thread so the game never stutters. At close the save is written at once and waited for.

const INTERVAL := 30.0
const DEBOUNCE := 1.5                 # after an action, the save follows this soon (several actions in a row make one save)

var enabled := false                  # off for the loading screen and for the debugging runs (they must not touch the player's save)
var capture: Callable                 # returns the data to save (see WorldSnapshot.capture)
var _since := 0.0                     # time since the last save
var _pending := false                 # something happened since the last save
var _timer := 0.0                     # time left before the pending save is made
var _task := -1                       # the worker task writing the last save

func request() -> void:
	if not _pending:
		_pending = true
		_timer = DEBOUNCE

func _process(delta: float) -> void:
	if not enabled:
		return
	_since += delta
	if _pending:
		_timer -= delta
	if (_pending and _timer <= 0.0) or _since >= INTERVAL:
		_save_async()

func _save_async() -> void:
	if _task >= 0 and not WorkerThreadPool.is_task_completed(_task):
		_pending = true
		_timer = 1.0                                      # the last save is still being written: try again soon
		return
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	var data: Dictionary = capture.call()
	_task = WorkerThreadPool.add_task(SaveGame.write.bind(data), false, "autosave")
	_since = 0.0
	_pending = false

## Write the save now and wait for it (closing the game).
func save_now() -> void:
	if not enabled:
		return
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	SaveGame.write(capture.call())
	_since = 0.0
	_pending = false
