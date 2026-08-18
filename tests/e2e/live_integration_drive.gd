extends Node
## Headless live-integration driver — fires real events at a real Fractal
## collector on http://localhost:8080, then exits.
##
## Used by sdks/godot/ci/run_e2e.sh to verify that a Godot SDK
## release talks correctly to a live Postgres + ClickHouse + Go-collector
## stack. Not part of the gdUnit4 suite (no in-Godot assertions); CI asserts
## the resulting state in ClickHouse via curl after this scene exits.
##
## ENV inputs (read at runtime — let CI inject):
##   FRACTAL_API_KEY        defaults to "ci-e2e-fixed-api-key"
##   FRACTAL_COLLECTOR      defaults to "http://localhost:8080"
##   FRACTAL_API            defaults to ""           — when set, exercises Rails translations sync
##   FRACTAL_DRIVE_CLICKS   defaults to 12
##   FRACTAL_DRIVE_MODE     defaults to "normal"     — one of:
##                            normal:        fire events, errors, translations; assert; exit 0
##                            crash:         configure, write breadcrumb, OS.kill self
##                                           (leaves an unclean session.json behind)
##                            verify_replay: configure (drains the previous unclean
##                                           session.json into an AbnormalShutdown event,
##                                           POSTed to /v1/errors); exit 0
##                            native_crash:  arm Crashpad, then deliberately
##                                           segfault via the FractalNative
##                                           GDExtension. Process dies; minidump
##                                           lands at user://fractal/minidumps/.
##                            native_verify: configure with errors_native_enabled=true,
##                                           let the SDK enumerate + upload pending
##                                           minidumps via POST /v1/minidumps.
##                                           Exits 0 once one has been uploaded.
##
## Local repro:
##   ./ci/godot_tests.sh res://tests/e2e/live_integration_drive.tscn
## (the gdunit runner ignores non-test-suite scenes; for live drive run via
##  Godot directly: `godot --headless res://tests/e2e/live_integration_drive.tscn`)


