#!/bin/bash
# Fetches and builds the two dependency trees for the fractal_native
# GDExtension. Invoked by CI and by anyone wanting to rebuild from source.
#
# Usage:
#   ./build/setup.sh [platform] [arch]
# Defaults: macos arm64
#
# Requires: git, scons, cmake, a C++17 toolchain.
set -euo pipefail

PLATFORM="${1:-macos}"
ARCH="${2:-arm64}"

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$THIS_DIR"

# ─── godot-cpp ────────────────────────────────────────────────────────────
if [ ! -d godot-cpp ]; then
  git clone --depth 1 -b godot-4.5-stable https://github.com/godotengine/godot-cpp.git
fi
echo "==> Building godot-cpp ($PLATFORM $ARCH)"
(cd godot-cpp && scons platform="$PLATFORM" arch="$ARCH" target=template_release -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)")

# ─── sentry-native (Crashpad backend) ─────────────────────────────────────
if [ ! -d sentry-native ]; then
  git clone --depth 1 --recursive https://github.com/getsentry/sentry-native.git
fi

BUILD_SUBDIR="build_${PLATFORM}_${ARCH}"
mkdir -p "sentry-native/$BUILD_SUBDIR"
echo "==> Configuring sentry-native ($PLATFORM $ARCH)"

CMAKE_ARGS=(
  -B "sentry-native/$BUILD_SUBDIR"
  -S sentry-native
  -DCMAKE_BUILD_TYPE=Release
  -DSENTRY_BACKEND=crashpad
  -DSENTRY_BUILD_SHARED_LIBS=OFF
  -DSENTRY_TRANSPORT=none
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
)
case "$PLATFORM" in
  macos)
    CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0)
    ;;
  windows)
    # Static CRT (/MT) to match godot-cpp; without this cmake defaults to /MD
    # and the linker rejects the mismatch (LNK2038).
    CMAKE_ARGS+=(-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded)
    ;;
esac
cmake "${CMAKE_ARGS[@]}"

echo "==> Building sentry-native ($PLATFORM $ARCH)"
cmake --build "sentry-native/$BUILD_SUBDIR" --config Release --parallel "$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)"

echo "==> setup.sh done. Run \`scons platform=$PLATFORM arch=$ARCH target=template_release\` from the addon root to build the GDExtension."
