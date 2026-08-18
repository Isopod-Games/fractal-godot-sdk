# Fractal Native — Phase B crash capture (Crashpad backend)

Optional GDExtension that gives the Fractal SDK true native crash capture:
SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL on Unix; `SetUnhandledExceptionFilter`
on Windows. Crashes are caught by an out-of-process `crashpad_handler`,
written as full minidumps under `user://fractal/minidumps/`, and uploaded
to the Fractal backend (`POST /v1/minidumps`) on the next launch.

The pure-GDScript Fractal SDK works without this addon — see the
heartbeat-based abnormal-shutdown detection in `addons/fractal/`. The
native addon adds rich register-state minidumps for the SIGSEGV-class
crashes the heartbeat layer can only flag, not stack-trace.

## Status

| Platform | Built? | Verified? |
| --- | --- | --- |
| macOS arm64 | ✓ committed binary | ✓ end-to-end SIGSEGV → minidump → upload |
| macOS x86_64 | CI matrix | not yet validated |
| Linux x86_64 | CI matrix | not yet validated |
| Windows x86_64 | CI matrix | not yet validated |
| Android       | not yet | future work |
| iOS           | not yet | future work |

## How it works

1. `Fractal.errors.configure()` checks for `Engine.has_singleton("FractalNative")`. If found and `errors_native_enabled = true`, it calls `init(handler_path, database_path, release, environment)`.
2. The C++ binding initializes sentry-native (Crashpad backend) with an empty DSN — sentry-native handles signal handlers, fork-safe minidump writing, and database management. We never send anything to Sentry's servers.
3. When a native crash occurs, the `crashpad_handler` child process detects it, writes a `.dmp` to `user://fractal/minidumps/pending/<uuid>.dmp`, and the parent process dies as normal.
4. On the next launch, `Fractal.errors._drain_pending_minidumps()` enumerates the dump files and POSTs each to `/v1/minidumps` as multipart form data (dump + JSON metadata). On 2xx response, the dump is deleted.
5. The Go collector inserts a `NativeCrash` row into ClickHouse with the dump path. Symbolication is server-side / out-of-band.

## Building

```bash
# Pull and build dependencies (godot-cpp + sentry-native + crashpad).
./build/setup.sh macos arm64

# Build the GDExtension itself.
scons platform=macos arch=arm64 target=template_release -j8
```

Outputs `bin/macos-arm64/libfractal_native.dylib` and copies (manually for
now) `crashpad_handler` from the sentry-native build into `bin/<platform>/`.

For other platforms swap the args. Cross-compiling from macOS to
Linux/Windows is not supported — use the CI matrix (.github/workflows/native_build.yml).

## Configuration

Add to your `FractalConfig`:

```gdscript
config.errors_native_enabled = true
```

The errors module will detect `FractalNative`, init Crashpad, and start
writing dumps on crashes. If the addon isn't installed, this flag is a no-op.

## Wire spec

Multipart form to `POST /v1/minidumps`:

| Field | Type | Notes |
| --- | --- | --- |
| `minidump`    | binary | The .dmp file. |
| `metadata`    | JSON   | `{event_id, runtime: {name, version}, app_version, environment, user, tags, breadcrumbs, platform, os_version}` |
| `dump_format` | text   | `crashpad` for this addon. Other SDKs use `breakpad`, `unreal_uecp`, `dotnet_managed_trace`. |

See [[CRASH_PROTOCOL.md](https://github.com/Isopod-Games/fractal-sdk-protocol/blob/main/CRASH_PROTOCOL.md)](https://github.com/Isopod-Games/fractal-sdk-protocol/blob/main/CRASH_PROTOCOL.md) for the
full cross-engine contract.

## License notes

This addon vendors **sentry-native** (MIT) and **Crashpad** (Apache 2.0).
Both are linked statically into `libfractal_native.dylib` / .so / .dll.

## Gotchas

### `#` comments in `.gdextension` files silently break library loading

Godot's INI parser (`VariantParser::parse_tag_assign_eof`) only treats `;` as
a comment character — **`#` is not a comment**. Any `#`-prefixed line between
two section headers is treated as text that gets accumulated into an internal
buffer. Once that buffer is non-empty, the `[` of the next section header is
no longer recognised as a tag; instead it is appended to the buffer and the
section is consumed as a garbage key under the previous section.

**Symptom:** `ERROR: No GDExtension library found for current OS and
architecture (macos.arm64)` — even when the keys are correct and all feature
tags are confirmed active. Every key variant fails identically because
`has_section("libraries")` returns false.

**The trap:** `config->load()` returns `OK` (no error message), so the parse
looks successful. The feature-tag diagnostic script will also print the right
features (e.g. `has_feature: arm64`) because the diagnostic runs after loading
— the mismatch is invisible at runtime.

**Fix:** keep `.gdextension` files comment-free. If you need notes, use `;`
(semicolon) comments, or put the notes elsewhere.

This cost several CI runs to diagnose; do not add `#` comments back.

## Limitations / TODO

- **No symbolication today.** The minidump is stored on the backend but
  unprocessed. Wiring up `minidump_stackwalk` (Breakpad's symbolicator)
  with debug-symbol upload is a future backend task.
- **iOS / Android not yet shipped.** Requires NDK / Xcode build matrix.
- **Multi-arch macOS** ships only arm64 today; Intel build via CI.
