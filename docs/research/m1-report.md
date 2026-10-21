# M1 里程碑报告：片内 SDRAM 帧缓存 → HDMI

- 日期：2026-10-21
- 状态：**编译验收通过（bit 已生成）**；功能未上板实测（本机无板卡）
- 工程：`E:\fpga-2026\dsh_code\proj\m1_sdram_fb\`（新建，纯英文路径）
- 依据：`docs/specs/2026-10-21-hdmi-basic-player-design.md` §3–§5、`docs/research/m0-report.md`、`docs/research/td-toolchain.md`、`docs/research/example-arch.md` §3
- 原始资料 `E:\fpga-2026\选题一-EG4S20-HX4S20C官方例程\` **只读未改**（只把 HDMI 链 3 个文件 + SDRAM 控制器 8 个文件拷进新工程）

---

## 0. 结论速览

| 项 | 结果 |
|---|---|
| 工程/顶层 | `proj/m1_sdram_fb/m1_sdram_fb.al`，顶层 `m1_top`（7 个 IO：50 MHz、KEY2 复位、KEY0 换页、4 对 TMDS） |
| 帧缓存 | 片内 SDRAM 硬宏 `EG_PHY_SDRAM_2M_32`（2M×32 = 8 MB），页 A + 页 B 各 307,200 字 = 2.4 MB |
| 写侧 | 自写 `m1_sdram_wr.v`：640×480 渐变 + 8 px 移动竖条 + 页标识边框，32 bit/像素（低 24 位 RGB888），每帧写一整页（2400 个 128 字突发） |
| 读侧 | 两个读端口 RD1/RD2 各锁一页，按"每个有效像素读 1 字"连续出数，寄存器选择后送 HDMI 核（替代 M0 彩条） |
| 双缓冲 | 写"不在显示的那一页"，**帧起始（场消隐）**切换显示页；自动 60 帧（≈1.008 s）换一次 + KEY0 手动换页 |
| PLL | 2 个（4 个里的 2 个）：50 MHz → 25.000 MHz 像素 + 125.000 MHz 串行；控制器内部 100.000 MHz + 100.000 MHz/270° |
| 编译 | 全清编译 **29.8 s**，`TD_FLOW_OK`，退出码 0；两次独立全清编译 **393 行 payload 逐行一致、Bitstream CRC 相同** |
| bit | `m1_sdram_fb_Runs/phy_1/m1_sdram_fb.bit`，629,635 B，`Design name: m1_top` |
| 资源 | LUT **1941/19600 (9.90%)**、FF **1525/19600 (7.78%)**、BRAM **16/64 (25.0%)**、PLL **2/4 (50%)**、GCLK 5/16、IO 7/188 |
| 时序（final/routed） | Setup **WNS +2.174 ns**（0 违例端点），Hold **WNS +0.003 ns**；4 个时钟域全部收敛，无跨域路径组 |
| 非仿真验证 | 自写 `sim/model_sdram_fb.py` 周期级模型：读 FIFO 最低余量 **152 字（6.1 µs）**，无读下溢/写上溢，SDRAM 稳态占用 59.1% |
| 遗留风险 | 未上板；SDR_CLK(270°) 未加 SDC（`USR-6125`）；读 FIFO 的 FWFT 时序是推断（有厂商用法佐证）；hold 仅 +3 ps |

---

## 1. 工程结构与文件来源

```
proj/m1_sdram_fb/
├── m1_sdram_fb.al              TD 工程文件（TD_Version 必须是数字版号 6.2.190657）
├── IO.adc                      引脚约束（7 个 IO）
├── timing.sdc                  时钟约束（50 / 25 / 125 / 100 MHz，4 个 exclusive 组）
├── run_flow.tcl                DefaultFlow 的 CI wrapper（TD_FLOW_OK / exit 1）
├── build.ps1                   一条命令全清重编
├── README.md                   工程速览
├── rtl/
│   ├── m1_top.v                顶层（新写）
│   ├── m1_video_src.v          光栅 + 页控制 + AXIS 源，25 MHz（新写，取代 M0 的 video_gen）
│   ├── m1_sdram_wr.v           测试图案写入器，100 MHz（新写）
│   ├── hdmi_phy_warpper.v      ← 厂商原样拷贝
│   ├── lane_lvds_10_1.v        ← 厂商原样拷贝
│   ├── hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v  ← 厂商加密 IP 原样拷贝
│   └── sdram_ctrl_4p/          ← 厂商拷贝 8 个文件（仅 Sdram_RD_FIFO.v 改 1 个阈值，见 §3.6）
│       ├── Sdram_Control_4Port.v   command.v   control_interface.v   sdr_data_path.v
│       ├── sdram_ip.v              （例化 EG_PHY_SDRAM_2M_32 硬宏）
│       ├── Sdram_WR_FIFO.v         Sdram_RD_FIFO.v  （512×32 异步 FIFO，EG_LOGIC_FIFO）
│       ├── Sdram_PLL.v             （50 MHz → 100 MHz + 100 MHz/270°）
│       └── *.ipc                   仅作文档，**未挂进工程**（TD 无脚本化 IP 生成器，直接挂 .v）
├── al_ip/pll_m1_hdmi/
│   ├── pll_m1_hdmi.v           HDMI PLL（M0 原样改名）
│   ├── pll_m1_hdmi.ipc         仅作文档，未挂进工程
│   └── README.txt              PLL 推导过程
├── sim/model_sdram_fb.py       FIFO/带宽/地址映射的周期级 Python 模型（本机无 iverilog/verilator）
└── m1_sdram_fb_Runs/{syn_1,phy_1}/
```

厂商文件来源（全部只读拷贝、**逐字节未改**）：

- HDMI 链：`...\AC201_AL_board_test\src\user_source\hdl_source\`
- SDRAM 控制器：`...\AC201_AL_board_test\src\5640\sdram_ctrl_4p\`

拷贝后用 SHA256 逐个比对：HDMI 链 3 个 + SDRAM 控制器 8 个，**10/11 与原文件逐字节一致**；唯一改动是 `Sdram_RD_FIFO.v` 的一个 FIFO 阈值 **`.AF(128) → .AF(256)`**（读 FIFO 的 almost-full 门限，原因见 §3.6，文件头有说明）。原件未动。

**没有**带进来：以太网、OV5640/摄像头、RTC、红外、蜂鸣器、数码管/74HC595、WM8960/音频、36 位 `gpio_40pin`、`hardware_test.v`、`design_top_wrapper.v`。

与 M0 的差异：`video_gen.v` 删除（被 `m1_video_src.v` 取代）；PLL 目录/模块改名 `pll_m1_hdmi`；顶层改名 `m1_top` 并新增 `key0_n`；`settings.cfg`/`.prj`/`.al` 工程名改为 `m1_sdram_fb`；SDC 增加 `sdram_clk`。

---

## 2. 系统架构、时钟与复位

```
                     ┌──────────────────────────── 25 MHz 像素域 ───────────────────────────┐
 50 MHz ──pll_m1_hdmi─┤ 25.000 MHz ── m1_video_src ──AXIS──> hdmi_1_4b_core ──> hdmi_phy ──> TMDS
   K14               │                 │   ▲   ▲                                          │
                     │                 │   │   └── RD1_DATA / RD2_DATA（各 32 bit）          │
                     │                 │   └────── RD1 / RD2 读使能（每有效像素 1 次）        │
                     └─────────────────┼──────────────────────────────────────────────────┘
                                       │ 页选择 / 写起始（电平 + 翻转，2FF 同步）
 50 MHz ──> Sdram_Control_4Port ──────┴────── 100 MHz 域 ── m1_sdram_wr ──WR1──> 写 FIFO
              │  Sdram_PLL: 100 MHz / 100 MHz 270°
              │  RD1 FIFO 512×32 ← 读端口 1（页 A）      RD2 FIFO ← 读端口 2（页 B）
              └── EG_PHY_SDRAM_2M_32（片内 8 MB，硬宏，不占引脚）
