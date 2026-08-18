#!/bin/bash
# Builds libfractal_native (+ crashpad_handler) for the current platform.
# Called by bin/ci when FRACTAL_BUILD_NATIVE=1 is set.
#
# On success, bumps this platform's entry in version.gd's
# NATIVE_BINARY_VERSIONS to the current VERSION — this is the mechanism that
# satisfies check_sdk_freshness.sh's staleness/version-bump rules for the
# host platform. The other two platforms are untouched; they're not built
# here (see bin/dispatch_matrix for backfilling them via the GH Actions
# matrix, now optional rather than required).
#
# Requires: scons, cmake, and a C++17 toolchain.
#   macOS:  brew install scons cmake
#   Linux:  sudo apt-get install scons cmake build-essential libcurl4-openssl-dev pkg-config zlib1g-dev
set -euo pipefail

ADDON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Detect platform ──────────────────────────────────────────────────────────
case "$(uname -s)" in
  Linux*)  PLATFORM=linux  ;;
  Darwin*) PLATFORM=macos  ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
  *) echo "ERROR: unsupported platform $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64)        ARCH=x86_64 ;;
  arm64|aarch64) ARCH=arm64  ;;
  *) echo "ERROR: unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"

echo "==> Building fractal_native for $PLATFORM/$ARCH (jobs: $JOBS)"
cd "$ADDON_DIR"

./build/setup.sh "$PLATFORM" "$ARCH"
scons platform="$PLATFORM" arch="$ARCH" target=template_release -j"$JOBS"

# Copy crashpad_handler alongside the lib so the addon ships as a unit
for candidate in \
  "build/sentry-native/build_${PLATFORM}_${ARCH}/crashpad_build/handler/crashpad_handler" \
  "build/sentry-native/build_${PLATFORM}_${ARCH}/crashpad_build/handler/Release/crashpad_handler.exe"
do
  if [ -f "$candidate" ]; then
    dest="bin/${PLATFORM}-${ARCH}/$(basename "$candidate")"
    if [ -f "$dest" ] && cmp -s "$candidate" "$dest"; then
      echo "$(basename "$candidate") unchanged, skipping copy"
    else
      cp "$candidate" "bin/${PLATFORM}-${ARCH}/"
      chmod +x "$dest" 2>/dev/null || true
      echo "Copied $(basename "$candidate") → bin/${PLATFORM}-${ARCH}/"
    fi
    break
  fi
done

echo "Build complete:"
ls -la "bin/${PLATFORM}-${ARCH}/"

# Regenerate .gdextension based on which platform binaries now exist in bin/.
# Only committed binaries appear in the file so Godot doesn't error on missing libs.
echo "==> Updating fractal_native.gdextension..."
python3 - "$ADDON_DIR" <<'PYEOF'
import sys, os

addon = sys.argv[1]

PLATFORMS = [
    ("macos-arm64",    "macos",   "arm64",  "libfractal_native.dylib", "crashpad_handler",     "macos"),
    ("linux-x86_64",   "linux",   "x86_64", "libfractal_native.so",    "crashpad_handler",     "linux"),
    ("windows-x86_64", "windows", "x86_64", "fractal_native.dll",      "crashpad_handler.exe", "windows"),
]

libs, deps = [], []
for dir_name, platform, arch, lib_file, handler_file, dep_key in PLATFORMS:
    if not os.path.isfile(os.path.join(addon, "bin", dir_name, lib_file)):
        continue
    prefix = f"res://addons/fractal_native/bin/{dir_name}"
    libs += [
        f'{platform}.{arch} = "{prefix}/{lib_file}"',
        f'{platform}.debug.{arch} = "{prefix}/{lib_file}"',
        f'{platform}.editor.{arch} = "{prefix}/{lib_file}"',
    ]
    if os.path.isfile(os.path.join(addon, "bin", dir_name, handler_file)):
        deps.append(f'{dep_key} = {{\n    "{prefix}/{handler_file}" : ""\n}}')

content = (
    "[configuration]\n\n"
    'entry_symbol = "fractal_native_library_init"\n'
    'compatibility_minimum = "4.4"\n\n'
    "[libraries]\n\n"
    + "\n".join(libs) + "\n\n"
    "[dependencies]\n\n"
    + "\n".join(deps) + "\n"
)

gdext = os.path.join(addon, "fractal_native.gdextension")
with open(gdext, "w") as f:
    f.write(content)
print(f"Updated {gdext} for platforms: {[p[0] for p in PLATFORMS if os.path.isfile(os.path.join(addon, 'bin', p[0], p[3]))]}")
PYEOF

# Bump this platform's NATIVE_BINARY_VERSIONS entry to the current VERSION.
# This is what makes a local build sufficient for check_sdk_freshness.sh's
# Rule A/B3 on the host platform — no GH Actions matrix required. The other
# two platforms' entries are left untouched; they're not verifiable here.
VERSION_GD="$ADDON_DIR/../fractal/core/version.gd"
SDK_VERSION="$(tr -d '[:space:]' < "$ADDON_DIR/../../VERSION")"
PLATFORM_KEY="${PLATFORM}-${ARCH}"
sed -i.bak "s/\"$PLATFORM_KEY\": \"[^\"]*\"/\"$PLATFORM_KEY\": \"$SDK_VERSION\"/" "$VERSION_GD"
rm -f "$VERSION_GD.bak"
echo "Set NATIVE_BINARY_VERSIONS[\"$PLATFORM_KEY\"] := $SDK_VERSION"
