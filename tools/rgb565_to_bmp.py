#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rgb565_to_bmp.py -- 把裸 RGB565 帧文件转成 M2 播放器能读的 BMP

为什么需要它
------------
M2/M3/M4 的 RTL (rtl/*_fat_bmp.v) 只认一种文件：带 BMP 头的 640x480 / 24 bit /
BI_RGB / 未压缩位图。裸的 RGB565 帧（640*480*2 = 614400 字节，没有文件头）会被
头校验判成"坏图"，直接回退到 M1 测试图案，所以不能直接扔进 TF 卡。

本脚本做两件事：
    1. 把每个 RGB565 像素展开成 RGB888（5/6/5 -> 8/8/8，位复制：x<<3|x>>2 等）；
    2. 用 tools/make_bmp.py 里同一个 BMP 写入函数打包成播放器格式。
转换是无损的：展开后的 RGB888 再量化回 565 一定得到原来的值，屏幕上看到的
颜色就是原来 565 的颜色。

默认按小端解释（低字节在前，C 数组 / 常见 .bin 导出的顺序）。如果你的文件是
高字节在前，加 --big-endian。

用法
    python rgb565_to_bmp.py image_1.bin image_2.bin -o D:\\card
    python rgb565_to_bmp.py C:\\...\\fpga_images -o D:\\card      # 目录下所有 *.bin
    python rgb565_to_bmp.py frame.bin -o .\\out --start 7          # -> IMG0007.BMP
    python rgb565_to_bmp.py frame.bin --big-endian
"""

import argparse
import array
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_bmp import W, H, PIX_BYTES, bmp_bytes, HDR_BYTES  # noqa: E402

RAW_BYTES = W * H * 2           # 614400


def decode_565(raw, big_endian):
    """raw(614400 B) -> RGB888 字节串, 行优先自上而下, 每像素 R,G,B"""
    a = array.array('H')
    a.frombytes(raw)
    want_little = not big_endian
    if sys.byteorder == 'big' and want_little:
        a.byteswap()
    elif sys.byteorder == 'little' and big_endian:
        a.byteswap()

    out = bytearray(PIX_BYTES)
    j = 0
    for v in a:
        r = (v >> 11) & 0x1F
        g = (v >> 5) & 0x3F
        b = v & 0x1F
        out[j]     = (r << 3) | (r >> 2)
        out[j + 1] = (g << 2) | (g >> 4)
        out[j + 2] = (b << 3) | (b >> 2)
        j += 3
    return bytes(out)


def collect(inputs):
    files = []
    for it in inputs:
        if os.path.isdir(it):
            for n in sorted(os.listdir(it)):
                if n.lower().endswith(('.bin', '.raw', '.rgb565')):
                    files.append(os.path.join(it, n))
        else:
            files.append(it)
    return files


def main():
    ap = argparse.ArgumentParser(
        description='raw RGB565 640x480 frame -> M2 player BMP (640x480 24bpp BI_RGB)')
    ap.add_argument('inputs', nargs='+', help='.bin files / directories')
    ap.add_argument('-o', '--outdir', default=None,
                    help='output directory (default: next to the first input)')
    ap.add_argument('--start', type=int, default=1, help='first number (default 1)')
    ap.add_argument('--prefix', default='IMG', help="file name prefix (default IMG)")
    ap.add_argument('--big-endian', action='store_true',
                    help='the 565 words are high byte first (default: low byte first)')
    a = ap.parse_args()

    files = collect(a.inputs)
    if not files:
        print('no .bin input found')
        return 2

    outdir = a.outdir or os.path.dirname(os.path.abspath(files[0])) or '.'
    os.makedirs(outdir, exist_ok=True)

    n = a.start
    made = []
    for p in files:
        with open(p, 'rb') as f:
            raw = f.read()
        if len(raw) != RAW_BYTES:
            print('%-42s  SKIP  size %d B (need exactly %d = 640*480*2)'
                  % (os.path.basename(p), len(raw), RAW_BYTES))
            continue
        data = bmp_bytes(decode_565(raw, a.big_endian))
        name = '%s%04d.BMP' % (a.prefix, n)
        dst = os.path.join(outdir, name)
        with open(dst, 'wb') as f:
            f.write(data)
        made.append((p, dst, len(data)))
        print('%-42s -> %-16s %8d bytes' % (os.path.basename(p), name, len(data)))
        n += 1

    if not made:
        print('\nnothing written')
        return 1

    print('\n%d file(s) written, %d bytes each (54 header + 640*480*3 pixel)'
          % (len(made), HDR_BYTES + PIX_BYTES))
    print('输出目录：%s' % os.path.abspath(outdir))
    print('把这 %d 个 IMGnnnn.BMP 拷到 FAT32 TF 卡的【根目录】，插卡上电即可。' % len(made))
    print('（转换是无损的：屏幕上就是这些 565 像素展开后的颜色）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