```

### 2.1 四个时钟域

| 时钟 | 频率 | 来源 | 用途 |
|---|---:|---|---|
| `clk_50m` | 50 MHz | 板载晶振 K14 | 两个 PLL 的参考、KEY2 同步 |
| `pixel_clk` | 25.000 MHz | `pll_m1_hdmi` C1 | 光栅/页控制/AXIS、HDMI 核、两个读 FIFO 的读时钟 |
| `serial_clk` | 125.000 MHz | `pll_m1_hdmi` C2（相位 39.375°） | 4 路 TMDS 串行器 |
| `sdram_clk` | 100.000 MHz | `Sdram_Control_4Port` 内部 `Sdram_PLL` C0 | 控制器本体、WR1_CLK、写图案发生器 |
| `SDR_CLK` | 100.000 MHz / 270° | 同 C1 | 只送 `EG_PHY_SDRAM_2M_32` 的 clk（片内，不上引脚） |

跨域只有三类，全部显式处理：

1. **数据流**：写 FIFO / 读 FIFO 是厂商的 512×32 异步 FIFO（`EG_LOGIC_FIFO`，RESETMODE=ASYNC，读写时钟独立）——真正的跨域通路在这两个宏里；
2. **控制电平**：`wr_page`、`wr_start_tog`、`wr_done_tog`、`sdram_ready` 都是"整帧稳定"的电平或翻转信号，各过 2~3 级同步器 + 边沿检测；
3. **复位**：`KEY2` → 50 MHz 两级同步 → 与 `pll_lock` 相与得到 `S_rst_n_async`；再在**每个时钟域各做一次"异步置位、同步释放"**。
   SDRAM 域额外用 16 bit 计数器（2^15 × 40 ns ≈ **1.31 ms**）延后释放，保证内部 `Sdram_PLL` 锁稳后再让控制器开始 240 µs 的 SDRAM 初始化。

**为什么写侧要单独用 100 MHz**：写一页 307,200 字若用 25 MHz 需要 12.3 ms（占满整个有效行时间），会和两路读争带宽；用 100 MHz 时一页约 3~5 ms 写完，剩下 11 ms 控制器几乎只服务读端口，FIFO 余量最大。代价是多一个时钟域和一套 CDC，已在上面列明。

### 2.2 复位顺序（上电）

```
KEY2 释放 & PLL lock
   ├─ pixel_clk  2FF  → S_rst_pixel      （HDMI 核 + 光栅，立即开始）
   ├─ serial_clk 2FF  → S_rst_serial
   └─ 1.31 ms 后 → sdram_clk 2FF → S_rst_sdram 释放
                        └─ 控制器 240 µs 初始化 → 读 FIFO 开始被填满
```

---

## 3. SDRAM 帧缓存：地址映射与顺序流式访问

### 3.1 片内硬宏的证据

`sdram_ip.v` 例化 `EG_PHY_SDRAM_2M_32`（`E:\arch\eagle_macro.v:683`），综合后：

- `u_sdram_mem`（`sdram_ip`）层次资源 **0 LUT / 0 FF / 0 BRAM**（纯硬宏，走专用布线）；
- post-route 的 Detailed IO Report 里，SDRAM 的 `dq[31:0] / addr[10:0] / ba / cs_n / ras_n / cas_n / we_n / cke / dm0..3 / clk` 全部落在 **S 行焊盘（S1…S89）**；
- AC208 的《管脚信息表》194 行里**没有任何 S 行焊盘**，也没有任何 SDRAM 信号 —— 说明这些是封装内 FPGA die 与堆叠 SDRAM die 之间的专用接口，不是用户 IO；
- `#IO 7 / 188`（只有 3 输入 + 4 输出），SDRAM 接口一个都没算进用户 IO。

→ 结论：帧缓存用的是**片内 8 MB SDRAM**，不需要外部器件、不占引脚。`sdram_ip.ipc` 只是 IP 生成器留下的配置记录，本工程不挂它。

### 3.2 字地址 vs 字节地址（本工程最容易错的一处）

`Sdram_Control_4Port` 的 `WR1_ADDR/RD1_ADDR` 是 **32 bit 数据总线的字地址**（`ASIZE=21`，2^21 字 = 8 MB）。而设计文档里页 B 的基址 `0x12C000` 是**字节地址**：

```
页长 = 640 × 480 = 307,200 像素 = 307,200 字（32 bit/像素）
                              = 1,228,800 字节 = 0x12C000 字节
页 B 字地址 = 0x12C000 / 4 = 0x04B000 = 307,200
```

