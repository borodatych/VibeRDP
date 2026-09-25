#!/usr/bin/env bash
# Builds the local test peers of the core and the client: the sample RDP server of FreeRDP, which replays a RemoteFX
# recording, answers input and takes Kerberos logons, and a Kerberos KDC for those logons
# Test tools only, for this Mac's architecture; they never ship and never touch the submodule
# Needs the OpenSSL and the Kerberos sources that build-freerdp.sh stages; how to run it: docs/manuals/devSetup.md
#
# Environment: the same as build-freerdp.sh

# shellcheck source-path=SCRIPTDIR
set -euo pipefail

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

FREERDP_SRC="$REPO_ROOT/core/third_party/FreeRDP"
PATCHES="$SCRIPT_DIR/test-server"
OUT="$CACHE_DIR/test-server"
HOST_ARCH=$(uname -m)
OPENSSL_ROOT="$CACHE_DIR/stage/openssl-$HOST_ARCH$RUNTIME_PREFIX"
KRB5_STAGE="$CACHE_DIR/stage/krb5-$HOST_ARCH"
KRB5_ROOT="$KRB5_STAGE$RUNTIME_PREFIX"
KRB5_SRC="$CACHE_DIR/src/krb5-$KRB5_VERSION"
# The KDC, its database tools and their libraries: a shared build of the same release, installed where it is built
KDC="$OUT/kdc"
CERTIFICATE_DAYS=365

# The sources are copied, so the patches never reach the submodule
prepare_sources() {
    local patch

    log "Copying FreeRDP sources to $OUT/src"
    rm -rf "$OUT/src"
    mkdir -p "$OUT"
    rsync -a --exclude .git "$FREERDP_SRC/" "$OUT/src/"
    for patch in "$PATCHES"/*.patch; do
        patch -s -p1 -d "$OUT/src" <"$patch" || die "$(basename "$patch") no longer applies to the submodule"
    done
}

build_server() {
    log "Building the sample server ($HOST_ARCH)"
    # pkg-config sees only the staged Kerberos, as in build-freerdp.sh
    PKG_CONFIG_LIBDIR="$KRB5_ROOT/lib/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$KRB5_STAGE" \
        "$CMAKE" --fresh -G "$GENERATOR" -S "$OUT/src" -B "$OUT/build" \
        -DCMAKE_C_FLAGS="-Werror=unguarded-availability-new" \
        -DWINPR_HAVE_PIPE2=OFF \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
        -DCMAKE_OSX_ARCHITECTURES="$HOST_ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DCMAKE_IGNORE_PREFIX_PATH="$HOST_PREFIXES" \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
        -DOPENSSL_ROOT_DIR="$OPENSSL_ROOT" \
        -DOPENSSL_USE_STATIC_LIBS=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DWITH_CLIENT=OFF \
        -DWITH_SERVER=ON \
        -DWITH_SAMPLE=ON \
        -DWITH_SHADOW=OFF \
        -DWITH_PROXY=OFF \
        -DWITH_PLATFORM_SERVER=OFF \
        -DWITH_MANPAGES=OFF \
        -DWITH_WINPR_TOOLS=OFF \
        -DWITH_CCACHE=OFF \
        -DWITH_CLANG_FORMAT=OFF \
        -DWITH_FFMPEG=OFF \
        -DWITH_SWSCALE=OFF \
        -DWITH_OPUS=OFF \
        -DWITH_MACAUDIO=OFF \
        -DWITH_PCSC=OFF \
        -DWITH_PKCS11=OFF \
        -DWITH_SMARTCARD_EMULATE=OFF \
        -DWITH_FUSE=OFF \
        -DWITH_URIPARSER=OFF \
        -DWITH_JSON_DISABLED=ON \
        -DWITH_AAD=OFF \
        -DWITH_KRB5=ON \
        -DKRB5_ROOT_FLAVOUR=MIT \
        -DPKG_CONFIG_ARGN=--static \
        -DCHANNEL_URBDRC=OFF >/dev/null
    "$CMAKE" --build "$OUT/build" --parallel "$JOBS" --target sfreerdp-server
}

# The KDC of the Kerberos test realm; build-core.sh makes the realm per run
# A build of the release takes minutes, so it stays until build.env names another
build_kdc() {
    local build_dir="$OUT/kdc-build"
    local stamp="$KDC/.stamp"

    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$KRB5_VERSION" ]; then
        log "Test KDC: MIT Kerberos $KRB5_VERSION ($HOST_ARCH) is up to date"
        return 0
    fi

    log "Building the test KDC: MIT Kerberos $KRB5_VERSION ($HOST_ARCH)"
    rm -rf "$build_dir" "$KDC"
    mkdir -p "$build_dir"
    (
        cd "$build_dir"
        "$KRB5_SRC/src/configure" --prefix="$KDC" --disable-nls --disable-pkinit --with-krb5-config=no \
            --with-crypto-impl=builtin --with-tls-impl=no --without-keyutils --without-libedit --without-lmdb \
            --without-ldap >/dev/null
        make -j"$JOBS" >/dev/null
        make install >/dev/null
    )
    rm -rf "$build_dir"
    echo "$KRB5_VERSION" >"$stamp"
}

# A throwaway key and certificate for the TLS of the test peer: made per build, never committed
make_certificate() {
    log "Making the test certificate"
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -subj "/CN=localhost" -days "$CERTIFICATE_DAYS" \
        -keyout "$OUT/server.key" -out "$OUT/server.crt" 2>/dev/null
}

main() {
    local server="$OUT/build/server/Sample/sfreerdp-server"

    command -v rsync >/dev/null || die "rsync not found"
    command -v patch >/dev/null || die "patch not found"
    [ -d "$OPENSSL_ROOT" ] || die "no OpenSSL in $OPENSSL_ROOT: run build-freerdp.sh first"
    [ -d "$KRB5_ROOT" ] || die "no Kerberos in $KRB5_ROOT: run build-freerdp.sh first"
    [ -f "$KRB5_SRC/src/configure" ] || die "no Kerberos sources in $KRB5_SRC: run build-freerdp.sh first"

    prepare_sources
    build_server
    build_kdc
    make_certificate
    [ -x "$server" ] || die "the sample server was not built"
    [ -x "$KDC/sbin/krb5kdc" ] || die "the test KDC was not built"
    log "Done: $OUT"
}

main "$@"
