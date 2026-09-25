#!/usr/bin/env bash
# Builds the sample RDP server of FreeRDP as a local test peer: the client tests replay a RemoteFX recording from it
# A test tool only, for this Mac's architecture; it never ships and never touches the submodule
# Needs the OpenSSL that build-freerdp.sh stages; how to run it: docs/manuals/devSetup.md
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
    local no_pkgconfig="$BUILD/no-pkgconfig"

    log "Building the sample server ($HOST_ARCH)"
    mkdir -p "$no_pkgconfig"
    PKG_CONFIG_LIBDIR="$no_pkgconfig" "$CMAKE" --fresh -G "$GENERATOR" -S "$OUT/src" -B "$OUT/build" \
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
        -DWITH_KRB5=OFF \
        -DCHANNEL_URBDRC=OFF >/dev/null
    "$CMAKE" --build "$OUT/build" --parallel "$JOBS" --target sfreerdp-server
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

    prepare_sources
    build_server
    make_certificate
    [ -x "$server" ] || die "the sample server was not built"
    log "Done: $OUT"
}

main "$@"
