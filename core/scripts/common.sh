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
# Xcode 26.6 links _dispatch_once_f into the app weakly, and Xcode 27 strongly:
# libdispatch has had it since macOS 10.6, so the reference resolves on every target
# The Mach RPC stubs that mig generates for the KCM ticket cache of Kerberos call _voucher_mach_msg_set
# only after checking that it is there; in a static library the line of nm ends with the name
# The stack allocation of the standard library of Swift 6.2, as Xcode 26.6 inlines it, asks
# _swift_stdlib_isStackAllocationSafe only under #available(macOS 12.3), where the runtime of Swift 5.6 brought it;
# Swift 6.3 no longer calls it, so only some toolchains leave the reference
# shellcheck disable=SC2016 # the dollar sign belongs to the symbol names, nothing expands here
TOOLCHAIN_WEAK_SYMBOLS=' __swift_FORCE_LOAD_\$_| ____chkstk_darwin | _\$s| __availability_version_check | _dispatch_once_f | _voucher_mach_msg_set( |$)| _swift_stdlib_isStackAllocationSafe '

# The object files of a build that reference each weak symbol of a binary beyond the toolchain's own:
# the symbol names the runtime, not the source, and the compiler of one Xcode may leave it where another does not
# objects is a folder of Objects-normal/<arch> folders; nothing is printed when every symbol is expected
report_weak_sources() {
    local file=$1 objects=$2
    local arch symbol object

    for arch in $ARCHS; do
        [ -d "$objects/$arch" ] || continue
        # Most builds have no such symbol: grep then finds nothing, which under pipefail must not end the script
        { nm -arch "$arch" -m "$file" 2>/dev/null | grep '(undefined) weak external' || true; } |
            { grep -vE "$TOOLCHAIN_WEAK_SYMBOLS" || true; } | awk '{ if ($(NF - 1) == "(from") print $(NF - 2); else print $NF }' |
            while read -r symbol; do
                for object in "$objects/$arch"/*.o; do
                    if nm -u "$object" 2>/dev/null | grep -qxF "$symbol"; then
                        echo "$symbol ($arch) comes from $(basename "$object"), in:" >&2
                        # The object file may hold code of another source: batch mode puts shared specializations
                        # in the first file of a batch, so the functions that make the reference are named too
                        { objdump -d -r "$object" 2>/dev/null |
                            awk -v symbol="$symbol" '/^[0-9a-f]+ <.*>:$/ { fn = $2 } index($0, symbol) { print fn }' ||
                            true; } | sort -u | tr -d '<>:' | xcrun swift-demangle | sed 's/^/    /' >&2
                    fi
                done
            done
    done
}

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
