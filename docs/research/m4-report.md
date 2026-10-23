# M4 里程碑报告：板载 WM8960 音频输出（I2C 初始化 + I2S 发送 + 1 kHz 正弦测试音）

- 日期：2026-10-21（离线版）；**2026-10-23 上板实测通过**
- 状态：**已上板验证通过**（2026-10-23：耳机 1 kHz 出声，D3+D2 常亮、D1 灭）；
  **离线模型 146 项检查全 PASS**；上板实测、引脚修正与 I²C 帧时序修复见 **§10**
- 工程：`E:\fpga-2026\dsh_code\proj\m4_audio\`（由 M3 工程复制 → 改名 → 重建 run 目录）
- 依据：`docs/research/m3-report.md`（先读）、`m0-report.md`、`hw-facts.md` §7、
  `example-arch.md` §5、`docs/specs/2026-10-21-hdmi-basic-player-design.md` §8；
  **WM8960 数据手册 Rev 4.2**（页码在 §5.4 逐条标注）
- 原始资料 `E:\fpga-2026\选题一-EG4S20-HX4S20C官方例程\` **只读未改**：
  三个 I2C 框架文件与寄存器表**没有拷贝**，而是按同样三段式结构重写（改动逐条列在 §5）；
  音频 PLL 按 M0 的手写方式新写；27 个厂商 .v 文件（SD 引擎 16 + SDRAM 控制器 8 + HDMI 3）
  逐字节未改（只在复制时把 `m3_`→`m4_` 应用于本工程自己的文件）

---

## 0. 结论速览

| 项 | 结果 |
|---|---|
| 工程/顶层 | `proj/m4_audio/m4_audio.al`，顶层 `m4_top`，**26 个 IO**（M3 的 19 个 + 音频 7 个） |
| 新增 IO | `I2S_MCLK`=B8、`I2S_BCLK`=C8、**`I2S_DACLRC`=A7**、**`I2S_DACDAT`=A8**、`I2C_SCL`=L16、`I2C_SDA`=M16（三态）；原 `I2S_ADCLRC`=C7 **已删除**（C7 是 codec 输出脚，见 §10.3） |
| 时钟 | **新增第 5 个时钟域 `mclk_audio` = 12.288136 MHz**，第 3 个 PLL（`pll_m4_audio`，VCO 725 MHz，C0=59）；**+11 ppm**，见 §4 |
| I2S | FPGA 主机：BCLK = MCLK/4 = **3.072034 MHz**、LRCK = BCLK/64 = **48.0005 kHz**、16 bit 数据在 32 bit 槽内、DACDAT 在 BCLK 下降沿更新、MSB 在 LRCK 翻转后第 2 个上升沿（严格 Philips I2S） |
| I2C | 40.06 kHz（分频 312×4），**13 条寄存器**全部 ACK 检查、NACK 重试 3 次、失败即静音；总线 16 位控制字 = 7 bit 地址 + 9 bit 数据（两字节），器件写地址 **0x34** |
| 测试音 | 1 kHz（**1000.011 Hz**，+11 ppm）、48 kHz、16 bit、双声道同数据、峰值 16384 = **−6.02 dBFS**、THD+N **−55.6 dB** |
| 编译 | 全清编译 **81~92 s**（三次实测 81.1 / 89.6 / 92.2 s；syn ≈ 20 s + phy ≈ 62~72 s），`TD_FLOW_OK`，退出码 0；最终 RTL 的两次独立全清编译 payload **1218 行逐行一致** |
| bit | `m4_audio_Runs/phy_1/m4_audio.bit`，**630 799 B**，`Design name: m4_top`，`Bitstream CRC 10000111101000001100101000000010`，`PLL setting string = 1011` |
| 资源 | LUT **5101/19600 (26.03%)**、FF **4444 (22.67%)**、BRAM **18/64**、**PLL 3/4**、GCLK 7/16、IO 26/188；相对 M3 **+406 LUT / +226 FF / +1 BRAM / +1 PLL / +1 GCLK / +7 IO** |
| 时序（final/routed） | Setup **WNS +0.111 ns**（0 违例）、Hold **WNS +0.003 ns**；**5 个时钟域全部收敛，无跨域 path group**；`mclk_audio` 域余量 **+73.5 ns** |
| 离线验证 | `sim/model_m4_audio.py`：**146 项全 PASS**（PLL 数学 13 + 寄存器位域 42 + 厂商表缺陷 19 + I2C 位流 22 + 失败路径 8 + I2S 波形 16 + 正弦 18 + 引脚一致性 9，实际分布见 §9） |
| 遗留风险 | 未上板；PLL 725 MHz VCO 的环路滤波参数是抄同器件 1000 MHz 配置（M4-R1，附一键退路）；WM8960 耳机座接 LOUT1/ROUT1 属推断（M4-R2）；SD `spi_clk` 仍无 SDC（M2 R1 继承）；100 MHz 域余量 **0.111 ns**（M3-R7 同批路径） |

---

## 1. 与 M3 的差异一览（"只动了该动的"）

```
proj/m4_audio/
├── m4_audio.al                  ← 工程名/顶层名/文件清单（make_proj_files.ps1 重新生成）
├── IO.adc                       ← +7 个音频引脚（26 个 IO）
├── timing.sdc                   ← +1 个 generated clock（mclk_audio）+ exclusive 组加一组
├── run_flow.tcl / build.ps1     ← 只改工程名/路径
├── make_proj_files.ps1          ← 文件清单 +7（音频 7 个 .v）、改名
├── README.md                    ← 重写（M4 使用说明）
├── rtl/
│   ├── m4_top.v                 ← 改名 + 7 个新端口 + 音频段（PLL/复位/I2C/正弦/I2S，约 150 行新增）
│   ├── m4_wm8960_table.v        ← **新增**：13 条寄存器表（每条带数据手册依据）
│   ├── m4_i2s_bit_shift.v       ← **新增**：位级 I2C（重写厂商 i2s_bit_shift）
│   ├── m4_i2s_control.v         ← **新增**：一帧 3 字节写（重写厂商 i2s_control，修正数据字节数）
│   ├── m4_i2s_init_dev.v        ← **新增**：表遍历 + 重试 + 延时（重写厂商 i2s_init_dev）
│   ├── m4_sine_rom.v            ← **新增**（生成文件）：1/4 波正弦表 256×16
│   ├── m4_sine_tone.v           ← **新增**：相位累加器 + 象限镜像
│   ├── m4_i2s_tx.v              ← **新增**：I2S 主机发送
│   ├── m4_video_src.v / m4_seg7.v / m4_hc595.v / m4_fat_bmp.v / ...  ← 仅改名（逻辑未动）
│   ├── sd_spi/(16) sdram_ctrl_4p/(8) hdmi 链/(3)                      ← 逐字节未改
├── al_ip/pll_m4_hdmi/           ← 仅改名（参数未动）
├── al_ip/pll_m4_audio/          ← **新增**：音频 PLL
├── sim/gen_sine_rom.py          ← **新增**：正弦表生成器（--check 校验 RTL 与生成器一致）
├── sim/model_m4_audio.py        ← **新增**：146 项模型
├── sim/model_m4_ctrl.py         ← M3 的 75 项模型（原样保留，M3 逻辑未改）
├── sim/model_fat32_bmp.py       ← M2 的 80 项模型（原样保留）
└── m4_audio_Runs/{syn_1,phy_1}/
```

验证方式（脚本比对，不是肉眼）：

| 检查 | 结果 |
|---|---|
| `m4_byte_seq / m4_pix_pump / m4_page_wr / m4_sd_sec / m4_video_src / m4_seg7 / m4_hc595` 与 M3 版本（`m3_`→`m4_` 后）逐字符比较 | **完全相同** |
| 32 个厂商文件 SHA256 与 M3 副本比较 | 相同（复制时未改内容） |
| `rtl/m4_sine_rom.v` 与 `sim/gen_sine_rom.py` 输出比较（`--check`） | 一致 |
| `m4_top.v` 与 `m3_top.v` diff | 只有"头注释 + 端口 + 音频段 + led3 选择"四处，M3 逻辑一行未动 |

---

## 2. 系统架构

### 2.1 时钟域（5 个，M4 新增 1 个）

| 时钟 | 频率 | 用途 | M4 新增内容 |
|---|---:|---|---|
| `clk_50m` | 50 MHz | KEY2 同步、两个 PLL 的参考、**WM8960 I2C 初始化** | **整个 I2C 引擎**（40 kHz SCL） |
| `pixel_clk` | 25.000 MHz | 光栅 / AXIS / 页控制 / 按键 / 轮播 / 数码管 | 无 |
| `serial_clk` | 125.000 MHz | 4 路 TMDS 串行器 | 无 |
| `sdram_clk` | 100.000 MHz | SDRAM / SD SPI / FAT32 / 写页 | 无（只多了 `init_ok` 的 2FF，用于可选 LED） |
| **`mclk_audio`** | **12.288136 MHz** | **正弦发生器 + I2S 发送** | **新增**（第 3 个 PLL） |

> **为什么 I2C 放 50 MHz 域**：I2C 是 40 kHz 的慢速位操作，与任何域都异步；放 50 MHz 域
> 可以完全不动 M3 的 100 MHz 余量（M3/M4 只有 0.111~0.744 ns 余量），也不需要在高速域加逻辑。
> **为什么正弦/I2S 放 MCLK 域**：MCLK 是 codec 的主时钟，用它分频出 BCLK/LRCK 可以让
> MCLK:BCLK:LRCK 严格保持 4:1:256 的整数关系（无累加误差、无毛刺），这是 I2S 主机最稳的做法。

### 2.2 音频通路

```
 50 MHz 域                                                     12.288 MHz 域 (mclk_audio)
