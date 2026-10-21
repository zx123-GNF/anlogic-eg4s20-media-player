# 安路 EG4S20 官方例程架构分析（AC208 / TangDynasty 6.2.2）

> 分析对象（只读，未做任何修改）：
> **A** = `E:\fpga-2026\选题一-EG4S20-HX4S20C官方例程\03-AC208板例程(AC201-EG4S20_WM8960版)\01-board_test基础自检\AC201_AL_board_test\`
> **B** = `...\02-uart_sd_rw串口读写SD卡\AC201_AL_uart_sd_rw\`
> 目标：TF 卡读 JPEG/PCM → 硬件 JPEG 解码 → SDRAM → HDMI 640×480（含音频）。本文只回答"官方例程里已经有什么能复用"。

> ⚠️ **更正（2026-10-21）**：本文初稿把 `EG_PHY_SDRAM_2M_32` 误判为"片内 SDRAM 硬宏"。核对 `sdram_ip.v` 端口后确认：它是**外置 SDRAM 颗粒的引脚级 PHY**（ras/cas/we/addr/ba/dq/dm/cke 全是片外信号）。**本板没有 SDRAM 颗粒**（`IO.adc` 无 SDRAM 引脚约束，`board_test` 里这条链是从带 SDRAM 的旧板工程 `ov5640_sdram_hdmi_tft` 拷来的死代码）。因此下文 §0 表、§3、§8、§9 中"SDRAM 可做帧缓存"的结论作废：帧缓存只能落在 **512 KB 异步 SRAM** 上，详见 [hw-facts.md](hw-facts.md) §4.1–4.2、§9.1。

---

## 0. 结论速览

| 模块 | 位置 | 结论 |
|---|---|---|
| HDMI 1.4b 发送核心（加密） | A:`src/user_source/hdl_source/hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v` | **可原样复用**，仅改参数（时序/HACTIVE/VIC）+ 重配 PLL |
| TMDS 串行化（ODDR） | A:`src/user_source/hdl_source/lane_lvds_10_1.v`、`hdmi_phy_warpper.v` | **可原样复用** |
| SDRAM 控制器 + SDRAM 宏 | A:`src/5640/sdram_ctrl_4p/*` | ⚠️ **见文首更正：本板无 SDRAM，此链不可用**；控制器本身只能顺序流式读写 |
| 显示时序发生器 | A:`src/5640/vga/disp_driver.v` + `disp_parameter_cfg.v` | **时序参数可抄**（内含 640×480 表），模块本身是并口 TFT 用 |
| ACR（HDMI 音频时钟再生） | A:`src/user_source/hdl_source/audio_arc_calculate.v` | **可原样复用** |
| I2S 接收 | A:`src/user_source/hdl_source/I2S_receiver.v` | 可用（若音频源是 I2S）；播放需自己写 I2S 发送 |
| WM8960 I2C 初始化 | A:`src/i2s_init_dev.v`+`i2s_control.v`+`i2s_bit_shift.v`+`ES8388_init_table.v` | **框架可复用**，寄存器表/器件地址/主频必须核对 |
| SD/TF 扇区读写 | B:`rtl/*` | **可复用为"读扇区引擎"**，上限 ≈3 MB/s，无 FAT |
| JPEG 解码 | —— | **例程中完全不存在，必须自写** |
| TF 卡 FAT32 / 多扇区流 | —— | **不存在，必须自写** |
| I2S 发送 / PCM 播放 | —— | **不存在（被注释掉），必须自写** |

---

## 1. 工程与工具链基线（问题 7）

- **TD 版本**：`A/AC201_AL_board_test.al:4`、`B/uart_sd_rw.al:4` 均为 `<TD_Version>6.2.190657</TD_Version>`；`A/AC201_AL_board_test_Runs/syn_1/flow.status` 打印 `Tang Dynasty v6.2.190657`；`syn_1/run.bat` 写死 `E:/Anlogic_TD_6.2.2/bin/td_commands_prompt.exe`，即 **TD 6.2.2**。`00-工程操作说明文档.docx` 也写"打开 TD6.2.2 下载界面下载程序"。
- **器件**：两工程均 `<Family>EG4</Family> <Device>EG4S20BG256</Device>`（`*.al:7-9`），封装 BG256，速度为 `Speed` 空（NA）。综合用器件库 `syn_1/settings.cfg` 里 `set device_name eagle_s20.db`。
- **顶层**：A 为 `hardware_test`（`.al:573-576`），B 为 `top`（`.al:257-260`）。
- **`.al` 结构约定**（XML，`Project Version="3" Minor="2"`）：
  - `Path` 属性是作者机器上的绝对路径（`C:/Users/Administrator/Desktop/...`），其余路径**相对工程目录、正斜杠**，如 `src/5640/sdram_ctrl_4p/Sdram_Control_4Port.v`。
  - 每个 `<File>` 带 `UsedInSyn / UsedInP&R / BelongTo(design_1|constraint_1) / CompileOrder`；不参与编译的文件标 `AutoExcluded="true"`（A 里是 `ov5640_init_table_jpeg.v`、`disp_parameter_cfg.v`——后者其实是被 `` `include `` 的头文件）。
  - 约束分两类：`<ADC_FILE> io.adc`（引脚，内容为 `set_pin_assignment {...} { LOCATION=..; IOSTANDARD=..; }`）、`<SDC_FILE> timing.sdc`。
  - IP 单独列在 `<IP_FILE>`，指向 `al_ip/<name>/<name>.ipc`（PLL/FIFO/SDRAM 配置）或 `al_ip/<name>/<name>.xml`（FIFO Designer 输出）。`al_ip/<ip>/` 下同时生成 `.v` 和 `.vhd`，`.al` 只引用 `.ipc`，由 TD 自行取 `.v`。
  - `<Runs>` 固定 `syn_1`(Synthesis) + `phy_1`(PhysicalDesign, `SynRun="syn_1"`)。
- **Runs 目录约定**：`<proj>_Runs/syn_1|phy_1/` 内含 `settings.cfg`（`ADCList/SDCList/device_name/start_step/end_step`）、`<prj>.prj`（**路径前缀 `../../`**，即从 run 目录回退两级）、`<prj>.tcl`（TD 默认流程脚本，步骤 `read_design opt_rtl opt_gate opt_place opt_route bitgen`）、`run.bat`、`run.log`、报告（`*_gate.area`、`*_gate.timing`、`gate.qor`、`*_phy.area`、`place.qor`、`route.qor`、`final_timing.rpt`）；`best_result/` 存最优 `.bit` + `readMe.txt`。
- **`log/` 目录**是 TD GUI 会话日志，不是流程报告：`td_*.log/.logw`（编译会话，含 `HDL-xxxx` 告警）、`bw_*.log`（下载/板级调试，出现大量 `PRG-8000 ERROR: Connect server failed`＝当时未连板）。**A 的 phy 阶段报告未随例程打包**（`phy_1/` 只剩 `.bit/.prj/.tcl`），B 保留了完整 phy 报告。
- **引脚基线**（`管脚表/AC201-EG4S20管脚信息表.xlsx`）：板载时钟 `CLK_50MHz = K14`；SD 卡 `SD_CLK=M2, SD_MOSI=L3, SD_MISO=K6, SD_CS=R2`；HDMI 为 4 对差分 `B10/C9, D11/D12, C11/A11, F10/H11`；音频 `I2S_MCLK=B8, BCLK=C8, DACLRC=A8, DACDAT=A7, ADCLRC=C7, ADCDAT=C6`；I²C 总线（音频/EEPROM/RTC 共用）`SCL=L16, SDA=M16`。**表中没有 DDC/EDID 引脚**，说明 HDMI DDC 未引到 FPGA。
- 另注：`原理图/` 里只有 `AC601-EG4S20_原理图.pdf`（核心板），没有 AC201 底板原理图；`_缺失附件说明/缺失附件说明.txt` 说明 `AC201_uart_to_eeprom` 例程因论坛附件损坏缺失。

---

## 2. HDMI 输出链路（问题 1）

### 2.1 顶层如何驱动

`hardware_test.v:270-282` 只把 `design_top_wrapper` 的 4 根 TMDS 输出接到顶层端口，其余端口全部**常量/悬空**：

```verilog
design_top_wrapper design_top_wrapper(
  .I_sys_clk (clk), .I_key_in (1'b0),
  .I_i2s_BCLK(1'b0), .I_i2s_LRCK(1'b0), .I_i2s_DOUT(1'b0),
  .O_tmds_ch0_p(...), .O_tmds_ch1_p(...), .O_tmds_ch2_p(...), .O_tmds_clk_p(...));
```

- `design_top_wrapper` 还有 `O_ddc_scl / IO_ddc_sda` 两个端口，**顶层根本没接**，`IO.adc` 也没有 DDC 引脚 → 本板的 HDMI DDC/EDID 通路**不可用**。`src/user_source/constraints_source/pin.adc` 里给了 `O_ddc_scl=P12 / IO_ddc_sda=M10`，但那是另一块板（I²S 在 `N12/T13/L12`）的引脚集，**未列入 `.al`**，属遗留文件。
- 链路：`design_top_wrapper` → `pll_hdmi1_4b`(像素/串行时钟) → `video_source_test`(AXIS 视频源) → `hdmi_1_4b_transmitter_core_wrapper`(加密) → `hdmi_phy_wrapper`(4×`lane_lvds_10_1`) → 引脚。
- 4 个 TMDS 输出仅约束 `_p` 端且 `IOSTANDARD = LVDS33_E`（`IO.adc` 中 `O_tmds_ch0_p=D11` 等），`_n` 端由差分对自动配对，RTL 里没有 `_n` 端口（`hardware_test.v:69-72`）。

### 2.2 分辨率 / 像素时钟 / 色深

- 核心例化参数（`design_top_wrapper.v:123-145`）：`HTOTAL=1650, HSA=40, HFP=110, HBP=220, HACTIVE=1280, VTOTAL=750, VSA=5, VFP=5, VBP=20, VACTIVE=720` → **1280×720@60**，`VIDEO_VIC=69`，`VIDEO_FORMAT="RGB"`，`VIDEO_TPG="Enable"`，`AUDIO_SAMPLE_RATE="48K"`，`IIC_SCL_DIV=125`，`DEVICE="EG"`。
- 像素时钟 = `pll_hdmi1_4b` 的 `clk1_out` = **73.33 MHz**，串行时钟 = `clk2_out` = **366.67 MHz（相位 90°）**（`al_ip/pll_hdmi1_4b/pll_hdmi1_4b.v:13-20,63-74`；`.ipc` 里的 100/75/375 只是界面标称值，以生成的 `.v` 注释为准）。366.67 = 5×73.33，即 **每像素 5 个串行时钟 × DDR 2 bit = 10 bit TMDS**，单 lane 733 Mbps。
- 色深 = **24 bit RGB888**（每通道 8 bit，无 deep color）：AXIS 数据宽度 `I_axis_s_data[23:0]`（`…wrapper.enc.v:40`）。
- 时序约束 `timing.sdc`：`pixel_clk 13.5 ns (74.07 MHz)`、`serial_clk 2.7 ns (370 MHz)`，且两者 `-exclusive` 分组。注意它按**内部网名** `S_pixel_clk / S_serial_clk` 约束，一旦改动 `design_top_wrapper` 内部信号名就会失效。

### 2.3 TMDS 是"加密 IP + LVDS 原语"吗？

是，但要精确说：加密 IP 只做 **TMDS 编码/打包**，串行化用的是 **ODDR 原语 + 移位寄存器**，不是 SERDES：

- 加密 IP 输出 4 组 `[9:0]` 并行 TMDS 字（`O_ch0/1/2_tmds_data`、`O_clk_tmds_data`），在像素时钟域（`…wrapper.enc.v:71-74`）。
- `hdmi_phy_warpper.v:26-68` 把每 10 bit **按位反转**后送 `lane_lvds_10_1`。
- `lane_lvds_10_1.v`：用 `I_pixel_clk` 产生的 `S_odd_even` 在 `I_serial_clk` 域打两拍得到"装载"脉冲（`S_load_en_2d`），装载后 `S_shift_data <= S_shift_data << 2`（每串行时钟移 2 bit），再把 `S_shift_data[9:8]`（即 bit9→`d1`、bit8→`d0`）送 `EG_LOGIC_ODDR` → 单端输出。10 bit / 2 bit = 5 个串行时钟/像素，正好对应 5× 时钟比。
- 因此"LVDS"只是**引脚标准**（`LVDS33_E`），物理上是 LVDS 差分对由 ODDR 单端驱动；`DEVICE` 参数支持 `EF2/EF3/EF4/SF1/EG/PH1A/PH1P/DR1` 八种 ODDR 原语（`lane_lvds_10_1.v:58-155`），EG4S20 用 `EG_LOGIC_ODDR`。

### 2.4 加密 IP 是否需要 license / TD 能否直接编译

**不需要额外 license，TD 可直接编译、可直接生成 bit。** 证据：

- `.enc.v` 只有模块头（2–75 行）明文，主体 77–5038 行是 `` `pragma protect ``（`encrypt_agent = "Anlogic"`，`anlogic-rsa-001` 等公私钥块，共 5041 行）。**未尝试解密**。
- 综合日志正常展开其内部层次并给出资源：`syn_1/AC201_AL_board_test_gate.area` 里有 `hdmi_tx_controller_wrapper / hdmi_tmds_encode ×3 / hdmi_island_data_assemble / hdmi_island_data_gen / audio_sample_packet_2_channel / audio_clock_regeneration_packet / hdmi_video_tpg_gen / video_axi_stream_receiver` 等子模块及其 LUT 数。
- `syn_1/run.log:560` 仅有一条 `Open license file E:/Anlogic_TD_6.2.2/license/Anlogic.lic`（TD 标准 license），之后 `SYN-1001` 各 stage 正常结束；`phy_1/AC201_AL_board_test.bit`（642 KB）已生成。
- 唯一限制：它只能被 TD 吃（第三方仿真器需自己具备对应的 `pragma protect` 解密授权，例程未提供仿真模型）。

### 2.5 有没有 HDMI 音频通路？音频怎么进 data island

**RTL 通路是完整的，但本工程顶层把它掐断了。**

- 通路：`I_i2s_*` → `I2S_receiver`（`design_top_wrapper.v:61-72`，输出 24 bit 左右声道 + valid）→ `audio_arc_calculate`（算 ACR 的 CTS/N，`:75-86`）→ 加密 IP 的 `I_audio_valid / I_audio_left_data[23:0] / I_audio_right_data[23:0] / I_acr_valid / I_acr_cts[19:0] / I_acr_n[19:0]`（`…wrapper.enc.v:46-55`）。data island 的打包、BCH 校验、保护带插入都在加密 IP 内部（`hdmi_island_data_assemble`、`audio_sample_packet_2_channel`、`BCH_32_24_encode`、`audio_clock_regeneration_packet`、`BCH_64_56_encode`，见 `gate.area`）。
- 但 `hardware_test.v:275-277` 把 `I_i2s_BCLK/I_i2s_LRCK/I_i2s_DOUT` 全接 `1'b0` → **board_test 里 HDMI 是不出声的**；`I2S_receiver` 只占 173 LUT，等于空转。
- 结论：**"PCM → TMDS data island" 这段官方已经给了（复用 `audio_arc_calculate` + 核心的 audio 端口），缺的是"从 SDRAM/TF 卡取 PCM 并按时序推 24 bit 样点"的发送侧。**

### 2.6 重要发现：HDMI 显示的不是 `video_source_test`

- `VIDEO_TPG = "Enable"` → 核心内部图案发生器生效；
- 综合证据：`video_source_test` 只占 **1 个 LUT**（`gate.area` 层次报告），即它的数据被完全优化掉；而核心内 `u_hdmi_video_tpg_gen` 占 105 LUT、`u_video_axi_stream_receiver` 占 27 LUT。
- 另有一处参数错配：`video_source_test` 例化给的是 1080p 时序（`HTOTAL=2200, VTOTAL=1125`，`design_top_wrapper.v:98-108`），而核心是 720p——正好印证它没被真正使用。
- 因此"HDMI 显示屏在几种图像中轮询切换"（`00-工程操作说明文档.docx`）是**核心内置 TPG**，不是外部视频。目标工程必须把 `VIDEO_TPG` 设为 `"Disable"` 并自己产生符合 640×480 的 AXIS 流。

---

## 3. SDRAM 控制器（问题 2）

### 3.1 血统与结构

`src/5640/sdram_ctrl_4p/Sdram_Control_4Port.v` 就是 **Altera 经典 `Sdram_Control_4Port`** 的移植版：保留了原版宏定义与参数（`:65-98`）：

```
ROWSTART 8, ROWSIZE 11, COLSTART 0, COLSIZE 8, BANKSTART 19, BANKSIZE 2
ASIZE 21 (地址 2^21 字), DSIZE 32 (数据位宽)
INIT_PER 24000, REF_PER 1024, SC_CL 3, SC_RCD 3, SC_RRD 7, SC_PM 1(页模式), SC_BL 1
```

子模块：`command.v`（SDRAM 命令/初始化/刷新状态机）、`control_interface.v`、`sdr_data_path.v`（DQ 输入输出与 DQM 对齐）、`Sdram_WR_FIFO.v` / `Sdram_RD_FIFO.v`（异步 FIFO）、`Sdram_PLL.v`（内部 PLL）、`sdram_ip.v`（SDRAM 硬宏）。

- **4 个端口**：WR1、WR2（写，`[31:0]` 数据，`[20:0]` 起止地址，9 bit 突发长度，独立写时钟 `WRx_CLK`）与 RD1、RD2（读，同构，`RDx_CLK`）。每端口另有 `FULL/EMPTY`。
- **FIFO 深度 512×32**：`Sdram_WR_FIFO.ipc`（`aef=127, aff=378`）、`Sdram_RD_FIFO.ipc`（`aff=128`），对应资源 7 个 `fifo9k`。
- **时钟**：控制器内部自己产生（`Sdram_Control_4Port.v:259-265`）`Sdram_PLL` → `CLK = 100 MHz`（控制器主时钟）、`SDR_CLK = 100 MHz / 270°`（送 SDRAM）；参考时钟是端口 `REF_CLK`（例程接 50 MHz）。注意 `CLK` 在端口表里是 **`output wire`（第 253 行）**，所以 `ov5640_sdram_vga.v:134` 的 `.CLK(clk_w)` 是把它接到一根未声明的隐式线网——**无害但是个坑**（容易误以为是输入时钟）。
- ⚠️ **本文初稿误称"片内 SDRAM 硬宏"，已更正**：`sdram_ip.v` 例化的是 `EG_PHY_SDRAM_2M_32`，端口为 `ras_n/cas_n/we_n/addr[10:0]/ba[1:0]/dq[31:0]/cs_n/dm0-3/cke`——这是**外置 SDRAM 颗粒的引脚级 PHY**，不是片内宏。本板没有 SDRAM 颗粒，`IO.adc` 也无任何 SDRAM 引脚约束，`ov5640_sdram_vga` 的 SDRAM 信号只连内部 wire，综合后该层次资源为 0。所以这条链在本板**不可用**（详见 [hw-facts.md](hw-facts.md) §4.1）。
- 容量核对：2^21 × 4 B = 8 MB，与 `ASIZE=21` 一致。

### 3.2 怎么例化（可直接照抄的用法）

见 `src/5640/ov5640_sdram_vga.v:130-209`：写侧 1 用摄像头像素时钟写入，读侧 1 用显示时钟读出，读侧 2/写侧 2 全部接 0 关闭。

```verilog
Sdram_Control_4Port u_Sdram_Control_4Port_0(
  .REF_CLK(clk /*50M*/), .RESET_N(rst_n), .CLK(clk_w),
  .WR1_DATA(fifo_wrdata), .WR1(fifo_wrreq), .WR1_ADDR('d0), .WR1_MAX_ADDR(IMAGE_LENGTH),
  .WR1_LENGTH(9'h80), .WR1_LOAD(!rst_n), .WR1_CLK(camera_pclk),
  .RD1_DATA(data_rgb),  .RD1(Rd_Sdram), .RD1_ADDR('d0), .RD1_MAX_ADDR(IMAGE_LENGTH),
  .RD1_LENGTH(9'h80), .RD1_LOAD(!rst_n), .RD1_CLK(clk_vga),
  /* WR2/RD2 全 0 */);
```

### 3.3 能不能直接当显示帧缓存

**能，但只有"顺序流式"能力，这点对 JPEG 很关键。**

- 每端口内部地址计数器 `rWR1_ADDR`/`rRD1_ADDR` 在每次突发完成后 `+= rWR1_LENGTH`，超过 `MAX_ADDR-LENGTH` 回绕到起始地址（`:525-576`），`LOAD` 用于重置起始地址/清 FIFO。**没有逐字随机地址口**，突发长度只能 9 bit 配置，且是页模式连续突发。
- 帧缓存用法已被官方验证：`IMAGE_LENGTH = IMAGE_WIDTH*IMAGE_HEIGHT/2`，一个 32 bit 字装 2 个 RGB565 像素，读侧用 `Rd_Sdram` 取反在 `data_rgb[31:16]` / `[15:0]` 之间切换（`ov5640_sdram_vga.v:82-86,211`）。640×480 RGB565 只需 `640*480/2 = 153600` 字 = 600 KB，8 MB 里绰绰有余。
- **风险 1（撕裂）**：写侧与读侧用的是**同一段地址范围**（都是 `0..IMAGE_LENGTH`），两个指针各自回绕、互不同步 → 画面边界会撕裂。做播放器时应分配两块区间（或用 `MAX_ADDR` + `LOAD` 做帧同步切换）实现真正的双缓冲。
- **风险 2（JPEG 顺序）**：JPEG 解码输出天然是 **MCU 块序**（4:2:0 时 16×16，4:4:4 时 8×8），而这里只能顺序写。必须做"块→行"重排：加 16 行 × 640 px 的行缓存 ≈ 640×16×16 bit = **160 Kbit ≈ 18 个 9K BRAM**（4:4:4 减半，约 9 个）。指望"先按块序写 SDRAM、再搬到光栅序"绕不过去——搬运算同样需要步进寻址，而控制器只有顺序口。**这是本方案最吃 BRAM 的一项，也是决定 640×480 能否落地的关键预算。**
- **带宽**：32 bit @100 MHz 峰值 400 MB/s；1280×720@60 RGB888 读 ≈ 166 MB/s、640×480@60 RGB565 读 ≈ 37 MB/s，写同理，余量充足。但注意写侧时钟是**异步**的（摄像头/解码器时钟），要靠 512 深 FIFO 吸收突发。

---

## 4. 时钟（问题 3）

板上只有一颗 **50 MHz** 晶振（`管脚表` "板载时钟 CLK_50MHz = K14"；`B/al_ip/pll/pll.ipc` 的 `input_frequency = 50 MHz`，`top.v:38-45` 用它产生 100 MHz）。A 工程共 **4 个 PLL，全部用满（`gate.area`: `#pll 4 out of 4 = 100%`）**：

| PLL | 输入 | 输出 | 用途 | 来源 |
|---|---|---|---|---|
| `al_ip/pll` | 125 MHz（RGMII RX 时钟，**不是**板载 50 M） | C0 = 125 MHz | 以太网 GMII/RGMII | `al_ip/pll/pll.ipc:12`、`pll.v:18`、`eth_udp_loopback_rgmii.v:85-89` |
| `al_ip/pll_hdmi` | 50 MHz | C0 33.33 / C1 33.33 / C2 23.81 / C3 166.67 / C4 8.197 MHz | TFT 800×480(33.33)、OV5640 XCLK(23.81)、视频 5x(166.67)、音频 MCLK(8.197) | `pll_hdmi.v:16-21`；`.ipc` 标称 33/33/24/165/8.192 |
| `al_ip/pll_hdmi1_4b` | 50 MHz | C0 100 / C1 **73.33（像素）** / C2 **366.67（串行, 90°）** | HDMI 720p60 | `pll_hdmi1_4b.v:16-21` |
| `Sdram_PLL`（在控制器内部） | 50 MHz | C0 100 / C1 100 @270° | SDRAM 主时钟 + SDR SDR_CLK | `Sdram_PLL.v:12-20` |

- 例化方式见 `design_top_wrapper.v:48-56`（只取 `clk1_out/clk2_out`，`reset=1'b0`，`extlock` 直接当复位源：`S_rst = ~S_pll_lock`）。
- `disp_driver` 所在路径用的 `clk_vga = 33.33 MHz`（`ov5640_sdram_vga.v:66-74`），对应 `disp_parameter_cfg.v` 的 `Resolution_800x480`（1056×525@60 ≈ 33.3 MHz）——**与 HDMI 的 73.33 MHz 是两套独立显示时钟**。
- 坑：`al_ip/pll/pll.ipc` 与 `al_ip/pll_hdmi/pll_hdmi.ipc` 的 `input_frequency` 分别是 125/50 MHz，**同名 IP 在不同工程里参数不同**（B 工程的 `al_ip/pll/pll.ipc` 是 50→100 MHz）。跨工程拷 IP 时必须核对 `.ipc`。
- **对 640×480 的含义**：需要 pixel 25.175 MHz / serial 125.875 MHz。TD 的 PLL 分频比是整数，25.175 无法从 50 MHz 精确得到；建议用 **25.0 MHz（VCO 100 MHz ÷ 4）+ 125.0 MHz 串行**（帧率 59.5 Hz，绝大多数显示器可接受），并同步改 `timing.sdc`（13.5/2.7 → 40/8 ns）。**PLL 必须用 IP Generator 重新生成，同时 `timing.sdc` 的网名约束也要跟着改。**

---

## 5. 音频（问题 4）

### 5.1 WM8960 初始化（I2C）

- 顶层把共用 I²C 总线（`L16/M16`，音频 codec + RTC + EEPROM 共用）用 `src/function_pin.v` 做**时分复用**：`mode = iis_done`（codec 初始化完成前给音频、之后给 RTC），SDA 用 `oe/o` 分解成三态（`function_pin.v:33-42`）。这是个很实用的小技巧，可直接复用。
- 初始化链：`audio_loop_back.v` → `i2s_init_dev.v`（按 `lut_size` 逐条写，`Go` 只在 `cnt_go == 59999` 时高一个时钟、之后计数器停在 60000 → **上电约 1.2 ms 后单次触发，不会周期性重来**）→ `i2s_control.v`（I2C 字节级时序，`reg_addr = addr_mode ? addr : {addr[7:0],addr[15:8]}` 支持 8/16 位寄存器地址）→ `i2s_bit_shift.v`（位级，SCL 由 `SYS_CLOCK/SCL_CLOCK/4` 分频）。
- **注意命名陷阱**：`src/ES8388_init_table.v` 文件名/模块名叫 ES8388，但内容是 **WM8960 寄存器表**（表内注释：R43=0x2B 的 "ADC 和 DAC 使用相同 LRCK"、R13=0x0D 的 MCLK/fs 比例、R12=0x0C 的 ADC I2S 16 bit 等），`lut_size = 40` 条。
- **必须核对的两点**：
  1. `dev_id = 8'h20`（`ES8388_init_table.v:28`，注释写"WM8960 IIC 接口器件地址"）。WM8960 的 7 bit 地址是 `0x1A`（写字节 `0x34`），`0x20` 更像 ES8388 的写地址。`i2s_bit_shift` 是把这个字节**原样**当地址字节发（`i2s_control.v:139` `write_byte(WR|STA, device_id)`）→ 若板上是 WM8960，这里要改成 `0x34`。**以原理图/实测为准。**
  2. I²C 速率：注释写 400 kHz，代码 `i2s_bit_shift.v:58` 是 `SCL_CLOCK = 40_000`（实际 **40 kHz**，40 条寄存器约 10 ms 量级）。
- 引脚表与 `IO.adc` 对音频 LRCK/DAT 的定义**不一致**：`IO.adc` 里 `I2S_RCLK=A7`、`I2S_DO=A8`、`I2S_DI=C7`；管脚表里 `A8=DACLRC`、`A7=DACDAT`、`C7=ADCLRC`、`C6=ADCDAT`。`hardware_test.v:251-255` 又把 ADC/DAC 的 LRCK 合成一根 `I2S_RCLK`。复用时必须重新核对（寄存器 R43=0x80 已让 ADCLRC=DACLRC，所以共用 LRCK 是设计意图，但**哪根脚是 LRCK 需要确认**）。

### 5.2 I2S 发送 / 采样率

- **没有 I2S 发送。** `audio_loop_back.v:42-43` 只有两句：

  ```verilog
  assign aud_xck   = clk_18_3;      // MCLK
  assign aud_dacdat = aud_adcdat;   // ADC 数据直通 DAC（自环）
  ```

  文件里 `i2s_rx/i2s_tx` 的例化整段被注释（`:98-126`），`DATA_WIDTH=32`、`SAMPLE_RATE=48000`、`REF_CLK=18432000` 都是**没用的遗留参数**。
- 采样率：MCLK 取 `pll_hdmi` 的 C4 = **8.197 MHz**（`pll_hdmi.v:21`），而寄存器表注释写 "MCLK 时钟为 8.192M"。**8.192 MHz 与 48 kHz 不成整数比**（8192000/48000 ≈ 170.7），按 256fs 推算实际 fs 应为 **32 kHz**。→ 目标工程若要 48 kHz，应把 MCLK 改为 **12.288 MHz**（重新配 PLL）或统一按 32 kHz 设计；WM8960 寄存器表里的 `0x0D`(R13)/`0x18`(R24) 也要按目标 fs 重算。
- `hardware_test.v:244` 把 `clk_8192` 接到 `audio_loop_back` 的 `clk_18_3`，端口名（18.3 MHz）与实际频率（8.197 MHz）也不一致，说明这段是从别的板子搬过来的。

### 5.3 `audio_arc_calculate.v` 的作用

算 HDMI 的 **ACR（Audio Clock Regeneration）包**参数，让接收端能从视频时钟恢复音频时钟：

- `parameter ACR_N = 6144`（48 kHz 的标准 N 值），`AUDIO_DIV = ACR_N >> 7 = 48`；
- 每来 48 个 `I_audio_valid`（即 48 个样点 ≈ 1 ms）产生一次 `O_acr_valid`，同时把这段时间内累计的像素时钟数 +1 作为 `O_acr_cts`，`O_acr_n = ACR_N`（`audio_arc_calculate.v:18-67`）。
- 因 CTS 是**用像素时钟实时计出来的**，所以换分辨率/换像素时钟（如 640×480 的 25 MHz）**不用改这个模块**，只要 `ACR_N` 与目标 fs 匹配（48k→6144，44.1k→6272，32k→4096）。这是本工程里最"干净"的可复用音频模块。

---

## 6. 资源占用（问题 5）

数据源：`AC201_AL_board_test_Runs/syn_1/AC201_AL_board_test_gate.area`（综合后、门级、含全部 IP；A 的 phy 报告未随例程打包，`phy_1/` 只有 `.bit`）。EG4S20 总量：LUT 19600、寄存器 19600、BRAM9K 64、BRAM32K 16、DSP 29、PLL 4、GCLK 16、IO 188。

| 项目 | 用量 | 占比 |
|---|---|---|
| IO | 120 / 188（34 in + 82 out + 4 inout） | 63.83% |
| PAD | 124 / 188（ireg 20 / oreg 75） | 65.96% |
| LUT（`#lut`，含 ripple/carry，`#Total_luts` 3556 = lut4 3170 + lut5 386） | 5286 / 19600 | **26.97%** |
| 寄存器 | 3860 / 19600 | **19.69%** |
| BRAM | 29 / 64（bram9k 22 + fifo9k 7） | **45.31%** |
| BRAM32K | 0 / 16 | 0% |
| DSP | 0 / 29 | 0% |
| **PLL** | **4 / 4** | **100%** |
| GCLK | 4 / 16 | 25% |

主要模块占比（同文件层次报告，`lut / ripple / seq / bram`）：

| 模块 | lut | ripple | seq | bram |
|---|---|---|---|---|
| `hardware_test`（顶层合计） | 4421 | 865 | 3955 | 29 |
| `design_top_wrapper`（HDMI 链） | 1667 | 271 | 1778 | 11 |
| ├ `hdmi_1_4b_transmitter_core_wrapper`（加密） | 1451 | 271 | 1640 | 11 |
| │ ├ `hdmi_tx_controller_wrapper` | 1167 | 223 | 1347 | 8 |
| │ └ `hdmi_edid_wrapper`（IIC/EDID） | 284 | 48 | 291 | 3 |
| ├ `I2S_receiver` | 173 | 0 | 84 | 0 |
| ├ `hdmi_phy_wrapper`（4×lane） | 42 | 0 | 54 | 0 |
| └ `video_source_test` | **1** | 0 | 0 | 0 |
| `eth_udp_loopback_rgmii` | 780 | 147 | 908 | 8 |
| `ov5640_sdram_vga` | 653 | 139 | 396 | 9 |
| ├ `Sdram_Control_4Port` | 405 | 58 | 258 | 7 |
| └ `camera_init`（含 2 个 256×16 表 ROM） | 128 | 16 | 73 | 2 |
| `uart_pcf8563`+RTC | 578 | 66 | 446 | 0 |
| `audio_loop_back` | 136 | 29 | 72 | 1 |
| `ir_decode` / `HEX_top` / `led` / `BEEP` | 151 / 165 / 53 / 80 | … | … | 0 |

- **时序**：综合阶段 `gate.qor` 显示 Setup WNS = +7850 ps（约束只有自动派生的 50 MHz / 20 ns），`gate.timing` 的 `Min Period 12.15 ns → Fmax 82.3 MHz`。但真实像素时钟是 73.33 MHz（13.64 ns），**综合后余量只有约 1.5 ns 量级**；P&R 报告缺失，无法确认 74 MHz 域是否收敛。→ 说明 720p 对 EG4S20 已经偏紧，**降到 640×480（25 MHz）反而非常宽松**，这对目标是利好。
- **对目标工程的直接约束**：
  - **PLL 已经 4/4 用满**。必须释放：去掉以太网（省 1 个 PLL + 780 LUT + 8 BRAM）、去掉 OV5640 通路（省 `pll_hdmi`，但音频 8.197 MHz MCLK 也来自它，需另建一个 PLL）。规划后：PLL1 = HDMI 像素+串行、PLL2 = SDRAM(内置)、PLL3 = 音频 MCLK(12.288 M)，仍剩 1 个。
  - **BRAM 45%（29/64）**：其中 HDMI 11 + SDRAM 7 = 18 是要保留的，砍掉 eth(8)/摄像头(9)/音频表(1) 后可用约 46 个；JPEG 的块→行缓存约 18 个 + Huffman 表/IDCT 转置若干 → **总量刚好够但要精算**，别再无谓地给 FIFO 加深。
  - **IO 63.8%**：`hardware_test.v:285-300` 那 36 位 `gpio_40pin` 只是把时钟 2^23 分频后全 36 位一起翻转的方波（`GPIO40_HDMI_SAFE_MASK = 36'hFFFFFFFFF`，无任何功能），**纯占 IO**，直接删掉可释放 36 个 IO——SD 卡 4 根、I²S 4 根、HDMI 4 对都够用了。

---

## 7. SD 卡例程（问题 6）

### 7.1 接口模式：SPI，不是 SD 模式

- 顶层只有 4 根：`mosi / miso / sclk / sd_cs_n`（`B/rtl/top.v:22-31`），引脚 `L3/K6/M2/R2`（`B/io.adc`），与管脚表 SD 卡一栏完全一致。
- `sd_card_control.v:223-236` 例化 `spi_driver` 时 `mode = 2'b11` → **CPOL=1, CPHA=1（SPI Mode 3）**，SD 卡 SPI 模式的常规选择。
- 命令序列走 SPI 的 6 字节命令格式（`sd_init.v:35-38` 的 `CMD0={8'h40,...}`、`CMD8={8'h48,...}`、`CMD55={8'h77,...}`、`ACMD41={8'h69,8'h40,...}`），**未做 CMD58 读 OCR、未切 4-bit 总线**，所以只能跑 SPI 模式。

### 7.2 接口信号与"最高速率"

`sd_card_control`（`B/rtl/sd_card_control.v:22-46`）的对外接口非常干净：

```verilog
parameter clock_freq=100_000_000, spi_lowfreq=400_000, spi_highfreq=25_000_000;
input start;  input [1:0] mode;      // 0=初始化 1=写扇区 2=读扇区
input [27:0] sector_addr;            // LBA，28 bit
input [8:0] wr_ram_addr;  input [7:0] wr_ram_din;  input wr_ram_wea;   // 写缓冲 512×8
input [8:0] rd_ram_addr;  output [7:0] rd_ram_dout;                     // 读缓冲 512×8
output idle, done;
```

- 一次事务 = 一个 512 字节扇区：
  - **读**：`sd_read_sector.v` → `sd_write_addr #(.mode(1))`，`write_addr = {8'h58 - mode*7, sd_addr[27:0], 8'hff}`（`sd_write_addr.v`）→ mode=1 时首字节 **`0x51` = CMD17**，CRC 占位 `0xFF`；等 R1 `0x00` → 等数据起始 token `0xFE` → 收 512 字节写入 `RD_RAM`。
  - **写**：`sd_write_sector.v` → mode=0 时首字节 **`0x58` = CMD24**；等 R1 `0x00` → `sd_write_data.v` 里 `cnt_value==0` 发 `0xFE`、1~512 发 512 字节、>512 再补 2 字节 `0xFF`（共 518 字节，SPI 模式不校验 CRC）→ 等 busy 结束、回 `0xFF` 收尾。
- 缓冲是两块 `ram_dual_port_simple`（512×8，= 2 个 BRAM，见 `B/uart_sd_rw_Runs/phy_1/uart_sd_rw_phy.area` `#bram 2`）。
- **速率**：`400 kHz` 初始化 → 数据阶段 25 MHz。分频链是 `spi_div_value = clock_freq/(freq*2)`（`sd_card_control.v:26-27`）：`clk_div_var` 先 ÷2 得到 50 MHz 的 `spi_clk`，`spi_driver` 再 2 分频得到 25 MHz 的 `sclk`；`uart_sd_example.v:255` 传的是 `spi_highfreq = clock_freq/4`（100 MHz 主频下正好 25 MHz，注释也说主频高于 100 MHz 时应固定设 25 M）。SPI 模式规范上限就是 25 MHz。
  - 纯数据：512 B × 8 bit / 25 MHz = **164 µs/扇区 → 3.1 MB/s**；
  - 加上 CMD17(6B)+响应+token 等待+CRC 约 20~30 µs → **实测约 2.6~2.9 MB/s**；100 KB 的 JPEG ≈ 40 ms，320×240 的一帧未压缩 RGB565（150 KB）≈ 55 ms。→ **单张图片可以，30 fps 视频流不行**。

### 7.3 能否直接当 TF 卡读取层

**可以当"物理层/扇区层"，但只是最小可用的那部分。**

- 能直接复用的：`sd_card_control.v` + `sd_init/sd_read_sector/sd_write_sector/sd_write_addr/sd_read_data/sd_cmd_send/sd_cmd_rec/spi_driver/clk_div_var/ram_dual_port_simple/sequence_comparator/pulse_conver/cnt/delay`。这套代码风格统一（`start/done/idle` 握手 + `sequence_comparator` 做边沿脉冲），**没有外部依赖，纯 Verilog，可直接搬进新工程**。
- 不能直接复用的：`uart_sd_example.v` 及以上全是"串口命令解析 + 一张扇区"的演示（`string_save_cmp/string_param/numstr_to_bcd/bcd_to_hex/uart_const_baud`），与播放器无关。
- 必须补的：
  1. **FAT32/exFAT 解析**（MBR→BPB→FAT 链→簇→扇区），例程只有 `sector_addr`，没有任何文件系统概念；
  2. **多扇区连续读**（`CMD18` READ_MULTIPLE_BLOCK）或至少去掉每次事务的命令开销，否则有效带宽掉到 ~2.6 MB/s；
  3. **流式输出**：现在是"填满 512 B → done → 主机来取"，要改成 FIFO/双缓冲持续供给 JPEG 解码器；
  4. **时序收敛**：`B/uart_sd_rw_Runs/phy_1/final_timing.rpt` 显示 `Constraint File: (空)`、自动派生 50 MHz、`SWNS = -2.841 ns`、`Fmax 43.78 MHz`、8 条违例端点（`route.qor` 同样 -2841 ps）。**即例程的 100 MHz 域并未真正收敛/约束**。复用时必须补 `.sdc`（100 MHz + 派生时钟），必要时把 SPI 降到 12.5 MHz 或修关键路径后再上 25 MHz。

---

## 8. 针对目标的缺口清单

**可原样复用（改参数/改引脚即可）**
1. `hdmi_1_4b_transmitter_core_wrapper.enc.v` + `hdmi_phy_warpper.v` + `lane_lvds_10_1.v` → HDMI 640×480 输出（改 10 个时序参数 + `VIDEO_TPG="Disable"` + `VIDEO_VIC=1`）。
2. `audio_arc_calculate.v`（ACR）——像素时钟变了也不用改。
3. ~~`Sdram_Control_4Port` + `sdram_ip` + 两个 FIFO IP（8 MB 帧缓存）~~ —— **本板无 SDRAM，不可用**；帧缓存只能落在 512 KB 异步 SRAM 上（见 [hw-facts.md](hw-facts.md) §4.2、§9.1）。
4. `disp_parameter_cfg.v` 里 640×480 的时序常数（`H_Total 800 / H_Sync 96 / HBP 40 / HFP 8 / V_Total 525 / VSA 2 / VBP 25 / VFP 2`，像素时钟 25.175 MHz）——即使最终走 HDMI，也可直接抄这套数字。
5. `function_pin.v`（共用 I²C 分时）、`key_remove_shakes.v`、`i2s_init_dev/i2s_control/i2s_bit_shift` 框架。
6. B 工程的 SD 扇区引擎（`sd_card_control` 及其子模块）。

**必须自己写**
1. **JPEG 解码器**：例程里完全没有（全库 grep `huffman/idct/jpeg_decod/zigzag/dequant` 只命中加密 FIFO 核里的一段 base64 噪声，无任何真实实现）；`ov5640_init_table_jpeg.v` 是 OV5640 的 **JPEG 编码**输出配置，与解码无关，且在 `.al` 里是 `AutoExcluded`。
2. **TF 卡 FAT32 层 + 多扇区流式读**。
3. **视频时序/AXIS 发生器**（640×480，配合核心的 `I_axis_s_*` 握手；`video_source_test` 只是蓝通道递增的测试图案，且会被 TPG 旁路）。
4. **SDRAM 写侧的块→行重排 + 双缓冲/换帧**（控制器只能顺序写）。
5. **I2S 发送 / PCM 播放**（把 SDRAM 里的 PCM 按 48 kHz 推给 WM8960；`i2s_tx` 在例程里是注释掉的）。
6. **干净的 SDC**（不要再用 `get_nets {S_pixel_clk}` 这种依赖内部网名的写法；SD 工程干脆没有 SDC）。

**待实测确认的三个疑点**
- WM8960 的 I²C 器件地址（代码 `0x20` vs 常见 `0x34`）。
- 音频 LRCK 到底是 `A7` 还是 `A8`（`IO.adc` 与管脚表冲突）。
- 8.197 MHz MCLK 对应的真实采样率（推断 32 kHz，而非注释里的 48 kHz）。

---

## 9. 摘要

两套官方例程可原样复用的有四条链：① HDMI 发射链——加密核心 `hdmi_1_4b_transmitter_core_wrapper.enc.v` 在 TD 6.2.2 下即可编译、无需额外 license，改十个时序参数就从 720p 降到 640×480，TMDS 由 `lane_lvds_10_1` 的 ODDR 原语串行化；ACR 模块 `audio_arc_calculate.v` 与像素时钟无关，可照用。② 帧缓存——`Sdram_Control_4Port` 面向 8 MB **外置** SDRAM（本板没有，不可用；帧缓存只能做在 512 KB SRAM 上）。③ SD 卡——SPI Mode 3、25 MHz、CMD17/CMD24 单扇区，可整段搬用，上限约 3 MB/s。④ WM8960 的 I2C 初始化框架与 640×480 时序常数。

必须自写：JPEG 解码器（例程只有 OV5640 的 JPEG 编码配置）、FAT32 与多扇区流式读、640×480 AXIS 视频源（现 `VIDEO_TPG=Enable`，`video_source_test` 综合后仅剩 1 个 LUT，画面其实是核心内置图案）、SDRAM 写侧的块→行重排与双缓冲、I2S 发送（`i2s_tx` 被注释）。硬约束：PLL 已 4/4 用满、BRAM 已 45%、36 位 `gpio_40pin` 纯占 IO 应删。待实测：WM8960 地址 `0x20` 疑为 `0x34`、音频 LRCK 的 `A7/A8` 冲突、8.197 MHz MCLK 实为 32 kHz。
