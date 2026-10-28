# -*- coding: utf-8 -*-
"""
make_engineering_report.py
生成《安路赛道第 1 题 · 选题一 —— EG4S20 HDMI 多媒体播放器 五阶段工程汇报》Word 文档。

内容来自仓库中的：
  docs/specs/2026-10-21-hdmi-basic-player-design.md
  docs/research/m0..m6-report.md / bench-bringup-postmortem.md / hw-facts.md / example-arch.md
  proj/m6_media/rtl/*.v（当前交付版本的 RTL）
  TD 构建产物（资源 / 时序报告）
"""
import os
from docx import Document
from docx.shared import Pt, Cm, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.style import WD_STYLE_TYPE
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

OUT = r"E:\fpga-2026\安路赛道第1题_五阶段工程汇报.docx"

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

def set_style_font(style, ascii_font, east_asia, size, bold=None, color=None):
    style.font.name = ascii_font
    style.font.size = Pt(size)
    if bold is not None:
        style.font.bold = bold
    if color:
        style.font.color.rgb = RGBColor.from_string(color)
    rpr = style.element.get_or_add_rPr()
    rfonts = rpr.find(qn('w:rFonts'))
    if rfonts is None:
        rfonts = OxmlElement('w:rFonts')
        rpr.append(rfonts)
    rfonts.set(qn('w:ascii'), ascii_font)
    rfonts.set(qn('w:hAnsi'), ascii_font)
    rfonts.set(qn('w:eastAsia'), east_asia)


def shade_paragraph(p, fill='F2F3F5'):
    pPr = p._p.get_or_add_pPr()
    shd = OxmlElement('w:shd')
    shd.set(qn('w:val'), 'clear')
    shd.set(qn('w:color'), 'auto')
    shd.set(qn('w:fill'), fill)
    pPr.append(shd)
    # 左边框
    pbdr = OxmlElement('w:pBdr')
    left = OxmlElement('w:left')
    left.set(qn('w:val'), 'single')
    left.set(qn('w:sz'), '12')
    left.set(qn('w:space'), '4')
    left.set(qn('w:color'), 'B4C6E7')
    pbdr.append(left)
    pPr.append(pbdr)


def shade_cell(cell, fill):
    tcPr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement('w:shd')
    shd.set(qn('w:val'), 'clear')
    shd.set(qn('w:color'), 'auto')
    shd.set(qn('w:fill'), fill)
    tcPr.append(shd)


def add_page_number_footer(section):
    p = section.footer.paragraphs[0]
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    run = p.add_run()
    run.font.size = Pt(9)
    fld_begin = OxmlElement('w:fldChar')
    fld_begin.set(qn('w:fldCharType'), 'begin')
    instr = OxmlElement('w:instrText')
    instr.set(qn('xml:space'), 'preserve')
    instr.text = ' PAGE '
    fld_sep = OxmlElement('w:fldChar')
    fld_sep.set(qn('w:fldCharType'), 'separate')
    fld_text = OxmlElement('w:t')
    fld_text.text = '1'
    fld_end = OxmlElement('w:fldChar')
    fld_end.set(qn('w:fldCharType'), 'end')
    run._r.append(fld_begin)
    run._r.append(instr)
    run._r.append(fld_sep)
    run._r.append(fld_text)
    run._r.append(fld_end)


def add_header_text(section, text):
    p = section.header.paragraphs[0]
    p.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    r = p.add_run(text)
    r.font.size = Pt(8.5)
    r.font.color.rgb = RGBColor.from_string('808080')


# ---------------------------------------------------------------------------
# 文档骨架
# ---------------------------------------------------------------------------
doc = Document()

sec = doc.sections[0]
sec.page_width = Cm(21.0)
sec.page_height = Cm(29.7)
sec.left_margin = Cm(2.3)
sec.right_margin = Cm(2.1)
sec.top_margin = Cm(2.2)
sec.bottom_margin = Cm(2.0)

set_style_font(doc.styles['Normal'], 'Times New Roman', '宋体', 10.5)
doc.styles['Normal'].paragraph_format.line_spacing = 1.32
doc.styles['Normal'].paragraph_format.space_after = Pt(3)

for name, size, color, before in (
        ('Heading 1', 17, '1F3864', 16),
        ('Heading 2', 13.5, '2E5395', 10),
        ('Heading 3', 11.5, '2E5395', 8)):
    st = doc.styles[name]
    set_style_font(st, 'Microsoft YaHei', '微软雅黑', size, bold=True, color=color)
    st.paragraph_format.space_before = Pt(before)
    st.paragraph_format.space_after = Pt(5)

code_style = doc.styles.add_style('CodeBlock', WD_STYLE_TYPE.PARAGRAPH)
set_style_font(code_style, 'Consolas', 'Consolas', 8.3)
code_style.paragraph_format.line_spacing = 1.0
code_style.paragraph_format.space_before = Pt(2)
code_style.paragraph_format.space_after = Pt(2)
code_style.paragraph_format.left_indent = Cm(0.25)

caption_style = doc.styles.add_style('Caption2', WD_STYLE_TYPE.PARAGRAPH)
set_style_font(caption_style, 'Microsoft YaHei', '微软雅黑', 8.5, color='595959')
caption_style.paragraph_format.alignment = WD_ALIGN_PARAGRAPH.CENTER
caption_style.paragraph_format.space_before = Pt(2)
caption_style.paragraph_format.space_after = Pt(6)

add_header_text(sec, '安路赛道第 1 题 · 选题一 · EG4S20 HDMI 多媒体播放器 · 五阶段工程汇报')
add_page_number_footer(sec)

doc.core_properties.title = '安路赛道第 1 题 · 选题一 · EG4S20 HDMI 多媒体播放器 五阶段工程汇报'
doc.core_properties.subject = 'FPGA 竞赛项目工程汇报'
doc.core_properties.author = '选题一工程组'


# ---------------------------------------------------------------------------
# 排版辅助
# ---------------------------------------------------------------------------
_table_no = [0]
_code_no = [0]


def H(text, level=1):
    h = doc.add_heading(text, level=level)
    h.paragraph_format.keep_with_next = True
    return h


def P(text, bold=False, size=None, color=None, align=None, first_indent=True):
    p = doc.add_paragraph()
    if first_indent:
        p.paragraph_format.first_line_indent = Cm(0.74)
    r = p.add_run(text)
    r.bold = bold
    if size:
        r.font.size = Pt(size)
    if color:
        r.font.color.rgb = RGBColor.from_string(color)
    if align == 'center':
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    return p


def BUL(items, size=None):
    for it in items:
        p = doc.add_paragraph(style='List Bullet')
        p.paragraph_format.space_after = Pt(2)
        p.paragraph_format.line_spacing = 1.25
        r = p.add_run(it)
        if size:
            r.font.size = Pt(size)


def NUM(items, size=None):
    for it in items:
        p = doc.add_paragraph(style='List Number')
        p.paragraph_format.space_after = Pt(2)
        p.paragraph_format.line_spacing = 1.25
        r = p.add_run(it)
        if size:
            r.font.size = Pt(size)


def CODE(lines, caption=None):
    text = '\n'.join(lines) if isinstance(lines, (list, tuple)) else lines
    if caption:
        _code_no[0] += 1
        c = doc.add_paragraph(style='Caption2')
        c.add_run('代码 %d  %s' % (_code_no[0], caption))
    p = doc.add_paragraph(style='CodeBlock')
    parts = text.split('\n')
    for i, line in enumerate(parts):
        r = p.add_run(line)
        if i != len(parts) - 1:
            r.add_break()
    p.paragraph_format.keep_together = True
    shade_paragraph(p)


def _row_cant_split(row):
    trPr = row._tr.get_or_add_trPr()
    el = OxmlElement('w:cantSplit')
    trPr.append(el)


def _row_header(row):
    trPr = row._tr.get_or_add_trPr()
    el = OxmlElement('w:tblHeader')
    trPr.append(el)


def TABLE(headers, rows, caption=None, widths=None, font=9, header_fill='DCE6F1'):
    if caption:
        _table_no[0] += 1
        c = doc.add_paragraph(style='Caption2')
        c.add_run('表 %d  %s' % (_table_no[0], caption))
        # 表格标题不要和表体分页：Word/LibreOffice 都会据此把标题与紧随的表格留在同一页
        c.paragraph_format.keep_with_next = True
    t = doc.add_table(rows=1, cols=len(headers))
    t.style = 'Table Grid'
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    t.autofit = False
    hdr = t.rows[0].cells
    for i, h in enumerate(headers):
        hdr[i].text = ''
        p = hdr[i].paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        r = p.add_run(h)
        r.bold = True
        r.font.size = Pt(font)
        r.font.name = 'Microsoft YaHei'
        shade_cell(hdr[i], header_fill)
    for row in rows:
        cells = t.add_row().cells
        for i, v in enumerate(row):
            cells[i].text = ''
            p = cells[i].paragraphs[0]
            r = p.add_run(str(v))
            r.font.size = Pt(font)
    # 行不跨页、表头跨页重复
    _row_header(t.rows[0])
    for row in t.rows:
        _row_cant_split(row)
    if widths:
        # 页面可用宽度 = 21.0 - 2.3 - 2.1 = 16.6 cm，超出则按比例缩放，避免表格溢出页边距
        total = float(sum(widths))
        maxw = 16.4
        scale = (maxw / total) if total > maxw else 1.0
        for i, w in enumerate(widths):
            for row in t.rows:
                row.cells[i].width = Cm(w * scale)
    doc.add_paragraph().paragraph_format.space_after = Pt(2)
    return t


def PAGEBREAK():
    doc.add_page_break()


def QUOTE(text):
    p = doc.add_paragraph()
    p.paragraph_format.left_indent = Cm(0.6)
    p.paragraph_format.right_indent = Cm(0.4)
    r = p.add_run(text)
    r.italic = True
    r.font.size = Pt(9.5)
    r.font.color.rgb = RGBColor.from_string('404040')
    shade_paragraph(p, 'FFF7E6')


# ===========================================================================
# 封面
# ===========================================================================
for _ in range(3):
    doc.add_paragraph()

p = doc.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
r = p.add_run('安路赛道第 1 题 · 选题一')
r.font.size = Pt(22)
r.font.name = 'Microsoft YaHei'
r.font.bold = True
r.font.color.rgb = RGBColor.from_string('1F3864')

p = doc.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
r = p.add_run('EG4S20 HDMI 多媒体播放器')
r.font.size = Pt(28)
r.font.name = 'Microsoft YaHei'
r.font.bold = True
r.font.color.rgb = RGBColor.from_string('2E5395')

p = doc.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
r = p.add_run('—— 五个阶段工程汇报 ——')
r.font.size = Pt(16)
r.font.name = 'Microsoft YaHei'
r.font.color.rgb = RGBColor.from_string('595959')

doc.add_paragraph()
doc.add_paragraph()

TABLE(['项目', '内容'], [
    ['赛题', '2026 安路科技 FPGA 赛道 · 第 1 题 · 选题一（FPGA 多媒体播放器）'],
    ['硬件平台', 'AC208 开发板 = AC201-EG4S20 底板 + AC601 核心板，FPGA 为 EG4S20BG256'],
    ['开发工具', 'Tang Dynasty 2026.1 SP2（TD），AL-LINK JTAG 下载'],
    ['工程路径', r'E:\fpga-2026\dsh_code（git 仓库），最终交付工程 proj\m6_media'],
    ['阶段划分', '阶段一 HDMI 显示平台（M0+M1）/ 阶段二 TF 卡图像播放与交互（M2+M3）/ '
                 '阶段三 音频子系统（M4）/ 阶段四 音视频一体播放（M5）/ '
                 '阶段五 图文混排播放列表（M6）'],
    ['最终状态', '照片与视频混排的播放列表：上电自启动、自动顺序播放、按键/长按交互、'
                 '数码管显示总条数与当前序号，视频声音走 HDMI 内嵌音频；bit 已固化在 SPI 配置 Flash，'
                 '断电重启仍然生效'],
    ['文档版本', 'v2.0（2026-10-28，增加阶段五 M6）'],
], widths=[3.2, 12.6], font=9.5)

for _ in range(2):
    doc.add_paragraph()
p = doc.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
r = p.add_run('摘要：本项目用一片 EG4S20 FPGA 独立完成「TF 卡文件系统 → 图像解码/视频软解码 → '
              '片内 SDRAM 双页帧缓存 → HDMI 720p 输出 + 内嵌音频」的完整多媒体播放链路，'
              '不依赖任何外部解码芯片或软核 CPU。五个阶段依次建起显示、存储/交互、音频、'
              '音视频一体、图文混排播放列表五条能力：最终一个播放列表里既有 640×480 照片又有带声音的视频，'
              '上电自启动、自动顺序播放、按键与数码管交互完备，bit 固化在 SPI 配置 Flash 中。')
r.font.size = Pt(9.5)
r.font.color.rgb = RGBColor.from_string('404040')

PAGEBREAK()

