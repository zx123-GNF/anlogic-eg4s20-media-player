#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""生成 M2/M3/M4 上板用的 640x480 24-bit BMP 测试图（放到 TF 卡根目录）。

用法：
    python tools/make_demo_images.py                 # 默认输出到 demo/
    python tools/make_demo_images.py -o D:\\我的测试图

生成 6 张：色条+十字线 / 灰阶+彩色渐变 / 网格棋盘 / RGB 三色块 /
大号图号 1..6 / 文字说明图。全部 640x480、24-bit、无压缩 BMP（BGR、自底向上），
正好符合 M2 的 FAT32+BMP 解析支持范围。
"""
import argparse
import os
import struct

W, H = 640, 480


def _font(size):
    from PIL import ImageFont
    try:
        return ImageFont.load_default(size=size)
    except TypeError:  # 老版本 Pillow 没有 size 参数
        return ImageFont.load_default()


def save_bmp(img, path):
    """用 PIL 存 24-bit BMP，并回读校验头字段。"""
    img = img.convert("RGB")
    img.save(path, format="BMP")
    with open(path, "rb") as f:
        head = f.read(30)
    assert head[0:2] == b"BM", "不是 BMP"
    off = struct.unpack_from("<I", head, 10)[0]
    bpp = struct.unpack_from("<H", head, 28)[0]
    w = struct.unpack_from("<i", head, 18)[0]
    h = struct.unpack_from("<i", head, 22)[0]
    if (w, h, bpp) != (W, H, 24):
        raise RuntimeError(f"{path}: 头字段不对 {(w, h, bpp)}")
    return off


def img_bars():
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(img)
    cols = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
            (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]
    bw = W // len(cols)
    for i, c in enumerate(cols):
        d.rectangle([i * bw, 0, (i + 1) * bw - 1, H], fill=c)
    d.line([(W // 2, 0), (W // 2, H - 1)], fill=(128, 128, 128))
    d.line([(0, H // 2), (W - 1, H // 2)], fill=(128, 128, 128))
    d.rectangle([0, 0, W - 1, H - 1], outline=(128, 128, 128))
    return img


def img_gray():
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(img)
    # 上半：16 级灰阶
    for i in range(16):
        v = i * 17
        d.rectangle([i * 40, 0, (i + 1) * 40 - 1, H // 2 - 1], fill=(v, v, v))
    # 下半：RGB 三通道渐变
    for x in range(W):
        v = x * 255 // (W - 1)
        d.line([(x, H // 2), (x, H // 2 + H // 6)], fill=(v, 0, 0))
        d.line([(x, H // 2 + H // 6), (x, H // 2 + 2 * H // 6)], fill=(0, v, 0))
        d.line([(x, H // 2 + 2 * H // 6), (x, H // 2 + 3 * H // 6 - 1)], fill=(0, 0, v))
    return img


def img_grid():
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (W, H), (16, 16, 48))
    d = ImageDraw.Draw(img)
    step = 40
    for x in range(0, W, step):
        d.line([(x, 0), (x, H - 1)], fill=(60, 60, 90))
    for y in range(0, H, step):
        d.line([(0, y), (W - 1, y)], fill=(60, 60, 90))
    for y in range(0, H // step):
        for x in range(0, W // step):
            if (x + y) % 2 == 0:
                d.rectangle([x * step, y * step, x * step + step - 1, y * step + step - 1],
                            fill=(120, 120, 160))
    return img


def img_rgb():
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W // 3 - 1, H - 1], fill=(255, 0, 0))
    d.rectangle([W // 3, 0, 2 * W // 3 - 1, H - 1], fill=(0, 255, 0))
    d.rectangle([2 * W // 3, 0, W - 1, H - 1], fill=(0, 0, 255))
    return img


def img_number(n):
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W - 1, H - 1], outline=(255, 255, 255), width=4)
    f = _font(320)
    s = str(n)
    box = d.textbbox((0, 0), s, font=f)
    d.text(((W - (box[2] - box[0])) // 2, (H - (box[3] - box[1])) // 2 - box[1]),
           s, font=f, fill=(255, 255, 0))
    return img


def img_text():
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (W, H), (8, 24, 48))
    d = ImageDraw.Draw(img)
    lines = ["FPGA HDMI 640x480", "AC208 / EG4S20BG256",
             "TF: FAT32 + IMGnnnn.BMP", "M0-M4 build OK"]
    f = _font(40)
    y = 80
    for t in lines:
        box = d.textbbox((0, 0), t, font=f)
        d.text(((W - (box[2] - box[0])) // 2, y), t, font=f, fill=(230, 230, 255))
        y += 80
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "demo"))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    imgs = [(1, img_bars), (2, img_gray), (3, img_grid), (4, img_rgb),
            (5, lambda: img_number(5)), (6, img_text)]
    for i, fn in imgs:
        path = os.path.join(args.out, f"IMG{i:04d}.BMP")
        off = save_bmp(fn(), path)
        print(f"OK {path}  ({os.path.getsize(path)} bytes, pixel data @ {off})")
    print("\n把 IMG0001.BMP ~ IMG0006.BMP 拷到 FAT32 格式化的 TF 卡根目录即可（总数不要超过 16）。")


if __name__ == "__main__":
    main()
