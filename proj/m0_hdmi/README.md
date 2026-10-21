# m0_hdmi — M0 里程碑：HDMI 640×480 彩条

AC208（EG4S20BG256）· 安路 TD Release_2026.1_SP2 · 纯 Verilog + 1 个 PLL + 厂商加密 HDMI 核

* **顶层**：`m0_top`
* **端口**：`clk`(50 MHz, K14) / `rst_n`(KEY2, H14, 低有效) / `O_tmds_ch0_p` `ch1_p` `ch2_p` `clk_p`（LVDS33_E）
* **输出**：640×480@59.52 Hz，8 条竖彩条（RGB888），TMDS 10:1（像素 25.000 MHz / 串行 125.000 MHz）
* **报告**：`E:\fpga-2026\dsh_code\docs\research\m0-report.md`

## 编译（一条命令）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\fpga-2026\dsh_code\proj\m0_hdmi\build.ps1
```

产物：`m0_hdmi_Runs\phy_1\m0_hdmi.bit`（629,635 B）

脚本做的事（等价于手工两步，必须分别 `cd` 进两个 run 目录）：

```powershell
cd E:\fpga-2026\dsh_code\proj\m0_hdmi\m0_hdmi_Runs\syn_1
E:\bin\td_commands_prompt.exe E:/fpga-2026/dsh_code/proj/m0_hdmi/run_flow.tcl

cd ..\phy_1
E:\bin\td_commands_prompt.exe E:/fpga-2026/dsh_code/proj/m0_hdmi/run_flow.tcl
```

Tcl 路径必须用正斜杠；`run_flow.tcl` 把 TD 不可靠的退出码变成 0/1 并打印 `TD_FLOW_OK`。

## 目录

```
m0_hdmi.al                      TD 工程文件（GUI 可打开）
IO.adc                          引脚约束（6 个 IO）
timing.sdc                      时钟约束（50 / 25 / 125 MHz，三者 exclusive）
run_flow.tcl                    DefaultFlow 的 CI wrapper
build.ps1                       一键重新编译
rtl/m0_top.v                    顶层：PLL / 复位同步 / video_gen / HDMI 核 / TMDS 串行器
rtl/video_gen.v                 640×480 AXIS 视频源（8 色彩条，RGB888）
rtl/hdmi_phy_warpper.v          厂商原样拷贝（4×lane_lvds_10_1）
rtl/lane_lvds_10_1.v            厂商原样拷贝（ODDR 10:1 串行化）
rtl/hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v
                                厂商加密 HDMI 1.4b 发送核（原样拷贝）
al_ip/pll_m0_hdmi/pll_m0_hdmi.v PLL：50 MHz -> 25.000 / 125.000 MHz
al_ip/pll_m0_hdmi/README.txt    PLL 参数推导、相位说明
m0_hdmi_Runs/syn_1|phy_1/       TD 的两个 run（settings.cfg + m0_hdmi.prj + 产物）
```

`rtl/` 下 3 个厂商文件的来源：
`E:\fpga-2026\选题一-EG4S20-HX4S20C官方例程\03-AC208板例程(AC201-EG4S20_WM8960版)\01-board_test基础自检\AC201_AL_board_test\src\user_source\hdl_source\`（只读，未改动原件）。

其余外设（以太网 / 摄像头 / RTC / 红外 / 数码管 / SDRAM / 音频 / 36 位 GPIO）全部没有带入本工程。
