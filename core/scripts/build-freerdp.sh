#!/usr/bin/env bash
# Builds OpenSSL and FreeRDP as universal static libraries for the macOS client
# Every build parameter comes from build.env at the repository root
# How to run it and what it produces: docs/manuals/devSetup.md
#
# Environment:
#   VIBERDP_CACHE_DIR  downloads, build trees and install prefixes (default: core/build)
#   CMAKE              cmake executable (default: cmake from PATH)

# shellcheck source-path=SCRIPTDIR
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
FREERDP_SRC="$REPO_ROOT/core/third_party/FreeRDP"

# shellcheck source=../../build.env
. "$REPO_ROOT/build.env"

CACHE_DIR=${VIBERDP_CACHE_DIR:-$REPO_ROOT/core/build}
CMAKE=${CMAKE:-cmake}
JOBS=$(sysctl -n hw.ncpu)

DOWNLOADS="$CACHE_DIR/downloads"
SOURCES="$CACHE_DIR/src"
BUILD="$CACHE_DIR/build"
STAGE="$CACHE_DIR/stage"
PREFIX="$CACHE_DIR/prefix"
OPENSSL_SRC="$SOURCES/openssl-$OPENSSL_VERSION"

# Host package managers stay invisible to CMake: their libraries are built for a single architecture
HOST_PREFIXES="/opt/homebrew;/usr/local;/opt/local"

GENERATOR="Unix Makefiles"
if command -v ninja >/dev/null; then
    GENERATOR=Ninja
fi