# ===========================================================================
# 目录
# ===========================================================================
H('目录', 1)
toc = [
    ('1  项目概述', ''),
    ('1.1  赛题与总体目标', ''),
    ('1.2  硬件平台', ''),
    ('1.3  开发工具与工程方法', ''),
    ('1.4  五个阶段的划分', ''),
    ('1.5  最终成果速览', ''),
    ('2  阶段一：HDMI 显示平台（M0 + M1）', ''),
    ('2.1  目标', ''),
    ('2.2  M0：TMDS 输出与彩条', ''),
    ('2.3  M1：片内 SDRAM 双页帧缓存', ''),
    ('2.4  本阶段最难的地方', ''),
    ('2.5  指标', ''),
    ('3  阶段二：TF 卡图像播放与交互（M2 + M3）', ''),
    ('3.1  目标', ''),
    ('3.2  SD 卡与 FAT32-lite', ''),
    ('3.3  交互与数码管', ''),
    ('3.4  上板调试：五个 bug 与 UART 调试通道', ''),
    ('3.5  指标', ''),
    ('4  阶段三：音频子系统（M4）', ''),
    ('4.1  目标', ''),
    ('4.2  12.288 MHz 音频时钟', ''),
    ('4.3  WM8960 的 I²C 初始化', ''),
    ('4.4  I²S 发送', ''),
    ('4.5  上板调试：两个 bug', ''),
    ('4.6  指标', ''),
    ('5  阶段四：音视频一体播放（M5）', ''),
    ('5.1  目标与 M5V1 片源格式', ''),
    ('5.2  数据流与关键模块', ''),
    ('5.3  音频双路：I²S 与 HDMI 内嵌音频', ''),
    ('5.4  六个关键 bug', ''),
    ('5.5  调试方法与可观测性', ''),
    ('5.6  指标', ''),
    ('6  阶段五：图文混排播放列表（M6）', ''),
    ('6.1  目标与四条现实需求', ''),
    ('6.2  架构：一个列表 + 两个引擎 + 单一 owner', ''),
    ('6.3  播放列表规则与按键语义', ''),
    ('6.4  三个真 bug 与一次时序事故', ''),
    ('6.5  片源编码与带宽账', ''),
    ('6.6  固化到 SPI 配置 Flash', ''),
    ('6.7  指标', ''),
    ('7  贯穿全工程的关键技术', ''),
    ('7.1  时钟域与跨时钟域设计', ''),
    ('7.2  SDRAM 带宽预算', ''),
    ('7.3  时序收敛史', ''),
    ('7.4  离线验证与构建可复现性', ''),
    ('7.5  厂商代码的使用原则', ''),
    ('8  难点问题总表', ''),
    ('9  成果、复现与展望', ''),
    ('附录 A  工程目录结构', ''),
    ('附录 B  关键参数速查', ''),
    ('附录 C  里程碑文档与提交索引', ''),
    ('附录 D  工具链与构建坑清单', ''),
]
for name, _ in toc:
    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(1)
    r = p.add_run(name)
    if '.' not in name.split(' ')[0]:
        r.bold = True
        r.font.size = Pt(10.5)
    else:
        r.font.size = Pt(10)
        p.paragraph_format.left_indent = Cm(0.9)

PAGEBREAK()

# ===========================================================================
# 1 项目概述
# ===========================================================================
H('1  项目概述', 1)

H('1.1  赛题与总体目标', 2)
P('赛题要求在一块安路（Anlogic）FPGA 开发板上实现一个多媒体播放器：从 TF 卡读取媒体文件，'
  '经 FPGA 内部处理后通过 HDMI 输出到显示器，并具备基本的交互与人机界面。项目按里程碑推进，'
  '每个里程碑都要求「能编译、能上板、有文档」，最终交付一套可现场演示的完整工程。')
P('我们的实现路线刻意回避了两条常见捷径：一是不用软核 CPU（没有 RISC-V/MicroBlaze，'
  '全部状态机用 RTL 手写）；二是不用外部解码芯片（没有 JPEG/H.264 解码器，视频格式是我们'
  '自己定义的 M5V1 帧内 RLE 格式，由 FPGA 纯逻辑实时解码）。整条链路为：')
QUOTE('TF 卡（FAT32/SPI）→ 扇区流 → M5V1 软解码（RLE）→ 片内 8 MB SDRAM 双页帧缓存 → '
      '1280×720 TMDS 输出；每帧 3200 个 48 kHz 音频样点 → 异步 FIFO → HDMI 内嵌音频（LPCM+ACR）'
      '→ 显示器内置喇叭。')

H('1.2  硬件平台', 2)
P('板卡为 AC208，由 AC201-EG4S20 底板与 AC601 核心板叠插组成。关键资源与接口如下：')
TABLE(['项目', '参数 / 型号', '对本项目的意义'], [
    ['FPGA', 'EG4S20BG256（安路 EG4 系列）', '19 600 LUT、64 个 BRAM9K、29 个 DSP、4 个 PLL'],
    ['片内 SDRAM', 'EG_PHY_SDRAM_2M_32 硬宏：2M×32 = 8 MB', '双页 640×480×32 bit 帧缓存（每页 307 200 字）'],
    ['板载时钟', '50 MHz 有源晶振（K14）', '所有时钟域的唯一参考源'],
    ['显示', '4 对 LVDS 直连 HDMI 座（无发送芯片）', 'TMDS 由 FPGA 直接产生（ODDR 原语 10:1 串行化）'],
    ['存储', 'TF 卡座（SPI 模式：CLK=M2 / MOSI=L3 / MISO=K6 / CS=R2）', 'FAT32 文件系统，25 MHz 读，约 0.4 s 读一张 640×480 BMP'],
    ['音频', 'WM8960 立体声 Codec（I²C 0x1A / I²S 主机模式）', '阶段三的测试音输出；阶段四起为 HDMI 音频的旁路通道'],
    ['人机交互', 'KEY0/KEY1/KEY2 + 8 位数码管（2×74HC595 三线）', '切图、暂停、图号/状态显示'],
    ['下载', 'AL-LINK（JTAG）', 'SRAM 配置：掉电即失，重配即复位'],
], widths=[2.6, 6.6, 6.6], caption='AC208 平台关键资源')

H('1.3  开发工具与工程方法', 2)
P('工具链是安路 Tang Dynasty 2026.1 SP2。我们把它完全脚本化，保证「一条命令构建、一条命令烧写、'
  '结果可复现」：')
BUL([
    '工程文件 .al 由 make_proj_files.ps1 生成（文件清单写死在脚本里，新增 RTL 必须登记，避免 GUI 手工维护）。',
    'build.ps1 依次跑 syn_1（read_design→opt_rtl→opt_gate）与 phy_1（opt_place→opt_route→bitgen），'
    '用 run_flow.tcl 把 TD 不可靠的退出码包装成 TD_FLOW_OK / TD_FLOW_FAILED。',
    'tools/flash.ps1 通过 AL-LINK 把 bit 下载到 SRAM（约 19 s），并附打印时序报告（SWNS/HWNS）。',
    '每个里程碑都做「两次独立全清编译」对比：bit 的 payload 逐行一致、Bitstream CRC 相同，证明构建可复现。',
    '在没有逻辑分析仪的条件下，自写 Python 周期级模型（FAT32/BMP、双页 SDRAM、交互状态机、I²C/I²S）'
    '把关键时序先离线验完，再用串口/数码管/LED 上板确认。',
    '工程分两套：离线验收工程（m0_hdmi / m1_sdram_fb / m2_sd_tf_bmp / m3_interact / m4_audio）'
    '用于编译验收与离线模型；实机工程（m0_720p / m2_720p / m3_720p / m4_720p / m5_video）'
    '用于上板演示。两者共享同一套 RTL，差异只在显示时序与调试开关，每份里程碑报告的「上板状态」'
    '小节记录实机结论。',
])

H('1.4  五个阶段的划分', 2)
P('七个里程碑按能力叠加关系归并为五个阶段。每个阶段都能独立上板演示，后一阶段只在前一阶段基础上增量修改：')
TABLE(['阶段', '里程碑', '核心目标', '本阶段新增的关键模块', '上板状态'], [
    ['一', 'M0 + M1', '点亮 HDMI，建立帧缓存', 'video_gen、m1_sdram_wr、m1_video_src、Sdram_Control_4Port', 'M0 编译通过；M1 编译通过'],
    ['二', 'M2 + M3', 'TF 卡图片播放与交互', 'm*_sd_sec、m*_fat_bmp、m*_page_wr、m*_pix_pump、按键/数码管逻辑', '2026-10-22 上板出图'],
    ['三', 'M4', 'WM8960 音频输出', 'm*_i2s_init_dev / i2s_control / i2s_bit_shift / i2s_tx / sine_tone', '2026-10-23 上板出声'],
    ['四', 'M5', '音视频一体播放', 'm5_stream、m5_vdec、m5_aud_fifo、m5_audio_acr、m5_video_src720', '2026-10-24 上板画面+原声'],
    ['五', 'M6', '图文混排播放列表 + 固化启动',
     'm6_fat（混排列表/排名/视频交接）、m6_vstream（簇链块流）、m6_vdec（起始页/结束脉冲/递减计数）、'
     'm6_top（SD/WR1/页脉冲的 owner 仲裁）、SPI Flash 固化流程', '2026-10-28 上板全部验证 + 断电自启动'],
], widths=[1.2, 2.0, 3.6, 6.6, 3.4], caption='五个阶段一览')

H('1.5  最终成果速览', 2)
TABLE(['维度', '结果'], [
    ['播放列表', 'TF 卡 FAT32 根目录的 IMGnnnn.BMP 与 VIDnnnn.M5V 合成一份列表（key = {类型, 编号}），'
                 '上电顺序播放：5 张照片（每 3 s）→ 3 段视频（各带原声、播完自动进下一段）→ 循环'],
    ['照片', '640×480 24 bit BMP，M3 的逐行写页 + 双页换页，自动播放间隔 3.02 s'],
    ['视频', '320×240 RGB332 RLE、15 fps，逐帧字节预算 ≤36 kB（自适应量化），SDRAM 环形写双页，'
             '1280×720@59.26 Hz 显示'],
    ['声音', '每帧 3200 个 48 kHz 单声道样点 → HDMI 内嵌音频（LPCM 24 bit 左对齐 + ACR）→ 显示器内置喇叭'],
    ['交互', 'S0 短按下一个 / S1 短按上一个 / S0 长按 1 s 暂停（暂停后可逐项浏览，视频也能切到并播放）；'
             '数码管 = 总条数 + 当前序号，出错显示 E<n>'],
    ['资源', 'LUT 7 700 / 19 600（39.3%）、REG 6 181、BRAM 33 / 64、DSP 2 / 29、PLL 2 / 4'],
    ['时序', 'Setup SWNS +0.102 ns、Hold HWNS +0.003 ns，四个时钟域全部收敛、零违例端点'],
    ['代码', 'RTL 约 7 700 行（自写 + 厂商 IP 例化），Python 工具约 1 500 行（编码器 + 码率评估 + 离线模型）'],
    ['固化', 'bit 已写入 SPI 配置 Flash 并回读校验，断电重启自行加载（现场无需下载器）'],
    ['交付', 'proj/m6_media 工程、tools/m6_encode.py 片源编码器、out/VID000{5,6}.M5V 示例片源、七份里程碑报告'],
], widths=[2.2, 13.6], caption='最终成果速览')

PAGEBREAK()

# ===========================================================================
# 2 阶段一
# ===========================================================================
H('2  阶段一：HDMI 显示平台（M0 + M1）', 1)

H('2.1  目标', 2)
P('本阶段只解决一件事：让 FPGA 在显示器上输出稳定、时序正确的画面，并建立一个可被上层写满/读空的'
  '帧缓存。它是后面所有功能的地基——后面三个阶段的每个功能，最后都要落到「往帧缓存写像素」和'
  '「从帧缓存读像素上屏」这两件事上。')

H('2.2  M0：TMDS 输出与彩条', 2)
P('M0 采用「复用厂商加密 HDMI IP」的策略：把官方 board_test 里的 hdmi_1_4b_transmitter_core_wrapper、'
  'hdmi_phy_wrapper、lane_lvds_10_1 三个文件原样拷入新工程，改十个时序参数把默认 1080p 降到 640×480，'
  '再自写一个产生 8 条竖彩条的 AXIS 视频源。这样第一版工程就绕开了「HDMI 核无法从零构建」的最大风险。')
P('第一版成功的关键在于三件事：把工程文件版本号写成数字（TD 只认 6.2.190657 这种数字版号，写成 '
  'Release_2026.1_SP2 会让 open_project 直接 coredump）；为 25 MHz 像素时钟与 125 MHz 串行时钟写独立的 SDC'
  '（厂商旧约束按内部网名写，已失效）；接受 PLL 相位只能到 39.375° 的硬件限制（CLKCn_FPHASE 只有 3 bit，'
  '一步 0.125 ns，90° 超出范围）。')
