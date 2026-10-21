# M0 里程碑报告：HDMI 640×480 彩条（TD 2026.1 SP2 / AC208 EG4S20BG256）

- 日期：2026-10-21
- 状态：**编译验收通过（bit 已生成）**；功能未上板实测（无硬件）
- 工程：`E:\fpga-2026\dsh_code\proj\m0_hdmi\`（新建，纯英文路径）
- 依据：`docs/specs/2026-10-21-hdmi-basic-player-design.md` §3/§5、`docs/research/td-toolchain.md`、`hw-facts.md`、`example-arch.md`
- 原始资料目录 `E:\fpga-2026\选题一-EG4S20-HX4S20C官方例程\` **只读未改**（只把 3 个 HDMI 相关源文件拷进新工程）

---

## 0. 结论速览

| 项 | 结果 |
|---|---|
| 工程/顶层 | `proj/m0_hdmi/m0_hdmi.al`，顶层 `m0_top`（6 个 IO：50 MHz 时钟、KEY2 复位、4 对 TMDS） |
| PLL | 1 个（4 个里的 1 个），50 MHz → **25.000 MHz 像素 + 125.000 MHz 串行**（同一 VCO 1000 MHz） |
| 视频源 | 自写 `rtl/video_gen.v`，8 条竖彩条（白/黄/青/绿/品红/红/蓝/黑），RGB888，AXIS 流 |
| HDMI 核参数 | `VIDEO_TPG="Disable"`、`VIDEO_VIC=1`、`VIDEO_FORMAT="RGB"`，时序 800×525 / 640×480 |
| 编译 | **一次全清编译 17.8 s**（syn ≈6 s + phy ≈12 s），`TD_FLOW_OK`，退出码 0 |
| bit | `E:\fpga-2026\dsh_code\proj\m0_hdmi\m0_hdmi_Runs\phy_1\m0_hdmi.bit`，**629,635 B**，SHA256 `3292C26F…696A41F3`（header 里带编译时间，故 SHA 每次编译都变；payload 可复现，见 §6.2） |
| 资源 | LUT **1244/19600 (6.35%)**、FF **1127/19600 (5.75%)**、BRAM **8/64 (12.5%)**、PLL **1/4 (25%)**、GCLK 3/16、IO 6/188 |
| 时序（final/routed） | Setup **WNS +5.501 ns**（0 违例端点），Hold **WNS +0.003 ns**（0 违例端点） |
| 遗留风险 | 未上板实测；串行时钟相位只能到 39.4°；hold 裕量仅 3 ps（`tlast` 已通过 bit 不变性验证，见 §8.3） |

---

## 1. 工程结构与文件来源

```
proj/m0_hdmi/
├── m0_hdmi.al                  TD 工程文件（GUI 可打开；TD_Version 必须是数字版号，见 §7.2）
├── IO.adc                      引脚约束（6 个 IO）
├── timing.sdc                  时钟约束（50 / 25 / 125 MHz，三者 exclusive，见 §5）
├── run_flow.tcl                DefaultFlow 的 CI wrapper（TD_FLOW_OK / exit 1）
├── build.ps1                   一条命令全清重编
├── README.md                   工程速览
├── rtl/
│   ├── m0_top.v                顶层（新写）
│   ├── video_gen.v             640×480 彩条 AXIS 源（新写）
│   ├── hdmi_phy_warpper.v      ← 厂商原样拷贝
│   ├── lane_lvds_10_1.v        ← 厂商原样拷贝
│   └── hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v  ← 厂商加密 IP 原样拷贝
├── al_ip/pll_m0_hdmi/
│   ├── pll_m0_hdmi.v           PLL（按厂商生成文件结构手改分频，见 §4.2）
│   ├── pll_m0_hdmi.ipc         仅作文档，**未挂进工程**
│   └── README.txt              PLL 推导过程
└── m0_hdmi_Runs/
    ├── syn_1/                  settings.cfg + m0_hdmi.prj + 综合产物
    └── phy_1/                  settings.cfg + m0_hdmi.prj + 布局布线产物 + m0_hdmi.bit