func _ready() -> void:
	# Wait one frame so all autoloads are fully resolved.
	await get_tree().process_frame

	var api_key: String = OS.get_environment("FRACTAL_API_KEY")
	if api_key.is_empty():
		api_key = "ci-e2e-fixed-api-key"
	var collector: String = OS.get_environment("FRACTAL_COLLECTOR")
	if collector.is_empty():
		collector = "http://localhost:8080"
	var api_url: String = OS.get_environment("FRACTAL_API")  # empty disables translations
	var click_count: int = int(OS.get_environment("FRACTAL_DRIVE_CLICKS"))
	if click_count <= 0:
		click_count = 12
	var mode: String = OS.get_environment("FRACTAL_DRIVE_MODE")
	if mode.is_empty():
		mode = "normal"

	var translations_enabled: bool = not api_url.is_empty()

	print("[drive] config: mode=%s, collector=%s, api=%s (translations=%s), clicks=%d" % [
		mode, collector, api_url, translations_enabled, click_count,
	])

	# AnalyticsGlue is bypassed via FRACTAL_CI_MODE — this is the FIRST
	# configure() call, which means the persisted-state drain runs here
	# with CI credentials.
	# Uses small batch_size so the driver actually triggers a network round-trip
	# instead of waiting on the 30-second flush timer.
	# Long heartbeat interval keeps the on-disk marker static during the test;
	# the synthetic shutdown timing comes from the test orchestration, not the timer.
	Fractal.configure({
		"api_key": api_key,
		"collector_url": collector,
		"api_url": api_url,
		"app_version": "ci-e2e",
		"environment": "ci",
		"analytics_enabled": true,
		"errors_enabled": true,
		"translations_enabled": translations_enabled,
		"translations_locales": PackedStringArray(["es"]),
		"translations_sync_on_startup": false,
		"analytics_batch_size": 5,
		"analytics_flush_interval": 1.0,
		"errors_session_marker_enabled": true,
		"errors_heartbeat_interval_s": 60.0,
		# native_verify intentionally skips sentry_init — drain_pending_native()
		# uploads leftovers without arming Crashpad, avoiding a WSL2 spin-loop.
		"errors_native_enabled": (mode == "native_crash"),
		"debug": true,
	})
	# Use a deterministic player ID so CI assertions can target it precisely.
	Fractal.analytics.set_player_id("ci_drive_player")

	if mode == "crash":
		await _run_crash_mode()
		return  # _run_crash_mode never returns normally — it OS.kills.
	if mode == "verify_replay":
		await _run_verify_replay_mode()
		return
	if mode == "native_crash":
		await _run_native_crash_mode()
		return  # also never returns — segfaults via Crashpad
	if mode == "native_verify":
		await _run_native_verify_mode()
		return

	var batches_sent: Array[int] = [0]
	var errors_sent: Array[int] = [0]
	var sync_results: Array = []  # populated with {locale, count} on each sync
	Fractal.analytics.batch_sent.connect(func(_n): batches_sent[0] += 1)
	Fractal.errors.error_sent.connect(func(): errors_sent[0] += 1)
	Fractal.translations.sync_succeeded.connect(func(locale, count):
		sync_results.append({"locale": locale, "count": count})
	)
	Fractal.translations.sync_failed.connect(func(locale, err):
		push_error("[drive] translations sync_failed for %s: %s" % [locale, err])
	)

	print("[drive] firing %d clicks + 1 shop_open + 1 item_purchased" % click_count)
	for i in range(click_count):
		Fractal.analytics.track("ci_click", {"i": i})
	Fractal.analytics.track("ci_shop_open", {})
	Fractal.analytics.track("ci_item_purchased", {"item": "tap_power", "cost": 10})
	Fractal.analytics.flush()

	print("[drive] capturing one warning error")
	Fractal.errors.set_tag("ci", "true")
	Fractal.errors.add_breadcrumb("ci breadcrumb", "test", "info")
	Fractal.errors.capture_error("CIIntegrationError", "fired from live driver", {
		"severity": "warning",
		"handled": true,
	})

	if translations_enabled:
		print("[drive] syncing translations for 'es'")
		Fractal.translations.sync()

	# Wait long enough for SDK HTTP round-trip + collector batcher flush to ClickHouse.
	# Collector's default batcher flushes every 1s; allow a comfortable margin.
	await get_tree().create_timer(8.0).timeout

	print("[drive] batches_sent=%d, errors_sent=%d, translation_syncs=%d" % [
		batches_sent[0], errors_sent[0], sync_results.size(),
	])
	if batches_sent[0] == 0:
		push_error("[drive] no batches were acknowledged by collector — failing")
		get_tree().quit(1)
		return
	if errors_sent[0] == 0:
		push_error("[drive] no errors were acknowledged by collector — failing")
		get_tree().quit(1)
		return
	if translations_enabled:
		if sync_results.is_empty():
			push_error("[drive] translations sync did not succeed — failing")
			get_tree().quit(1)
			return
		# Confirm a synced key actually resolves through TranslationServer.
		var prev_locale: String = TranslationServer.get_locale()
		TranslationServer.set_locale("es")
		var resolved: String = TranslationServer.translate("ui.greeting")
		TranslationServer.set_locale(prev_locale)
		print("[drive] tr('ui.greeting', es) -> '%s' (expected 'Hola CI')" % resolved)
		if resolved != "Hola CI":
			push_error("[drive] expected synced translation 'Hola CI', got '%s'" % resolved)
			get_tree().quit(1)
			return

	print("[drive] OK — exiting 0")
	get_tree().quit(0)


func _run_crash_mode() -> void:
	# Phase 1 of the crash-replay test: leave an unclean session marker on
	# disk and exit via SIGKILL so neither NOTIFICATION_CRASH nor
	# NOTIFICATION_WM_CLOSE_REQUEST fire. The next launch will detect the
	# unclean marker and emit an AbnormalShutdown error.
	Fractal.errors.set_tag("ci_crash_phase", "1")
	Fractal.errors.add_breadcrumb("about to be killed", "test", "warning")
	# Tick the marker once so the breadcrumb is captured on disk.
	Fractal.errors._on_heartbeat()
	# Defer one frame so the file write completes before kill.
	await get_tree().process_frame
	print("[drive] mode=crash — sending SIGKILL to self")
	OS.kill(OS.get_process_id())


