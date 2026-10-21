#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_bmp.py -- 把任意图片转换成 M2 FPGA 播放器能读的 BMP
               (640x480, 24 bit, BI_RGB, 未压缩, 自底向上, 54 字节文件头)

M2 的 RTL (rtl/m2_fat_bmp.v) 只接受下面这一种 BMP，其余一律判为"坏图"并回退：

    'BM'                offset  0 ..  1
    biSize        = 40  offset 14 .. 17   (BITMAPINFOHEADER)
    biWidth       = 640 offset 18 .. 21
    biHeight      = 480 offset 22 .. 25   (+480 = 自底向上；-480 也支持)
    biBitCount    = 24  offset 28 .. 29
    biCompression = 0   offset 30 .. 33   (BI_RGB)
    bfOffBits     >= 54 offset 10 .. 13   (像素数据起点)

本脚本直接手写 BMP 头 + BGR 像素，不依赖 Pillow 的 BMP 编码器，
因此输出字节是确定的（可用 --check 复核）。

用法
    python make_bmp.py 图片1.jpg 图片2.png            # -> IMG0001.BMP IMG0002.BMP
    python make_bmp.py 图片目录 -o D:\\card            # 批量，默认从 0001 开始
    python make_bmp.py a.png --start 7                 # -> IMG0007.BMP
    python make_bmp.py a.png --fit stretch             # 拉伸而不是加黑边
    python make_bmp.py --check IMG0001.BMP             # 只校验，不转换
