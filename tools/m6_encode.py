#!/usr/bin/env python3
"""m6_encode.py -- transcode a clip into the M5V1 format for the M6 playlist player.

Same container / RLE as tools/m5_encode.py (the M5 decoder is reused verbatim in
M6), but two differences that a *real world* clip needs:

  * per frame adaptive quality.  A photo-like frame of real footage RLE-codes to
    ~47 kB at 320x240 RGB332, i.e. 47 kB * 15 fps = 705 kB/s - more than the TF
    card delivers over SPI.  Every frame is therefore tested against a byte
    budget and, if it does not fit, re-quantised (4 levels per channel, then
    median + 4 levels, then 2 levels) until it does.  Smooth/static frames stay
    lossless RGB332.
  * the output file name is an 8.3 video name (VIDnnnn.M5V), because the M6
    playlist sorts IMGnnnn.BMP / VIDnnnn.M5V by the four digit number.

Budget reference (measured on this board): the SPI sector read is 820 us for
512 bytes at 5 MHz and 410 us at 10 MHz, so the stream ceiling is ~0.6 MB/s and
~1.1 MB/s.  M6 runs the card at 10 MHz and keeps video+audio below 60 % of it.

USAGE
    python tools/m6_encode.py INPUT.mp4 OUT_DIR --name VID0005.M5V
           [--fps 15] [--width 320] [--height 240] [--max-kb 50]
"""
import argparse
import os
import struct
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import m5_encode as enc


def quantise(a, levels):
    """Reduce every channel to `levels` evenly spaced values (2, 4, 8)."""
    step = 256 // levels
    return ((a // step) * step + step // 2).astype(np.uint8)


def median3(a):
    p = np.pad(a, ((1, 1), (1, 1), (0, 0)), mode="edge")
    h, w = a.shape[0], a.shape[1]
    win = [p[i:i + h, j:j + w, :] for i in range(3) for j in range(3)]
    return np.median(np.stack(win, 0), axis=0).astype(np.uint8)


#  candidate chain: first one under the budget wins
VARIANTS = (
    ("rgb332", lambda a: a),
    ("q4",     lambda a: quantise(a, 4)),
    ("medq4",  lambda a: quantise(median3(a), 4)),
    ("q2",     lambda a: quantise(a, 2)),
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("outdir")
    ap.add_argument("--name", default="VID0005.M5V")
    ap.add_argument("--fps", type=int, default=15)
    ap.add_argument("--width", type=int, default=320)
    ap.add_argument("--height", type=int, default=240)
    ap.add_argument("--max-kb", type=float, default=50.0)
    ap.add_argument("--limit-frames", type=int, default=0)
    args = ap.parse_args()

    enc.find_ffmpeg()
    os.makedirs(args.outdir, exist_ok=True)
    w, h, fps = args.width, args.height, args.fps
    if 48000 % fps:
        sys.exit("fps must divide 48000")
    budget = int(args.max_kb * 1024)

    print(f"decoding {os.path.basename(args.input)} -> {w}x{h} @ {fps} fps")
    frames = enc.decode_video(args.input, w, h, fps, True)
    if args.limit_frames:
        frames = frames[:args.limit_frames]
    n = len(frames)
    spf = 48000 // fps
    audio = enc.decode_audio(args.input, 48000, spf, 1)
    need = n * spf * 2
    if len(audio) < need:
        audio.extend(b"\x00" * (need - len(audio)))
    audio = audio[:need]
    print(f"{n} frames, {len(audio)//2} audio samples ({len(audio)/2/48000:.2f} s)")

    body = bytearray()
    sizes = np.zeros(n, dtype=np.int64)
    hits = {k: 0 for k, _ in VARIANTS}
    for i, fr in enumerate(frames):
        a0 = np.frombuffer(fr, np.uint8).reshape(h, w, 3)
        payload = None
        for tag, fn in VARIANTS:
            px = enc.to_rgb332(fn(a0), w, h)
            payload = enc.rle_encode(px, 1)
            if len(payload) <= budget:
                hits[tag] += 1
                break
        sizes[i] = len(payload)
        body += struct.pack(">IHH", len(payload), spf, 1)
        body += payload
        body += audio[i * spf * 2:(i + 1) * spf * 2]
        if i % 60 == 0:
            print(f"  frame {i:4d}/{n}  rle {len(payload):6d} B")

    hdr = struct.pack(">4sHHHHIHHIII", b"M5V1", w, h, fps, 1, n,
                      48000, 1, 32, len(audio) // 2, 0)
    path = os.path.join(args.outdir, args.name)
    with open(path, "wb") as f:
        f.write(hdr)
        f.write(body)
    total = os.path.getsize(path)
    frame_bytes = (total - 32) / n
    aud = spf * 2
    print()
    print(f"wrote {path}: {total/1e6:.2f} MB, {n} frames, "
          f"{frame_bytes/1024:.1f} kB/frame incl. {aud/1024:.1f} kB audio")
    print(f"  payload  avg {sizes.mean()/1024:5.1f} kB  min {sizes.min()/1024:5.1f}  "
          f"max {sizes.max()/1024:5.1f}  (>budget: {int((sizes>budget).sum())})")
    print(f"  variants {hits}")
    for clk in (5e6, 10e6):
        bps = clk / 8 * 0.8
        print(f"  at {clk/1e6:4.1f} MHz SPI ({bps/1e3:6.1f} kB/s): "
              f"{frame_bytes*fps/1024:6.1f} kB/s needed = "
              f"{frame_bytes*fps/1024/(bps/1024)*100:5.1f} % of the link")
    with open(path + ".txt", "w", encoding="utf-8") as f:
        f.write(f"{args.input}\nw={w} h={h} fps={fps} frames={n} size={total} "
                f"audio={len(audio)} avg_payload={sizes.mean():.0f}\n")


if __name__ == "__main__":
    main()