P('SDC 前后踩了四次坑，是阶段一最耗时的部分：综合后 S_pixel_clk 的网名被改；u_pll/clk1_out 报 '
  '"No pins matched"（模块被 flatten，只剩宏实例 u_pll/pll_inst.clkc[1]）；create_clock 报 USR-8194；'
  'create_generated_clock 不允许同时 -multiply_by 与 -divide_by（USR-8157）。最隐蔽的一次是 exclusive '
  '时钟分组漏掉了 clk_50m，工具把「同源时钟」当跨域分析，直接报出 Setup −1.898 ns / Hold −3.906 ns 的'
  '假违例；把四个时钟全部放进互斥组后 WNS 回到 +5.501 ns。这条经验后来写成 timing.sdc 的固定模板。')
CODE([
    '# 串行时钟只能从像素时钟派生（TD 宏实例被 flatten 后的真实引脚名）',
    'create_generated_clock -name serial_clk -source [get_pins {u_pll/pll_inst.clkc[1]}] \\',
    '                       -multiply_by 5 [get_pins {u_pll/pll_inst.clkc[2]}]',
    '# PLL 相位反推：相位 = (CPHASE + 1 + FPHASE/8) / DIV × 360°',
    '#   720p: DIV=3, FPHASE=6 -> 90° ; 125 MHz: DIV=8 时 90° 需 FPHASE=16 > 7 -> 只能 39.375°',
], caption='M0：SDC 与 PLL 相位')
CODE([
    '// M0 的 HDMI 核例化（640×480 版本）',
    'hdmi_1_4b_transmitter_core_wrapper #(',
    '    .DEVICE       ("EG"),',
    '    .HTOTAL        (800),   .HSA  (96),  .HBP (48),  .HFP (16),  .HACTIVE (640),',
    '    .VTOTAL        (525),   .VSA  (2),   .VBP (33),  .VFP (10),  .VACTIVE (480),',
    '    .VIDEO_VIC     (1),     // 640×480p60',
    '    .VIDEO_TPG     ("Disable"),',
    '    .VIDEO_FORMAT  ("RGB"),',
    '    .AUDIO_SAMPLE_RATE ("48K"),',
    '    .IIC_SCL_DIV   (125)',
    ') u_hdmi_core ( ... );',
], caption='M0：把加密 IP 的时序参数从 1080p 改成 640×480')

H('2.3  M1：片内 SDRAM 双页帧缓存', 2)
P('本项目第一个「反直觉」的发现是：板上并没有 SDRAM 颗粒，但 FPGA 芯片内部有 8 MB SDRAM 硬宏。'
  '早期调研一度写成「板上无 SDRAM，只能放 512 KB 以内」，后来在官方例程 src/5640/sdram_ctrl_4p/sdram_ip.v '
  '里看到 EG_PHY_SDRAM_2M_32 的例化才纠正过来。这颗硬宏是后面所有帧缓存方案的基础。')
P('M1 用 Sdram_Control_4Port 的四端口控制器：WR1 写、RD1/RD2 读。两个 640×480×32 bit 的页面'
  '（各 307 200 字）分别由两个读端口锁定，写入永远指向「当前不在显示的那一页」，'
  '在帧起始（场消隐）时切换显示页，从而彻底避免撕裂。')
CODE([
    'Sdram_Control_4Port u_sdram (',
    '    .REF_CLK      (clk),                 // 50 MHz 参考',
    '    .RESET_N      (~S_rst_sdram),',
    '    .CLK          (S_sdram_clk),         // 100 MHz 工作时钟',
    '',
    '    // ---- 写端口 WR1：一次写一整页，128 字一个突发 ----',
    '    .WR1_DATA     (S_wr_data),   .WR1       (S_wr),',
    '    .WR1_ADDR     (S_wr_addr),   .WR1_MAX_ADDR (PAGE_END),',
    '    .WR1_LENGTH   (9\'h80),        .WR1_LOAD    (S_wr_load),',
    '',
    '    // ---- 读端口 RD1 / RD2：各锁一页，交给显示侧 ----',
    '    .RD1_DATA     (S_rd1_data),  .RD1  (S_rd1_re),',
    '    .RD1_ADDR     (PAGE_A_BASE), .RD1_MAX_ADDR (PAGE_A_END),',
    '    .RD1_LENGTH   (9\'h80),        .RD1_LOAD     (1\'b0),',
    '    .RD2_DATA     (S_rd2_data),  .RD2  (S_rd2_re),',
    '    .RD2_ADDR     (PAGE_B_BASE), .RD2_MAX_ADDR (PAGE_END),',
    '    .RD2_LENGTH   (9\'h80),        .RD2_LOAD     (1\'b0),',
    '    ... );',
], caption='M1：双页帧缓存的 SDRAM 四端口接法（页 A = 0x000000，页 B = 0x04B000）')
P('本阶段还做了离线周期级模型（Python），在没有板子的时候先把「写一页 + 读一页」的 FIFO 水位算清楚：'
  '读 FIFO 最低余量 152 字（6.1 µs），无读下溢、无写上溢，SDRAM 稳态占用 59.1%。'
  '这个模型后来成了整条工程的标准做法。')
P('M1 踩到的三个坑都很「硬件」：')
BUL([
    '字/字节地址混用：设计文档写的页 B 基址 0x12C000 是字节地址，直接填进 WR1_ADDR（字地址）会落到'
    '字地址 1 228 800（字节 4.69 MB），与页 A 隔 921 600 字的空洞、环形写失效。除以 4 得 0x04B000 后'
    '两页才首尾相接（页 A 0x00000~0x4AFFF、页 B 0x04B000~0x95FFF，环形 614 400 字）。',
    'WR1_LOAD / RD1_LOAD 都不清 FIFO（厂商代码里 aclr(WR1_LOAD) 被注释掉）：写 FIFO 的 AE=127 意味着最多'
    '滞留 127 个上一页的字，打一次 LOAD 会让整页永久右移 0~127 字；读 FIFO 更会压着旧页数据。'
    '最终改成「写侧不用 LOAD 的环形计数 + 两个读端口固定页 + 帧起始切 mux」。',
    '写侧丢字：最初用「寄存器输出 + 上一拍判 full」，最后一个字在 full 同拍被丢 → 整页少 1 字、'
    '环形地址永久错位 1 字。改成组合使能 O_wr = S_busy && !I_fifo_full 后消除。',
    '读 FIFO 阈值从 AF=128 提到 AF=256：模型下 RD2 最低余量从 24 字（0.96 µs）升到 152 字（6.1 µs），'
    '代价是启动多等一点，但换来了读端永不欠载。',
])

H('2.4  本阶段最难的地方', 2)
TABLE(['难点', '现象', '根因与解决'], [
    ['「板上到底有没有 SDRAM」的判断反复',
     '早期文档先写「无 SDRAM」，后写「有」，帧缓存方案差点被推翻',
     '以官方例程的 .ipc/硬宏例化为准：EG_PHY_SDRAM_2M_32 是片内硬宏、不占引脚；'
     '更正文档并改为双页帧缓存方案'],
    ['显示器只认 720p',
     '640×480 的设计烧进去，屏幕直接报 "not support"（这是后来上板才发现的）',
     '把整个显示链改成 1280×720@59.26 Hz：像素 73.333 MHz（50 MHz×22/15）、串行 366.667 MHz；'
     '画面按 640×480 窗口居中显示'],
    ['720p 下 SDRAM 写入死锁',
     '改 720p 后全黑，LED 长期 busy=1、页号不翻转',
     '页写入器的 HACTIVE/VACTIVE 描述的是「帧缓冲几何」而不是「画布几何」，720p 改造时误传 1280×720，'
     '写入器等 921 600 个像素而数据源只有 307 200 个 → 双向死锁。改为传 PAGE_W/PAGE_H=640/480'],
    ['Sdram_Control_4Port 只能顺序寻址',
     '读写同一页会互相覆盖、画面撕裂',
     '双页 + 场消隐换页；写页用「逐行 WR1_LOAD + 行末等 FIFO 恰好空」，保证页边界严格对齐'],
], widths=[3.4, 5.4, 7.4], caption='阶段一的主要难点')

H('2.5  指标', 2)
TABLE(['指标', 'M0', 'M1'], [
    ['顶层 / IO', 'm0_top / 6 个', 'm1_top / 7 个'],
    ['LUT', '1 244（6.35%）', '1 941（9.90%）'],
    ['FF', '1 127（5.75%）', '1 525（7.78%）'],
    ['BRAM', '8 / 64', '16 / 64'],
    ['PLL', '1 / 4', '2 / 4'],
    ['Setup WNS', '+5.501 ns', '+2.174 ns'],
    ['全清编译', '17.8 s', '29.8 s'],
    ['上板', '640×480 版未上板；720p 探测工程（m0_720p）上板确认显示器接受 720p',
     '未单独上板，随 M2 一起在 720p 播放器上验证'],
], widths=[3.6, 5.6, 5.6], caption='阶段一资源与时序')

PAGEBREAK()

# ===========================================================================
# 3 阶段二
# ===========================================================================
H('3  阶段二：TF 卡图像播放与交互（M2 + M3）', 1)

H('3.1  目标', 2)
P('让 FPGA 从 TF 卡读出真实文件并显示：SD 卡 SPI 模式 → FAT32（MBR/BPB/根目录/簇链）→ '
  '640×480 24 位 BMP 解析 → 写入 SDRAM 页；再加按键切图、自动轮播、暂停和 8 位数码管显示。')

H('3.2  SD 卡与 FAT32-lite', 2)
P('SD 层直接复用厂商 sd_card_control（SPI Mode3：初始化 400 kHz，数据 25 MHz），外面包一层'
  '「起始 / 扇区号 / 完成 / 看门狗超时复位」的封装 m*_sd_sec。文件层是自写的 FAT32-lite：')
BUL([
    'MBR（或 superfloppy）→ 分区 BPB：BPS=512、每簇扇区数、保留扇区、FAT 数、FATSz32、根目录簇号；',
    '根目录按簇链扫描 32 字节目录项，匹配 8.3 短文件名（如 IMG0001.BMP），最多 16 张；',
    '按 FAT 链把文件映射成扇区序列；读一页 640×480 24 bit BMP 约 2 030 个扇区（1 801 数据 + 226 FAT + 3 挂载），'
    '纯 SPI 时间约 0.386 s。',
])
P('BMP 解析校验 BM / biSize=40 / 640×480 / 24 bpp / 无压缩；处理自底向上行序、每行 4 字节对齐、BGR→RGB，'
  '并按 32 bit/像素打包写入 SDRAM。页写入改为「逐行 WR1_LOAD，一行 5 个 128 字突发，行末等 4 096 拍」，'
  '保证写 FIFO 在换页时恰好排空。')
P('本阶段有两个典型的设计权衡：')
BUL([
    '文件列表排序：最初用 16 项组合插入排序，综合后 WNS 直接掉到 −5.066 ns、关键路径 14.8 ns'
    '（扇区字节→数字检查→key mux→16 个比较器→优先级→16:1 写数组）。改成「按目录顺序追加 + 每项 2 拍的'
    '串行 min/max 扫描」（一次按键约 32 拍）后，逻辑量骤降、时序转正。',
    'BMP 自底向上 vs 写端口严格顺序：一行打一次 WR1_LOAD，靠「每行 640 字 = 5×128 突发 + 写 FIFO AE=127'
    '⇒ 行末 FIFO 字数必为 128 的整数倍」以及 4 096 拍 DRAIN（最坏 3×(138+2×138)=1 242 拍）保证 LOAD 时'
    'FIFO 干净；代价是约 19.7 ms/页。',
    'UART 调试通道：抓取前 8 次字节读取的 偏移(9b)/长度(6b)/FSM 状态(6b)/34 个原始字节，加实时状态'
    '与 6 条件检查位图，每 0.6 s 重发；PC 端 tools/read_uart.ps1 解码。它就是后面「55 55」这类硬 bug 的'
    '全部证据来源。',
])

H('3.3  交互与数码管', 2)
BUL([
    '按键消抖 2^18×40 ns = 10.49 ms，动作在「松开」时生效；KEY0 下一张、KEY1 上一张、KEY2 复位；',
    'KEY0 长按 ≥1.000 s 进入暂停/恢复（阈值从消抖后算，物理上要按 1.01 s）；'
    '自动轮播 3.0072 s/张（179 帧×16.8 ms 帧计数，不依赖毫秒精度），墙钟周期约 3.4 s（含 0.4 s 装载）；',
    '装载期间（约 0.4 s）按键被丢弃，避免状态竞争；无卡时禁止自动轮播，否则每 3 s 重试挂载 + 2.7 s 超时会闪屏；',
    '数码管 8 位动态扫描（1 kHz，刷新 125 Hz），经 2×74HC595 三线移位输出，显示「总数 + 图号」，'
    '错误显示 E1~E4，装载中点亮 DP，暂停时整屏 2 Hz 闪烁。',
])
P('数码管部分有三个细节值得记录：')
BUL([
    '任务书写「2 片 595 = 2 位数字」是错的：16 bit = 段码 8 + 位码 8，实际是 8 位数码管，所以 8 位全扫只用 6 位；',
    '厂商 HC595_Driver 每拍把 Data 重装移位寄存器，一帧移到一半时内容变化会混入新旧字（切图瞬间闪一下）。'
    '改为 I_start 当拍整字锁存、16 bit（6.8 µs）移完再打 RCLK；',
    '29 bit 状态总线跨域撕裂：100 MHz 侧多位同拍翻转，2FF 可能采到「旧低位+新高位」的混合值。'
    '用「相隔 1 ms 两次采样一致才接受」过滤（40 ns 瞬态跨不过两个采样点），代价是显示滞后 ≤2 ms。',
])

