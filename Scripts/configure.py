#!/usr/bin/env python3
"""Sets the bundle identifier base and Apple developer team for Networker.

    python3 Scripts/configure.py --bundle-id com.yourname.networker --team ABCDE12345

The bundle identifier base becomes the app's bundle ID; the tunnel extension uses
"<base>.tunnel" and the shared App Group "group.<base>". This script rewrites
Config/Networker.xcconfig and both .entitlements files so they stay consistent.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
XCCONFIG = ROOT / "Config" / "Networker.xcconfig"
ENTITLEMENTS = [
    ROOT / "Networker" / "Networker.entitlements",
    ROOT / "NetworkerTunnel" / "NetworkerTunnel.entitlements",
]


def current_base():
    match = re.search(r"^BUNDLE_ID_BASE\s*=\s*(\S+)\s*$", XCCONFIG.read_text(), re.MULTILINE)
    if not match:
        sys.exit(f"BUNDLE_ID_BASE not found in {XCCONFIG}")
    return match.group(1)


def set_xcconfig(key, value):
    text = XCCONFIG.read_text()
    pattern = re.compile(rf"^{key}\s*=.*$", re.MULTILINE)
    if not pattern.search(text):
        sys.exit(f"{key} not found in {XCCONFIG}")
    XCCONFIG.write_text(pattern.sub(f"{key} = {value}".rstrip(), text, count=1))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bundle-id", help="new bundle identifier base, e.g. com.yourname.networker")
    parser.add_argument("--team", help="Apple Developer Team ID (10 characters)")
    args = parser.parse_args()
    if not args.bundle_id and not args.team:
        parser.error("nothing to do: pass --bundle-id and/or --team")

    if args.bundle_id:
        new = args.bundle_id.strip()
        if not re.fullmatch(r"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+", new):
            sys.exit("bundle id must look like com.yourname.networker (letters, digits, hyphens, dots)")
        if new.endswith(".tunnel"):
            sys.exit("bundle id must not end in .tunnel; that suffix is reserved for the extension")
        old = current_base()
        for path in ENTITLEMENTS:
            text = path.read_text()
            if f"group.{old}" not in text:
                sys.exit(f"expected group.{old} in {path}; edit the file by hand")
            path.write_text(text.replace(f"group.{old}", f"group.{new}"))
        set_xcconfig("BUNDLE_ID_BASE", new)
        print(f"bundle id base: {new}")
        print(f"  app:        {new}")
        print(f"  extension:  {new}.tunnel")
        print(f"  app group:  group.{new}")

    if args.team:
        team = args.team.strip().upper()
        if not re.fullmatch(r"[A-Z0-9]{10}", team):
            sys.exit("team id must be 10 letters/digits")
        set_xcconfig("DEVELOPMENT_TEAM", team)
        print(f"development team: {team}")


if __name__ == "__main__":
    main()
