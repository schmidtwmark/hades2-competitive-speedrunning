#!/usr/bin/env bash
# Record the test instances' game windows to video while they run: x11grab of
# each "Hades II" window on the gamescope Xwayland display, GPU-encoded
# (VAAPI) so the games keep their frame rate. If a window is recreated, a new
# segment starts. Runs on the test PC; stop it with `systemctl --user stop h2r-rec`.
#   record.sh OUTDIR [windows=2] [fps=30]
set -uo pipefail
OUT="${1:?outdir}"; N="${2:-2}"; FPS="${3:-30}"
export DISPLAY="${H2R_DISPLAY:-:1}"
mkdir -p "$OUT"
rm -f "$OUT"/w*.mkv

record_window() { # window index (1 = first game window created)
  local idx=$1 seg=0 id
  while :; do
    id=$(xdotool search --name 'Hades II' 2>/dev/null | sed -n "${idx}p")
    if [ -z "$id" ]; then sleep 0.25; continue; fi
    seg=$((seg + 1))
    start=$(date +%s.%N) # in the name, so windows can be lined up in time later
    # Wall-clock timestamps: grabbing can fall below FPS while two games run,
    # and the video must still play back in real time (gaps become held frames).
    ffmpeg -nostdin -loglevel error -use_wallclock_as_timestamps 1 -f x11grab -window_id "$id" -draw_mouse 0 \
      -framerate "$FPS" -i "$DISPLAY" -fps_mode passthrough \
      -vaapi_device /dev/dri/renderD128 -vf 'format=nv12,hwupload' -c:v h264_vaapi -qp 24 \
      "$OUT/w$idx-$(printf %03d "$seg")-$start.mkv"
    sleep 0.25
  done
}

for i in $(seq "$N"); do record_window "$i" & done
wait
