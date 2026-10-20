#!/usr/bin/env bash
# Capture one test instance's own game window (not the desktop) to a PNG on the Mac.
#   scripts/bazzite/capture.sh out.png [window-index]
set -euo pipefail
OUT="${1:?out.png}"; IDX="${2:-1}"
HOST="${BAZZITE:-bazzite.local}"
ssh "$HOST" "export DISPLAY=:1; id=\$(xdotool search --name 'Hades II' 2>/dev/null | sed -n '${IDX}p'); [ -n \"\$id\" ] || { echo 'no game window' >&2; exit 1; }; import -window \"\$id\" png:-" >"$OUT"
echo "captured $(wc -c <"$OUT") bytes -> $OUT"
