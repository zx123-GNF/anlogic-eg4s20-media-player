# -*- coding: utf-8 -*-
"""Fill the competition template with the EG4S20 player content.

The template (paragraph order, styles, numbering, header logo, page setup) is
kept exactly as it is: placeholder instruction lines are rewritten in place,
extra body paragraphs are clones of the template's own body paragraph, and
tables/figures are inserted between them.
"""
import copy
import os

from docx import Document
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt

TPL = r"C:\Users\31860\Desktop\2658aa94-81d0-454c-b2ac-fc040ff2c01a.docx"
OUT = r"C:\Users\31860\Desktop\安路赛道第1题_作品报告_图文混排多媒体播放器.docx"
FIG = r"E:\fpga-2026\fill"

doc = Document(TPL)
paras = [p._p for p in doc.paragraphs]      # snapshot: element refs stay valid
BODY_TPL = paras[7]                          # body paragraph: List Paragraph, ind 420

# --------------------------------------------------------------------------
# low level helpers
# --------------------------------------------------------------------------


def make_rpr(size=24, bold=False, color=None):
    rPr = OxmlElement("w:rPr")
    rf = OxmlElement("w:rFonts")
    rf.set(qn("w:ascii"), "Times New Roman")
    rf.set(qn("w:hAnsi"), "Times New Roman")
    rf.set(qn("w:eastAsia"), "宋体")
    rf.set(qn("w:cs"), "Times New Roman")
    rf.set(qn("w:hint"), "eastAsia")
    rPr.append(rf)
    if bold:
        rPr.append(OxmlElement("w:b"))
    if color:
        c = OxmlElement("w:color")
        c.set(qn("w:val"), color)
        rPr.append(c)
    for tag in ("w:sz", "w:szCs"):
        e = OxmlElement(tag)
        e.set(qn("w:val"), str(size))
        rPr.append(e)
    return rPr


def set_text(el, text, size=24, bold=False, color=None):
    for child in list(el):
        if child.tag in (qn("w:r"), qn("w:hyperlink")):
            el.remove(child)
    r = OxmlElement("w:r")
    r.append(make_rpr(size, bold, color))
    t = OxmlElement("w:t")
    t.set(qn("xml:space"), "preserve")
    t.text = text
    r.append(t)
    el.append(r)


def new_par_after(anchor, text="", size=24, bold=False, center=False):
    el = copy.deepcopy(BODY_TPL)
    for child in list(el):
        if child.tag in (qn("w:r"), qn("w:hyperlink"), qn("w:bookmarkStart"),
                         qn("w:bookmarkEnd"), qn("w:pPr")):
            el.remove(child)
    pPr = copy.deepcopy(BODY_TPL.find(qn("w:pPr")))
    # drop any numbering / keep indent from the body template
    for tag in ("w:numPr",):
        e = pPr.find(qn(tag))
        if e is not None:
            pPr.remove(e)
    el.insert(0, pPr)
    if center:
        jc = OxmlElement("w:jc")
        jc.set(qn("w:val"), "center")
        pPr.append(jc)
        ind = pPr.find(qn("w:ind"))
        if ind is not None:
            pPr.remove(ind)
    set_text(el, text, size=size, bold=bold)
    anchor.addnext(el)
    return el


def add_body(anchor, texts, size=24, gap_after=True):
    """Insert a list of body paragraphs after `anchor`; returns last element."""
    cur = anchor
    for t in texts:
        cur = new_par_after(cur, t, size=size)
    if gap_after:
        cur = new_par_after(cur, "", size=size)
    return cur


def delete_par(el):
    parent = el.getparent()
    if parent is not None:
        parent.remove(el)


def caption_before(anchor_next, text, size=21):
    """Return a caption element to insert before a table/figure."""
    cap = new_par_after(anchor_next, text, size=size, center=True)
    keep_next(cap)
    return cap