H('3.4  上板调试：五个 bug 与 UART 调试通道', 2)
P('本阶段第一次真正上板，一晚上从「黑屏」调到「正常出图」。最值得记录的是：屏幕上的一个黑屏，'
  '背后叠了五个互相独立的故障，其中两个来自厂商例程。')
TABLE(['#', 'bug', '现象', '根因与修复'], [
    ['①', '显示器丢锁', '烧完新 bit 后 no signal，拔插 HDMI 就正常',
     'FPGA 重配置时 TMDS 中断约 1 s，便携屏丢锁后不会自动重握手。不改 RTL，写进流程：每次烧写后拔插 HDMI'],
    ['②', '页写入器死锁', '全黑，LED 长期 busy=1，页号不翻转',
     '720p 改造时把画布尺寸 1280×720 传给了「一页帧缓冲的几何」参数，写入器等 921 600 像素而数据源只给 307 200 个 → 双向死锁'],
    ['③', '扇区缓冲 RAM 读延迟导致字节整体错位一格', 'MBR 签名读成 55 55（应为 55 AA），分区类型读成 0x00',
     'ram_dual_port_simple 是「第 t 拍看到第 t−1 拍地址的数据」，字节状态机在第 1 个字节那拍没递增地址 → 后面全滞后一格。在预处理拍也递增地址'],
    ['④', '厂商 SD 引擎的字节计数器不随 start 复位', '第 1 个扇区正确，第 2 个扇区起数据全乱',
     'sd_read_data 内部 cnt 只被 rst 清零。改为每次事务开始前把 SD 引擎复位 8 拍，使计数器归零'],
    ['⑤', 'BPB 检查混用两次读取的字段 + 偏移写错', 'err=2，换任何卡都失败',
     '34 字节窗口在一次读取后被覆盖，检查却跨两次读取取值；且注释把 TotSec32 当成 FATSz16。改为在 read#1 完成时锁存字段，再用锁存值检查'],
], widths=[0.8, 4.2, 5.2, 6.6], caption='阶段二上板遇到的五个 bug')
P('定位这些 bug 的关键武器是自写的 UART 调试通道（CH340E，115200）：抓取前 8 次字节读取的'
  '偏移/长度/状态/34 个原始字节，再加上实时状态与检查位图，每 0.6 s 重发。实现时踩了两个综合坑：'
  '用 304 字节数组 + for 循环写快照被 TD 综合成巨型多路器（100 MHz 域 SWNS −5.2 ns），改成 4 个扁平 '
  '293 bit 寄存器；字符生成组合链一条路径 11.5 ns（SWNS −1.4 ns），拆成 3 级流水。')

H('3.5  指标', 2)
TABLE(['指标', 'M2', 'M3'], [
    ['IO', '16', '19'],
    ['LUT', '4 458（22.74%）', '4 695（23.95%）'],
    ['FF', '3 939（20.10%）', '4 218（21.52%）'],
    ['BRAM', '17 / 64', '17 / 64'],
    ['Setup WNS', '+0.155 ns', '+0.744 ns'],
    ['全清编译', '67.5 s', '约 72 s'],
    ['离线模型', 'FAT32/BMP 80 项检查全通过', '交互/数码管 75 项检查全通过'],
    ['上板', '2026-10-22 出图', '随 M2 一起验证'],
], widths=[3.6, 5.6, 5.6], caption='阶段二资源与时序')

PAGEBREAK()

# ===========================================================================
# 4 阶段三
# ===========================================================================
H('4  阶段三：音频子系统（M4）', 1)

H('4.1  目标', 2)
P('把板载 WM8960 立体声 Codec 用起来：FPGA 通过 I²C 写 13 条寄存器完成初始化，'
  '再以 I²S 主机模式送出 48 kHz/16 bit 数据，先播放内部 1 kHz 正弦测试音验证整条模拟通路。')

H('4.2  12.288 MHz 音频时钟', 2)
P('WM8960 要求 MCLK = 256×fs。48 kHz × 256 = 12.288 MHz，而参考时钟是 50 MHz，'
  '不是整数倍关系。用连分数求最佳有理逼近，得到 VCO 725 MHz + 分频 C=59 的方案：'
  '50 MHz × (29/2) = 725 MHz，再 ÷59 = 12.288136 MHz，误差 +11 ppm（1 kHz 测试音实测 1000.011 Hz）。'
  '由此 BCLK = MCLK/4 = 3.072034 MHz、LRCK = BCLK/64 = 48.0005 kHz。')
P('这里有一个值得写进报告的数学结论：12.288 MHz 精确值在固定 VCO 的分频结构下是不可能得到的。'
  'M/(N·C) = 12.288/50 = 0.24576 = 768/3125，而 3125 = 5^5 与 768 互素，因此 N·C 必须是 3125 的倍数；'
  '最小可行 C=3125 对应 VCO 38.4 GHz，远超器件上限。用连分数 [0;4,14,2,26] 取收敛子 29/118 = 0.245763，'
  '得到 +11 ppm 的近似解——对 48 kHz 音频完全够用（1 kHz 测试音偏高 0.011 Hz）。'
  '我们也评估过 24.576 MHz 再二分频、以及逻辑小数分频（抖动 ±40 ns），前者同样无解，后者被抖动否决。')
CODE([
    '// pll_m5_audio：50 MHz -> 12.288136 MHz（VCO 725 MHz, C=59）',
    'EG_PHY_PLL #(',
    '    .FIN("50.000000"), .FEEDBK_MODE("NORMAL"), .FEEDBK_PATH("CLKC0_EXT"),',
    '    .REFCLK_DIV(1), .FBCLK_DIV(29),              // 50 × 29 = 725 MHz VCO',
    '    .CLKC0_ENABLE("ENABLE"), .CLKC0_DIV(59)      // 725 / 59 = 12.288136 MHz',
    ') pll_inst ( ... );',
], caption='音频 PLL：用连分数逼近出 12.288136 MHz')

H('4.3  WM8960 的 I²C 初始化', 2)
P('厂商例程的寄存器表（被命名为 ES8388_init_table.v，内容却是 WM8960）逐条复核后发现 7 处缺陷：'
  '器件地址写成 0x20（那是 ES8388 的地址，WM8960 的 7 位地址是 0x1A、写地址 0x34）；'
  '控制字只发 1 个数据字节（WM8960 是 7 位地址 + 9 位数据 = 2 字节）；R7 写成右对齐而注释说 I²S；'
  'R25/R26/R34/R37/R47 从未写（VREF/VMID、输出缓冲、混音器全没上电）；没有解除 DAC 静音；'
  '没有 VMID 充电延时。我们按数据手册 Rev 4.2 重写了 13 条表：')
TABLE(['#', '寄存器', '值', '作用', '延时'], [
    ['0', 'R15 复位', '0x000', '软复位到已知默认态', '1 ms'],
    ['1', 'R4 Clocking(1)', '0x000', 'SYSCLK←MCLK、DACDIV/ADCDIV=÷256 → fs=48 kHz', '—'],
    ['2', 'R7 Audio IF', '0x002', 'FORMAT=I2S、WL=16 bit、MS=0（从机）', '—'],
    ['3/4', 'R10/R11 DAC 音量', '0x0FF', '左右 DAC 数字音量 0 dB', '—'],
    ['5/6', 'R34/R37 混音', '0x100', 'DAC 接入左右输出混音器（断开 Line-In 默认通路）', '—'],
    ['7', 'R25 Power 1', '0x0C0', 'VREF + VMID 上电（所有模拟块基准）', '500 ms'],
    ['8', 'R26 Power 2', '0x1E0', 'DACL/DACR + LOUT1/ROUT1 输出缓冲上电', '10 ms'],
    ['9', 'R47 Power 3', '0x00C', '输出混音器上电', '10 ms'],
    ['10', 'R5 ADC&DAC', '0x000', '解除 DAC 静音（默认是静音）', '10 ms'],
    ['11/12', 'R2/R3 耳机音量', '0x079', '左右耳机 0 dB', '—'],
], widths=[1.0, 3.4, 1.6, 8.2, 1.6], caption='重写后的 WM8960 13 条初始化表')
P('时序上：I²C 40.06 kHz（分频 312×4），每条 673.9 µs，13 条共 551.3 ms；每条都检查 ACK，'
  'NACK 重试 3 次，失败即静音（DACDAT 恒 0），避免在显示器/耳机里放噪声。')
P('几个容易踩的寄存器细节：解除静音是 R5 的 bit3（DACMU，默认是静音），不是 R6；'
  'R2/R3 耳机音量复位默认 0x000 = −73 dB，必须最后写，否则上电会有 POP 声；'
  'R13/R12 是保留寄存器，MCLK/fs 的分频在 R4（DACDIV/ADCDIV），不是「R13 写 0x00 表示 MCLK/LRCK 比」；'
  '厂商注释里「R8 bit7 = 主模式」也是错的（主从在 R7 bit6，R8 没有主从位）。')

H('4.4  I²S 发送', 2)
P('FPGA 做 I²S 主机：帧 64 个 BCLK，LRCK 低为左声道；数据在 BCLK 下降沿更新，'
  'MSB 出现在 LRCK 翻转后的第 2 个上升沿（严格 Philips I²S），16 bit 数据放在 32 bit 槽的高 16 位。'
  '采样值在帧起点被锁存，同时给音源一个 O_tick 脉冲，让音源推进到下一个样点。')
CODE([
    '// 每个 BCLK 下降沿（S_mcnt==0）更新 slot / LRCK / DACDAT',
    "wire [5:0] S_nslot = S_slot + 6'd1;",
    "wire [4:0] S_off   = S_nslot[4:0];                  // 0..31 半帧内槽号",
    'wire [15:0] S_src  = S_nslot[5] ? S_sr : S_sl;       // 右 / 左样点',
    "wire [3:0] S_bidx  = (5'd16 - S_off);                // 数据位下标",
    "wire S_bitv = ((S_off >= 5'd1) && (S_off <= 5'd16)) ? S_src[S_bidx] : 1'b0;",
    '...',
    'if (S_mcnt == 2\'d0) begin          // BCLK 下降沿',
    "    O_bclk   <= 1'b0;",
    '    S_slot   <= S_nslot;',
    '    O_lrck   <= S_nslot[5];        // 半帧边界翻转 LRCK',
    '    O_dacdat <= I_en ? S_bitv : 1\'b0;',
    "    if (S_nslot == 6'd0) begin     // 新帧：锁存样点并给音源 tick",
    '        S_sl <= I_sample;  S_sr <= I_sample;  O_tick <= 1\'b1;',
    '    end',
    'end',
], caption='I²S 主机的槽生成与时序（m5_i2s_tx.v）')

H('4.5  上板调试：两个 bug', 2)
P('上板后耳机只有上电 POP 声。LED 显示「音频 PLL 锁 + I²C NACK」，说明播放器本身是好的、只有 codec 配不上。'
  '第一步不是改代码，而是写了一个 50 行的 I²C 总线扫描器（DEBUG_AUDIO=2，ASCII 打到串口）：'
  '扫到 0x1A ACK —— 板上 codec 确实是 WM8960，总线、上拉、引脚全部正常，问题只能是帧时序。')
TABLE(['#', 'bug', '现象', '根因与修复'], [
    ['⑥', '多字节 I²C 帧字节之间多一个 SCL 脉冲', '单字节扫描全部 ACK，3 字节寄存器写全部 NACK',
     'bit 引擎每写完一个字节（含 ACK）就回 idle，而 idle 无条件把 SCL 拉高；ACK 结束时 SCL 本是低，'
     '于是从机在字节之间看到多余上升沿，把后续字节当数据位 → NACK。加 S_hold 标志：非最后一字节结束时 '
     'SCL 保持低、只释放 SDA，等下一个字节直接在低电平期间放数据；只有 STOP 后才回空闲高'],
    ['⑦', 'I²S 引脚接反，还把 codec 的输出脚当输出驱动', '出声前先查引脚时发现管脚表与核心板原理图冲突',
     '管脚表写 A8=DACLRC/A7=DACDAT，但 AC601 核心板原理图与厂商可运行工程的 IO.adc 都是 A8=数据、A7=时钟；'
     '且 C7 是 codec 的 ADCDAT 输出脚，原来当 ADCLRC 推挽输出，等于和 codec 对顶。改为 LRCK→A7、DACDAT→A8，删除 C7 输出'],
], widths=[0.8, 4.0, 5.0, 7.0], caption='阶段三的两个 bug（I²C 帧时序、I²S 引脚）')
P('修好后：D3（PLL 锁）+ D2（初始化 OK）常亮、D1（NACK）灭，复位后约 0.55 s 耳机出 1 kHz 正弦'
  '（−6.02 dBFS，THD+N −55.6 dB）。')

