# Fractal SDK for Godot 4.x

> **This repository is a mirror.** It is generated from Fractal's monorepo,
> which is where development happens. Edits made here are overwritten by the
> next sync, and pull requests cannot be merged directly — please open an
> issue describing the change instead.

Connects your Godot 4.x game to [Fractal](https://github.com/Isopod-Games).

Fractal is a platform for game developers. This SDK gives you analytics, error
tracking (including native crashes), and translations sync. You can turn each
part on or off, and it all sits behind a single `Fractal` autoload.

Fractal does more than what this SDK covers. Playtesting, alerts, CRM, and asset
tracking all live in the dashboard.

```gdscript
Fractal.configure({
    "api_key": "your-key",
    "api_url": "https://getfractal.dev",
    "analytics_enabled": true,
    "errors_enabled": true,
    "translations_enabled": true,
    "translations_locales": PackedStringArray(["en", "es", "fr"]),
})

Fractal.analytics.track("level_complete", {"level": 5, "duration_s": 47})
Fractal.errors.capture_error("NullReferenceException", "shop item missing")
Fractal.translations.sync()
```

Each subsystem is independently toggleable. Disabled subsystems become silent no-ops, call sites never need null checks.

## Features

- **Three subsystems, one autoload**: `Fractal.analytics`, `Fractal.errors`, `Fractal.translations`.
- **Toggleable per project**: disable any subsystem to skip its overhead entirely.
- **Offline-first**: events queue locally and retry; translations fall back to cache; errors are persisted to disk before the POST so a crash mid-submission doesn't lose data.
- **Three-layer crash capture**:
  1. `OS.crash()` and engine-side fatals write a crash report; replayed as `UnhandledCrash` on next launch.
  2. **Heartbeat session marker** detects SIGSEGV / OOM-kill / `kill -9` / force-quit on the next launch and emits an `AbnormalShutdown` event with breadcrumbs from the dead session and best-effort log scraping.
  3. **Optional native GDExtension** (`addons/fractal_native/`) catches SIGSEGV with full Crashpad minidumps. Backend symbolicates inline if `minidump_stackwalk` is on PATH and the project has uploaded breakpad `.sym` files via `/v1/symbols`.
  See [docs/ERRORS.md](docs/ERRORS.md).
- **Sentry-like error API**: breadcrumbs, severity, user/tag/context, retry-safe persistent error queue.
- **Live translations**: pull approved strings from Fractal at runtime; bundled `.translation` files act as offline fallback.
- **Platform-aware**: Windows / macOS / Linux / Steam Deck / Android / iOS / Web.
- **Cross-engine ready**: wire protocols and on-disk schemas are documented at [[CRASH_PROTOCOL.md](https://github.com/Isopod-Games/fractal-sdk-protocol/blob/main/CRASH_PROTOCOL.md)](https://github.com/Isopod-Games/fractal-sdk-protocol/blob/main/CRASH_PROTOCOL.md) so future Unity / Unreal / JS SDKs implement the same contract.
- **Tested**: **52 SDK tests** (unit + integration + e2e via gdUnit4) + **16 backend Go tests** (minidump endpoint, symbolicator, /v1/symbols) + a full-stack CI workflow that boots Postgres + ClickHouse + Rails + the Go collector and drives a headless Godot SDK against it (including a SIGKILL/replay crash-replay test).

## Installation

### Option 1: Download (Recommended)

1. Log in to [Fractal](https://getfractal.dev) and go to **API Keys**
2. Click **Download** next to the Godot SDK
3. Extract the zip at the **root of your Godot project**: this creates `addons/fractal/` and `addons/fractal_native/` automatically
4. Enable the plugin in **Project Settings → Plugins**
5. The `Fractal` singleton is automatically available

### Option 2: Copy the Addon Manually

1. Copy **both** `addons/fractal/` and `addons/fractal_native/` to your project's `addons/` directory
   - `addons/fractal/`, core plugin (analytics, errors, translations)
   - `addons/fractal_native/`, optional native extension for full minidump crash capture (Windows/Linux/macOS)
2. Enable the plugin in **Project Settings → Plugins**
3. The `Fractal` singleton is automatically available

Then call `Fractal.configure(...)` once at startup (e.g., in an autoload `_ready()`).

See the [Quick start](#quick-start-by-subsystem) section below.

## Quick start by subsystem

### Analytics

```gdscript
Fractal.analytics.track("session_start")
Fractal.analytics.track("item_purchased", {"item": "potion", "price": 50})
Fractal.analytics.set_player_id("player-123")
Fractal.analytics.set_user_property("region", "us")
Fractal.analytics.flush()  # force-send any queued batch
```

See [docs/ANALYTICS.md](docs/ANALYTICS.md) for the full API and offline behavior.

### Errors

```gdscript
Fractal.errors.add_breadcrumb("clicked start", "ui", "info")
Fractal.errors.set_user("player-123")
Fractal.errors.set_player_id("player-123")  # only needed if analytics is disabled/absent
Fractal.errors.set_tag("build", "release")

Fractal.errors.capture_error("NullReferenceException", "shop item missing", {
    "severity": "error",
    "handled": true,
    "stack_trace": "...",
    "extra": {"item_id": 99},
})
```

Crashes (`NOTIFICATION_CRASH`) are persisted to disk and replayed automatically on next launch as `severity: "fatal"`. See [docs/ERRORS.md](docs/ERRORS.md).

### Translations

```gdscript
# Pull approved translations from Fractal for all configured locales.
Fractal.translations.sync()

# Switch the active locale (also fires `language_changed`).
Fractal.translations.set_locale("es")
```

Synced translations are merged into Godot's `TranslationServer` on top of any bundled `.translation` files, so offline play continues to work. See [docs/TRANSLATIONS.md](docs/TRANSLATIONS.md).

## Configuration

Configuration is a `FractalConfig` Resource (or a plain Dictionary):

```gdscript
Fractal.configure({
    "api_key": "...",
    "api_url": "https://getfractal.dev",
    "app_version": "1.0.0",
    "environment": "production",       # development|staging|production

    # Toggles
    "analytics_enabled": true,
    "errors_enabled": true,
    "translations_enabled": false,

    # Tuning (optional)
    "analytics_batch_size": 10,
    "analytics_flush_interval": 30.0,
    "errors_max_breadcrumbs": 20,
    "translations_locales": PackedStringArray(["en", "es", "fr"]),
    "translations_sync_on_startup": true,
    "translations_sync_interval_hours": 6.0,

    "debug": false,
})
```

You can also save a `FractalConfig` resource to disk (`res://fractal_config.tres`) and pass it directly:

```gdscript
Fractal.configure(preload("res://fractal_config.tres"))
```

Full reference: [docs/CONFIG.md](docs/CONFIG.md).

## Test game

A small clicker game lives at `test_game/` and exercises every SDK feature:

- Analytics: clicks, purchases, milestones, achievements.
- Errors: a "throw error" debug button + a "force crash" button (replays on next launch).
- Translations: a live language picker (en/es/fr).

Open `project.godot` in Godot 4.5 and hit Play.

## Tests

`gdUnit4` is vendored under `addons/gdUnit4/`. Run the full suite headless:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd \
  --ignoreHeadlessMode \
  -a res://tests/unit -a res://tests/integration -a res://tests/e2e -c
```

Counts: 36 unit + 16 integration + 3 e2e = **55 tests**. See [docs/TESTING.md](docs/TESTING.md).

## Versioning

There is no manual release step. `bin/ci` enforces version freshness on every PR via `ci/check_sdk_freshness.sh`, and merging to `main` auto-tags. Four rules, all reported together (not first-fail):

- **Rule A, binary staleness.** Native source (`addons/fractal_native/{src/,SConstruct,build/setup.sh}`) changed since `addons/fractal_native/bin/<platform>/` was last committed for the **host platform** (whichever OS is running the check) → fail. Staleness on the other two platforms is a warning, not a failure. See "Per-platform binaries" below.
- **Rule B1, version bump required.** Shipped SDK source (`addons/fractal/**` etc.) changed but `VERSION` didn't → fail, with the exact `bump_version.sh` command to run.
- **Rule B2, increment sanity.** `VERSION` changed but isn't exactly one semver step (major, minor, or patch) ahead of `main` → fail, listing the allowed next versions.
- **Rule B3, native bump required.** Native source changed → `VERSION` must be bumped, and the **host platform's** `NATIVE_BINARY_VERSIONS` entry must change and equal the new `VERSION` (binaries embed `VERSION` at build time). Same host-platform gating as Rule A for the other two platforms.
- **Rule B4, unexplained binaries.** Any platform's `bin/<platform>/` changed with no matching native source change → fail (regardless of platform, this is a hygiene check, not a matrix requirement), unless `main` was already stale for that platform (a legitimate catch-up rebuild).

**Per-platform binaries.** `addons/fractal_native/bin/` holds three independent platform builds (`macos-arm64`, `linux-x86_64`, `windows-x86_64`), each tracked by its own entry in `version.gd`'s `NATIVE_BINARY_VERSIONS` dict. A developer can only build+verify the platform they're actually on, so the three entries are allowed to drift out of lockstep, CI only requires the host platform's entry to be current. The cross-platform matrix (`native_build.yml` / `bin/dispatch_matrix`) is optional: use it to backfill the other two platforms (e.g. ahead of a release), not as a required step for every native change.

**GDScript change:**

```bash
# edit addons/fractal/**
ci/bump_version.sh patch   # or minor/major
# write real notes under the new CHANGELOG.md heading, the "_Release notes
# pending._" stub fails check_version_sync.sh on purpose
bin/ci
```

**Native change** (binaries embed `VERSION`, so bump before rebuilding). A local build for your own platform is sufficient, the cross-platform matrix is not required:

```bash
# edit addons/fractal_native/src/**
ci/bump_version.sh minor

FRACTAL_BUILD_NATIVE=1 bin/ci   # builds for your platform and bumps its
                                # NATIVE_BINARY_VERSIONS entry automatically
git add addons/fractal_native/bin addons/fractal/core/version.gd
git commit -m "Rebuild Godot SDK native binaries for vX.Y.Z"
bin/ci
```

or manually, without the `bin/ci` wrapper:

```bash
addons/fractal_native/build/build_local.sh
```

Both stage the binary for your platform and bump only that platform's `NATIVE_BINARY_VERSIONS` entry. The other two platforms' entries are left as-is (warned about, not failed on) until someone on that platform rebuilds, or you backfill them yourself:

```bash
bin/dispatch_matrix   # optional, dispatches native_build.yml's cross-platform matrix (~30-45 min), waits for it,
                      # then prompts to fetch + stage the binaries for all three platforms (pass --yes to skip the prompt)
```

`native_build.yml` is manual-dispatch only (`bin/dispatch_matrix`) and optional, it's expensive across three platforms and this project isn't yet earning revenue to burn CI minutes on iteration. Use it when you want the other two platforms current too (e.g. ahead of a release), not as a gate on every native change. `bin/dispatch_matrix` chains straight into `fetch_native_artifacts.sh` on a successful run (with a `[Y/n]` prompt in between). See `ci/fetch_native_artifacts.sh` if you need to fetch a specific run manually instead (e.g. you answered `n` to the prompt, or the run was dispatched from elsewhere). Neither script ever commits; that's always a manual step.

### Release publishing and pinning

`.github/workflows/godot_sdk_tag.yml`'s `release` job (chained after `tag`, since a
default-`GITHUB_TOKEN`-pushed tag doesn't trigger a separate `on: push: tags:` workflow)
builds the zip via `rake godot_sdk:build_zip` and publishes it as a GitHub Release on the
public, releases-only `isopod-fractal-analytics/godot-sdk` repo, the SDK's source stays
here in the monorepo (see #287 for the deferred full split). Auth is a fine-grained PAT in
the `GODOT_SDK_RELEASES_TOKEN` Actions secret, scoped to just that repo. Idempotent:
re-running for an already-published version replaces the asset (`--clobber`) instead of
failing.

Consumers pin a version via `GET /api/v1/<version>` (see `docs/api/README.md`)
the currently-deployed version is served locally with no GitHub dependency; older versions
`302`-redirect to the release asset. The one-time backfill for the four pre-pipeline tags
(`v2.0.0`, `v2.0.1`, `v3.0.0`, `v3.0.1`) lives at `ci/backfill_releases.sh`.

`fetch_native_artifacts.sh` refuses to fetch a run that doesn't match the current `VERSION` and source tree, bump and push first, or it'll tell you to.

One version bump per PR. On merge, `.github/workflows/godot_sdk_tag.yml` tags `main` as `godot-sdk/vX.Y.Z` automatically (idempotent, safe if the tag already exists and points at an ancestor commit).

## Migrating from v1

If you were using `FractalAnalytics.track(...)` directly, see [docs/MIGRATION.md](docs/MIGRATION.md).

## Compatibility

- **Godot 4.4+** (tested with 4.5 stable).
- **No external dependencies**: pure GDScript, no GDExtension.
- **Coexists** with other addons (e.g., RogueRollers' Sentry GDExtension stays independent. See [docs/ERRORS.md](docs/ERRORS.md)).
