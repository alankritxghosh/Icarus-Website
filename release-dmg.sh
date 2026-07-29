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

# Regenerate the Sparkle update feed. Without this, a published DMG is
# invisible to every already-installed copy of Icarus -- they poll appcast.xml
# and would keep seeing the previous release forever, which looks exactly like
# "updates don't work" and is impossible to notice from this side.
#
# generate_appcast signs each build with the PRIVATE EdDSA key in the login
# keychain, so this can only run on the machine that holds it. It lives in the
# Icarus repo's SwiftPM artifacts; point ICARUS_APPCAST_TOOL at it to override.
APPCAST_TOOL="${ICARUS_APPCAST_TOOL:-}"
if [ -z "$APPCAST_TOOL" ]; then
  APPCAST_TOOL="$(find "$(dirname "$SRC")/.." -type f -name generate_appcast -perm -u+x -print -quit 2>/dev/null || true)"
fi
if [ -n "$APPCAST_TOOL" ] && [ -x "$APPCAST_TOOL" ]; then
  FEED_DIR="$(mktemp -d)"
  cp Icarus.dmg "$FEED_DIR/"
  # Deliberately NOT carrying the previous appcast forward. Every release is
  # published to the SAME URL (/Icarus.dmg), so an older entry would keep
  # pointing at that URL while the bytes behind it are now a newer build --
  # an item whose length and signature no longer describe what downloading it
  # actually gets you. One DMG URL means one entry. If multiple versions ever
  # need to stay downloadable, the filename has to carry the version first.
  if "$APPCAST_TOOL" --download-url-prefix "https://icarus-website-kappa.vercel.app/" "$FEED_DIR" >/dev/null 2>&1; then
    cp "$FEED_DIR/appcast.xml" appcast.xml
    STAMPED_FEED="appcast.xml"
  else
    echo "error: could not sign the update feed -- is the Sparkle private key" >&2
    echo "       in this machine's login keychain? Publishing a DMG without a" >&2
    echo "       matching appcast entry means nobody can update to it." >&2
    rm -rf "$FEED_DIR"
    exit 1
  fi
  rm -rf "$FEED_DIR"
else
  echo "warning: generate_appcast not found -- appcast.xml NOT regenerated," >&2
  echo "         so installed copies will not be offered this build." >&2
  STAMPED_FEED="NOT UPDATED"
fi
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
echo "  feed:     ${STAMPED_FEED:-unchanged}"
echo "  cask:     $STAMPED_CASK"
echo
if [ "$SKIP_CASK" -eq 0 ]; then
  echo "Next: git diff and commit in BOTH repos — this one and the tap."
else
  echo "Next: git diff, then commit and push to deploy."
  echo "NOTE: the Homebrew cask was NOT updated and now points at an older build."
fi