```

厂商文件来源（全部只读拷贝，原件未动）：
`E:\fpga-2026\选题一-EG4S20-HX4S20C官方例程\03-AC208板例程(AC201-EG4S20_WM8960版)\01-board_test基础自检\AC201_AL_board_test\src\user_source\hdl_source\`

**没有**带进来的：以太网、OV5640/摄像头、RTC、红外、蜂鸣器、数码管/74HC595、SDRAM 控制器、WM8960/音频、36 位 `gpio_40pin`、`hardware_test.v`、`design_top_wrapper.v`、`video_source_test.v`、`key_remove_shakes.v`、`I2S_receiver.v`、`audio_arc_calculate.v`。工程里只挂 `m0_top` 一个顶层。

---

## 2. 怎么把工程建起来的（可复现的建工程流程）

1. **建目录**：`proj/m0_hdmi/{rtl, rtl/hdmi1.4b_transmitter_core, al_ip/pll_m0_hdmi, m0_hdmi_Runs/{syn_1,phy_1}}`。
2. **拷 HDMI 链**：`hdmi_phy_warpper.v`、`lane_lvds_10_1.v`、加密核 `hdmi_1_4b_transmitter_core_wrapper.enc.v` 原样拷贝（加密核只读端口/改参数例化即可，TD 无需额外 license）。
3. **写新 RTL**：`m0_top.v`（照 `design_top_wrapper.v` 的例化方式，只保留 HDMI 链）、`video_gen.v`。
4. **做 PLL**：TD **没有可脚本化的 IP 生成器**（`read_ipc_file` 只是"加载已生成的 IP"，见 §7.1），所以复制厂商同器件生成文件 `Sdram_PLL.v` / `pll_hdmi1_4b.v` 的参数结构、重算分频，写成普通 Verilog 文件 `al_ip/pll_m0_hdmi/pll_m0_hdmi.v`。
5. **工程文件**：手写 `.al`（XML）+ 两个 run 目录的 `settings.cfg` / `m0_hdmi.prj`（格式照 `proj/td_smoke/uart_sd_rw.al` 与 board_test 的 `.al`/`.prj`；路径相对工程、正斜杠、带 `UsedInSyn/UsedInP&R/BelongTo/CompileOrder` 属性）。
6. **约束**：`IO.adc`（6 条 `set_pin_assignment`）+ `timing.sdc`。
7. **编译**：`build.ps1` → 17.8 s 得 bit。全清编译（删掉两个 run 目录里除 `settings.cfg`、`m0_hdmi.prj` 外的所有文件）实测通过，说明工程自包含、可复现。

---

## 3. 视频时序与 AXIS 映射（`rtl/video_gen.v`）

| 参数 | 值 | 参数 | 值 |
|---|---:|---|---:|
| HTOTAL | 800 | VTOTAL | 525 |
| HSA | 96 | VSA | 2 |
| HBP | 48 | VBP | 33 |
| HFP | 16 | VFP | 10 |
| HACTIVE | 640 | VACTIVE | 480 |

- 像素时钟 25.000 MHz → 行频 31.25 kHz → 帧频 **59.52 Hz**（CEA-861 640×480p60，VIC=1）。
- 计数器自由运行并与 HDMI 核同时复位（同一 `S_rst_pixel`）；有效区 = `line >= 45 && col >= 160`（HBLANK = 800−640 = 160，VBLANK = 525−480 = 45），每行正好 640 拍、每帧 480 行。
- 彩条：x = col−160，`x/80` 分 8 段，每段 80 px：白 `FFFFFF`、黄 `FFFF00`、青 `00FFFF`、绿 `00FF00`、品红 `FF00FF`、红 `FF0000`、蓝 `0000FF`、黑 `000000`；`{R[7:0],G[7:0],B[7:0]}`。
- AXIS：`valid`/`data`/`user`/`last` 在同一个时钟块里打拍，保证同一拍上的数据与打拍前的计数一致（不会错位 1 像素）：
  - `user`（SOF）= 帧第一个有效像素（line 45、col 160）
  - `last`（EOL）= **行最后一个有效像素**（col = HTOTAL−1 = 799）
  - `I_video_ready` 未使用（见 §8）
- 设计时踩到的坑：`last` 最初写成 `HTOTAL−HFP−1`（=783），会提前 16 像素——已改成 `HTOTAL−1`（代码复查发现，已修）。

---

## 4. HDMI 核与 PLL

### 4.0 顶层 `m0_top` 结构

```verilog
module m0_top (
    input  wire clk,            // 50 MHz, K14
    input  wire rst_n,          // KEY2, H14, low active
    output wire O_tmds_ch0_p,   // D11/D12
    output wire O_tmds_ch1_p,   // C11/A11
    output wire O_tmds_ch2_p,   // F10/H11
    output wire O_tmds_clk_p    // B10/C9
);

