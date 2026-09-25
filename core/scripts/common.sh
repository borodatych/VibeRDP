# Shared setup of the core build scripts: sourced, never run
# shellcheck shell=bash
# shellcheck disable=SC2034 # the variables serve the scripts that source this file
# shellcheck source-path=SCRIPTDIR

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# shellcheck source=../../build.env
. "$REPO_ROOT/build.env"

CACHE_DIR=${VIBERDP_CACHE_DIR:-$REPO_ROOT/core/build}
CMAKE=${CMAKE:-cmake}
CTEST=$(dirname "$(command -v "$CMAKE")")/ctest
JOBS=$(sysctl -n hw.ncpu)

BUILD="$CACHE_DIR/build"
PREFIX="$CACHE_DIR/prefix"

# Host package managers stay invisible to CMake: their libraries are built for a single architecture
HOST_PREFIXES="/opt/homebrew;/usr/local;/opt/local"

# Longest a check may run: code of the other architecture goes through Rosetta, and a stuck translation never returns
FOREIGN_RUN_TIMEOUT=300

GENERATOR="Unix Makefiles"
if command -v ninja >/dev/null; then
    GENERATOR=Ninja
fi

log() { printf '\n==> %s\n' "$*"; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

can_execute() {
    arch -"$1" /usr/bin/true 2>/dev/null
}

# Runs a command and fails once it outlives the timeout instead of hanging the build
run_bounded() {
    local seconds=$1
    shift
    local pid waited=0

    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$seconds" ]; then
            kill -9 "$pid" 2>/dev/null || true
            die "$(basename "$1") did not finish in $seconds s; if it runs through Rosetta, check that Rosetta still translates"
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
}

# Weak references the toolchain emits by design, each with a fallback, rather than calls to a newer API:
# the __swift_FORCE_LOAD_$_ markers of the Swift overlays are autolinking hooks,
# and ___chkstk_darwin, the stack probe of x86_64 code, falls back to a private copy linked from compiler-rt
# Swift symbols, mangled as _$s, are weak only inside an #available branch: Swift refuses an unguarded call
# to a newer API, and SDK code inlined into the app, as SwiftUI's tag(_:), carries its own check and fallback
# __availability_version_check is what those checks call, and compiler-rt reads the system version without it
# shellcheck disable=SC2016 # the dollar sign belongs to the symbol names, nothing expands here
TOOLCHAIN_WEAK_SYMBOLS=' __swift_FORCE_LOAD_\$_| ____chkstk_darwin | _\$s| __availability_version_check '

# Every slice is present, records the deployment target and uses no API newer than it
# A weak reference to such an API resolves to NULL on an older macOS and crashes there
check_binary() {
    local file=$1
    local arch minos weak

    for arch in $ARCHS; do
        lipo "$file" -verify_arch "$arch" || die "$file lacks the $arch slice"
        minos=$(otool -arch "$arch" -l "$file" | awk '$1 == "minos" { print $2 }' | sort -u | tr '\n' ' ')
        [ "$minos" = "$MACOSX_DEPLOYMENT_TARGET " ] || die "$file ($arch) targets macOS '$minos'"
        weak=$(nm -arch "$arch" -m "$file" 2>/dev/null | grep '(undefined) weak external' |
            grep -vE "$TOOLCHAIN_WEAK_SYMBOLS" || true)
        [ -z "$weak" ] || die "$file ($arch) uses APIs newer than macOS $MACOSX_DEPLOYMENT_TARGET: $weak"
    done
}
