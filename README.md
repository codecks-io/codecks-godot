# Codecks Bug & Feedback Reporter for Godot

Collect bugs and feedback right from your Godot game and keep players in the loop on what happens with their feedback.

This repository ships the reusable addon (`addons/codecks_bug_reporter/`) together with a small demo project so you can see it in action right away.

## Documentation

For the complete picture head to the [Codecks Manual Page](https://manual.codecks.io/user-reports/).

## Set up

Requires **Godot 4.x** (developed against 4.2).

1. Copy the `addons/codecks_bug_reporter/` folder into the `addons/` folder of your project.
2. Open **Project > Project Settings > Plugins** and enable **Codecks Bug & Feedback Reporter**.

Enabling the plugin does three things for you:

- registers the `codecks/report_token` project setting (visible under **Project > Project Settings**),
- registers the `Codecks` autoload singleton, the runtime API your game calls into, and
- turns on Godot's engine file logging so the optional diagnostics attachment can include a log (it leaves a custom log path you've configured alone).

Once enabled, open the `main.tscn` scene at the project root — it contains a default layout and a sample setup for you to check out.

## Getting started

The demo scene already provides the UI and the wiring you need to get going. To test the report tool from the demo:

1. Enter your report token (the one you created in your Codecks **User Reports** settings screen) into **Project > Project Settings**, under **Codecks > Report Token** (the `codecks/report_token` setting). The placeholder default is `XXXXXXXXXXXXXXXXXXXX`.
2. Run the project and click the **Report a Bug** button.
3. Fill out the form and press **Submit**.

If everything works, you should see a card pop up in your Codecks just moments later, with the screenshot attached. On a successful send the form shows a brief confirmation and closes itself; on a failure it stays open with a specific, actionable error message (and the same reason is printed to the Output panel) so you can tell at a glance which step broke — a wrong token, a network problem, or a rejected attachment upload.

The form collects a description, a severity (defaulting to **Low** so a report someone bothered to file never lands untriaged), an optional email, and a single **"Include a screenshot and diagnostics to help fix this"** toggle. That toggle is on by default; when ticked it attaches a screenshot plus a plain-text file with recent log output and basic diagnostics (OS, Godot version, GPU, resolution, locale). Untick it to send a text-only report with no attachments.

### Calling it from code

You don't have to use the form — you can drive the `Codecks` autoload directly:

```gdscript
# Listen for the outcome.
Codecks.report_created.connect(func(status): print("Codecks:", status))
Codecks.report_error.connect(func(msg): printerr("Codecks error:", msg))

# Optionally capture a screenshot (PNG of the current viewport).
var screenshot := Codecks.take_screenshot()

# Optionally build a diagnostics text file (recent log tail + system info).
var diagnostics := Codecks.build_diagnostics()

# Send the report. severity and email are optional; files is an array of
# { filename, type, data } dictionaries (take_screenshot and build_diagnostics
# each return one).
Codecks.create_report("The boss fight crashed!", "high", "player@example.com", [screenshot, diagnostics])
```

`report_created` fires once the flow finishes with one of:

- `"Success"` — the card was created and every attachment uploaded.
- `"Partially"` — the card was created, but at least one attachment upload failed.
- `"Fail"` — the card could not be created.

`report_error` fires with a specific human-readable message on every failure mode (no token, the placeholder token, a network/connection error, a rejected token, a server rejection, an empty or malformed response, or a failed attachment upload).

## Adapting it to your own needs

After testing the demo, we recommend copying or integrating the report form into your own game scene where you can configure it to show up on a hotkey or from a menu entry as it suits your game. Instantiate `res://addons/codecks_bug_reporter/bug_report_form.tscn` and add it to the tree to show the overlay form, just as the demo's `main.gd` does behind its **Report a Bug** button. You may also restyle the layout to fit your game thematically, or use the default layout as provided.

Under the hood there are two pieces you'll work with:

- **`Codecks` (autoload, `codecks.gd`)** — the runtime API. `create_report()` posts the card to Codecks and then uploads each attachment to the presigned URL the backend returns; `take_screenshot()` grabs the current viewport as a PNG; `build_diagnostics()` assembles the optional log-and-system-info text file. It also turns every failure into a specific, plain-language message rather than a raw error body.
- **`BugReportForm` (`bug_report_form.gd` / `bug_report_form.tscn`)** — the in-game overlay form that gathers the description, severity, email and attachment choices and submits them through the autoload. It auto-closes on success and keeps the error visible on failure.

## License

The code is licensed under the MIT license. See [`LICENSE`](./LICENSE).

## Contribute

Issues and pull requests are welcome. When working on the addon, keep new attachment types riding the existing `create_report` → `fileNames` → upload flow rather than standing up a second upload path, and keep player-facing data opt-in — never ship anything the player did not choose to send.