pll_m0_hdmi u_pll(...)                    // 50 MHz -> S_pixel_clk 25M / S_serial_clk 125M
// KEY2 -> 2FF @clk -> S_rst_n_async = pll_lock & key_n
// S_rst_n_async -> 2FF @S_pixel_clk  -> S_rst_pixel   (async assert / sync release)
// S_rst_n_async -> 2FF @S_serial_clk -> S_rst_serial  (async assert / sync release)
video_gen #(800/96/48/16/640, 525/2/33/10/480) u_video_gen(...)   // AXIS 彩条源
hdmi_1_4b_transmitter_core_wrapper u_hdmi_core(...)               // 加密 IP
hdmi_phy_wrapper u_hdmi_phy(...)                                  // 4 x lane_lvds_10_1
endmodule
```

整条链只有 1 个 PLL、1 个视频源、1 个 HDMI 核、4 个串行器；没有其它外设逻辑。

### 4.1 加密核参数（`m0_top.v` 例化）

```verilog
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE("EG"),
    .HTOTAL(800), .HSA(96), .HFP(16), .HBP(48), .HACTIVE(640),
    .VTOTAL(525), .VSA(2),  .VFP(10), .VBP(33), .VACTIVE(480),
    .VIDEO_VIC(1),            // 640x480p60
    .VIDEO_TPG("Disable"),    // 关键：关掉核内自带测试图
    .VIDEO_FORMAT("RGB"),
    .AUDIO_SAMPLE_RATE("48K"),
    .IIC_SCL_DIV(125)
) u_hdmi_core ( ... );
```

音频/ACR/EDID 端口全部接常量（`I_audio_valid=0`、`I_acr_*=0`、`I_edid_read_trig=0`），DDC 输出接内部空线（板上 DDC/HPD/CEC 都没引到 FPGA）。

**`VIDEO_TPG="Disable"` 生效的硬证据**（对比 board_test 相同核、TPG=Enable）：

| 模块 | board_test（TPG=Enable） | 本工程（TPG=Disable） |
|---|---|---|
| `hdmi_video_tpg_gen` | 105 LUT，存在 | **不存在**（area 报告里 0 处 `tpg`） |
| `video_source_test`（外部源） | 1 LUT（被优化掉） | —— |
| `video_axi_stream_receiver` | 27 LUT | **63 LUT + 67 FF + 3 BRAM**（真在收数据） |
| `hdmi_video_source` | —— | 133 LUT + 43 FF（真在出图） |

### 4.2 PLL 参数（`al_ip/pll_m0_hdmi/pll_m0_hdmi.v`）

| 参数 | 值 | 说明 |
|---|---|---|
| FIN / REFCLK_DIV / FBCLK_DIV | 50.000 MHz / 1 / 20 | 内部反馈（`FEEDBK_MODE=NOCOMP`、`FEEDBK_PATH=VCO_PHASE_0`）→ VCO = 50×20/1 = **1000 MHz** |
| CLKC0 | DIV=10, CPHASE=9, FPHASE=0 | 100.000 MHz（反馈抽头，未用） |
| CLKC1 | DIV=40, CPHASE=39, FPHASE=0 | **25.000 MHz 像素时钟** |
| CLKC2 | DIV=8, CPHASE=7, **FPHASE=7** | **125.000 MHz 串行时钟**，相位 45×7/8 = **39.375°**（0.875 ns） |
| 环路滤波 | GMC_GAIN=4, ICP_CURRENT=13, KVCO=4, LPF_CAPACITOR=1, LPF_RESISTOR=4 | 直接照抄 `Sdram_PLL.v`（同为 VCO 1000 MHz、PFD 50 MHz） |

- 关系式（用厂商 3 个 PLL 的 `.ipc`/`.v` 反推并互相验证）：
  - 内部反馈（`VCO_PHASE_0`）：`Fvco = FIN × FBCLK_DIV / REFCLK_DIV`，`CLKCn = Fvco / CLKCn_DIV`
  - 外部反馈（`CLKC0_EXT`，`pll_hdmi1_4b` 用）：`Fvco = FIN × CLKC0_DIV × FBCLK_DIV / REFCLK_DIV`
  - 相位编码（反推，4 个输出全部对得上）：
    `相位 = (CLKCn_CPHASE + 1 + CLKCn_FPHASE/8) / CLKCn_DIV × 360°`
    · 0° 输出：厂商一律写 `CPHASE = DIV−1`（退化为 `45×FPHASE/DIV`）
    · 验证点 1：`pll_hdmi1_4b` C2（DIV=3, CPHASE=2, FPHASE=6）→ 450° ≡ **90°**（与头部注释一致）
    · 验证点 2：`Sdram_PLL` C1（DIV=10, CPHASE=6, FPHASE=4）→ **270°**（与头部注释一致）
    · 本工程 C2（DIV=8, CPHASE=7, FPHASE=7）→ **39.375°**
  - `CLKCn_FPHASE` 只有 0..7（一步 = VCO 周期/8 = 0.125 ns）
- **小数分频不是真的小数**：`.ipc` 里写 73.33/366.67 之类，实际是"固定 VCO 后整数分频"，所以 25.175 MHz 做不到——本工程用 **25.000 MHz**（帧率 59.52 Hz，绝大多数显示器可接受）。
- **相位**：厂商 720p 用 90°（DIV=3、FPHASE=6 → 6/8 VCO = 90°）；本工程 125 MHz（DIV=8）要 90° 需 FPHASE=16，**超出 0..7 范围**，只能取最大值 7 → 39.375°（0.875 ns）。TD 自己派生时钟时也打印 `-multiply_by 2.5 -phase 39`，与该推导一致。详见 §8.2 备选方案。

### 4.3 复位

- `rst_n` = KEY2(H14) 低有效，先过 50 MHz 的 2 级同步器（去亚稳），再与 `pll_lock` 相与得到 `S_rst_n_async`。
- 再在**每个 PLL 时钟域各做一次"异步置位、同步释放"**：`S_rst_pixel`（25 MHz，给 video_gen + HDMI 核）、`S_rst_serial`（125 MHz，给 4 个 TMDS 串行器）。
- 这样就没有跨时钟域的异步复位释放路径，post-route 只剩 3 个域内 path group（§6.3）。

---

## 5. 约束

### 5.1 `IO.adc`（与最终 `*_phy.area` 的 Detailed IO Report 逐条一致）

| 信号 | 脚 | IOSTANDARD | 其它 |
|---|---|---|---|
| `clk` | K14 | LVCMOS33 | PULLUP |
| `rst_n` | H14 | LVCMOS33 | PULLUP |
| `O_tmds_ch0_p` / (n) | D11 / D12 | LVDS33_E | DRIVESTRENGTH=8, DDRX1 |
| `O_tmds_ch1_p` / (n) | C11 / A11 | LVDS33_E | 同上 |
| `O_tmds_ch2_p` / (n) | F10 / H11 | LVDS33_E | 同上 |
| `O_tmds_clk_p` / (n) | B10 / C9 | LVDS33_E | 同上 |

只约束 `_p` 端，`_n` 端由工具自动配对（与厂商例程一致），工具实际分配结果就是上表括号里的脚。

### 5.2 `timing.sdc`

```tcl
create_clock -name clk_50m -period 20.000 -waveform {0 10.000} [get_ports {clk}]

