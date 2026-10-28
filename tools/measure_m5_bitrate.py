#!/usr/bin/env python3
"""measure_m5_bitrate.py -- how big is an M5V1 (RGB332 + RLE) frame for a real clip?

The M5 player streams the file from the TF card over SPI at 5 MHz, so the hard
budget is about 600 kB/s.  Audio (48 kHz mono s16) already costs 96 kB/s, so the
question is what the RLE payload of a real 320x240 RGB332 frame costs and which
pre-filter (posterise / median) brings it inside the budget.

Usage:  python tools/measure_m5_bitrate.py CLIP.mp4 [--frames 60] [--fps 15]
"""
import argparse
import os
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import m5_encode as enc


def apply_filter(a, mode):
    """a: (h,w,3) uint8 -> (h,w,3) uint8"""
    if mode == "raw":
        return a
    if mode.startswith("post"):                     # poster: number of levels per ch
        levels = int(mode[4:])                      # 2,4,8
        step = 256 // levels
        return ((a // step) * step + step // 2).astype(np.uint8)
    if mode == "median":                            # 3x3 median on each channel
        p = np.pad(a, ((1, 1), (1, 1), (0, 0)), mode="edge")
        win = [p[i:i + a.shape[0], j:j + a.shape[1], :] for i in range(3) for j in range(3)]
        return np.median(np.stack(win, 0), axis=0).astype(np.uint8)
    if mode == "medpost4":
        p = np.pad(a, ((1, 1), (1, 1), (0, 0)), mode="edge")
        win = [p[i:i + a.shape[0], j:j + a.shape[1], :] for i in range(3) for j in range(3)]
        m = np.median(np.stack(win, 0), axis=0).astype(np.uint8)
        return ((m // 64) * 64 + 32).astype(np.uint8)
    raise SystemExit("unknown filter " + mode)


def to_rgb332(a):
    # m5_encode.to_rgb332 works on the raw rgb24 bytes; replicate it on arrays
    return ((a[:, :, 0] & 0xE0) | ((a[:, :, 1] >> 3) & 0x1C) | (a[:, :, 2] >> 6)).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clip")
    ap.add_argument("--frames", type=int, default=45)
    ap.add_argument("--fps", type=int, default=15)
    ap.add_argument("--w", type=int, default=320)
    ap.add_argument("--h", type=int, default=240)
    ap.add_argument("--filters", default="raw,post4,median,medpost4")
    args = ap.parse_args()

    enc.find_ffmpeg()
    frames = enc.decode_video(args.clip, args.w, args.h, args.fps, True)[:args.frames]
    print(f"{os.path.basename(args.clip)}: {len(frames)} frames {args.w}x{args.h} @{args.fps}")

    for mode in args.filters.split(","):
        sizes = []
        for fr in frames:
            a = np.frombuffer(fr, np.uint8).reshape(args.h, args.w, 3)
            a = apply_filter(a, mode)
            payload = enc.rle_encode(to_rgb332(a).tobytes(), 1)
            sizes.append(len(payload))
        s = np.array(sizes)
        aud = 48000 // args.fps * 2
        tot = s + aud
        print(f"  {mode:10s} rle avg {s.mean()/1024:6.1f} kB  "
              f"min {s.min()/1024:5.1f}  max {s.max()/1024:6.1f}  "
              f"| frame total avg {tot.mean()/1024:6.1f} kB "
              f"-> {(tot.mean()*args.fps)/1024:6.1f} kB/s at {args.fps} fps")


if __name__ == "__main__":
    main()