def add_table(anchor, headers, rows, widths, caption, font=21):
    """Create 表 with caption above, after `anchor`. Returns last element."""
    cap = new_par_after(anchor, caption, size=font, center=True)
    tbl = doc.add_table(rows=1, cols=len(headers))
    tbl.alignment = WD_TABLE_ALIGNMENT.CENTER
    tbl.autofit = False
    tblPr = tbl._tbl.tblPr
    borders = OxmlElement("w:tblBorders")
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        e = OxmlElement("w:" + edge)
        e.set(qn("w:val"), "single")
        e.set(qn("w:sz"), "6")
        e.set(qn("w:space"), "0")
        e.set(qn("w:color"), "7F7F7F")
        borders.append(e)
    tblPr.append(borders)
    for i, h in enumerate(headers):
        cell = tbl.rows[0].cells[i]
        cell.text = ""
        p = cell.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        r = OxmlElement("w:r")
        r.append(make_rpr(font, bold=True))
        t = OxmlElement("w:t")
        t.text = h
        r.append(t)
        p._p.append(r)
        tcPr = cell._tc.get_or_add_tcPr()
        shd = OxmlElement("w:shd")
        shd.set(qn("w:val"), "clear")
        shd.set(qn("w:fill"), "F2F2F2")
        tcPr.append(shd)
    for row in rows:
        cells = tbl.add_row().cells
        for i, v in enumerate(row):
            cells[i].text = ""
            p = cells[i].paragraphs[0]
            p.alignment = WD_ALIGN_PARAGRAPH.LEFT if i else WD_ALIGN_PARAGRAPH.CENTER
            r = OxmlElement("w:r")
            r.append(make_rpr(font))
            t = OxmlElement("w:t")
            t.set(qn("xml:space"), "preserve")
            t.text = str(v)
            r.append(t)
            p._p.append(r)
    total = sum(widths)
    scale = 14.4 / total if total > 14.4 else 1.0
    wcm = [w * scale for w in widths]
    tblPr2 = tbl._tbl.tblPr
    layout = OxmlElement("w:tblLayout")
    layout.set(qn("w:type"), "fixed")
    tblPr2.append(layout)
    tblW = OxmlElement("w:tblW")
    tblW.set(qn("w:w"), str(int(sum(wcm) * 567)))
    tblW.set(qn("w:type"), "dxa")
    tblPr2.append(tblW)
    grid = tbl._tbl.find(qn("w:tblGrid"))
    if grid is not None:
        for gc, w in zip(grid.findall(qn("w:gridCol")), wcm):
            gc.set(qn("w:w"), str(int(w * 567)))
    for i, w in enumerate(wcm):
        for row in tbl.rows:
            row.cells[i].width = Cm(w)
    for row in tbl.rows:
        for cell in row.cells:
            for p in cell.paragraphs:
                pf = p.paragraph_format
                pf.line_spacing = 1.0
                pf.space_before = Pt(1)
                pf.space_after = Pt(1)
    # header row repeats, rows do not split
    trPr = tbl.rows[0]._tr.get_or_add_trPr()
    hdr = OxmlElement("w:tblHeader")
    trPr.append(hdr)
    for row in tbl.rows:
        trPr = row._tr.get_or_add_trPr()
        trPr.append(OxmlElement("w:cantSplit"))
    for row in tbl.rows[:-1]:
        for cell in row.cells:
            for p in cell.paragraphs:
                pPr = p._p.find(qn("w:pPr"))
                if pPr is None:
                    pPr = OxmlElement("w:pPr")
                    p._p.insert(0, pPr)
                if pPr.find(qn("w:keepNext")) is None:
                    pPr.append(OxmlElement("w:keepNext"))
    cap.addnext(tbl._tbl)
    last = tbl._tbl
    last = new_par_after(last, "", size=font)
    return last


def add_figure(anchor, img, width_cm, caption, font=21):
    el = new_par_after(anchor, "", center=True)
    from docx.text.paragraph import Paragraph
    p = Paragraph(el, doc.paragraphs[0]._parent)
    p.add_run().add_picture(os.path.join(FIG, img), width=Cm(width_cm))
    cap = new_par_after(el, caption, size=font, center=True)
    return new_par_after(cap, "", size=font)


def keep_next(el):
    pPr = el.find(qn("w:pPr"))
    if pPr is None:
        pPr = OxmlElement("w:pPr")
        el.insert(0, pPr)
    if pPr.find(qn("w:keepNext")) is None:
        pPr.append(OxmlElement("w:keepNext"))


def fill_section(anchor, texts, size=24):
    """Replace the template instruction line with the first paragraph, add the rest."""
    set_text(anchor, texts[0], size=size)
    return add_body(anchor, texts[1:], size=size)
KEEP_NEXT_IDX = [5, 24, 39, 50, 58, 6, 9, 12, 15, 18, 21, 27, 30, 35, 41, 43, 48, 53, 55]
for _i in KEEP_NEXT_IDX:
    keep_next(paras[_i])

# --------------------------------------------------------------------------
# 作品名称 / 标题区
# --------------------------------------------------------------------------
set_text(paras[0], "基于 EG4S20 的图文混排多媒体播放器", size=36, bold=False)
delete_par(paras[1])

# --------------------------------------------------------------------------
# 摘要
# --------------------------------------------------------------------------
ABSTRACT = [
    "出发点是：一块 FPGA、一张 TF 卡、一台普通显示器，能不能自己把卡里的照片和视频放出来，还要有声音。"
    "整机没有处理器核，也没有视频解码芯片，全部由 FPGA 内部手写的状态机完成。",

    "EG4S20 内部塞了四套东西：SPI 读卡器、自写的 FAT32 文件系统、两个播放引擎（照片走 BMP 逐行写入，视频走"
    "自己定义的 M5V1 帧内 RLE 解码），以及一条 1280×720 的 HDMI 输出链路。片内 8 MB SDRAM 划成两页 640×480 "
    "帧缓存，写一页、显示另一页，换页放在行消隐里；声音不经过帧缓存，48 kHz 样点直接送进 HDMI 音频包。",

    "用户看到的是一台不需要电脑的播放器。插卡上电两秒左右出第一张照片，之后每三秒换一张；照片放完自动接上视频，"
    "显示器自带的喇叭出声；一段放完接下一段，全部放完回到第一张循环。S0、S1 随时可以手动切换，长按 S0 一秒是"
    "暂停，暂停状态下还能逐项翻看，视频也能被切出来播放。八位数码管左半边是总条数、右半边是当前第几条，"
    "出错显示错误码。",

    "关键数字：输出 1280×720、59.26 Hz；照片 640×480 二十四位 BMP，装一张约 0.6 秒；视频 320×240 彩色 8 位、"
    "15 帧每秒，解码后 2×2 放大到 640×480，码率控制在卡速的一半左右；声音 48 kHz 单声道。整机占用 LUT 39.3%、"
    "BRAM 33 块，100 MHz 建立余量 +0.102 ns。bit 已经写进 SPI 配置 Flash，断电重启自己跑起来。",

    "开发中的取舍写在正文里：自己定片源格式并配了带逐帧字节预算的编码器，先写 Python 周期级模型再写 RTL，"
    "把串口、数码管、LED 都做成能读内部状态的窗口。",
]
fill_section(paras[3], ABSTRACT)