create_generated_clock -name pixel_clk  -source [get_ports {clk}] -divide_by 2 \
    [get_pins {u_pll/pll_inst.clkc[1]}]

create_generated_clock -name serial_clk \
    -source [get_pins {u_pll/pll_inst.clkc[1]}] -multiply_by 5 \
    [get_pins {u_pll/pll_inst.clkc[2]}]

set_clock_groups -exclusive \
    -group [get_clocks {clk_50m}] -group [get_clocks {pixel_clk}] -group [get_clocks {serial_clk}]
```

为什么不是三句 `create_clock`（这里踩了 4 次坑，都是实测）：

1. `[get_nets {S_pixel_clk}]` 这种写法（厂商例程用的）在综合后网名会变成 `u_hdmi_core/I_pixel_clk_syn_*` 等，**不可靠**，本工程不用。
2. `[get_pins {u_pll/clk1_out}]` → `No pins matched`：`pll_m0_hdmi` 只是普通模块，被 flatten 掉，只剩 PLL 宏实例 `u_pll/pll_inst`，PLL 输出引脚名是 `u_pll/pll_inst.clkc[1]`（点号分隔）。
3. 在 `clkc[1]` 上 `create_clock` → `USR-8194: primary clock pixel_clk is on the network of clock clk_50m. Please define it as a generated clock instead.` 因为 PLL 没注册成 IP，TD 把宏当"直通"，认为 PLL 输出仍属 `clk_50m` 网络。→ 用 `create_generated_clock`（结果周期仍是 **40 ns / 8 ns**，即 25.000 / 125.000 MHz）。
4. TD 的 `create_generated_clock` **不允许同时** `-multiply_by` 和 `-divide_by`（`USR-8157`）。125 MHz = 25 MHz × 5，所以串行时钟从**像素时钟**派生 ×5，而不是从 50 MHz 派生 ×2.5。
5. `-exclusive` 分组必须把 `clk_50m` 也列进去：只分 pixel/serial 两组时，TD 会把核的一部分寄存器判成 `clk_50m` 域，仍然分析出 `clk_50m → serial_clk` 的跨域路径并报 **−1.898 ns** 的假 WNS（见 §8 的"踩坑记录"）。

最终 TD 报的时钟表证实约束正确：`pixel_clk 25.000 MHz / 40 ns`、`serial_clk 125.000 MHz / 8 ns`、`clk_50m 50 MHz / 20 ns`，且 post-route 只有 3 个"域内"path group。

---

## 6. 编译与结果

### 6.1 一条可复现命令

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\fpga-2026\dsh_code\proj\m0_hdmi\build.ps1
```