若直接把 `0x12C000` 当字地址填进端口，页 B 会落到**字地址 1,228,800（字节 4.69 MB）**处——虽然仍在 8 MB 器件内，但与页 A 之间隔了 921,600 字的空洞，环形写就不成立了，而且语义也与设计文档不符。本工程全部用字地址，两页因此**首尾相接**。

### 3.3 地址映射表

| 区域 | 字地址 | 字节地址 | 长度 | SDRAM 行/体 |
|---|---|---|---:|---|
| 页 A | `0x00000 .. 0x4AFFF` | `0x000000 .. 0x12BFFF` | 307,200 字 | bank0，row 0..1199（每行 256 字） |
| 页 B | `0x04B000 .. 0x095FFF` | `0x12C000 .. 0x257FFF` | 307,200 字 | bank0 row 1200..2047 + bank1 row 0..351 |
| 环形写区间 | `0x00000 .. 0x095FFF` | `0x000000 .. 0x257FFF` | 614,400 字 | 两页首尾相接 |
| 器件容量 | `0x00000 .. 0x1FFFFF` | `0x000000 .. 0x7FFFFF` | 2,097,152 字 | 2M×32 = 8 MB |

控制器内部译码（`Sdram_Control_4Port.v` / `command.v` 的宏定义）：

```
bank = addr[20:19]   row = addr[18:8]   col = addr[7:0]
```

一次突发 128 字，起始列只能是 0 或 128（页长 307,200 = 2400×128，页基址都是 128 的整数倍），**永远不会跨行**，所以页模式（`SC_PM=1`，全页突发 + burst terminate）是安全的。

### 3.4 为什么是"环形写 + 双读端口"，而不是每次换页打 `WR1_LOAD`/`RD1_LOAD`

这是 M1 最关键的设计决策，踩过的坑写在下面（都是读厂商 RTL 推出来的，不是猜的）：

1. **`WR1_LOAD`/`RD1_LOAD` 都不清 FIFO**。`Sdram_Control_4Port.v:326-338, 359-370` 里两个 FIFO 的 `rst` 接的是 `!RESET_N`，`aclr(WR1_LOAD)` 那一行是被注释掉的。
2. **写侧**：`WR1` 写 FIFO 的"几乎空"阈值 `AE=127`，控制器只在 `usedw>127` 时才发 128 字突发。所以任意时刻 FIFO 里最多会滞留 **127 个上一页的字**。若此时打 `WR1_LOAD` 把地址重置到新页基址，这 127 个字会先被写进新页开头 → **整页内容永久右移 0~127 字**（表现为画面整体横移、行首回卷）。
3. **读侧更糟**：读 FIFO 的"几乎满"阈值 `AF`（厂商值 128，本工程调到 256）决定它会预取到 `usedw≈AF..AF+127`。若打 `RD1_LOAD` 换页，FIFO 里还压着 **最多 AF+127 个旧页的字**，显示会永久相位偏移同样多的字。
4. 想"打 LOAD 前先把 FIFO 排空"也不行：写 FIFO 因为 `AE=127` 永远不会排空；读 FIFO 一边排一边被控制器续填，无法稳定观察到 empty。

**本工程的做法**：

- **写侧不用 LOAD**（`WR1_LOAD=1'b0`）：地址计数器从 0 开始、按 128 递增、到 `0x96000` 回卷，成为 614,400 字的环。一页正好 2400 个突发，所以每页起始时刻环地址**必然**落在页基址上；FIFO 滞留的字只是延迟，不改变"第 n 个字写到基址+n"（见 §3.5）。
- **读侧用两个端口**（RD1 固定页 A、RD2 固定页 B，各自由 `RESET_N` 装载一次地址后自由循环）。两路都按"每有效像素读 1 字"连续消费，永远和光栅同相；换页只是**在帧起始把 AXIS 数据源从 RD1 切到 RD2**（寄存器 mux），地址、FIFO、相位全都不用动，因此换页不会撕裂也不会偏。

> 代价：读带宽翻倍（两页都在被读）。实测/模型都很宽裕（§11），换来的是"换页零风险"。

### 3.5 "第 n 个字 → 基址+n" 成立的三个前提

写侧 FIFO 只是延迟线，控制器每次突发取走"最老的 128 个字"，因此第 n 个字一定落到第 ⌊n/128⌋ 个突发的地址上。成立条件是：

1. **FIFO 从空开始**：`RESET_N` 复位时 `.rst(!RESET_N)` 清空，且写侧在 SDRAM 域退出复位前不会产生写（`m1_sdram_wr` 的 `I_rst` 就是 `S_rst_sdram`，起始脉冲在 `sdram_ready` 之后才发）；
2. **突发时 FIFO 里至少有 128 个字**：`AE=127` 保证 `usedw>127` 才发写突发；
3. **写使能不会在 full 生效的同一拍丢字**：见 §4.2（改成组合写使能）。

读侧同理：读 FIFO 从空开始、按 128 字突发取数、按 1 字/像素消费，只要**从不清空、从不下溢**，输出序列就永远是 `基址, 基址+1, …`。

### 3.6 读 FIFO 的 almost-full 阈值（本工程唯一一处厂商参数改动）

`Sdram_RD_FIFO.v` 是 IP 生成器产物，里面只有一句 `.AF(128)`。按 UG301 §14.3 的定义，`AF` 是 **afull 拉高时的绝对 FIFO 使用量**（默认值 `DATA_DEPTH_W-6`，即"用到只剩 6 个空位"时才几乎满），所以 `AF=128` 表示**读 FIFO 只保留约 128 字的预取量**。

这在厂商原设计（**一个**读端口 + 33 MHz 显示）里够用；但 M1 有 **两个**读端口 + 一个写端口共用同一个控制器，而且仲裁优先级是 `RD1 > RD2 > WR1`（`Sdram_Control_4Port.v:592-637` 的 if-else 顺序），**RD2 是最低优先级的读端口**：它发出突发请求时，最坏要等 RD1 的一整个突发（约 1.4 µs）甚至再加一个写突发。周期模型（§10）在 `AF=128` 下给出：

| AF | RD1 最低余量 | RD2 最低余量 | 判定 |
|---:|---:|---:|---|
| 128（厂商原值） | 59 字 | **24 字（0.96 µs）** | 能跑，但一次额外的仲裁延迟就会下溢 |
| **256（本工程）** | **187 字** | **152 字（6.1 µs）** | 余量充足 |