┌──────────────────────────────────────────────┐   init_ok   ┌────────────────────────────────┐
│ u_i2c_init (m4_i2s_init_dev)                 │   ──2FF──▶  │ u_tone (m4_sine_tone)          │
│  ├ u_table (13 条 {delay,reg,data})          │             │   32 bit 相位累加器            │
│  └ u_ctrl (m4_i2s_control)                   │             │   + u_rom (256×16, 1 BRAM)     │
│      └ u_bit (m4_i2s_bit_shift)              │             │        │ sample (16 bit)       │
│           │ SCL / SDA(oe,o,i)                │             │        ▼                       │
└───────────┼──────────────────────────────────┘             │ u_i2s_tx (m4_i2s_tx)           │
            ▼                                                │   BCLK = MCLK/4                │
      I2C_SCL (L16)  ────────────────┐                       │   LRCK = BCLK/64               │
      I2C_SDA (M16)  ── 三态 ────────┤                       │   DACDAT 下降沿更新            │
                                     ▼                       └───┬────────┬────────┬────────────┘
                            ┌──────────────────┐                 │        │        │
                            │ WM8960 (从机)     │◀────────────────┘        │        │
                            │  R7 MS=0 从机     │   I2S_MCLK B8  ◀─────────┘        │
                            │  48 kHz / 16 bit  │   I2S_BCLK C8   ◀──────────────────┤
                            │  DAC → 耳机      │   I2S_DACLRC A8 ◀───────────────────┤
                            └──────────────────┘   I2S_DACDAT A7 ◀───────────────────┘
                                 (I2S_ADCLRC C7 也由 FPGA 输出，ADC 未用但脚不悬空)
```

### 2.3 上电时序

```
KEY2 释放 ─┬─ HDMI PLL 锁 ──▶ M3 显示链起振（与 M3 完全相同）
           └─ 音频 PLL 锁 ──▶ S_rst_n_audio 释放
                                  ├─ 50 MHz 域：2FF 同步释放 → I2C 引擎复位释放
                                  │      ├ 10 ms 上电延时（codec 自身 POR）
                                  │      ├ 13 条寄存器 × 675 µs ≈ 8.8 ms
                                  │      └ 寄存器间延时：1 ms + **500 ms**(VMID) + 10+10+10 ms
                                  │            ⇒ 约 551 ms 后 O_ok = 1
                                  └─ 12.288 MHz 域：2FF 同步释放 → 正弦 + I2S 立即开始跑
                                        （DACDAT 一直是 0，直到 init_ok 同步过来）
```

> 注意：**音频 PLL 没锁不会影响 HDMI**。M3 的复位链 `S_rst_n_async` 只包含 HDMI PLL 锁，
> M4 另开一条 `S_rst_n_audio = S_rst_n_async & audio_lock` 给音频用（§3.3）。

---

## 3. 顶层改动（`rtl/m4_top.v`）

### 3.1 新增端口（7 个，全部按管脚表）

| 端口 | 脚 | 方向 | 说明 |
|---|---|---|---|
| `I2S_MCLK` | B8 | out | 12.288136 MHz（PLL 直出，走全局时钟网后到 PAD）；核心板 pin 96 = ES_MCLK |
| `I2S_BCLK` | C8 | out | 3.072034 MHz；核心板 pin 97 = ES_DSCLK |
| `I2S_DACLRC` | **A7** | out | 48.0005 kHz；核心板 pin 101 = **ES_DLCLK**（管脚表误标为 A8，见 §10.3） |
| `I2S_DACDAT` | **A8** | out | 串行数据；核心板 pin 98 = **ES_DSDIN** |
| ~~`I2S_ADCLRC`~~ | ~~C7~~ | ~~out~~ | **已删除**：C7 = 核心板 pin 102 = ES_ASDOUT，是 **codec 的输出脚**，不能驱动（§10.3） |
| `I2C_SCL` | L16 | out | 推挽（板上只有一个主） |
| `I2C_SDA` | M16 | inout | 三态：`oe ? o : 1'bz`，ACK 位读回 |

### 3.2 为什么 SDA 用三态而 SCL 不用

I2C 规范里两根线都是开漏，但本板 SCL 只有 FPGA 一个主设备，推挽驱动上升沿更干净
（40 kHz 下无争议）；SDA 必须双向——写数据时驱动，ACK 位必须释放给从机拉低，
否则读不到 ACK、也就无法实现"初始化失败就静音"。这与厂商 `function_pin.v` 的
`oe/o/i` 分解是同一个思路，只是 M4 不需要再和 RTC 分时复用（直接独占总线）。

### 3.3 复位与跨域

```verilog
wire S_rst_n_async = S_pll_lock & S_key_n_sync[1];          // M3 原样（HDMI PLL）
wire S_rst_n_audio = S_rst_n_async & S_audio_lock;          // M4 新增（音频 PLL）

// 50 MHz 域：异步置位、同步释放
always @(posedge clk or negedge S_rst_n_audio) ...
wire S_rst_i2c = ~S_rst_i2c_sync[1];

// 12.288 MHz 域：同样异步置位、同步释放
always @(posedge S_mclk or negedge S_rst_n_audio) ...
wire S_rst_mclk = ~S_rst_mclk_sync[1];

// init_ok：50 MHz → 12.288 MHz，2FF 电平同步（准静态，只有一个方向）
always @(posedge S_mclk or negedge S_rst_n_audio)
    S_ok_sync <= {S_ok_sync[0], S_init_ok};
wire S_tone_en = S_ok_sync[1];
```

整个 M4 只有 **1 根跨域信号**（`init_ok`，准静态电平）——这也是 §7 里
"无跨域 path group"的原因。

### 3.4 `DEBUG_LED` 参数（上板首日神器）

```verilog
module m4_top #(parameter DEBUG_LED = 0) ( ... );
wire S_led3 = DEBUG_LED ? S_init_ok_sdram[1] : S_disp_page;
```

默认 0 = **M3 行为完全不变**（led3 = 页 A/B）。改成 1 重编译（85 s），
`led[3]`(T15) 就变成"WM8960 初始化全部 ACK"指示灯：**常亮 = I2C 全通**，
灭 = 没通或没跑完。这样上板第一眼就能区分"I2C 问题"还是"模拟通路问题"。

---

## 4. 时钟推导：为什么是 725 MHz VCO / C=59

### 4.1 精确 12.288 MHz 在数学上不可能

EG4S20 的 `EG_PHY_PLL`（内部反馈 `FEEDBK_MODE=NOCOMP`、`FEEDBK_PATH=VCO_PHASE_0`）满足

```
f_vco = f_in × FBCLK_DIV / REFCLK_DIV          (M/N，均为 1..128 的整数)
f_out = f_vco / CLKCn_DIV                       (C，1..128 的整数)
⇒ f_out = 50 MHz × M / (N × C)
```

要求 `f_out = 12.288 MHz`，即

```
M/(N·C) = 12.288/50 = 0.24576 = 768/3125
```

`3125 = 5⁵`，而 `768 = 2⁸·3`，两者互素（模型检查 1.09/1.10）。所以
`N·C` 必须是 3125 的倍数，最小解 `C = 3125` → `f_vco = 12.288 × 3125 = 38.4 GHz`，
**远超 VCO 上限 1200 MHz**（检查 1.11）。

> 这就是任务书里"VCO 1000 MHz 时 12.288 不能整除"的严格证明：
> 不是 1000 不行，而是**任何**整数 M/N/C 都不行。

### 4.2 连分数找最佳有理逼近

`0.24576` 的连分数是 `[0; 4, 14, 2, 26, ...]`（检查 1.12），收敛子：

| 收敛子 | 小数 | 对应频率 | 误差 | 可实现性 |
|---|---|---|---|---|
| 1/4 | 0.25 | 12.500 MHz | **+1.73 %** | M=1,N=1,C=4（VCO 50 MHz，低于 VCO 下限） |
| 14/57 | 0.245614 | 12.2807 MHz | −0.06 % | 57 = 3×19，需要 C=57 或 N=3,C=19 |
| **29/118** | **0.245763** | **12.288136 MHz** | **+0.0011 %（+11 ppm）** | **N=2, M=29, C=59** ✔ |
| 90/366 | … | 12.295 MHz | +0.06 % | 不如 29/118 |

`29/118 = 29/(2×59)`，取 **REFCLK_DIV=2、FBCLK_DIV=29、CLKC0_DIV=59**：

```
f_vco = 50 × 29 / 2 = 725 MHz          （300..1200 MHz 合法，检查 1.02）
f_out = 725 / 59     = 12.288136 MHz   （+11 ppm，检查 1.03/1.04）
PFD   = 50 / 2       = 25 MHz
fs    = 12.288136/256 = 48.00053 kHz   （+11 ppm，检查 1.07）
BCLK  = 12.288136/4   = 3.072034 MHz   （= 64 × fs）
LRCK  = 3.072034/64   = 48.00053 kHz
```

+11 ppm 比 50 MHz 晶振本身的 ±50 ppm 还小 4 倍，所以"1 kHz 测试音"的实测频率是
**1000.011 Hz**（模型 7.07），人耳完全不可分辨。

### 4.3 被否掉的方案（写下来避免重复试）