`build.ps1` 内部等价于（必须分别 cd 进两个 run 目录）：

```powershell
cd E:\fpga-2026\dsh_code\proj\m0_hdmi\m0_hdmi_Runs\syn_1
E:\bin\td_commands_prompt.exe E:/fpga-2026/dsh_code/proj/m0_hdmi/run_flow.tcl   # read_design → opt_rtl → opt_gate

cd ..\phy_1
E:\bin\td_commands_prompt.exe E:/fpga-2026/dsh_code/proj/m0_hdmi/run_flow.tcl   # opt_place → opt_route → bitgen
```

要点（沿用 `td-toolchain.md`）：Tcl 路径必须正斜杠；裸跑 exe 失败也返回 0 且可能停在 `td >`，所以用 `run_flow.tcl` 包一层（成功 `TD_FLOW_OK` + exit 0，失败 `TD_FLOW_FAILED: ...` + exit 1）。

**耗时**（32 线程，全清编译，实测）：

| 阶段 | 命令时间 | wall |
|---|---:|---:|
| syn_1（read_design + opt_rtl + opt_gate） | 3 s | ≈6 s |
| phy_1（opt_place 3.3 s + opt_route 7.7 s + bitgen） | 11 s | ≈12 s |
| **合计** | — | **17.8 s** |

日志：`m0_hdmi_Runs/syn_1/console_ci.log`、`.../phy_1/console_ci.log`；TD 详细日志 `td_2026*.log`。license 命中 4 次 `Open license file E:/license/Anlogic.lic`，无 license 报错。

### 6.2 bit 文件

```
E:\fpga-2026\dsh_code\proj\m0_hdmi\m0_hdmi_Runs\phy_1\m0_hdmi.bit
  629,635 字节
  SHA256 3292C26F69C2806F7DD926B35AD08A6AFEEAE9BD962B83C88E646B17696A41F3
```

**可复现性**：两次独立的全清编译，去掉 `#` 头部之后的 **280 行 payload 逐行完全一致**、`Bitstream CRC` 相同，只有头部 `# Date:` 行不同（所以文件 SHA256 每次编译都会变，这是正常现象——和 `td-toolchain.md` §3.5 里厂商参考 bit 的对比结论一致）。

头部：

```
# Anlogic ASCII Bitstream
# Version: Release_2026.1_SP2
# Design name: m0_top
# Architecture: eagle_s20
# Package: EG4S20BG256
# Date: 2026/10/21 12:45
# Bitstream CRC: 11001010001100101111110010110010
# USER CODE: 00000000101111110000000000000000
# Transfer CRC: 10011010100010101111110111110101
```

bitgen 日志：`BIT-1004 : PLL setting string = 0001`、`BIT-1004 : Generate bits file m0_hdmi.bit.`（PLL 已被写进 bit 配置串）。

### 6.3 资源占用（`phy_1/m0_hdmi_phy.area`，post-route）

| 资源 | 用量 | 总量 | 占比 |
|---|---:|---:|---:|
| LUT（`#lut`，含进位链） | **1,244** | 19,600 | **6.35%** |
| └ `#Total_luts`（纯 LUT4/5，取自综合 `gate.area`） | 813（lut4 763 + lut5 50） | — | — |
| 寄存器 FF（`#reg`） | **1,127** | 19,600 | **5.75%** |
| 逻辑单元 LE | 1,588 | — | — |
| BRAM9K（`#bram`） | **8** | 64 | **12.50%** |
| BRAM32K | 0 | 16 | 0% |
| DSP | 0 | 29 | 0% |
| **PLL** | **1** | 4 | **25.00%** |
| GCLK | 3 | 16 | 18.75% |
| PAD / IO | 10 / 6 | 188 | 5.32% / 3.19% |

层次（lut / seq / bram）：