# --------------------------------------------------------------------------
# 第二 / 第三部分 的模板引导语（原来是红字提示，改成正常正文）
# --------------------------------------------------------------------------
set_text(paras[25], "这一部分按“整体—硬件—软件”三层展开：先给系统框图和各模块之间的关系，"
                    "再讲硬件接口，最后逐个说明软件模块的实现。")
set_text(paras[40], "这一部分用实物照片和测试数据说明完成情况：先看整机实物，再看工程成果和逐项功能验证。")

# --------------------------------------------------------------------------
# 1.1 功能与特性
# --------------------------------------------------------------------------
FUNC = [
    "一句话概括：插卡上电就能自己播放的多媒体播放器。",

    "照片播放。读根目录里 640×480 二十四位 BMP，整页写进没在显示的那一页，写完在行消隐里换页，"
    "所以换图是一下子跳过去的，看不到刷屏。",

    "视频播放。播放自己定义的 M5V1 文件：320×240 彩色 8 位帧经 RLE 压缩存在卡上，解码器逐帧展开、2×2 放大、"
    "按 15 帧每秒连续写进帧缓存；自带 48 kHz 单声道音轨，从显示器喇叭出声。",

    "混排播放列表。一次目录扫描同时收照片和视频，按文件名里的编号排序，两种条目在同一个序列里循环，"
    "不需要先切模式再播。",

    "按键交互。S0、S1 短按切换上一条下一条，长按 S0 一秒暂停或恢复；暂停时短按可以逐项浏览，"
    "视频也能被切出来播放，播完停在最后一帧。",

    "状态显示与自启动。数码管显示总条数和当前序号，出错显示错误码，四颗 LED 指示挂载、错误、忙碌、"
    "是否在放视频；bit 固化在 SPI Flash 里，上电约两秒出画面。",
]
fill_section(paras[7], FUNC)

# --------------------------------------------------------------------------
# 1.2 应用领域
# --------------------------------------------------------------------------
APP = [
    "这块板子没有操作系统，启动快、状态确定，更适合当“设备里的一小块显示子系统”，而不是去替代通用播放器。",

    "工业与仪器面板。设备开机动画、操作提示、故障演示短片，用几张照片加几段短视频就够；改内容只要换 TF 卡里的"
    "文件，不用重新烧固件，也不用拆机。",

    "展厅与门店广告机。成本低，一块 FPGA 加一块屏；没有系统可崩，断电恢复后自动接着播，不会像小主机那样"
    "卡在开机 logo 上等人处理。",

    "教学与实验平台。从 SPI 读卡、FAT32、BMP 解析、RLE 解码、SDRAM 双页到 HDMI 与内嵌音频，每一层都能单独"
    "拆出来做实验，也能直接当数字逻辑、计算机组成类课程的综合设计题目。",

    "便携测试设备。板卡小、功耗低，一根 HDMI 线接现成屏幕就能当图形界面，适合手持仪器。",

    "老旧设备显示升级。很多设备还在用并口小屏，换屏成本高；用这块板子把数据转成 HDMI，可以直接接市面上"
    "的显示器。",
]
fill_section(paras[10], APP)

# --------------------------------------------------------------------------
# 1.3 主要技术特点
# --------------------------------------------------------------------------
TECH = [
    "全部逻辑自己写，没有软核，也没有外购解码 IP。整机四个时钟域（50/100/73.333/366.667 MHz），"
    "跨域只用 2FF 同步和 Gray 码指针 FIFO 两种结构。",

    "片源自己定格式。真实影片一帧 RGB332 的 RLE 负载能到 47 kB，15 帧每秒就是 705 kB/s，超过卡速；"
    "编码器给每帧设字节预算，超了逐级降质，实测压到平均 29 kB、峰值 36 kB，视频约占链路一半。",

    "帧缓存按“一帧正好一页”设计：一页 307200 字，一帧也写 307200 字，写口连续写不用按行等，"
    "帧边界天然落在页边界上；换页放在行消隐里做。",

    "HDMI 内嵌音频从零做：48 kHz 采样脉冲用 32 位相位累加器从像素时钟分频（步长 2811250，"
    "实际 47.9999 kHz），音频时钟再生包取 N=6144、CTS 实测。",

    "一个 SD 引擎两个所有者：照片和视频不能同时读卡，中间加所有权仲裁，交接前先让对方停稳，"
    "再留 25 ms 等显示侧换页。",
]
fill_section(paras[13], TECH)

