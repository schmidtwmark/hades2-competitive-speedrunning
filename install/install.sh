#!/usr/bin/env bash
# Install Ranked Race for Hades II on Linux / Steam Deck (Steam + Proton).
#
#   install/install.sh                 install or update
#   install/install.sh --uninstall     remove it again
#   options: --game-dir "<.../Hades II>"   (default: found in your Steam libraries)
#            --name "Your Name"            the name your rival sees (default: "Melinoe 123")
#            --dry-run                     show what would happen, change nothing
#
# What it does (and nothing else):
#   1. finds the Hades II install in your Steam libraries;
#   2. downloads the exact Hell2Modding + ModUtil set the mod is tested with
#      from Thunderstore (install/packages.txt) and checks each SHA-256;
#   3. puts Hell2Modding's d3d12.dll next to Hades2.exe (an existing one is
#      backed up) and the mods into "Hades II/Ship/ReturnOfModding/plugins".
# It never touches your saves. Afterwards set the Steam launch options it
# prints (Steam keeps those itself; no script can set them reliably).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUID="schmidtwmark-RankedRace"
MARKER=".ranked-race-install"
LAUNCH_OPTIONS='WINEDLLOVERRIDES="d3d12=n,b" %command% --rom_enabled true'
GAME_DIR=""
NAME=""
MODE=install
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --game-dir) GAME_DIR="${2:?--game-dir needs a path}"; shift 2 ;;
    --name) NAME="${2:?--name needs a value}"; shift 2 ;;
    --uninstall) MODE=uninstall; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
run() { if [ "$DRY" = 1 ]; then say "  (dry run) $*"; else "$@"; fi; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"; }

# --- find the game -------------------------------------------------------------
find_game() {
  local roots=("$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam")
  local libs=()
  for r in "${roots[@]}"; do
    [ -d "$r/steamapps" ] && libs+=("$r")
    local vdf="$r/steamapps/libraryfolders.vdf"
    if [ -f "$vdf" ]; then
      while IFS= read -r p; do libs+=("$p"); done < <(sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"/\1/p' "$vdf")
    fi
  done
  for l in "${libs[@]}"; do
    local g="$l/steamapps/common/Hades II"
    if [ -f "$g/Ship/Hades2.exe" ]; then printf '%s\n' "$g"; return 0; fi
  done
  return 1
}

if [ -z "$GAME_DIR" ]; then
  GAME_DIR="$(find_game)" || die "could not find Hades II in your Steam libraries; pass --game-dir \"/path/to/Hades II\""
fi
SHIP="$GAME_DIR/Ship"
[ -f "$SHIP/Hades2.exe" ] || die "$SHIP/Hades2.exe not found (is --game-dir the 'Hades II' folder?)"
ROM="$SHIP/ReturnOfModding"
PLUGINS="$ROM/plugins"
say "Hades II: $GAME_DIR"

# --- uninstall -------------------------------------------------------------------
if [ "$MODE" = uninstall ]; then
  ours=0
  [ -f "$ROM/$MARKER" ] && ours=1 # this installer created the ReturnOfModding folder
  if [ "$ours" = 1 ]; then
    run rm -rf "$ROM"
    say "removed $ROM"
  else
    run rm -rf "$PLUGINS/$GUID"
    say "removed $PLUGINS/$GUID (ReturnOfModding was there before this installer, so the rest stays)"
  fi
  if [ -f "$SHIP/d3d12.dll.before-ranked-race" ]; then
    run mv -f "$SHIP/d3d12.dll.before-ranked-race" "$SHIP/d3d12.dll"
    say "restored the d3d12.dll that was there before"
  elif [ "$ours" = 1 ] && [ -f "$SHIP/d3d12.dll" ]; then
    run rm -f "$SHIP/d3d12.dll"
    say "removed Hell2Modding (Ship/d3d12.dll)"
  fi
  say "Done. Remove the Hades II launch options in Steam if you added them."
  exit 0
fi

# --- download + verify -----------------------------------------------------------
need curl
need unzip
if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"; else need shasum; SHA="shasum -a 256"; fi
[ -f "$ROOT/mod/src/main.lua" ] || die "run this from a full copy of the repository (mod/src is missing)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
while read -r guid version hash; do
  case "$guid" in ''|'#'*) continue ;; esac
  ns="${guid%%-*}"; name="${guid#*-}"
  zip="$WORK/$guid.zip"
  say "downloading $guid $version"
  curl -fsSL --retry 3 -o "$zip" "https://thunderstore.io/package/download/$ns/$name/$version/" || die "download failed: $guid $version"
  got="$($SHA "$zip" | cut -d' ' -f1)"
  [ "$got" = "$hash" ] || die "$guid $version: SHA-256 mismatch (got $got, want $hash); not installing"
  mkdir -p "$WORK/x/$guid"
  unzip -q "$zip" -d "$WORK/x/$guid"
done < "$ROOT/install/packages.txt"

# --- install ---------------------------------------------------------------------
H2M="$WORK/x/Hell2Modding-Hell2Modding/ReturnOfModdingPack/d3d12.dll"
[ -f "$H2M" ] || die "Hell2Modding package has no ReturnOfModdingPack/d3d12.dll"
fresh=0
[ -d "$ROM" ] || fresh=1
if [ -f "$SHIP/d3d12.dll" ] && ! cmp -s "$H2M" "$SHIP/d3d12.dll"; then
  run cp -f "$SHIP/d3d12.dll" "$SHIP/d3d12.dll.before-ranked-race"
  say "backed up the existing Ship/d3d12.dll to d3d12.dll.before-ranked-race"
fi
run cp -f "$H2M" "$SHIP/d3d12.dll"
run mkdir -p "$PLUGINS"
[ "$fresh" = 1 ] && run touch "$ROM/$MARKER"
for dir in "$WORK"/x/*; do
  guid="$(basename "$dir")"
  [ "$guid" = Hell2Modding-Hell2Modding ] && continue
  run rm -rf "$PLUGINS/$guid"
  run cp -R "$dir" "$PLUGINS/$guid"
done
run rm -rf "$PLUGINS/$GUID"
run mkdir -p "$PLUGINS/$GUID"
run cp -R "$ROOT/mod/src/." "$PLUGINS/$GUID/"
say "installed Hell2Modding + ModUtil + Ranked Race into $ROM"

# The name other racers see (controller players can't type one in game).
if [ -n "$NAME" ]; then
  printf '%s' "$NAME" | grep -Eq "^[A-Za-z0-9 _.'-]{1,24}$" || die "--name: 1-24 letters, digits, spaces or _ . ' -"
  CFG="$ROM/config/$GUID/config.json"
  run mkdir -p "$(dirname "$CFG")"
  if [ "$DRY" = 1 ]; then
    say "  (dry run) set player_name in $CFG"
  elif [ -f "$CFG" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$CFG" "$NAME" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
try:
    cfg = json.load(open(path))
except Exception:
    cfg = {}
cfg["player_name"] = name
json.dump(cfg, open(path, "w"))
PY
  else
    printf '{"player_name":"%s"}' "$NAME" >"$CFG"
  fi
  say "racer name: $NAME"
fi

cat <<EOF

One step left: Steam launch options (Steam stores these itself).
  Steam -> Library -> Hades II -> Properties -> General -> Launch Options, set:

    $LAUNCH_OPTIONS

  If there is already something there, keep it and add the two parts:
  WINEDLLOVERRIDES="d3d12=n,b" before %command%, and --rom_enabled true after it.

Then start Hades II and pick "Play Competitive Speedrun" on the title screen.
Check it loaded: $ROM/LogOutput.log mentions "$GUID".
EOF
