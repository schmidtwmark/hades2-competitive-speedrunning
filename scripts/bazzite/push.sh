#!/usr/bin/env bash
# Push pinned Hell2Modding + dependencies and the mod source from the Mac into
# both instance roots of the test bed. Run from the Mac. Packages come from
# local/thunderstore (hashes in local/thunderstore/sha256.txt).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST="${BAZZITE:-bazzite.local}"
TB='h2r-testbed'
PKG="$ROOT/local/thunderstore/x"
GUID="schmidtwmark-RankedRace"

ssh "$HOST" "mkdir -p $TB/h2m $TB/rom-A/ReturnOfModding/plugins $TB/rom-B/ReturnOfModding/plugins"
rsync -a "$ROOT/scripts/bazzite/instance.sh" "$ROOT/scripts/bazzite/testbed-setup.sh" "$ROOT/scripts/bazzite/pad.py" "$HOST:$TB/"
rsync -a "$PKG/Hell2Modding-Hell2Modding-1.0.117/ReturnOfModdingPack/d3d12.dll" "$HOST:$TB/h2m/d3d12.dll"
for X in A B; do
  for dir in "$PKG"/*; do
    name="$(basename "$dir")"
    case "$name" in Hell2Modding-Hell2Modding-*) continue ;; esac
    guid="${name%-*}" # strip -<version>
    rsync -a --delete "$dir/" "$HOST:$TB/rom-$X/ReturnOfModding/plugins/$guid/"
  done
  rsync -a --inplace --delete --exclude ".DS_Store" "$ROOT/mod/src/" "$HOST:$TB/rom-$X/ReturnOfModding/plugins/$GUID/"
done
echo "pushed $(cd "$ROOT/mod/src" && ls | wc -l | tr -d ' ') mod files + deps to $HOST:$TB/rom-{A,B}"
