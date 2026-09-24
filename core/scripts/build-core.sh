#!/usr/bin/env bash
# Builds and tests VibeRDPCore for every architecture of build.env, then merges the slices into one universal framework
# Needs the prefix that build-freerdp.sh produces; how to run it: docs/manuals/devSetup.md
#
# Environment: the same as build-freerdp.sh

# shellcheck source-path=SCRIPTDIR
set -euo pipefail

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CORE_SRC="$REPO_ROOT/core"
CORE_OUT="$CACHE_DIR/core"
FRAMEWORK_NAME=VibeRDPCore.framework
HOST_ARCH=$(uname -m)

# Configures and builds one variant of the core; extra arguments go to CMake after the common ones
build_variant() {
    local name=$1 arch=$2
    shift 2

    log "VibeRDPCore: building $name"
    "$CMAKE" --fresh -G "$GENERATOR" -S "$CORE_SRC" -B "$BUILD/core-$name" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
        -DVRC_VERSION="$VERSION" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DCMAKE_PREFIX_PATH="$PREFIX/universal" \
        -DCMAKE_IGNORE_PREFIX_PATH="$HOST_PREFIXES" \
        "$@" >/dev/null
    "$CMAKE" --build "$BUILD/core-$name" --parallel "$JOBS"
}

test_variant() {
    local name=$1 arch=$2

    if can_execute "$arch"; then
        log "VibeRDPCore: testing $name"
        run_bounded "$FOREIGN_RUN_TIMEOUT" "$CTEST" --test-dir "$BUILD/core-$name" --output-on-failure --parallel "$JOBS"
    else
        log "This Mac cannot execute $arch code: the $arch tests are built but not run"
    fi
}

# The framework exports the VRC API and nothing else: an engine symbol in the export table is a linker setup error
check_exports() {
    local file=$1
    local arch foreign

    for arch in $ARCHS; do
        foreign=$(nm -arch "$arch" -gU "$file" | awk '{ print $3 }' | grep -v '^_VRC' || true)
        [ -z "$foreign" ] || die "$file ($arch) exports symbols beyond the VRC API: $foreign"
    done
}

# The bundle of the first architecture carries the headers, the module map and Info.plist; lipo merges the binaries
merge_framework() {
    local framework="$CORE_OUT/$FRAMEWORK_NAME"
    local binary="$framework/Versions/A/VibeRDPCore"
    local base=${ARCHS%% *}
    local inputs=() arch

    log "Merging $ARCHS into $framework"
    for arch in $ARCHS; do
        inputs+=("$BUILD/core-$arch/$FRAMEWORK_NAME/Versions/A/VibeRDPCore")
    done
    rm -rf "$CORE_OUT"
    mkdir -p "$CORE_OUT"
    ditto "$BUILD/core-$base/$FRAMEWORK_NAME" "$framework"
    lipo -create "${inputs[@]}" -output "$binary"
    check_binary "$binary"
    check_exports "$binary"
    [ -f "$framework/Modules/module.modulemap" ] || die "$framework has no module map: Swift cannot import it"
}

main() {
    local arch

    [ -d "$PREFIX/universal" ] || die "no FreeRDP prefix in $PREFIX/universal: run build-freerdp.sh first"

    build_variant "$HOST_ARCH" "$HOST_ARCH"
    test_variant "$HOST_ARCH" "$HOST_ARCH"
    build_variant sanitize "$HOST_ARCH" -DCMAKE_BUILD_TYPE=Debug -DVRC_SANITIZE=ON
    test_variant sanitize "$HOST_ARCH"

    for arch in $ARCHS; do
        [ "$arch" = "$HOST_ARCH" ] || build_variant "$arch" "$arch"
    done
    merge_framework

    # The other architectures run through Rosetta: their tests go last, so a stuck translation withholds no result
    for arch in $ARCHS; do
        [ "$arch" = "$HOST_ARCH" ] || test_variant "$arch" "$arch"
    done
    log "Done: $CORE_OUT/$FRAMEWORK_NAME"
}

main "$@"
