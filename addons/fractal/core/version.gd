class_name FractalVersion
extends RefCounted
## Single source of truth for the SDK version at runtime.
##
## Kept in lockstep with `sdks/godot/VERSION` (`ci/bump_version.sh` propagates
## one into the other; `ci/check_version_sync.sh` enforces they agree, and
## `ci/check_sdk_freshness.sh` fails `bin/ci` loudly if a bump is missing).
##
## VERSION bumps on every SDK source change. NATIVE_BINARY_VERSIONS tracks
## each platform's committed binary independently — a developer can only
## build+verify one platform locally, so the three entries legitimately fall
## out of lockstep with each other (and with VERSION) until someone on that
## platform rebuilds it. `ci/check_sdk_freshness.sh` only requires the
## *current* platform's entry to be current; the other two are a soft
## warning, not a CI failure — see version_lib.sh's host-platform gating.
## The runtime mismatch check in errors.gd compares FractalNative.get_version()
## against this platform's entry, not VERSION, to avoid false positives on
## non-native releases.
## TODO: PRE_VERSIONING_NATIVE below self-retires the first time every
## NATIVE_BINARY_VERSIONS entry moves past 2.0.0 — delete it then.

const VERSION := "3.0.4"

## Per platform-arch key (matches addons/fractal_native/bin/<key>/), the
## VERSION last rebuilt+recommitted for that platform via
## `ci/fetch_native_artifacts.sh` (cross-platform matrix) or a local build
## (`addons/fractal_native/build/build_local.sh`, current platform only).
const NATIVE_BINARY_VERSIONS := {
	"macos-arm64": "3.0.0",
	"linux-x86_64": "3.0.0",
	"windows-x86_64": "3.0.0",
}

## Last native build cut before get_version() existed. A binary without the
## method is treated as matching iff we still expect this version — the
## exemption self-retires the moment a platform's NATIVE_BINARY_VERSIONS
## entry moves past it.
const PRE_VERSIONING_NATIVE := "2.0.0"


## The addons/fractal_native/bin/<key>/ key for the platform this code is
## currently running on, e.g. "linux-x86_64". Independent of
## FractalPlatformDetector to avoid a circular preload (platform_detector.gd
## already preloads this file for VERSION).
static func current_platform_key() -> String:
	var os_key: String
	match OS.get_name():
		"Windows":
			os_key = "windows"
		"macOS":
			os_key = "macos"
		"Linux":
			os_key = "linux"
		_:
			os_key = OS.get_name().to_lower()
	return "%s-%s" % [os_key, Engine.get_architecture_name()]


## The NATIVE_BINARY_VERSIONS entry for <platform_key>, or "" if unknown
## (e.g. a platform with no committed native binary at all).
static func native_binary_version_for(platform_key: String) -> String:
	return NATIVE_BINARY_VERSIONS.get(platform_key, "")


## Pure comparison used by errors.gd::_arm_native to decide whether the
## loaded FractalNative singleton matches the binary version this GDScript
## release expects for the current platform. Factored out so it's testable
## without a real GDExtension singleton. `has_get_version` should be false
## when the singleton predates the get_version() binding (pre-2.1 binaries)
## — that is treated as a match only while the expected version still points
## at PRE_VERSIONING_NATIVE; any later expected version makes it a mismatch.
static func native_binary_matches(has_get_version: bool, reported_version: String,
		expected: String = native_binary_version_for(current_platform_key())) -> bool:
	if not has_get_version:
		return expected == PRE_VERSIONING_NATIVE
	return reported_version == expected