| 方案 | 结果 | 否掉的原因 |
|---|---|---|
| VCO 1000 MHz + C=81 | 12.3457 MHz（+0.47 %） | 频率误差 8 音分；**但作为退路保留**（见 M4-R1） |
| VCO 1000 + 两个输出"组合" | — | PLL 输出之间没有相位/频率合成器，无法凑出 12.288 |
| 24.576 MHz 再 2 分频 | 24.576 同样 = 3072/125，`3125 | D` 无解 | 与 12.288 同一数学障碍；且 ÷2 会引入额外抖动 |
| 逻辑分频（100 MHz + 小数分频器） | 平均 12.288，但瞬时抖动 ±40 ns | 音频 MCLK 抖动直接恶化 DAC，比 0.47 % 频差糟糕得多 |
| 25.175 MHz 式"凑 CEA" | — | 与本任务无关 |

### 4.4 环路滤波参数（唯一没有工具背书的地方）

TD 的 IP 生成器会按 (FIN, VCO, PFD, 带宽档) 算 `GMC_GAIN/ICP_CURRENT/KVCO/LPF_CAPACITOR/LPF_RESISTOR`，
本工程没有 GUI 可用（M0 §7.1），因此**照抄同器件、同为 "Medium" 档的 `Sdram_PLL.v`
（VCO 1000 / PFD 50）**：

```verilog
.GMC_GAIN(4), .ICP_CURRENT(13), .KVCO(4), .LPF_CAPACITOR(1), .LPF_RESISTOR(4)
```

本设计 VCO 725 / PFD 25 都是它的一半左右，环路带宽随之下降（锁定更慢、更稳，保守方向）。
**这是 M4 唯一的"未经验证"的模拟参数**，退路见 §10 M4-R1。

### 4.5 SDC 怎么约束这个"非整数"时钟

`timing.sdc` 新增：

```tcl
# 12.288136 MHz = 50/4.069，整数分频写不出来；用 -divide_by 4 声明为 12.5 MHz
# （比真实 12.288 MHz 严 1.7 %，方向安全），只为给该域一个真实时钟对象
create_generated_clock -name mclk_audio \
    -source [get_ports {clk}] -divide_by 4 \
    [get_pins {u_pll_audio/pll_inst.clkc[0]}]

set_clock_groups -exclusive \
    -group [get_clocks {clk_50m}]  -group [get_clocks {pixel_clk}] \
    -group [get_clocks {serial_clk}] -group [get_clocks {sdram_clk}] \
    -group [get_clocks {mclk_audio}]
```

为什么不能写 `create_clock -period 81.379`：PLL 在本工程里是普通 Verilog 文件，TD 不认为
它是时钟源，会在 PLL 输出上报 `USR-8194: primary clock ... is on the network of clock
clk_50m`（M0 §5.2 已踩过）；`create_generated_clock` 才是正确构造，而它要求整数倍/分频。
`-divide_by 4` 让 STA 按 80 ns 分析（真实 81.379 ns），**只会更严，不会漏违例**。

---

## 5. I2C 初始化

### 5.1 协议要点（数据手册 p63）

> "A control word consists of 16 bits. The first 7 bits (B15 to B9) are address bits …
> The remaining 9 bits (B8 to B0) are data bits." / "The device address is 0011010 (0x34h)."

所以一帧写是 **4 个字节**：

```
START | 0x34 (7bit addr + W=0) | ACK | {reg[6:0], data[8]} | ACK | data[7:0] | ACK | STOP
         ↑ 器件地址                   ↑ 寄存器地址 + 数据最高位        ↑ 数据低 8 位
```

三个必须记住的推论：
1. **器件写地址是 0x34**，不是厂商代码里的 0x20（0x20 是 ES8388 的）；
2. **数据是 9 bit**，两字节发送，`data[8]` 藏在第一个数据字节的最低位；
3. WM8960 的控制口"operates as a slave device only"——I2C 上它永远是从机；
   I2S 的主/从是另一回事（R7 bit6 MS）。

### 5.2 三层结构（复用厂商框架，但把数据宽度改对）

| 层 | M4 模块 | 对应厂商文件 | 关键改动 |
|---|---|---|---|
| 位级 | `m4_i2s_bit_shift.v` | `i2s_bit_shift.v` | 4 相位/SCL 周期不变；SDA 拆成 `oe/o/i`；ACK 位中间采样并输出 `O_nack`；总线空闲态 = SCL=1/SDA 释放 |
| 字节级 | `m4_i2s_control.v` | `i2s_control.v` | **一帧 3 字节（dev + {reg,data8} + data7:0）**；每字节查 ACK，NACK 立即 STOP 收尾；`I_dev` 做成端口（默认 0x34） |
| 表级 | `m4_i2s_init_dev.v` | `i2s_init_dev.v` | 表从 40 条改成 13 条带延时列的表；**NACK 重试上限 3 次**（厂商是原地死等）；上电延时 10 ms（厂商 1.2 ms）；输出 `O_ok/O_nack_err/O_index` |

厂商代码的**两个致命 bug**（这也是"板测例程音频到底能不能响"的答案）：

| # | 厂商写法 | 后果 |
|---|---|---|
| 1 | `dev_id = 8'h20` | 总线上没有 0x20 这个器件 → **全部 NACK**，一条都写不进去 |
| 2 | `addr_mode=0` 时 `cnt` 从 1 直接跳到 3（跳过 cnt=2） | 只发 **1 个数据字节**，而 WM8960 要 2 个 → 控制字不完整、被丢弃 |

> 模型 §3 用从机模型量化了第 2 条的后果：即使地址改对，厂商的 40 条也会因为
> "少一个字节"而被 codec 解析成 `寄存器 = 原地址>>1`、`数据 = (原地址&1)<<8 | 原数据`，
> 于是 40 条全部落到 **R0..R24** 上，`R25/R26/R34/R37/R47`（电源与混音器）**一次都没写到**
> → 即使 I2C 通了也是**绝对静音**（检查 3.05~3.08）。

### 5.3 位时序（40.06 kHz）

```
分频：DIV = 50e6/(40e3×4) = 312
      SCL 周期 = 4 × 312 × 20 ns = 24.96 µs  →  40.06 kHz
      一个字节 = 9 个 SCL 周期 = 224.6 µs
      一条寄存器 = 3 字节 = 673.9 µs   （模型 4.15）
      13 条 + 延时 = 551.3 ms          （模型 4.14）

每个 SCL 周期的 4 个相位（同一个 50 MHz 时钟）：
        ┌── ph0 ──┬── ph1 ──┬── ph2 ──┬── ph3 ──┐
SCL  ───┘         └─────────┘         └─────────
        低            高          高          低
SDA     ◀ 数据在此改变 ▶ ◀ 从机采样 ▶ ◀ 主机采 ACK ▶
```

一个完整写帧（`reg=0x07, data=0x002`，即 I2S/16bit/从机）的位流：

```
        START   dev=0x34          ACK  b1=0x0E   ACK  b2=0x02   ACK  STOP
SCL  ‾‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__ ... __/‾‾‾‾‾
SDA  ‾‾‾\_______________________________________________________/‾‾‾‾‾‾‾
        │0 0110100│0│  0 0001110  │0│ 0000 0010  │0│
        └─ addr ──┘W └ reg=0x07,d8=0┘ └ data[7:0] ┘
```

> 位序：每字节 MSB 先；`b1 = {reg[6:0], data[8]}`。例：`reg=0x07, data=0x002` →
> `b1 = 0x0E`（0x07<<1 | 0），`b2 = 0x02`；`reg=0x1A, data=0x1E0` → `b1 = 0x35`（0x1A<<1|1）、`b2 = 0xE0`。

### 5.4 寄存器表逐条（13 条，全部以数据手册为准）

表文件：`rtl/m4_wm8960_table.v`，格式 `{delay[2:0], reg[7:0], data[8:0]}`。
"页"指 WM8960 数据手册 Rev 4.2 的页码。

| # | 寄存器 | 值 | 位域解释 | 作用 / 依据 | 之后延时 |
|---:|---|---|---|---|---|
| 0 | **R15 (0Fh) Reset** | `0x000` | 写任意值复位全部寄存器 | 软复位，回到已知默认态（p67） | 1 ms |
| 1 | **R4 (04h) Clocking(1)** | `0x000` | `CLKSEL=0`(SYSCLK←MCLK) `SYSCLKDIV=00`(÷1) `DACDIV=000`(÷256) `ADCDIV=000`(÷256) | **MCLK/fs 分频在这里**：fs = 12.288136M/256 = 48.0005 kHz（p57 + Table 40 p58） | – |
| 2 | **R7 (07h) Audio Interface** | `0x002` | `FORMAT=10`(I2S) `WL=00`(16bit) `LRP=0`(低=左) `MS=0`(**从机**) `BCLKINV=0` `DLRSWAP=0` `ALRSWAP=0` | **主从与格式**：FPGA 做 I2S 主机，codec 必须是从机（p52） | – |
| 3 | **R10 (0Ah) LDAC volume** | `0x0FF` | `DACVU=0` `LDACVOL=0xFF` | 左 DAC 数字音量 0 dB（p67） | – |
| 4 | **R11 (0Bh) RDAC volume** | `0x0FF` | 同上 | 右 DAC 数字音量 0 dB | – |
| 5 | **R34 (22h) LOUTMIX** | `0x100` | `LD2LO=1` `LI2LO=0` `LI2LOVOL=000` | **左 DAC → 左输出混音器**；关掉默认打开的 Line-In 通路（p67，默认 0x050 只通 Line-In） | – |
| 6 | **R37 (25h) ROUTMIX** | `0x100` | `RD2RO=1` `RI2RO=0` | 右 DAC → 右输出混音器 | – |
| 7 | **R25 (19h) Power 1** | `0x0C0` | `VMIDSEL=01`(2×50k) `VREF=1` `AINL/AINR/ADCL/ADCR/MICB=0` `DIGENB=0`(MCLK 通) | **VREF + VMID 上电**（所有模拟块的基准）；ADC/MIC 不用就不开（p64） | **500 ms**（VMID 电容充电，pop-free） |
| 8 | **R26 (1Ah) Power 2** | `0x1E0` | `DACL=1 DACR=1 LOUT1=1 ROUT1=1`，`SPKL/SPKR/OUT3/PLL_EN=0` | **DAC + 左右耳机输出缓冲器上电**；D 类功放与 PLL 不用（p65） | 10 ms |
| 9 | **R47 (2Fh) Power 3** | `0x00C` | `LOMIX=1 ROMIX=1` `LMIC/RMIC=0` | 输出混音器上电（p65） | 10 ms |
| 10 | **R5 (05h) ADC&DAC ctrl** | `0x000` | `DACMU=0`(**解除静音**) `DEEMPH=00` `ADCHPD=0` `DACDIV2=0` | **DAC 解除静音**（默认 0x008 是静音！）（p67） | 10 ms |
| 11 | **R2 (02h) LOUT1** | `0x079` | `OUT1VU=0` `LO1ZC=0` `LOUT1VOL=0x79` | 左耳机 **0 dB**（0x00=−73 dB，0x7F=+6 dB）（p67） | – |
| 12 | **R3 (03h) ROUT1** | `0x079` | 同上 | 右耳机 0 dB | – |

