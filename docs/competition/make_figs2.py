# -*- coding: utf-8 -*-
"""v2 figures: bigger type, tighter canvas so the block diagram stays legible
when it is scaled to 14 cm inside the report."""
import math
import os

from PIL import Image, ImageDraw, ImageFont

OUT = r"E:\fpga-2026\fill"
REG = r"C:\Windows\Fonts\msyh.ttc"
BOLD = r"C:\Windows\Fonts\msyhbd.ttc"
BORDER = "#2E5395"
FILL = "#EAF1FA"
FILL2 = "#FDF3E3"
TEXT = "#1B1B1B"
TITLE = "#10233F"
GREY = "#555555"


def f(size, bold=False):
    return ImageFont.truetype(BOLD if bold else REG, size)


def box(d, x, y, w, h, title, lines, fill=FILL, border=BORDER, base=23, tsize=27):
    d.rounded_rectangle([x, y, x + w, y + h], radius=8, fill=fill, outline=border, width=3)
    pad = 10
    maxw = w - 2 * pad
    s = base
    while s > 12:
        ft, fl = f(tsize if s >= base else s + 3, True), f(s)
        if all(d.textlength(t, font=fl) <= maxw for t in lines) and \
           d.textlength(title, font=ft) <= maxw:
            break
        s -= 1
    ft, fl = f(tsize, True), f(s)
    n = len(lines) + 1
    step = s + 9
    top = y + h / 2 - (n - 1) * step / 2
    d.text((x + w / 2, top), title, font=ft, fill=TITLE, anchor="mm")
    for i, t in enumerate(lines):
        d.text((x + w / 2, top + (i + 1) * step), t, font=fl, fill=TEXT, anchor="mm")


def arrow(d, p1, p2, color=BORDER, width=3):
    d.line([p1, p2], fill=color, width=width)
    ang = math.atan2(p2[1] - p1[1], p2[0] - p1[0])
    L, W = 16, 8
    x2, y2 = p2
    d.polygon([(x2, y2),
               (x2 - L * math.cos(ang) + W * math.sin(ang),
                y2 - L * math.sin(ang) - W * math.cos(ang)),
               (x2 - L * math.cos(ang) - W * math.sin(ang),
                y2 - L * math.sin(ang) + W * math.cos(ang))], fill=color)


def label(d, x, y, text, size=22, color=GREY, anchor="mm", bold=False):
    d.text((x, y), text, font=f(size, bold), fill=color, anchor=anchor)


