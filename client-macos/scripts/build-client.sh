#!/usr/bin/env bash
# Generates the Xcode project of the macOS client, builds the universal app, checks the bundle and runs the tests
# Needs the framework that core/scripts/build-core.sh produces; how to run it: docs/manuals/devSetup.md
#
# Environment: the same as core/scripts/build-freerdp.sh, plus
#   XCODEGEN  xcodegen executable (default: xcodegen from PATH)

# shellcheck source-path=SCRIPTDIR
set -euo pipefail

# shellcheck source=../../core/scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/scripts/common.sh"

XCODEGEN=${XCODEGEN:-xcodegen}
CLIENT_SRC="$REPO_ROOT/client-macos"
PROJECT="$CLIENT_SRC/VibeRDP.xcodeproj"
SCHEME=VibeRDP
FRAMEWORK="$CACHE_DIR/core/VibeRDPCore.framework"
DERIVED_DATA="$CACHE_DIR/client/DerivedData"
RESULTS="$CACHE_DIR/client/results"
APP="$DERIVED_DATA/Build/Products/Release/VibeRDP.app"
HOST_ARCH=$(uname -m)

check_prerequisites() {
    command -v "$XCODEGEN" >/dev/null || die "xcodegen not found, see docs/manuals/devSetup.md"
    [ "$("$XCODEGEN" --version)" = "Version: $XCODEGEN_VERSION" ] ||
        die "xcodegen $XCODEGEN_VERSION is required, found: $("$XCODEGEN" --version)"
    command -v xcodebuild >/dev/null || die "xcodebuild not found, see docs/manuals/devSetup.md"
    [ -f "$FRAMEWORK/Modules/module.modulemap" ] || die "no core framework in $FRAMEWORK: run core/scripts/build-core.sh first"
}

# project.yml takes the build parameters and the framework path from the environment
generate_project() {
    log "Generating $PROJECT"
    VERSION="$VERSION" \
        MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        ARCHS="$ARCHS" \
        VIBERDP_CORE_FRAMEWORK="$FRAMEWORK" \
        "$XCODEGEN" generate --quiet --spec "$CLIENT_SRC/project.yml"
}

build_app() {
    log "Building $APP"
    xcodebuild -quiet -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -derivedDataPath "$DERIVED_DATA" -destination "generic/platform=macOS" ONLY_ACTIVE_ARCH=NO build
}

check_app() {
    local binary="$APP/Contents/MacOS/VibeRDP"
    local embedded="$APP/Contents/Frameworks/VibeRDPCore.framework/Versions/A/VibeRDPCore"

    log "Verifying slices, deployment target, the embedded core and the signature"
    check_binary "$binary"
    check_binary "$embedded"
    # The output is read whole first: grep -q stops at the first match, and under pipefail the writer's SIGPIPE fails
    local libraries commands
    libraries=$(otool -L "$binary")
    commands=$(otool -l "$binary")
    grep -qF "@rpath/VibeRDPCore.framework/" <<<"$libraries" || die "$binary does not link the core framework"
    grep -qF "@executable_path/../Frameworks" <<<"$commands" || die "$binary cannot find the embedded frameworks"
    # --deep checks the nested framework too: an embedded copy left unsigned fails here
    codesign --verify --deep --strict "$APP" || die "$APP fails signature verification"
}

# The tests run inside the launched app, one architecture at a time
# The count comes from the result bundle: a run that finds no tests must fail, not pass quietly
test_app() {
    local arch=$1
    local results="$RESULTS/test-$arch.xcresult"
    local summary total passed

    if ! can_execute "$arch"; then
        log "This Mac cannot execute $arch code: the $arch tests are not run"
        return 0
    fi

    log "Testing the app ($arch)"
    rm -rf "$results"
    run_bounded "$FOREIGN_RUN_TIMEOUT" xcodebuild -quiet -project "$PROJECT" -scheme "$SCHEME" \
        -derivedDataPath "$DERIVED_DATA" -destination "platform=macOS,arch=$arch" -resultBundlePath "$results" test
    summary=$(xcrun xcresulttool get test-results summary --path "$results")
    total=$(plutil -extract totalTestCount raw -o - - <<<"$summary")
    passed=$(plutil -extract passedTests raw -o - - <<<"$summary")
    [ "$total" -gt 0 ] || die "no tests ran on $arch"
    [ "$passed" = "$total" ] || die "$passed of $total tests passed on $arch"
    log "Passed $passed of $total tests ($arch)"
}

main() {
    local arch

    check_prerequisites
    generate_project
    build_app
    check_app
    test_app "$HOST_ARCH"

    # The other architectures run through Rosetta: their tests go last, so a stuck translation withholds no result
    for arch in $ARCHS; do
        [ "$arch" = "$HOST_ARCH" ] || test_app "$arch"
    done
    log "Done: $APP"
}

main "$@"
