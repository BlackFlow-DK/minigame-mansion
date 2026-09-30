extends SceneTree
## Headless test runner, driven by tools/godot-test.ps1:
##   godot --headless --fixed-fps 60 --path game --script res://tests/run_tests.gd -- [--filter=text]
## Runs every `test_*` method of every res://tests/test_*.gd (a GameTest), one fresh instance
## per test. Prints one line per test and a summary. Exit 0 when all pass, 1 otherwise
## (also when nothing ran, a file fails to compile, or a test times out).
## This file is the main loop: it and every script it references statically are compiled
## before autoloads exist, so it only reaches tests dynamically (no GameTest/Stage/... names).

const TEST_DIR := "res://tests"
const TEST_TIMEOUT_MS := 60000
## Hard stop if the runner itself dies mid-run (a runtime error aborts _run and quit never comes).
const STALL_MS := TEST_TIMEOUT_MS + 10000


## Counts engine/script errors (not warnings) so a test that errors fails.
class ErrorLog extends Logger:
	var _mutex := Mutex.new()
	var _errors: Array[String] = []

	func _log_error(_function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		var text := rationale if rationale != "" else code
		for bt in script_backtraces:
			if bt.get_frame_count() > 0:
				file = bt.get_frame_file(0)
				line = bt.get_frame_line(0)
				break
		_mutex.lock()
		_errors.append("error: %s (%s:%d)" % [text, file.get_file(), line])
		_mutex.unlock()

	func take() -> Array[String]:
		_mutex.lock()
		var out := _errors.duplicate()
		_errors.clear()
		_mutex.unlock()
		return out


var _log := ErrorLog.new()
var _heartbeat_ms: int = 0
var _finished: bool = false


func _initialize() -> void:
	OS.add_logger(_log)
	_heartbeat_ms = Time.get_ticks_msec()
	_run()


func _process(_delta: float) -> bool:
	if not _finished and Time.get_ticks_msec() - _heartbeat_ms > STALL_MS:
		printerr("tests: runner stalled (aborted by a script error?), giving up")
		OS.remove_logger(_log)
		_finished = true
		quit(1)
	return false


func _run() -> void:
	var filter := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--filter="):
			filter = arg.trim_prefix("--filter=")
	await process_frame  # autoloads are ready
	var passed := 0
	var failed := 0
	var files: Array[String] = []
	for f in DirAccess.get_files_at(TEST_DIR):
		if f.begins_with("test_") and f.get_extension() == "gd":
			files.append(TEST_DIR.path_join(f))
	files.sort()
	for path in files:
		var file := path.get_file()
		var script := load(path) as GDScript
		if script == null or not script.can_instantiate():
			print("FAIL %s: does not compile" % file)
			failed += 1
			continue
		for method in _test_methods(script):
			var id := "%s::%s" % [file.get_basename(), method]
			if filter != "" and not id.containsn(filter):
				continue
			_heartbeat_ms = Time.get_ticks_msec()
			_log.take()
			var t := script.new() as Node
			if t == null or not t.has_method(&"run_test"):
				print("FAIL %s: script does not extend GameTest" % file)
				failed += 1
				if t:
					t.free()
				break
			t.name = "Test"
			root.add_child(t)
			var start := Time.get_ticks_msec()
			t.call(&"run_test", method)
			while not t.get(&"done") and Time.get_ticks_msec() - start < TEST_TIMEOUT_MS:
				await process_frame
			var problems: Array[String] = []
			problems.append_array(t.get(&"failures"))
			if not t.get(&"done"):
				problems.append("timed out after %d ms" % TEST_TIMEOUT_MS)
			root.remove_child(t)
			t.queue_free()
			await process_frame
			problems.append_array(_log.take())
			var ms := Time.get_ticks_msec() - start
			if problems.is_empty():
				passed += 1
				print("PASS %s (%d ms)" % [id, ms])
			else:
				failed += 1
				print("FAIL %s: %s" % [id, " | ".join(problems)])
	print("tests: %d passed, %d failed" % [passed, failed])
	if passed + failed == 0:
		print("tests: nothing ran%s" % ("" if filter == "" else " (filter '%s')" % filter))
		failed = 1
	OS.remove_logger(_log)
	_finished = true
	quit(1 if failed > 0 else 0)


## `test_*` methods in declaration order, without duplicates.
func _test_methods(script: GDScript) -> Array[StringName]:
	var out: Array[StringName] = []
	for m in script.get_script_method_list():
		var n := StringName(m["name"])
		if String(n).begins_with("test_") and not out.has(n):
			out.append(n)
	return out
