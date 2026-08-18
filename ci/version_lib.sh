# Pure decision logic for the Godot SDK version-freshness checks
# (sdks/godot/ci/check_sdk_freshness.sh, bump_version.sh), factored out so
# it can be sourced (and unit-tested via BATS) without touching git remotes
# or GitHub. Callers must source native_paths.sh first for
# FRACTAL_NATIVE_PATHS_REGEX, FRACTAL_NATIVE_PLATFORM_KEYS, and friends.

# fractal_host_platform_key
#
# Prints the addons/fractal_native/bin/<key>/ key for the platform this
# script is currently running on, e.g. "linux-x86_64". Mirrors the
# platform/arch detection in build/build_local.sh so both agree on what
# "the platform you can build locally" means.
fractal_host_platform_key() {
  local platform arch
  case "$(uname -s)" in
    Linux*)  platform=linux ;;
    Darwin*) platform=macos ;;
    MINGW*|MSYS*|CYGWIN*) platform=windows ;;
    *) platform="$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
  esac
  case "$(uname -m)" in
    x86_64)        arch=x86_64 ;;
    arm64|aarch64) arch=arm64  ;;
    *) arch="$(uname -m)" ;;
  esac
  echo "$platform-$arch"
}

# fractal_native_rebuild_needed <ref> <platform_key>
#
# "Has native source changed since the binaries under
# addons/fractal_native/bin/<platform_key>/ were last committed, as of
# <ref>?" Anchoring on the bin/<platform_key> commit, not the last
# godot-sdk/v* tag, means a --skip-native release can never hide a native
# change from the next release's detection: a tag-range diff only sees the
# range since the newest tag, so a change that shipped under --skip-native
# (no tag movement of its own) falls outside every future tag-range diff and
# goes undetected forever. Baseline anchoring has no such blind spot, it
# always looks back to the actual last-committed binaries, regardless of tag
# history.
#
# Scoped per-platform because a developer can only rebuild+verify the
# platform they're actually on; the other two platforms' binaries are
# allowed to lag (see fractal_freshness_check's host-platform gating).
#
# Prints the matching changed native-source files (if any) to stdout, one
# per line. Returns 0 (rebuild needed) when there is no commit touching
# bin/<platform_key> reachable from <ref> (nothing has ever been committed
# there), or when any file changed between that commit and <ref> matches
# FRACTAL_NATIVE_PATHS_REGEX. Returns 1 otherwise.
fractal_native_rebuild_needed() {
  local ref="$1" platform_key="$2"
  local baseline
  baseline="$(git log -1 --format=%H "$ref" -- "sdks/godot/addons/fractal_native/bin/$platform_key" 2>/dev/null || true)"

  if [ -z "$baseline" ]; then
    return 0
  fi

  local changed
  changed="$(git diff --name-only "$baseline..$ref" 2>/dev/null | grep -E "$FRACTAL_NATIVE_PATHS_REGEX" || true)"
  if [ -n "$changed" ]; then
    echo "$changed"
    return 0
  fi
  return 1
}

# fractal_version_increment_ok <current> <candidate>
#
# True iff <candidate> is exactly one semver step ahead of <current>: a
# major bump (X+1.0.0), a minor bump (X.Y+1.0), or a patch bump (X.Y.Z+1).
# Guards against typos, e.g. 2.0.0 -> 12.3.0, sailing through just
# because 12.3.0 sorts higher than 2.0.0.
fractal_version_increment_ok() {
  local current="$1" candidate="$2"
  local c_major c_minor c_patch n_major n_minor n_patch
  IFS='.' read -r c_major c_minor c_patch <<< "$current"
  IFS='.' read -r n_major n_minor n_patch <<< "$candidate"

  if [ "$n_major" -eq "$((c_major + 1))" ] && [ "$n_minor" -eq 0 ] && [ "$n_patch" -eq 0 ]; then
    return 0
  fi
  if [ "$n_major" -eq "$c_major" ] && [ "$n_minor" -eq "$((c_minor + 1))" ] && [ "$n_patch" -eq 0 ]; then
    return 0
  fi
  if [ "$n_major" -eq "$c_major" ] && [ "$n_minor" -eq "$c_minor" ] && [ "$n_patch" -eq "$((c_patch + 1))" ]; then
    return 0
  fi
  return 1
}

# fractal_next_versions <current>
#
# Prints the three versions fractal_version_increment_ok would accept for
# <current>, one per line, major/minor/patch bump in that order. Used to
# tell the operator what's actually allowed after a rejected version.
fractal_next_versions() {
  local current="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<< "$current"
  echo "$((major + 1)).0.0"
  echo "$major.$((minor + 1)).0"
  echo "$major.$minor.$((patch + 1))"
}

