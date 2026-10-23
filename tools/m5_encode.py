#!/usr/bin/env python3
"""m5_encode.py -- transcode a normal video into the M5V1 format the FPGA plays.

WHY THIS FORMAT
---------------
The EG4S20 has no video decoder and the TF card is read over SPI at 5 MHz
(~0.6 MB/s), so the player needs a format that is (a) trivial to decode in RTL
and (b) small enough to stream at 15 fps.  The demo clip has a mostly static
background with a small moving subject, so a 320x240 RGB332 (3-3-2) frame with
a 2 byte token RLE shrinks to ~14 kB/frame = ~210 kB/s at 15 fps: one fifth of
what the card can deliver.

The FPGA still outputs 1280x720 and the frame buffer is still 640x480, so the
decoder nearest-neighbour upscales every source pixel 2x2 and writes a normal
640x480 page -- the rest of the M4 pipeline is untouched.

FILE LAYOUT (all fields big endian, the RTL reads bytes MSB first)
------------------------------------------------------------------
  header, 32 bytes
      0  "M5V1"           magic
      4  u16 width        = 320
      6  u16 height       = 240
      8  u16 fps          = 15
     10  u16 bpp          = 1 (RGB332) | 2 (RGB565)
     12  u32 frames
     16  u16 audio_rate   = 48000
     18  u16 audio_ch     = 1
     20  u32 first_frame  = 32      (offset of the first frame block)
     24  u32 audio_samples_total
     28  u32 reserved
  frame block, repeated `frames` times
      u32 payload_len     bytes of RLE payload that follow (incl. end token)
      u16 audio_samples   mono samples for this frame (48000/fps)
      u16 bpp2            = bpp (sanity check, keeps the block 8 byte aligned)
      RLE payload         payload_len bytes
      audio samples       audio_samples * 2 bytes, signed 16 bit, MSB first

  RLE payload: sequence of 16 bit big endian tokens, output 640*480/4 pixels
      1 = repeat   count = (tok & 0x0FFF) + 1, next bpp bytes are the pixel
      2 = literal  count = (tok & 0x0FFF) + 1, next count*bpp bytes are pixels
      0 = end of frame
  The last pixel of the frame must be produced by a normal token, the end token
  follows immediately.

USAGE
-----
  python m5_encode.py INPUT.mp4 OUT_DIR
        [--fps 15] [--width 320] [--height 240] [--crop]
  Writes OUT_DIR/VID0.M5V (put VID0.M5V in the root directory of the TF card).
  --crop (default) cuts the source to the target aspect ratio; --pad letterboxes
  it on black instead.
"""
import argparse
import os
import struct
import subprocess
import sys

import numpy as np

FFMPEG = "ffmpeg"
FFPROBE = "ffprobe"


def find_ffmpeg():
    """ffmpeg is installed by winget on this machine; find it without PATH help."""
    global FFMPEG, FFPROBE
    try:
        subprocess.run([FFMPEG, "-version"], capture_output=True, check=True)
        FFPROBE = "ffprobe"
        return
    except (FileNotFoundError, OSError):
        pass
    import glob
    pats = [
        os.path.expanduser(r"~\AppData\Local\Microsoft\WinGet\Packages"
                           r"\Gyan.FFmpeg*\**\bin\ffmpeg.exe"),
        r"C:\ffmpeg\bin\ffmpeg.exe",
        r"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
    ]
    for pat in pats:
        hits = glob.glob(pat, recursive=True)
        if hits:
            FFMPEG = hits[0]
            FFPROBE = os.path.join(os.path.dirname(hits[0]), "ffprobe.exe")
            return
    sys.exit("ffmpeg not found - install it (winget install Gyan.FFmpeg) or fix FFMPEG")


def build_vf(w, h, fps, crop):
    if crop:
        # scale to cover the target box, then centre crop
        return (f"fps={fps},scale={w}:{h}:force_original_aspect_ratio=increase,"
                f"crop={w}:{h}")
    return (f"fps={fps},scale={w}:{h}:force_original_aspect_ratio=decrease,"
            f"pad={w}:{h}:(ow-iw)/2:(oh-ih)/2:color=black")