因此把该文件改成 `.AF(256)`：读 FIFO 稳定在 256~383 字。突发请求发生在"使用量 < 256"时，突发再加 128 字 → 最多 383 字 < 512，**不可能溢出**。这是本工程对厂商文件的唯一改动（1 个参数），控制器逻辑、突发长度、地址行为都没动；文件头写了原因，原件未改。

> 另一种不改厂商文件的做法是把 `RD1_LENGTH/RD2_LENGTH` 从 128 降到 64，让 FIFO 更频繁地补水；但模型显示那样 RD2 最低余量只有约 57 字（2.3 µs），不如调 AF 干净，而且突发次数翻倍、开销更大。

---

## 4. 写侧：测试图案发生器 `rtl/m1_sdram_wr.v`（100 MHz）

### 4.1 图案（640×480，32 bit/像素，低 24 位 RGB888）

| 区域 | 内容 | 用途 |
|---|---|---|
| 边框 8 px | 页 A = 绿 `00FF00`，页 B = 品红 `FF00FF` | **换页时一眼看出换了页** |
| 8 px 宽竖条 | 白 `FFFFFF`，每 60 次整页写右移 8 px，到 x=632 回卷 | 证明"每秒都在重写"（≈8 px/s，80 s 扫过全屏） |
| 其余 | R = x[9:2]（0..159），G = y[8:1]（0..239），B = `0x40` | 水平/垂直渐变，**能看出地址顺序/镜像错误** |

竖条位置和页标识都由写侧自己维护（`S_bar_x`、`S_page_q`），不跨时钟域传，避免多 bit CDC 采到中间值。

### 4.2 写 FSM 与一个真实的丢字坑

```
IDLE --(start 翻转沿 & !busy)--> 置 busy、x=y=0、锁存目标页
WRITE: O_wr = busy && !WR1_FULL（组合）
       每个被接收的字：x++；x==639 → y++、x=0；y==479 → busy=0、done_tog 翻转、竖条计数
```

- **`O_wr` 必须是组合的**（`S_busy && !I_fifo_full`）。最初写成"寄存器输出 + 上一拍判断 full"，就会出现：最后一个字在第 t 拍决定写、第 t+1 拍才出现在写口上，而 full 恰好在 t+1 拍拉高 → FIFO 丢掉这个字 → 整页少 1 字 → 环形地址与内容永久错位 1 字。改成组合使能后，写使能与 full 同拍判断，不会丢字。
- 写使能只在 `!full` 时有效，其余时间 x/y 不前进，图案不会错位。
- `done_tog` 在最后一个字被 FIFO **接收**的那一拍翻转；25 MHz 域用 3 级同步 + 异或边沿检测收到后置 `page_ok[wr_page]=1`。

---

## 5. 读侧与 AXIS：`rtl/m1_video_src.v`（25 MHz）

### 5.1 像素节拍

与 M0 完全一致的光栅：`HTOTAL=800 / HSA=96 / HBP=48 / HFP=16 / HACTIVE=640`，`VTOTAL=525 / VSA=2 / VBP=33 / VFP=10 / VACTIVE=480`，25.000 MHz → 行频 31.25 kHz → **59.52 Hz**。

- `valid <= S_active`（每有效像素 1 拍），`user` = 每帧第一个有效像素，`last` = 每行最后一个有效像素（col=799），`data` 与三者同拍打拍 → 与 M0 的 AXIS 时序逐拍相同；
- **`re` 是组合的 `S_active && S_rd_en`**，与 `data` 采样同拍（见下）。

### 5.2 FIFO 读时序（FWFT 假设）

`EG_LOGIC_FIFO` 配置 `.ore(1'b0)`（`REGMODE_R="NOREG"`），即 RAM 异步读：`DO` 在 `RE` 之前就已是当前字，`RE` 在时钟沿推进指针。厂商 `ov5640_sdram_vga` 的用法正是"在 `RE` 同一拍用 `data_rgb`"（`assign rgb = Rd_Sdram ? data_rgb[15:0] : data_rgb[31:16]`，`Rd_Sdram` 每两拍翻转一次），可作佐证。

因此本设计：

```
每个有效像素拍：  O_rd1_re = O_rd2_re = 1
                  O_video_data <= S_disp_en ? (S_disp_page ? RD2_DATA : RD1_DATA)[23:0] : 0
```

`DO` 在当前拍就是本像素的字，采样后与 `valid` 同拍进入 HDMI 核。

### 5.3 启动时序：为什么先空跑一帧再显示

读 FIFO 在复位后立刻被控制器填满（早于第一次写），所以它开头 ≤512 个字是**上电时 SDRAM 里的旧内容**。如果直接显示，第一帧左上角约 400~512 个像素会是花点。

处理办法（零成本）：**先消费一整帧、不显示**。

```
page_ok[disp] 有效的那一帧帧起始：S_rd_en <= 1   （开始消费，但数据仍强制黑）
下一帧帧起始：                   S_disp_en <= 1  （开始显示）
```

消费一整帧正好 307,200 字 = 一个页长，读地址计数器回到 0，且这期间 FIFO 里的字都是"页写完之后才从 SDRAM 取"的新数据 → **第一帧可见画面就是干净且对齐的**。

### 5.4 页控制（双缓冲）

```
每帧帧起始（line=0,col=0，即场消隐开始）：
  if (!page_ok[disp])                      // 启动阶段：还没有可显示的页
        wr_page <= disp;  rd_en <= 0;      // 先写"想显示的那一页"
  else
        rd_en <= 1;
        if ((swap_pend || auto_swap) && page_ok[~disp])
                disp_page <= ~disp_page;   // 场消隐期间换页
                wr_page   <= disp_page;    // 旧值 = 刚离开的那一页（= ~新 disp）
        else
                wr_page   <= ~disp_page;   // 平时一直重写"不在显示的那一页"
  start_tog 翻转一次                      // 启动本帧的整页写
```

