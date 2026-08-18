# Shared path-classification regexes. Sourced (not executed) by
# build/dispatch_matrix.sh, ci/version_lib.sh, and ci/check_sdk_freshness.sh
# so none of them can drift on what counts as "native changed" / "shipped
# source changed" — keep the definitions here only.
#
# Note: these regexes classify *source paths* for CI purposes and are
# independent from GodotSdk::ZipBuilder::SHIPPED_ADDON_GLOBS
# (lib/godot_sdk/zip_builder.rb), which allowlists what actually goes into
# the distributable zip. Both express "what ships" and must be kept
# conceptually in sync, but they operate on different inputs (git diff paths
# here vs. a file tree there).
FRACTAL_NATIVE_PATHS_REGEX='sdks/godot/addons/fractal_native/(src/|SConstruct|build/setup\.sh)'

# Shipped Godot SDK source: the GDScript addon plus the thin native-glue
# files that ship alongside the compiled binary. Native source proper
# (src/, SConstruct, build/setup.sh) is FRACTAL_NATIVE_PATHS_REGEX's domain
# (Rule B3), not this one (Rule B1) — a change matching both is still only
# evaluated once, by B3.
FRACTAL_SDK_SHIPPED_PATHS_REGEX='sdks/godot/(addons/fractal/|addons/fractal_native/fractal_native\.(gd|gdextension))'

# Excluded from FRACTAL_SDK_SHIPPED_PATHS_REGEX: editor-generated files,
# vendored test framework, compiled binaries, native source (B3's domain),
# tests, the demo game, docs, the ci/ tooling itself, and the
# version-carrying files (their own diffs don't require *another* bump).
FRACTAL_SDK_EXCLUDE_PATHS_REGEX='\.uid$|sdks/godot/addons/gdUnit4/|sdks/godot/addons/fractal_native/bin/|sdks/godot/addons/fractal_native/(src/|SConstruct|build/setup\.sh)|sdks/godot/tests/|sdks/godot/test_game/|sdks/godot/docs/|sdks/godot/ci/|sdks/godot/README\.md$|sdks/godot/CHANGELOG\.md$|sdks/godot/VERSION$'

# Committed native binaries — Rule B4 (unexplained-binary-change) domain.
FRACTAL_NATIVE_BIN_REGEX='sdks/godot/addons/fractal_native/bin/'

# The three platform-arch keys binaries are staged under
# (addons/fractal_native/bin/<key>/) and tracked individually in
# NATIVE_BINARY_VERSIONS. A developer can only build+verify one of these
# locally per machine — see version_lib.sh's host-platform gating.
FRACTAL_NATIVE_PLATFORM_KEYS=(macos-arm64 linux-x86_64 windows-x86_64)
