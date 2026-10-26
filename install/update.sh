#!/usr/bin/env bash
# Update Hades 2 Competitive Speedrunning (Linux / Steam Deck) in one command, with the game closed:
#
#   curl -fsSL https://raw.githubusercontent.com/schmidtwmark/hades2-competitive-speedrunning/main/install/update.sh | bash
#
# Downloads this repository's latest release (the main branch) to a temporary
# folder and runs its installer, which keeps your racer name and settings.
# Any installer options pass through: ... | bash -s -- --game-dir "/path/to/Hades II"
set -euo pipefail
REPO="schmidtwmark/hades2-competitive-speedrunning"
if ps -eo comm | grep -q '^Hades2'; then
  echo "Hades II is running: quit the game, then run this again." >&2
  exit 1
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Downloading the latest Hades 2 Competitive Speedrunning..."
curl -fsSL --retry 3 "https://codeload.github.com/$REPO/tar.gz/refs/heads/main" | tar -xz -C "$tmp"
bash "$tmp"/*/install/install.sh "$@" </dev/null