| 模块 | LUT | FF | BRAM |
|---|---:|---:|---:|
| `m0_top` 合计 | 1,031 | 1,132 | 8 |
| ├ `u_hdmi_core`（加密核） | 904 | 1,026 | 8 |
| │ ├ `hdmi_tmds_encode` ×3 | 123+120+125 | 167+110+115 | 0 |
| │ ├ `hdmi_island_data_assemble` | 249 | 374 | 0 |
| │ ├ `hdmi_island_data_gen`（含音频 FIFO） | 81 | 81 | 5 |
| │ ├ `hdmi_video_source` | 133 | 43 | 0 |
| │ └ `video_axi_stream_receiver`（含 w24_d1024 FIFO） | 63 | 67 | 3 |
| ├ `u_hdmi_phy`（4×lane） | 37 | 45 | 0 |
| ├ `u_video_gen`（彩条源） | 60 | 25 | 0 |
| └ `u_pll`（宏） | 0 | 0 | 0 |

GCLK 分配：`S_pixel_clk`（PLL clkc1，623 负载）、`u_hdmi_phy/.../I_serial_clk`（clkc2，32 负载）、`clk_dup_1`（输入脚，3 负载）。

### 6.4 时序（`phy_1/final_timing.rpt`，final / routed，Slow+Fast 角）

```
Setup : WNS  +5501 ps  TNS 0 ps  NUM_FEPS 0
Hold  : WNS    +3 ps   TNS 0 ps  NUM_FEPS 0
```

| 时钟 | 约束周期 | SWNS | HWNS | 端点数 | 实测最短周期 / Fmax |
|---|---:|---:|---:|---:|---:|
| `pixel_clk` 25 MHz | 40.000 ns | **+33.593 ns** | +0.003 ns | 1,520 | 6.407 ns / 156 MHz |
| `clk_50m` 50 MHz | 20.000 ns | **+16.814 ns** | +0.239 ns | 74 | 3.186 ns / 314 MHz |
| `serial_clk` 125 MHz | 8.000 ns | **+5.501 ns** | +0.239 ns | 72 | 2.499 ns / 400 MHz |

- STA 覆盖 99.94%，只有 3 个域内 path group（`pixel_clk→pixel_clk`、`clk_50m→clk_50m`、`serial_clk→serial_clk`），**没有跨域 path group**。
- 全局 WNS = **+5.501 ns**，来自 125 MHz 串行域（TMDS 串行器），裕量 69%。
- **注意 hold 只有 +3 ps**：工具认为通过，但余量极小（厂商同一流程的 uart 例程也只有 +25 ps，属该流程常态）。见 §8、§9。

---

## 7. 踩坑记录（都实测过，供后续复用）

### 7.1 TD 没有可用的命令行 IP 生成器

- `read_ipc_file <x.ipc>` **不是生成器**，只是"加载已生成的 IP"：报 `Load IPC file E error, the IP's generated file E doesn't exist`（同时暴露它把带冒号的路径截断成 `E`）。
- `xmlipgen` 只针对 XML 类 IP（FIFO Designer 等），提示 `XmlIpGen cannot find all xml file`。
- 结论：PLL 只能 ①GUI 里点，或 ②复制厂商生成文件改参数。本工程选 ②（更快、可 review、可复现），并把 `.ipc` 留作文档但不挂进工程，避免 GUI 误重新生成。

### 7.2 `.al` / `.prj` 的 `TD_Version` 必须是数字版号

写 `<TD_Version>Release_2026.1_SP2</TD_Version>` 会让 `open_project` **直接 coredump**（`Oops! coredump minidump-*.dmp`，无任何错误码）。改成 `<TD_Version>6.2.190657</TD_Version>`（TD 自己写文件时的值）即可正常打开/编译。

### 7.3 `UsedInP&R` 不要写成 `&amp;`

TD 自己生成的 `.al`/`.prj` 里是裸 `&`。跟着它写（不做 XML 转义）才与工具一致。

### 7.4 `create_clock` vs `create_generated_clock`、`exclusive` 分组

见 §5.2 的 5 条。特别提醒：**如果只在 pixel/serial 之间做 exclusive**，TD 会因"PLL 未被识别为 PLL"把核的一部分寄存器归到 `clk_50m`，从而分析出跨域路径并报 **Setup WNS −1.898 ns / Hold WNS −3.906 ns** 的假违例（本工程第一版就是这样）。把 `clk_50m` 也放进 exclusive 组后，路径组只剩 3 个域内组，WNS +5.501 ns。

---

## 8. 没解决的问题 / 只能上板验证的东西

