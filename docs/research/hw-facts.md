# AC208（AC201-EG4S20 + WM8960 音频版）硬件事实清单

> 提取范围：`E:\fpga-2026\选题一-EG4S20-HX4S20C官方例程\03-AC208板例程(AC201-EG4S20_WM8960版)\`
> 方式：只读。管脚表 xlsx 用 openpyxl 全量导出；PDF 用自写 FlateDecode + Tj 文本抽取；Altium `.SchDoc` 二进制按 `LibReference`/`|Text=` 记录解析器件与网络名；`.adc`/`.al`/`.qor`/`.area` 直接读文本。
> 本文件是本次任务唯一新增产物，原始资料未做任何修改。

> ⚠️ **重大更正（2026-10-21，本文件第 1 版结论错误）**：**这颗 FPGA 芯片内部自带 SDRAM**。官方《2026 全国大学生嵌入式芯片与系统设计竞赛 FPGA 赛道选题指南（安路）》推荐平台 1 明确写：`EG4S20BG256 … 片内集成 SDRAM：2Mx32bit`（[指南 PDF](anlogic_2026_guide.pdf)）；安路官网 SALEAGLE 4 系列也写"部分器件内置 64M bit SDR SDRAM"（[产品页](https://www.anlogic.com/product/fpga/saleagle)）。所以：
> - 板级 BOM/管脚表里没有 SDRAM 是对的（它不占引脚），但**不代表不能用**；`01-board_test\src\5640\sdram_ctrl_4p\sdram_ip.v` 例化的 `EG_PHY_SDRAM_2M_32` 就是这片**片内 8 MB SDRAM 的硬宏**，可以直接拿来做帧缓存。
> - 因此下文 §0 第 1/6 条、§4.1、§9.1–9.2 中"板上没有 SDRAM / 512 KB 装不下 640×480"的结论**作废**（保留原文以便追溯错误来源，但请以本条为准）。
> - 512 KB 外部 SRAM 仍是可用的（16 bit、10 ns），适合做解码缓冲/条带缓存，不再承担整帧缓存。

## 0. 结论速览（先看这 6 条）

1. ~~**板上没有 SDRAM**~~ → **更正：芯片内部有 8 MB SDRAM（2M×32），板级无外置颗粒但片内可用**（见文首更正）。板级管脚表/原理图确实没有 SDRAM 信号，因为它是片内硬宏、不占引脚；`01-board_test` 里那份 SDRAM 控制器用的正是片内 `EG_PHY_SDRAM_2M_32`。
2. **唯一外部存储器是 512 KB 异步 SRAM**：IS61WV25616EDBLL-10TLI（256K×16，4 Mbit，10 ns，44-pin TSOP II）。
3. **HDMI 是 FPGA 直接打 TMDS**：4 对差分（CLK + D0/D1/D2）直接接 FPGA LVDS 引脚，板上**没有 HDMI 发送芯片**，只有 2 片 AZ1045-04F ESD 阵列 + HDMI 母座 J4；**DDC 只有上拉、没接 FPGA，HPD/CEC/EDID 都没有**。
4. **TF 卡是 SPI 模式（1 bit）**，4 根线：CLK/MOSI/MISO/CS，无 CD/WP。
5. **音频走 WM8960 模拟通路**（I2S + I2C），MCLK 由 FPGA PLL 给 18.432 MHz；**HDMI 里没有音频**（板测例程把 HDMI 的 I2S 输入接死 0）。
6. ~~**640×480 RGB565 帧缓存 = 600 KB > 512 KB SRAM，塞不下**~~ → **更正：帧缓存放片内 8 MB SDRAM，不受 512 KB SRAM 限制**（见文首更正）。

---

## 1. 资料与来源对照

| 代号 | 文件 | 说明 |
| --- | --- | --- |
| 【管脚表】 | `管脚表\AC201-EG4S20管脚信息表.xlsx` | 单 sheet「管脚信息」，A1:D194，194 行；列＝功能/具体信号/FPGA管脚号/邮票孔编号 |
| 【核图】 | `原理图\AC601-EG4S20_原理图.pdf` | 4 页，Altium 导出；**只有核心板**（FPGA+SRAM+Flash+电源+154 pin 连接器），文本层只有位号/球号/网络名，**无器件型号** |
| 【底板图】 | `底板设计源文件\AC201_EG4S20_评估底板设计源文件.rar` | 内含 `AC201_EG4S20.PrjPcb`、8 个 `.SchDoc`（01_FPGA/02_AUDIO/03_general/04_IIC+IIS_Audio/05_POWER/06_HDMI/07_1GbNET/08_connector）、`AC201_EG4S20.PcbDoc`、`AC201_EG4S20.pdf` |
| 【底板PDF】 | `03-SRAM...\AC201-240515.pdf`（8 页）/ rar 内 `AC201_EG4S20.pdf` | 文本层同样只有位号与网络名，无元件参数，故器件型号取自 `.SchDoc` |
| 【IO.adc】 | `01-board_test基础自检\AC201_AL_board_test\IO.adc` | **实际生效**的约束（`.al` 的 `constraint_1` 只挂了 `IO.adc` + `timing.sdc`） |
| 【pin.adc(未用)】 | `...\src\user_source\constraints_source\pin.adc` | 未被工程引用，与 IO.adc 冲突（见 §5 待确认 1） |
| 【SRAM文档】 | `03-SRAM...\sram.md`、`doc\sram_uart_notes.md`、`C883296_..._IS61WV25616EDBLL-10TLI_规格书_WJ126315.PDF` | 明确写了板载 SRAM 料号与容量 |
| 【面积报告】 | `01-board_test...\AC201_AL_board_test_Runs\syn_1\AC201_AL_board_test_gate.area`、`03-SRAM...\syn_1\..._gate.area` | 器件容量与占用 |
| 【README】 | `..\README_先读我.txt` | AC208 = AC201-EG4S20 WM8960 版，芯片 EG4S20BG256 |

---

## 2. 芯片与资源

- **器件**：`EG4S20BG256`（`.al` 中 `<Device>EG4S20BG256</Device>`；【README】第 9 行）。
- **封装/引脚**：BGA256，FT256 外形（底板图 01_FPGA 里核心板符号 `H154-AC601-EG4S20-FBGA256`）。
- **总量（TD `*.area` 里 "out of" 的上限，即工具认定的器件容量）**：

| 资源 | 总量 |
| --- | --- |
| LUT | 19 600（`#lut ... out of 19600`） |
| 寄存器 | 19 600（`#reg ... out of 19600`，TD 按 slice 计） |
| BRAM 9Kb | 64 块（`#bram ... out of 64`，子项 `#bram9k`） |
| BRAM 32Kb | 16 块 |
| DSP | 29（`#dsp ... out of 29`） |
| IO/PAD | 188 |
| PLL | 4 |
| 全局时钟 GCLK | 16 |
| 特殊 CSB | 2 |

  → BRAM 合计约 64×9 Kb + 16×32 Kb = **1088 Kb ≈ 136 KB**。