- `auto_swap` 每 `SWAP_FRAMES=60` 帧一次（≈1.008 s）；KEY0（F7，低有效，25 MHz 采样 + 18 bit 计数 ≈10.5 ms 消抖）可随时请求，在下一个帧起始生效；
- **只有 `page_ok` 的页会被选中**，所以永远显示"已经完整写完"的页；
- `start_tog` 比 `wr_page` 晚 1 个像素时钟（40 ns）发出，保证写域同步到翻转沿时页号早已稳定。

### 5.5 一帧的时间轴（稳态）

| 时刻（以帧起始 t=0 计） | 事件 |
|---|---|
| 0 | 帧起始：决定 `disp_page`/`wr_page`，`start_tog` 翻转；AXIS mux 从本帧起用新页 |
| +80 ns | 写域同步到翻转沿，`m1_sdram_wr` 开始产生 307,200 个字（受 `WR1_FULL` 反压） |
| ≈ +3…5 ms | 最后一个字进入写 FIFO，`done_tog` 翻转 → 25 MHz 域置 `page_ok` |
| 0…16.78 ms | 读端口按 640 字/行（有效区）× 480 行消费两页；写端口在 0~5 ms 占用部分带宽 |
| 16.78 ms | 下一帧起始，重复；到第 60 帧起始且请求换页时切 `disp_page` |

写入永远在**显示另一页**时进行；被写的那一页下次被选中前至少还有一整帧，所以看不到"半新半旧"。

---

## 6. 约束

### 6.1 `IO.adc`（7 个 IO，与 post-route Detailed IO Report 逐条一致）

| 信号 | 脚 | IOSTANDARD | 其它 |
|---|---|---|---|
| `clk` | K14 | LVCMOS33 | PULLUP |
| `rst_n` | H14 | LVCMOS33 | PULLUP |
| `key0_n` | F7 | LVCMOS33 | PULLUP（管脚表：KEY0=F7，邮票孔 110） |
| `O_tmds_ch0_p` / (n) | D11 / D12 | LVDS33_E | DRIVESTRENGTH=8, DDRX1 |
| `O_tmds_ch1_p` / (n) | C11 / A11 | LVDS33_E | 同上 |
| `O_tmds_ch2_p` / (n) | F10 / H11 | LVDS33_E | 同上 |
| `O_tmds_clk_p` / (n) | B10 / C9 | LVDS33_E | 同上 |

SDRAM 接口全部在片内 S 行焊盘，**不需要也不能**在 `IO.adc` 里约束。

### 6.2 `timing.sdc`

```tcl
create_clock -name clk_50m -period 20.000 -waveform {0 10.000} [get_ports {clk}]

create_generated_clock -name pixel_clk  -source [get_ports {clk}] -divide_by 2 \
    [get_pins {u_pll/pll_inst.clkc[1]}]
create_generated_clock -name serial_clk -source [get_pins {u_pll/pll_inst.clkc[1]}] -multiply_by 5 \
    [get_pins {u_pll/pll_inst.clkc[2]}]
create_generated_clock -name sdram_clk  -source [get_ports {clk}] -multiply_by 2 \
    [get_pins {u_sdram/sdram_pll1/pll_inst.clkc[0]}]

set_clock_groups -exclusive \
    -group [get_clocks {clk_50m}] -group [get_clocks {pixel_clk}] \
    -group [get_clocks {serial_clk}] -group [get_clocks {sdram_clk}]
```

- 两个 PLL 都是普通 Verilog 文件，TD 不把它们注册成 IP、只当"直通"，因此在 PLL 输出上只能用 `create_generated_clock`（M0 已实测：`create_clock` 会报 `USR-8194`）。
- **`sdram_clk` 用 `-multiply_by 2` 从 50 MHz 派生**（100 MHz），TD 接受，post-route 时钟表里出现 `clk1: 100.000 MHz`，**570 个端点 / 7032 条路径**被正常分析（WNS +2.174 ns）。
- `SDR_CLK`（100 MHz/270°，只送片内 SDRAM 宏的 clk）**故意不加约束**：该域没有任何寄存器到寄存器路径。代价是 phy 日志里一条 `USR-6125 CRITICAL-WARNING: No clock constraint on PLL/clock buffer pin u_sdram/sdram_pll1/pll_inst.clkc[1]`（见 §12）。
- 四个时钟互斥分组：pixel↔sdram 的数据都在异步 FIFO 里，控制信号都过了同步器；serial 与 pixel 是 TMDS 自定时装载；clk_50m 只做复位同步。

---

## 7. 编译

### 7.1 一条命令

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\fpga-2026\dsh_code\proj\m1_sdram_fb\build.ps1
```

等价于（必须分别 `cd` 进两个 run 目录）：

```powershell
cd E:\fpga-2026\dsh_code\proj\m1_sdram_fb\m1_sdram_fb_Runs\syn_1
E:\bin\td_commands_prompt.exe E:/fpga-2026/dsh_code/proj/m1_sdram_fb/run_flow.tcl
cd ..\phy_1
E:\bin\td_commands_prompt.exe E:/fpga-2026/dsh_code/proj/m1_sdram_fb/run_flow.tcl
```

Tcl 路径必须正斜杠；`run_flow.tcl` 把 TD 不可靠的退出码变成 0/1 并打印 `TD_FLOW_OK`。

### 7.2 耗时（32 线程，**全清编译**：两个 run 目录只留 `settings.cfg` + `m1_sdram_fb.prj`）

| 阶段 | 命令时间 | 说明 |
|---|---:|---|
| syn_1（read_design + opt_rtl 3.46 s + opt_gate 3 s） | 6 s | elaborate 里能看到 `EG_PHY_SDRAM_2M_32` |
| phy_1（place 5.75 s + route 14.68 s + bitgen <1 s） | 21 s | route 里含 SDRAM 控制器的 100 MHz 路径优化 |
| **合计 wall** | **29.8 s** | 退出码 0，日志 `TD_FLOW_OK` |

### 7.3 bit 文件与可复现性

```
E:\fpga-2026\dsh_code\proj\m1_sdram_fb\m1_sdram_fb_Runs\phy_1\m1_sdram_fb.bit
  629,635 字节
  SHA256 50BBF2396419C044D538DF39835B94CA6378398D65E1EF9D7B2934F00EA00B73