# fractal_version_at_ref <ref>
#
# Prints sdks/godot/VERSION as it existed at <ref>, whitespace-stripped.
# Prints nothing (empty string) if the file doesn't exist at <ref>, this is
# the bootstrap signal: VERSION/version.gd don't exist on older history, so
# an empty result means "skip the numeric bump rules, they don't apply yet."
fractal_version_at_ref() {
  local ref="$1"
  git show "$ref:sdks/godot/VERSION" 2>/dev/null | tr -d '[:space:]' || true
}

# fractal_native_binary_version_at_ref <ref> <platform_key>
#
# Prints the NATIVE_BINARY_VERSIONS["<platform_key>"] entry from version.gd
# as it existed at <ref>. Prints nothing if the file or that platform's
# entry doesn't exist at <ref>.
fractal_native_binary_version_at_ref() {
  local ref="$1" platform_key="$2"
  git show "$ref:sdks/godot/addons/fractal/core/version.gd" 2>/dev/null \
    | sed -n "s/.*\"$platform_key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# fractal_freshness_check <base> <head> [host_platform_key]
#
# Runs the four CI rules against the diff from <base> to <head> and prints a
# report to stdout/stderr. Returns 0 iff every rule passes; prints and
# accumulates ALL violations rather than stopping at the first one, so a
# single `bin/ci` run surfaces everything that needs fixing at once.
#
# <host_platform_key> defaults to fractal_host_platform_key(), the platform
# actually running this check. Only that platform's native binary is
# required to be fresh and version-matched; the other two platforms are a
# non-fatal WARNING when stale, since a developer can only build+verify one
# platform locally and the cross-platform matrix (native_build.yml) is now
# optional/occasional rather than a required release gate.
#
# Rule A (staleness, always runs, ref-invariant): native source changed
#   since the host platform's addons/fractal_native/bin/<key>/ was last
#   committed, as of <head>. Fatal for the host platform; a WARNING for the
#   other two.
# Rule B1 (GDScript bump): shipped SDK source changed but VERSION didn't.
# Rule B2 (increment sanity): VERSION changed but isn't exactly one semver
#   step ahead of <base>.
# Rule B3 (native bump): native source changed, requires VERSION bumped and
#   the host platform's NATIVE_BINARY_VERSIONS entry changed to match the
#   new VERSION. Fatal for the host platform; a WARNING for the other two.
# Rule B4 (unexplained binaries): a platform's bin/<key>/ changed with no
#   matching native source change, unless that platform was already stale
#   (catch-up rebuild), which still requires its NATIVE_BINARY_VERSIONS
#   entry to match VERSION. Always fatal (any platform), this catches
#   accidental/unexplained commits and doesn't depend on the matrix.
#
# The B-rules are skipped entirely (with a logged reason) when VERSION is
# absent at <base>, "bootstrap mode," i.e. this diff is the one
# introducing VERSION/version.gd to the repo. Rule A still runs.
fractal_freshness_check() {
  local base="$1" head="$2"
  local host_platform_key="${3:-$(fractal_host_platform_key)}"
  local failed=0

  local platform_key rebuild_needed_output
  for platform_key in "${FRACTAL_NATIVE_PLATFORM_KEYS[@]}"; do
    if rebuild_needed_output="$(fractal_native_rebuild_needed "$head" "$platform_key")"; then
      if [ "$platform_key" = "$host_platform_key" ]; then
        failed=1
        echo "FAIL (Rule A, binary staleness, $platform_key): native source changed since addons/fractal_native/bin/$platform_key/ was last committed:"
        echo "$rebuild_needed_output" | sed 's/^/    /'
        echo "  Remediation: build locally to catch compile errors cheaply, "
        echo "    sdks/godot/addons/fractal_native/build/setup.sh <platform> <arch> && (cd sdks/godot/addons/fractal_native && scons platform=<platform> arch=<arch> target=template_release)"
        echo "    or just FRACTAL_BUILD_NATIVE=1 bin/ci, which does this for the current platform."
      else
        echo "WARN (Rule A, binary staleness, $platform_key): native source changed since addons/fractal_native/bin/$platform_key/ was last committed (not the host platform, not fatal):"
        echo "$rebuild_needed_output" | sed 's/^/    /'
        echo "  Remediation (optional, whenever someone is on $platform_key or dispatches the matrix): bin/dispatch_matrix, or build locally on $platform_key and sdks/godot/ci/fetch_native_artifacts.sh."
      fi
    fi
  done

  if [ "$base" = "$head" ]; then
    [ "$failed" -eq 0 ] && echo "fractal_freshness_check: OK (base == head, only Rule A applies)"
    return "$failed"
  fi

  local base_version
  base_version="$(fractal_version_at_ref "$base")"

  if [ -z "$base_version" ]; then
    echo "fractal_freshness_check: bootstrap mode, VERSION absent at base ($base), skipping version-bump rules (B1-B4)"
    [ "$failed" -eq 0 ] && echo "fractal_freshness_check: OK"
    return "$failed"
  fi

  local head_version
  head_version="$(fractal_version_at_ref "$head")"
  if [ -z "$head_version" ]; then
    failed=1
    echo "FAIL: sdks/godot/VERSION missing at head ($head)"
    return "$failed"
  fi

  local version_changed=false
  [ "$base_version" != "$head_version" ] && version_changed=true

  local diff_files
  diff_files="$(git diff --name-only "$base..$head" 2>/dev/null || true)"

  local shipped_changed
  shipped_changed="$(echo "$diff_files" | grep -E "$FRACTAL_SDK_SHIPPED_PATHS_REGEX" 2>/dev/null | grep -Ev "$FRACTAL_SDK_EXCLUDE_PATHS_REGEX" || true)"

  # Rule B1
  if [ -n "$shipped_changed" ] && [ "$version_changed" = false ]; then
    failed=1
    echo "FAIL (Rule B1, version bump required): shipped SDK source changed but sdks/godot/VERSION did not:"
    echo "$shipped_changed" | sed 's/^/    /'
    echo "  Remediation: run sdks/godot/ci/bump_version.sh patch|minor|major"
  fi

  # Rule B2
  if [ "$version_changed" = true ] && ! fractal_version_increment_ok "$base_version" "$head_version"; then
    failed=1
    echo "FAIL (Rule B2, increment sanity): VERSION $base_version -> $head_version is not a single semver step. Allowed next versions:"
    fractal_next_versions "$base_version" | sed 's/^/    /'
  fi

  local native_source_changed
  native_source_changed="$(echo "$diff_files" | grep -E "$FRACTAL_NATIVE_PATHS_REGEX" 2>/dev/null || true)"

  # Rule B3
  if [ -n "$native_source_changed" ]; then
    if [ "$version_changed" = false ]; then
      failed=1
      echo "FAIL (Rule B3, native bump required): native source changed but sdks/godot/VERSION did not:"
      echo "$native_source_changed" | sed 's/^/    /'
      echo "  Remediation: run sdks/godot/ci/bump_version.sh (native changes are shipped source too), then rebuild and sdks/godot/ci/fetch_native_artifacts.sh (or a local build for your platform)"
    else
      for platform_key in "${FRACTAL_NATIVE_PLATFORM_KEYS[@]}"; do
        local base_nbv head_nbv
        base_nbv="$(fractal_native_binary_version_at_ref "$base" "$platform_key")"
        head_nbv="$(fractal_native_binary_version_at_ref "$head" "$platform_key")"

        local reason=""
        if [ "$base_nbv" = "$head_nbv" ]; then
          reason="native source changed but $platform_key's NATIVE_BINARY_VERSIONS entry did not change ($head_nbv)"
        elif [ "$head_nbv" != "$head_version" ]; then
          reason="$platform_key's NATIVE_BINARY_VERSIONS entry ($head_nbv) != VERSION ($head_version)"
        fi

        if [ -n "$reason" ]; then
          if [ "$platform_key" = "$host_platform_key" ]; then
            failed=1
            echo "FAIL (Rule B3, native bump required, $platform_key): $reason"
            echo "  Remediation: rebuild the native binaries for $platform_key and run sdks/godot/ci/fetch_native_artifacts.sh (or a local build) to set NATIVE_BINARY_VERSIONS[\"$platform_key\"] := VERSION"
          else
            echo "WARN (Rule B3, native bump required, $platform_key): $reason (not the host platform, not fatal)"
          fi
        fi
      done
    fi
  fi

  # Rule B4, unexplained binaries, evaluated per platform, always fatal
  # regardless of host platform: this is a hygiene check (why did this
  # commit touch a binary at all), independent of the cross-platform matrix.
  if [ -z "$native_source_changed" ]; then
    for platform_key in "${FRACTAL_NATIVE_PLATFORM_KEYS[@]}"; do
      local bin_changed
      bin_changed="$(echo "$diff_files" | grep -F "sdks/godot/addons/fractal_native/bin/$platform_key/" 2>/dev/null || true)"
      [ -z "$bin_changed" ] && continue

      if fractal_native_rebuild_needed "$base" "$platform_key" > /dev/null; then
        local head_nbv
        head_nbv="$(fractal_native_binary_version_at_ref "$head" "$platform_key")"
        if [ "$head_nbv" != "$head_version" ]; then
          failed=1
          echo "FAIL (Rule B4, unexplained binaries, $platform_key): catch-up rebuild of already-stale binaries, but NATIVE_BINARY_VERSIONS entry ($head_nbv) != VERSION ($head_version)"
        fi
      else
        failed=1
        echo "FAIL (Rule B4, unexplained binaries, $platform_key): addons/fractal_native/bin/$platform_key/ changed without a matching native source change:"
        echo "$bin_changed" | sed 's/^/    /'
      fi
    done
  fi

  [ "$failed" -eq 0 ] && echo "fractal_freshness_check: OK (VERSION=$head_version, host=$host_platform_key)"
  return "$failed"
}
