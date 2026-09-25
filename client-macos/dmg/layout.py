#!/usr/bin/env python3
"""The window of the installer image: the .DS_Store of its volume, written and checked without Finder

The records are the ones Finder writes for a laid-out window:
the window (bwsp), the icon view with its background (icvp), the view version (vSrn) and where each item stands (Iloc)
Written here, the build shows no half-made Finder window and needs no permission to script Finder

No bookmark to the background (pBBk): current Finder cannot resolve one made by mac_alias
and then shows no background at all, while the alias alone it resolves

write lays the window out on the read-write image, check reads the image that ships and fails unless it matches
Needs ds_store and mac_alias: scripts/build-dmg.sh keeps them in a venv of the cache
"""

import argparse
import os
import sys

import ds_store.store
from ds_store import DSStore
from mac_alias import Alias

BACKGROUND_FOLDER = ".background"
BACKGROUND = os.path.join(BACKGROUND_FOLDER, "background.tiff")

# Icon view, not arranged, captions under the icons: what Finder writes; the size and the picture come per image
ICON_VIEW = {
    "viewOptionsVersion": 1,
    "arrangeBy": "none",
    "gridOffsetX": 0.0,
    "gridOffsetY": 0.0,
    "gridSpacing": 100.0,
    "labelOnBottom": True,
    "showIconPreview": True,
    "showItemInfo": False,
    "textSize": 12.0,
    "backgroundColorRed": 1.0,
    "backgroundColorGreen": 1.0,
    "backgroundColorBlue": 1.0,
    # 2 is a picture, 1 the plain colour above
    "backgroundType": 2,
}

BARS_HIDDEN = {
    "ShowToolbar": False,
    "ShowStatusBar": False,
    "ShowSidebar": False,
    "ContainerShowSidebar": False,
    "ShowTabView": False,
}


def point(text):
    x, y = text.split(",")
    return int(x), int(y)


def window_bounds(args):
    """bwsp keeps the window in screen space of Cocoa: its bottom-left corner from the bottom of the main screen,
    and a height that counts the title bar"""
    height = args.window_height + args.title_bar
    bottom = args.screen_height - args.window_top - height
    return "{{%d, %d}, {%d, %d}}" % (args.window_left, bottom, args.window_width, height)


def places(args):
    return (
        (args.app, args.app_position),
        (args.applications, args.applications_position),
        # Finder that shows hidden files shows this folder whatever its name: given no place, it lands in the window
        (BACKGROUND_FOLDER, args.background_folder_position),
    )


def write(args):
    background = os.path.join(args.mount, BACKGROUND)
    if not os.path.isfile(background):
        sys.exit(f"layout: no background at {background}")

    with DSStore.open(os.path.join(args.mount, ".DS_Store"), "w+") as store:
        store["."]["bwsp"] = dict(BARS_HIDDEN, WindowBounds=window_bounds(args))
        store["."]["icvp"] = dict(
            ICON_VIEW, iconSize=float(args.icon_size), backgroundImageAlias=Alias.for_file(background).to_bytes())
        store["."]["vSrn"] = ("long", 1)
        for name, position in places(args):
            store[name]["Iloc"] = position


def check(args):
    """Every record write puts down, read back from the image that ships"""
    # A bookmark is only reported, not parsed: its presence alone hides the background
    ds_store.store.codecs.pop(b"pBBk", None)
    path = os.path.join(args.mount, ".DS_Store")
    if not os.path.isfile(path):
        return ["no .DS_Store: the window would open as a plain list of files"]

    with DSStore.open(path, "r") as store:
        records = {(entry.filename, entry.code.decode()): entry.value for entry in store}

    problems = []
    window = records.get((".", "bwsp")) or {}
    if window.get("WindowBounds") != window_bounds(args):
        problems.append(f"window bounds {window.get('WindowBounds')!r}, expected {window_bounds(args)!r}")
    problems += [f"{bar} is not hidden" for bar in BARS_HIDDEN if window.get(bar) is not False]

    view = records.get((".", "icvp")) or {}
    if view.get("backgroundType") != 2 or not view.get("backgroundImageAlias"):
        problems.append("the icon view has no background picture")
    elif Alias.from_bytes(view["backgroundImageAlias"]).target.filename != os.path.basename(BACKGROUND):
        problems.append("the background alias points at another file")
    if view.get("iconSize") != float(args.icon_size) or view.get("arrangeBy") != "none":
        problems.append(f"icon view {view.get('iconSize')!r}/{view.get('arrangeBy')!r}")
    if (".", "pBBk") in records:
        problems.append("a background bookmark (pBBk): Finder would show no background")

    for name, expected in places(args):
        if records.get((name, "Iloc")) != expected:
            problems.append(f"{name} at {records.get((name, 'Iloc'))}, expected {expected}")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("mode", choices=["write", "check"])
    parser.add_argument("mount")
    parser.add_argument("--app", required=True, help="the name of the bundle, NAME.app")
    parser.add_argument("--applications", required=True, help="the name of the link to /Applications")
    parser.add_argument("--window-left", type=int, required=True)
    parser.add_argument("--window-top", type=int, required=True)
    parser.add_argument("--window-width", type=int, required=True)
    parser.add_argument("--window-height", type=int, required=True, help="the content, without the title bar")
    parser.add_argument("--title-bar", type=int, required=True)
    parser.add_argument("--screen-height", type=int, required=True, help="the main screen, in points")
    parser.add_argument("--icon-size", type=int, required=True)
    parser.add_argument("--app-position", type=point, required=True, help="X,Y of the centre of the icon")
    parser.add_argument("--applications-position", type=point, required=True)
    parser.add_argument("--background-folder-position", type=point, required=True, help="below the window")
    args = parser.parse_args()

    if args.mode == "write":
        write(args)
        return
    problems = check(args)
    for problem in problems:
        print(f"layout: {problem}", file=sys.stderr)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