- **实测占用（参考）**：board_test 整板例程 `#lut 5286 (26.97%)`、`#reg 3860`、`#bram 29 (45.31%)`、`#pll 4/4 (100%)`、`#IO 120 (63.83%)`。**PLL 已被板测例程用满 4 个**（【面积报告】board_test_gate.area）。

> 芯片无 JPEG 解码硬核、无视频硬核。题目里的"硬件 JPEG 解码"只能用 LUT/BRAM 自己搭 RTL（19 600 LUT 对 baseline JPEG 解码器偏紧，需早评估）。【核图】与器件表里没有任何视频/编解码芯片。

---

## 3. 时钟与复位

| 项 | 事实 | 来源 |
| --- | --- | --- |
| 板载时钟 | **50 MHz**，接 FPGA `K14`（无邮票孔编号 → 属核心板功能） | 【管脚表】第 8 行；【IO.adc】`clk`=K14 |
| 时钟来源 | 核心板 4 脚有源晶振（U10 旁 `Y1`，引脚 `PIY101..104`） | 【核图】第 2 页（page obj 10） |
| 其它晶振 | 25 MHz `Y2` 给 RTL8211F PHY；32.768 kHz `Y1` 给 PCF8563 RTC | 【底板图】07_1GbNET（`OSC`、`Y2`）、04_IIC+IIS_Audio（`32.768k`、`Y1`） |
| PLL 资源 | 4 个；板测例程已全部用掉 | 【面积报告】 |
| 板测例程 PLL 配置 | `pll_hdmi1_4b`：输入 50 MHz，输出 100 / 75 / 375 MHz；`pll_hdmi`：33/33/24/165/8.192 MHz | `al_ip\pll_hdmi1_4b\pll_hdmi1_4b.ipc`、`al_ip\pll_hdmi\pll_hdmi.ipc` |
| 时序约束 | `pixel_clk` 13.5 ns（≈74.07 MHz）、`serial_clk` 2.7 ns（≈370 MHz），两时钟 exclusive | `src\user_source\constraints_source\timing.sdc` |
| 复位 | 无专用复位芯片；板测用 `rst_n = KEY2 (H14)` | 【IO.adc】`rst_n`=H14；【管脚表】第 106 行 KEY2=H14 |