def fig_system():
    W, H = 1460, 1010
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)

    for y, t in ((150, "存储与读取"), (330, "播放与写入"), (520, "显示与输出"), (700, "支撑与调试")):
        label(d, 20, y, t, size=24, color="#7A3E00", anchor="lm", bold=True)
        d.line([(170, y - 58), (170, y + 58)], fill="#E0E0E0", width=2)

    y1 = 95
    box(d, 190, y1, 380, 110, "TF 卡", ["FAT32 · 8.3 文件名"])
    box(d, 620, y1, 380, 110, "SPI 扇区引擎", ["400 kHz 初始化 → 12.5 MHz", "单扇区读 · 超时复位"])
    box(d, 1050, y1, 380, 110, "扇区缓冲 512 B", ["一次读入，整块使用"])

    y2 = 265
    box(d, 190, y2, 280, 130, "播放列表引擎", ["mount / 扫描 / 选条", "照片与视频混排"], fill=FILL2)
    box(d, 510, y2, 280, 130, "页写入", ["逐行 128 字突发", "只写隐藏页"])
    box(d, 830, y2, 280, 130, "簇链块流", ["按簇链吐字节", "valid / ready"], fill=FILL2)
    box(d, 1150, y2, 280, 130, "M5V1 解码", ["RLE 展开、×2 放大", "音频 48 kHz 样点"], fill=FILL2)

    y3 = 450
    box(d, 190, y3, 300, 140, "SDRAM 双页", ["两页各 307 200 字", "换页在行消隐"])
    box(d, 500, y3, 280, 140, "光栅与窗口", ["1280×720 @ 59.26 Hz", "窗口内 1 字/像素"])
    box(d, 790, y3, 280, 140, "HDMI 发送核", ["AXIS 像素 + 音频包", "LPCM 24 bit / ACR"])
    box(d, 1080, y3, 200, 140, "TMDS", ["4 lane", "366.7 MHz"])
    d.rounded_rectangle([1290, y3, 1440, y3 + 140], radius=8, fill="#F2F2F2",
                        outline="#777777", width=3)
    d.text((1365, y3 + 52), "显示器", font=f(26, True), fill=TITLE, anchor="mm")
    d.text((1365, y3 + 94), "屏幕+喇叭", font=f(21), fill=GREY, anchor="mm")

    y4 = 640
    box(d, 190, y4, 280, 130, "按键", ["S0 / S1 切换", "长按 S0 暂停"])
    box(d, 483, y4, 280, 130, "8 位数码管", ["总数 + 当前序号", "出错显示 E<n>"])
    box(d, 776, y4, 300, 130, "时钟与复位", ["100 / 73.3 / 366.7 MHz", "2FF 与 Gray FIFO"])
    box(d, 1089, y4, 340, 130, "PC 端工具链", ["片源编码 / 构建 / 烧写", "串口状态行"])

    # 层内箭头
    arrow(d, (572, y1 + 55), (618, y1 + 55))
    arrow(d, (1002, y1 + 55), (1048, y1 + 55))
    arrow(d, (1120, y2 + 65), (1148, y2 + 65))
    # 扇区缓冲 -> 四个模块（总线式）
    d.line([(1240, y1 + 112), (1240, 240)], fill="#7A3E00", width=3)
    d.line([(330, 240), (1240, 240)], fill="#7A3E00", width=3)
    for xd in (330, 650, 970, 1290):
        arrow(d, (xd, 240), (xd, y2 - 2), color="#7A3E00")
    # 两条支路 -> 总线 -> SDRAM
    d.line([(650, y2 + 132), (650, 435), (1290, 435), (1290, y2 + 132)], fill="#7A3E00", width=3)
    d.line([(340, 435), (650, 435)], fill="#7A3E00", width=3)
    arrow(d, (340, 435), (340, y3 - 2), color="#7A3E00")
    # 显示链
    arrow(d, (492, y3 + 70), (498, y3 + 70))
    arrow(d, (782, y3 + 70), (788, y3 + 70))
    arrow(d, (1072, y3 + 70), (1078, y3 + 70))
    arrow(d, (1282, y3 + 70), (1288, y3 + 70))

    d.line([(20, 830), (1440, 830)], fill="#E0E0E0", width=2)
    label(d, 20, 870, "数据流：TF 卡 → 扇区引擎 → 扇区缓冲 →（照片）页写入 /（视频）簇链块流 + 解码 "
                      "→ 双页帧缓存 → 光栅窗口 → HDMI 核 → TMDS → 屏幕",
          size=22, color="#10233F", anchor="lm")
    label(d, 20, 930, "控制与支撑：按键、数码管挂在播放列表引擎上；时钟复位与 PC 工具链用于开发调试。"
                      "音频不经过帧缓存。", size=22, anchor="lm")
    img.save(os.path.join(OUT, "fig_system.png"))
    print("fig_system.png", img.size)


