#!/usr/bin/env bash
# Builds OpenSSL, MIT Kerberos and FreeRDP as universal static libraries for the macOS client
# Every build parameter comes from build.env at the repository root
# How to run it and what it produces: docs/manuals/devSetup.md
#
# Environment:
#   VIBERDP_CACHE_DIR  downloads, build trees and install prefixes (default: core/build)
#   CMAKE              cmake executable (default: cmake from PATH)

# shellcheck source-path=SCRIPTDIR
set -euo pipefail

# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

FREERDP_SRC="$REPO_ROOT/core/third_party/FreeRDP"
DOWNLOADS="$CACHE_DIR/downloads"
SOURCES="$CACHE_DIR/src"
STAGE="$CACHE_DIR/stage"
OPENSSL_SRC="$SOURCES/openssl-$OPENSSL_VERSION"
KRB5_SRC="$SOURCES/krb5-$KRB5_VERSION"

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
    for tool in "$CMAKE" perl make curl shasum tar lipo otool nm strings pkg-config; do
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

fetch_krb5() {
    local tarball="$DOWNLOADS/krb5-$KRB5_VERSION.tar.gz"
    # The releases of a series live in a folder named after it: 1.22.2 in 1.22
    local url="https://kerberos.org/dist/krb5/${KRB5_VERSION%.*}/krb5-$KRB5_VERSION.tar.gz"

    mkdir -p "$DOWNLOADS" "$SOURCES"
    if [ ! -f "$tarball" ]; then
        log "Downloading MIT Kerberos $KRB5_VERSION"
        curl -fsSL -o "$tarball.part" "$url"
        mv "$tarball.part" "$tarball"
    fi
    echo "$KRB5_SHA256  $tarball" | shasum -a 256 -c - >/dev/null || die "checksum mismatch: $tarball"
    [ -f "$KRB5_SRC/src/configure" ] || tar -xzf "$tarball" -C "$SOURCES"
}