---

## 4. 存储器

### 4.1 SDRAM —— **芯片内部有（8 MB），板上无需颗粒**（本节已更正）

| 项 | 结论 |
| --- | --- |
| 位置 | **EG4S20BG256 芯片内部**（片内 SDRAM 硬宏），不占 FPGA 引脚，因此板级管脚表/原理图里查不到 |
| 容量/组织 | `EG_PHY_SDRAM_2M_32`：2M×32 bit = **8 MB / 64 Mbit**，32 bit 数据，4 bank，11 位地址 |
| 怎么用 | TD IP：`SDRAM PHY`（`EG_PHY_SDRAM`，device=EG4S20BG256）；例程 `01-board_test\src\5640\sdram_ctrl_4p\` 已给出完整控制器 + 两个 FIFO |

证据：
1. 官方《2026 全国大学生嵌入式芯片与系统设计竞赛 FPGA 赛道选题指南（安路）》推荐平台 1：`EG4S20BG256 … 片内集成 SDRAM：2Mx32bit`（[指南 PDF](anlogic_2026_guide.pdf)）。
2. 安路官网 SALEAGLE 4 系列："部分器件内置 64M bit SDR SDRAM"（[产品页](https://www.anlogic.com/product/fpga/saleagle)）。
3. `sdram_ip.v` 端口为 `clk/ras_n/cas_n/we_n/addr[10:0]/ba[1:0]/dq[31:0]/cs_n/dm0-3/cke`——`IO.adc` 里没有这些引脚，正说明它们连的是**片内**宏。
4. 板级 BOM/原理图确实没有 SDRAM 颗粒（第 1 版据此误判为"没有 SDRAM"，教训：片内资源不会出现在板级资料里）。

> 用法注意：`Sdram_Control_4Port` 只能**顺序流式**访问（每端口有内部地址计数器），没有逐字随机口；对 640×480 帧缓存足够，但做"解码块序→显示行序"需要额外行缓存重排。

### 4.2 SRAM（`03-SRAM` 例程用的那颗）—— **512 KB**

| 项 | 事实 | 来源 |
| --- | --- | --- |
| 型号 | **IS61WV25616EDBLL-10TLI**（ISSI 异步 SRAM，带透明 ECC） | 【SRAM文档】`sram.md` 第 1 节；规格书 PDF 文件名 |
| 组织 | 256K × 16 bit = 4 Mbit = **512 KB** | 同上；`doc\sram_uart_notes.md`（合法地址 `0x00000~0x3FFFF`） |
| 位宽 | 16 bit，`LB#`/`UB#` 支持按字节访问 | 同上 |
| 速度 | **10 ns**（@3.3 V，可 2.4–3.6 V） | 同上 |
| 封装 | 44-pin TSOP Type II | 同上 |
| 时钟 | 异步，无时钟、无刷新，靠 CE#/OE#/WE# 控制 | 同上 |
| 地址线 | A0–A17（例程 `ADDR_W=18`） | `rtl\sram_async_ctrl.v` 第 18 行、`rtl\sram_uart_top.v` 第 22 行 |
| 挂在哪 | **核心板板载**（无邮票孔编号） | 【管脚表】第 9–48 行 D 列为空 |
| 引脚 | A0..A18 → B3,A2,B2,C3,B1,L1,M1,N1,P1,R1,L4,L5,K3,K5,J3,F5,F4,F3,J4；DQ0..15 → C2,C1,D3,D1,H3,J1,K1,K2,G3,G1,H2,H1,E2,E1,F2,F1；CE#=H4, WE#=J6, OE#=G5, LB#=G6, UB#=H5 | 【管脚表】第 9–48 行；【IO.adc】03 工程逐条核对一致 |