def decode_video(src, w, h, fps, crop):
    vf = build_vf(w, h, fps, crop)
    cmd = [FFMPEG, "-v", "error", "-i", src, "-vf", vf, "-pix_fmt", "rgb24",
           "-f", "rawvideo", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    fsz = w * h * 3
    n = len(raw) // fsz
    return [raw[i * fsz:(i + 1) * fsz] for i in range(n)]


def decode_audio(src, rate, frames_per_ch, ch):
    """Return a bytearray of interleaved s16le samples, exactly what the frames need."""
    cmd = [FFMPEG, "-v", "error", "-i", src, "-vn", "-ac", str(ch),
           "-ar", str(rate), "-f", "s16le", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return bytearray(raw)


def to_rgb332(frame, w, h):
    a = np.frombuffer(frame, np.uint8).reshape(h, w, 3)
    out = ((a[:, :, 0] & 0xE0) | ((a[:, :, 1] >> 3) & 0x1C) | (a[:, :, 2] >> 6))
    return out.astype(np.uint8).tobytes()


def to_rgb565(frame, w, h):
    a = np.frombuffer(frame, np.uint8).reshape(h, w, 3).astype(np.uint16)
    v = ((a[:, :, 0] & 0xF8) << 8) | ((a[:, :, 1] & 0xFC) << 3) | (a[:, :, 2] >> 3)
    # big endian byte pairs, matching the RTL (first byte = MSB)
    return v.astype(">u2").tobytes()


def rle_encode(px, bpp):
    """16 bit tokens; returns payload including the end token.

    Runs are found with numpy (the per pixel Python loop was far too slow for
    a 19 s clip), then the run list is turned into repeat / literal tokens.
    """
    arr = np.frombuffer(px, np.uint8) if bpp == 1 else np.frombuffer(px, ">u2")
    n = len(arr)
    # start index of every run of equal values
    cuts = np.flatnonzero(arr[1:] != arr[:-1]) + 1
    starts = np.concatenate(([0], cuts))
    ends = np.concatenate((cuts, [n]))
    lens = ends - starts

    out = bytearray()

    def token(cmd, count):
        tok = (cmd << 12) | (count - 1)
        out.append(tok >> 8)
        out.append(tok & 0xFF)

    def pixel_bytes(i):
        if bpp == 1:
            return bytes((int(arr[i]),))
        v = int(arr[i])
        return bytes((v >> 8, v & 0xFF))

    i = 0
    nruns = len(lens)
    while i < nruns:
        if lens[i] >= 3:
            ln = int(lens[i])
            while ln > 0:
                take = min(ln, 4096)
                token(1, take)
                out += pixel_bytes(starts[i])
                ln -= take
            i += 1
        else:
            # gather short runs into one literal, stop before a long run
            j = i
            count = 0
            while j < nruns and lens[j] < 3 and count + int(lens[j]) <= 4096:
                count += int(lens[j])
                j += 1
            if count == 0:                       # a single 4096+ pixel run: literal
                count = min(int(lens[i]), 4096)
                j = i + 1 if count == int(lens[i]) else i
            token(2, count)
            if bpp == 1:
                out += bytes(arr[starts[i]:starts[i] + count])
            else:
                out += arr[starts[i]:starts[i] + count].astype(">u2").tobytes()
            i = j
    out.append(0)
    out.append(0)
    return out



def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("outdir")
    ap.add_argument("--fps", type=int, default=15)
    ap.add_argument("--width", type=int, default=320)
    ap.add_argument("--height", type=int, default=240)
    ap.add_argument("--bpp", type=int, default=1, choices=(1, 2))
    ap.add_argument("--pad", action="store_true", help="letterbox instead of crop")
    ap.add_argument("--no-audio", action="store_true")
    ap.add_argument("--limit-frames", type=int, default=0)
    args = ap.parse_args()

    find_ffmpeg()
    os.makedirs(args.outdir, exist_ok=True)
    w, h, fps, bpp = args.width, args.height, args.fps, args.bpp
    if 48000 % fps:
        sys.exit("fps must divide 48000 so every frame carries a whole audio chunk")

    print(f"decoding {args.input} -> {w}x{h} @ {fps} fps (bpp {bpp})")
    frames = decode_video(args.input, w, h, fps, not args.pad)
    if args.limit_frames:
        frames = frames[:args.limit_frames]
    nframes = len(frames)
    samples_per_frame = 48000 // fps
    audio = bytearray()
    if not args.no_audio:
        audio = decode_audio(args.input, 48000, samples_per_frame, 1)
        need = nframes * samples_per_frame * 2
        if len(audio) < need:
            audio.extend(b"\x00" * (need - len(audio)))
        audio = audio[:need]
    print(f"frames {nframes}, audio {len(audio)//2} samples "
          f"({len(audio)/2/48000:.2f} s), need {samples_per_frame}/frame")

    body = bytearray()
    total_rle = 0
    for idx, fr in enumerate(frames):
        px = to_rgb332(fr, w, h) if bpp == 1 else to_rgb565(fr, w, h)
        payload = rle_encode(px, bpp)
        total_rle += len(payload)
        aoff = idx * samples_per_frame * 2
        achunk = audio[aoff:aoff + samples_per_frame * 2] if audio else b""
        body += struct.pack(">IHH", len(payload), samples_per_frame, bpp)
        body += payload
        body += achunk
        if idx % 30 == 0:
            print(f"  frame {idx:4d}/{nframes}  rle {len(payload):6d} B")

    hdr = struct.pack(">4sHHHHIHHIII",
                      b"M5V1", w, h, fps, bpp, nframes,
                      48000, 1 if audio else 0, 32,
                      len(audio) // 2, 0)
    path = os.path.join(args.outdir, "VID0.M5V")
    with open(path, "wb") as f:
        f.write(hdr)
        f.write(body)
    size = os.path.getsize(path)
    per_frame = total_rle / nframes
    print()
    print(f"wrote {path}: {size/1e6:.2f} MB, {nframes} frames, "
          f"{total_rle/nframes/1024:.1f} kB video/frame")
    for clk in (5e6, 10e6, 12.5e6, 25e6):
        bps = clk / 8 * 0.8
        print(f"  stream budget at {clk/1e6:5.3g} MHz SPI = {bps/1e3:6.1f} kB/s -> "
              f"{bps/((size - 32)/nframes):4.1f} fps max")
    with open(os.path.join(args.outdir, "VID0.M5V.txt"), "w", encoding="utf-8") as f:
        f.write(f"{args.input}\nw={w} h={h} fps={fps} bpp={bpp} frames={nframes} "
                f"size={size} audio={len(audio)} bytes\n")


if __name__ == "__main__":
    main()