顺序不是随便排的（模型 2.37~2.41 逐条检查）：
**复位 → 时钟/格式 → 数字音量 → 混音路由 → VREF/VMID(等 500 ms) → 输出缓冲(等 10 ms)
→ 混音器上电(等 10 ms) → 解除静音(等 10 ms) → 最后才把耳机音量从 −73 dB 抬到 0 dB**。
这样上电过程中耳机里始终是安静的，不会"砰"一下。

**为什么音量放最后**：R2/R3 复位默认是 `0x000`（−73 dB），先写 0x079 就意味着
"输出缓冲还没上电就把音量开到 0 dB"，缓冲器上电瞬间会有一个阶跃 → 听得见的 pop。
放最后 + 前面 30 ms 的逐级上电，可以让 pop 降到几乎听不见。

### 5.5 与厂商 40 条表的逐项对照（"逐条复核"结论）

| 厂商条目 / 注释 | 问题 | M4 处理 |
|---|---|---|
| `dev_id = 8'h20`（注释"WM8960 器件地址"） | 0x20 是 ES8388 的地址；WM8960 是 0x34（p63） | 改成 `parameter DEV_ADDR = 8'h34` |
| 全部 40 条只发 1 个数据字节 | 控制字不完整 → 全部无效（模型 3.05） | 3 字节帧（§5.1） |
| 缺 R7 | 接口格式从未配置（靠默认 0x00A = I2S **24 bit**） | 显式写 `R7=0x002`（I2S/16bit/从机） |
| `R8 = 0x84` 注释"主模式，bit7=1" | R8 没有主从位（那是 R7 bit6）；`BCLKDIV` 只在主机模式有效 | **不写 R8**（保持默认 0x1C0），主从在 R7 里设 |
| `R13 = 0x00` 注释"MCLK 与频率比率" | **R13 是 Reserved**（p67）；MCLK/fs 在 R4 | 不写 R13；改在 R4 里设 `DACDIV/ADCDIV=÷256` |
| `R12 = 0x0C` 注释"ADC Control I2S 16bit" | R12 也是 Reserved（ADC 格式在 R9/R7） | 不写 |
| 缺 R25/R26/R47 | VREF/VMID/DAC/输出缓冲/混音器全部没上电 | 新增 3 条（含 500 ms 等 VMID） |
| 缺 R34/R37 | 默认只把 **Line-In** 接到混音器，DAC 根本没接进去 | 新增 2 条 `0x100` |
| 缺"解除静音"的 R5 | R5 默认 `0x008` = **DACMU=1 静音** | 新增 `R5=0x000` |
| `R2 = 0x00F3`、`R3 = 0x00F0` 两次 | 值本身也不对（0xF3 的 bit7 是 ZC 位，音量 0x73），而且顺序在最前 | 改为最后写 `0x079`（0 dB） |
| 表里 `0x2E..0x31` 各写两遍 | 冗余 | 去掉 |
| 无任何延时（40 条连写 ≈ 10 ms） | VMID 没时间充电，输出级上电会 pop/无声 | 加 delay 列（1/10/100/500 ms） |
| 注释基于 MCLK=8.192 MHz / fs=16 kHz | 与实际 12.288 MHz/48 kHz 不符（example-arch §5.2 已指出） | 全部按 12.288 MHz/256 重算 |

> 逐条复核后，**13 条**替代了原来的 40 条：删掉的都是"重复、写保留寄存器、写错位"的条目，
> 增加的是真正让 DAC 出声必须的电源/混音/静音条目。

### 5.6 失败处理（"初始化失败就静音"）

```
每字节 → O_nack（ACK 位中间采样 SDA）
  ├ 第 1/2 字节 NACK：立刻发 STOP 释放总线，本次写失败
  ├ 第 3 字节 NACK：同上，O_nack=1
  └ 同一寄存器失败 → 重试，最多 3 次（共 4 次尝试，模型 5.04）
         └ 仍失败 → O_ok = 0，整个初始化中止（不再继续后面的寄存器）
O_ok=0 → S_tone_en=0 → DACDAT 恒 0（静音），且 I2S 时钟照常输出
```

模型 §5 用"codec 不存在"的场景验证：0 条写入、3 次重试、1.27 ms 内放弃、总线释放、
`O_ok=0`（→ 静音）。上板时如果 I2C 有胶着，宁可无声也不会是噪声。

---

## 6. I2S 发送（`rtl/m4_i2s_tx.v`）

### 6.1 时钟关系

```
MCLK = 12.288136 MHz
BCLK = MCLK / 4      = 3.072034 MHz      （4 个 MCLK 一个 BCLK 周期，50 % 占空比）
LRCK = BCLK / 64     = 48.0005 kHz       （64 个 BCLK 一帧）
```

`S_mcnt[1:0]` 自由计数：`mcnt==0` 时 BCLK 拉低（**下降沿，同时更新数据与 LRCK**），
`mcnt==2` 时拉高。因为全部由 MCLK 同步产生，三者严格整数关系、无毛刺。

### 6.2 帧格式（slot 0..63，LRCK 低 = 左声道）

```
slot :  0   1   2  ...  16   17  ...  31 |  32   33  ...  48   49  ...  63
LRCK : ‾‾‾‾\___________________________________________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
            ←──────────── 左声道 (LRCK=0) ────────────→ ←──── 右声道 (LRCK=1) ────→
DACDAT:  0  b15 b14 ... b0    0   0 ...  0            0   b15 ...  b0    0  ...  0
          ↑   ↑                                        ↑    ↑
          │   └ MSB 在 LRCK 翻转后第 2 个上升沿被采样    │    └ 右声道 MSB
          └ 1 个 BCLK 的固定延迟（I2S 定义）             └ 右声道同样延迟 1 BCLK
```

文字版时序（一个左声道槽的头几位）：

```
BCLK  ‾‾‾‾\____/‾‾‾‾\____/‾‾‾‾\____/‾‾‾‾\____
          ↑         ↑         ↑         ↑
        上升沿1    上升沿2    上升沿3    上升沿4      ← codec 在上升沿采样
LRCK  ‾‾‾‾\____________________________________
          │
DACDAT ‾‾‾‾‾‾‾‾‾‾‾‾‾\_____/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
          保持上一个 LSB  │ b15 │ b14 │ b13 ...
                         └ 在下降沿换数据（半周期 162 ns 的建立/保持余量）
```

### 6.3 为什么"16 bit 数据放在 64 BCLK 帧（32 bit 槽）"是安全的

- 数据手册 p49：I2S 模式下"MSB is available on the second rising edge of BCLK following a
  LRCLK transition"，且"Depending on word length, BCLK frequency and sample rate, there may be
  unused BCLK cycles between the LSB of one sample and the MSB of the next"——**允许槽比字长**；
- codec 被配置成 16 bit（R7 `WL=00`），它只取每声道的前 16 个数据位，后面 16 个 BCLK 被忽略；
- 我们的 16 bit 数据是**左对齐**（紧跟 1 BCLK 延迟），所以 24 bit 模式（R7 默认）下也能正确
  解析成同样的相对幅度——这给"万一 R7 没写进去"留了一条活路。

### 6.4 波形检查（模型 §6，逐 MCLK 周期）

| 检查 | 结果 |
|---|---|
| BCLK 周期 = 4 MCLK、占空比 50 % | PASS（6.01/6.02） |
| LRCK 半周期 = 32 BCLK、整周期 = 64 BCLK | PASS（6.03/6.04） |
| LRCK 低 = 左声道 | PASS（6.05 + 6.07） |
| DACDAT **只在 BCLK 下降沿**变化 | PASS（6.06，0 次违例） |
| LRCK 翻转后第 1 个上升沿为 0、第 2 个为 MSB | PASS（6.11/6.12） |
| 16 个数据位还原 = 发送值（含 0x8001 全 1/全 0 边界） | PASS（6.13） |
| 第 17 个上升沿是 0 填充、每槽 32 BCLK | PASS（6.14/6.15） |
| 用"只看上升沿"的接收模型还原 L/R 样点 | PASS（6.07~6.10，L==R） |
| `I_en=0` 时 DACDAT 恒 0（静音） | PASS（6.16） |

