#!/bin/sh
# Publish a new Icarus.dmg to this website.
#
# Copies the disk image in, recomputes its SHA-256, and stamps that hash into
# both install.sh and index.html. These must always agree: install.sh refuses to
# install any image whose hash does not match, so a DMG dropped in by hand
# without re-stamping breaks every terminal install until someone notices.
# Running this instead of copying the file by hand is what prevents that.
#
# Works with a DMG from either source — a local build
# (mac/Icarus/scripts/package_dmg.sh) or the dmg.yml CI workflow artifact.
#
# Usage:
#   ./release-dmg.sh /path/to/Icarus.dmg
#
# Then review `git diff`, commit, and push — Vercel deploys from main.

set -eu

SRC="${1:-}"
[ -n "$SRC" ] || { echo "usage: $0 /path/to/Icarus.dmg" >&2; exit 1; }
[ -f "$SRC" ] || { echo "no such file: $SRC" >&2; exit 1; }

cd "$(dirname "$0")"

TMP="$(mktemp -d)"
MNT="$TMP/mnt"
cleanup() {
  [ -d "$MNT" ] && hdiutil detach "$MNT" -quiet 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# Guard against publishing a build that points at a local brain. Such a build
# installs and launches perfectly for whoever built it, and fails for every
# tester — remotely, and without an obvious cause. Catch it here instead.
echo "Checking the disk image..."
mkdir -p "$MNT"
hdiutil attach "$SRC" -nobrowse -quiet -mountpoint "$MNT"
[ -d "$MNT/Icarus.app" ] || { echo "No Icarus.app inside $SRC — not an Icarus disk image." >&2; exit 1; }

PLIST="$MNT/Icarus.app/Contents/Info.plist"
BRAIN="$(/usr/libexec/PlistBuddy -c 'Print :ICARUS_BRAIN_URL' "$PLIST" 2>/dev/null || echo '')"
case "$BRAIN" in
  https://*) : ;;
  '')
    echo "This build has no ICARUS_BRAIN_URL stamped, so it falls back to" >&2
    echo "127.0.0.1:8000 and cannot reach a hosted brain. Refusing to publish." >&2
    echo "Rebuild with: ICARUS_BRAIN_URL=https://... scripts/package_dmg.sh" >&2
    exit 1 ;;
  *)
    echo "This build points at '$BRAIN', which is not a hosted https brain." >&2
    echo "Refusing to publish." >&2
    exit 1 ;;
esac
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo '?')"
hdiutil detach "$MNT" -quiet

cp "$SRC" Icarus.dmg
SHA="$(shasum -a 256 Icarus.dmg | cut -d ' ' -f 1)"
KB="$(( ($(wc -c < Icarus.dmg) + 512) / 1024 ))"

sed -i '' -E "s/^EXPECTED_SHA=.*/EXPECTED_SHA=\"$SHA\"/" install.sh
sed -i '' -E "s#<code>[0-9a-f]{64}</code>#<code>$SHA</code>#" index.html
sed -i '' -E "s/~[0-9]+ KB/~$KB KB/g" index.html

# Prove the stamp actually landed, rather than trusting that sed matched.
STAMPED="$(sed -n -E 's/^EXPECTED_SHA="([0-9a-f]{64})"$/\1/p' install.sh)"
[ "$STAMPED" = "$SHA" ] || { echo "install.sh was not stamped correctly — fix before committing." >&2; exit 1; }
grep -q "$SHA" index.html || { echo "index.html was not stamped correctly — fix before committing." >&2; exit 1; }
sh -n install.sh || { echo "install.sh is no longer valid shell — fix before committing." >&2; exit 1; }

echo
echo "Published Icarus $VERSION"
echo "  brain:    $BRAIN"
echo "  size:     ${KB} KB"
echo "  sha256:   $SHA"
echo "  stamped:  install.sh, index.html"
echo
echo "Next: git diff, then commit and push to deploy."
