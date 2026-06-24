@tool
extends EditorPlugin
## Editor plugin for the Codecks Bug & Feedback Reporter.
##
## On enable it:
##   * registers the project setting `codecks/report_token` (mirrors
##     UCodecksSettings::ReportToken),
##   * registers the project setting `codecks/hotkey_enabled` and an InputMap
##     action `codecks_open_report` (default F10) so QA/players can summon the
##     report form from anywhere in a running game without the dev wiring a
##     button,
##   * turns on Godot's built-in file logging so the diagnostics attachment can
##     actually include the engine log (it is OFF by default), and
##   * registers the runtime autoload singletons `Codecks` -> codecks.gd and
##     `CodecksOverlay` -> codecks_overlay.gd (the hotkey overlay).

const SETTING_NAME := "codecks/report_token"
const DEFAULT_TOKEN := "XXXXXXXXXXXXXXXXXXXX"
const AUTOLOAD_NAME := "Codecks"
const AUTOLOAD_PATH := "res://addons/codecks_bug_reporter/codecks.gd"

# Game-wide hotkey overlay: a second autoload that watches for an InputMap action
# and summons the existing report form over the current scene.
const OVERLAY_AUTOLOAD_NAME := "CodecksOverlay"
const OVERLAY_AUTOLOAD_PATH := "res://addons/codecks_bug_reporter/codecks_overlay.gd"

# Project setting that toggles the hotkey overlay. Default true => zero-plumbing
# open-from-anywhere once the plugin is enabled; a project that wants full control
# of its own input can switch it off (the overlay then consumes no input).
const SETTING_HOTKEY_ENABLED := "codecks/hotkey_enabled"
const DEFAULT_HOTKEY_ENABLED := true

# The InputMap action the overlay listens for, and its default key (F10). The
# binding lives in the InputMap so a project can rebind or clear it in Project
# Settings -> Input Map without touching the addon. Registered idempotently so we
# never clobber a binding the project has already customised.
const HOTKEY_ACTION := "codecks_open_report"
const DEFAULT_HOTKEY_KEY := KEY_F10

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

	# Register the hotkey-enabled project setting (default on). Only seed it when
	# unset so we never overwrite a project's deliberate choice.
	if not ProjectSettings.has_setting(SETTING_HOTKEY_ENABLED):
		ProjectSettings.set_setting(SETTING_HOTKEY_ENABLED, DEFAULT_HOTKEY_ENABLED)
	ProjectSettings.add_property_info({
		"name": SETTING_HOTKEY_ENABLED,
		"type": TYPE_BOOL,
		"hint": PROPERTY_HINT_NONE,
		"hint_string": "Let players summon the bug report form with the codecks_open_report hotkey (default F10) from anywhere in the running game.",
	})
	ProjectSettings.set_initial_value(SETTING_HOTKEY_ENABLED, DEFAULT_HOTKEY_ENABLED)

	# Register the InputMap action the overlay listens for, bound to F10 by default.
	# This must be PERSISTED into project.godot (under input/<action>), not just
	# added to the live InputMap, so the action still exists when the game RUNS
	# (the runtime InputMap is built from project.godot at startup, and an
	# editor-only InputMap.add_action would not survive into the running game).
	# Idempotent: only seed it when the project has no such input action yet, so a
	# project that has rebound (or deliberately cleared) it keeps its own binding.
	var input_setting := "input/" + HOTKEY_ACTION
	if not ProjectSettings.has_setting(input_setting):
		var ev := InputEventKey.new()
		ev.physical_keycode = DEFAULT_HOTKEY_KEY
		# The project.godot input map stores each action as { deadzone, events }.
		ProjectSettings.set_setting(input_setting, {
			"deadzone": 0.5,
			"events": [ev],
		})

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

	# Register the runtime API singleton and the hotkey overlay singleton.
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	add_autoload_singleton(OVERLAY_AUTOLOAD_NAME, OVERLAY_AUTOLOAD_PATH)


func _exit_tree() -> void:
	remove_autoload_singleton(OVERLAY_AUTOLOAD_NAME)
	remove_autoload_singleton(AUTOLOAD_NAME)

	# Remove the input action we registered, so disabling the plugin leaves no
	# orphan binding behind. Only the live InputMap entry is removed here; the
	# persisted project.godot input/<action> entry is left in place because a
	# project may have customised its binding, and remove_autoload_singleton +
	# ProjectSettings already persist on disable. Clearing the binding entirely on
	# every disable would also wipe a user's deliberate rebind.
	if InputMap.has_action(HOTKEY_ACTION):
		InputMap.erase_action(HOTKEY_ACTION)