1. **功能完全没上板验证**。验收按任务要求以"编译通过 + bit 生成 + 参数/约束正确"为准。彩条是否稳定、颜色/顺序是否正确、显示器是否认这个时序，都要上板。
2. **串行时钟相位只能到 39.4°**（`CLKCn_FPHASE` 0..7，一步 0.125 ns）。厂商 720p 用的是 90°。这个相位只是像素域→串行域的采样余量旋钮（数据/时钟 lane 用完全相同的逻辑串行化，所以不影响引脚上 data/clock 的关系）。若上板出现雪花/闪烁/整屏抖动，可按下面顺序试：
   - 把 `CLKC2_FPHASE` 在 0..7 之间扫（改一个数字，重编译 18 s）；
   - 或把 VCO 换成 **500 MHz**（`FBCLK_DIV=10`、`CLKC0_DIV=5`、`CLKC1_DIV=20`、`CLKC2_DIV=4`、`CLKC2_FPHASE=7` → 78.75°，更接近 90°），此时环路滤波参数需要复核（不再与 `Sdram_PLL` 同 VCO）；
   - 25.175 MHz（真 CEA 值）本工程做不到：VCO 必须是 25.175 的整数倍，而 50 MHz 参考 + 整数 M/N/D 只能出 1000/500/250… 的组合，没有 25.175 的整数倍落在 PLL 合法 VCO 区间；要精确 25.175 得换参考时钟。
3. **AXIS `tlast` 语义（风险已降级）**。加密核里 `video_axi_stream_receiver` 只有 63 LUT + 3 BRAM。实测证据：把 `last` 的产生条件从 `col==783`（错误值）改成 `col==799`（行末有效像素）后，**bit 的 payload 与 `Bitstream CRC` 一字不变**，说明核内部没有使用 `I_axis_s_last`（TD 顺带把没人用的 `O_video_last` 也优化掉了）。所以 `tlast` 大概率对画面没有影响；本设计仍按 AXI-Video 标准在每行最后一个有效像素给出 `tlast`。若上板出现"图像左移/行错位/滚屏"，优先怀疑 FIFO 对齐/`ready`（下一条），而不是 `tlast`。
4. **`I_video_ready` 被忽略**：`video_gen` 自由跑计数，不看反压（与厂商 `video_source_test` 一致）。核内有 1024 深 FIFO，正常不会反压；若上板出现竖条错位，可改为 `valid && ready` 才推进数据（但会破坏时序对齐，需谨慎）。
5. **hold 裕量只有 +3 ps**（`pixel_clk` 域）。逻辑上通过、工具 0 违例，但余量极小。若上板不稳定，可在 `phy_1/settings.cfg` 打开 `set arr_filter true` + `set drHoldFix on`（DefaultFlow 会走 `fix_hold`），或降像素时钟/降低核内频率需求后重编。
6. **25.000 MHz 而不是 25.175 MHz**：帧率 59.52 Hz（不是 59.94）。CEA-861/VESA 显示器一般都能锁；个别老显示器/采集卡/带 EDID 强校验的设备可能不认，且本板**没有 DDC/EDID/HPD**，无法读显示器能力，也不能热插拔检测。
7. **PLL 环路滤波参数是抄的**（同 VCO 1000 MHz、同 PFD 50 MHz 的 `Sdram_PLL`），没有实测 lock 时间/抖动。上板时如果 PLL 不锁（`extlock` 常 0），则整个设计一直处于复位（黑屏）——这是第一个要量的信号。
8. **没有做仿真**：本机没有 iverilog/verilator/Questa，TD 的命令行也没有可用的仿真入口，`video_gen` 的时序只做了代码级核对（时长/计数/彩条边界）。如果需要，下一步可以用 `E:\sim_release\eg4` + ModelSim 补一个 testbench。

---

## 9. 上板时要注意什么

1. **必须先给 KEY2 复位**：`rst_n`（H14）低有效，按住 KEY2 再松开（或上电后按一次），PLL 锁定后才会出图。若黑屏，先量 PLL `extlock`（可临时把 `S_pll_lock` 引到 LED 或 ChipWatcher）。
2. **显示器/线材**：接 HDMI 显示器（不是 DVI-only 老设备），分辨率 640×480@60。板上无 EDID/DDC/HPD，显示器要能"盲锁"这个固定时序（绝大多数可以）。
3. **下载**：用 TD 的 Board Debugger / `bw.exe` 通过 JTAG 下载 `m0_hdmi.bit`（本机没接板，未验证下载链路）；`bit` 头部 `Design name: m0_top`、`Architecture: eagle_s20`、`Package: EG4S20BG256` 均正确。
4. **预期画面**：8 条等宽竖彩条，从左到右 白/黄/青/绿/品红/红/蓝/黑，满屏无边框；如果颜色顺序或宽度不对，问题在 `video_gen` 的 `S_bar_idx`/`HBLANK`；如果图像整体偏移，问题在核内 FIFO 对齐或 `ready`（§8.4/8.5），`tlast` 基本可以排除（§8.3 的实测证据）。
5. **不要用**官方例程的 `run.bat`（写死旧路径 + `pause`）。