H('4.6  指标', 2)
TABLE(['指标', '数值'], [
    ['新增 IO', '7 个：I2S_MCLK(B8)、I2S_BCLK(C8)、I2S_DACLRC(A7)、I2S_DACDAT(A8)、I2C_SCL(L16)、I2C_SDA(M16，三态)'],
    ['时钟', '新增第 5 个时钟域 mclk_audio = 12.288136 MHz（第 3 个 PLL）'],
    ['LUT / FF / BRAM', '5 101（26.03%）/ 4 444 / 18'],
    ['PLL', '3 / 4'],
    ['Setup WNS', '+0.111 ns（mclk 域余量 +73.5 ns）'],
    ['测试音', '1 kHz（1000.011 Hz）、48 kHz、−6.02 dBFS、THD+N −55.6 dB'],
    ['离线模型', '146 项检查全通过（PLL 数学 / 寄存器位域 / 厂商表缺陷 / I²C 位流 / I²S 波形 / 正弦 / 引脚）'],
], widths=[3.4, 12.4], caption='阶段三指标')
P('遗留风险：音频 PLL 的 725 MHz VCO 环路滤波参数是照同器件 1000 MHz 配置抄的，没有仪器实测抖动；'
  '若出现锁相不稳，退路是 12.3457 MHz（+0.47% ≈ 8 音分，人耳几乎不可辨）。')

PAGEBREAK()

# ===========================================================================
# 5 阶段四
# ===========================================================================
H('5  阶段四：音视频一体播放（M5）', 1)

H('5.1  目标与 M5V1 片源格式', 2)
P('最后一个阶段把前三个阶段串起来：从 TF 卡读一个视频文件，实时解码成 720p 画面，'
  '同时把每帧的音频送进 HDMI，由显示器内置喇叭放出来。视频格式是我们自己定义的 M5V1——'
  '没有现成解码器，就必须让格式足够简单、足够适合 RTL 实现：帧内 RLE、RGB332、固定 15 fps、'
  '固定采样率。')
TABLE(['文件头字段（32 B）', '值', '说明'], [
    ['magic', '"M5V1"', '解码器靠它重同步'],
    ['width × height', '320 × 240', '源分辨率（显示时 2×2 放大到 640×480）'],
    ['fps', '15', '与音频 48 kHz/3200 样点严格对应'],
    ['bpp', '1（RGB332）', '1 字节 1 像素；也支持 2（RGB565）'],
    ['frames', '286', '片长 ≈19 s，播完自动重同步循环'],
    ['audio_rate / audio_ch', '48000 / 1', '单声道 s16le'],
    ['first_frame', '32', '首帧块偏移'],
    ['audio_samples_total', '915 200', '286×3200'],
], widths=[4.2, 4.0, 7.6], caption='M5V1 文件头')
TABLE(['每帧块结构', '长度', '说明'], [
    ['payload_len（u32 大端）', '4 B', 'RLE 数据长度（含结束 token）'],
    ['audio_samples（u16）', '2 B', '本帧音频样点数 = 3200'],
    ['bpp 回读（u16）', '2 B', '=1，用于帧头自检'],
    ['RLE payload', '17.7~19 KB', 'token：01xx=repeat（count=(tok&0xFFF)+1，后跟 1 字节像素）、'
                                   '10xx=literal（count 个字节像素）、0=帧结束'],
    ['音频', '6 400 B', '3200 个 s16le 样点'],
], widths=[5.0, 3.2, 7.6], caption='M5V1 每帧块结构')
P('片源由 tools/m5_encode.py 生成：ffmpeg 解码 → 320×240 RGB332 → RLE（numpy 找游程）→ 与音频交错写文件。'
  '最终示例文件 7 443 761 B，平均码率约 3.1 Mbit/s。')

H('5.2  数据流与关键模块', 2)
BUL([
    'm5_sd_sec：把厂商 SD SPI 引擎包成「读一个扇区」的事务（含事务前复位 8 拍、看门狗超时）。',
    'm5_stream：MBR → BPB → 根目录扫描 VID0.M5V → 按「线性扇区」连续读取（文件在卡上连续时不需要逐簇查 FAT），'
    '把扇区数据搬进 512 B 双口 RAM，再用 valid/ready 字节握手把字节流推出；文件结尾自动回卷循环。',
    'm5_vdec：M5V1 解码器（19 态状态机）——重同步 → 32 B 文件头 → 帧块头 → RLE token → 行缓冲 → '
    '2×2 放大 → 写 SDRAM 连续环（WR1）→ 音频定长消费。每帧发 ready 脉冲通知显示侧换页。',
    'm5_video_src720：显示侧从 RD1/RD2 读当前页，把 640×480 画面居中放进 1280×720 画布（窗口偏移 320,120），'
    '并在 vstart 时按 ready 脉冲交换页。',
    '两个 m5_aud_fifo：把每帧 3200 个样点分别送到 12.288 MHz 域（I²S/WM8960）和 73.333 MHz 像素域（HDMI 音频）。',
])

H('5.3  音频双路：I²S 与 HDMI 内嵌音频', 2)
P('声音有两条并行通路。I²S 通路沿用阶段三的 WM8960（耳机口）；HDMI 通路是本阶段的重点：'
  '每帧音频先进入异步 FIFO，读出侧用像素时钟做 48 kHz 采样脉冲，再连同 ACR（音频时钟再生）参数一起'
  '送给加密 HDMI 核，核内部自动完成 data island 打包、BCH 校验与保护带插入。')
P('48 kHz 与 73.333 MHz 像素时钟不是整数关系：73 333 333 / 48 000 = 1 527.9 个像素时钟一个样点。'
  '用 32 bit 相位累加器取进位作为采样脉冲，步长 step = round(48000×2^32/73333333) = 2 811 250，'
  '实际采样率 47.9999 kHz。ACR 每 48 个样点（1 ms）发一次，N=6144、CTS=两次 ACR 之间实测的像素时钟数'
  '（≈73 333），接收端按 fs = f_pixel×N/(128×CTS) 恢复音频时钟——换分辨率/换像素时钟都不用改参数。')
CODE([
    '// 48 kHz 采样脉冲：32 bit 累加器，取加法进位（1 拍脉冲）',
    "wire [32:0] S_aph_nx = {1'b0, S_aph} + 33'd2811250;",
    'wire        S_aud48  = S_aph_nx[32];      // 47.9999 kHz, 1 个像素时钟宽',
    '',
    '// ACR：每 48 个样点输出一次 cts = 这段区间实测的像素时钟数',
    "wire S_acr = I_audio_valid && (S_div == (AUDIO_DIV - 1));   // AUDIO_DIV = 6144>>7 = 48",
    'O_acr_valid <= S_acr;',
    'O_acr_cts   <= S_acr ? (S_cts + 20\'d1) : 20\'d0;',
    'O_acr_n     <= S_acr ? ACR_N[19:0]     : 20\'d0;',
], caption='HDMI 音频：48 kHz 采样脉冲与 ACR 包生成')
CODE([
    '// 加密 HDMI 核的音频端口（与厂商 design_top_wrapper 的接法一致）',
    '.I_audio_valid      (S_aud48),',
    ".I_audio_left_data  ({S_hdmi_src, 8'h00}),   // 16 bit 样点左对齐放入 24 bit",
    ".I_audio_right_data ({S_hdmi_src, 8'h00}),   // 单声道送左右两声道",
    '.I_acr_valid        (S_acr_valid),',
    '.I_acr_cts          (S_acr_cts),',
    '.I_acr_n            (S_acr_n),',
], caption='HDMI 内嵌音频接线')

H('5.4  六个关键 bug', 2)
P('本阶段最长的一段是「画面先通了、声音没通」，最后一口气挖出六个 bug。它们互相叠加：'
  '前两个让视频流错位，第三个让一次错位污染后面所有帧，后三个分别卡住时序、HDMI 音频和字节序。')
TABLE(['#', '现象', '根因', '定位证据', '修复'], [
    ['①', '画面局部花屏、帧被截断',
     '字节握手用寄存器输出：进入新状态第一拍 ready 仍是 0，但状态机已按 I_byte_valid 前进 → '
     '一个流字节被当成两个 token 字节用，每触发一次丢一个字节',
     '7 段显示 endv=0x0D74（首次结束符位置），正常应为 0x4522；反推帧块头位置正好落在真实帧头前 1 字节',
     '把 O_byte_ready 改成由状态组合解码，与 FSM 采样 I_byte_valid 同拍'],
    ['②', '帧块头整体偏移、error=4',
     '文件头最后一个字节「正在移入」的那一拍就做 bpp 比较，S_hdr 仍只有 28 字节 → bpp 读成 0x0F00 → '
     '走兜底分支多吞 1 字节',
     '7 段显示帧块头 00450A0C，而正确值是 0000450A（差 1 字节）',
     '字段改从下一拍值 {S_hdr[247:0], I_byte} 提取；保留 28/29 两种提取做容错'],
    ['③', '偶发错位会污染后续帧',
     '帧边界完全依赖 RLE 结束符，一次误判后所有帧都错位',
     '帧块头自带的 payload_len 一直没用上',
     '用帧块头长度算出绝对边界 S_pend，提前结束就丢弃余量（V_PSKIP）；音频按 2×aud_n 定长消费；'
     '非法长度则重新同步'],
    ['④', '100 MHz 域时序违例（SWNS −0.455 ns）',
     '32 bit 加法 S_vbyt + S_len 叠在「状态解码→握手→消费计数」后面，路径 8 级逻辑 10.175 ns > 10 ns',
     'final_timing.rpt 最差路径：u_vdec/S_st → S_byte_want → W_consume → 加法器',
     '把 S_pend 计算移到独立状态 V_PEND（操作数都是寄存器），SWNS 回到 +0.225 ns'],
    ['⑤', '显示器发出满幅噪声、ACR 全错',
     'HDMI 采样脉冲用了 33 bit 累加器取 bit32，实际有一半时间为高 → I_audio_valid 变成几十 MHz',
     '给显示器放 1 kHz 测试音：仍嘈杂；查代码发现脉冲不是单拍',
     '改成 32 bit 累加器（模 2^32）取加法进位 bit32 → 干净的单拍 48 kHz'],
    ['⑥', '有声音但「很大声的乱码嘈杂」',
     '编码器用 ffmpeg -f s16le（小端）存音轨，RTL 却按大端拼样点 → 每个样点高低字节互换',
     '用文件数据分别按小端/大端解释：小端是平滑波形（ZCR 0.21），大端是随机跳变（ZCR 0.46、高频能量 3.2 倍）',
     '改为 O_aud_data <= {I_byte, S_aud_hi}（小端：第一个字节作低字节）'],
], widths=[0.7, 3.2, 4.6, 4.4, 4.4], font=8.5, caption='阶段四的六个关键 bug')

H('5.5  调试方法与可观测性', 2)
P('这块板没有板载 USB 串口，上板调试只能靠 4 个 LED 和 8 位数码管。为此我们把数码管改造成「寄存器窗口」：'
  '4 页调试字每 0.67 s 轮播（原始字节探针、解析结果、错误/结束符位置、音频 FIFO 计数），'
  '4 个 LED 编码「卡挂载 / 有错误 / 解码中 / 音频在流」，再用照片/录像把数值读回来。'
  '当问题落到「丢了几个字节」这种粒度时，先离线用 Python 复现候选现象的签名（正常/每扇区丢 1 字节/'
  '每扇区重复 1 字节/起始偏移 1~3 字节各对应什么字节位置与行数），再拿上板读数对号入座——'
  '这比逐次改 RTL 试错快一个数量级。')
BUL([
    '先量出来再改代码：帧块头字节、endv（结束符位置）、FIFO 计数、bpp 提取值都做成可读数值，'
    '而不是靠「看起来像不像」。',
    '一个现象先做 A/B：换回已知能跑的 bit、拔插 HDMI、换卡，把环境问题与设计问题切开。',
    '把「字节位置」当第一等公民：音视频两个通路的所有谜题最后都收敛到「流的第几个字节」，'
    '所以探针永远按字节位置采样，不依赖解析逻辑。',
])

H('5.6  指标', 2)
TABLE(['指标', '数值'], [
    ['片源', '7 443 761 B，320×240 RGB332@15 fps，286 帧，48 kHz 单声道（平均码率 ≈3.1 Mbit/s）'],
    ['LUT / REG / BRAM / DSP', '5 363（27.36%）/ 4 068 / 48 / 64 / 4 / 29'],
    ['PLL', '3 / 4（100 MHz、73.333&366.667 MHz、12.288 MHz）'],
    ['Setup / Hold', 'SWNS +0.138 ns / HWNS +0.003 ns，零违例端点'],
    ['全清编译', '约 100 s（syn ≈ 30 s + phy ≈ 70 s）'],
    ['上板', '1280×720 画面连续播放 + 显示器内置喇叭原声，2026-10-24 验证通过'],
], widths=[4.0, 11.8], caption='阶段四指标')

PAGEBREAK()