---

## 7. 测试音（`rtl/m4_sine_tone.v` + `rtl/m4_sine_rom.v`）

### 7.1 结构

```
I_tick (每帧 1 个 MCLK 脉冲, 48 kHz)
   │
   ▼
S_phase += 89478485            (32 bit, PHASE_INC = round(2^32 × 1000/48000))
   │
   ├─ idx  = phase[31:22]      (1024 点/周期 → 1 kHz 时 48 点/周期)
   ├─ quad = idx[9:8]          (象限)
   ├─ a    = idx[8] ? ~idx[7:0] : idx[7:0]     (象限内镜像 → 1/4 波表)
   ├─ mag  = rom[a]            (0..16384, 1 个 BRAM9K, 同步读 1 拍)
   └─ s    = quad[1] ? -mag : mag              (二补数取反 +1)
```

- 1024 点/周期只需 **256×16 bit = 4 Kbit**（1 个 BRAM9K），比全波表省一半；
- `I_tick` 由 I2S 发送器在 slot 0 给出，两个声道锁存**同一个样点**（单声道测试音）；
- 复位时 `phase=0`，表首值是 sin(0.176°)=50 LSB，所以**第一个样点就在过零点**，
  DACDAT 没有直流阶跃 → 起播无 click（模型 7.12：首样点 50，相邻最大跳变 2205 = 理论值 2·A·sin(π/48)）。

### 7.2 指标（模型 §7）

| 指标 | 设计值 | 实测（模型） |
|---|---|---|
| 频率 | 1 kHz | **1000.0111 Hz**（+11 ppm，来自 MCLK） |
| 采样率 | 48 kHz | 48.00053 kHz |
| 幅度 | −6.02 dBFS | 峰值 **16384**（= 满幅一半），RMS −9.03 dBFS |
| 直流 | 0 | 均值 0.00 LSB |
| 削顶 | 无 | 最大 \|s\| = 16384 |
| THD+N | — | **−55.6 dB**（受 1024 点相位表限制） |
| 每周期样点 | 48 | 47.99 |
| 静音（`I_en=0`） | 全 0 | 全 0 |

> THD 的 −55.6 dB 不是正弦表精度问题（表本身 ≤1 LSB 误差，检查 7.05），而是
> **相位量化到 1/1024 周期**（0.35°）造成的——16384 × 0.0031 rad ≈ 50 LSB 的相位误差。
> 若要更好：把表加到 512 项/象限（8 Kbit，仍 1 个 BRAM9K）可到约 −61 dB，
> 但 −55 dB 对"测试音"已经绰绰有余（比耳机/扬声器的失真低一个量级）。

---

## 8. 资源与时序

### 8.1 资源（post-route，`phy_1/m4_audio_phy.area`）

| 资源 | 用量 | 总量 | 占比 | M3 时 | 差值 |
|---|---:|---:|---:|---:|---:|
| LUT（`#lut`） | **5 101** | 19 600 | **26.03 %** | 4 695 | **+406** |
| 逻辑单元 LE | 6 279 | — | — | 5 747 | +532 |
| 寄存器 FF（`#reg`） | **4 444** | 19 600 | **22.67 %** | 4 218 | **+226** |
| BRAM（bram9k 17 + fifo9k 8） | **18** | 64 | **28.12 %** | 17 | **+1**（正弦表） |
| BRAM32K | 0 | 16 | 0 % | 0 | 0 |
| DSP | 0 | 29 | 0 % | 0 | 0 |
| **PLL** | **3** | 4 | **75.00 %** | 2 | **+1** |
| GCLK | **7** | 16 | 43.75 % | 6 | **+1**（MCLK 走全局时钟网） |
| PAD / IO | 30 / **26** | 188 | 15.96 % / 13.83 % | 23 / 19 | **+7** |

新增模块的层次（le / lut / ff / bram）：

| 模块 | LE | LUT | FF | BRAM | 说明 |
|---|---:|---:|---:|---:|---|
| `u_i2c_init`（`m4_i2s_init_dev`） | 277 | 240 | 151 | 0 | 表 + 重试 + 延时 |
| └ `u_ctrl`（`m4_i2s_control`） | 112 | 102 | 71 | 0 | 3 字节帧 |
| └ └ `u_bit`（`m4_i2s_bit_shift`） | 68 | 58 | 34 | 0 | 位级 + 312 分频 |
| `u_tone`（`m4_sine_tone`） | 74 | 38 | 49 | **1** | 相位累加器 + 镜像 |
| └ `u_rom`（`m4_sine_rom`） | 0 | 0 | 0 | **1** | 256×16 推断成 BRAM（0 LUT） |
| `u_i2s_tx`（`m4_i2s_tx`） | 38 | 30 | 27 | 0 | BCLK/LRCK/移位 |
| `u_pll_audio` | 0 | 0 | 0 | 0 | 硬核 |
| **音频合计** | **389** | **308** | **227** | **1** | 约占 M4 增量的一半（其余是既有逻辑的布局抖动，与 M3 报告的 ± 现象一致） |

### 8.2 时序（`phy_1/final_timing.rpt`，final / routed，Slow+Fast 角）

```
Setup : WNS +111 ps   TNS 0 ps   NUM_FEPS 0
Hold  : WNS   +3 ps   TNS 0 ps   NUM_FEPS 0
```

| 时钟 | 约束周期 | 时钟表 fanout | SWNS | HWNS | 实测最短周期 / Fmax |
|---|---:|---:|---:|---:|---|
| `sdram_clk` 100 MHz | 10.000 ns | 1 721 | **+0.111 ns** | +0.154 ns | 9.889 ns / 101.12 MHz |
| `pixel_clk` 25 MHz | 40.000 ns | 879 | +30.791 ns | +0.003 ns | 9.209 ns / 108.59 MHz |
| `clk_50m` 50 MHz | 20.000 ns | 135 | +12.277 ns | +0.239 ns | 7.723 ns / 129.48 MHz |
| **`mclk_audio`** 12.5 MHz（声明值） | 80.000 ns | **52** | **+73.543 ns** | +0.223 ns | 6.457 ns / 154.87 MHz |
| `serial_clk` 125 MHz | 8.000 ns | 38 | +3.584 ns | +0.239 ns | 4.416 ns / 226.45 MHz |

- **5 个域内 path group，没有跨域 path group**（`CC-From/CC-To` 全为 `no`）——
  M4 唯一的跨域信号 `init_ok` 被 2FF 正确"圈"在各自域内；
- 全局 WNS 仍是 100 MHz 域 `u_fat` 内部的 FAT32 结构读出 → 地址 mux 路径
  （本次 `u_fat/S_app_reg[0] → u_fat/ramread0_syn_276[3]`，数据路径 9.609 ns、net 占 89 %）
  ——**与 M3 同一批路径**（M3-R7：同一份 RTL 多次编译在 0.11…0.74 ns 之间跳，本次 0.111 ns）；
- **`mclk_audio` 域余量 +73.5 ns（92 %）**：音频逻辑（12 MHz 的计数器/移位/ROM）
  对时序毫无压力，不是关键路径；
- Hold 从 M3 的 +14 ps 变成 +3 ps（同批路径，属该流程常态，0 违例）。

### 8.3 编译与可复现性

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\fpga-2026\dsh_code\proj\m4_audio\build.ps1
```

| 项 | 结果 |
|---|---|
| 全清编译 wall | **81.1 / 89.6 s**（最终 RTL 两次；syn ≈ 20 s + phy place 17 s + route 45~52 s + bitgen ≈ 1 s） |
| 退出码 / 日志 | 0 / `TD_FLOW_OK` |
| bit | 630 799 B，`Design name: m4_top`、`Architecture: eagle_s20`、`Package: EG4S20BG256` |
| `Bitstream CRC` | `10000111101000001100101000000010` |
| `PLL setting string` | **`1011`**（3 个 PLL：bit0/1/3；M3 是 `0011`） |
| 可复现性 | 最终 RTL 的两次独立全清编译：payload **1218 行逐行一致**（SHA256 `27A1A8AA…5C4D44E7`），`Bitstream CRC` 相同，WNS 相同（+0.111 ns）；只有 `# Date:` 行不同（SHA256 每次都变，属正常） |
| 全清编译的定义 | 两个 run 目录清到只剩 `settings.cfg` + `m4_audio.prj` |

日志（`phy_1/console_ci.log`）：

```
BIT-1003 : Generate bitstream completely, there are 199875 bits set as '1'.
BIT-1004 : PLL setting string = 1011
BIT-1004 : Generate bits file m4_audio.bit.
TD_FLOW_OK
```

新增逻辑的编译告警：**0 条 ERROR**；`m4_*.v` 只有一条
`HDL-5314 WARNING: net 'S_rom' does not have a driver in m4_sine_rom.v(19)` ——
这是"整张表只在 `initial` 里赋值"的常规告警，厂商 `ov5640_init_table_jpeg.v` 是同样写法
且综合成 2 个 BRAM；本次 area 报告里 `u_rom` 也是 **0 LUT + 1 BRAM**，说明表被推断成
带初值的 BRAM（TD 的 `default_reg_initial = auto`）。见风险 M4-R3。

---

## 9. 离线验证：`sim/model_m4_audio.py`（146 项全 PASS）

本机没有 Verilog 仿真器（m2-report §10），沿用 M1/M2/M3 的做法：**把 RTL 逐句照抄成
Python，用定向场景跑**。M4 的模型分 4 个部分：

