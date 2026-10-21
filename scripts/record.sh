#!/usr/bin/env bash
# Record a real-game test run as video: starts the window recorder on the test
# PC (scripts/bazzite/record.sh), runs the given test command, then fetches the
# recordings and builds one video in local/videos/<name>.mp4 (two windows side
# by side, labelled, when WINDOWS=2).
#   scripts/record.sh NAME WINDOWS [LABELS] -- COMMAND [ARGS...]
#   scripts/record.sh race 2 "Player A|Player B" -- env QUEUE=1 BOARD=1 scripts/e2e-two-games.sh 3
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${BAZZITE:-bazzite.local}"
NAME="${1:?name}"; N="${2:?windows}"; shift 2
LABELS="Player A|Player B"
if [ "${1:-}" != "--" ]; then LABELS="$1"; shift; fi
[ "${1:-}" = "--" ] && shift
OUT="$ROOT/local/videos/$NAME"
mkdir -p "$OUT"
rm -f "$OUT"/*.mkv

rsync -a "$ROOT/scripts/bazzite/record.sh" "$HOST:h2r-testbed/"
ssh "$HOST" 'systemctl --user stop h2r-rec 2>/dev/null; mkdir -p ~/h2r-testbed/run;
  systemd-run --user --unit=h2r-rec --collect --quiet -p StandardOutput=append:$HOME/h2r-testbed/run/rec.out \
    -p StandardError=append:$HOME/h2r-testbed/run/rec.out bash $HOME/h2r-testbed/record.sh $HOME/h2r-testbed/run/rec '"$N"
echo "recording $N window(s); running: $*"

"$@"
STATUS=$?

ssh "$HOST" 'systemctl --user stop h2r-rec' >/dev/null 2>&1
sleep 1
rsync -a "$HOST:h2r-testbed/run/rec/" "$OUT/"

# One continuous file per window (segments start over when a window is
# recreated), and when each window started (from the first segment's name).
INPUTS=(); STARTS=()
for i in $(seq "$N"); do
  ls "$OUT"/w"$i"-*.mkv >/dev/null 2>&1 || continue
  : >"$OUT/list$i.txt"
  for f in "$OUT"/w"$i"-*.mkv; do echo "file '$f'" >>"$OUT/list$i.txt"; done
  ffmpeg -nostdin -loglevel error -y -f concat -safe 0 -i "$OUT/list$i.txt" -c copy "$OUT/w$i.mkv"
  INPUTS+=("$OUT/w$i.mkv")
  first=$(ls "$OUT"/w"$i"-*.mkv | head -1)
  STARTS+=("$(basename "$first" .mkv | cut -d- -f3)")
done
[ ${#INPUTS[@]} -gt 0 ] || { echo "no recordings"; exit 1; }
# Delay of each window behind the first one to appear (black until it opens).
DELAYS=($(python3 -c 'import sys; s=[float(x) for x in sys.argv[1:]]; print(" ".join("%.3f" % (x - min(s)) for x in s))' "${STARTS[@]}"))

# Labels as an image strip (this ffmpeg has no drawtext).
python3 - "$OUT/labels.png" "${#INPUTS[@]}" "$LABELS" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageFont
path, n, labels = sys.argv[1], int(sys.argv[2]), sys.argv[3].split("|")
w = 960 * n if n > 1 else 1280
img = Image.new("RGB", (w, 44), (18, 16, 22))
d = ImageDraw.Draw(img)
font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 24)
for i in range(n):
    d.text((i * (w // n) + 16, 9), labels[i] if i < len(labels) else f"Window {i + 1}", fill=(255, 202, 110), font=font)
img.save(path)
PY

if [ ${#INPUTS[@]} -eq 2 ]; then
  ffmpeg -nostdin -loglevel error -y -i "${INPUTS[0]}" -i "${INPUTS[1]}" -loop 1 -i "$OUT/labels.png" -filter_complex \
    "[0:v]setpts=PTS-STARTPTS,scale=960:540,setsar=1,fps=30,tpad=start_duration=${DELAYS[0]}:color=black[a];[1:v]setpts=PTS-STARTPTS,scale=960:540,setsar=1,fps=30,tpad=start_duration=${DELAYS[1]}:color=black[b];[a][b]hstack=inputs=2:shortest=0[v];[2:v]format=yuv420p[l];[l][v]vstack=inputs=2:shortest=1,format=yuv420p[out]" \
    -map "[out]" -c:v libx264 -preset medium -crf 27 -movflags +faststart "$ROOT/local/videos/$NAME.mp4"
else
  ffmpeg -nostdin -loglevel error -y -i "${INPUTS[0]}" -loop 1 -i "$OUT/labels.png" -filter_complex \
    "[0:v]scale=1280:720,setsar=1,fps=30[a];[1:v]format=yuv420p[l];[l][a]vstack=inputs=2:shortest=1,format=yuv420p[out]" \
    -map "[out]" -c:v libx264 -preset medium -crf 25 -movflags +faststart "$ROOT/local/videos/$NAME.mp4"
fi
echo "video: local/videos/$NAME.mp4 ($(du -h "$ROOT/local/videos/$NAME.mp4" | cut -f1), $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$ROOT/local/videos/$NAME.mp4" | cut -d. -f1) s)"
exit $STATUS