```

头部：

```
# Anlogic ASCII Bitstream
# Version: Release_2026.1_SP2
# Design name: m1_top
# Architecture: eagle_s20
# Package: EG4S20BG256
# Bitstream CRC: 00010110110111100100010011011001
# USER CODE: 00000000101111110000000000000000
# Transfer CRC: 01101100101100110100101001100000
```

**两次独立全清编译**：去掉 `#` 头部后的 393 行 payload **逐行完全一致**，`Bitstream CRC` 相同，只有 `# Date:` 不同（所以文件 SHA256 每次都会变，属正常）。
bitgen 日志：`BIT-1004 : PLL setting string = 0011`（两个 PLL 都写进了配置串）、`BIT-1003 : Generate bitstream completely, there are 66907 bits set as '1'`。

---

## 8. 资源（post-route，`phy_1/m1_sdram_fb_phy.area`）

| 资源 | 用量 | 总量 | 占比 |
|---|---:|---:|---:|
| LUT（`#lut`，含进位链） | **1,941** | 19,600 | **9.90%** |
| 逻辑单元 LE | 2,258 | — | — |
| 寄存器 FF（`#reg`） | **1,525** | 19,600 | **7.78%** |
| BRAM（bram9k 8 + fifo9k 8） | **16** | 64 | **25.00%** |
| BRAM32K | 0 | 16 | 0% |
| DSP | 0 | 29 | 0% |
| **PLL** | **2** | 4 | **50.00%** |
| GCLK | 5 | 16 | 31.25% |
| PAD / IO | 11 / 7 | 188 | 5.85% / 3.72% |

层次（le / lut / seq / bram）：

| 模块 | LE | LUT | FF | BRAM |
|---|---:|---:|---:|---:|
| `m1_top` 合计 | 2,258 | 1,611 | 1,531 | 16 |
| ├ `u_hdmi_core`（加密 HDMI 核） | 1,362 | 910 | 1,004 | 8 |
| ├ `u_sdram`（Sdram_Control_4Port） | 546 | 469 | 308 | 8 |
| │ ├ `command1` / `control1` | 58 / 98 | 57 / 70 | 52 / 53 | 0 |
| │ ├ `read_fifo1` / `read_fifo2` | 4 / 4 | 4 / 4 | 1 / 0 | 2+2 |
| │ └ `write_fifo1` / `write_fifo2` | 0 / 5 | 0 / 5 | 0 / 1 | 2+2 |
| ├ `u_sdram_wr`（写图案） | 135 | 88 | 50 | 0 |
| ├ `u_video_src`（读侧/页控制） | 125 | 94 | 87 | 0 |
| ├ `u_hdmi_phy`（4×lane） | 44 | 35 | 44 | 0 |
| ├ `u_pll`（宏） | 0 | 0 | 0 | 0 |
| └ `u_sdram_mem`（SDRAM 硬宏） | 0 | 0 | 0 | 0 |

SDRAM 链路新增的资源：控制器 `u_sdram` **546 LE + 8 BRAM**（4 个 512×32 异步 FIFO，每个 2 个 `fifo9k`），写图案 135 LE，读侧/页控制 125 LE；同时删掉了 M0 的彩条发生器（约 60 LE）→ **净增约 746 LE、+8 BRAM、+1 PLL、+2 GCLK**。GCLK 从 3 增到 5：`pixel_clk`(678)、`sdram_clk`(242)、`serial_clk`(33)、`SDR_CLK`(1)、`clk_50m`(38)。

---

## 9. 时序（`phy_1/final_timing.rpt`，final / routed，Slow+Fast 角）

```
Setup : WNS +2174 ps  TNS 0 ps  NUM_FEPS 0
Hold  : WNS   +3 ps   TNS 0 ps  NUM_FEPS 0
```

| 时钟 | 约束周期 | SWNS | HWNS | 端点 | 实测最短周期 / Fmax |
|---|---:|---:|---:|---:|---:|
| `pixel_clk` 25 MHz | 40.000 ns | **+30.069 ns** | +0.003 ns | 1,654 | 9.931 ns / 100.7 MHz |
| `sdram_clk` 100 MHz | 10.000 ns | **+2.174 ns** | +0.038 ns | 570 | 7.826 ns / 127.8 MHz |
| `clk_50m` 50 MHz | 20.000 ns | **+16.902 ns** | +0.137 ns | 38 | 3.098 ns / 322.8 MHz |
| `serial_clk` 125 MHz | 8.000 ns | **+4.902 ns** | +0.137 ns | 33 | 3.098 ns / 322.8 MHz |

- 只有 4 个**域内** path group，**没有跨域 path group**（exclusive 分组生效），STA 覆盖 0 违例端点；
- 全局 WNS = **+2.174 ns**，来自 100 MHz SDRAM 域：`u_sdram/ST_reg[6]` → `u_sdram_mem/sdram_syn_16.do[0]`（命令状态机到 SDRAM 宏的数据口），裕量 21.7%；
- `pixel_clk` 域的最小周期从 M0 的 6.4 ns 变差到 9.9 ns（新增页控制/多路选择器），但相对 40 ns 约束仍有 30 ns 余量。

---

## 10. 没有仿真器时怎么验证：`sim/model_sdram_fb.py`

本机没有 iverilog/verilator/Questa，TD 命令行也没有可用仿真入口。为了不是"只靠眼看 RTL"，写了一个**周期级行为模型**（纯 Python，无依赖），把最容易出错的三件事量化：

**建模内容**

- 100 MHz 控制器"一次一个 128 字突发"，优先级 **RD1 > RD2 > WR1**（与 `Sdram_Control_4Port.v:592-637` 的自动读写控制逐条对应）；
- 突发开销 = 128 个数据拍 + 固定开销。由 RTL 状态机推：`ST` 计到 `SC_CL+SC_RCD+LENGTH+1 = 135`，加 2 拍命令握手 → 取 **10 拍开销（138 拍/突发）**，并做 20…300 拍的敏感性扫描；
- FIFO 阈值（都可配置）：写 `AE=127`（`usedw>127` 才发写突发）、写 `AF=378`（`usedw>=378` 时写侧停手）、读 `AF=256`（`usedw<256` 才发读突发，见 §3.6）、深度 512；
- 光栅 800×525@25 MHz，每有效像素两路各消费 1 字；
- 写侧每帧 307,200 字、受 full 反压、写完即停；
- 环形/页地址计数器与回卷点。

