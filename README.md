# dsh_code — FPGA 比赛 · 安路赛道 第 1 题（EG4S20 HDMI 多媒体播放器）

选题一：**EG4S20 HDMI 多媒体播放**。板子 **AC208**（AC201-EG4S20 底板 + AC601 核心板，芯片
**EG4S20BG256**，片内 8 MB SDRAM 硬宏），工具 **TangDynasty TD 2026.1 SP2**（`E:\bin`，license
`E:\license\Anlogic.lic`）。

> 状态时间戳：**2026-10-23**。比赛交稿截止 **2026-11-04 18:00**，决赛 11/20–22。

## 现在做到哪了

| 里程碑 | 工程 | 输出 | 板上验证 |
|---|---|---|---|
| M0 探测 | `proj/m0_hdmi` | 640×480 彩条 | ❌ 屏不收 480p（"not support"） |
| M0-720p 探测 | `proj/m0_720p` | **1280×720 彩条** | ✅ **通过**（锁定了 720p 输出方案） |
| M1 | `proj/m1_sdram_fb` | SDRAM 双缓冲 + 渐变测试图 | ❌ 未验证（640×480 版） |
| M2 | `proj/m2_720p` | **TF 卡 BMP 播放器，1280×720 输出** | ✅ **通过**（照片正常显示） |
| M3 | `proj/m3_720p` | M2 + 数码管 + 短按换图 + 长按暂停 + 3 s 自动轮播 | ✅ **通过**（数码管/按键/换图实测正常） |
| M4 | `proj/m4_720p` | M3 + WM8960 音频（I2C 初始化 + I2S + 1 kHz 正弦） | ✅ **通过**（耳机 1 kHz 出声，D3+D2 常亮 = PLL 锁 + 寄存器全 ACK） |
| M5 | — | 联调 / 演示打包 / 演示脚本 | 🚧 文档进行中 |

> 老的 640×480 工程（`m0_hdmi`、`m1_sdram_fb`、`m2_sd_tf_bmp`、`m3_interact`、`m4_audio`）保留作
> 历史对照。**正式方案全部跑 1280×720**，原因见下「关键约束」。

## 一条命令干活

```powershell
# 编译（每个工程目录下，30~150 秒）
cd E:\fpga-2026\dsh_code\proj\m2_720p
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1

# 烧录（不用开 BitWriter 图形界面；AL-LINK 插好 + 板上电即可）
cd E:\fpga-2026\dsh_code\tools
powershell -NoProfile -ExecutionPolicy Bypass -File .\flash.ps1 -Proj m2_720p
powershell -NoProfile -ExecutionPolicy Bypass -File .\flash.ps1 -Proj m2_720p -Spd 2   # 不稳时降 TCK

# 读调试串口（板子 USB-C = CH340E，115200 8N1）
powershell -NoProfile -ExecutionPolicy Bypass -File .\read_uart.ps1
```

**烧完一定要拔插一次 HDMI 线**：这块便携屏在 FPGA 重配置导致 TMDS 中断后不会自己重新锁定。

## 目录

| 目录 | 内容 |
|---|---|
| `proj/m*_720p/` | 正式工程（`rtl/` 源码、`IO.adc` 引脚、`timing.sdc` 时钟、`make_proj_files.ps1` 生成工程、`build.ps1` 一键编译） |
| `proj/m0_720p/` | 720p 彩条探测工程（无 LED 端口，四灯全灭是正常的） |
| `docs/` | `board-test-guide.md` 上板手册、`demo-script.md` 演示脚本、`submission-checklist.md` 交稿清单、`specs/` 设计规格 |
| `docs/research/` | 硬件事实、工具链、各里程碑报告、**`bench-bringup-postmortem.md`（7 个底层 bug 复盘）** |
| `tools/` | `flash.ps1` 烧录、`read_uart.ps1` 串口、`install_al_link_driver.ps1` 驱动、`make_bmp.py` 等 |
| `demo/` | 6 张 640×480 测试图 |

## 关键约束（都吃过亏）

1. **显示器只认 1280×720**：这块便携屏原生 1024×600，喂 640×480 直接报 "not support"。所以输出固定
   1280×720@59.26 Hz（像素时钟 73.333 MHz，来自厂商 `pll_hdmi1_4b`），640×480 帧缓冲**居中显示**。
2. **HDMI 全靠 FPGA 直接打 TMDS**：板上没有 HDMI 发送芯片，也**没有 DDC/EDID/HPD**，只能固定时序输出。
3. **TF 卡是 SPI 1 bit**：CLK=M2 MOSI=L3 MISO=K6 CS=R2，无 CD/WP，只在**复位后**初始化（不支持热插拔）。
   卡必须 FAT32、根目录 8.3 文件名的 `IMGnnnn.BMP`（640×480 24 bit，≤16 张）。
4. **LED 低电平点亮**：`led[3:0] = {页号, 有错误, 正在写, 卡已挂载}`，亮 = 该位为 0。
5. **按键**：S0=下一张、S1=上一张、S2=复位；板上没有摇杆（之前发现的"四向开关"是显示器自己的 OSD 摇杆）。
6. **片内 SDRAM 控制器只能顺序流式访问**，两页帧缓冲各 307200 字。

## 提交

见 [`docs/submission-checklist.md`](docs/submission-checklist.md)。设计报告里的「调试过程」章节直接用
[`docs/research/bench-bringup-postmortem.md`](docs/research/bench-bringup-postmortem.md)。
