#!/usr/bin/env bash
# Packs dist/VibeRDP.app, which build-client.sh leaves after its checks and tests, into an installer image
# with a laid-out window: dist/VibeRDP-<version>.dmg
# How to run it: docs/manuals/devSetup.md
#
# The order is the whole trick:
#   1. draw the background for the version packed, both scales in one TIFF
#   2. a read-write image, mounted where Finder does not see it
#   3. the window layout, the last write before compression: Finder replaces an early one with its defaults
#   4. detach and convert to a compressed read-only image
#   5. mount what ships and check it carries this background, this version and this layout
#
# Environment: VIBERDP_CACHE_DIR as for the other build scripts, plus
#   RSVG_CONVERT  rsvg-convert executable (default: rsvg-convert from PATH; brew install librsvg)

# shellcheck source-path=SCRIPTDIR
set -euo pipefail

# shellcheck source=../../core/scripts/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../core/scripts/common.sh"

RSVG_CONVERT=${RSVG_CONVERT:-rsvg-convert}
CLIENT_SRC="$REPO_ROOT/client-macos"
DIST="$REPO_ROOT/dist"
APP="$DIST/VibeRDP.app"
SOURCE="$CLIENT_SRC/dmg/background.svg"
LAYOUT="$CLIENT_SRC/dmg/layout.py"
VOLUME=VibeRDP
# Finder shows a link by its own name, not as the localized folder: the name says what the text of the window says
APPLICATIONS_LINK="Программы"
# The libraries of the layout: downloaded, cheap to fetch again, so they live in the cache
VENV="$CACHE_DIR/dmg-venv"
DS_STORE_VERSION=1.3.0
MAC_ALIAS_VERSION=2.2.0

# The window and everything in it: these numbers and client-macos/dmg/background.svg are two halves of one layout
# An icon position is its centre, and Finder draws the caption 65 points below it, where the screens of the picture are
# The title bar of a Finder window is 31 points: the window is that much taller than the background
WINDOW_W=640
WINDOW_H=400
TITLE_BAR=31
# Where the window opens, from the top-left corner of the main screen
WINDOW_LEFT=200
WINDOW_TOP=120
ICON_SIZE=96
APP_X=168
APP_Y=176
APPLICATIONS_X=472
APPLICATIONS_Y=176
# Finder that shows hidden files shows the background folder too: a whole icon below the bottom edge keeps it out of
# the window, and such a viewer gets a vertical scroll bar instead, not a horizontal one over the first-launch line
BACKGROUND_FOLDER_X=$((WINDOW_W / 2))
BACKGROUND_FOLDER_Y=$((WINDOW_H + ICON_SIZE))

WORK=""
MOUNT_POINT=""

cleanup() {
    # A volume left mounted by a failed run makes the next one fail as well
    if [ -n "$MOUNT_POINT" ]; then
        hdiutil detach -quiet -force "$MOUNT_POINT" 2>/dev/null || true
    fi
    [ -z "$WORK" ] || rm -rf "$WORK"
}

check_prerequisites() {
    [ -d "$APP" ] || die "no $APP: run client-macos/scripts/build-client.sh first"
    command -v "$RSVG_CONVERT" >/dev/null || die "rsvg-convert not found: brew install librsvg"
    command -v python3 >/dev/null || die "python3 not found: the window layout needs it"
    # Checked by importing, not by the interpreter being there: an install cut short leaves a venv without libraries
    if ! "$VENV/bin/python3" -c 'import ds_store, mac_alias' 2>/dev/null; then
        log "Preparing the libraries of the window layout in $VENV"
        python3 -m venv "$VENV"
        "$VENV/bin/pip3" install --quiet --disable-pip-version-check \
            "ds-store==$DS_STORE_VERSION" "mac-alias==$MAC_ALIAS_VERSION"
    fi
}

# Mounted out of the sight of Finder; the mount point is read back, since a volume of the same name gets "VibeRDP 1"
attach() {
    hdiutil attach -nobrowse -noverify -noautoopen "$@" | awk -F'\t' '/\/Volumes\// { print $NF; exit }'
}