**结果（4 帧；前两帧读未使能，第 2~4 帧稳态）**

| 突发开销 | 每突发拍数 | 读 FIFO 最低余量 RD1/RD2 | 读下溢 | 写完成字数（3 帧应 921600） | 稳态占用 | 判定 |
|---:|---:|---:|---:|---:|---:|---|
| 10（RTL 推导值） | 138 | **187 / 152 字** | 0 | 921,600 | 59.1% | OK |
| 20 | 148 | 182 / 144 | 0 | 921,600 | 63.4% | OK |
| 40 | 168 | 172 / 129 | 0 | 921,600 | 72.0% | OK |
| 80 | 208 | 152 / 99 | 0 | 921,600 | 89.1% | OK |
| 100 | 228 | 142 / 84 | 0 | 921,600 | 97.7% | OK（极限） |
| 150 | 278 | 117 / 0 | rd2=46 | 614,400 | 119% | FAIL（带宽 >100%） |
| 180 | 308 | 102 / 0 | rd2=45696 | 516,474 | 132% | FAIL |

- 稳态每帧 7200 个突发（读 2×2400 + 写 2400）。RTL 推导的 138 拍/突发下占用 **59.1%**，读 FIFO 最低 **152 字（6.1 µs）**，写侧每帧都能写完一页；
- 即使把每突发开销放大到 100 拍（占用 97.7%），读路径仍有 84 字（3.4 µs）余量、写侧仍能写完；
- 失效点正好落在"带宽需求 > 100%"（开销 ≈130 拍/突发，即 7200×258 > 1,680,000 拍）：写侧先顶不住、读侧随后下溢 —— 与"一次一个突发、总带宽 100 MHz"的物理上限一致；
- 三个地址计数器每帧各走 2400×128 = 307,200 字，回卷点分别落在 0 / 0x4B000 / 0x96000，模型确认**每次回卷都正好在页边界**；
- 模型同时验证"每个写突发发出时 FIFO 里至少 128 字"（`AE=127` 的直接后果），这是 §3.5 的前提 2。

模型运行：`python sim\model_sdram_fb.py [突发开销拍数] [帧数]`。

---

## 11. 假设与风险

| # | 假设/风险 | 依据 | 一旦不成立的现象 | 应对 |
|---|---|---|---|---|
| 1 | **`EG_LOGIC_FIFO` 是 FWFT**：`DO` 在 `RE` 之前就是当前字 | `.ore(0)` + `REGMODE_R="NOREG"`；厂商 `ov5640_sdram_vga` 在同一拍用 `data_rgb` | 画面整体左/右移 1 像素（第一像素错） | 把 `O_video_data` 的采样延后一拍（改 1 行），重编 30 s |
| 2 | 片内 SDRAM 可用、内容掉电不保 | 官方选题指南/安路产品页"内置 64 Mbit SDR"、S 行专用焊盘、`#IO` 只有 7 | 整屏花屏/不变 | 无法软件兜底；需换方案（外部 SRAM） |
| 3 | `SDR_CLK`(270°) 未加 SDC，SDRAM 接口时序由硬宏保证 | 厂商 board_test 的 `timing.sdc` 也只约束像素/串行两路、没管 SDRAM 的 270° 输出，同样出 bit 并上板跑过；`clk1` 只有 1 个负载且走全局时钟网 | SDRAM 读写偶发错字（花点） | 给 `clkc[1]` 补 `create_generated_clock`/`derive_clocks` 后重编 |
| 4 | 读 FIFO 从不下溢（余量 152 字 = 6.1 µs；已把读 FIFO 的 `AF` 从厂商 128 调到 256） | §10 模型 | 画面永久横移/错行（下溢一次就偏 1 字） | 再降读带宽需求，或把 `RD*_LENGTH` 从 128 降到 64（更频繁补水） |
| 5 | 写一页能在 16.78 ms 内完成 | 模型：≈3~5 ms | 该页不置 `page_ok`，显示停在上上页（不花屏，只是不更新） | 提高写优先级/缩小页长 |
| 6 | `pixel_clk` 域 hold 只有 **+3 ps** | 与 M0 同一批路径，`drHoldFix on` 已开 | 上板偶发像素错 | 见 m0-report §8.5：`arr_filter true` 或降频重编 |
| 7 | 12 条 `DRC RTCLK-5079`（`u_sdram/DQM_b*`、`mDATAOUT_b*` 走了局部时钟资源） | 厂商控制器 + 片内 SDRAM 专用布线 | 未知，理论上影响 SDRAM 数据采样 | 未处理；上板若花屏优先怀疑此处 |
| 8 | `key0_n=F7` 按键极性/引脚 | 管脚表 KEY0=F7、低有效 | 手动换页无效（自动换页仍正常） | 只影响演示，不影响 M1 验收 |
| 9 | 首帧前有 ~4 帧（67 ms）黑屏 | 启动时序（§5.3） | 上电后 0.07 s 黑屏，属正常 | — |
| 10 | 自动换页 60 帧 ≈ 1.008 s（59.52 Hz 而非 59.94） | M0 已定 25.000 MHz | 换页周期略长于 1 s | — |

---

## 12. 上板验证清单

> 前提：`m1_sdram_fb.bit` 已用 TD Board Debugger / `bw.exe` 通过 JTAG 下载；显示器能盲锁 640×480@59.5 Hz（板上无 DDC/EDID）。

### 12.1 应该看到什么

| 步骤 | 预期现象 |
|---|---|
| 1. 上电/按 KEY2 | 先黑屏约 70 ms，然后出现画面（不是彩条，而是渐变 + 白竖条 + 彩色边框） |
| 2. 静止观察 | 背景：左暗右亮（红渐变）+ 上暗下亮（绿渐变）+ 蓝色底；四周 8 px 边框 |
| 3. 观察 1 s | 白色竖条每约 1 s 向右跳 8 px；边框颜色在**绿 ↔ 品红**之间每约 1 s 切换一次（这就是换页） |
| 4. 按 KEY0 | 边框颜色立刻（下一帧）切换，节奏与自动换页相同 |
| 5. 长时间 | 画面稳定、无闪烁、无横纹、无整屏抖动（说明读 FIFO 没下溢、PLL 锁定） |

### 12.2 失败判据 → 先查哪里