# --------------------------------------------------------------------------
# 1.4 主要性能指标（表格）
# --------------------------------------------------------------------------
set_text(paras[16], "整机指标分显示、片源、存储、资源和时序几类，实测值见表 1-1。")
add_table(paras[16], ["项目", "指标"], [
    ["输出分辨率", "1280×720 @ 59.26 Hz，TMDS 4 lane 直驱（板上无 HDMI 发送芯片）"],
    ["照片", "640×480 24 位 BMP，装载约 0.6 s/张，自动播放间隔 3.02 s"],
    ["视频", "320×240 RGB332 + RLE，15 fps，解码后 2×2 放大到 640×480"],
    ["音频", "48 kHz 单声道，HDMI 内嵌 LPCM 24 bit（ACR N=6144）"],
    ["存储", "TF 卡 SPI 12.5 MHz，FAT32，8.3 文件名，播放列表上限 16 条"],
    ["逻辑资源", "LUT 7700/19600（39.3%），寄存器 6181，BRAM 33/64，DSP 2/29"],
    ["时序", "100 MHz 域建立余量 +0.102 ns、保持余量 +0.003 ns，无违例端点"],
    ["启动", "上电约 2 s 出第一张画面（bit 固化在 SPI 配置 Flash）"],
    ["供电", "5 V 单电源；整机 = AC208 开发板 + HDMI 显示器"],
], widths=[3.0, 12.0], caption="表 1-1  主要性能指标")

# --------------------------------------------------------------------------
# 1.5 主要创新点
# --------------------------------------------------------------------------
POINT = [
    "（1）照片和视频共用一份播放列表：排序键取“类型 + 四位编号”，目录不排序也能算出正确序号。",
    "（2）帧缓存按“一帧一页”设计，视频改成连续环形写，省掉逐行写的行间隔等待（每帧省 19.7 ms）。",
    "（3）片源格式与编码器一起设计：逐帧字节预算加四级自适应量化，把真实影片压进 SPI 带宽之内。",
    "（4）纯逻辑 HDMI 内嵌音频（相位累加器 + 音频时钟再生包），不用外部 codec 也能让显示器出声。",
]
fill_section(paras[19], POINT)

# --------------------------------------------------------------------------
# 1.6 设计流程
# --------------------------------------------------------------------------
FLOW = [
    "按里程碑推进，每个里程碑都要“能编译、能上板、有文档”：点亮 HDMI 彩条 → SDRAM 双页帧缓存 → "
    "TF 卡读 FAT32 与 BMP → 按键与数码管 → 音频通路 → M5V1 视频软解码与 HDMI 内嵌音频 → "
    "照片视频混排列表与 SPI Flash 固化。",
    "每个阶段先写 Python 周期级模型把状态机跑通，再写 RTL；上板前把关键数字做成可读的，"
    "出问题先读数再改代码。",
]
fill_section(paras[22], FLOW)

# --------------------------------------------------------------------------
# 2.1 整体介绍
# --------------------------------------------------------------------------
set_text(paras[28], "")
IMPL = [
    "系统整体框图见图 2-1。左边是存储与读取：TF 卡走 SPI，扇区引擎一次读 512 字节进扇区缓冲，"
    "之后所有解析都在缓冲里做，不再碰卡。中间是播放层，分成两条支路：照片由播放列表引擎选中后，"
    "页写入器把像素按行写进帧缓存；视频则由簇链块流把文件当字节流吐出来，交给 M5V1 解码器展开成整帧。"
    "两条支路都写进同一对帧缓存页，显示侧只读“正在显示的那一页”。右边是输出：光栅与窗口模块按 1280×720"
    " 的时序把 640×480 窗口里的像素一个一个读出来，拼成 AXIS 流送进 HDMI 发送核，最后经 ODDR 串行化成四对 "
    "TMDS 差分信号。",

    "模块之间的关系有两条约束值得单独说。第一，帧缓存只有一对，所以同一时刻只能有一个东西在写："
    "照片用页写入器逐行写，视频用解码器连续写，两者靠一个所有权仲裁器分时复用，切换前必须让对方停稳。"
    "第二，声音不跟画面走同一条路：解码器解出的 48 kHz 样点经异步 FIFO 直接进 HDMI 音频包，"
    "不占帧缓存带宽，也不受换页影响。",

    "时钟分四个域：50 MHz 是参考，100 MHz 给存储和两个播放引擎，73.333 MHz 给像素与 HDMI 核，"
    "366.667 MHz 给 TMDS 串行化。跨域结构只有 2FF 同步和 Gray 码指针 FIFO 两种，"
    "所有跨域点都在时序约束里声明过。",
]
last = add_body(paras[28], IMPL)
add_figure(last, "fig_system.png", 14.4, "图 2-1  系统整体框图")