layout() {
    "$VENV/bin/python3" "$LAYOUT" "$1" "$2" \
        --app VibeRDP.app --applications "$APPLICATIONS_LINK" \
        --window-left "$WINDOW_LEFT" --window-top "$WINDOW_TOP" \
        --window-width "$WINDOW_W" --window-height "$WINDOW_H" --title-bar "$TITLE_BAR" \
        --screen-height "$SCREEN_H" --icon-size "$ICON_SIZE" \
        --app-position "$APP_X,$APP_Y" --applications-position "$APPLICATIONS_X,$APPLICATIONS_Y" \
        --background-folder-position "$BACKGROUND_FOLDER_X,$BACKGROUND_FOLDER_Y"
}

main() {
    check_prerequisites
    trap cleanup EXIT
    WORK=$(mktemp -d)

    # The number in the window is the number of the app packed into it, read from the bundle itself
    local version
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
    local image="$DIST/VibeRDP-$version.dmg"
    # Finder keeps the window counted from the bottom of the main screen; AppKit gives its height without Finder
    SCREEN_H=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSScreen.mainScreen.frame.size.height') ||
        die "no main screen: the image is laid out for one"

    log "Drawing the background for $version"
    sed "s/__VERSION__/$version/" "$SOURCE" >"$WORK/background.svg"
    "$RSVG_CONVERT" -w "$WINDOW_W" -h "$WINDOW_H" "$WORK/background.svg" -o "$WORK/background-1x.png"
    "$RSVG_CONVERT" -w $((WINDOW_W * 2)) -h $((WINDOW_H * 2)) "$WORK/background.svg" -o "$WORK/background-2x.png"
    # One TIFF with both pages: Finder takes the 2x one on Retina by itself
    tiffutil -cathidpicheck "$WORK/background-1x.png" "$WORK/background-2x.png" -out "$WORK/background.tiff" \
        >"$WORK/tiffutil.log" 2>&1 || die "tiffutil failed: $(cat "$WORK/tiffutil.log")"

    log "Building the read-write image"
    local staging="$WORK/staging"
    mkdir -p "$staging/.background"
    ditto "$APP" "$staging/VibeRDP.app"
    ln -s /Applications "$staging/$APPLICATIONS_LINK"
    cp "$WORK/background.tiff" "$staging/.background/background.tiff"
    # Room for the payload plus the slack hdiutil wants for the file system itself
    local size_kb=$(($(du -sk "$staging" | cut -f1) + 40000))
    hdiutil create -quiet -srcfolder "$staging" -volname "$VOLUME" -fs HFS+ -format UDRW -size "${size_kb}k" \
        "$WORK/image.dmg"

    log "Laying out the window"
    MOUNT_POINT=$(attach "$WORK/image.dmg")
    [ -d "$MOUNT_POINT" ] || die "the read-write image did not mount"
    layout write "$MOUNT_POINT"
    sync
    hdiutil detach -quiet "$MOUNT_POINT"
    MOUNT_POINT=""

    log "Compressing into $image"
    rm -f "$image"
    hdiutil convert -quiet "$WORK/image.dmg" -format UDZO -imagekey zlib-level=9 -o "$image"

    # What ships is checked, not what was meant: nothing else looks inside the compressed image before a person does
    log "Checking the image that ships"
    MOUNT_POINT=$(attach -readonly "$image")
    [ -d "$MOUNT_POINT" ] || die "the finished image did not mount"
    cmp -s "$MOUNT_POINT/.background/background.tiff" "$WORK/background.tiff" ||
        die "the image carries another background than the one drawn for $version"
    local shipped
    shipped=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$MOUNT_POINT/VibeRDP.app/Contents/Info.plist")
    [ "$shipped" = "$version" ] || die "the image carries the app $shipped under the background of $version"
    codesign --verify --deep --strict "$MOUNT_POINT/VibeRDP.app" || die "the app in the image fails its signature"
    layout check "$MOUNT_POINT" || die "the image carries another window layout: it would not open as designed"
    hdiutil detach -quiet "$MOUNT_POINT"
    MOUNT_POINT=""

    log "Done: $image"
}

main "$@"
