extends Node
## Codecks Bug & Feedback Reporter — runtime API singleton (autoload "Codecks").
##
## Faithful Godot 4.x port of the Codecks Unreal plugin's CodecksCardCreator.
## Talks to the SAME backend contract:
##   1. POST JSON to https://api.codecks.io/user-report/v1/create-report?token=<reportToken>
##   2. For every returned uploadUrls entry, POST a multipart/form-data body to the
##      presigned S3 url (AWS POST-policy fields first, file part last).
##
## Auth is ONLY the report token in the query string.
##
## Usage:
##   Codecks.report_created.connect(func(status): print(status))
##   Codecks.report_error.connect(func(msg): printerr(msg))
##   var shot := Codecks.take_screenshot(true)
##   Codecks.create_report("It crashed!", "high", "p@example.com", [shot])

## Emitted once the whole flow finishes. status is "Success", "Partially" or "Fail".
signal report_created(status: String)
## Emitted with a specific human-readable message on any failure mode.
signal report_error(message: String)

const CREATE_REPORT_URL := "https://api.codecks.io/user-report/v1/create-report?token="

## File-type identifiers (mirror the Unreal CodecksFileType enum).
const FILE_TYPE_BINARY := "binary"
const FILE_TYPE_PLAIN_TEXT := "plain_text"
const FILE_TYPE_JSON := "json"
const FILE_TYPE_PNG := "png"
const FILE_TYPE_JPG := "jpg"

## Card creation status strings (mirror CodecksCardCreationStatus).
const STATUS_SUCCESS := "Success"
const STATUS_PARTIALLY := "Partially"
const STATUS_FAIL := "Fail"

## Allowed severity values accepted by the backend. Empty string => omitted.
const _VALID_SEVERITIES := ["low", "high", "critical"]

## The fixed ordered list of AWS POST-policy field names the original plugin emits.
## Order is preserved exactly so the signed S3 policy validates.
const _AWS_FIELD_NAMES := [
	"key",
	"Cache-Control",
	"acl",
	"bucket",
	"X-Amz-Algorithm",
	"X-Amz-Credential",
	"X-Amz-Date",
	"Policy",
	"X-Amz-Signature",
]

## Maps a CodecksFileType to its MIME Content-Type (mirror of the Unreal switch).
func _mime_for_type(type: String) -> String:
	match type:
		FILE_TYPE_PLAIN_TEXT:
			return "text/plain"
		FILE_TYPE_JSON:
			return "application/json"
		FILE_TYPE_PNG:
			return "image/png"
		FILE_TYPE_JPG:
			return "image/jpeg"
		_:
			return "application/octet-stream"


