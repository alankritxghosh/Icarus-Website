#!/bin/sh
# Icarus installer.
#
# Why this exists: Icarus is not notarized by Apple (that needs a paid
# Developer ID). A browser marks its downloads with com.apple.quarantine,
# which is what makes macOS refuse to open the app. Files fetched with curl
# are not marked, so installing from the terminal avoids that entirely.
#
# This script does nothing clever: it downloads the same disk image the
# website serves, checks it against a known checksum, and copies the app
# into /Applications. Read it before running it — you should read anything
# you pipe into a shell.
#
# Manual alternative, if you would rather not pipe to sh:
#   curl -fLO https://icarus-website-kappa.vercel.app/Icarus.dmg
#   shasum -a 256 Icarus.dmg          # compare with the checksum below
#   open Icarus.dmg                   # drag Icarus to Applications

set -eu

DMG_URL="https://icarus-website-kappa.vercel.app/Icarus.dmg"
EXPECTED_SHA="7be8992752c2b1683306a220e34d6b2a532640535645cace56cb385d4a4c0f28"
DEST="${ICARUS_DEST:-/Applications}"
APP="Icarus.app"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Icarus is a macOS app; this machine is not running macOS." >&2
  exit 1
fi

if pgrep -qf "$DEST/$APP/Contents/MacOS/Icarus" 2>/dev/null; then
  echo "Icarus is currently running. Quit it first, then run this again." >&2
  exit 1
fi

TMP="$(mktemp -d)"
MNT="$TMP/mnt"
cleanup() {
  [ -d "$MNT" ] && hdiutil detach "$MNT" -quiet 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "Downloading Icarus..."
curl -fsSL "$DMG_URL" -o "$TMP/Icarus.dmg"

echo "Verifying download..."
ACTUAL="$(shasum -a 256 "$TMP/Icarus.dmg" | cut -d ' ' -f 1)"
if [ "$ACTUAL" != "$EXPECTED_SHA" ]; then
  echo "Checksum mismatch - not installing." >&2
  echo "  expected: $EXPECTED_SHA" >&2
  echo "  actual:   $ACTUAL" >&2
  echo "Either the download was corrupted, or the published build changed." >&2
  exit 1
fi

echo "Installing to $DEST ..."
mkdir -p "$MNT"
hdiutil attach "$TMP/Icarus.dmg" -nobrowse -quiet -mountpoint "$MNT"

if [ ! -w "$DEST" ]; then
  echo "No write permission for $DEST." >&2
  echo "Re-run with a different target, e.g.:  ICARUS_DEST=\"\$HOME/Applications\" sh -" >&2
  exit 1
fi

rm -rf "${DEST:?}/$APP"
cp -R "$MNT/$APP" "$DEST/"

# Belt and braces: curl does not set the quarantine flag, but if this script
# was ever run on an image obtained some other way, clear it so the copy in
# /Applications opens without the Gatekeeper prompt.
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

echo
echo "Installed: $DEST/$APP"
echo "Open it from $DEST, or run:  open -a Icarus"
echo
echo "First run: sign in with GitHub, connect a repo, then press Cmd-Shift-I"
echo "anywhere and ask a question. Problems -> ayushghosh2015@gmail.com"