1. **I2C 位级引擎**：`BitEngine` 严格照 `m4_i2s_bit_shift.v` 的 4 相位/9 位状态机，
   每个相位 = 312 个 50 MHz 周期（与 RTL 的分频器完全一致，所以 SCL 频率/帧长/总时间是
   算出来的，不是估的）；
2. **WM8960 从机模型**：**只从 SCL/SDA 的位流解码**（上升沿移位、START/STOP 检测、
   第 9 拍拉低 ACK、STOP 时提交 `{reg,data8}`+`data7:0`）——所以"帧格式错"会被从机
   发现，而不是被测试脚本放过（厂商的 40 条就是这样被判定"全部无效"的）；
3. **I2S 发送器**：逐 MCLK 周期（12.288 MHz）产生 BCLK/LRCK/DACDAT，再用一个
   **只看上升沿**的接收模型还原样点（模拟 WM8960 的采样行为）；
4. **正弦**：直接从 `rtl/m4_sine_rom.v` 解析表（Verilog 与模型不可能漂移），
   逐样点跑相位累加器，做过零点计数、最小二乘拟合、THD+N。

| 组 | 覆盖内容 | 项数 |
|---|---|---:|
| 1 | PLL/时钟：VCO 725、VCO 区间、+11 ppm、BCLK/LRCK、64 BCLK/帧、3125 互素证明、连分数、29/118 误差 | 13 |
| 2 | 寄存器表位域：R4/R7/R5/R25/R26/R47/R34/R37/R2/R3/R10/R11 逐位解码 + 上电顺序 4 条 + 表长/地址/保留寄存器 | 42 |
| 3 | 厂商表缺陷：地址 0x20、帧短一字节、落到 reg>>1、R25/R26/R34/R37/R47 从未写、R7 从未写、意外的 R4=0x084（24 kHz）、R8 假主模式、保留寄存器、重复条目 | 19 |
| 4 | I2C 位流：0x34 地址、13 帧全部选中、13 条写入与表逐条相同、0 个畸形帧、ok=1、无重试、总线释放、初始化不重来、10 ms 上电延时、551.3 ms 总时长、673.9 µs/条 | 22 |
| 5 | 失败路径：无 ACK 时 0 写入、ok=0、3 次重试、1.27 ms 放弃、总线释放、静音 | 8 |
| 6 | I2S 波形：BCLK 周期/占空比、LRCK 64 BCLK、极性、只在下降沿换数据、MSB 位置、16 位还原、填充位、L/R 一致、静音 | 16 |
| 7 | 正弦：表 256 项/单调/≤1 LSB、PHASE_INC、1000.011 Hz、−6.02 dBFS、无削顶、零均值、无 click、过零点、拟合幅度、THD+N、48 样点/周期 | 18 |
| 8 | 引脚一致性：7 个音频脚与 `hw-facts.md` §7 逐条对齐、26 个 IO、无重复引脚 | 9 |
| | **合计** | **146** |

运行：

```powershell
python E:\fpga-2026\dsh_code\proj\m4_audio\sim\model_m4_audio.py       # 只打印失败项
python E:\fpga-2026\dsh_code\proj\m4_audio\sim\model_m4_audio.py -v    # 打印全部 146 项
python E:\fpga-2026\dsh_code\proj\m4_audio\sim\gen_sine_rom.py --check # 正弦表一致性
```

> **模型抓到的两个真 bug**（都是先写 RTL、跑模型才发现）：
> ① `m4_i2s_control` 把 `DEV_ADDR=0x34` 又左移了一位（发成 0x68）→ 从机永不选中；
> ② 模型自己的接收端忘了 I2S 的"1 BCLK 延迟"，导致还原样点整体右移 1 位（0x1234→0x091A）。
> 第二个虽然是模型的问题，但正好证明"只看上升沿"的接收模型是真的在按 I2S 协议解码。

M3 的 75 项交互模型（`sim/model_m4_ctrl.py`）与 M2 的 80 项 FAT32 模型
（`sim/model_fat32_bmp.py`）原样保留且仍然适用——M4 没有改 `m4_video_src/m4_seg7/
m4_hc595/m4_fat_bmp` 的任何逻辑。

---

## 10. 上板验证清单

> 前提：`m4_audio.bit` 用 TD Board Debugger / `bw.exe` 经 JTAG 下载；
> TF 卡是 FAT32、根目录有 `IMG0001.BMP`…（M3 的显示功能应照旧工作）。

### 10.1 期望现象（按顺序）

| # | 操作 | 预期 |
|---|---|---|
| 1 | 插耳机（绿色 3.5 mm），上电/按 KEY2 | ≈0.55 s 后耳机里出现**稳定的 1 kHz 纯音**（像"嘀——"，音量中等，不刺耳） |
| 2 | 同时看 HDMI | M3 的画面/轮播照旧（音频不影响显示） |
| 3 | 数码管 | 与 M3 完全一致（总数 + 图号） |
| 4 | 拔掉耳机再插 | 声音应恢复（无耳机检测电路，模拟输出一直开着） |
| 5 | `DEBUG_LED=1` 重编译后看 led[3] | **常亮 = I2C 13 条全部 ACK**；灭 = 没通（见 10.3） |

### 10.2 听不到时的排查顺序（**严格按此顺序，每步都有判据**）

```
① I2C 有没有 ACK  →  ② MCLK 有没有 12.288 MHz  →  ③ 寄存器表里 DAC/耳机是否使能
                   →  ④ 音量值  →  ⑤ 数字侧波形（BCLK/LRCK/DACDAT）  →  ⑥ 模拟侧（耳机座/功放）
```

**① I2C 有无 ACK**（示波器，双通道，SCL=L16、SDA=M16，触发 SCL 下降沿，时基 5 ms/div）

- 上电后应看到**一串约 8.8 ms 的突发**（13 条 × 3 字节 × 9 拍 = 351 个 SCL 脉冲）。
  13 条之间还有 1 ms / 500 ms / 10 ms 的间隔，所以整体跨度约 0.55 s；把时基放到
  100 ms/div 才能看全，先抓"有没有突发"再放大看细节。
- 每个字节第 9 拍（ACK）**SDA 必须被从机拉低**。判断方法：把时基放到 5 µs/div，
  数第 9 个 SCL 高电平期间 SDA 是否为低。
- 现象 → 结论：
  - SCL 完全不动 → 音频 PLL 没锁（`S_rst_n_audio` 一直有效），或 KEY2 没释放；
  - SCL 有波形但 SDA 一直高（无 ACK）→ 地址/接线/供电问题。先确认发的是 **0x34**
    （第 1 个字节 = 0011 0100 + W=0），再看 WM8960 的 AVDD/DBVDD/DCVDD 是否 3.3 V；
  - SDA 一直被拉低不放 → 总线上别的器件（24LC256/PCF8563）在拉，或 SDA 与 GND 短路。

**② MCLK 有没有 12.288 MHz**（示波器/频率计，探头 B8）

- 应为 **12.288 MHz、0→3.3 V 方波、约 50 % 占空比**（万用表直流档量约 **1.65 V**，
  这是"有 clock"的最快判据；0 V 或 3.3 V 都说明没时钟）。
- 没有 → 音频 PLL 没锁。用 ChipWatcher 看 `u_pll_audio/pll_inst.extlock`
  （或把 `DEBUG_LED` 扩成看 `S_audio_lock`）。此时按 **M4-R1** 换成退路参数重编译（85 s）。

**③ 寄存器表里 DAC/耳机是否使能**

- 本设计**不支持 I2C 读回**（只写），所以用"逻辑分析仪/USB-I2C 解码写序列"或
  ChipWatcher 看 `u_i2c_init/S_idx` 停在 12（= 13 条写完）且 `O_ok=1`。
- 若 `O_ok=0` 且 `S_idx` 停在某个值 n，说明第 n 条（0 起）失败——按 §5.4 的表查是哪个寄存器。
- 最常被漏掉的三条：`R25=0x0C0`（VREF/VMID）、`R26=0x1E0`（DAC+耳机缓冲）、`R5=0x000`（解除静音）。

**④ 音量值**

- `R2/R3 = 0x079`（0 dB）。若上板发现声音太大/太小，改表里最后两条：
  `0x060`≈−25 dB、`0x040`≈−57 dB（每减 1 ≈ −1 dB，0x00 = −73 dB）。

**⑤ 数字侧波形**（示波器，探头 C8/A8/A7，触发 LRCK 上升沿）

- BCLK **3.072 MHz**（0.2 µs/div 能看到方波，周期 325 ns）；
- LRCK **48 kHz**（20 µs/div），低电平 10.4 µs、高电平 10.4 µs；
- DACDAT 在 LRCK 翻转后**第 1 个 BCLK 为 0、第 2 个才是 MSB**；数据随 1 kHz 正弦变化
  （用 200 µs/div 看 DACDAT 的"疏密"包络，周期 1 ms）；
- 三个都没有 → 音频 PLL 没锁或 `m4_i2s_tx` 没复位释放；只有 BCLK 没有 LRCK → 检查 A8 是否被
  别的功能占用（本工程没有）。

**⑥ 模拟侧**

- 耳机座是**绿色**那个（蓝色是 Line-In）；确认耳机本身好的（插手机试）。
- 若 ①~⑤ 全对还没声：本设计假设耳机座接 **LOUT1/ROUT1**（WM8960 的 HP 输出）。
  若该板把 3.5 mm 座接到 **LOUT2/ROUT2**，在表里加两条 `R40=0x079`、`R41=0x079`
  重编译即可（这两个寄存器默认 0x050 ≈ −33 dB，且默认没有从 DAC 混音过去，见 M4-R2）。
