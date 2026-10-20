#!/usr/bin/env bash
# Read-only survey of the test PC. Run from the Mac:
#   ssh bazzite.local 'bash -s' < scripts/bazzite/triage.sh > local/triage.txt
# Changes nothing on the remote machine.
set -uo pipefail
APPID=1145350
echo "== host"; hostname; uname -r; grep -E '^(NAME|VERSION)=' /etc/os-release; nproc; free -g | head -2
echo "== gpu"; (lspci 2>/dev/null | grep -iE 'vga|3d|display') || true
echo "== session"; echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-}"; loginctl list-sessions 2>/dev/null | head
pgrep -a gamescope | head -3 || true; pgrep -a -f 'steam' | grep -v -- '-c ' | head -5 || true
echo "== tools"; for t in node npm lua python3 rsync unzip curl sha256sum distrobox podman flatpak; do printf '%s: ' "$t"; command -v "$t" || echo missing; done

# Steam roots: native, flatpak
for r in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
  [ -d "$r/steamapps" ] && echo "steam_root: $(readlink -f "$r")"
done | sort -u
echo "== libraries"
for r in "$HOME/.local/share/Steam" "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
  f="$r/steamapps/libraryfolders.vdf"; [ -f "$f" ] && grep '"path"' "$f"
done
echo "== hades2 manifest"
for lib in $(for r in "$HOME/.local/share/Steam" "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do f="$r/steamapps/libraryfolders.vdf"; [ -f "$f" ] && grep '"path"' "$f" | sed -E 's/.*"path"[[:space:]]*"([^"]+)".*/\1/'; done | sort -u); do
  m="$lib/steamapps/appmanifest_$APPID.acf"
  if [ -f "$m" ]; then
    echo "library: $lib"
    grep -E '"(buildid|installdir|LastUpdated|SizeOnDisk|StateFlags)"' "$m"
    game="$lib/steamapps/common/$(grep '"installdir"' "$m" | sed -E 's/.*"installdir"[[:space:]]*"([^"]+)".*/\1/')"
    echo "game_dir: $game"
    ls -la "$game" | head -20
    ls -la "$game/Ship" | head -40
    [ -f "$game/Ship/Hades2.exe" ] && sha256sum "$game/Ship/Hades2.exe"
    echo "scripts: $(ls "$game/Content/Scripts" 2>/dev/null | wc -l) files"
    ls "$game/Content/Scripts" 2>/dev/null | grep -E '^(RunLogic|RoomLogic|DeathLoopLogic|RandomLogic|BountyLogic|KeepsakeLogic|KeepsakeData|WeaponSets|CombatLogic|RunClearLogic)\.lua$'
    echo "h2m_present: $(ls "$game/Ship"/d3d12.dll "$game/Ship"/winhttp.dll 2>/dev/null | tr '\n' ' ')"
    ls -d "$game/Ship/ReturnOfModding" 2>/dev/null && ls "$game/Ship/ReturnOfModding/plugins" 2>/dev/null
    cat "$game/Ship/ReturnOfModdingFirstEnabledReason.txt" 2>/dev/null
    echo "compatdata: $lib/steamapps/compatdata/$APPID"
    cd_saves="$lib/steamapps/compatdata/$APPID/pfx/drive_c/users/steamuser/Saved Games/Hades II"
    ls -la "$cd_saves" 2>/dev/null | head -20
    cat "$lib/steamapps/compatdata/$APPID/config_info" 2>/dev/null | head -3
  fi
done
echo "== proton versions"
for r in "$HOME/.local/share/Steam" "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
  ls -d "$r/steamapps/common/Proton"* "$r/compatibilitytools.d/"* 2>/dev/null
done
echo "== launch options for $APPID"
for f in "$HOME"/.local/share/Steam/userdata/*/config/localconfig.vdf; do
  [ -f "$f" ] && awk -v id="\"$APPID\"" '$1==id{p=1} p&&/LaunchOptions/{print; exit}' "$f"
done
echo "== r2modman / gale"
ls -d "$HOME/.config/r2modmanPlus-local" "$HOME/.local/share/com.kesomannen.gale" "$HOME/.config/r2modman" 2>/dev/null
find "$HOME/.config/r2modmanPlus-local" -maxdepth 4 -iname '*hades*' 2>/dev/null | head
echo "== done"
