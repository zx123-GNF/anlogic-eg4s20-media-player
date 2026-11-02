# dsh_code — FPGA 比赛 · 安路赛道 第 1 题（EG4S20 HDMI 多媒体播放器）

选题一：**EG4S20 HDMI 多媒体播放**。板子 **AC208**（AC201-EG4S20 底板 + AC601 核心板，芯片
**EG4S20BG256**，片内 8 MB SDRAM 硬宏），工具 **TangDynasty TD 2026.1 SP2**（`E:\bin`，license
`E:\license\Anlogic.lic`）。

> 状态时间戳：**2026-10-28**。比赛交稿截止 **2026-11-04 18:00**，决赛 11/20–22。
>
> **最终版 = `proj/m6_final`（M6 改名而来，顶层 `m6_top`）**：TF 卡里的照片（`IMGnnnn.BMP`）和视频
> （`VIDnnnn.M5V`）合成**一个播放列表**，上电自启动顺序播放，视频带 HDMI 内嵌音频；bit 已固化在
> SPI 配置 Flash 里，断电重启仍然生效。

## 现在做到哪了

| 里程碑 | 工程 | 输出 | 板上验证 |
|---|---|---|---|
| M0 探测 | `proj/m0_hdmi` | 640×480 彩条 | ❌ 屏不收 480p（"not support"） |
| M0-720p 探测 | `proj/m0_720p` | **1280×720 彩条** | ✅ **通过**（锁定了 720p 输出方案） |
| M1 | `proj/m1_sdram_fb` | SDRAM 双缓冲 + 渐变测试图 | ✅ 通过（离线模型 + 720p 版） |
| M2 | `proj/m2_720p` | TF 卡 BMP 播放器，1280×720 输出 | ✅ **通过**（照片正常显示） |
| M3 | `proj/m3_720p` | M2 + 数码管 + 短按换图 + 长按暂停 + 3 s 自动轮播 | ✅ **通过**（数码管/按键/换图实测正常） |
| M4 | `proj/m4_720p` | M3 + WM8960 音频（I²C 初始化 + I²S + 1 kHz 正弦） | ✅ 通过（耳机 1 kHz 出声） |
| M5 | `proj/m5_video` | M5V1 视频软解码 + 双页环形写 + HDMI 内嵌音频 | ✅ **通过**（画面 + 显示器喇叭原声） |
| **M6（最终版）** | **`proj/m6_final`** | **照片 + 视频混排播放列表、按键/暂停浏览、数码管总数+序号、SPI Flash 固化** | ✅ **通过**（2026-10-28，断电自启动；`program_spi` + `verify_spi` 均通过） |

> 老的 640×480 工程（`m0_hdmi`、`m1_sdram_fb`、`m2_sd_tf_bmp`、`m3_interact`、`m4_audio`）保留作
> 历史对照与离线模型工程。**正式方案全部跑 1280×720**，原因见下「关键约束」。

## 一条命令干活

```powershell
# 编译（每个工程目录下，30~160 秒）
cd E:\fpga-2026\dsh_code\proj\m6_final
powershell -NoProfile -ExecutionPolicy Bypass -File .\make_proj_files.ps1   # 改了 RTL 文件清单才需要
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1             # 打印 SWNS/HWNS

# 烧录 SRAM（临时，约 19 s；AL-LINK 插好 + 板上电即可，不用开 BitWriter 图形界面）
cd E:\fpga-2026\dsh_code
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\flash.ps1 -Proj m6_final

# 固化到 SPI 配置 Flash（约 87 s）+ 回读校验（约 28 s），断电重启仍然生效
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\flash.ps1 -Proj m6_final -Mode program_spi
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\flash.ps1 -Proj m6_final -Mode verify_spi

# 读调试串口（板子 USB-C = CH340E，115200 8N1）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\read_uart.ps1 -Seconds 30
```

**烧完一定要拔插一次 HDMI 线**：这块便携屏在 FPGA 重配置导致 TMDS 中断后不会自己重新锁定。

## TF 卡内容（M6 最终版）

FAT32，根目录（8.3 名字）：

