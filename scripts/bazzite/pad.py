#!/usr/bin/env python3
"""Virtual gamepad (Xbox layout) for real-input UI tests on the test PC.

The game sees it like a plugged-in pad (uinput -> evdev -> SDL in Proton), so
tests can drive screens with the same input a player uses, no keyboard/mouse.

  pad.py serve FIFO          create the pad and run commands written to FIFO
  pad.py send FIFO CMD...    write commands to a running pad

Commands (space separated): a b x y lb rb start back guide ls rs
  up down left right (d-pad), stick:DX,DY,SECONDS (left stick, -1..1),
  wait:SECONDS, hold:BUTTON,SECONDS
"""
import os
import sys
import time

from evdev import AbsInfo, UInput
from evdev import ecodes as e

BUTTONS = {
    "a": e.BTN_SOUTH, "b": e.BTN_EAST, "x": e.BTN_WEST, "y": e.BTN_NORTH,
    "lb": e.BTN_TL, "rb": e.BTN_TR, "back": e.BTN_SELECT, "start": e.BTN_START,
    "guide": e.BTN_MODE, "ls": e.BTN_THUMBL, "rs": e.BTN_THUMBR,
}
DPAD = {"up": (e.ABS_HAT0Y, -1), "down": (e.ABS_HAT0Y, 1), "left": (e.ABS_HAT0X, -1), "right": (e.ABS_HAT0X, 1)}
TAP = 0.08
GAP = 0.25


def make_pad():
    stick = AbsInfo(value=0, min=-32768, max=32767, fuzz=16, flat=128, resolution=0)
    trigger = AbsInfo(value=0, min=0, max=255, fuzz=0, flat=0, resolution=0)
    hat = AbsInfo(value=0, min=-1, max=1, fuzz=0, flat=0, resolution=0)
    caps = {
        e.EV_KEY: list(BUTTONS.values()),
        e.EV_ABS: [(e.ABS_X, stick), (e.ABS_Y, stick), (e.ABS_RX, stick), (e.ABS_RY, stick),
                   (e.ABS_Z, trigger), (e.ABS_RZ, trigger), (e.ABS_HAT0X, hat), (e.ABS_HAT0Y, hat)],
    }
    # Not an Xbox VID/PID: Steam Input would claim that and expose its own
    # virtual pad instead, which stays silent for games Steam didn't launch
    # (and Proton then hides the real device). Steam leaves generic pads alone
    # by default, so Proton/SDL reads this one directly.
    return UInput(caps, name="H2R Test Gamepad", vendor=0x1209, product=0x4832,
                  version=0x111, bustype=e.BUS_USB)


def run(pad, cmd):
    if cmd in BUTTONS:
        cmd = "hold:%s,%s" % (cmd, TAP)
    if cmd in DPAD:
        axis, v = DPAD[cmd]
        pad.write(e.EV_ABS, axis, v); pad.syn(); time.sleep(TAP)
        pad.write(e.EV_ABS, axis, 0); pad.syn()
    elif cmd.startswith("hold:"):
        name, secs = cmd[5:].split(",")
        pad.write(e.EV_KEY, BUTTONS[name], 1); pad.syn(); time.sleep(float(secs))
        pad.write(e.EV_KEY, BUTTONS[name], 0); pad.syn()
    elif cmd.startswith("stick:"):
        dx, dy, secs = (float(v) for v in cmd[6:].split(","))
        pad.write(e.EV_ABS, e.ABS_X, int(dx * 32767)); pad.write(e.EV_ABS, e.ABS_Y, int(dy * 32767)); pad.syn()
        time.sleep(secs)
        pad.write(e.EV_ABS, e.ABS_X, 0); pad.write(e.EV_ABS, e.ABS_Y, 0); pad.syn()
    elif cmd.startswith("wait:"):
        time.sleep(float(cmd[5:]))
        return
    else:
        print("pad: unknown command %r" % cmd, flush=True)
        return
    print("pad: " + cmd, flush=True)
    time.sleep(GAP)


def serve(fifo):
    if not os.path.exists(fifo):
        os.mkfifo(fifo)
    pad = make_pad()
    print("pad: ready on " + fifo, flush=True)
    while True:
        with open(fifo) as f:  # blocks until a writer connects
            for line in f:
                for cmd in line.split():
                    run(pad, cmd)


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "serve":
        serve(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "send":
        with open(sys.argv[2], "w") as f:
            f.write(" ".join(sys.argv[3:]) + "\n")
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