func _run_verify_replay_mode() -> void:
	# Phase 2: configure() above already drained the unclean marker into
	# an AbnormalShutdown event. Wait for it to be POSTed.
	var sent: Array[int] = [0]
	Fractal.errors.error_sent.connect(func(): sent[0] += 1)
	var ok: bool = await _wait_for(func(): return sent[0] >= 1, 8000)
	if not ok:
		push_error("[drive] mode=verify_replay — no AbnormalShutdown was POSTed within 8s")
		get_tree().quit(1)
		return
	print("[drive] mode=verify_replay — AbnormalShutdown POSTed; exiting 0")
	get_tree().quit(0)


func _wait_for(predicate: Callable, timeout_ms: int) -> bool:
	var elapsed := 0
	while not predicate.call() and elapsed < timeout_ms:
		await get_tree().process_frame
		elapsed += 16
	return predicate.call()


func _run_native_crash_mode() -> void:
	# Phase 1 of the native-crash-replay test. Requires the FractalNative
	# GDExtension to be present on this platform — fails loudly if not,
	# because the workflow is supposed to have built and dropped it in.
	if not Engine.has_singleton("FractalNative"):
		push_error("[drive] mode=native_crash: FractalNative singleton missing — addon not built for this platform")
		get_tree().quit(1)
		return
	var native = Engine.get_singleton("FractalNative")
	if not native.is_initialized():
		push_error("[drive] mode=native_crash: native init() never ran — errors_native_enabled didn't take")
		get_tree().quit(1)
		return
	# Tag the crash for downstream identification in CH.
	Fractal.errors.set_tag("ci_native_phase", "1")
	Fractal.errors.add_breadcrumb("about to native-segfault", "test", "warning")
	# Tick session marker so the breadcrumb is also persisted via the
	# heartbeat layer — useful belt-and-suspenders if Crashpad happens
	# to fail to write for any reason.
	Fractal.errors._on_heartbeat()
	await get_tree().process_frame
	print("[drive] mode=native_crash — calling FractalNative._force_segfault_for_testing()")
	native._force_segfault_for_testing()
	# Unreachable — the deref above triggers SIGSEGV; Crashpad's handler
	# writes the minidump out-of-process and the parent dies.
	push_error("[drive] mode=native_crash: UNREACHABLE — segfault didn't happen")
	get_tree().quit(1)


func _run_native_verify_mode() -> void:
	# Phase 2 of the native-crash-replay test. configure() with
	# errors_native_enabled=true → _arm_native() → _drain_pending_minidumps()
	# enumerates the dump from phase 1 and uploads each via /v1/minidumps.
	# We wait for the per-dump request to complete, then exit 0.
	#
	# Native uploads use FractalHttpClient.request_raw_bytes (multipart),
	# bypassing the regular /v1/errors path — so error_sent is NOT a
	# reliable signal here. Instead we poll the on-disk minidump
	# directory: when it's empty, the upload(s) succeeded.
	var helpers = load("res://addons/fractal_native/fractal_native.gd")
	if helpers == null or not helpers.is_available():
		push_error("[drive] mode=native_verify: FractalNative not available")
		get_tree().quit(1)
		return
	var native = Engine.get_singleton("FractalNative")
	var db_path: String = helpers.database_path()
	var initial_count: int = native.pending_minidumps(db_path).size()
	if initial_count == 0:
		push_error("[drive] mode=native_verify: no pending minidumps to drain — phase 1 didn't run or didn't crash")
		get_tree().quit(1)
		return
	print("[drive] mode=native_verify: %d pending minidump(s) to upload" % initial_count)
	# Drain without sentry_init — avoids the WSL2 Crashpad spin-loop.
	Fractal.errors.drain_pending_native()
	var ok: bool = await _wait_for(
		func(): return native.pending_minidumps(db_path).size() < initial_count,
		15000,
	)
	if not ok:
		push_error("[drive] mode=native_verify: timed out waiting for upload")
		get_tree().quit(1)
		return
	print("[drive] mode=native_verify: upload acknowledged; exiting 0")
	get_tree().quit(0)