# ===========================================================================
# 6 阶段五 M6
# ===========================================================================
H('6  阶段五：图文混排播放列表（M6）', 1)
P('前四个阶段各解决一类问题：显示、存储与交互、音频、音视频一体。但它们都是「一个工程演一件事」——'
  'M3 只播图片，M5 只播一个写死名字的视频文件。阶段五（M6）把它们合成用户真正要的东西：'
  '一个播放列表里既有照片又有视频，上电自动顺序播放，按键与长按规则和 M3 完全一致，'
  '数码管只显示「一共几条 / 正在播第几条」。')

H('6.1  目标与四条现实需求', 2)
P('需求是 M5 验收后由使用者直接提出的，四条，没有任何技术限定：')
NUM([
    '把新的两段视频（连同 M5 的老片源）和原来的 5 张照片放进同一个播放列表；',
    '上电默认顺序播放；点按按键的逻辑与之前一致（S0 下一个 / S1 上一个）；',
    '长按 S0 的行为与之前一致（暂停 / 恢复），但暂停之后视频也要能被切换并播放；',
    '数码管前面显示总条数、后面显示正在播第几条，不要再出现视频时的「帧号/地址乱码」。',
])
P('这四条看着只是功能叠加，实际逼出三个架构决策：① 列表必须是混排的一份，否则两套播放器各扫一遍目录、'
  '数量与序号必然对不上；② 两个播放引擎必须共用同一套 SD 引擎与帧缓存，因为硬件只有一份；'
  '③ 暂停的语义必须从「冻结数据流」改成「停自动前进」，否则暂停后切到视频永远解不出画面。')

H('6.2  架构：一个列表 + 两个引擎 + 单一 owner', 2)
P('M6 没有另起炉灶，而是把 M3 的 FAT32/BMP 引擎与 M5 的 RLE 解码链路接在同一套存储与显示通路上，'
  '新增的是一个「播放列表引擎」和一个「所有权仲裁器」：')
TABLE(['模块', '职责', '来自'], [
    ['m6_fat', 'mount、根目录一次扫描建混排列表、按 key 选择并维护当前排名、BMP 头检查与像素流、'
               '把视频条目的 {首簇, 文件长度} 交给视频引擎', 'M3 的 m3_fat_bmp 升级'],
    ['m6_page_wr / m6_pix_pump / m6_byte_seq', '逐行 128 字突发把一页写完；把扇区里的 BGR 变成 24 bit 像素',
     'M3 原样'],
    ['m6_vstream', '给定首簇/长度/mount 参数，把文件当字节流吐出（512 B 一块，valid/ready 交接）',
     '新写（M5 里 mount+目录扫描整段删除）'],
    ['m6_vdec', 'M5V1 RLE 解码、×2 放大、每帧 307 200 字连续写 WR1 环形、48 kHz 音频还原',
     'M5 的 m5_vdec + 三处改动'],
    ['m6_video_src720', '1280×720 光栅、640×480 居中窗口、按键消抖/长短按、3.02 s 自动换图、页交换',
     'M3/M5 同一份 + I_auto_en'],
    ['m6_top', 'SD 引擎 / 厂商扇区 RAM 读口 / WR1 写口 / 页脉冲的 owner 多路选择；视频引擎 arm-run-stop 调度；'
               'HDMI 内嵌音频', '新写'],
], widths=[4.2, 8.0, 3.6], font=8.5, caption='阶段五的模块划分')

P('最关键的一处是「一个 SD 引擎，两个所有者」。视频与图片不可能同时进行，所以只要保证任意时刻只有一个引擎'
  '在碰 SD 与 WR1 即可：m6_fat 在 mount / 扫描 / 装图时拥有资源；一旦它选中视频条目就进入 S_VID、'
  '拉高 O_vid_req，m6_top 把视频引擎从复位里放出来并接管；视频结束（解码器数完文件头里的帧数）后，'
  'm6_top 先停引擎并回 I_vid_idle，m6_fat 才允许再动 SD/WR1。')

P('另一个关键点是「不重复 mount」。m6_fat 已经把 data_lba / fat_lba / spc / log2spc 解析出来了，'
  '直接连同首簇与文件长度交给 m6_vstream，后者只做「簇 → 扇区」的算术和簇链遍历——'
  '省掉了 M5 里「每段视频重新初始化 SD 卡 + 重新扫目录」的 40~200 ms，也让切换更干净。')

H('6.3  播放列表规则与按键语义', 2)
P('文件名就是播放顺序，规则只有两条：类型前缀决定条目种类，数字决定排序键。')
TABLE(['名字模式', '类型', 'key（17 bit）', '例子'], [
    ['IMG<编号>.BMP', '照片', '{1\'b0, 编号}', 'IMG0001.BMP → 0x00001'],
    ['VID<编号>.M5V', '视频', '{1\'b1, 编号}', 'VID0005.M5V → 0x10005'],
], widths=[4.4, 2.0, 4.2, 5.2], font=9, caption='文件名 → 排序 key')
P('编号允许 1~4 位十进制（其余名字节为空格），所以老的 M5 片源 VID0.M5V 也能进列表（编号 0）。'
  '播放顺序 = key 升序：先按编号，同编号时照片排在视频前；默认命名（5 张照片 + 3 段视频）'
  '自然就是「5 张照片，然后 3 段视频」。要换顺序改文件名编号即可，不用改 RTL。')

P('位置显示（数码管右 4 位）不能直接用数组下标：列表按目录顺序存放（M3 为了避开 100 MHz 上的 16 路'
  '比较器，故意不排序），所以 M6 维护一个 1 起的排名计数器 S_rank——「下一个」就是 rank+1（扫描发现'
  '没有更大的 key 说明到尾，回到 1），「上一个」就是 rank−1（已经最小则变成总数）。'
  '这样显示的永远等于真实播放顺序里的位置，和目录顺序无关。')

TABLE(['操作', '行为'], [
    ['S0（KEY0）短按', '下一个：照片立刻换页、视频立刻切走'],
    ['S1（KEY1）短按', '上一个'],
    ['S0 长按 ≥1 s', '暂停 / 恢复。暂停只停「自动往下走」：照片停住；视频照常播（因此暂停中短按可以逐项浏览，'
                     '视频也能切到并播放）；视频播完停在最后一帧，不自动进下一项'],
    ['自动播放', '照片每 179 帧（3.02 s）自动换下一项；视频由解码器按文件头里的帧数自己判断结束'],
], widths=[3.6, 12.2], font=9, caption='按键语义（与 M3 一致）')

H('6.4  三个真 bug 与一次时序事故', 2)
P('阶段五的调试只用了 4 次上板：每次上板前先用串口把内部状态变成可读数字。这一阶段把调试串口升级成'
  '「在每段视频结束时锁存当时的内部状态再周期性打印」——因为最关键的故障（视频只播 0.1 s 就没了）'
  '在 0.5 s 轮询下根本抓不到。')
TABLE(['#', '现象', '根因', '定位证据', '修复'], [
    ['①', '视频只出第一帧，然后被下一张照片从下往上刷掉、没有声音',
     'm6_vstream 读 FAT 表项早取一拍：本地扇区缓冲是寄存器输出口（地址→下一拍数据），'
     '状态机在设地址的下一拍就取数 → FAT 返回值全错 → 簇链从第一簇之后跳到随机簇（空白区，全 0）',
     '串口快照 err=4 / frm=0001 / vbyt=byt=0x0000B9FD（正好一帧的字节数）/ 下一个「帧块头」全 0；'
     '离线核对编码文件在该偏移处其实是合法头',
     '换成 M5 已验证的四状态取数引擎（设地址→等一拍→取字节→移位）'],
    ['②', '数码管总条数 07、序号却涨到十几；最后一段视频永远播不到',
     '列表扫描在「最后一个条目」那一拍用的是寄存器里旧的候选标志，最后一个数组元素永远没机会成为「下一个」；'
     '列表是目录顺序，最后一段视频恰好排在最后 → 它永远不被选中，位置计数器与真实顺序脱节',
     '串口显示 key 永远到不了 0x10006、rank 超过 count',
     '把「本条目是否更优」做成组合逻辑参与最后一拍判决（C_have_gt | W_gt_hit）'],
    ['③', '画面被横向切成长条、从右边挪到左边（照片正常）',
     '100 MHz 时序违例 SWNS −0.543 ns：`(帧计数+1) >= 帧数`（16 bit 加法 + 16 bit 关系比较，'
     '11 级逻辑 10.263 ns）正好压在解码器的帧边界判断上，帧写指针偶发错位 → 整幅画面横向错位',
     'final_timing.rpt 最差路径：u_vd/lt10 → S_st；逻辑 11 级、数据路径 10.263 ns',
     '帧数与音频字节改成递减计数器（`== 1` 是宽与门），SWNS 回到 +0.102 ns，条纹消失'],
    ['④', '暂停（长按 S0）之后只能切图片，切不到视频',
     '暂停被实现成「冻结字节流」，切到视频时字节流仍被冻结 → 解码器永远解不出画面，只有序号在变',
     '用户复述现象；串口 sst/vst 常驻 0（视频引擎从未真正运行）',
     '暂停只停自动前进（去掉字节流的暂停门控）；视频播完若处于暂停则停在最后一帧（S_vid_hold）'],
], widths=[0.7, 3.0, 4.4, 4.4, 4.2], font=8.5, caption='阶段五的四个问题')

P('另外还修了两个「半 bug」：视频最后一帧的换页要等到下一个行消隐才生效，而装图逻辑立刻按'
  '「当前显示页取反」选目标页，于是新照片被画在马上要显示的那一页上（表现为从上往下的刷屏）——'
  '加 25 ms 落定等待再选页；以及 RLE 像素计数器只有 12 bit，遇到 4096 像素的 token 会绕回 0，'
  '导致每帧少写 1 个像素、literal token 还会错位——加宽到 13 bit。')

H('6.5  片源编码与带宽账', 2)
P('M5 的编码器固定 RGB332、不做质量取舍，实测真实影片一帧要 ~47 kB，15 fps 就是 705 kB/s，'
  '超过 TF 卡（5 MHz SPI）能给的约 0.6 MB/s。M6 的编码器加入逐帧字节预算：每帧从无损 RGB332 开始试，'
  '超预算就依次降档（4 级量化 → 3×3 中值 + 4 级量化 → 2 级量化），直到 ≤ 36 kB。')
TABLE(['文件', '帧数', '时长', '大小', '平均负载', '峰值', '需求带宽（含 FAT 开销）'], [
    ['VID0005.M5V', '579', '38.6 s', '19.7 MB', '28.7 kB', '36.0 kB', '524 kB/s'],
    ['VID0006.M5V', '371', '24.7 s', '13.0 MB', '29.5 kB', '36.0 kB', '536 kB/s'],
], widths=[3.0, 1.4, 1.6, 2.0, 2.2, 1.8, 3.8], font=8.5, caption='两段新片源的编码结果')
P('自适应档位命中率大致是：无损 RGB332 约 51%、4 级量化约 33%、中值+4 级约 16%、2 级 1%。'
  '同时把卡时钟从 5 MHz 提到 12.5 MHz，链路可用带宽约 1.0~1.1 MB/s，视频占约 50%，'
  '峰值帧也只到 ~70%——早期「一卡一卡」的 5 s 段落就是 50 kB 预算下追不上链路造成的。')

H('6.6  固化到 SPI 配置 Flash', 2)
P('演示当天不能指望笔记本 + 下载线，所以最后把 bit 写进板子的 SPI 配置 Flash：')
CODE([
    r'# 固化（约 87 s）+ 回读校验（约 28 s），掉电重启仍然生效',
    r'powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\flash.ps1 -Proj m6_media -Mode program_spi',
    r'powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\flash.ps1 -Proj m6_media -Mode verify_spi',
], caption='SPI Flash 固化流程')
P('上位机通过 AL-LINK 用 BitWriter 的 program_spi / verify_spi 模式完成，无需额外工具。'
  '实测：断电、拔掉 USB 下载线、重新上电，板子自行加载 M6 并进入播放列表。')

H('6.7  指标', 2)
TABLE(['指标', '数值'], [
    ['播放列表', '示例 8 条（5 张 BMP + 3 段 M5V），上限 16 条（MAXF）'],
    ['照片加载', '640×480×24 bit ≈ 0.9 MB，12.5 MHz SPI 约 0.6 s/张（M3 的 5 MHz 是 1.5 s）'],
    ['视频', '320×240 RGB332@15 fps，峰值 36 kB/帧；12.5 MHz SPI 下链路占用约 50%'],
    ['音频', '48 kHz 单声道，HDMI 内嵌音频（LPCM 24 bit + ACR N=6144）'],
    ['LUT / REG / BRAM / DSP / PLL', '7 700（39.29%）/ 6 181 / 33 / 64 / 2 / 29 / 2 / 4'],
    ['Setup / Hold', 'SWNS +0.102 ns / HWNS +0.003 ns，零违例端点'],
    ['全清编译', '约 158 s（syn ≈ 55 s + phy ≈ 103 s）'],
    ['上板', '2026-10-28：混排播放、按键、暂停浏览、数码管计数、HDMI 原声、断电自启动全部验证通过'],
], widths=[4.4, 11.4], caption='阶段五指标')

