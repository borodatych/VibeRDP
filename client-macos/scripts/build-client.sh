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
# The local RDP peer of core/scripts/build-test-server.sh; without it the live tests skip themselves
TEST_SERVER="$CACHE_DIR/test-server"
TEST_SERVER_SAMPLE="$TEST_SERVER/build/server/Sample"
# With --local-only the port only names the socket file: the server opens no TCP port
# One server replays a recording, the other answers the mouse: the sample server does either, not both
TEST_SERVER_REPLAY_PORT=3389
TEST_SERVER_INTERACTIVE_PORT=3390
# The server opens its socket within milliseconds; the margin is for a machine busy with something else
TEST_SERVER_START_TIMEOUT=10
# Set while test servers run: their processes and the folder of their sockets
TEST_SERVER_PIDS=""
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
    command -v python3 >/dev/null || die "python3 not found: the check of the interface strings needs it"
    [ -f "$FRAMEWORK/Modules/module.modulemap" ] || die "no core framework in $FRAMEWORK: run core/scripts/build-core.sh first"
}

# The interface strings: nothing in the base language outside the catalog, no dead key, seeded languages complete
check_localization() {
    log "Checking the interface strings"
    python3 "$CLIENT_SRC/scripts/check-localization.py" "$CLIENT_SRC"
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

# The live tests connect to sample servers that this script starts, not the app under test:
# macOS asks the user whether an app may read a removable volume, and the cache may live on one,
# and it asks again after every build, since the ad-hoc signature of the app changes with it
# The script has the access of its terminal already, and a test killed for hanging leaves no server behind
start_test_servers() {
    local arch=$1

    TEST_SERVER_RUN_DIR=$(mktemp -d)
    launch_test_server "$arch" replay "$TEST_SERVER_REPLAY_PORT" \
        "--pcap=$TEST_SERVER/src/server/Sample/rfx_test.pcap"
    launch_test_server "$arch" interactive "$TEST_SERVER_INTERACTIVE_PORT"
    # xcodebuild hands TEST_RUNNER_ variables to the app under test without the prefix
    TEST_RUNNER_VIBERDP_TEST_SERVER_SOCKET=$(test_server_socket "$TEST_SERVER_REPLAY_PORT")
    TEST_RUNNER_VIBERDP_INTERACTIVE_SERVER_SOCKET=$(test_server_socket "$TEST_SERVER_INTERACTIVE_PORT")
    export TEST_RUNNER_VIBERDP_TEST_SERVER_SOCKET TEST_RUNNER_VIBERDP_INTERACTIVE_SERVER_SOCKET
}

# The sample server names its socket after the port, in the folder that TMPDIR gives it
test_server_socket() {
    printf '%s/tfreerdp-server.%s' "$TEST_SERVER_RUN_DIR" "$1"
}

# One sample server on its own socket; the arguments after the port choose what it does
launch_test_server() {
    local arch=$1 mode=$2 port=$3
    shift 3
    local server_log="$RESULTS/test-server-$mode-$arch.log"
    local socket pid polls=0

    socket=$(test_server_socket "$port")

    # The server makes its socket in TMPDIR: a folder of its own gives the socket a known and free path
    # It reads its test icon from the working folder, and the build puts the icon next to the binary
    (cd "$TEST_SERVER_SAMPLE" && TMPDIR="$TEST_SERVER_RUN_DIR" exec ./sfreerdp-server "--port=$port" --local-only \
        "--cert=$TEST_SERVER/server.crt" "--key=$TEST_SERVER/server.key" "$@") >"$server_log" 2>&1 &
    pid=$!
    TEST_SERVER_PIDS="$TEST_SERVER_PIDS $pid"
    until [ -S "$socket" ]; do
        kill -0 "$pid" 2>/dev/null || die "the $mode test server exited, see $server_log"
        [ "$polls" -lt "$((TEST_SERVER_START_TIMEOUT * 10))" ] ||
            die "the $mode test server opened no socket in $TEST_SERVER_START_TIMEOUT s, see $server_log"
        sleep 0.1
        polls=$((polls + 1))
    done
}

# Runs on exit too, so a failed run leaves no server and no socket folder behind
stop_test_servers() {
    local pid

    unset TEST_RUNNER_VIBERDP_TEST_SERVER_SOCKET TEST_RUNNER_VIBERDP_INTERACTIVE_SERVER_SOCKET
    for pid in $TEST_SERVER_PIDS; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    TEST_SERVER_PIDS=""
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
        start_test_servers "$arch"
    fi
    run_bounded "$FOREIGN_RUN_TIMEOUT" xcodebuild -quiet -project "$PROJECT" -scheme "$SCHEME" \
        -derivedDataPath "$DERIVED_DATA" -destination "platform=macOS,arch=$arch" -resultBundlePath "$results" \
        -test-timeouts-enabled YES -default-test-execution-time-allowance "$TEST_TIME_ALLOWANCE" \
        -maximum-test-execution-time-allowance "$TEST_TIME_ALLOWANCE" test
    stop_test_servers
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

    trap stop_test_servers EXIT
    check_prerequisites
    check_localization
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
