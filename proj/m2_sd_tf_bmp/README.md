# m2_sd_tf_bmp — M2 里程碑：TF 卡(SPI) → FAT32 → 640×480 BMP → SDRAM 页 B → 切页显示

AC208（EG4S20BG256）· 安路 TD Release_2026.1_SP2 · 纯 Verilog + 2 个 PLL +
厂商加密 HDMI 核 + 厂商 SDRAM 控制器 + 厂商 SD 卡 SPI 引擎

* **顶层**：`m2_top`
* **端口**：`clk`(50 MHz, K14) / `rst_n`(KEY2, H14, 低有效) /
  `key0_n`(KEY0, F7, 下一张) / `key1_n`(KEY1, E7, 上一张) /
  `SD_CLK`(M2) `SD_MOSI`(L3) `SD_MISO`(K6) `SD_CS`(R2) /
  `led[3:0]`(M12 R16 R15 T15) / `O_tmds_*`（LVDS33_E）
* **功能**：上电自动挂载 TF 卡、扫根目录、按编号排序、读 `IMGnnnn.BMP`（640×480 24 bit）
  写进 SDRAM 的**页 B**，写完整页后在场消隐**切页**显示；KEY0/KEY1 切换图片；
  没有卡 / 没有 BMP / BMP 不合格时回退显示 M1 的测试图案。
* **报告**：`E:\fpga-2026\dsh_code\docs\research\m2-report.md`
* **工具**：`E:\fpga-2026\dsh_code\tools\make_bmp.py`（任意图片 → 播放器能读的 BMP）

## 数据通路

```
TF 卡 --SPI(Mode3, 400 kHz 初始化 -> 25 MHz 读)--> sd_card_control (512x8 RD_RAM)
                                                    │  字节读（100 MHz）
                                                    ├─> m2_byte_seq   FAT32 结构 -> 寄存器
                                                    └─> m2_pix_pump   BMP 负载 -> 24 bit RGB
                                                    │
                                                    └─> m2_page_wr --WR1--> SDRAM 页 A / 页 B
                                                                              │
                                              RD1(页A) ─────────────────────> ├─ mux ─> AXIS ─> HDMI
                                              RD2(页B) ─────────────────────> ┘
```

## 地址映射（SDRAM 是 32 bit **字**地址）

| 区域 | 字地址 | 长度 |
|---|---|---|
| 页 A | `0x00000 .. 0x4AFFF` | 307 200 字 = 640×480 |
| 页 B | `0x04B000 .. 0x095FFF` | 307 200 字 |
| 环形写上限 `WR1_MAX_ADDR` | `0x096000` | — |

一行 = 640 字 = 5 个 128 字突发；行基址 `页基址 + y*640`（= `(y<<9)+(y<<7)`）天然 128 字对齐。
BMP 是**自底向上**存的，所以**先写第 479 行、最后写第 0 行**——每行用自己的 `WR1_LOAD`
重新装地址计数器（M1 的环形写换成了"逐行 LOAD"，原因见报告 §6）。

## 编译（一条命令）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\fpga-2026\dsh_code\proj\m2_sd_tf_bmp\build.ps1
```

产物：`m2_sd_tf_bmp_Runs\phy_1\m2_sd_tf_bmp.bit`（629 635 B，`Design name: m2_top`）

脚本做的事（等价于手工两步，必须分别 `cd` 进两个 run 目录）：

```powershell
cd E:\fpga-2026\dsh_code\proj\m2_sd_tf_bmp\m2_sd_tf_bmp_Runs\syn_1
E:\bin\td_commands_prompt.exe E:/fpga-2026/dsh_code/proj/m2_sd_tf_bmp/run_flow.tcl

cd ..\phy_1
E:\bin\td_commands_prompt.exe E:/fpga-2026/dsh_code/proj/m2_sd_tf_bmp/run_flow.tcl
```

Tcl 路径必须用正斜杠；`run_flow.tcl` 把 TD 不可靠的退出码变成 0/1 并打印 `TD_FLOW_OK`。

## 怎么用（3 步）

1. `python E:\fpga-2026\dsh_code\tools\make_bmp.py 图1.jpg 图2.png -o D:\card`
   → 生成 `IMG0001.BMP` `IMG0002.BMP`（640×480 / 24 bit / 54 字节头 / 未压缩）；
2. 把 `IMGxxxx.BMP` 拷到 **FAT32** TF 卡的**根目录**（不要子目录，8.3 短文件名）；
3. 插卡 → 上电或按 KEY2 → 约 0.5 s 后显示第 1 张；KEY0 = 下一张，KEY1 = 上一张。

## 目录

```
m2_sd_tf_bmp.al                 TD 工程文件（TD_Version = 6.2.190657）
IO.adc                          引脚约束（16 个 IO：时钟/3 键/SD 4 根/LED 4 个/4 对 TMDS）
timing.sdc                      时钟约束（50 / 25 / 125 / 100 MHz，四个 exclusive 组）
run_flow.tcl                    DefaultFlow 的 CI wrapper
build.ps1                       一键重新编译
make_proj_files.ps1             由文件清单生成 .al / .prj / settings.cfg（可重复生成工程）
rtl/m2_top.v                    顶层：PLL / 复位 / SDRAM 控制器 / SD 引擎 / FAT32 FSM / 写页 / HDMI
rtl/m2_video_src.v              光栅 + 页选择 + 按键消抖 + AXIS 源（25 MHz 域）
rtl/m2_page_wr.v                逐行 WR1_LOAD 的整页写入器（100 MHz 域）
rtl/m2_sd_sec.v                 sd_card_control 的封装：start/扇区号/done + 看门狗
rtl/m2_byte_seq.v               把当前扇区里的 N 个字节读进寄存器（FAT32 结构解析用）
rtl/m2_pix_pump.v               把扇区里的 BMP 负载变成 {0,R,G,B} 像素流
rtl/m2_fat_bmp.v                FAT32-lite + BMP 校验 + 主控状态机（100 MHz 域）
rtl/sd_spi/*.v                  厂商 SD 卡 SPI 引擎（16 个文件逐字节原样拷贝）
rtl/sdram_ctrl_4p/*             厂商 SDRAM 控制器（8 个文件；仅 Sdram_RD_FIFO.v 的 AF 128→256，M1 已改）
rtl/hdmi_phy_warpper.v          厂商原样拷贝（4×lane_lvds_10_1）
rtl/lane_lvds_10_1.v            厂商原样拷贝（ODDR 10:1 串行化）
rtl/hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v
                                厂商加密 HDMI 1.4b 发送核（原样拷贝）
al_ip/pll_m2_hdmi/pll_m2_hdmi.v PLL：50 MHz -> 25.000 / 125.000 MHz
sim/model_fat32_bmp.py          离线 FAT32/BMP/RTL 模型 + 测试向量生成器（80 项检查）
m2_sd_tf_bmp_Runs/syn_1|phy_1/  TD 的两个 run（settings.cfg + m2_sd_tf_bmp.prj + 产物）
```

厂商文件来源（只读，未改动原件）：

* HDMI 链 / SDRAM 控制器：`...\01-board_test基础自检\AC201_AL_board_test\src\...`（同 M1）
* SD 卡 SPI 引擎：`...\02-uart_sd_rw串口读写SD卡\AC201_AL_uart_sd_rw\rtl\`
  （16 个文件逐字节相同，SHA256 全部比对通过；GBK 中文注释原样保留）

没有带入：以太网 / OV5640 / RTC / 红外 / 数码管 / WM8960 音频 / 36 位 GPIO / 串口命令解析。
