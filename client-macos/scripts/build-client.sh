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
# The local RDP peer of core/scripts/build-test-server.sh; without it the live test skips itself
TEST_SERVER="$CACHE_DIR/test-server"
TEST_SERVER_SAMPLE="$TEST_SERVER/build/server/Sample"
# With --local-only the port only names the socket file: the server opens no TCP port
TEST_SERVER_PORT=3389
# The server opens its socket within milliseconds; the margin is for a machine busy with something else
TEST_SERVER_START_TIMEOUT=10
# Set while a test server runs: its process and the folder of its socket
TEST_SERVER_PID=""
TEST_SERVER_RUN_DIR=""
# A test that hangs fails alone after this many seconds, the others still run, and the result bundle gets finished
# XCTest counts the allowance in whole minutes
TEST_TIME_ALLOWANCE=60
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

# The live test connects to a sample server that this script starts, not the app under test:
# macOS asks the user whether an app may read a removable volume, and the cache may live on one,
# and it asks again after every build, since the ad-hoc signature of the app changes with it
# The script has the access of its terminal already, and a test killed for hanging leaves no server behind
start_test_server() {
    local arch=$1
    local server_log="$RESULTS/test-server-$arch.log"
    local socket polls=0

    TEST_SERVER_RUN_DIR=$(mktemp -d)
    socket="$TEST_SERVER_RUN_DIR/tfreerdp-server.$TEST_SERVER_PORT"
    # The server makes its socket in TMPDIR: a folder of its own gives the socket a known and free path
    # It reads its test icon from the working folder, and the build puts the icon next to the binary
    (cd "$TEST_SERVER_SAMPLE" && TMPDIR="$TEST_SERVER_RUN_DIR" exec ./sfreerdp-server \
        "--port=$TEST_SERVER_PORT" --local-only "--pcap=$TEST_SERVER/src/server/Sample/rfx_test.pcap" \
        "--cert=$TEST_SERVER/server.crt" "--key=$TEST_SERVER/server.key") >"$server_log" 2>&1 &
    TEST_SERVER_PID=$!
    until [ -S "$socket" ]; do
        kill -0 "$TEST_SERVER_PID" 2>/dev/null || die "the test server exited, see $server_log"
        [ "$polls" -lt "$((TEST_SERVER_START_TIMEOUT * 10))" ] ||
            die "the test server opened no socket in $TEST_SERVER_START_TIMEOUT s, see $server_log"
        sleep 0.1
        polls=$((polls + 1))
    done
    # xcodebuild hands TEST_RUNNER_ variables to the app under test without the prefix
    export TEST_RUNNER_VIBERDP_TEST_SERVER_SOCKET="$socket"
}

# Runs on exit too, so a failed run leaves no server and no socket folder behind
stop_test_server() {
    unset TEST_RUNNER_VIBERDP_TEST_SERVER_SOCKET
    if [ -n "$TEST_SERVER_PID" ]; then
        kill "$TEST_SERVER_PID" 2>/dev/null || true
        wait "$TEST_SERVER_PID" 2>/dev/null || true
        TEST_SERVER_PID=""
    fi
    if [ -n "$TEST_SERVER_RUN_DIR" ]; then
        rm -rf "$TEST_SERVER_RUN_DIR"
        TEST_SERVER_RUN_DIR=""
    fi
}

# The tests run inside the launched app, one architecture at a time
# The count comes from the result bundle: a run that finds no tests must fail, not pass quietly
test_app() {
    local arch=$1
    local results="$RESULTS/test-$arch.xcresult"
    local summary total passed skipped

    if ! can_execute "$arch"; then
        log "This Mac cannot execute $arch code: the $arch tests are not run"
        return 0
    fi

    log "Testing the app ($arch)"
    mkdir -p "$RESULTS"
    rm -rf "$results"
    if [ -x "$TEST_SERVER_SAMPLE/sfreerdp-server" ]; then
        start_test_server "$arch"
    fi
    run_bounded "$FOREIGN_RUN_TIMEOUT" xcodebuild -quiet -project "$PROJECT" -scheme "$SCHEME" \
        -derivedDataPath "$DERIVED_DATA" -destination "platform=macOS,arch=$arch" -resultBundlePath "$results" \
        -test-timeouts-enabled YES -default-test-execution-time-allowance "$TEST_TIME_ALLOWANCE" \
        -maximum-test-execution-time-allowance "$TEST_TIME_ALLOWANCE" test
    stop_test_server
    summary=$(xcrun xcresulttool get test-results summary --path "$results")
    total=$(plutil -extract totalTestCount raw -o - - <<<"$summary")
    passed=$(plutil -extract passedTests raw -o - - <<<"$summary")
    skipped=$(plutil -extract skippedTests raw -o - - <<<"$summary")
    [ "$total" -gt 0 ] || die "no tests ran on $arch"
    [ "$((passed + skipped))" = "$total" ] || die "$passed of $total tests passed on $arch, $skipped skipped"
    # A test skips itself only with a stated reason, such as a machine without a GPU; the log names the count
    log "Passed $passed of $total tests ($arch), skipped $skipped"
}

main() {
    local arch

    trap stop_test_server EXIT
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