## Public entry point. Mirrors UCodecksCardCreator::CreateNewCodecksCard.
##
## content    — the card text (required).
## severity   — "", "low", "high" or "critical". Anything else is treated as "".
## user_email — optional; trimmed; omitted from the payload when empty.
## files      — Array of Dictionaries shaped like take_screenshot's return:
##              { filename: String, type: String, data: PackedByteArray }.
func create_report(content: String, severity: String = "", user_email: String = "", files: Array = []) -> void:
	# Trim the token: a stray space or newline pasted along with it makes the
	# backend reject the request with HTTP 401.
	var report_token := str(ProjectSettings.get_setting("codecks/report_token", "")).strip_edges()
	if report_token.is_empty():
		report_error.emit("No Codecks report token configured (Project Settings -> codecks/report_token).")
		report_created.emit(STATUS_FAIL)
		return
	if report_token == "XXXXXXXXXXXXXXXXXXXX":
		report_error.emit("The Codecks report token is still the placeholder. Paste your real Report Token in Project Settings -> codecks/report_token (Codecks: Organization Settings -> User Reports).")
		report_created.emit(STATUS_FAIL)
		return

	var body := {
		"content": content,
	}

	var sev := severity.strip_edges().to_lower()
	if sev in _VALID_SEVERITIES:
		body["severity"] = sev

	var clean_mail := user_email.strip_edges()
	if not clean_mail.is_empty():
		body["userEmail"] = clean_mail

	var file_names: Array = []
	for file in files:
		file_names.append(file.get("filename", ""))
	body["fileNames"] = file_names

	var url := CREATE_REPORT_URL + report_token

	var http := HTTPRequest.new()
	add_child(http)

	var headers := PackedStringArray(["Content-Type: application/json"])
	var err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		http.queue_free()
		report_error.emit("Could not start the create-report request locally (HTTPRequest error code %d). The request was not sent." % err)
		report_created.emit(STATUS_FAIL)
		return

	# request_completed(result, response_code, headers, body)
	var response: Array = await http.request_completed
	http.queue_free()

	var result: int = response[0]
	var response_code: int = response[1]
	var response_body: PackedByteArray = response[3]

	# Network/transport layer failure: the request never got an answer (DNS,
	# connect, TLS, timeout). These are the retryable class.
	if result != HTTPRequest.RESULT_SUCCESS:
		report_error.emit("Could not reach Codecks (network): %s. Check your internet connection." % _describe_request_result(result))
		report_created.emit(STATUS_FAIL)
		return

	var text := response_body.get_string_from_utf8()

	# The server answered with a non-2xx status. Distinguish the causes so a dev
	# wiring up the addon can tell at a glance which leg broke. These are the
	# permanent class: never retry blindly.
	if response_code < 200 or response_code >= 300:
		report_error.emit(_describe_create_http_error(response_code, text))
		report_created.emit(STATUS_FAIL)
		return

	if text.is_empty():
		report_error.emit("Codecks returned an empty response when creating the card (unexpected). The card may not have been created.")
		report_created.emit(STATUS_FAIL)
		return

	var json := JSON.new()
	var parse_err := json.parse(text)
	if parse_err != OK:
		report_error.emit("Codecks returned an unexpected (non-JSON) response when creating the card: %s (line %d)." % [json.get_error_message(), json.get_error_line()])
		report_created.emit(STATUS_FAIL)
		return

	var data = json.data
	if typeof(data) != TYPE_DICTIONARY:
		report_error.emit("Codecks returned an unexpected response shape when creating the card (expected a JSON object).")
		report_created.emit(STATUS_FAIL)
		return

	var ok := bool(data.get("ok", false))
	if not ok:
		# HTTP was 2xx but the body says the request was rejected (e.g. validation).
		var message := str(data.get("message", "Unknown Error"))
		report_error.emit("Codecks rejected the report: %s." % message)
		report_created.emit(STATUS_FAIL)
		return

	# Card created. If there were no files, we're done.
	if files.is_empty():
		report_created.emit(STATUS_SUCCESS)
		return

	var upload_urls = data.get("uploadUrls", [])
	if typeof(upload_urls) != TYPE_ARRAY or upload_urls.is_empty():
		# Card was created but the backend returned no upload targets for our files.
		report_error.emit("Card created, but the server returned no upload URLs for the attachments.")
		report_created.emit(STATUS_PARTIALLY)
		return

	await _upload_attachments(upload_urls, files)


## Phase 2: upload each attachment to its presigned S3 url.
func _upload_attachments(upload_urls: Array, files: Array) -> void:
	var any_failed := false

	for entry in upload_urls:
		if typeof(entry) != TYPE_DICTIONARY:
			continue

		var file_name := str(entry.get("fileName", ""))
		if file_name.is_empty():
			continue

		# Find the matching local file by name.
		var file: Dictionary = {}
		for candidate in files:
			if str(candidate.get("filename", "")) == file_name:
				file = candidate
				break
		if file.is_empty():
			# No matching attachment for this upload URL; skip (matches Unreal "continue").
			continue

		var upload_url := str(entry.get("url", ""))
		if upload_url.is_empty():
			continue

		var fields = entry.get("fields", {})
		if typeof(fields) != TYPE_DICTIONARY:
			continue

		var boundary := _make_boundary()
		var payload := _build_multipart(fields, file, boundary)

		var http := HTTPRequest.new()
		add_child(http)

		var headers := PackedStringArray(["Content-Type: multipart/form-data; boundary=\"%s\"" % boundary])
		var err := http.request_raw(upload_url, headers, HTTPClient.METHOD_POST, payload)
		if err != OK:
			http.queue_free()
			any_failed = true
			report_error.emit("Could not start the attachment upload for '%s' locally (HTTPRequest error code %d). The card was created; only the attachment did not land." % [file_name, err])
			continue

		var response: Array = await http.request_completed
		http.queue_free()

		var result: int = response[0]
		var response_code: int = response[1]
		var response_body: PackedByteArray = response[3]

		if result != HTTPRequest.RESULT_SUCCESS:
			any_failed = true
			report_error.emit("Could not reach the attachment upload server (network): %s, while uploading '%s'. Check your internet connection." % [_describe_request_result(result), file_name])
			continue

		var response_text := response_body.get_string_from_utf8()
		# S3 returns 204 No Content on success. Treat non-2xx, or a body containing
		# "Error" (matches the Unreal check), as a failed upload. The S3 error body
		# is XML, so surface only the parsed <Code>/<Message>, never the raw body.
		if response_code < 200 or response_code >= 300:
			any_failed = true
			report_error.emit("Attachment upload failed for '%s' (HTTP %d)%s. The card was created; only the attachment did not land." % [file_name, response_code, _describe_s3_error(response_text)])
			continue
		if response_text.find("Error") != -1:
			any_failed = true
			report_error.emit("Attachment upload rejected for '%s'%s. The card was created; only the attachment did not land." % [file_name, _describe_s3_error(response_text)])
			continue

	report_created.emit(STATUS_PARTIALLY if any_failed else STATUS_SUCCESS)