| 现象 | 最可能原因 | 检查点 |
|---|---|---|
| 全黑，无任何输出 | PLL 未锁 / 复位没释放 | 量 `S_pll_lock`（可临时引到 LED）；确认按过 KEY2 |
| 有 HDMI 信号但全黑 | `S_rd_en`/`S_disp_en` 没起来（`page_ok` 永远 0） | 量写侧 `O_done_tog` 是否有翻转（说明写 FSM 在跑）；查 `WR1_FULL` 是否常高（控制器没在取数） |
| 花屏/雪花 | SDRAM 读写时序问题（风险 3/7） | 先看是不是"全屏随机"（SDR_CLK/布线）还是"规则条纹"（地址错） |
| 画面整体横向偏移 N 像素、行首回卷 | 读 FIFO 相位被破坏（下溢）或写侧丢字 | 见风险 1/4；重点查 `m1_sdram_wr` 的写使能是否组合（本工程已是） |
| 颜色/方向不对（红绿互换、上下颠倒、左右镜像） | 地址顺序或 RGB 位序 | 本设计 R=x、G=y，上暗下亮即 G 正确；左右亮即 R 正确 |
| 只有第一帧有画面、之后不变 | 写侧停了（`WR1_FULL` 常高 / `done_tog` 没回） | 量 `S_wr` 是否有活动；查 `S_page_ok` 是否只有 1 位 |
| 边框颜色不切换 | 换页请求没生效（`page_ok[~disp]` 为 0，或 KEY0 引脚不对） | 自动换页兜底，若仍不切 → `S_swap_div`/`page_ok` 逻辑 |
| 画面局部撕裂（一条横线上下内容不同） | 换页没在场消隐做，或写到了正在显示的页 | 本设计换页只在帧起始；若出现，查 `S_disp_page` 是否被异步改动 |
| 偶发单像素花点 | hold 余量 3 ps / SDRAM 采样 | 见风险 6 |

### 12.3 建议的测量点（ChipWatcher / 临时 LED）

`S_pll_lock`、`S_sdram_ready`、`S_page_ok[1:0]`、`S_disp_page`、`S_rd_en`、`S_disp_en`、`S_wr`（活动即 100 MHz 有写）、`S_wr_full`、`S_rd1_empty`/`S_rd2_empty`（正常应恒 0）、`S_wr_done_tog`。

---

## 13. 与 M1 验收要求的逐条对照

| # | 要求 | 结果 | 证据 |
|---|---|---|---|
| 1 | 复制 M0 工程、改工程名/顶层名、保留 HDMI 链/PLL/IO.adc/timing.sdc | ✅ | `m1_sdram_fb.al`、`m1_top`；HDMI 链 3 文件逐字节相同 |
| 2 | 组装 Sdram_Control_4Port + 7 个子模块（command/control_interface/sdr_data_path/sdram_ip/两个 FIFO/Sdram_PLL） | ✅ | `rtl/sdram_ctrl_4p/` 共 8 个 .v（仅 `Sdram_RD_FIFO.v` 的 AF 阈值 128→256，见 §3.6），`.ipc` 仅作文档 |
| 3 | 写侧自写测试图案，32 bit/像素写页 A | ✅ | `m1_sdram_wr.v`；渐变+移动竖条+边框；每帧 307,200 字 |
| 4 | 读侧从页 A 连续读出拼 RGB888 AXIS 送 HDMI | ✅ | `m1_video_src.v`；`RD1_DATA[23:0]` → AXIS；`VIDEO_TPG="Disable"` |
| 5 | 页 B + "写 B 同时显示 A" + 场消隐换页 | ✅ | 环形写 + 双读端口 + 帧起始 mux；§5.4/§5.5 |
| 6 | HDMI 640×480@~59.5 Hz 参数不变 | ✅ | 800×525/25.000 MHz，帧率 59.52 Hz |
| 7 | 编译到 `phy_1/*.bit`，报告资源与时序（三域 WNS） | ✅ | §8/§9（实际 **四个** 时钟域） |
| 8 | 无仿真器时做代码级推演并写进报告 | ✅ | §3.4/§3.5/§4.2/§5.2/§5.3 + §10 周期模型 |

---

## 14. 下一步（M2 衔接）

1. **写侧换数据源**：`m1_sdram_wr` 的 `S_pat` 换成"BMP 像素流"接口（`data/valid/ready`），写地址计数器与环形逻辑可原样保留；M2 只需要保证"一帧 307,200 字、按光栅顺序"。
2. **换页策略升级**：M2 切图时应当"等新页写完再切"，把现在的 `page_ok` 位扩展成"页序号 + 完成计数"，避免连续切图时显示旧页。
3. **上板回归 M0 的遗留项**：串行时钟相位（39.375°）、`tlast`、hold 3 ps —— 这些在 M1 里原样继承，一旦上板出现雪花/抖动，按 m0-report §8 的顺序排查。
4. 若要把 SDRAM 占用率再降一档，可把两个读端口改成"只读当前显示页 + 换页时重建相位"（需要给控制器加 FIFO 清除能力，属改厂商代码，风险更高，暂不做）。

---

## 15. 附录：关键日志

综合（`syn_1/console_ci.log`）：

```
HDL-1007 : elaborate module m1_top in ../../rtl/m1_top.v(33)
HDL-1007 : elaborate module Sdram_Control_4Port in ../../rtl/sdram_ctrl_4p/Sdram_Control_4Port.v(1)
HDL-1007 : elaborate module EG_PHY_SDRAM_2M_32 in E:\arch/eagle_macro.v(683)
RUN-1001 : Open license file E:/license/Anlogic.lic
TD_FLOW_OK
```

布局布线 + bitgen（`phy_1/console_ci.log`）：

```
RUN-1003 : finish command "place" in  5.747153s wall
RUN-1003 : finish command "route" in 14.681717s wall
BIT-1003 : Generate bitstream completely, there are 66907 bits set as '1'.
BIT-1004 : PLL setting string = 0011
BIT-1004 : Generate bits file m1_sdram_fb.bit.
TD_FLOW_OK
```

时序（`phy_1/m1_sdram_fb_phy.ts`）：

```
SWNS: 2.174ns, STNS: 0.000ns.
HWNS: 0.003ns, HTNS: 0.000ns.
```
