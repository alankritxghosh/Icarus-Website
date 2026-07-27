#!/bin/sh
# Publish a new Icarus.dmg.
#
# The disk image's SHA-256 is pinned in FOUR places across two repositories:
# install.sh, index.html, and the Homebrew cask's sha256 and version. Every one
# of them refuses or misrepresents a build that does not match, so updating some
# and not others does not fail loudly -- it leaves one install path serving the
# previous build while the others move on. This script stamps all four from a
# single source of truth: the image itself.
#
# Works with a DMG from either source -- a local build
# (mac/Icarus/scripts/package_dmg.sh) or the dmg.yml CI workflow artifact.
#
# Usage:
#   ./release-dmg.sh /path/to/Icarus.dmg
#   ./release-dmg.sh /path/to/Icarus.dmg --skip-cask
#
# The Homebrew cask lives in a separate repository. This script looks for it at
# $ICARUS_TAP_DIR, then at ../homebrew-icarus, and REFUSES to publish if it
# finds neither -- leaving the tap stale has to be a decision (--skip-cask),
# not an accident of which directories happen to be checked out.
#
# Then review `git diff` in BOTH repos, commit, and push. Vercel deploys the
# website from main; the tap is live the moment it is pushed.

set -eu

SRC=""
SKIP_CASK=0
for arg in "$@"; do
  case "$arg" in
    --skip-cask) SKIP_CASK=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 1 ;;
    *) SRC="$arg" ;;
  esac
done

[ -n "$SRC" ] || { echo "usage: $0 /path/to/Icarus.dmg [--skip-cask]" >&2; exit 1; }
[ -f "$SRC" ] || { echo "no such file: $SRC" >&2; exit 1; }

# Resolve SRC before cd, so a relative path still works.
SRC="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
cd "$(dirname "$0")"

# Locate the cask BEFORE touching anything. Stamping the website first and only
# then discovering the tap is missing would leave exactly the half-updated state
# this script exists to prevent.
CASK=""
if [ "$SKIP_CASK" -eq 0 ]; then
  TAP="${ICARUS_TAP_DIR:-../homebrew-icarus}"
  CASK="$TAP/Casks/icarus.rb"
  if [ ! -f "$CASK" ]; then
    echo "Cannot find the Homebrew cask at: $CASK" >&2
    echo >&2
    echo "The tap pins this same hash. Publishing without updating it leaves" >&2
    echo "'brew install' serving the PREVIOUS build while every other install" >&2
    echo "path moves to the new one -- quietly, and only for brew users." >&2
    echo >&2
    echo "Clone it beside this repo:" >&2
    echo "    git clone https://github.com/alankritxghosh/homebrew-icarus ../homebrew-icarus" >&2
    echo "or point ICARUS_TAP_DIR at an existing checkout," >&2
    echo "or pass --skip-cask to leave the tap stale deliberately." >&2
    exit 1
  fi
fi

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

STAMPED_CASK="no (--skip-cask)"
if [ "$SKIP_CASK" -eq 0 ]; then
  sed -i '' -E "s/^  version \".*\"\$/  version \"$VERSION\"/" "$CASK"
  sed -i '' -E "s/^  sha256 \"[0-9a-f]{64}\"\$/  sha256 \"$SHA\"/" "$CASK"
  STAMPED_CASK="$CASK"
fi

# Prove every stamp actually landed, rather than trusting that sed matched.
STAMPED="$(sed -n -E 's/^EXPECTED_SHA="([0-9a-f]{64})"$/\1/p' install.sh)"
[ "$STAMPED" = "$SHA" ] || { echo "install.sh was not stamped correctly — fix before committing." >&2; exit 1; }
grep -q "$SHA" index.html || { echo "index.html was not stamped correctly — fix before committing." >&2; exit 1; }
sh -n install.sh || { echo "install.sh is no longer valid shell — fix before committing." >&2; exit 1; }

if [ "$SKIP_CASK" -eq 0 ]; then
  CASK_SHA="$(sed -n -E 's/^  sha256 "([0-9a-f]{64})"$/\1/p' "$CASK")"
  CASK_VER="$(sed -n -E 's/^  version "(.*)"$/\1/p' "$CASK")"
  [ "$CASK_SHA" = "$SHA" ] || { echo "cask sha256 was not stamped correctly ($CASK_SHA) — fix before committing." >&2; exit 1; }
  [ "$CASK_VER" = "$VERSION" ] || { echo "cask version was not stamped correctly ($CASK_VER) — fix before committing." >&2; exit 1; }
  # Optional: brew is not required to publish, but if it is here, let it check
  # the cask still parses rather than discovering that on someone's install.
  if command -v brew >/dev/null 2>&1; then
    brew style "$CASK" >/dev/null 2>&1 || {
      echo "warning: 'brew style $CASK' is unhappy — run it and look before committing." >&2
    }
  fi
fi

echo
echo "Published Icarus $VERSION"
echo "  brain:    $BRAIN"
echo "  size:     ${KB} KB"
echo "  sha256:   $SHA"
echo "  stamped:  install.sh, index.html"
echo "  cask:     $STAMPED_CASK"
echo
if [ "$SKIP_CASK" -eq 0 ]; then
  echo "Next: git diff and commit in BOTH repos — this one and the tap."
else
  echo "Next: git diff, then commit and push to deploy."
  echo "NOTE: the Homebrew cask was NOT updated and now points at an older build."
fi