# --------------------------------------------------------------------------
# 2.2.1 硬件整体介绍
# --------------------------------------------------------------------------
set_text(paras[31], "2.2.1 硬件整体介绍")
HW = [
    "硬件直接用安路 AC208 开发板：AC201-EG4S20 底板加 AC601 核心板，核心板上是 EG4S20BG256。"
    "选它主要是三点：LUT 够用（19600 个）、片内有 8 MB SDRAM 硬宏（正好做两页帧缓存，省掉外挂存储器）、"
    "HDMI 座是直接连到 FPGA 引脚的，不需要 HDMI 发送芯片。主要资源见表 2-2。",
]
last31 = add_body(paras[31], HW)
add_table(last31, ["项目", "型号 / 参数", "在本作品里的用途"], [
    ["FPGA", "EG4S20BG256", "19600 LUT、64 个 BRAM9K、29 个 DSP、4 个 PLL"],
    ["片内 SDRAM", "EG_PHY_SDRAM_2M_32，2M×32 = 8 MB", "两页 640×480 帧缓存，每页 307200 字"],
    ["参考时钟", "50 MHz 有源晶振（K14）", "所有时钟的根，经 PLL 分出 100 / 73.333 / 366.667 MHz"],
    ["显示接口", "4 对 LVDS 直连 HDMI 座，无发送芯片", "TMDS 由 FPGA 内部 ODDR 10:1 串行化后直接输出"],
    ["存储卡", "TF 卡座，SPI 四线（M2 / L3 / K6 / R2）", "片源存放，FAT32 文件系统"],
    ["交互", "3 个按键 + 8 位数码管（2×74HC595 三线）", "切换、暂停、总数与序号显示"],
    ["下载", "AL-LINK（JTAG）", "烧 SRAM 调试用，也用来写 SPI 配置 Flash"],
], widths=[2.6, 6.2, 6.8], caption="表 2-2  硬件资源与接口")

# --------------------------------------------------------------------------
# 2.2.2 机械设计介绍
# --------------------------------------------------------------------------
set_text(paras[32], "2.2.2 机械设计介绍")
MECH = [
    "本作品没有做机械设计。整机就是开发板加显示器，靠开发板自带的固定孔和桌面摆放，"
    "连接只有一根 HDMI 线、一根供电线和一张 TF 卡。这样做是为了把精力放在逻辑与显示链路上；"
    "如果后续要做成产品形态，外壳和散热结构需要单独设计。",
]
add_body(paras[32], MECH)

# --------------------------------------------------------------------------
# 2.2.3 电路各模块介绍
# --------------------------------------------------------------------------
set_text(paras[33], "2.2.3 电路各模块介绍")
HW2 = [
    "本作品没有自制 PCB 和原理图，用的是现成开发板，所以这里用“信号—引脚”对应表代替电路图（表 2-3），"
    "并说明几处关键的电路事实。",
    "显示部分没有 HDMI 发送芯片，TMDS 由 FPGA 直接驱动，四对差分线直接连到 HDMI 座。板子也没有 "
    "DDC/EDID/HPD 通路，所以分辨率、时序只能固定写死，程序里按 1280×720、59.26 Hz 输出。",
    "存储部分用 TF 卡的 SPI 模式，四根线（时钟、命令、数据输入、片选）都带上拉，卡座没有插拔检测脚，"
    "上电初始化一次，不支持热插拔。",
    "交互部分是三个低有效按键加两片 74HC595 驱动的八位数码管，串行三线（移位时钟、锁存、数据），"
    "数码管段码和位码由 595 移位链输出。",
    "调试口是把 FPGA 的一根引脚接到板载 CH340E 串口，115200 8N1，用来打印内部状态；逻辑分析仪不可用时，"
    "这一根线比示波器还管用。",
]
last33 = add_body(paras[33], HW2)
add_table(last33, ["信号", "引脚", "说明"], [
    ["clk", "K14", "50 MHz 参考时钟，所有 PLL 的输入"],
    ["rst_n", "H14", "KEY2，低有效，兼作复位"],
    ["key0_n / key1_n", "F7 / E7", "S0 / S1，低有效，内部消抖"],
    ["SD_CLK / SD_MOSI / SD_CS", "M2 / L3 / R2", "TF 卡 SPI 输出三线"],
    ["SD_MISO", "K6", "TF 卡 SPI 输入"],
    ["SEG7_SCLK / SEG7_RCLK / SEG7_DIO", "T14 / R12 / R14", "数码管 74HC595 串行三线"],
    ["uart_tx", "P2", "调试串口，115200 8N1"],
    ["led[3:0]", "M12 / R16 / R15 / T15", "状态灯，低电平点亮"],
    ["O_tmds_ch0~2_p、clk_p", "D11 / C11 / F10 / B10", "HDMI 四对差分（含时钟）"],
], widths=[4.6, 4.2, 6.6], caption="表 2-3  关键信号与引脚分配")