```
IMG0001.BMP … IMG0005.BMP      5 张 640×480 24 bit 照片
VID0.M5V                        M5 时代的演示视频（编号 0，所以排在第 1 段）
VID0005.M5V / VID0006.M5V       本次两段（本仓库 out/ 下由 tools/m6_encode.py 生成）
```

播放顺序 = 文件名里的 1~4 位编号升序（同编号时照片在视频前），所以默认就是「5 张照片 → 3 段视频 → 循环」。
数码管左 4 位 = 总条数，右 4 位 = 正在播第几条；出错显示 `E<n>`（含义见
[`docs/research/m6-report.md`](docs/research/m6-report.md) §9 与 `docs/demo-script.md` §7.3）。

## 目录

| 目录 | 内容 |
|---|---|
| `proj/m6_final/` | **最终版工程**（M6 改名而来；`rtl/` 源码、`IO.adc` 引脚、`timing.sdc` 时钟、`make_proj_files.ps1`、`build.ps1`） |
| `release/` | 代码包 `fpga安路一题代码.zip`（全部阶段代码 + 全部调试日志，5.8 MB） |
| `proj/m5_video/` | 上一版交付工程（单文件视频播放器），保留作回归对照 |
| `proj/m*_720p/` | 各里程碑的正式工程（`proj/m*_interact`、`proj/m4_audio` 等是 640×480/离线模型工程） |
| `docs/` | `board-test-guide.md` 上板手册、`demo-script.md` 演示脚本（§7 = M6）、`specs/` 设计规格 |
| `docs/research/` | 硬件事实、工具链坑清单、`m0..m6-report.md` 里程碑报告、`bench-bringup-postmortem.md` 底层 bug 复盘 |
| `docs/report/` | **五阶段工程汇报（Word）** 与它的生成脚本 `make_engineering_report.py` |
| `tools/` | `flash.ps1` 烧录/固化、`read_uart.ps1` 串口、`m6_encode.py` 片源编码、`measure_m5_bitrate.py` 码率评估、`make_bmp.py` 等 |
| `demo/` | 6 张 640×480 测试图 |

## 关键约束（都吃过亏）

1. **显示器只认 1280×720**：这块便携屏原生 1024×600，喂 640×480 直接报 "not support"。所以输出固定
   1280×720@59.26 Hz（像素时钟 73.333 MHz，来自厂商 `pll_hdmi1_4b`），640×480 帧缓冲**居中显示**。
2. **HDMI 全靠 FPGA 直接打 TMDS**：板上没有 HDMI 发送芯片，也**没有 DDC/EDID/HPD**，只能固定时序输出。
3. **TF 卡是 SPI 1 bit**：CLK=M2 MOSI=L3 MISO=K6 CS=R2，无 CD/WP，只在**复位后**初始化（不支持热插拔）。
   卡必须 FAT32、根目录 8.3 文件名。阶段一~四数据时钟 5 MHz，**M6 提到 12.5 MHz**（25 MHz 实测读数据会坏）。
4. **LED 低电平点亮**：`led[3:0] = {在放视频, 有错误, 正在装图/解码, 卡已挂载}`，亮 = 该位为 1（对外取反）。
5. **按键**：S0=下一项、S1=上一项、长按 S0（≥1 s）=暂停/恢复、S2=复位；板上没有摇杆。
6. **片内 SDRAM 控制器只能顺序流式访问**，两页帧缓冲各 307200 字；视频帧正好一页，所以连续写就能自动落在页边界。
7. **像素缓冲与视频帧缓冲共用 WR1**：M6 里 SD 引擎、WR1 写口、页完成脉冲都靠一个 owner 多路器仲裁，
   两个播放引擎不能同时动硬件。

## 提交

见 [`docs/submission-checklist.md`](docs/submission-checklist.md)。设计报告里的「调试过程」章节直接用
[`docs/research/bench-bringup-postmortem.md`](docs/research/bench-bringup-postmortem.md)，
五阶段汇总报告见 [`docs/report/`](docs/report/)，可提交的完整代码包见
[`release/fpga安路一题代码.zip`](release/)。