PAGEBREAK()

# ===========================================================================
# 7 关键技术
# ===========================================================================
H('7  贯穿全工程的关键技术', 1)

H('7.1  时钟域与跨时钟域设计', 2)
P('阶段一~四有五个时钟域，全部由 50 MHz 晶振经 PLL 派生；阶段五删掉了音频 PLL（不再用 WM8960 的 I²S 支路），'
  '只剩四个域。跨域只有三类结构：2FF 同步、Gray 码指针异步 FIFO、以及「标志位 + 单次脉冲」的握手。')
TABLE(['时钟域', '频率', '来源', '主要负载'], [
    ['clk（50 MHz）', '50 MHz', '板载晶振 K14', 'I²C 初始化、数码管扫描、按键、UART'],
    ['sdram_clk（100 MHz）', '100 MHz', 'Sdram_PLL', 'SD 引擎、FAT32/解码状态机、SDRAM 写、音频 FIFO 写侧'],
    ['pixel_clk', '73.333 MHz', 'pll_hdmi_720p C1', '显示读、HDMI 核、HDMI 音频采样脉冲/ACR'],
    ['serial_clk', '366.667 MHz', 'pll_hdmi_720p C2（90°）', 'TMDS 10:1 串行化'],
    ['mclk_audio', '12.288 MHz', 'pll_m5_audio C0', '仅阶段三/四使用（I²S 发送、WM8960 MCLK）；'
                                                      '阶段五已删除，省下 15 个 BRAM'],
], widths=[3.4, 2.6, 4.0, 6.4], caption='阶段一~四的五个时钟域（阶段五为前四个）')

H('7.2  SDRAM 带宽预算', 2)
P('显示侧每个刷新周期只读当前页的 640×480 窗口像素：307 200 字 × 59.26 Hz ≈ 18.2 M 字/s。'
  '解码侧每帧写一整页：307 200 字 × 15 fps ≈ 4.6 M 字/s。合计约 22.8 M 字/s × 4 B ≈ 91 MB/s，'
  '占 100 MHz×32 bit = 400 MB/s 理论带宽的 23% 左右；即使加上 SDRAM 刷新、行切换与四端口仲裁开销，'
  '仍有充足余量。这也是为什么「单页读写会撕裂、但双页方案在带宽上完全可行」。')

H('7.3  时序收敛史', 2)
P('EG4S20 对 100 MHz 域并不宽裕，每个阶段都出现过负余量。下表是修复记录，'
  '可以看到收敛的手段始终是「把组合逻辑从关键路径上拿下来」：')
TABLE(['阶段', '最差路径', '根因', '修法', '修复后 SWNS'], [
    ['M2', '100 MHz 域 5 449 端点', 'RAM 读延迟带来的长组合链', '字节状态机预处理拍也递增地址', '+0.155 ns'],
    ['M2', 'UART 快照多路器', '304 字节数组 + for 循环被综合成巨型多路器', '改成 4 个扁平 293 bit 寄存器', '由 −5.2 ns 转正'],
    ['M2', 'UART 字符组合链', '索引→字节→十六进制一条链 11.5 ns', '拆成 3 级流水（UART 一位 868 拍）', '由 −1.4 ns 转正'],
    ['M3', '100 MHz 域', '同一份 RTL 多次编译在 0.15~0.74 ns 之间跳（布线受限）', '不改逻辑，接受并记录', '+0.744 ns'],
    ['M4', '100 MHz 域', 'M3 继承路径', '—', '+0.111 ns'],
    ['M5', 'u_vdec 状态→握手→32 bit 加法', '帧尾位置计算叠在状态解码之后', '独立状态 V_PEND', '−0.455 → +0.225 ns'],
    ['M6', 'u_vdec 帧边界：帧计数 +1 与 16 bit 关系比较串联',
     '11 级逻辑；而且压在帧边界判断上，出错表现为画面横向错位', '帧数/音频字节改递减计数器（== 1）',
     '−0.543 → +0.102 ns'],
], widths=[1.4, 4.6, 5.2, 4.4, 2.4], font=8.5, caption='时序收敛记录')

H('7.4  离线验证与构建可复现性', 2)
P('没有逻辑分析仪、上板机会有限，所以每个阶段都先写 Python 周期级模型，把状态机「照抄」一遍做穷举检查。'
  '这既是验证手段，也是定位工具：当上板现象与模型不符时，差异往往直接指向 bug。')
TABLE(['阶段', '离线模型', '检查项', '覆盖内容'], [
    ['M1', 'model_sdram_fb.py', 'FIFO 水位/占用率', '读 FIFO 最低余量 152 字、无下溢/上溢、SDRAM 占用 59.1%'],
    ['M2', 'model_fat32_bmp.py', '80 项', '造 FAT32 卡 + 照抄 RTL 状态机：MBR/BPB/根目录/簇链/BMP 头/行序/页地址/失败回退'],
    ['M3', 'model_m3_ctrl.py', '75 项', '消抖、长短按、暂停、轮播计时、装载期丢键、段码/位序/DP/闪烁、595 帧格式'],
    ['M4', 'model_m4_audio.py', '146 项', 'PLL 数学、寄存器位域、厂商表缺陷、I²C 位流、I²S 波形、正弦、引脚一致性'],
    ['M6', 'measure_m5_bitrate.py / 帧格式校验', '全帧', '逐帧统计 RLE 负载求码率上界；'
     '逐帧走 token 校验像素数是否恰为 76 800、payload 是否恰好消费完（把「画面错位」先从片源里排除掉）'],
], widths=[1.4, 3.6, 2.2, 8.6], font=8.5, caption='各阶段的离线验证')
P('构建可复现性用「两次独立全清编译」验证：M1 393 行、M2 1 057 行、M3 1 287 行、M4 1 218 行 payload '
  '逐行一致，Bitstream CRC 相同。这保证「文档里写的参数」与「烧进板子的 bit」是同一份东西。')

H('7.5  厂商代码的使用原则', 2)
P('项目复用了厂商的 HDMI 加密 IP、SDRAM 控制器、SD SPI 引擎，但没有把它们当「正确实现」，'
  '而是当「参考实现」：每个文件先读懂再决定复用/重写/包装。实际踩到的厂商缺陷：')
BUL([
    'SD 引擎的字节计数器只被 rst 清零、不被 start 清零（只在「按一次读一个扇区」的演示里不出错）；',
    'WM8960 寄存器表：地址写成 ES8388 的 0x20、控制字只发 1 个数据字节、关键电源/静音/混音寄存器从未写；',
    'HDMI 720p 例程里有 1080p 的参数错配（video_source_test 传的是 1080p 时序），说明该分支未被真正使用；',
    '板测工程把 HDMI 的 I²S 音频输入接死 0 —— 我们阶段四证明这颗加密核的 HDMI 音频是可用且能驱动显示器喇叭的。',
])

PAGEBREAK()

# ===========================================================================
# 7 难点总表
# ===========================================================================
H('8  难点问题总表', 1)
P('下表汇总全工程 18 个「现象→根因→定位→修复」记录，按阶段排序。它同时是一份踩坑手册：'
  '同类问题（时钟域、RAM 延迟、握手时序、字节序）在本项目里反复出现，规律性很强。')
TABLE(['#', '阶段', '现象', '根因', '定位手段', '修复'], [
    ['1', '一', '显示器报 not support（640×480）', '显示器只认 720p', '换分辨率试', '全链改 720p（73.333/366.667 MHz）'],
    ['2', '一', '改 720p 后全黑、busy 常亮', '页写入器把画布尺寸当帧缓冲尺寸', 'LED/页号观察', '传 PAGE_W/PAGE_H=640/480'],
    ['3', '二', '重烧 bit 后 no signal', '显示器丢锁不自动重握手', 'A/B 拔插 HDMI', '烧写后必拔插 HDMI（写进流程）'],
    ['4', '二', 'MBR 签名 55 55', '扇区 RAM 读延迟导致字节错位一格', 'UART 打印 34 字节原始窗口', '预处理拍也递增地址'],
    ['5', '二', '第 2 个扇区起数据乱', '厂商 SD 引擎字节计数器不复位', 'UART 对比字段', '每次事务前复位引擎 8 拍'],
    ['6', '二', 'BPB 检查永远失败', '跨两次读取混用窗口 + 偏移注释错', '6 个检查合成 bitmap 得到 0x16', '读取完成时锁存字段'],
    ['7', '二', 'UART 快照导致 SWNS −5.2 ns', '304 字节数组被综合成巨型多路器', '时序报告', '改扁平寄存器'],
    ['8', '三', '单字节 I²C ACK、多字节 NACK', '字节间 SCL 多余上升沿', 'I²C 扫描器 + 帧时序分析', 'S_hold：字节间 SCL 保持低'],
    ['9', '三', '耳机无声/引脚冲突', '管脚表与核心板原理图冲突、codec 输出脚被当输出', '核心板原理图 + 厂商 IO.adc 交叉验证', 'LRCK→A7、DACDAT→A8、删 C7 输出'],
    ['10', '四', '画面花屏、帧截断', '字节握手 ready 晚一拍 → 丢字节', '7 段 endv=0x0D74 vs 0x4522', 'ready 改组合逻辑'],
    ['11', '四', '帧块头偏移 1 字节', '头字段在「正在移入」那拍比较', '7 段 00450A0C vs 0000450A', '用下一拍值提取 + 双提取兜底'],
    ['12', '四', '一次误判污染后续帧', '帧边界只靠结束符', '帧块头长度字段未使用', '定长边界 S_pend + V_PSKIP'],
    ['13', '四', '显示器满幅噪声/ACR 全错', '采样脉冲用 33 bit 累加器取 bit32（半周期为高）', '给显示器放 1 kHz 测试音仍嘈杂', '32 bit 累加器取进位'],
    ['14', '四', '声音很大但全是乱码嘈杂', '音频 s16le 被按大端拼样点', '文件数据按两种字节序分别算 ZCR/频谱', '按小端拼 {低字节, 高字节}'],
    ['15', '五', '视频只出第一帧、随后被照片刷掉、没声音',
     'FAT 表项取数早一拍（扇区缓冲是寄存器输出口）→ 簇链跳到错簇',
     '串口快照 vbyt=byt=一帧字节数、下一个帧块头全 0；离线核对片源该偏移是合法头', '换 M5 的四状态取数引擎'],
    ['16', '五', '序号超过总条数、最后一段视频永不播',
     '列表扫描最后一拍用旧候选标志，最后一个条目永远选不中',
     '串口 key 到不了 0x10006；rank > count', '候选判断组合化，最后一拍并入判决'],
    ['17', '五', '画面横向被切一条挪到左边（照片正常）',
     'SWNS −0.543 ns：帧计数 +1 与 16 bit 比较串联（10.263 ns）压在帧边界判断上',
     'final_timing.rpt 最差路径 u_vd/lt10 → S_st，11 级逻辑', '改递减计数器，SWNS +0.102 ns'],
    ['18', '五', '长按暂停后只能切图片、切不到视频', '暂停被实现成冻结字节流',
     '串口 sst/vst 常驻 0（视频引擎从未运行）', '暂停只停自动前进 + 视频播完停帧（S_vid_hold）'],
], widths=[0.7, 0.9, 4.0, 4.4, 4.0, 4.0], font=8, caption='全工程难点问题总表')

PAGEBREAK()

# ===========================================================================
# 8 成果与展望
# ===========================================================================
H('9  成果、复现与展望', 1)

H('9.1  最终交付物', 2)
TABLE(['交付物', '位置', '说明'], [
    ['最终工程', r'proj\m6_media', 'RTL + 约束 + 一键构建脚本（顶层 m6_top），混排播放列表'],
    ['片源编码器', r'tools\m6_encode.py', '任意视频 → M5V1（RGB332 RLE + 48 kHz 单声道 + 逐帧字节预算）'],
    ['码率评估', r'tools\measure_m5_bitrate.py', '只取几十帧就能估出「按这个码率编，链路够不够」'],
    ['示例片源', r'out\VID0005.M5V / VID0006.M5V', '19.7 MB / 13.0 MB，插到 TF 卡 FAT32 根目录'],
    ['烧写工具', r'tools\flash.ps1', 'AL-LINK：SRAM（约 19 s）/ SPI 配置 Flash 固化（约 87 s）'],
    ['里程碑报告', r'docs\research\m0..m6-report.md', '每个阶段的实现、验证、风险与决策记录'],
    ['上板复盘', r'docs\research\bench-bringup-postmortem.md', '9 个 bug 的现象→根因→证据→修法'],
    ['演示脚本', r'docs\demo-script.md', '§7 是 M6 现场演示的 8 步流程、LED/数码管读数与排障'],
], widths=[3.0, 6.4, 6.4], font=9, caption='最终交付物')

