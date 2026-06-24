@tool
extends EditorPlugin
## Editor plugin for the Codecks Bug & Feedback Reporter.
##
## On enable it:
##   * registers the project setting `codecks/report_token` (mirrors
##     UCodecksSettings::ReportToken),
##   * turns on Godot's built-in file logging so the diagnostics attachment can
##     actually include the engine log (it is OFF by default), and
##   * registers the runtime autoload singleton `Codecks` ->
##     res://addons/codecks_bug_reporter/codecks.gd.

const SETTING_NAME := "codecks/report_token"
const DEFAULT_TOKEN := "XXXXXXXXXXXXXXXXXXXX"
const AUTOLOAD_NAME := "Codecks"
const AUTOLOAD_PATH := "res://addons/codecks_bug_reporter/codecks.gd"

# Godot's built-in engine-log-to-file setting. Off by default, which is why the
# diagnostics attachment usually finds no log. Enabling it here (editor-only,
# idempotent) means subsequent runs write user://logs/godot.log for us to tail.
const FILE_LOGGING_SETTING := "debug/file_logging/enable_file_logging"


func _enter_tree() -> void:
	# Register the report-token project setting.
	if not ProjectSettings.has_setting(SETTING_NAME):
		ProjectSettings.set_setting(SETTING_NAME, DEFAULT_TOKEN)
	ProjectSettings.add_property_info({
		"name": SETTING_NAME,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "Codecks report token for your Parent Card.",
	})
	ProjectSettings.set_initial_value(SETTING_NAME, DEFAULT_TOKEN)

	# Enable engine file logging so the diagnostics attachment can tail the log.
	# Idempotent: only write (and only persist) when it is not already on, so we
	# never clobber a project that has deliberately configured logging. This runs
	# in the editor only (EditorPlugin), never at game runtime, and the change is
	# read at the next startup, so the first log appears on the next run.
	var logging_changed := false
	if not bool(ProjectSettings.get_setting(FILE_LOGGING_SETTING, false)):
		ProjectSettings.set_setting(FILE_LOGGING_SETTING, true)
		logging_changed = true

	ProjectSettings.save()

	if logging_changed:
		print("[Codecks] Enabled engine file logging (%s). Restart the project once so user://logs/godot.log is written; until then the diagnostics attachment notes the log is not captured yet." % FILE_LOGGING_SETTING)

	# Register the runtime API singleton.
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