> **待确认**：管脚表与核心板原理图都引出了第 19 根地址线 `SRAM_A18 = J4`（【核图】第 3 页网标 `NLA18` 接 U2），但实装 25616 只有 A0–A17、例程也只用 18 位。推测是为兼容 512K×16（1 MB，如 IS61WV51216）留的焊盘/走线。

### 4.3 其它存储

| 器件 | 型号 | 接口/引脚 | 来源 |
| --- | --- | --- | --- |
| 配置 Flash | 板上 SPI Flash（核心板 U3，8 pin） | `FLASH_CLK`=R11, `MOSI`=T10, `MISO`=P10, `CS#`=T3, `WP#`=J14, `HOLD#`=R9 | 【管脚表】第 49–54 行；【核图】第 3 页 U3 |
| EEPROM | **24LC256**（32 KB，I²C） | 与音频/RTC 共用 I²C：`IIC_SCL`=L16(37), `IIC_SDA`=M16(36) | 【底板图】04_IIC+IIS_Audio（`24LC256`）；【管脚表】第 89–90 行 |

---

## 5. HDMI

| 项 | 事实 | 来源 |
| --- | --- | --- |
| 连接器 | **J4，HDMI 母座（表贴）**，标准 19 pin Type-A（符号里 pin15=`DDC CLK`、pin16=`DDC DATA`） | 【底板图】06_HDMI.SchDoc（`LibReference=HDMI`，值 `HDMI母口`，位号 J4） |
| TMDS lane 数 | **4 对差分**：CLK + D0 + D1 + D2（3 data lane + 1 clock lane，HDMI 1.4 标准） | 同上网标 `DVI_CLK_P/N`、`DVI_TX0..2_P/N`；【管脚表】第 75–82 行 |
| 是否直连 FPGA | **是**，FPGA LVDS 差分直接输出，`IOSTANDARD = LVDS33_E` | 【IO.adc】`O_tmds_ch0_p`=D11、`ch1`=C11、`ch2`=F10、`clk`=B10 |
| HDMI 发送芯片 | **无**。底板上只有 2 片 **AZ1045-04F**（4 路 ESD 阵列，U12/U13）+ 8 个隔直/滤波电容 C55–C62 + R46/R47/R48 | 【底板图】06_HDMI.SchDoc 器件表 |
| DDC/EDID | 连接器 15/16 pin 有 DDC CLK/DATA，板上有 3 个 10 K 上拉（5 V 侧 `VCC5.0`），但**没有引到 FPGA**：FPGA 网标、管脚表里都没有 DDC 信号 | 同上；【管脚表】无 DDC 行 |
| HPD / CEC | **未引出**（原理图与管脚表均无 HPD/CEC 网标） | 同上 |
| 是否带音频 | **板上不带**。HDMI 侧只有 TMDS + DDC 上拉，没有音频回传/嵌入器件；板载音频是独立的 WM8960 模拟通路（§7）。板测例程 `design_top_wrapper` 里 HDMI IP 的 `I_i2s_*` 全部接 `1'b0` | 【底板图】06_HDMI；`src\user_source\hdl_source\design_top_wrapper.v` 第 61–72、159–165 行；`hardware_test.v` 第 275–277 行 |

**引脚明细（TMDS，全部 LVDS33_E，DRIVESTRENGTH=8）**

