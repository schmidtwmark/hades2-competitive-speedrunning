#!/usr/bin/env bash
# Start / stop / inspect one isolated game instance on the test PC.
#   instance.sh start A [game args...]   launch as systemd user unit h2r-A (Proton 11 in SteamLinuxRuntime_4)
#   instance.sh stop A                    stop unit h2r-A (only its own processes)
#   instance.sh status A
# Each instance runs in its own systemd user unit so it outlives the SSH
# session that started it, and stopping it can only touch its own cgroup.
# The owner's install, prefix and saves are never used.
set -uo pipefail
TB="$HOME/h2r-testbed"
STEAM="$HOME/.local/share/Steam"
PROTON="$STEAM/steamapps/common/Proton 11.0"
RUNTIME="$STEAM/steamapps/common/SteamLinuxRuntime_4"
cmd="${1:?start|stop|status}"
X="${2:?instance A|B}"
shift 2 || true
UNIT="h2r-$X"
PFX="$TB/pfx-$X"
ROM="$TB/rom-$X"
OUT="$TB/run/$X.out"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

case "$cmd" in
start)
  if systemctl --user is-active --quiet "$UNIT"; then echo "instance $X already running"; exit 1; fi
  systemctl --user reset-failed "$UNIT" 2>/dev/null
  mkdir -p "$TB/run" "$ROM/ReturnOfModding/config"
  : >"$OUT"
  # Test roots only: skip Hell2Modding's one-time welcome dialog (it covers the overlay).
  GUI_CFG="$ROM/ReturnOfModding/config/Hell2Modding-Hell2Modding-GUI.cfg"
  if [ -f "$GUI_CFG" ]; then sed -i 's/^onboarded = false/onboarded = true/' "$GUI_CFG"
  else printf 'is_open_at_startup = false\nonboarded = true\n' >"$GUI_CFG"; fi
  # Like the installer: no log console window.
  H2M_CFG="$ROM/ReturnOfModding/config/Hell2Modding-Hell2Modding-General.cfg"
  if grep -q '^Console Enabled' "$H2M_CFG" 2>/dev/null; then sed -i 's/^Console Enabled = .*/Console Enabled = false/' "$H2M_CFG"
  else printf '[Logging]\nConsole Enabled = false\n' >>"$H2M_CFG"; fi
  systemd-run --user --unit="$UNIT" --collect --quiet \
    -p WorkingDirectory="$TB/game/Ship" \
    -p StandardOutput="append:$OUT" -p StandardError="append:$OUT" \
    -p TimeoutStopSec=15 \
    --setenv=DISPLAY="${H2R_DISPLAY:-:1}" \
    --setenv=XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    --setenv=DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus" \
    --setenv=STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM" \
    --setenv=STEAM_COMPAT_DATA_PATH="$PFX" \
    --setenv=SteamAppId=1145350 --setenv=SteamGameId=1145350 --setenv=STEAM_COMPAT_APP_ID=1145350 \
    --setenv=WINEDLLOVERRIDES="d3d12=n,b" \
    --setenv=H2R_INSTANCE="$X" \
    -- "$RUNTIME/_v2-entry-point" --verb=waitforexitandrun -- \
       "$PROTON/proton" waitforexitandrun "$TB/game/Ship/Hades2.exe" \
       --rom_modding_root_folder "Z:$ROM" "$@"
  echo "started instance $X as unit $UNIT"
  ;;
stop)
  if systemctl --user is-active --quiet "$UNIT"; then
    systemctl --user stop "$UNIT"
    echo "stopped instance $X"
  else
    echo "instance $X not running"
  fi
  ;;
status)
  state="$(systemctl --user is-active "$UNIT" 2>/dev/null)"
  echo "instance $X: ${state:-inactive}"
  ;;
esac