## Turns an HTTPRequest.Result code into a short human cause, so a network
## failure says "host could not be resolved" rather than a bare number. The
## numeric code is kept in parentheses for bug reports.
func _describe_request_result(result: int) -> String:
	var cause := ""
	match result:
		HTTPRequest.RESULT_CANT_CONNECT:
			cause = "could not connect to the server"
		HTTPRequest.RESULT_CANT_RESOLVE:
			cause = "host could not be resolved (DNS)"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			cause = "the connection dropped"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			cause = "TLS/SSL handshake failed"
		HTTPRequest.RESULT_TIMEOUT:
			cause = "the request timed out"
		HTTPRequest.RESULT_NO_RESPONSE:
			cause = "no response from the server"
		HTTPRequest.RESULT_REQUEST_FAILED:
			cause = "the request failed"
		_:
			cause = "transport error"
	return "%s (HTTPRequest result %d)" % [cause, result]


## Builds a specific message for a non-2xx response from the create-report call.
## 401/403 is almost always a bad token (Report Token vs Access Key); other 4xx
## is a rejected request whose reason we pull from the JSON "message"/"error"
## field; 5xx is a server-side error worth retrying. The raw body is never dumped
## (it may be HTML); only the parsed reason is shown.
func _describe_create_http_error(response_code: int, text: String) -> String:
	if response_code == 401 or response_code == 403:
		return "Report token rejected (HTTP %d). Check your Report Token in Project Settings -> codecks/report_token. Use the Report Token from Codecks (Organization Settings -> User Reports), not an Access Key." % response_code
	if response_code >= 500:
		return "Codecks server error (HTTP %d). This is on the server side; try again in a moment." % response_code
	if response_code >= 400:
		var reason := _parse_json_error_message(text)
		if reason.is_empty():
			return "Codecks rejected the request (HTTP %d)." % response_code
		return "Codecks rejected the request (HTTP %d): %s." % [response_code, reason]
	# Any other non-2xx (e.g. an unexpected 3xx).
	return "Unexpected HTTP status %d from Codecks while creating the card." % response_code


## Extracts a human-readable error reason from a JSON error body, trying the
## common field names. Returns "" when the body is not JSON or carries no usable
## message, so callers can fall back without ever surfacing a raw HTML/body dump.
func _parse_json_error_message(text: String) -> String:
	if text.strip_edges().is_empty():
		return ""
	var json := JSON.new()
	if json.parse(text) != OK:
		return ""
	var data = json.data
	if typeof(data) != TYPE_DICTIONARY:
		return ""
	for key in ["message", "error", "msg", "detail"]:
		if data.has(key):
			var value := str(data[key]).strip_edges()
			if not value.is_empty():
				return value
	return ""


## Extracts the S3 error code/message from an S3 XML error body, formatted as a
## leading ": <text>" suffix (empty when nothing usable is found). S3 replies
## with XML like <Error><Code>...</Code><Message>...</Message></Error>; we never
## dump the raw XML, only the parsed Code/Message.
func _describe_s3_error(text: String) -> String:
	var code := _extract_xml_tag(text, "Code")
	var message := _extract_xml_tag(text, "Message")
	if not code.is_empty() and not message.is_empty():
		return ": %s - %s" % [code, message]
	if not code.is_empty():
		return ": %s" % code
	if not message.is_empty():
		return ": %s" % message
	return ""