- 仍有微弱"沙沙"而非 1 kHz → 说明 I2S 数据没对齐（检查 R7 是否真的是 0x002，
  以及 `BCLKINV/LRP` 是否被意外写坏）。

### 10.3 建议的 ChipWatcher 观察点

`u_pll_audio/pll_inst.extlock`、`S_audio_lock`、`u_i2c_init/S_st[2:0]`、`u_i2c_init/S_idx[4:0]`、
`u_i2c_init/S_retry[1:0]`、`u_i2c_init/O_ok`、`u_i2c_init/O_nack_err`、
`u_i2s_tx/S_slot[5:0]`、`u_i2s_tx/S_mcnt[1:0]`、`u_tone/S_phase[31:22]`、
`u_tone/O_sample[15:0]`、`S_ok_sync[1]`。

### 10.4 万用表能做什么、不能做什么

| 量什么 | 能判断 | 读数 |
|---|---|---|
| B8（MCLK）直流平均 | 有没有时钟 | 有 ≈ **1.65 V**；没有 = 0 V 或 3.3 V |
| C8（BCLK）直流平均 | 有没有 BCLK | ≈ 1.65 V |
| A8（LRCK）直流平均 | 有没有 LRCK | ≈ 1.65 V（占空比 50 %） |
| L16/M16 空闲电平 | 总线是否释放 | **3.3 V**（上拉）；0 V = 被拉死 |
| A7（DACDAT）直流平均 | **几乎无用**（数据是随机样点，平均值≈1.65 V，静音时也是 0） | — |
| 耳机座对地电阻 | 判断耳机座是否接错 | 几十 Ω 到几百 Ω（直流） |

> 结论：**万用表只能确认"时钟有没有"，确认不了 I2S 对不对**；时序必须用示波器/逻辑分析仪。

---

## 11. 风险与假设

| # | 假设/风险 | 依据 | 一旦不成立的现象 | 应对 |
|---|---|---|---|---|
| **M4-R1** | 音频 PLL 的**环路滤波参数**是照抄同器件 VCO 1000/PFD 50 的配置（VCO 725/PFD 25 无工具背书） | §4.4 | `extlock` 不亮 → MCLK 没有 → 完全无声 | **一键退路**：`pll_m4_audio.v` 改 4 个数 `REFCLK_DIV(1) FBCLK_DIV(20) CLKC0_DIV(81) CLKC0_CPHASE(80)` → 12.3457 MHz（+0.47 %，音高 +8 音分，听不出），重新生成工程/编译 85 s。若仍不锁，再试 `FBCLK_DIV(29) REFCLK_DIV(1) CLKC0_DIV(118)`（VCO 1450 超上限，仅作排除法） |
| **M4-R2** | 板上 3.5 mm 耳机座接 **LOUT1/ROUT1**（HP_L/HP_R） | WM8960 参考设计惯例；`hw-facts.md` §7 只写了"绿色 = 耳机" | I2C 全通、MCLK/BCLK 都对，但耳机无声 | 表里加 `R40=0x079`、`R41=0x079`（LOUT2/ROUT2 通路），重编译 |
| **M4-R3** | 正弦表用 `initial` 赋值，TD 会把它写进 BRAM 初值 | area 报告 `u_rom` = 0 LUT + 1 BRAM；厂商 `ov5640_init_table_jpeg.v` 同样写法且综合出 2 BRAM | 若 BRAM 没初值：耳机里是噪声/静音 | 上板一听就知道；退路是把表改成 `case` 组合 ROM（约 +1 300 LUT，仍可接受） |
| **M4-R4** | WM8960 的 I2C 地址 0x34、I2S 引脚 A8/A7/C7 按管脚表 | 数据手册 p63；`hw-facts.md` §7（并已指出厂商 `IO.adc` 错位） | 地址错 → 无 ACK，数码管/`O_ok`=0；引脚错 → 有波形但无声 | `DEV_ADDR` 是 parameter（改一行）；引脚按 `IO.adc` 注释可换 |
| **M4-R5** | R2/R3 的 `OUT1VU=0` 就能立即生效 | ASoC 的 `SOC_DOUBLE_R_TLV("Playback Volume", WM8960_LOUT1, ...)` 就是这么写的（bit8 保持 0） | 音量停在 −73 dB → 无声 | 把表里 R2/R3 改成 `0x179`/`0x179`（bit8=1 强制更新） |
| **M4-R6** | 未上板验证（本机无板卡） | — | — | §10 的 5 步排查 + §10.3 的观察点即为上板脚本 |
| **M4-R7** | 100 MHz 域 setup 余量 **0.111 ns**（M3 是 0.744 ns，同一批路径的布局抖动） | §8.2 | 极端条件下 FAT32 读扇区可能出错 | 同 M2 R2/M3 R7：降 SPI 频率或拆 `u_fat`；与 M4 音频逻辑无关（音频域余量 73 ns） |
| **M4-R8** | SD 引擎 `spi_clk` 仍无 SDC（继承 M2 R1） | `timing.sdc` 注释 | 偶发扇区读错 | 同 M2 R1 |
| **M4-R9** | I2C 无上拉也会"看起来能通" | `IO.adc` 给 SCL/SDA 开了内部 PULLUP（弱上拉） | 长线/多器件时上升沿变慢 | 外部已有 10 k 上拉（EEPROM/RTC 共用总线）；若波形差可把 SCL 频率降到 20 kHz（改 `SCL_CLOCK` 参数） |

---

## 12. 与 M4 验收要求的逐条对照

| # | 要求 | 结果 | 证据 |
|---|---|---|---|
| 1 | 新增第 3 个 PLL 输出 12.288 MHz 给 MCLK，50 MHz 输入，手写方式，VCO 不能整除要写推导 | ✅ **12.288136 MHz（+11 ppm）**，第 3 个 PLL（3/4），VCO 725 MHz/C=59，推导见 §4（含"精确不可能"的证明、连分数、5 个被否方案、退路） | §4、`al_ip/pll_m4_audio/`、bit `PLL setting string=1011` |
| 2 | BCLK = 48k×64 = 3.072 MHz、LRCK = 48 kHz 由 FPGA 产生，FPGA 主机 / codec 从机 | ✅ BCLK = MCLK/4 = **3.072034 MHz**、LRCK = BCLK/64 = **48.0005 kHz**；R7 `MS=0`（从机） | §6、`m4_i2s_tx.v`、模型 6.01~6.05 / 2.15 |
| 3 | I2C 复用 `i2s_init_dev/i2s_control/i2s_bit_shift` 框架 | ✅ 同样三段式（表级/字节级/位级），模块名 `m4_i2s_*` 一一对应，改动逐条列在 §5.2 | §5.2 |
| 4 | 器件地址 0x20 → **0x34**，做成 parameter | ✅ `DEV_ADDR = 8'h34`（`m4_i2s_init_dev` 的 parameter；`I_dev` 端口传入 `m4_i2s_control`） | §5.1、模型 4.03 |
| 5 | 主从模式：FPGA 主机时 codec 必须从机（查 R8/R7 的 master/slave 位） | ✅ R7 bit6 `MS=0`；**并证明厂商"R8 bit7=主模式"是错的**（R8 无此位） | §5.4 #2、§5.5、模型 2.15/3.15 |
| 6 | 采样率/MCLK 分频匹配 12.288 MHz / 48 kHz | ✅ R4 = 0x000（CLKSEL=MCLK、SYSCLKDIV=÷1、DACDIV/ADCDIV=÷256 → 48 kHz）；**并指出厂商写的 R13 是保留寄存器** | §5.4 #1、模型 2.06~2.10/3.11~3.12 |
| 7 | 输出通路：DAC 解除静音(R6)、耳机音量(R2/R3=0x79)、输出混合器(R4/R5)、电源管理(R1/R2) | ✅ 按**数据手册**：解除静音是 **R5 bit3 DACMU**（不是 R6）、耳机音量 **R2/R3=0x079**、混音器路由 **R34/R37=0x100** + 电源 **R47=0x00C**、电源管理 **R25=0x0C0 / R26=0x1E0**（R1/R2 实际是输入音量寄存器，不用于此） | §5.4 表 + 每条的位域解释 |
| 8 | 每条寄存器都要注释说明作用 | ✅ 表文件里 13 条每条都有"位域 + 页码 + 作用"，报告 §5.4 再列一遍 | `rtl/m4_wm8960_table.v`、§5.4 |
| 9 | I2C 速率 ~40 kHz 可接受；SDA 三态参考 `function_pin.v`；初始化后 SCL/SDA 空闲高 | ✅ 40.06 kHz；`oe/o/i` 三态；初始化后 `O_scl=1`、SDA 释放（模型 4.11） | §3.2、§5.3、模型 4.11 |
| 10 | 自己写 `i2s_tx.v`（不用被注释掉的例程代码）：标准 I2S、MSB 先、LRCK 翻转后延迟 1 BCLK、16 bit 数据、DACDAT 下降沿更新 | ✅ 全新实现；模型逐项验证（6.06/6.11~6.15） | §6、`rtl/m4_i2s_tx.v` |
| 11 | 1 kHz 正弦、48 kHz、16 bit、双声道、幅度约 −6 dBFS | ✅ 1000.011 Hz、48.0005 kHz、16 bit、L=R、峰值 16384（−6.02 dBFS）、THD −55.6 dB | §7、模型 §7 |
| 12 | 上电自动播放，不需要交互；初始化失败就静音 | ✅ 无按键依赖；`O_ok=0` → DACDAT 恒 0 | §2.3、§5.6、模型 5.07/6.16 |
| 13 | 不破坏 M3 的显示/SD/SDRAM 链路 | ✅ M3 的 7 个模块逻辑零改动；32 个厂商文件逐字节未改；M3 复位链未动；模型 `model_m4_ctrl.py` 仍适用 | §1、§3.3 |
| 14 | 新增 PLL 用掉第 3 个（共 4 个，余 1） | ✅ `#pll 3 out of 4 = 75 %` | §8.1 |
| 15 | SDC 给新增时钟域补约束，至少 MCLK 与 I2S 输出相关逻辑 | ✅ `create_generated_clock mclk_audio` + 5 组 `-exclusive`；并说明为什么不能写 12.288 的精确周期 | §4.5、`timing.sdc` |
| 16 | 必须编译到 `m4_audio_Runs\phy_1\*.bit`，报告资源（PLL 3/4、BRAM 增加）与四/五个时钟域 WNS | ✅ 630 799 B bit；LUT 26.06 %、BRAM 18（+1）、PLL 3/4；5 个域的 WNS 全部列出（§8.2） | §8 |
| 17 | 本机无仿真器 → 用 Python 周期级模型验证 I2S 时序、正弦幅度、初始化序列位流 | ✅ 146 项（I2S 逐周期、I2C 位流 + 从机解码、正弦 1 s 逐样点） | §9 |
| 18 | 报告：寄存器逐条注释、I2C 时序、I2S 时序图（文字版）、时钟推导、资源/时序、上板验证清单（排查顺序 + 示波器/万用表测法） | ✅ 本文件 §4/§5/§6/§8/§10 | — |