---

## 10. 附录：关键日志片段

综合（`m0_hdmi_Runs/syn_1/console_ci.log`）：

```
RUN-1002 : start command "elaborate -top m0_top"
HDL-1007 : elaborate module pll_m0_hdmi in ../../al_ip/pll_m0_hdmi/pll_m0_hdmi.v(29)
HDL-1007 : elaborate module EG_PHY_PLL(FIN="50.000000",FBCLK_DIV=20,CLKC0_DIV=10,CLKC1_DIV=40,
           CLKC2_DIV=8,CLKC0_ENABLE="ENABLE",CLKC1_ENABLE="ENABLE",CLKC2_ENABLE="ENABLE",
           FEEDBK_MODE="NOCOMP",STDBY_ENABLE="DISABLE",CLKC2_FPHASE=7,...) in E:\arch/eagle_macro.v(889)
HDL-1007 : elaborate module hdmi_1_4b_transmitter_core_wrapper(HTOTAL=800,HSA=96,HFP=16,HBP=48,
           HACTIVE=640,VTOTAL=525,VSA=2,VFP=10,VBP=33,VACTIVE=480,VIDEO_TPG="Disable",VIDEO_VIC=1)
...
RUN-1001 : Open license file E:/license/Anlogic.lic
...
TD_FLOW_OK
```

布局布线 + bitgen（`m0_hdmi_Runs/phy_1/console_ci.log`）：

```
RUN-1003 : finish command "place" in  3.344625s wall ...
RUN-1003 : finish command "route" in  7.739471s wall ...
BIT-1002 : Init instances completely, inst num: 868
BIT-1003 : Generate bitstream completely, there are 41269 bits set as '1'.
BIT-1004 : PLL setting string = 0001
BIT-1004 : Generate bits file m0_hdmi.bit.
TD_FLOW_OK
```

时序（`phy_1/route_flow.status`）：

```
Timing Mode      : final
Setup            : WNS  5501ps  TNS        0ps  NUM_FEPS     0
Hold             : WNS     3ps  TNS        0ps  NUM_FEPS     0
```

---

## 11. 与 M0 验收要求的逐条对照

| # | 要求 | 结果 | 证据 |
|---|---|---|---|
| 1 | 新建 TD 工程，纯英文路径，EG4S20BG256 | ✅ | `proj/m0_hdmi/m0_hdmi.al`，`<Device>EG4S20BG256</Device>` |
| 2 | 顶层改名，只保留 50 MHz / KEY2 复位 / 4 对 TMDS | ✅ | `m0_top`，6 个 IO；层次里无以太网/摄像头/RTC/红外/数码管/SDRAM/音频；无 `hardware_test.v`/`design_top_wrapper.v` |
| 3 | PLL 50 MHz → 25.0 + 125.0（10:1），相位沿用原例程做法 | ✅（相位受限 39.4°，已说明） | §4.2；`pll_m0_hdmi.v` |
| 4 | 自写 `video_gen` 8 条竖彩条 RGB888，`VIDEO_TPG=Disable`、`VIC=1`、`RGB` | ✅ | §3、§4.1；area 报告无 `tpg` 模块 |
| 5 | `IO.adc` + `timing.sdc`（25/125 MHz、exclusive、不用内部网名） | ✅ | §5；post-route 时钟表 40 ns / 8 ns |
| 6 | 必须编译到 bitgen 成功，报告资源与时序 | ✅ | §6.2、§6.3、§6.4 |

---

## 12. 下一步（M1 衔接）

- 帧缓存接 `video_gen` 的数据口：把彩条 `S_bar_color` 换成从片内 SDRAM 读出的像素（保持 AXIS 时序不变），本工程无需改顶层端口与约束。
- 若 M1 要加 100 MHz 系统时钟，可在同一个 PLL 加 `CLKC3`（DIV=10 → 100 MHz），PLL 还有 3 个没用。
- 上板调通 M0 后，把 §8.2/8.3 的结论（相位、tlast）回写到本报告，避免 M1 重复踩坑。
