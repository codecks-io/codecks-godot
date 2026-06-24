extends Node
## Codecks Bug Reporter — game-wide hotkey overlay (autoload "CodecksOverlay").
##
## Lets QA/players summon the bug report form from ANYWHERE in a running game by
## pressing a configurable hotkey (default F10), so a project does not have to wire
## its own open-button. It reuses the SAME form scene the demo button uses
## (bug_report_form.tscn) — it never forks a second form.
##
## How it works:
##   * The editor plugin registers an InputMap action ("codecks_open_report",
##     bound to F10 by default) and the project settings that control it.
##   * This autoload watches for that action and, on press, instantiates the
##     existing form scene and adds it as its own child. The form is a
##     CanvasLayer, so it floats above the current scene regardless of where this
##     autoload sits in the tree.
##   * The form hides itself on close/submit (see bug_report_form.gd); the next
##     hotkey press re-shows the same instance. No double-open.
##
## Opt-in / non-destructive:
##   * If the dev disables the hotkey (codecks/hotkey_enabled = false), this
##     autoload consumes no input and registers no action handling, so it can
##     never collide with the game's own input.
##   * It coexists with a hand-wired open button (e.g. the demo's): each path owns
##     its own form instance and the overlay only ever shows the one it created.

## Project setting that toggles the hotkey overlay on/off. Default true so the
## feature is zero-plumbing once the plugin is enabled, but a project that wants
## full control over its own input can switch it off.
const SETTING_HOTKEY_ENABLED := "codecks/hotkey_enabled"

## The InputMap action the editor plugin registers and this autoload listens for.
## Kept as a plain string so this script never has to know the bound key — the
## binding lives in the InputMap (editable in Project Settings -> Input Map), and
## a project can rebind or clear it there without touching the addon.
const HOTKEY_ACTION := "codecks_open_report"

## The form scene reused verbatim — the same one main.gd (the demo button) opens.
const BUG_REPORT_FORM := preload("res://addons/codecks_bug_reporter/bug_report_form.tscn")

## The single form instance this overlay owns. Lazily created on first summon and
## reused afterwards (the form hides rather than frees itself), so repeated
## hotkey presses never stack overlays.
var _form: CanvasLayer = null

## Resolved once in _ready from the project setting. When false, _input does no
## work at all, guaranteeing the overlay never touches the game's input.
var _hotkey_enabled: bool = true


func _ready() -> void:
	_hotkey_enabled = bool(ProjectSettings.get_setting(SETTING_HOTKEY_ENABLED, true))
	# Only listen for input when the hotkey is enabled. Disabling it makes this
	# autoload inert so it can never consume or shadow the game's own input.
	set_process_input(_hotkey_enabled)


func _input(event: InputEvent) -> void:
	# Guard against the action not existing (e.g. a project that cleared it from
	# the InputMap): is_action_pressed on an unknown action would push an error.
	if not InputMap.has_action(HOTKEY_ACTION):
		return
	if event.is_action_pressed(HOTKEY_ACTION):
		_toggle_form()
		# Consume the event so the bound key does not also reach the game while we
		# open the reporter. Only happens on the dedicated hotkey, never otherwise.
		get_viewport().set_input_as_handled()


## Summons the report form: shows it if hidden, hides it if already on screen.
## Reuses the single owned instance, creating it the first time only.
func _toggle_form() -> void:
	if _form != null and is_instance_valid(_form):
		# Toggle: a second press while the form is open closes it again.
		_form.visible = not _form.visible
		return
	_form = BUG_REPORT_FORM.instantiate()
	add_child(_form)