def fig_flow():
    W, H = 1300, 760
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)
    box(d, 60, 60, 360, 130, "① 需求与规格", ["分辨率 / 帧率 / 片源格式", "按键与显示怎么给"])
    box(d, 470, 60, 360, 130, "② RTL 设计", ["状态机全部手写", "不用软核与解码芯片"])
    box(d, 880, 60, 360, 130, "③ Python 周期级模型", ["FAT32 / 双页 SDRAM / 交互", "先跑通时序再写板子"])
    box(d, 880, 420, 360, 130, "④ 上板验证", ["先 SRAM 试，再写 SPI Flash", "看屏、听声、读数码管"])
    box(d, 470, 420, 360, 130, "⑤ 脚本化构建", ["make_proj_files + build.ps1", "TD 2026.1 SP2"])
    box(d, 60, 420, 360, 130, "⑥ 可观测性", ["串口状态行 / 数码管窗口", "现象变读数"])
    arrow(d, (422, 125), (468, 125))
    arrow(d, (832, 125), (878, 125))
    d.line([(1060, 192), (1060, 418)], fill=BORDER, width=3)
    arrow(d, (1060, 404), (1060, 418))
    arrow(d, (878, 485), (832, 485))
    arrow(d, (468, 485), (422, 485))
    arrow(d, (240, 418), (240, 192))
    label(d, 1060, 300, "看屏、听声", size=22)
    label(d, 240, 300, "读数反推设计", size=22)
    label(d, 650, 300, "每个阶段：能编译、能上板、有文档", size=23, color=TITLE, bold=True)
    d.line([(60, 600), (1240, 600)], fill="#E0E0E0", width=2)
    label(d, 60, 645, "两次独立全清编译比对 bit payload 与 CRC，保证「文档参数」就是「烧进板子的 bit」。",
          size=22, anchor="lm")
    label(d, 60, 700, "没有逻辑分析仪，可疑时序先在 Python 模型里跑一遍，再用串口/数码管读回来对号。",
          size=22, anchor="lm")
    img.save(os.path.join(OUT, "fig_flow.png"))
    print("fig_flow.png", img.size)


def fig_pages():
    W, H = 1300, 620
    img = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([70, 80, 640, 210], radius=8, fill=FILL, outline=BORDER, width=3)
    d.text((355, 118), "页 A   0x000000 – 0x04AFFF", font=f(27, True), fill=TITLE, anchor="mm")
    d.text((355, 168), "307 200 字 = 640×480 像素", font=f(23), fill=GREY, anchor="mm")
    d.rounded_rectangle([70, 270, 640, 400], radius=8, fill=FILL2, outline="#B5651D", width=3)
    d.text((355, 308), "页 B   0x04B000 – 0x095FFF", font=f(27, True), fill=TITLE, anchor="mm")
    d.text((355, 358), "同样 307 200 字，与页 A 首尾相接", font=f(23), fill=GREY, anchor="mm")
    for y, txt, col in ((145, "第 N 帧", BORDER), (335, "第 N+1 帧", "#B5651D")):
        d.rounded_rectangle([750, y - 40, 990, y + 40], radius=8, fill="white", outline=col, width=3)
        d.text((870, y), txt, font=f(26, True), fill=col, anchor="mm")
    arrow(d, (642, 145), (746, 145))
    arrow(d, (992, 145), (1180, 145))
    arrow(d, (1180, 145), (1180, 335), color="#B5651D")
    arrow(d, (1180, 335), (992, 335), color="#B5651D")
    arrow(d, (642, 335), (746, 335), color="#B5651D")
    label(d, 1250, 240, "写口连续写\n不按行等待", size=23, color=TITLE)
    d.line([(70, 470), (1230, 470)], fill="#E0E0E0", width=2)
    label(d, 70, 515, "显示侧每帧读当前页 307 200 字，写入的永远是「没在显示」的那一页，换页在行消隐里完成。",
          size=22, anchor="lm")
    label(d, 70, 570, "一帧 = 2400 个 128 字突发，帧边界天然落在页边界上，连续写不会把两帧搅在一起。",
          size=22, anchor="lm")
    img.save(os.path.join(OUT, "fig_pages.png"))
    print("fig_pages.png", img.size)


fig_system()
fig_flow()
fig_pages()
