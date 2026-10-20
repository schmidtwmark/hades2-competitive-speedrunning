#!/usr/bin/env bash
# Install the mod (and the Hell2Modding/ModUtil versions it was tested with)
# into the owner's r2modman "Default" profile on the test PC, for real play.
# Run from the Mac. Back up first: this replaces the profile's d3d12.dll, the
# game's Ship/d3d12.dll and the listed plugin folders.
#   scripts/bazzite/deploy-r2modman.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST="${BAZZITE:-bazzite.local}"
PKG="$ROOT/local/thunderstore/x"
STAGE='h2r-deploy'

ssh "$HOST" "rm -rf $STAGE && mkdir -p $STAGE/plugins"
rsync -a "$PKG/Hell2Modding-Hell2Modding-1.0.117/ReturnOfModdingPack/d3d12.dll" "$HOST:$STAGE/d3d12.dll"
VERSIONS=""
for dir in "$PKG"/*; do
  name="$(basename "$dir")"
  ver="${name##*-}"
  guid="${name%-*}"
  VERSIONS="$VERSIONS $guid=$ver"
  case "$guid" in Hell2Modding-Hell2Modding) continue ;; esac
  rsync -a "$dir/" "$HOST:$STAGE/plugins/$guid/"
done
rsync -a --exclude '.DS_Store' "$ROOT/mod/src/" "$HOST:$STAGE/plugins/schmidtwmark-RankedRace/"

ssh "$HOST" "VERSIONS='$VERSIONS' bash -s" <<'REMOTE'
set -euo pipefail
R="$HOME/.var/app/io.github.ebkr.r2modman/config/r2modmanPlus-local/HadesII/profiles/Default"
G="$HOME/.local/share/Steam/steamapps/common/Hades II"
S="$HOME/h2r-deploy"
P="$R/ReturnOfModding/plugins"
# The earlier attempt was a symlink to another checkout; remove only the link.
[ -L "$P/schmidtwmark-Hades2SpeedrunRace" ] && rm "$P/schmidtwmark-Hades2SpeedrunRace"
for d in "$S"/plugins/*; do
  rsync -a --delete "$d/" "$P/$(basename "$d")/"
done
cp "$S/d3d12.dll" "$R/d3d12.dll"
cp "$S/d3d12.dll" "$G/Ship/d3d12.dll"
python3 - "$R/mods.yml" <<'PY'
import os, re, sys
path = sys.argv[1]
text = open(path).read()
for item in os.environ["VERSIONS"].split():
    guid, ver = item.split("=")
    major, minor, patch = ver.split(".")
    pat = re.compile(r"(  name: " + re.escape(guid) + r"\n(?:  .*\n)*?  versionNumber:\n    major: )\d+(\n    minor: )\d+(\n    patch: )\d+")
    text, n = pat.subn(lambda m: f"{m.group(1)}{major}{m.group(2)}{minor}{m.group(3)}{patch}", text)
    print(f"mods.yml {guid} -> {ver}: {'updated' if n else 'not listed'}")
open(path, "w").write(text)
PY
echo "profile plugins:"; ls "$P"
echo "d3d12: profile $(sha256sum "$R/d3d12.dll" | cut -c1-12) ship $(sha256sum "$G/Ship/d3d12.dll" | cut -c1-12)"
REMOTE