## Returns the text content of the first <tag>...</tag> in an XML string, or "".
## A tiny purpose-built reader: S3 error bodies are flat, so a full XML parser is
## unnecessary and avoids surfacing the raw body.
func _extract_xml_tag(text: String, tag: String) -> String:
	var open_tag := "<%s>" % tag
	var close_tag := "</%s>" % tag
	var start := text.find(open_tag)
	if start == -1:
		return ""
	start += open_tag.length()
	var end := text.find(close_tag, start)
	if end == -1:
		return ""
	return text.substr(start, end - start).strip_edges()


## Generates a "TERMINATOR" + 32 random digits boundary, mirroring the Unreal plugin.
func _make_boundary() -> String:
	var s := "TERMINATOR"
	for i in 32:
		s += str(randi() % 10)
	return s


## Builds the raw multipart/form-data body for an S3 presigned POST.
##
## Order (must match the Unreal plugin so the signed policy validates):
##   1. Every known AWS POST-policy field present in `fields`, in _AWS_FIELD_NAMES order.
##   2. A "Content-Type" form field carrying the file's MIME type.
##   3. The file part: a `Content-Type:` header, then
##      `Content-Disposition: form-data; name="file"; filename="<name>"`, then raw bytes.
##   4. Closing `--<boundary>--`.
func _build_multipart(fields: Dictionary, file: Dictionary, boundary: String) -> PackedByteArray:
	var crlf := "\r\n"
	var content_type := _mime_for_type(str(file.get("type", FILE_TYPE_BINARY)))
	var file_name := str(file.get("filename", ""))

	# Everything up to (but not including) the raw file bytes is plain ASCII text,
	# so we assemble it as a String and encode once.
	var head := ""

	# 1. AWS POST-policy fields, in the fixed order, only if present.
	for field_name in _AWS_FIELD_NAMES:
		if not fields.has(field_name):
			continue
		var value := str(fields[field_name])
		head += "--" + boundary + crlf
		head += "Content-Disposition: form-data; name=\"" + field_name + "\"" + crlf
		head += crlf
		head += value + crlf

	# 2. Content-Type form field.
	head += "--" + boundary + crlf
	head += "Content-Disposition: form-data; name=\"Content-Type\"" + crlf + crlf
	head += content_type + crlf

	# 3. File part header.
	head += "--" + boundary + crlf
	head += "Content-Type: " + content_type + crlf
	head += "Content-Disposition: form-data; name=\"file\"; filename=\"" + file_name + "\"" + crlf
	head += crlf

	# 4. Closing boundary (comes after the raw file bytes).
	var tail := crlf + "--" + boundary + "--"

	var payload := PackedByteArray()
	payload.append_array(head.to_utf8_buffer())

	var file_data = file.get("data", PackedByteArray())
	if file_data is PackedByteArray:
		payload.append_array(file_data)

	payload.append_array(tail.to_utf8_buffer())

	return payload


## How many bytes from the END of the log file to include in a diagnostics
## attachment. Keeps the upload small while still covering the most recent
## frames before a crash. 64 KiB comfortably holds thousands of log lines.
const _LOG_TAIL_BYTES := 65536


