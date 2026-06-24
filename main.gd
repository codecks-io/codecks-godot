extends Control
## Demo scene: a single button that opens the Codecks bug report form,
## mirroring the example level shipped with the Unreal plugin.

const BUG_REPORT_FORM := preload("res://addons/codecks_bug_reporter/bug_report_form.tscn")

@onready var _open_button: Button = %OpenReportButton

var _form: CanvasLayer = null


func _ready() -> void:
	_open_button.pressed.connect(_on_open_pressed)


func _on_open_pressed() -> void:
	if _form != null and is_instance_valid(_form):
		_form.show()
		return
	_form = BUG_REPORT_FORM.instantiate()
	add_child(_form)