| 信号 | P 脚 | N 脚 | 邮票孔(P/N) |
| --- | --- | --- | --- |
| TMDS_CLK | B10 | C9 | 80 / 79 |
| TMDS_D0 | D11 | D12 | 82 / 81 |
| TMDS_D1 | C11 | A11 | 84 / 83 |
| TMDS_D2 | F10 | H11 | 86 / 85 |

> 参考实现：`src\user_source\hdl_source\hdmi_phy_warpper.v` + `lane_lvds_10_1.v`（10:1 LVDS 串化，用 ODDR/IDDR 原语）+ 加密 IP `hdmi1.4b_transmitter_core\hdmi_1_4b_transmitter_core_wrapper.enc.v`（TD 加密，支持 RGB/YCbCr、VIC、TPG、音频 ACR、EDID 读取）。**该 IP 支持音频，但板上音频要从 FPGA 内部产生**（板上有 I2S 到 WM8960 的输出，没有"音频输入到 HDMI"的现成通路）。
> 例程默认输出 1280×720@60（`HTOTAL 1650 / HACTIVE 1280 / VTOTAL 750 / VACTIVE 720`，`design_top_wrapper.v` 第 126–137 行），640×480 需要改参数并重配 PLL（25.175 MHz pixel / 251.75 MHz serial）。

---

## 6. TF 卡（MicroSD）

| 项 | 事实 | 来源 |
| --- | --- | --- |
| 卡座 | **MicroSD_SOCKET**（TF），底板 S4 | 【底板图】04_IIC+IIS_Audio.SchDoc（`SDCARD_TF` / `MicroSD_SOCKET`，注释 `SPI SD卡接口`） |
| 模式 | **SPI 模式，1 bit**（只有 4 根信号，没有 DAT1/DAT2/DAT3） | 同上网标仅 `SD_CLK/SD_MOSI/SD_MISO/SD_SC` |
| CLK | **M2**（邮票孔 126） | 【管脚表】第 91 行 |
| MOSI(CMD) | **L3**（125） | 第 92 行 |
| MISO(DAT0) | **K6**（127） | 第 93 行 |
| CS | **R2**（124） | 第 94 行 |
| 卡检测 CD / 写保护 WP | **没有**（管脚表无此信号；原理图也没有） | — |
| 供电 | 3.3 V（VDD3.3） | 【底板图】04 |
| 例程验证 | `02-uart_sd_rw` 用 `spi_driver.v`（Mode0）+ `sd_init.v` 发 `CMD0(0x40)/CMD8(0x48)/CMD55(0x77)/ACMD41(0x69)`，确认 SPI 初始化流程 | `rtl\sd_init.v` 第 35–38 行 |

---

## 7. 音频（WM8960）

| 项 | 事实 | 来源 |
| --- | --- | --- |
| 编解码器 | **WM8960CGEFL/RV**（Wolfson/Cirrus 立体声 Codec） | 【底板图】02_AUDIO.SchDoc（`LibReference=WM8960CGEFL/RV`） |
| 控制口 | I²C：`IIC_SCL`=**L16**(37)、`IIC_SDA`=**M16**(36)，与 24LC256 / PCF8563 共用，例程用 `function_pin.v` 分时复用 | 【管脚表】第 83–90 行；`src\function_pin.v`（`mode=iis_done` 切换） |
| 数据口 | I²S（主/从由配置定），6 根：MCLK/BCLK/DACLRC/DACDAT/ADCLRC/ADCDAT | 同上 |
| MCLK | **18.432 MHz**，由 FPGA PLL 产生（`clk_18_3` → `aud_xck`） | `src\audio_loop_back.v` 第 25、45 行；`hardware_test.v` 第 244–256 行 |
| 采样率 / 格式 | 48 kHz、双声道、I²S（例程 `SAMPLE_RATE=48000`，`DATA_WIDTH=32`」 | `src\audio_loop_back.v` 第 26–31 行 |
| 板上接口 | 绿色 3.5 mm = 耳机输出；蓝色 = Line-in（板测玩法：电脑放歌→耳机能听到） | `00-工程操作说明文档.docx` 第 21 行 |
| 其它 | 有 Mic1 输入、`LI`（Line In）、喇叭 header；I²C 上还有 24LC256、PCF8563 | 【底板图】02/04 |