log() { printf '\n==> %s\n' "$*"; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

is_enabled_channel() {
    case " $FREERDP_CHANNELS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Channel names are the directory names of the submodule: they match the NAME in each ChannelOptions.cmake
all_channels() {
    local options_file
    for options_file in "$FREERDP_SRC"/channels/*/ChannelOptions.cmake; do
        basename "$(dirname "$options_file")"
    done
}

# Mach-O files of a prefix: static archives and the channel objects that the CMake packages link directly
object_list() {
    (cd "$1" && find . -type f \( -name '*.a' -o -name '*.o' \) | sort)
}

check_prerequisites() {
    local tool channel
    for tool in "$CMAKE" perl make curl shasum tar lipo otool strings; do
        command -v "$tool" >/dev/null || die "$tool not found, see docs/manuals/devSetup.md"
    done
    [ -f "$FREERDP_SRC/CMakeLists.txt" ] || die "FreeRDP submodule is missing: git submodule update --init"
    for channel in $FREERDP_CHANNELS; do
        [ -f "$FREERDP_SRC/channels/$channel/ChannelOptions.cmake" ] || die "unknown FreeRDP channel: $channel"
    done
}

fetch_openssl() {
    local tarball="$DOWNLOADS/openssl-$OPENSSL_VERSION.tar.gz"
    local url="https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"

    mkdir -p "$DOWNLOADS" "$SOURCES"
    if [ ! -f "$tarball" ]; then
        log "Downloading OpenSSL $OPENSSL_VERSION"
        curl -fsSL -o "$tarball.part" "$url"
        mv "$tarball.part" "$tarball"
    fi
    echo "$OPENSSL_SHA256  $tarball" | shasum -a 256 -c - >/dev/null || die "checksum mismatch: $tarball"
    [ -f "$OPENSSL_SRC/Configure" ] || tar -xzf "$tarball" -C "$SOURCES"
}

build_openssl() {
    local arch=$1
    local build_dir="$BUILD/openssl-$arch"
    local stage_dir="$STAGE/openssl-$arch"
    local stamp="$stage_dir/.stamp"
    local signature="$OPENSSL_VERSION $MACOSX_DEPLOYMENT_TARGET $RUNTIME_PREFIX"

    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$signature" ]; then
        log "OpenSSL $OPENSSL_VERSION ($arch) is up to date"
        return 0
    fi

    log "Building OpenSSL $OPENSSL_VERSION ($arch)"
    rm -rf "$build_dir" "$stage_dir"
    mkdir -p "$build_dir"
    # no-dso: providers are linked in and nothing is loaded from disk at runtime, the legacy provider included
    # The prefix is only baked into the library: the files are installed through DESTDIR
    (
        cd "$build_dir"
        perl "$OPENSSL_SRC/Configure" "darwin64-$arch" no-shared no-dso no-tests no-docs no-apps \
            --prefix="$RUNTIME_PREFIX" --openssldir="$RUNTIME_PREFIX/ssl" --libdir=lib \
            "-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
        make -j"$JOBS"
        make install_sw DESTDIR="$stage_dir"
    )
    echo "$signature" >"$stamp"
}

build_freerdp() {
    local arch=$1
    local build_dir="$BUILD/freerdp-$arch"
    local stage_dir="$STAGE/freerdp-$arch"
    local no_pkgconfig="$BUILD/no-pkgconfig"
    local channel upper
    local options=()

    for channel in $(all_channels); do
        upper=$(printf '%s' "$channel" | tr '[:lower:]' '[:upper:]')
        if is_enabled_channel "$channel"; then
            options+=("-DCHANNEL_$upper=ON" "-DCHANNEL_${upper}_CLIENT=ON")
        else
            options+=("-DCHANNEL_$upper=OFF")
        fi
    done

    log "Configuring FreeRDP ($arch)"
    mkdir -p "$no_pkgconfig"
    # pkg-config sees an empty directory for the same reason as HOST_PREFIXES
    # LTO stays off: the archives must hold machine code, not LLVM bitcode tied to one compiler version
    PKG_CONFIG_LIBDIR="$no_pkgconfig" "$CMAKE" -G "$GENERATOR" -S "$FREERDP_SRC" -B "$build_dir" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DCMAKE_INSTALL_PREFIX="$RUNTIME_PREFIX" \
        -DCMAKE_IGNORE_PREFIX_PATH="$HOST_PREFIXES" \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
        -DOPENSSL_ROOT_DIR="$STAGE/openssl-$arch$RUNTIME_PREFIX" \
        -DOPENSSL_USE_STATIC_LIBS=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DWITH_CLIENT=OFF \
        -DWITH_SERVER=OFF \
        -DWITH_SAMPLE=OFF \
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
        -DWITH_INTERNAL_RC4=ON \
        -DWITH_INTERNAL_MD4=ON \
        -DWITH_INTERNAL_MD5=ON \
        "${options[@]}"

    log "Building FreeRDP ($arch)"
    "$CMAKE" --build "$build_dir" --parallel "$JOBS"
    rm -rf "$stage_dir"
    DESTDIR="$stage_dir" "$CMAKE" --install "$build_dir" >/dev/null
}

# Points pkg-config and CMake package files at the directory they now live in
relocate() {
    local dir=$1
    shift
    local file from
    find "$dir/lib" -type f \( -name '*.pc' -o -name '*.cmake' \) | while IFS= read -r file; do
        sed -i '' -e "s|^prefix=.*|prefix=$dir|" "$file"
        for from in "$@"; do
            sed -i '' -e "s|$from|$dir|g" "$file"
        done
    done
}

assemble_prefix() {
    local arch=$1
    local dir="$PREFIX/$arch"
    local openssl_root="$STAGE/openssl-$arch$RUNTIME_PREFIX"
    local freerdp_root="$STAGE/freerdp-$arch$RUNTIME_PREFIX"

    rm -rf "$dir"
    mkdir -p "$dir"
    cp -R "$openssl_root/." "$dir/"
    cp -R "$freerdp_root/." "$dir/"
    relocate "$dir" "$openssl_root" "$freerdp_root"
}

make_universal() {
    local base=${ARCHS%% *}
    local dir="$PREFIX/universal"
    local arch file inputs

    log "Merging $ARCHS into universal binaries"
    for arch in $ARCHS; do
        [ "$(object_list "$PREFIX/$arch")" = "$(object_list "$PREFIX/$base")" ] ||
            die "the object sets of $base and $arch differ"
        diff -r "$PREFIX/$base/include" "$PREFIX/$arch/include" >&2 ||
            die "headers of $base and $arch differ: the universal prefix cannot share one include tree"
    done

    rm -rf "$dir"
    cp -R "$PREFIX/$base" "$dir"
    object_list "$dir" | while IFS= read -r file; do
        inputs=()
        for arch in $ARCHS; do
            inputs+=("$PREFIX/$arch/$file")
        done
        lipo -create "${inputs[@]}" -output "$dir/$file"
    done
    relocate "$dir" "$PREFIX/$base"
}

verify() {
    local dir="$PREFIX/universal"
    local arch file minos leaked

    log "Verifying slices, deployment target and baked paths"
    object_list "$dir" | while IFS= read -r file; do
        for arch in $ARCHS; do
            lipo "$dir/$file" -verify_arch "$arch" || die "$file lacks the $arch slice"
            minos=$(otool -arch "$arch" -l "$dir/$file" | awk '$1 == "minos" { print $2 }' | sort -u | tr '\n' ' ')
            [ "$minos" = "$MACOSX_DEPLOYMENT_TARGET " ] || die "$file ($arch) targets macOS '$minos'"
        done
    done

    # Install locations of this machine must never reach the binaries: a lookup there could load planted files
    for arch in $ARCHS; do
        leaked=$(find "$PREFIX/$arch/lib" -type f \( -name '*.a' -o -name '*.o' \) -exec strings -a {} + |
            grep -F -e "$STAGE" -e "$PREFIX" | sort -u || true)
        [ -z "$leaked" ] || die "build-machine install paths are baked into the $arch binaries: $leaked"
    done
}

link_check() {
    local build_dir="$BUILD/link-check"
    local binary="$build_dir/link-check"
    local disabled="" channel arch

    for channel in $(all_channels); do
        is_enabled_channel "$channel" || disabled="$disabled $channel"
    done

    log "Link check: CMake packages of the universal prefix"
    rm -rf "$build_dir"
    "$CMAKE" -G "$GENERATOR" -S "$SCRIPT_DIR/link-check" -B "$build_dir" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
        -DCMAKE_OSX_ARCHITECTURES="$(printf '%s' "$ARCHS" | tr ' ' ';')" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DCMAKE_PREFIX_PATH="$PREFIX/universal" \
        -DCMAKE_IGNORE_PREFIX_PATH="$HOST_PREFIXES" >/dev/null
    "$CMAKE" --build "$build_dir"

    for arch in $ARCHS; do
        log "Link check ($arch)"
        if arch -"$arch" /usr/bin/true 2>/dev/null; then
            # shellcheck disable=SC2086 # channel lists are space-separated names
            arch -"$arch" "$binary" "$RUNTIME_PREFIX" $FREERDP_CHANNELS -- $disabled
        else
            lipo "$binary" -verify_arch "$arch" || die "link-check lacks the $arch slice"
            log "This Mac cannot execute $arch code: the $arch slice is linked but not run"
        fi
    done
}

main() {
    local arch

    check_prerequisites
    log "FreeRDP $(git -C "$FREERDP_SRC" describe --tags --always), OpenSSL $OPENSSL_VERSION," \
        "macOS $MACOSX_DEPLOYMENT_TARGET+, $ARCHS -> $PREFIX"
    fetch_openssl
    for arch in $ARCHS; do
        build_openssl "$arch"
        build_freerdp "$arch"
        assemble_prefix "$arch"
    done
    make_universal
    verify
    link_check
    log "Done: $PREFIX/universal"
}

main "$@"