# --------------------------------------------------------------------------
# 2.3.1 软件整体介绍
# --------------------------------------------------------------------------
set_text(paras[36], "2.3.1 软件整体介绍")
SW = [
    "软件分两部分：板上的 RTL 和 PC 端的工具链。RTL 全部用 Verilog 手写，顶层一个文件，下面按功能分成 "
    "8 个模块（表 2-4），没有软核、没有 IP 集成工具自动生成的粘合逻辑，工程文件由脚本生成，保证换台机器"
    "也能重建。",
    "PC 端工具链有四件：片源编码器（Python 调 ffmpeg，把普通视频转成 M5V1）、码率评估脚本（拿几十帧先算"
    "“这个码率链路吃不吃得下”）、烧写/固化脚本（调 TD 的 BitWriter，命令行烧 SRAM 或写 SPI Flash）、"
    "串口读取脚本（收状态行）。开发闭环见图 2-2。",
    "整个流程是“先模型、后 RTL、再上板”。每个里程碑先在 Python 里把状态机照抄一遍，造一张假卡、假扇区数据，"
    "把 FAT32、BMP、双页换页、交互这些状态全跑一遍；模型能过再写 HDL，上板时把内部关键数字引到串口和数码管，"
    "出问题先看数。这套办法把每个阶段的调试次数压到了个位数。",
]
last36 = add_body(paras[36], SW)
add_figure(last36, "fig_flow.png", 13.8, "图 2-2  开发与验证闭环")

# --------------------------------------------------------------------------
# 2.3.2 软件各模块介绍
# --------------------------------------------------------------------------
set_text(paras[37], "2.3.2 软件各模块介绍")
SM = [
    "按图 2-1 的层次往下说。各模块的职责和关键输入输出汇总在表 2-4，下面挑四个最关键的说细节。",
]
last37 = add_body(paras[37], SM)
last37b = add_table(last37, ["模块", "职责", "关键输入 / 输出"], [
    ["时钟与复位", "PLL 分频、各域复位同步", "输入 50 MHz；输出 100 / 73.333 / 366.667 MHz 与复位"],
    ["SPI 扇区引擎", "按 LBA 读一个 512 B 扇区，带超时看门狗", "输入 LBA 与启动脉冲；输出扇区数据与完成/错误"],
    ["播放列表引擎", "mount、目录扫描、选条、排名、按键与自动播放、照片装载", "输入按键事件与扇区数据；输出选中条目、写页控制、数码管计数"],
    ["簇链块流", "按簇链把视频文件当字节流吐出", "输入首簇、文件长度、FAT 参数；输出字节流 + valid/ready"],
    ["M5V1 解码", "RLE 展开、RGB332 转 888、2×2 放大、音频样点还原", "输入字节流；输出每帧 307200 字写请求与 48 kHz 样点"],
    ["页写入", "按行把 24 位像素写进帧缓存，一行 128 字突发", "输入像素与行同步；输出 WR1 写请求与地址"],
    ["光栅与窗口", "1280×720 时序、窗口取像素、换页、按键消抖", "输入帧缓存读数据；输出 AXIS 像素流与当前页号"],
    ["HDMI 核与串行化", "打包视频/音频、生成 ACR、10:1 串行化", "输入 AXIS 与音频样点；输出四对 TMDS"],
], widths=[3.0, 6.0, 7.0], caption="表 2-4  软件模块划分")

SM2 = [
    "播放列表引擎是整个作品的“大脑”。它先把卡挂起来（读 MBR、分区 BPB、FAT 表位置、根目录簇），"
    "再扫一遍根目录，把 IMG 开头的 BMP 和 VID 开头的 M5V 都收进一张表，每条记下类型、编号、首簇和长度。"
    "排序键是“类型 + 编号”：照片在前、视频在后，同一编号再比类型。之后“下一条”就是找比当前键大的最小值，"
    "到末尾就绕回最小键；“上一条”反过来。位置计数不跟数组下标走，而是单独维护：下一条加一、到末尾归 1，"
    "所以数码管上的序号永远等于真实播放顺序，跟目录里文件的创建顺序无关。",

    "视频解码分两级。前一级是簇链块流：给它首簇和文件长度，它按 FAT 链一簇一簇读，每读一个扇区就复制到本地"
    "缓冲，然后一字节一字节交出去，下游不接收就停在那儿等；到文件末尾回卷，重新从首簇开始。后一级是 M5V1 "
    "解码器：先从 32 字节文件头里取宽高、帧数、音频参数，然后按“8 字节帧块头 + RLE 负载 + 音频样点”"
    "逐帧处理。RLE 只有三种记号——重复、原样、结束，展开成 320×240 的 8 位像素后写进行缓冲，每行再按 2×2 "
    "放大成 640×480 的两行写出去。帧的节奏由 15 fps 的定时器控制，一帧正好写满一页（图 2-3）。",

    "页与换页。两页各 307200 字，写口固定写“没在显示”的那一页：照片逐行写，一行 5 个 128 字突发，"
    "行末留够时间让写 FIFO 排空；视频连续写，一帧 2400 个突发，写完正好到页边界。整页写完后发一个换页脉冲，"
    "显示侧在下一个行消隐把读口切过去——所以看到的永远是完整的一帧，中间那段写入过程是看不见的。",

    "HDMI 音频。解码器每帧给出 3200 个样点，先进异步 FIFO（写侧 100 MHz、读侧 73.333 MHz，Gray 指针跨域），"
    "读侧用相位累加器产生 48 kHz 节拍：每个像素时钟加 2811250，累加器溢出那一下就是要送一个样点，"
    "实际频率 47.9999 kHz。样点填进 HDMI 音频包（LPCM 24 位左对齐），同时按 N=6144 和实测 CTS 生成音频时钟"
    "再生包，显示器靠它把音频和视频对齐。",
]
last2 = add_body(last37b, SM2)
add_figure(last2, "fig_pages.png", 13.8, "图 2-3  双页帧缓存与连续写")

