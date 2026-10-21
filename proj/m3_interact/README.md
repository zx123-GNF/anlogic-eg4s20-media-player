# m3_interact — M3 里程碑：按键切图 + 自动轮播 + 数码管显示图号

AC208（EG4S20BG256）· 安路 TD Release_2026.1_SP2 · 纯 Verilog + 2 个 PLL +
厂商加密 HDMI 核 + 厂商 SDRAM 控制器 + 厂商 SD 卡 SPI 引擎

在 M2（TF 卡 → FAT32 → 640×480 BMP → SDRAM 双页 → HDMI）之上加入三件事：
**按键消抖与手动切图**、**3 s/张 自动轮播（可暂停）**、**2×74HC595 数码管显示图号**。
M2 的显示链路与无卡回退行为**原样保留**。

* **顶层**：`m3_top`
* **端口**（19 个 IO）：`clk`(50 MHz, K14) / `rst_n`(KEY2, H14, 低有效) /
  `key0_n`(KEY0, F7, 下一张；长按 = 暂停) / `key1_n`(KEY1, E7, 上一张) /
  `SD_CLK`(M2) `SD_MOSI`(L3) `SD_MISO`(K6) `SD_CS`(R2) /
  `led[3:0]`(M12 R16 R15 T15) /
  `SEG7_SCLK`(T14) `SEG7_RCLK`(R12) `SEG7_DIO`(R14) /
  `O_tmds_*`（LVDS33_E）
* **报告**：`E:\fpga-2026\dsh_code\docs\research\m3-report.md`

## 按键 / 轮播映射

| 操作 | 效果 |
|---|---|
| KEY0 短按（< 1 s，松开生效） | 下一张（编号升序，末尾回绕到最小） |
| KEY1 短按 | 上一张（编号降序，开头回绕到最大） |
| KEY0 长按（≥ 1.000 s） | 自动轮播 暂停 / 恢复（长按不切图） |
| 自动 | 每张 **3.007 s**（179 帧 × 16.8 ms），装载完成后重新计时 |
| 装载中（≈0.4 s） | 按键被忽略（主控 FSM 只在空闲状态采样按键） |
| 无卡 / 无 BMP | 回退 M1 测试图案（与 M2 相同），数码管显示 `E1`/`E2`/`E3` |

## 数码管（8 位，动态扫描 1 kHz，段选+位选各 8 bit = 2 片 74HC595）

```
 d7 d6   d5 d4   d3 d2 d1 d0
 |--|    |---|   |---------|
 总数    空       当前图号（IMGnnnn 的 4 位十进制，补零）
```

* 无卡/坏卡/无 BMP：`E1` / `E2` / `E3`；正在挂载：`--`；全部候选 BMP 不合格（回退图案）：`E4`
* 装载中：d0 的小数点（DP）常亮；暂停：整屏约 2 Hz 闪烁
* 位序按厂商 `HEX8.v` 的约定（`sel[0]` = 最低位数字）；若上板发现数字左右镜像，
  把 `m3_seg7` 的 `DIG_REV` 置 1（一个参数，重编译 70 s）

## 数据通路（与 M2 相同，只在 25 MHz 域加了交互与显示）

```
TF 卡 --SPI(Mode3, 400 kHz -> 25 MHz)--> sd_card_control (512x8 RD_RAM)
                                          │  字节读（100 MHz）
                                          ├─> m3_byte_seq   FAT32 结构 -> 寄存器
                                          └─> m3_pix_pump   BMP 负载 -> 24 bit RGB
                                          │
                                          └─> m3_page_wr --WR1--> SDRAM 页 A / 页 B
                                                                    │
                                    RD1(页A) ─────────────────────> ├─ mux ─> AXIS ─> HDMI
                                    RD2(页B) ─────────────────────> ┘
                                          ▲
   25 MHz 域：m3_video_src（光栅/页控制/按键消抖/长按/暂停/轮播计时）
              m3_seg7（1 kHz 扫描 + 内容/译码） -> m3_hc595 -> SEG7_*
```

