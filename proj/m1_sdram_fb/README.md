# m1_sdram_fb — M1 里程碑：片内 SDRAM 帧缓存 → HDMI

AC208（EG4S20BG256）· 安路 TD Release_2026.1_SP2 · 纯 Verilog + 2 个 PLL + 厂商加密 HDMI 核 + 厂商 SDRAM 控制器

* **顶层**：`m1_top`
* **端口**：`clk`(50 MHz, K14) / `rst_n`(KEY2, H14, 低有效) / `key0_n`(KEY0, F7, 低有效，手动换页) /
  `O_tmds_ch0_p` `ch1_p` `ch2_p` `clk_p`（LVDS33_E）
* **输出**：640×480@59.52 Hz，画面来自片内 8 MB SDRAM 的帧缓存（页 A / 页 B 双缓冲），
  像素 25.000 MHz、串行 125.000 MHz、SDRAM 控制器 100.000 MHz
* **报告**：`E:\fpga-2026\dsh_code\docs\research\m1-report.md`

## 画面内容（写侧测试图案）

* 水平/垂直渐变：R = x/4（0..159），G = y/2（0..239），B = 0x40；
* 8 px 宽白色竖条，每 60 次整页写（≈1.008 s）右移 8 px，到右边界回卷；
* 8 px 边框：页 A 绿色、页 B 品红 —— 换页时边框颜色变化，一眼能看出换了页。

## 双缓冲

* 页 A：SDRAM 字地址 `0x00000..0x4AFFF`（字节 `0x000000..0x12BFFF`）
* 页 B：SDRAM 字地址 `0x04B000..0x095FFF`（字节 `0x12C000..0x257FFF`）
* 写侧 WR1 从 0 到 0x96000 做**环形**写（`WR1_LOAD` 恒 0），每帧写一整页（307200 字 = 2400 个 128 字突发）；
* 读侧用 **两个读端口**：RD1 固定读页 A、RD2 固定读页 B，各自 307200 字循环；
  两路都按"每个有效像素读 1 字"连续消费，因此永远与光栅对齐；
* 显示页 = 两个 FIFO 输出的寄存器选择，**在场消隐（帧起始）切换**，不会撕裂；
* 自动每 60 帧换页一次，KEY0 可提前换页；只有"已写完"的页才会被选中显示。

## 编译（一条命令）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\fpga-2026\dsh_code\proj\m1_sdram_fb\build.ps1
```

产物：`m1_sdram_fb_Runs\phy_1\m1_sdram_fb.bit`

脚本做的事（等价于手工两步，必须分别 `cd` 进两个 run 目录）：

```powershell
cd E:\fpga-2026\dsh_code\proj\m1_sdram_fb\m1_sdram_fb_Runs\syn_1
E:\bin\td_commands_prompt.exe E:/fpga-2026/dsh_code/proj/m1_sdram_fb/run_flow.tcl

cd ..\phy_1
E:\bin\td_commands_prompt.exe E:/fpga-2026/dsh_code/proj/m1_sdram_fb/run_flow.tcl
```

Tcl 路径必须用正斜杠；`run_flow.tcl` 把 TD 不可靠的退出码变成 0/1 并打印 `TD_FLOW_OK`。

## 目录

```
m1_sdram_fb.al                  TD 工程文件（GUI 可打开）
IO.adc                          引脚约束（7 个 IO）
timing.sdc                      时钟约束（50 / 25 / 125 / 100 MHz，四个 exclusive 组）
run_flow.tcl                    DefaultFlow 的 CI wrapper
build.ps1                       一键重新编译
rtl/m1_top.v                    顶层：2 个 PLL / 复位 / SDRAM 控制器 / 写侧 / 读侧 / HDMI 链
rtl/m1_video_src.v              光栅 + 页控制 + AXIS 源（25 MHz 域）
rtl/m1_sdram_wr.v               测试图案写入器（100 MHz 域）
rtl/sdram_ctrl_4p/*             厂商 SDRAM 控制器 + 2 个 FIFO + Sdram_PLL + sdram_ip
                                （仅 Sdram_RD_FIFO.v 把读 FIFO 的 AF 阈值 128 改成 256，见报告 §3.6）
rtl/hdmi_phy_warpper.v          厂商原样拷贝（4×lane_lvds_10_1）
rtl/lane_lvds_10_1.v            厂商原样拷贝（ODDR 10:1 串行化）
rtl/hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v
                                厂商加密 HDMI 1.4b 发送核（原样拷贝）
al_ip/pll_m1_hdmi/pll_m1_hdmi.v PLL：50 MHz -> 25.000 / 125.000 MHz
al_ip/pll_m1_hdmi/README.txt    PLL 参数推导、相位说明
sim/model_sdram_fb.py           FIFO/带宽/地址映射的周期级 Python 模型（本机无 Verilog 仿真器）
m1_sdram_fb_Runs/syn_1|phy_1/   TD 的两个 run（settings.cfg + m1_sdram_fb.prj + 产物）
```

厂商文件来源（只读，未改动原件）：

* HDMI 链：`...\AC201_AL_board_test\src\user_source\hdl_source\`
* SDRAM 控制器：`...\AC201_AL_board_test\src\5640\sdram_ctrl_4p\`
  （8 个文件中 7 个逐字节原样，`Sdram_RD_FIFO.v` 只改了 `.AF(128)->.AF(256)`，文件头有说明）

没有带入：以太网 / OV5640 / RTC / 红外 / 数码管 / WM8960 音频 / 36 位 GPIO。