# --------------------------------------------------------------------------
# 3.1 整体介绍
# --------------------------------------------------------------------------
set_text(paras[41].find(qn("w:r")).getparent() if False else paras[41], "整体介绍")
P31 = [
    "实物就是开发板 + TF 卡 + 一根 HDMI 线接到便携显示器上，没有外壳，也没有额外的电源模块。"
    "上电后 FPGA 从 SPI 配置 Flash 自己加载，约两秒出第一张画面。",
]
lastp = add_body(paras[41], P31)
PH1 = new_par_after(lastp, "【此处插入实物照片：系统正面 / 斜 45°】", size=21, center=True)

# --------------------------------------------------------------------------
# 3.2 工程成果
# --------------------------------------------------------------------------
set_text(paras[43], "工程成果")
GONG = [
    "工程成果分机械、电路、软件三块。机械部分本作品没有，电路部分直接用开发板，"
    "成果主要体现在软件（RTL 与 PC 端工具链）和最终呈现的画面上。",
]
add_body(paras[43], GONG)

set_text(paras[44], "3.2.1 机械成果")
M1 = ["本作品没有自制机械件，整机靠开发板本身的结构和桌面摆放，因此这一节没有可展示的机械设计图。"]
add_body(paras[44], M1)

set_text(paras[45], "3.2.2 电路成果")
M2 = [
    "电路成果是“用开发板搭出来的最小系统”：供电、时钟、HDMI 输出、TF 卡、按键、数码管、调试串口七部分，"
    "接线只有 HDMI、供电和 TF 卡三处。没有自制 PCB，所以这里放实物接线照片。",
]
lastm2 = add_body(paras[45], M2)
new_par_after(lastm2, "【此处插入电路实物照片：板卡接口与接线】", size=21, center=True)

set_text(paras[46], "3.2.3 软件成果")
M3 = [
    "软件成果是跑起来以后的“界面”，其实就是屏幕和数码管。屏幕上：照片整幅居中显示，"
    "视频在同一个位置连续播放；数码管上：左边四位是列表总条数，右边四位是当前第几条，"
    "暂停时两端的小数点亮起，出错时显示 E 加错误码。调试串口另有一行状态，"
    "里面是解码器状态、帧数、字节计数这些数字，平时不接电脑也不影响播放。",
]
lastm3 = add_body(paras[46], M3)
new_par_after(lastm3, "【此处插入屏幕与数码管照片：照片播放 / 视频播放】", size=21, center=True)

# --------------------------------------------------------------------------
# 3.3 特性成果
# --------------------------------------------------------------------------
set_text(paras[48], "特性成果")
C33 = [
    "功能逐项验证的结果见表 3-1。每一项都在实物上跑过，判定标准写在“验证方法”里，"
    "不靠“看起来正常”，而是靠数码管读数、串口状态行和时序报告对上。",
]
last48 = add_body(paras[48], C33)
add_table(last48, ["功能 / 指标", "验证方法", "结果"], [
    ["照片播放", "根目录放 5 张 640×480 BMP，看是否按编号顺序播、换页有无撕裂", "通过"],
    ["视频播放", "放 3 段 M5V1，看画面是否连续、喇叭是否出声、是否自动进下一段", "通过"],
    ["混排顺序", "照片与视频混在同一目录，观察是否 5 张照片后接 3 段视频再循环", "通过"],
    ["按键", "S0/S1 短按切换上一条下一条；长按 S0 一秒看数码管小数点是否亮起", "通过"],
    ["暂停浏览", "暂停状态下短按切到视频，确认能播放，播完停在最后一帧", "通过"],
    ["数码管", "对照显示器画面读“总条数 + 当前序号”；拔卡后复位应显示 E3", "通过"],
    ["上电自启动", "断电、拔掉下载线后重新上电，看是否两秒内出第一张画面", "通过"],
    ["时序与资源", "读 TD 布局布线报告：LUT 39.3%、BRAM 33/64、建立余量 +0.102 ns", "通过"],
], widths=[3.2, 8.4, 2.0], caption="表 3-1  功能与指标验证")

# --------------------------------------------------------------------------
# 4.1 可扩展之处
# --------------------------------------------------------------------------
set_text(paras[53], "可扩展之处")
EXT = [
    "一是画质和分辨率。现在视频是 320×240 的彩色 8 位、放大到 640×480，如果改成 RGB565 加更好的帧间压缩，"
    "在同样的卡速下可以把清晰度再提一档。",
    "二是音频。现在只有单声道 48 kHz，可以扩成立体声，或者把前期调过的 WM8960 音频通路接回来，"
    "同时输出到耳机口和 HDMI。",
    "三是内容管理。现在播放列表是开机扫描一次，可以做子目录、可以按修改时间排序，"
    "也可以加个简单的软键盘做文件选择。",
    "四是接口。板上有 I²C 总线，接个 RTC 或传感器，就能做“按时间切换播放内容”的电子看板。",
]
fill_section(paras[54], EXT)

