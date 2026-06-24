extends CanvasLayer
## In-game bug/feedback report form.
##
## A CanvasLayer + Control overlay that collects a description, severity,
## optional email and an optional context bundle (a screenshot plus a
## logs/system-info diagnostics file, gated by a single opt-in checkbox), then
## submits via the Codecks autoload. No native dialogs are used.

@onready var _description: TextEdit = %DescriptionEdit
@onready var _severity: OptionButton = %SeverityOption
@onready var _email: LineEdit = %EmailEdit
@onready var _attach_context: CheckBox = %AttachContextCheck
@onready var _submit_button: Button = %SubmitButton
@onready var _cancel_button: Button = %CancelButton
@onready var _status_label: Label = %StatusLabel
@onready var _powered_by: TextureRect = %PoweredBy

# Codecks marketing site opened when the "Powered by Codecks" footer is clicked.
const _CODECKS_URL := "https://codecks.io"

# Maps the OptionButton item index to the severity string create_report expects.
const _SEVERITY_BY_INDEX := ["", "low", "high", "critical"]

# Report status strings emitted by the Codecks autoload (mirror codecks.gd's
# STATUS_* constants). Kept as plain literals here so this script never has to
# reference the global "Codecks" identifier at parse time — that autoload only
# exists once the plugin is enabled, and referencing it directly makes the
# script fail to parse on a fresh project before the user can enable it.
const _STATUS_SUCCESS := "Success"
const _STATUS_PARTIALLY := "Partially"

# Whether the captured screenshot should include this form's UI.
@export var screenshot_includes_ui: bool = false

# How long the "Report sent. Thank you!" confirmation stays visible before the
# form auto-closes on a successful send. Only the success path auto-closes; a
# failure keeps the form open so the specific error stays on screen.
const _SUCCESS_CLOSE_DELAY := 1.4

# Generation counter for the pending auto-close. Each scheduled close captures
# the value at the time it was queued; closing the form manually (Cancel) bumps
# this so the in-flight timer sees a mismatch and aborts instead of re-hiding /
# re-resetting an already-closed (or freshly reopened) form.
var _close_generation: int = 0

# The Codecks autoload node, resolved at runtime via the scene tree (never via
# the global identifier — see the note on the status constants above). Null when
# the plugin is not enabled.
var _codecks: Node = null

# The specific failure reason from the last report_error signal, kept so the
# generic "created(Fail)" handler doesn't overwrite it on screen. Empty = none.
var _last_error: String = ""


func _ready() -> void:
	# Populate the severity dropdown.
	_severity.clear()
	_severity.add_item("None")
	_severity.add_item("Low")
	_severity.add_item("High")
	_severity.add_item("Critical")
	# Default to Low: a reported bug is at minimum Low, so reports never land
	# severity-less/untriaged. The reporter can still pick None/High/Critical.
	_severity.select(1)

	_submit_button.pressed.connect(_on_submit_pressed)
	_cancel_button.pressed.connect(_on_cancel_pressed)
	# The "Powered by Codecks" attribution footer opens codecks.io on click.
	_powered_by.gui_input.connect(_on_powered_by_gui_input)

	# Wire the Codecks autoload signals. The plugin registers it as "/root/Codecks".
	_codecks = get_node_or_null("/root/Codecks")
	if _codecks != null:
		_codecks.report_created.connect(_on_report_created)
		_codecks.report_error.connect(_on_report_error)
		_status_label.text = ""
	else:
		_status_label.text = "Codecks autoload not found. Enable the plugin in Project Settings."


func _on_submit_pressed() -> void:
	if _codecks == null:
		_status_label.text = "Codecks autoload not found. Enable the plugin in Project Settings."
		return

	var content := _description.text.strip_edges()
	if content.is_empty():
		_status_label.text = "Please enter a description before submitting."
		return

	var sev_index: int = _severity.selected
	if sev_index < 0 or sev_index >= _SEVERITY_BY_INDEX.size():
		sev_index = 0
	var severity: String = _SEVERITY_BY_INDEX[sev_index]
	var email := _email.text.strip_edges()

	# Single opt-in toggle (default ON). When ticked, attach BOTH a screenshot and
	# a logs/system-info diagnostics file to help fix the issue; when unticked,
	# send a text-only report with no attachments. build_diagnostics never crashes
	# and degrades gracefully when no log file is available.
	var files: Array = []
	if _attach_context.button_pressed:
		# Hide the form so the screenshot does not contain our own UI (unless asked).
		if not screenshot_includes_ui:
			visible = false
			# Wait until the frame with the form hidden has actually been drawn
			# before reading back the viewport texture.
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
		var shot: Dictionary = _codecks.take_screenshot(screenshot_includes_ui)
		if not screenshot_includes_ui:
			visible = true
		files.append(shot)

		var diag: Dictionary = _codecks.build_diagnostics()
		files.append(diag)

	# Clear any error from a previous attempt so a fresh failure isn't masked by
	# (or confused with) the last one.
	_last_error = ""
	_status_label.text = "Submitting report..."
	_submit_button.disabled = true
	_codecks.create_report(content, severity, email, files)


func _on_cancel_pressed() -> void:
	# Manual close: invalidate any pending success auto-close, reset, then hide.
	_close()


# Opens the Codecks marketing site when the attribution footer is left-clicked.
# Uses gui_input (not pressed) because TextureRect has no built-in button signal.
func _on_powered_by_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			OS.shell_open(_CODECKS_URL)


# Cancels any in-flight auto-close, restores the fields to their defaults and
# hides the form. Used by both the Cancel button and the success auto-close so a
# reopened form always starts clean.
func _close() -> void:
	_close_generation += 1
	_reset_fields()
	hide()


# Restores every input to the state a freshly opened form has, matching the
# scene defaults (empty description/email, no severity, context attachment on)
# and clears any status/error text.
func _reset_fields() -> void:
	_description.text = ""
	_severity.select(0)
	_email.text = ""
	_attach_context.button_pressed = true
	_status_label.text = ""
	_last_error = ""
	_submit_button.disabled = false


# Shows the success confirmation, then auto-closes the form after a brief delay.
# The delay is guarded by _close_generation so a manual Cancel (or a reopen)
# during the wait cancels this close cleanly instead of hiding/resetting a form
# the user is already using again.
func _auto_close_after_success() -> void:
	var generation := _close_generation
	await get_tree().create_timer(_SUCCESS_CLOSE_DELAY).timeout
	# Bail if the form was closed (or reopened) manually while we were waiting,
	# or if the node is on its way out.
	if not is_inside_tree() or not visible:
		return
	if generation != _close_generation:
		return
	_close()


func _on_report_created(status: String) -> void:
	_submit_button.disabled = false
	if status == _STATUS_SUCCESS:
		_status_label.text = "Report sent. Thank you!"
		_auto_close_after_success()
	elif status == _STATUS_PARTIALLY:
		_status_label.text = "Report sent, but an attachment failed to upload."
		_auto_close_after_success()
	else:
		# Failure. report_error fired first (synchronously) with the specific
		# reason — keep it on screen instead of clobbering it with a generic
		# line. Only fall back to the generic message if, somehow, no specific
		# error was captured.
		if not _last_error.is_empty():
			_status_label.text = _last_error
		else:
			_status_label.text = "Report could not be sent."


func _on_report_error(message: String) -> void:
	_submit_button.disabled = false
	_last_error = message
	# Also print to the Output panel so the reason is visible even if a later
	# signal updates the on-screen label.
	printerr("[Codecks] ", message)
	_status_label.text = message
