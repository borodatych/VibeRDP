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
# The Kerberos peer of build-test-server.sh: the KDC of a realm made per run, and a sample server that takes
# Kerberos logons through NLA and nothing else; without them the Kerberos logon tests skip themselves
TEST_SERVER="$CACHE_DIR/test-server"
TEST_KDC="$TEST_SERVER/kdc"
TEST_SERVER_SAMPLE="$TEST_SERVER/build/server/Sample"
# The logs of the peers stay after the run
PEER_LOGS="$CACHE_DIR/core-tests"
KERBEROS_REALM=VIBERDP.TEST
# Kerberos names the service after a host: the Kerberos server listens on TCP, on the loopback, under this name
KERBEROS_HOST=localhost
KERBEROS_USER=tester
# Each peer serves within a second; the margin is for a machine busy with something else
PEER_START_TIMEOUT=10
# Set while the peers run: their processes and the folder of the realm
PEER_PIDS=""
REALM_DIR=""

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

# A loopback port nothing listens on at the moment of asking
free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# Waits until a started peer listens on its TCP port; its log names the cause when it does not
await_listening() {
    local pid=$1 port=$2 what=$3 file=$4
    local polls=0

    until lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; do
        kill -0 "$pid" 2>/dev/null || die "the $what exited, see $file"
        [ "$polls" -lt "$((PEER_START_TIMEOUT * 10))" ] ||
            die "the $what did not start in $PEER_START_TIMEOUT s, see $file"
        sleep 0.1
        polls=$((polls + 1))
    done
}

# A Kerberos realm for this run in a temporary folder: the KDC and the Kerberos server on free loopback ports,
# and a user whose password is made here; the user needs preauthentication, as in Active Directory
# The tests learn the realm from the environment: the engine reads its configuration from KRB5_CONFIG
start_realm() {
    local kdc_log="$PEER_LOGS/kdc.log"
    local server_log="$PEER_LOGS/kerberos-server.log"
    local kdc_port rdp_port password pid

    log "Starting the Kerberos test realm"
    REALM_DIR=$(mktemp -d)
    rm -rf "$PEER_LOGS"
    mkdir -p "$PEER_LOGS"
    kdc_port=$(free_port)
    rdp_port=$(free_port)
    password=$(/usr/bin/openssl rand -hex 16)
    cat >"$REALM_DIR/krb5.conf" <<EOF
[libdefaults]
    default_realm = $KERBEROS_REALM
    dns_lookup_kdc = false
    dns_lookup_realm = false
    dns_uri_lookup = false
    dns_canonicalize_hostname = false
    rdns = false
[realms]
    $KERBEROS_REALM = {
        kdc = 127.0.0.1:$kdc_port
    }
[domain_realm]
    $KERBEROS_HOST = $KERBEROS_REALM
EOF
    cat >"$REALM_DIR/kdc.conf" <<EOF
[kdcdefaults]
    kdc_listen = 127.0.0.1:$kdc_port
    kdc_tcp_listen = 127.0.0.1:$kdc_port
[realms]
    $KERBEROS_REALM = {
        database_name = $REALM_DIR/principal
        key_stash_file = $REALM_DIR/stash
    }
[logging]
    kdc = FILE:$kdc_log
EOF
    (
        export KRB5_CONFIG="$REALM_DIR/krb5.conf" KRB5_KDC_PROFILE="$REALM_DIR/kdc.conf"
        "$TEST_KDC/sbin/kdb5_util" create -s -r "$KERBEROS_REALM" -P "$(/usr/bin/openssl rand -hex 16)"
        "$TEST_KDC/sbin/kadmin.local" -r "$KERBEROS_REALM" -q "addprinc +requires_preauth -pw $password $KERBEROS_USER"
        "$TEST_KDC/sbin/kadmin.local" -r "$KERBEROS_REALM" -q "addprinc -randkey TERMSRV/$KERBEROS_HOST"
        "$TEST_KDC/sbin/kadmin.local" -r "$KERBEROS_REALM" -q "ktadd -k $REALM_DIR/server.keytab TERMSRV/$KERBEROS_HOST"
    ) >"$PEER_LOGS/realm.log" 2>&1 || die "the Kerberos test realm was not made, see $PEER_LOGS/realm.log"

    KRB5_CONFIG="$REALM_DIR/krb5.conf" KRB5_KDC_PROFILE="$REALM_DIR/kdc.conf" "$TEST_KDC/sbin/krb5kdc" -n \
        >"$PEER_LOGS/kdc-console.log" 2>&1 &
    pid=$!
    PEER_PIDS="$PEER_PIDS $pid"
    await_listening "$pid" "$kdc_port" "test KDC" "$kdc_log"

    # The server reads its test icon from the working folder, and the build puts the icon next to the binary
    (cd "$TEST_SERVER_SAMPLE" && KRB5_CONFIG="$REALM_DIR/krb5.conf" exec ./sfreerdp-server \
        "--port=$rdp_port" "--kerberos-keytab=$REALM_DIR/server.keytab" \
        "--cert=$TEST_SERVER/server.crt" "--key=$TEST_SERVER/server.key") >"$server_log" 2>&1 &
    pid=$!
    PEER_PIDS="$PEER_PIDS $pid"
    await_listening "$pid" "$rdp_port" "Kerberos test server" "$server_log"

    export VIBERDP_KERBEROS_HOST=$KERBEROS_HOST VIBERDP_KERBEROS_PORT=$rdp_port \
        VIBERDP_KERBEROS_REALM=$KERBEROS_REALM VIBERDP_KERBEROS_USER=$KERBEROS_USER \
        VIBERDP_KERBEROS_PASSWORD=$password VIBERDP_KERBEROS_CONFIG="$REALM_DIR/krb5.conf"
}

# Runs on exit too, so a failed run leaves no peer and no realm behind
stop_realm() {
    local pid

    unset VIBERDP_KERBEROS_HOST VIBERDP_KERBEROS_PORT VIBERDP_KERBEROS_REALM VIBERDP_KERBEROS_USER \
        VIBERDP_KERBEROS_PASSWORD VIBERDP_KERBEROS_CONFIG
    for pid in $PEER_PIDS; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    PEER_PIDS=""
    if [ -n "$REALM_DIR" ]; then
        rm -rf "$REALM_DIR"
        REALM_DIR=""
    fi
}

main() {
    local arch

    trap stop_realm EXIT
    [ -d "$PREFIX/universal" ] || die "no FreeRDP prefix in $PREFIX/universal: run build-freerdp.sh first"
    if [ -x "$TEST_KDC/sbin/krb5kdc" ] && [ -x "$TEST_SERVER_SAMPLE/sfreerdp-server" ]; then
        command -v python3 >/dev/null || die "python3 not found: the Kerberos test realm needs it for free ports"
        start_realm
    else
        log "No Kerberos test peers in $TEST_SERVER: the Kerberos logon tests skip themselves"
    fi

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