**I²S 引脚（【管脚表】第 83–88 行，权威）**

| 信号 | FPGA 脚 | 邮票孔 |
| --- | --- | --- |
| I2S_MCLK | **B8** | 96 |
| I2S_BCLK | **C8** | 97 |
| I2S_DACLRC | **A8** | 98 |
| I2S_DACDAT | **A7** | 101 |
| I2S_ADCLRC | **C7** | 102 |
| I2S_ADCDAT | **C6** | 103 |

> ⚠️ 板测例程 `IO.adc` 里写的是 `I2S_DI`=C7、`I2S_DO`=A8、`I2S_RCLK`=A7，与上表**错位**（上表里 C7=ADCLRC、A8=DACLRC、A7=DACDAT，且 C6 完全没用到）。以管脚表/原理图为准；板测的音频通路上游是从 ES8388 板移植过来的（工程里同时存在 `ES8388_init_table.v`），实际能否出声**待实测确认**。

---

## 8. 其它外设

| 外设 | 明细 | 引脚 | 来源 |
| --- | --- | --- | --- |
| 用户 LED ×4 | LED0–3 | M12(26)、R16(25)、R15(24)、T15(21) | 【管脚表】100–103 |
| 独立按键 ×3 | KEY0/1/2（低有效，例程 `key_0/key_1`，KEY2 被当 `rst_n` 用） | F7(110)、E7(111)、H14(45) | 104–106；【IO.adc】 |
| 拨码开关 ×8 | SW0–SW7（上拨为亮/1） | N14(34)、K12(33)、J12(32)、M13(31)、L13(30)、P14(29)、P16(28)、P15(27) | 109–116 |
| 8 位数码管 | 三线串行：2 片 **74HC595PWR**，16 bit = `{seg[8], sel[8]}`（段选+位选各 8 位），动态扫描 | `SEG7_SCLK`=T14(18)、`SEG7_RCLK`=R12(19)、`SEG7_DIO`=R14(20) | 97–99；【底板图】03_general（`74hc595`×2、`smg_6*8`×2）；`src\HEX_top.v`、`src\HEX8.v` |
| 蜂鸣器 | 有源/无源蜂鸣器 + NPN 驱动 | `BEEP`=N16(35) | 107；03_general（`BUZZER2`、`SS8050LT`） |
| 红外接收 | IR 一体化接收头 | `IR`=D9(94) | 108；03_general（`IR`） |
| 串口 | **CH340E** USB 转串口，USB-C 16pin 座 | `UART_RXD`=E4(122)、`UART_TXD`=P2(123) | 95–96；04_IIC+IIS_Audio（`CH340E`、`USB-C-16`） |
| 以太网 | **RTL8211F-CG** 千兆 PHY + **HR911130A** 一体化 RJ45（RGMII），25 MHz 晶振 Y2；`ETH_INT_N` 只在网络名里出现，未接 FPGA | TXC=E15, TX_CTL=F16, TXD0/1/2/3=E16,F14,F13,D16, RXC=F9, RX_CTL=E12, RXD0/1/2/3=F12,H16,G16,F15, MDC=C16, MDIO=D14, RESET#=C15 | 60–74；07_1GbNET |
| CMOS 摄像头 | 8 bit DVP + SCCB（OV5640 例程），另有 PWDN/RST（例程里接到内部，管脚表未列） | PCLK=D8, XCLK=A3, HREF=C4, VSYNC=A4, SCLK=B5, SDAT=A6, D0–D7=E6,E3,C5,F6,D5,B6,E8,D6 | 117–130；`src\5640\` |
| 屏接口 | 16 位并口：`tft_rgb[15:0]` + `tft_clk/de/hs/vs/bl`，占用 GPIO2 组引脚；底板上该连接器为 **Header 18×2（36 pin）**，网标 `LCD_D0–D15 / LCD_RS / LCD_CS / LCD_RD / LCD_WR / LCD_BL` + 触摸 `T_CS/T_SCK/T_MOSI/T_MISO/T_PEN` | rgb0..15 = H15,G14,B15,B16,A14,J11,K11,H13,J13,G12,G11,K15,L14,M14,J16,K16；clk=B14, de=A12, hs=C13, vs=E13, bl=A13 | 131–193（GPIO2 组）+ IO.adc `tft_*`；08_connector |
| 扩展 GPIO | GPIO0_0..35（2×20 排针，40 pin）、GPIO2_0..27（2×18 排针，36 pin，与屏接口共用） | 见管脚表 131–194 | 131–194；08_connector |
| JTAG | TCK=C14(150)、TDI=C12(149)、TDO=E14(3)、TMS=A15(154)，IDC 2×5 座 | — | 4–7；01_FPGA（`IDC Box 2X5`） |
| 配置/状态 | PROGRAM_B=T2、INIT_B=R3、DONE=P13、MSEL0=T11、MSEL1=N11 | — | 55–59 |
| 电源 | DC 电源座 J3 + 开关 **SS-13F24-G050**；**MP2143DJ** 同步 Buck（反馈网络 499K/44.2K/200K，有 `VCC1P5_PG` 电源良好信号，疑为 1.5 V 核压）+ **XC6206P332MR** 3.3 V LDO；网络 `VCC5.0 / VDD3.3 / VDD2.5 / EX_VCC` | — | 05_POWER；01_FPGA 网标 |

> 引脚表里 `GPIO0_14`(L10)、`GPIO0_15`(M9) 等与【pin.adc(未用)】里的 `IO_ddc_sda`(M10)、`O_ddc_scl`(P12) 冲突，说明那份 pin.adc 是别的板/版本的约束。

---

## 9. 对本项目（TF→JPEG→帧缓存→HDMI 640×480）的直接影响

### 9.1 帧缓存容量（已更正：用片内 8 MB SDRAM）

帧缓存放**片内 8 MB SDRAM**（2M×32），不再受 512 KB SRAM 限制：

| 方案 | 单页需求 | 8 MB 余量 |
| --- | --- | --- |
| 640×480 RGB888 (24 bpp) | 921 600 B ≈ **900 KB** | 可放 2 页（双缓冲）+ 余量 |
| 640×480 RGB565 (16 bpp) | 614 400 B = **600 KB** | 可放 2–3 页 |
| 640×480 RGB444 (12 bpp) | 460 800 B = 450 KB | 充裕 |
| 640×480 8 bpp | 307 200 B = 300 KB | 充裕 |

→ 原第 1 版"16 bpp 单缓冲都放不下"的结论作废。**512 KB 外部 SRAM** 仍有用：可放 2 个 64 KB 压缩帧槽（正好对应参考图 2 的"两个 64 KiB 压缩帧槽"），或做解码条带缓存。

### 9.2 SRAM 带宽（推算，待实测）

- 640×480@60 显示读带宽 = 25.175 M 像素/s × 2 B ≈ **50 MB/s**（16 bpp），或 25 MB/s（8 bpp）。
- 单口异步 SRAM @10 ns 理论 100 M 次/s（200 MB/s），但 `sram_async_ctrl.v` 是"建立→等待→采样"4 拍状态机：50 MHz 下只有 **12.5 M 次/s（25 MB/s）**，连 8 bpp 都不够宽裕；需把 SRAM 节拍提到 ≥100 MHz 并做显示/解码双口仲裁（或用 8 bpp 让 1 个字装 2 像素，把访问数减半）。

### 9.3 HDMI 输出

- 硬件链路 OK：4 对 LVDS 直连，无发送芯片，TMDS 由 `hdmi_phy_warpper` + 加密 IP 产生，例程已跑通 720p。
- **640×480@60 需 25.175 MHz pixel / 251.75 MHz serial**（10:1），必须重配 PLL（现有 `pll_hdmi1_4b` 是 75/375 MHz 档），并把 IP 的 `HTOTAL/HACTIVE/VTOTAL/VACTIVE`（800×525 / 640×480）改掉。
- **没有 EDID/DDC/HPD** → 无法读显示器能力、无法做热插拔检测，只能固定时序输出（对 640×480 反而无所谓）。
- **HDMI 音频**：IP 支持（I2S 输入 + ACR），但板上没有"音频进 FPGA"的专用输入；音频数据只能来自 TF 卡里的 PCM 文件（FPGA 内部产生），再同时送 HDMI 和 WM8960。若只做"HDMI 带声音"，需自己接 I2S 到 IP 的音频口。

### 9.4 其它缺口

- **无 SDRAM、无外部大容量存储**：整帧缓存方案先天受限（§9.1）。
- **TF 只有 SPI 1 bit**：读一张 640×480 JPEG（约 30–60 KB）在 SPI 25 MHz 下约 10–20 ms，可接受；但 SPI 模式下**不能 4 bit 并发**，也没有 DMA/总线主控。
- **JPEG 解码要靠自写 RTL**（无硬核），19 600 LUT / 136 KB BRAM 要同时容纳 JPEG 解码 + HDMI TX IP + SDRAM/SRAM 控制器 + SD 控制器，资源需早算账（板测例程已占 5286 LUT、29 BRAM、4/4 PLL）。
- **PLL 只有 4 个且板测已用满**：新工程要规划 50 MHz 系统 / 25.175 MHz pixel / 251.75 MHz serial / 18.432 MHz audio MCLK 的分配（可一个 PLL 多输出）。

---

## 10. 待确认清单

| # | 事项 | 现状 | 建议核实方式 |
| --- | --- | --- | --- |
| 1 | HDMI DDC 到底接没接 FPGA | 底板 06_HDMI 有 DDC CLK/DATA(pin15/16)+3×10K 上拉，但无 FPGA 网标；`pin.adc`(未启用) 却把 DDC 指到 M10/P12（=GPIO0_4/0_3） | 万用表量 J4 pin15/16 到 M10/P12 通断；或看 `AC201_EG4S20.PcbDoc` 网络表 |
| 2 | I²S 六个信号的真实引脚 | 管脚表 vs `IO.adc` 在 C7/A7/A8/C6 上错位 | 以管脚表为准；实板用 I²S 环回/示波器验证 |
| 3 | SRAM 是否 512 KB 还是 1 MB | 料号 25616（512 KB）+ 19 根地址线（A18=J4）并存 | 看板上丝印；或写 A18 测试 |
| 4 | 电源各轨电压（1.5 V? 2.5 V?） | 只有 `VCC1P5_PG`、`VDD2.5` 等网标，无实测值 | 量 MP2143 输出 |
| 5 | 屏接口/摄像头接口与哪个排针一一对应 | 08_connector 有 40/36/20 pin 三种排针与 LCD_*/CMOS_*/GPIO* 网标，但 PDF 无位号-网标对应表 | 看 PCB 丝印（Header 20X2 疑为摄像头，18X2 疑为屏） |
| 6 | 板测音频是否真能出声 | 例程 I²S 引脚与管脚表错位，且带 ES8388 初始化表 | 烧 bit 实测 |

---

## 11. 快速索引：本项目直接用到的引脚

```
clk 50MHz        K14
HDMI TMDS        CLK B10/C9, D0 D11/D12, D1 C11/A11, D2 F10/H11   (LVDS33_E)
SD (SPI)         CLK M2, MOSI L3, MISO K6, CS R2
WM8960 I2S       MCLK B8, BCLK C8, DACLRC A8, DACDAT A7, ADCLRC C7, ADCDAT C6
WM8960 I2C       SCL L16, SDA M16
SRAM             地址 A0..A17 (B3,A2,B2,C3,B1,L1,M1,N1,P1,R1,L4,L5,K3,K5,J3,F5,F4,F3)
                 数据 DQ0..15 (C2,C1,D3,D1,H3,J1,K1,K2,G3,G1,H2,H1,E2,E1,F2,F1)
                 控制 CE# H4, WE# J6, OE# G5, LB# G6, UB# H5
UART             RX E4, TX P2
按键/LED/数码管   KEY0 F7, KEY1 E7, KEY2 H14 | LED0-3 M12,R16,R15,T15 | SEG7 T14/R12/R14
```