build_krb5() {
    local arch=$1
    local build_dir="$BUILD/krb5-$arch"
    local stage_dir="$STAGE/krb5-$arch"
    local stamp="$stage_dir/.stamp"
    local signature="$KRB5_VERSION $MACOSX_DEPLOYMENT_TARGET $RUNTIME_PREFIX"
    local krb5_root="$stage_dir$RUNTIME_PREFIX"
    local part deps

    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$signature" ]; then
        log "MIT Kerberos $KRB5_VERSION ($arch) is up to date"
        return 0
    fi

    log "Building MIT Kerberos $KRB5_VERSION ($arch)"
    rm -rf "$build_dir" "$stage_dir"
    mkdir -p "$build_dir"
    # Static libraries with the plugins linked in; the builtin crypto keeps OpenSSL out of it, and without PKINIT,
    # TLS for KDC proxies, LDAP and line editing it needs nothing beyond the system
    # Its default ticket cache on macOS is the system one, API:, which lives in Kerberos.framework: a shared build
    # links the framework into libkrb5, a static one leaves it to every program, the tools of Kerberos too
    # Without --with-krb5-config=no configure takes the default cache and keytab names from a krb5-config in PATH,
    # which would be whatever Kerberos this machine has
    # The configure checks run programs of the target architecture: another one runs under Rosetta
    (
        cd "$build_dir"
        CC="cc -arch $arch" \
            CFLAGS="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -Werror=unguarded-availability-new -O2" \
            LDFLAGS="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
            LIBS="-framework Kerberos" \
            "$KRB5_SRC/src/configure" --prefix="$RUNTIME_PREFIX" \
            --enable-static --disable-shared --disable-rpath --disable-nls --disable-pkinit --with-krb5-config=no \
            --with-crypto-impl=builtin --with-tls-impl=no --without-keyutils --without-libedit --without-lmdb \
            --without-ldap >/dev/null
        # Only the libraries, their headers and pkg-config files: the tools and servers of Kerberos are not needed,
        # and linked statically its admin tools define the same symbol as the admin library
        for part in util include lib build-tools; do
            make -C "$part" -j"$JOBS" >/dev/null
        done
        # The top level makes the install folders that a full install would have made
        make install-mkdirs DESTDIR="$stage_dir" >/dev/null
        for part in util include lib build-tools; do
            make -C "$part" install DESTDIR="$stage_dir" >/dev/null
        done
    )
    # The pkg-config file of Kerberos names only libkrb5support as private, as if it were never static
    # A static link also needs the system libraries that krb5-config records: -lkrb5support $LIBS $DL_LIB, as its
    # comment says; a framework goes as one linker flag, since CMake de-duplicates link options word by word
    grep -qx 'Libs.private: -lkrb5support' "$krb5_root/lib/pkgconfig/mit-krb5.pc" ||
        die "the private libraries of mit-krb5.pc changed: check the completion below"
    deps=$(sed -n -e "s/^LIBS='\(.*\)'\$/\1/p" -e "s/^DL_LIB='\(.*\)'\$/\1/p" "$krb5_root/bin/krb5-config" |
        tr '\n' ' ' | sed -E 's/-framework ([^ ]+)/-Wl,-framework,\1/g; s/ +/ /g; s/^ //; s/ $//')
    sed -i '' "s|^Libs.private: .*|& $deps|" "$krb5_root/lib/pkgconfig/mit-krb5.pc"
    echo "$signature" >"$stamp"
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
    local krb5_root="$STAGE/krb5-$arch$RUNTIME_PREFIX"
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
    # pkg-config sees only the staged Kerberos, for the same reason as HOST_PREFIXES: Homebrew stays out
    # Its files name the runtime prefix, and the sysroot puts the staging folder in front of it
    # --static adds the private libraries, which the exported packages of FreeRDP then carry to every program
    # LTO stays off: the archives must hold machine code, not LLVM bitcode tied to one compiler version
    # The configure checks see the SDK, not the deployment target, and adopt APIs the oldest supported macOS lacks
    # Using such an API is a compile error here, since its weak reference would be NULL on that macOS
    # pipe2 arrived in macOS 27 and its check only takes the function address, which passes: the result is preset
    # --fresh drops cached check results, so they always follow the current flags
    PKG_CONFIG_LIBDIR="$krb5_root/lib/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$STAGE/krb5-$arch" \
        "$CMAKE" --fresh -G "$GENERATOR" -S "$FREERDP_SRC" -B "$build_dir" \
        -DCMAKE_C_FLAGS="-Werror=unguarded-availability-new" \
        -DWINPR_HAVE_PIPE2=OFF \
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
        -DWITH_KRB5=ON \
        -DKRB5_ROOT_FLAVOUR=MIT \
        -DPKG_CONFIG_ARGN=--static \
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
    local krb5_root="$STAGE/krb5-$arch$RUNTIME_PREFIX"
    local freerdp_root="$STAGE/freerdp-$arch$RUNTIME_PREFIX"

    rm -rf "$dir"
    mkdir -p "$dir/lib"
    cp -R "$openssl_root/." "$dir/"
    # Of Kerberos the prefix takes the libraries and their headers; its tools and servers stay behind
    cp -R "$krb5_root/include" "$dir/"
    cp "$krb5_root"/lib/*.a "$dir/lib/"
    cp -R "$freerdp_root/." "$dir/"
    relocate "$dir" "$openssl_root" "$krb5_root" "$freerdp_root"
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
    local arch file leaked

    log "Verifying slices, deployment target, API availability and baked paths"
    object_list "$dir" | while IFS= read -r file; do
        check_binary "$dir/$file"
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
    check_binary "$binary"

    for arch in $ARCHS; do
        log "Link check ($arch)"
        if can_execute "$arch"; then
            # shellcheck disable=SC2086 # channel lists are space-separated names
            run_bounded "$FOREIGN_RUN_TIMEOUT" arch -"$arch" "$binary" "$RUNTIME_PREFIX" $FREERDP_CHANNELS -- $disabled
        else
            log "This Mac cannot execute $arch code: the $arch slice is linked but not run"
        fi
    done
}

main() {
    local arch

    check_prerequisites
    log "FreeRDP $(git -C "$FREERDP_SRC" describe --tags --always), OpenSSL $OPENSSL_VERSION," \
        "MIT Kerberos $KRB5_VERSION, macOS $MACOSX_DEPLOYMENT_TARGET+, $ARCHS -> $PREFIX"
    fetch_openssl
    fetch_krb5
    for arch in $ARCHS; do
        build_openssl "$arch"
        build_krb5 "$arch"
        build_freerdp "$arch"
        assemble_prefix "$arch"
    done
    make_universal
    verify
    link_check
    log "Done: $PREFIX/universal"
}

main "$@"