H('9.2  复现步骤', 2)
CODE([
    '# 0) TF 卡根目录（FAT32、8.3 名字）：',
    r'#    IMG0001.BMP … IMG0005.BMP  +  VID0.M5V / VID0005.M5V / VID0006.M5V',
    '',
    '# 1) 生成片源（任意视频 → M5V1，逐帧字节预算 36 kB）',
    r'python tools\m6_encode.py <video> out --name VID0007.M5V --max-kb 36',
    '',
    '# 2) 生成工程文件 + 全清构建（约 158 s，会打印 SWNS/HWNS）',
    r'cd E:\fpga-2026\dsh_code\proj\m6_media',
    r'powershell -NoProfile -ExecutionPolicy Bypass -File .\make_proj_files.ps1',
    r'powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1',
    '',
    '# 3) 烧 SRAM 调试（约 19 s；烧完拔插一次 HDMI 让显示器重新锁屏）',
    r'cd E:\fpga-2026\dsh_code',
    r'powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\flash.ps1 -Proj m6_media',
    '',
    '# 4) 固化到 SPI 配置 Flash（约 87 s）+ 回读校验（约 28 s），断电重启仍生效',
    r'powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\flash.ps1 -Proj m6_media -Mode program_spi',
    r'powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\flash.ps1 -Proj m6_media -Mode verify_spi',
    '',
    '# 5) 调试串口（CH340，115200 8N1，板子第二个 USB-C）',
    r'powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\read_uart.ps1 -Seconds 30',
], caption='从零复现的完整命令')

H('9.3  已知问题与后续规划', 2)
TABLE(['项目', '现状', '建议'], [
    ['耳机（WM8960/I²S）通路', '阶段三的遗留问题：初始化成功、样点已写入 FIFO，但耳机无声；M6 已把这条支路删除，'
     '交付的声音路径是 HDMI 内嵌音频', '若要恢复：排查耳机座、输出混音器与音量寄存器、I²S 数据对齐'],
    ['暂停时切到视频', '从第一帧开始播（不是「继续上次位置」）',
     '当前语义是「选择即播放」，够演示；若要逐帧浏览需给解码器加单帧步进'],
    ['照片加载期间的按键', '只排队不打断（M3 既有行为，最多同时排队 3 个）', '若要求「按了立刻切」，需在装图中加中止路径'],
    ['切换项的间隔', '视频→下一项有 25 ms 落定等待 + 一帧首帧延迟', '这是为了不撕裂；可改为「提前一帧预写」来省掉停顿'],
    ['列表容量', '上限 16 条（MAXF）', '要更多就把 m6_fat 的 MAXF 调大，代价是 17 bit key 的寄存器阵列变宽'],
    ['卡/文件命名', '只认 IMG/VID + 1~4 位数字 + 对应扩展名', '不符合的条目会被忽略；这是刻意的可预测行为'],
    ['SPI 时钟档位', '12.5 MHz（另有 5/10/25 可选）', '换卡若不稳，改 m6_sd_sec.v 一行回 10 MHz，片源不用重编'],
    ['分辨率/码率提升', '320×240 RGB332@15 fps，峰值 36 kB/帧', 'RGB565 + 更优压缩可提画质；注意 SDRAM 与 SPI 余量'],
], widths=[3.0, 6.8, 6.0], font=8.5, caption='已知问题与后续规划')

H('9.4  经验总结', 2)
NUM([
    '先做可观测性，再做功能：上板第一件事是把内部状态变成可读数字（串口/数码管/LED），'
    '而不是对着屏幕猜。本项目两次最长的调试（阶段二、阶段四）都靠这条。',
    '把「现象」翻译成「字节位置/时钟拍数」：所有音视频谜题最后都收敛到「流的第几个字节」或'
    '「第几拍有效」，能量化的现象才是可修的 bug。',
    '握手必须按同拍语义设计：valid/ready 只要有一方是寄存器输出，就要检查「进入新状态第一拍」的行为。',
    '凡是有 RAM 的地方都要问「数据是第几拍有效的」：扇区缓冲的读延迟让整个文件系统「流程全对、数据全错」。',
    '坐标系必须命名隔离：画布 / 窗口 / 帧缓冲 / 扇区，四个几何不要共用一个 HACTIVE。',
    '厂商代码是参考实现，不是正确实现：先读懂再复用，缺陷要写进文档（本工程遇到 4 处）。',
    '时钟域尽量少、跨域结构尽量统一（2FF / Gray FIFO / 标志握手三类），每加一个域都写进 SDC。',
    '离线模型是廉价的上板：周期级 Python 模型能在没有硬件时验证状态机，也能在出 bug 时提供对照。',
    '每个 bug 都按「现象→根因→证据→修法→固化到流程」记录：文档本身就是下一次调试的工具。',
    '构建可复现性要量化：两次全清编译的 payload 逐行一致 + CRC 相同，才算「代码就是烧进去的东西」。',
    '时序违例不要只看「设备能不能跑」：阶段五那条 −0.543 ns 的路径正好落在帧边界判断上，'
    '表现不是死机而是「画面横向错位」——一有时序违例就先当成功能 bug 的嫌疑人。',
    '短命故障要「锁存现场」：视频只播 0.1 s 就消失，0.5 s 轮询抓不到；改成「事件发生那一刻把状态锁存下来再打印」，'
    '一次上板就能定位。',
])

PAGEBREAK()

# ===========================================================================
# 附录
# ===========================================================================
H('附录 A  工程目录结构', 1)
CODE([
    r'E:\fpga-2026\dsh_code',
    r'├─ proj/',
    r'│   ├─ m0_hdmi/        阶段一：HDMI 彩条（640×480）',
    r'│   ├─ m0_720p/        720p 彩条探测工程',
    r'│   ├─ m1_sdram_fb/    阶段一：SDRAM 双页帧缓存',
    r'│   ├─ m2_sd_tf_bmp/   阶段二：SD/FAT32/BMP',
    r'│   ├─ m2_720p/        720p 版图片播放器',
    r'│   ├─ m3_interact/    阶段二：交互与数码管',
    r'│   ├─ m3_720p/',
    r'│   ├─ m4_audio/       阶段三：音频（离线模型工程）',
    r'│   ├─ m4_720p/        阶段三：基于 720p 播放器的音频版',
    r'│   ├─ m5_video/       阶段四：音视频一体播放（m5_top）',
    r'│   └─ m6_media/       阶段五：最终交付工程（m6_top，混排播放列表 + 固化）',
    r'├─ tools/              flash.ps1 / m5_encode.py / m6_encode.py / measure_m5_bitrate.py / read_uart.ps1 ...',
    r'├─ docs/               specs/ research/（m0..m6-report.md）/ demo-script.md board-test-guide.md',
    r'├─ out/                生成的片源（VID0.M5V / VID0005.M5V / VID0006.M5V，不入库）',
    r'└─ sim/                离线周期级模型与检查脚本',
], caption='仓库结构（只列关键项）')

H('附录 B  关键参数速查', 1)
TABLE(['参数', '值'], [
    ['显示时序', 'HTOTAL 1650 / HACTIVE 1280 / VTOTAL 750 / VACTIVE 720，VIC=4，59.26 Hz'],
    ['像素 / 串行时钟', '73.333 MHz / 366.667 MHz（HDMI PLL：50 MHz×22/15、÷3）'],
    ['帧缓存', '页 A 0x000000~0x04AFFF，页 B 0x04B000~0x095FFF，每页 307 200 字（640×480×32 bit）'],
    ['SDRAM 访问', 'WR1 写、RD1/RD2 读，128 字突发，100 MHz，32 bit'],
    ['SD 卡', 'SPI Mode3，初始化 400 kHz；阶段一~四数据 5 MHz，阶段五 12.5 MHz（M3 注释里的 25 MHz 实测不可用）'],
    ['M5V1 片源', '320×240 RGB332 RLE，15 fps，48 kHz 单声道 s16le，每帧 3200 样点，峰值 36 kB/帧'],
    ['播放列表', 'key = {is_video, 1~4 位编号}（17 bit），升序播放，上限 16 条；数码管 = 总数 + 当前排名'],
    ['HDMI 音频', 'LPCM 24 bit 左对齐，48 kHz（47.9999 kHz），ACR：N=6144、CTS≈73 333'],
    ['I²S / WM8960', 'MCLK 12.288136 MHz、BCLK 3.072034 MHz、LRCK 48.0005 kHz，I²C 40.06 kHz、器件 0x34（7 位 0x1A）'],
    ['按键/数码管', '消抖 10.49 ms；数码管 1 kHz 扫描、2×74HC595 三线'],
    ['最终资源/时序', 'LUT 39.3%（7 700）、BRAM 33/64、DSP 2/29、PLL 2/4；SWNS +0.102 ns、HWNS +0.003 ns'],
    ['固化', 'SPI 配置 Flash：program_spi 约 87 s + verify_spi 约 28 s，断电重启自行加载'],
], widths=[3.6, 12.2], font=8.5, caption='关键参数速查')

TABLE(['错误码', '含义（M6 交付版）'], [
    ['E1', 'SD 卡初始化失败（没插好 / 接触不良 / 不支持 SPI 模式）'],
    ['E2', '不是 FAT32 / BPB 字段不合法'],
    ['E3', '根目录里没有 IMGnnnn.BMP 或 VIDnnnn.M5V'],
    ['E4', 'BMP 头不对（不是 640×480 24 bit），或视频文件头/帧块头非法'],
    ['E5', 'MBR 的 0x55AA 签名不对（扇区数据是坏的），或视频帧内找不到结束符'],
    ['E6', '图片文件比 640×480 需要的还小，或视频扇区读超时'],
    ['E7', '分区表里没有可接受的分区项，或视频 FAT 读超时'],
    ['—', '无错误时数码管显示「总条数 + 当前序号」'],
], widths=[2.0, 13.8], font=9, caption='错误码（数码管显示 E<n>）')

H('附录 C  里程碑文档与提交索引', 1)
TABLE(['里程碑', '文档', '关键提交', '上板结论'], [
    ['M0', r'docs\research\m0-report.md', 'a694ed6 / f0087e9', '640×480 彩条编译通过；720p 探测通过'],
    ['M1', r'docs\research\m1-report.md', '373934c', '双页帧缓存编译通过（离线模型验证）'],
    ['M2', r'docs\research\m2-report.md', 'efd1735 / c58a25f / 5476242', '2026-10-22 上板出图（修 5 个 bug）'],
    ['M3', r'docs\research\m3-report.md', 'f2420bc / f27b691 / 76d62dd', '随 M2 一起验证'],
    ['M4', r'docs\research\m4-report.md', 'b58bd00 / 610193f / b0c57ae', '2026-10-23 耳机 1 kHz 出声'],
    ['M5', r'docs\research\m5-report.md', 'bdd5f26 / 4b7578d / 4635ea5', '2026-10-24 画面+显示器喇叭原声'],
    ['M6', r'docs\research\m6-report.md', '850f93d / 4353524 / c664153',
     '2026-10-28 混排播放、按键/暂停浏览、数码管计数、断电自启动全部通过'],
], widths=[1.4, 4.6, 5.0, 4.8], font=8.5, caption='里程碑文档与提交索引')

H('附录 D  工具链与构建坑清单', 1)
P('TD 2026.1 SP2 的脚本化使用过程中踩到的工具问题，按「现象→原因→绕过」记录，供换机/换版本时参考：')
TABLE(['现象', '原因', '绕过方法'], [
    ['open_project 直接 coredump', '.al 里的 TD_Version 写成 Release_2026.1_SP2 字符串', '改成数字版号 6.2.190657'],
    ['create_clock 报 USR-8194 / No pins matched', '综合后网名被改；PLL 模块被 flatten，只剩宏实例 u_pll/pll_inst.clkc[n]', '用宏实例引脚名写 SDC'],
    ['create_generated_clock 报 USR-8157', '不允许同时 -multiply_by 与 -divide_by', '拆成两次或用 -edges'],
    ['假跨域违例（Setup −1.898 / Hold −3.906 ns）', 'exclusive 时钟组漏掉了 clk_50m', '四个时钟全部放进互斥组'],
    ['read_ipc_file 把盘符路径截断', '工具路径解析缺陷', '不脚本化生成 IP，PLL 复制厂商文件手改分频'],
    ['set arr_filter true 直接崩', '本 flow 未实现该选项', '不做 arr_filter，靠 RTL 降组合深度救时序'],
    ['编译失败但 console_ci.log 里错误为空', 'HDL-8007 多驱动等错误只写进 td_*.logw', '失败时同时看 logw 文件'],
    ['两次编译 bit 不完全相同', 'bit 头带编译时间', '比较 payload 逐行与 Bitstream CRC，而不是整文件 SHA'],
], widths=[5.6, 6.0, 4.8], font=8.5, caption='TD 工具链坑清单')

PAGEBREAK()
p = doc.add_paragraph()
p.alignment = WD_ALIGN_PARAGRAPH.CENTER
r = p.add_run('—— 全文完 ——')
r.font.size = Pt(11)
r.font.color.rgb = RGBColor.from_string('808080')

# 保存
os.makedirs(os.path.dirname(OUT), exist_ok=True)
doc.save(OUT)
print('saved:', OUT)
print('paragraphs:', len(doc.paragraphs), 'tables:', len(doc.tables))