## 编译（一条命令）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\fpga-2026\dsh_code\proj\m3_interact\build.ps1
```

产物：`m3_interact_Runs\phy_1\m3_interact.bit`（629 635 B，`Design name: m3_top`）
全清编译 ≈ 70 s；两次独立全清编译 payload 1196 行逐行一致、`Bitstream CRC` 相同。

## 怎么用（3 步）

1. `python E:\fpga-2026\dsh_code\tools\make_bmp.py 图1.jpg 图2.png -o D:\card`
   → `IMG0001.BMP` `IMG0002.BMP`（640×480 / 24 bit / 54 字节头 / 未压缩）；
2. 把 `IMGxxxx.BMP` 拷到 **FAT32** TF 卡的**根目录**（不要子目录，8.3 短文件名）；
3. 插卡 → 上电或按 KEY2 → 第一张上屏，数码管显示它的编号；KEY0/KEY1 切图，
   长按 KEY0 暂停/恢复，3 s 后自动走下一张。

## 目录

```
m3_interact.al                   TD 工程文件（TD_Version = 6.2.190657）
IO.adc                           引脚约束（19 个 IO）
timing.sdc                       时钟约束（50 / 25 / 125 / 100 MHz；M3 未新增时钟）
run_flow.tcl                     DefaultFlow 的 CI wrapper
build.ps1                        一键全清重编
make_proj_files.ps1              由文件清单生成 .al / .prj / settings.cfg（工程可重复生成）
rtl/m3_top.v                     顶层：PLL / 复位 / SDRAM 控制器 / SD 引擎 / FAT32 FSM / 写页 / HDMI
rtl/m3_video_src.v               光栅 + 页选择 + 按键消抖 + 长按 + 暂停 + 轮播计时 + AXIS 源（25 MHz）
rtl/m3_seg7.v                    数码管内容/译码/1 kHz 扫描 + 多位状态 CDC 过滤（25 MHz）
rtl/m3_hc595.v                   2 片 74HC595 的 16 bit 移位/锁存驱动（25 MHz）
rtl/m3_page_wr.v                 逐行 WR1_LOAD 的整页写入器（100 MHz）
rtl/m3_sd_sec.v                  sd_card_control 的封装：start/扇区号/done + 看门狗
rtl/m3_byte_seq.v                把当前扇区里的 N 个字节读进寄存器（FAT32 结构解析用）
rtl/m3_pix_pump.v                把扇区里的 BMP 负载变成 {0,R,G,B} 像素流
rtl/m3_fat_bmp.v                 FAT32-lite + BMP 校验 + 主控状态机（100 MHz，M3 只加 2 个只读状态输出）
rtl/sd_spi/*.v                   厂商 SD 卡 SPI 引擎（16 个文件逐字节原样拷贝）
rtl/sdram_ctrl_4p/*              厂商 SDRAM 控制器（8 个文件；仅 Sdram_RD_FIFO.v 的 AF 128→256，M1 已改）
rtl/hdmi_phy_warpper.v           厂商原样拷贝（4×lane_lvds_10_1）
rtl/lane_lvds_10_1.v             厂商原样拷贝（ODDR 10:1 串行化）
rtl/hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v
                                 厂商加密 HDMI 1.4b 发送核（原样拷贝）
al_ip/pll_m3_hdmi/pll_m3_hdmi.v  PLL：50 MHz -> 25.000 / 125.000 MHz
sim/model_fat32_bmp.py           离线 FAT32/BMP/RTL 模型（M2 的 80 项检查，原样保留）
sim/model_m3_ctrl.py             M3 交互 + 数码管模型（75 项检查）
m3_interact_Runs/syn_1|phy_1/    TD 的两个 run（settings.cfg + m3_interact.prj + 产物）
```

厂商文件来源（只读，未改动原件）：

* 数码管参考：`...\01-board_test基础自检\AC201_AL_board_test\src\HEX_top.v`、`HEX8.v`、
  `HC595_Driver.v`（扫描节拍、段码表、`{seg,sel}` 帧格式沿用；见 `m3_seg7.v`/`m3_hc595.v` 头部说明）
* HDMI 链 / SDRAM 控制器：`...\01-board_test基础自检\...\src\...`（同 M1）
* SD 卡 SPI 引擎：`...\02-uart_sd_rw串口读写SD卡\AC201_AL_uart_sd_rw\rtl\`

没有带入：以太网 / OV5640 / RTC / 红外 / 蜂鸣器 / WM8960 音频 / 36 位 GPIO / 串口命令解析。
