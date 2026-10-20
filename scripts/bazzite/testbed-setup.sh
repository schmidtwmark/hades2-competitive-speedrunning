#!/usr/bin/env bash
# Build (or refresh) the isolated test bed on the test PC. Idempotent.
# Run remotely: ssh bazzite.local 'bash -s' < scripts/bazzite/testbed-setup.sh
#
# Layout (all under ~/h2r-testbed, never touching the owner's install/prefix/saves):
#   game/       btrfs reflink (copy-on-write) copy of the Steam install; Ship/d3d12.dll = our pinned H2M
#   pfx-A, pfx-B  reflink copies of the owner's Proton prefix (incl. a copy of their save)
#   rom-A, rom-B  per-instance ReturnOfModding roots (plugins, config, logs)
#   h2m/        pinned packages pushed from the Mac (scripts/bazzite/push.sh)
set -euo pipefail
TB="$HOME/h2r-testbed"
STEAM="$HOME/.local/share/Steam"
GAME="$STEAM/steamapps/common/Hades II"
CD="$STEAM/steamapps/compatdata/1145350"
mkdir -p "$TB/run"

if [ ! -d "$TB/game" ]; then
  echo "reflink-copying game install"
  cp -a --reflink=always "$GAME" "$TB/game.tmp"
  mv "$TB/game.tmp" "$TB/game"
fi
# Our pinned Hell2Modding replaces whatever d3d12.dll came along (in the copy only).
rm -f "$TB/game/Ship/d3d12.dll" "$TB/game/Ship/ReturnOfModdingFirstEnabledReason.txt"
cp "$TB/h2m/d3d12.dll" "$TB/game/Ship/d3d12.dll"
echo 1145350 > "$TB/game/Ship/steam_appid.txt"

for X in A B; do
  if [ ! -d "$TB/pfx-$X" ]; then
    echo "reflink-copying prefix for $X"
    cp -a --reflink=always "$CD" "$TB/pfx-$X"
  fi
  mkdir -p "$TB/rom-$X/ReturnOfModding/plugins" "$TB/rom-$X/ReturnOfModding/config" "$TB/rom-$X/ReturnOfModding/plugins_data"
done
echo "game: $(sha256sum "$TB/game/Ship/Hades2.exe" | cut -c1-16)…  h2m: $(sha256sum "$TB/game/Ship/d3d12.dll" | cut -c1-16)…"
echo "owner d3d12 untouched: $(sha256sum "$GAME/Ship/d3d12.dll" | cut -c1-16)…"
du -sh --apparent-size "$TB" 2>/dev/null | tail -1
echo "testbed ready"