"""

import argparse
import os
import struct
import sys

W, H = 640, 480
ROW_BYTES = W * 3                  # 1920, 天然 4 字节对齐
PIX_BYTES = ROW_BYTES * H          # 921600
HDR_BYTES = 54
IMG_EXTS = ('.png', '.jpg', '.jpeg', '.bmp', '.gif', '.tif', '.tiff',
            '.webp', '.ppm', '.pgm', '.pcx', '.tga', '.jfif')


# --------------------------------------------------------------------------
def bmp_bytes(rgb_top_down):
    """rgb_top_down = bytes, len = 640*480*3, 行优先自上而下, RGB -> BMP bytes"""
    assert len(rgb_top_down) == PIX_BYTES, len(rgb_top_down)
    out = bytearray()
    # BITMAPFILEHEADER
    out += b'BM'
    out += struct.pack('<I', HDR_BYTES + PIX_BYTES)     # bfSize
    out += struct.pack('<HH', 0, 0)                     # bfReserved1/2
    out += struct.pack('<I', HDR_BYTES)                 # bfOffBits
    # BITMAPINFOHEADER
    out += struct.pack('<I', 40)                        # biSize
    out += struct.pack('<i', W)                         # biWidth
    out += struct.pack('<i', H)                         # biHeight (+ = bottom-up)
    out += struct.pack('<H', 1)                         # biPlanes
    out += struct.pack('<H', 24)                        # biBitCount
    out += struct.pack('<I', 0)                         # biCompression = BI_RGB
    out += struct.pack('<I', PIX_BYTES)                 # biSizeImage
    out += struct.pack('<i', 2835)                      # biXPelsPerMeter (72 dpi)
    out += struct.pack('<i', 2835)                      # biYPelsPerMeter
    out += struct.pack('<I', 0)                         # biClrUsed
    out += struct.pack('<I', 0)                         # biClrImportant
    assert len(out) == HDR_BYTES, len(out)
    # 像素：自底向上（文件里第一行是图像最后一行），每像素 B,G,R
    for y in range(H - 1, -1, -1):
        line = bytearray(rgb_top_down[y * ROW_BYTES:(y + 1) * ROW_BYTES])
        line[0::3], line[1::3], line[2::3] = line[2::3], line[1::3], line[0::3]
        out += line
    assert len(out) == HDR_BYTES + PIX_BYTES, len(out)
    return bytes(out)


def fit_rows(img, mode, bg):
    """把 PIL 图像变成 640x480 的 (r,g,b) 行列表（自上而下）"""
    from PIL import Image
    img = img.convert('RGB')
    iw, ih = img.size
    if mode == 'stretch':
        img = img.resize((W, H), Image.LANCZOS)
    elif mode == 'crop':
        s = max(W / iw, H / ih)
        nw, nh = max(W, int(round(iw * s))), max(H, int(round(ih * s)))
        img = img.resize((nw, nh), Image.LANCZOS)
        left, top = (nw - W) // 2, (nh - H) // 2
        img = img.crop((left, top, left + W, top + H))
    else:                                   # pad (默认：保持比例 + 黑边)
        s = min(W / iw, H / ih)
        nw, nh = max(1, int(round(iw * s))), max(1, int(round(ih * s)))
        img = img.resize((nw, nh), Image.LANCZOS)
        canvas = Image.new('RGB', (W, H), bg)
        canvas.paste(img, ((W - nw) // 2, (H - nh) // 2))
        img = canvas
    return img.tobytes()                    # 640*480*3 bytes, RGB, top-down


def card_instructions(outdir, first_name, count):
    bar = '=' * 74
    print()
    print(bar)
    print('下一步：把图拷到 TF 卡（FAT32）的根目录')
    print(bar)
    print('  1) 卡必须是 FAT32 格式，并且有一个 MBR 分区表（Windows 格式化默认就是）。')
    print('     Windows 资源管理器只能把 <=32 GB 的卡格式化成 FAT32；')
    print('     64 GB 及以上的卡请用 guiformat / fat32format / SD Card Formatter。')
    print('  2) 文件放在【根目录】，不要放子目录；RTL 只扫根目录。')
    print('  3) 文件名必须是 8.3 格式（<=8 字符主名 + 3 字符扩展名），')
    print('     推荐 IMG0001.BMP ... 这种；长文件名会被当成 LFN 项跳过。')
    print('  4) 本工程最多索引根目录里前 16 个 *.BMP（MAXF=16）。')
    print()
    print('  本次生成 %d 个文件，目录： %s' % (count, outdir))
    print('  第一个文件：%s' % first_name)
    print('  拷贝完成后安全弹出 -> 插到 AC208 的 TF 座 -> 上电或按 KEY2 复位')
    print('  预期：约 0.5 s 后显示第 1 张；KEY0 = 下一张，KEY1 = 上一张')
    print('  没卡 / 没 BMP / BMP 不合格 -> 自动回退显示 M1 的测试图案（绿边框渐变）')
    print(bar)


# --------------------------------------------------------------------------
def do_check(paths):
    ok = True
    print('%-46s %-6s %-9s %-9s %-4s %-6s %s' %
          ('file', 'BM', 'biSize', '640x480', 'bpp', 'comp', 'verdict'))
    for p in paths:
        try:
            with open(p, 'rb') as f:
                d = f.read(HDR_BYTES)
                size = os.path.getsize(p)
        except OSError as e:
            print('%-46s  <cannot read: %s>' % (p, e))
            ok = False
            continue
        if len(d) < HDR_BYTES:
            print('%-46s  <too short>' % p)
            ok = False
            continue
        bm = d[0:2]
        bf_off = struct.unpack('<I', d[10:14])[0]
        bi_size = struct.unpack('<I', d[14:18])[0]
        w = struct.unpack('<i', d[18:22])[0]
        h = struct.unpack('<i', d[22:26])[0]
        bpp = struct.unpack('<H', d[28:30])[0]
        comp = struct.unpack('<I', d[30:34])[0]
        good = (bm == b'BM' and bi_size == 40 and w == W and abs(h) == H and
                bpp == 24 and comp == 0 and bf_off >= HDR_BYTES and
                size >= bf_off + PIX_BYTES)
        ok &= good
        print('%-46s %-6s %-9d %-9s %-4d %-6d %s' %
              (os.path.basename(p), bm.decode('latin1'), bi_size,
               '%dx%d' % (w, h), bpp, comp,
               'OK' if good else 'REJECTED (RTL would fall back)'))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(
        description='convert images to the M2 BMP flavour (640x480, 24bpp, BI_RGB)')
    ap.add_argument('inputs', nargs='+', help='image files / directories')
    ap.add_argument('-o', '--outdir', default=None,
                    help='output directory (default: next to the first input)')
    ap.add_argument('--start', type=int, default=1, help='first number (default 1)')
    ap.add_argument('--prefix', default='IMG', help="file name prefix (default IMG)")
    ap.add_argument('--fit', choices=['pad', 'stretch', 'crop'], default='pad',
                    help='pad = keep aspect + black bars (default), '
                         'stretch = ignore aspect, crop = fill and crop')
    ap.add_argument('--bg', default='000000', help='pad colour, RRGGBB (default 000000)')
    ap.add_argument('--check', action='store_true',
                    help='only validate existing BMPs against the RTL rules')
    a = ap.parse_args()

    # 展开目录
    files = []
    for it in a.inputs:
        if os.path.isdir(it):
            for n in sorted(os.listdir(it)):
                if n.lower().endswith(IMG_EXTS):
                    files.append(os.path.join(it, n))
        else:
            files.append(it)
    if not files:
        print('no input image found')
        return 2

    if a.check:
        return do_check(files)

    try:
        from PIL import Image
    except ImportError:
        print('需要 Pillow：  %s -m pip install pillow' % sys.executable)
        return 2

    bg = tuple(int(a.bg[i:i + 2], 16) for i in (0, 2, 4))
    outdir = a.outdir or os.path.dirname(os.path.abspath(files[0])) or '.'
    os.makedirs(outdir, exist_ok=True)

    n = a.start
    made = []
    for p in files:
        name = '%s%04d.BMP' % (a.prefix, n)
        dst = os.path.join(outdir, name)
        with Image.open(p) as im:
            rows = fit_rows(im, a.fit, bg)
        data = bmp_bytes(rows)
        with open(dst, 'wb') as f:
            f.write(data)
        made.append((p, dst, len(data)))
        print('%-44s -> %-22s %8d bytes' % (os.path.basename(p), name, len(data)))
        n += 1

    print('\n%d file(s) written, %d bytes each (54 header + 640*480*3 pixel)'
          % (len(made), HDR_BYTES + PIX_BYTES))
    card_instructions(os.path.abspath(outdir),
                      os.path.basename(made[0][1]), len(made))
    # 顺手复核一遍
    do_check([m[1] for m in made])
    return 0


if __name__ == '__main__':
    sys.exit(main())