## Builds a plain-text diagnostics attachment containing basic system info and,
## when available, the tail of the engine log file. Returned shaped for
## create_report's `files`:
##   { filename = "codecksDiagnostics.txt", type = "plain_text", data = PackedByteArray }
##
## This never throws and never blocks on a missing log: if file logging is off
## or the log cannot be read, the system-info section is still produced and a
## short note explains that no log file was found.
func build_diagnostics() -> Dictionary:
	var lines: Array = []

	lines.append("=== Codecks Bug Reporter diagnostics ===")
	lines.append("Generated: %s (local)" % Time.get_datetime_string_from_system(false, true))
	lines.append("")
	lines.append("--- System info ---")

	# Engine version, e.g. "4.2.2.stable.official".
	var version_info: Dictionary = Engine.get_version_info()
	lines.append("Godot version: %s" % str(version_info.get("string", "unknown")))

	# The game's own version string from Project Settings -> Application -> Config
	# -> Version. Omitted when unset so we never report a fabricated version.
	var project_version := str(ProjectSettings.get_setting("application/config/version", ""))
	if not project_version.is_empty():
		lines.append("Project version: %s" % project_version)

	# OS name plus, where the API exposes them, the distribution and version.
	lines.append("OS: %s" % OS.get_name())
	var distro := ""
	if OS.has_method("get_distribution_name"):
		distro = str(OS.get_distribution_name())
	if not distro.is_empty():
		lines.append("OS distribution: %s" % distro)
	var os_version := str(OS.get_version())
	if not os_version.is_empty():
		lines.append("OS version: %s" % os_version)

	lines.append("Processor: %s (%d threads)" % [OS.get_processor_name(), OS.get_processor_count()])

	# GPU. get_video_adapter_name is the renderer-agnostic device string.
	var gpu := "unknown"
	if RenderingServer.has_method("get_video_adapter_name"):
		gpu = str(RenderingServer.get_video_adapter_name())
	lines.append("GPU: %s" % gpu)

	# Resolution: the game window size plus the size of the screen it sits on.
	var win_size: Vector2i = DisplayServer.window_get_size()
	lines.append("Window size: %d x %d" % [win_size.x, win_size.y])
	var screen := DisplayServer.window_get_current_screen()
	var screen_size: Vector2i = DisplayServer.screen_get_size(screen)
	lines.append("Screen size: %d x %d" % [screen_size.x, screen_size.y])

	lines.append("Locale: %s" % OS.get_locale())
	lines.append("Debug build: %s" % str(OS.is_debug_build()))

	lines.append("")
	lines.append("--- Recent log ---")
	var log_section := _read_log_tail()
	lines.append(log_section)

	var text := "\n".join(lines)
	return {
		"filename": "codecksDiagnostics.txt",
		"type": FILE_TYPE_PLAIN_TEXT,
		"data": text.to_utf8_buffer(),
	}


## Reads the tail of the engine log file. Returns a human-readable section body:
## either the recent log text (with a header line stating the source path), or a
## note explaining why no log was included. Never crashes on a missing file.
func _read_log_tail() -> String:
	var logging_on := bool(ProjectSettings.get_setting("debug/file_logging/enable_file_logging", false))
	var log_path := str(ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log"))

	if not logging_on:
		# Enabling the plugin turns this on automatically, so reaching here means
		# it was switched back off. Tell the dev exactly which toggle restores it.
		return "No log file: engine file logging is off. Turn on Project Settings -> Debug -> File Logging -> Enable File Logging (the Codecks plugin enables this on activation), then restart the project so the next run writes a log."

	if log_path.is_empty():
		return "No log file: no log path is configured (Project Settings -> Debug -> File Logging -> Log Path is empty)."

	if not FileAccess.file_exists(log_path):
		# Logging is on but no file exists yet. The usual cause is that file
		# logging was only just enabled (e.g. when the plugin was activated): the
		# setting is read at engine startup, so a log is not written until the
		# next run. Say so plainly instead of implying something is broken.
		return "No log file at '%s' yet. Engine file logging is enabled but the log is only created on startup, so it appears on the next run. Restart the project, reproduce the issue, then send the report again to attach the log." % log_path

	var file := FileAccess.open(log_path, FileAccess.READ)
	if file == null:
		var open_err := FileAccess.get_open_error()
		return "Log file at '%s' could not be opened (FileAccess error code %d)." % [log_path, open_err]

	var length := file.get_length()
	# Read only the final chunk so the attachment stays small even for huge logs.
	if length > _LOG_TAIL_BYTES:
		file.seek(length - _LOG_TAIL_BYTES)
		# The seek may land mid-line; drop the first (likely partial) line.
		file.get_line()
	var tail := file.get_as_text()
	file.close()

	tail = tail.strip_edges()
	if tail.is_empty():
		return "Log file at '%s' is present but empty." % log_path

	var header := "Source: %s (last %d bytes)" % [log_path, _LOG_TAIL_BYTES]
	return header + "\n" + tail


## Captures the current frame as a PNG and returns it shaped for create_report's `files`.
##
## When show_ui is false, the caller is expected to have hidden the report UI before
## calling (the form does this). Returns:
##   { filename = "codecksCardScreenshot.png", type = "png", data = PackedByteArray }
func take_screenshot(show_ui: bool = true) -> Dictionary:
	var viewport := get_viewport()
	var image: Image = viewport.get_texture().get_image()
	var data := image.save_png_to_buffer()
	return {
		"filename": "codecksCardScreenshot.png",
		"type": FILE_TYPE_PNG,
		"data": data,
	}