# --------------------------------------------------------------------------
# 4.2 心得体会
# --------------------------------------------------------------------------
set_text(paras[55], "心得体会")
EXP = [
    "做完这个项目，最大的体会是：难的不是把功能写出来，而是把“看起来像坏了”的现象变成一个能对得上的数字。"
    "手上没有逻辑分析仪，一开始调试全靠盯着屏幕猜，一晚上过去只换来“好像更差了”。后来把数码管改成寄存器窗口，"
    "四页调试字轮着显示不同变量，四颗 LED 编码状态；再后来把串口接上，每半秒打一行内部状态，事情才开始有进展。",

    "印象最深的是视频播放的第一个版本：视频出来第一帧，然后画面被下一张照片从下往上刷掉，没有声音，"
    "数码管上的序号却一直在涨。光看屏幕分不清问题在读卡还是解码。把状态行改成“每段视频结束时锁存当时的内部"
    "状态再打印”，一次上板就读到了：解码器正好消费了一帧的字节数，然后读到的“下一帧块头”全是零。回去对照片源，"
    "那个偏移本来是合法的帧块头——问题锁定在读卡这边：簇链取 FAT 表项的状态机少等了一拍。本地扇区缓冲是"
    "寄存器输出口，地址给出去要隔一拍数据才有效，我们却在下一拍就取了数，于是每次 FAT 都拿到旧值，簇链从第一簇"
    "之后全跳到空白区。改回四状态取数引擎之后，串口显示整段视频字节数一字不差，声音也出来了。",

    "第二个教训是别信“时序过了就能跑”。有一版功能都对，但建立余量是 −0.543 ns，我们觉得只差半纳秒就上了板。"
    "画面能出，可视频右侧一条竖直的长条被挪到了左边，几次以为是显示链路的地址算错。回头查时序报告，"
    "最差路径正好落在解码器的帧边界判断上——一帧结束、下一页开始的判断打偏，写指针就错位。把“帧计数加一与"
    "帧数比较”改成“递减计数等于一”，路径从 11 级逻辑降到宽与门，余量回到 +0.102 ns，长条也消失了。"
    "之后“先看时序报告，再看功能”就写进了自己的检查清单。",

    "上板名额不多，每次上板前都要问：这次验证哪个假设，能不能先在 PC 上排除一半？FAT32 和 BMP 解析先写了 "
    "Python 模型照抄 RTL，用假卡镜像跑了几十项检查；I²C 与 I²S 的波形也"
    "先在模型里对齐字节、位和采样沿再写 HDL。这样上板时剩下的往往只是环境和看不见的时序。最后一个体会是取舍："
    "最早想做通用播放器，后来发现无压缩或者 JPEG 在 SPI 卡速下根本喂不饱，干脆自己定格式（帧内 RLE、320×240、"
    "15 fps，配一个字节预算编码器），后面很多事情因此变简单，代价只是片源要先转码。项目里每个 bug 都按"
    "“现象、根因、证据、修法”记了一笔；当时写是为了不重复踩，事后看反而是"
    "最有用的东西。",
]
fill_section(paras[56], EXP)

# --------------------------------------------------------------------------
# 5 参考文献
# --------------------------------------------------------------------------
REF = [
    "[1] 安路科技. Tang Dynasty 2026.1 用户手册[Z]. 上海: 上海安路信息科技股份有限公司, 2026.",
    "[2] 上海安路信息科技股份有限公司. EG4 系列 FPGA 器件数据手册[Z]. 2025.",
    "[3] 上海安路信息科技股份有限公司. EG4S20 开发板（AC208）原理图与引脚说明[Z]. 2025.",
    "[4] High-Definition Multimedia Interface Specification Version 1.4b[S]. HDMI Licensing, LLC, 2011.",
    "[5] Microsoft Corporation. FAT: General Overview of On-Disk Format, Version 1.03[Z]. 2000.",
    "[6] SD Association. SD Specifications Part 1: Physical Layer Simplified Specification[Z]. 2010.",
    "[7] Cummings C E. Simulation and Synthesis Techniques for Asynchronous FIFO Design[C]. "
    "SNUG 2002, San Jose, 2002.",
    "[8] Cummings C E. Clock Domain Crossing (CDC) Design & Verification Techniques Using "
    "SystemVerilog[C]. SNUG 2008, Boston, 2008.",
    "[9] 王诚, 吴继华, 范丽珍, 等. Altera FPGA/CPLD 设计（基础篇）[M]. 北京: 人民邮电出版社, 2005.",
    "[10] Wakerly J F. Digital Design: Principles and Practices[M]. 4th ed. "
    "Pearson Prentice Hall, 2005.",
    "[11] Salomon D. Data Compression: The Complete Reference[M]. 4th ed. London: Springer, 2007.",
    "[12] 李挥, 王志华. 数字视频处理与显示技术[M]. 北京: 电子工业出版社, 2010.",
]
set_text(paras[59], REF[0], size=22)
cur = paras[59]
for line in REF[1:]:
    cur = new_par_after(cur, line, size=22)

doc.save(OUT)
print("saved:", OUT)
print("paragraphs:", len(doc.paragraphs), "tables:", len(doc.tables),
      "images:", len(doc.inline_shapes))