---

## 13. 附录：关键日志

综合（`syn_1/console_ci.log`）：

```
HDL-1007 : elaborate module m4_top in ../../rtl/m4_top.v(112)
HDL-1007 : elaborate module m4_wm8960_table in ../../rtl/m4_wm8960_table.v(74)
HDL-1007 : elaborate module m4_i2s_bit_shift(FIN=..) ...
SYN-4027 : Net I2S_MCLK_dup_1 is clkc0 of pll u_pll_audio/pll_inst.
SYN-4025 : Tag rtl::Net I2S_MCLK_dup_1 as clock net
HDL-5314 WARNING: net 'S_rom' does not have a driver in ../../rtl/m4_sine_rom.v(19)
TD_FLOW_OK
```

布局布线 + bitgen（`phy_1/console_ci.log`）：

```
RUN-1003 : finish command "place" in  17s wall
RUN-1003 : finish command "route" in  45s wall
BIT-1002 : Init instances completely, inst num: 3619
BIT-1003 : Generate bitstream completely, there are 199875 bits set as '1'.
BIT-1004 : PLL setting string = 1011
BIT-1004 : Generate bits file m4_audio.bit.
TD_FLOW_OK
```

时序（`phy_1/route_flow.status`）：

```
Timing Mode      : final
Setup            : WNS   111ps  TNS        0ps  NUM_FEPS     0
Hold             : WNS     3ps  TNS        0ps  NUM_FEPS     0
```

---

## 14. 下一步（M5 衔接）

1. **上板首日**：先 `DEBUG_LED=1` 编译一版看 led[3]（I2C 通不通），再按 §10.2 的顺序量
   MCLK/BCLK/LRCK/DACDAT；这一步的结论直接决定 M5 要不要动 PLL 参数（M4-R1）。
2. **PCM 播放**：`m4_i2s_tx` 的接口就是"每帧给一个 16 bit 样点"，把 `m4_sine_tone`
   换成"从 SDRAM 读 PCM + 双缓冲"即可（M3 的 SDRAM 控制器还有 RD2 端口空闲），
   I2S 侧一行不用改。
3. **音量/静音交互**：`R2/R3` 已经在表里，按键改音量只需在 I2C 侧加一个"写单条寄存器"的入口
   （`m4_i2s_control` 已经支持任意 reg/data，不需要改状态机）。
4. **HDMI 带声音**：`audio_arc_calculate` + HDMI 核的 `I_audio_*` 端口已存在（M0 里接 0），
   把同一个样点流同时送过去即可；注意 ACR_N 与 48 kHz 匹配（example-arch §5.3）。
5. **若要更纯的正弦**：正弦表 512 项/象限（仍 1 个 BRAM9K），THD 可从 −55.6 dB 到约 −61 dB。

---

## 15. 上板实测（2026-10-23 夜，AC208 板）

本节记录离线报告与真实板卡之间的三处偏差，以及"没声音"的两个真正原因。
（同一份内容在 `docs/research/bench-bringup-postmortem.md` §6，从调试过程的角度写的。）

### 15.1 板上 codec 的地址是测出来的，不是查出来的

新加 **`rtl/m4_i2c_scan.v`**（`DEBUG_AUDIO == 2`）：复位 50 ms 后每 ~0.67 s 扫 128 个 7 位地址，
单字节写事务，结果 ASCII 打到 CH340E（`#addr:ack`）。实测：

```
#SDA=1
ACK: 1A  50  51  58
```

| 地址 | 器件 | 含义 |
|---|---|---|
| **0x1A** | **WM8960**（8 bit 写地址 0x34） | 本板确实是 WM8960 版 |
| 0x50 | 24LC256 EEPROM | 总线/上拉/引脚正常 |
| 0x51 | PCF8563 RTC | 总线正常 |
| 0x58 | MAC 地址 EEPROM | 总线正常 |

- SDA 空闲电平 = 1 → 总线上拉、FPGA 三态释放都正常。
- 因此 §5.4 的寄存器表、器件地址 0x34 全部正确；**之前怀疑的 ES8388（0x20）不成立**，
  厂商资料里那份 ES8388 原理图属于另一个 AC201 版本。

### 15.2 bug：I²C 多字节帧的字节间多出一个 SCL 脉冲（"一直 NACK"的真凶）

**现象**：单字节探测 ACK，3 字节寄存器写全部 NACK（LED D1 常亮）。

**原因**：`m4_i2s_bit_shift.v` 每写完一个字节（含 ACK）就回到 idle 分支，而 idle 分支
无条件把 SCL 拉高；ACK 结束时 SCL 本来为低，于是从机在字节之间看到一个多余上升沿
（SDA 已释放 = 高），当作一位数据 → 后两个字节整体错位 → NACK。

**修法**：新增 `S_hold`：非最后一字节结束时保持 **SCL 低、SDA 释放**，
下一字节命令到来时直接在 SCL 低电平期间放数据位；只有 STOP/中止后才回空闲高。
（单字节事务不受影响，所以扫描器能通过——这正是"工具能跑、初始化失败"的原因。）

### 15.3 bug：I²S 引脚接反 + 误驱动 codec 输出脚

以 **AC601 核心板原理图（U1 球号 → 网络）** 为准，并和厂商可运行的 `board_test/IO.adc`
交叉验证（`A8=I2S_DO`、`A7=I2S_RCLK`、`C7=I2S_DI`）：

| FPGA 球 | 核心板 pin | 核心板网络 | 实际含义 | 修正 |
|---|---|---|---|---|
| B8 | 96 | ES_MCLK | codec MCLK | 不变 |
| C8 | 97 | ES_DSCLK | codec SCLK（BCLK） | 不变 |
| A8 | 98 | ES_DSDIN | **DAC 数据** | `I2S_DACDAT` |
| A7 | 101 | ES_DLCLK | **LRCK** | `I2S_DACLRC` |
| C7 | 102 | ES_ASDOUT | **codec 输出（ADCDAT）** | 删除该输出 |

管脚表 `AC201-EG4S20管脚信息表.xlsx` 把 A8/A7 标成 DACLRC/DACDAT（且列了 WM8960 的 6 个音频脚），
与实际布线相反；**以核心板原理图为准**。C7 原来当 `ADCLRC` 推挽输出，等于和 codec 对顶，已删除。

### 15.4 实测结果

| 项 | 值 |
|---|---|
| LED | **D3（音频 PLL 锁）+ D2（13 条寄存器全 ACK）常亮，D1（NACK）灭** |
| 声音 | 复位后约 **0.55 s**（POR 10 ms + 13 条写约 9 ms + VMID 500 ms 等）开始 1 kHz 正弦 |
| 视频/FAT | 未受影响：`read_uart.ps1` 仍显示 `A..H` 快照与 `Z err=0 state=0x2A` |
| bit / 时序 | **630 799 B**，SWNS **+0.133 ns**、HWNS +0.011 ns（final/routed） |
| 工程 | 实测工程为 `proj/m4_720p`（M3 播放器 + 音频），`m4_audio` 保留为离线模型工程 |
| 发布配置 | `DEBUG_AUDIO = 0`（正常播放状态灯）；1 = 音频状态灯；2 = I²C 扫描器 |

### 15.5 复现步骤

```powershell
cd proj\m4_720p
powershell -NoProfile -ExecutionPolicy Bypass -File .\make_proj_files.ps1   # 文件清单变了才需要
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File ..\..\tools\flash.ps1 -Proj m4_720p
powershell -NoProfile -ExecutionPolicy Bypass -File ..\..\tools\read_uart.ps1   # 可选
```

### 15.6 留给 M5 / 报告的结论

1. 音频链路（I²C 初始化 → I²S 主模式 → DAC → 耳机）已在真板闭环，**M4 可以按"已验证"写进报告**。
2. 若以后要加 **音量/静音按键**：`m4_i2s_control` 已支持任意 reg/data，只需加"单条写"入口。
3. 若要加 **PCM/WAV 播放**：替换 `m4_sine_tone` 的数据源即可，I²S 侧不用改。
4. 若要做 **HDMI 嵌入音频**：本板音频走 codec，HDMI 核的 `I_audio_*` 未接；这是两条独立通路。
