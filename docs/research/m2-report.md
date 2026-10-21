# M2 里程碑报告：TF 卡(SPI) → FAT32 → 640×480 BMP → SDRAM 页 B → 切页显示

- 日期：2026-10-21
- 状态：**编译验收通过（bit 已生成，全清编译可复现）**；功能未上板实测（本机无板卡）
- 工程：`E:\fpga-2026\dsh_code\proj\m2_sd_tf_bmp\`（新建，纯英文路径）
- 依据：`docs/specs/2026-10-21-hdmi-basic-player-design.md` §4–§7、
  `docs/research/m1-report.md`、`m0-report.md` §4/§7、`example-arch.md` §7
- 原始资料 `E:\fpga-2026\选题一-EG4S20-HX4S20C官方例程\` **只读未改**
  （SD 引擎 16 个文件 + HDMI 链 3 个 + SDRAM 控制器 8 个，全部逐字节拷贝，SHA256 比对通过）

---

## 0. 结论速览

| 项 | 结果 |
|---|---|
| 工程/顶层 | `proj/m2_sd_tf_bmp/m2_sd_tf_bmp.al`，顶层 `m2_top`，**16 个 IO** |
| 新增 IO | SD_CLK=M2 / SD_MOSI=L3 / SD_MISO=K6 / SD_CS=R2；KEY0=F7、KEY1=E7、KEY2=H14（复位）；LED0–3=M12/R16/R15/T15 |
| SD 层 | 厂商 `sd_card_control` **原样复用**（SPI Mode3，400 kHz 初始化 → 25 MHz 读），外面加"起/扇区号/完成 + 看门狗"封装，超时复位引擎 |
| 文件层 | FAT32-lite 只读：MBR（或 superfloppy）→ BPB → 根目录**簇链** → 32 字节/项的目录项 → FAT 链 → 扇区序列 |
| BMP | 校验 `BM`/biSize=40/640×480/24bpp/comp=0；`bfOffBits` 任意（调色板按扇区跳过）；**自底向上** → 逐行反序写入 |
| 写页 | **逐行 `WR1_LOAD`**（替代 M1 的环形写），一行 5 个 128 字突发，行末等 4096 拍保证写 FIFO **恰好空** |
| 双缓冲 | 只写"不在显示"的那一页，写完 → 25 MHz 域在**场消隐**切页，不撕裂 |
| 交互 | KEY0 下一张 / KEY1 上一张（10.5 ms 消抖）；无卡/无图/坏图 → 回退 M1 测试图案；4 个 LED 指示状态 |
| 编译 | 全清编译 **67.5 s**，`TD_FLOW_OK`，退出码 0；**两次独立全流程编译（第二次是全清）1057 行 payload 逐行一致、Bitstream CRC 相同** |
| bit | `m2_sd_tf_bmp_Runs/phy_1/m2_sd_tf_bmp.bit`，629,635 B，`Design name: m2_top` |
| 资源 | LUT **4458/19600 (22.74%)**、FF **3939/19600 (20.10%)**、BRAM **17/64 (26.56%)**、PLL 2/4、GCLK 6/16、IO 16/188 |
| 时序（final/routed） | Setup **WNS +0.155 ns**（100 MHz 域 5449 个端点 0 违例），Hold **WNS +0.011 ns**；4 个时钟域全部收敛，无跨域路径组 |
| 非仿真验证 | 自写 `sim/model_fat32_bmp.py`：造 FAT32 卡 + 照抄 RTL 状态机，**80 项检查全通过**（方向/颜色/页地址/每行 5 突发/行末 FIFO 必空/DRAIN 上界/6 种失败回退） |
| 加载速度 | 模型统计 **2030 扇区/张**（1801 数据 + 226 FAT + 3 挂载），纯 SPI 时间 **0.386 s**（不含卡内读延迟） |
| 遗留风险 | 未上板；SD 引擎的 50 MHz 分频时钟**无法加 SDC**（见 §15 R1）；100 MHz 域 setup 只有 0.155 ns、hold 11 ps（布线受限，非逻辑深度） |

---

## 1. 工程结构与文件来源

```
proj/m2_sd_tf_bmp/
├── m2_sd_tf_bmp.al              TD 工程文件（TD_Version 必须是数字版号 6.2.190657）
├── IO.adc                       引脚约束（16 个 IO）
├── timing.sdc                   时钟约束（50 / 25 / 125 / 100 MHz + 4 组 exclusive）
├── run_flow.tcl                 DefaultFlow 的 CI wrapper（TD_FLOW_OK / exit 1）
├── build.ps1                    一条命令全清重编
├── make_proj_files.ps1          由文件清单生成 .al / .prj / settings.cfg（工程可重复生成）
├── README.md                    工程速览 / 使用 3 步
├── rtl/
│   ├── m2_top.v                 顶层（新写）
│   ├── m2_video_src.v           光栅 + 页选择 + 按键消抖 + AXIS 源，25 MHz（新写）
│   ├── m2_page_wr.v             逐行 LOAD 的整页写入器，100 MHz（新写）
│   ├── m2_sd_sec.v              sd_card_control 封装 + 看门狗（新写）
│   ├── m2_byte_seq.v            扇区 → N 字节寄存器（新写）
│   ├── m2_pix_pump.v            扇区 → 24 bit 像素流（新写）
│   ├── m2_fat_bmp.v             FAT32-lite + BMP 校验 + 主控 FSM（新写，最大模块）
│   ├── sd_spi/                  ← 厂商 SD 卡 SPI 引擎 16 个文件（逐字节原样）
│   ├── sdram_ctrl_4p/           ← 厂商 SDRAM 控制器 8 个文件（M1 已改 AF 128→256）
│   ├── hdmi_phy_warpper.v       ← 厂商原样
│   ├── lane_lvds_10_1.v         ← 厂商原样
│   └── hdmi1.4b_transmitter_core/hdmi_1_4b_transmitter_core_wrapper.enc.v  ← 厂商加密 IP
├── al_ip/pll_m2_hdmi/           HDMI PLL（M1 原样改名，M0 推导的 25.000/125.000 MHz）
├── sim/model_fat32_bmp.py       离线 FAT32/BMP/RTL 模型 + 测试向量生成（80 项检查）
└── m2_sd_tf_bmp_Runs/{syn_1,phy_1}/
```

SD 引擎 16 个文件（`sd_card_control` 及子模块）从
`...\02-uart_sd_rw串口读写SD卡\AC201_AL_uart_sd_rw\rtl\` 拷贝，**SHA256 逐个比对全部相同**，
**一个字都没改**（连 GBK 中文注释都原样保留——这是本工程唯一保留非 UTF-8 的文件组，
TD 解析正常，见 §12.4）。

与 M1 的差异：顶层换名 `m2_top`；`m1_video_src/m1_sdram_wr` 删除，换成 `m2_*` 六个新文件；
新增 SD 4 根 + KEY1 + LED 4 个引脚；`timing.sdc` 不变（spi_clk 的尝试见 §15 R1）；
`IO.adc` 从 7 个 IO 增到 16 个。

---

## 2. 系统架构、时钟与复位

```
                  ┌──────────────────────── 25 MHz 像素域 ─────────────────────────┐
 50 MHz ─pll_m2_hdmi─┤ 25.000 MHz ── m2_video_src ──AXIS──> hdmi_1_4b_core ──> phy ──> TMDS
   K14            │                │  ▲  ▲                                            │
                  │                │  │  └── RD1_DATA / RD2_DATA（各 32 bit）            │
                  │                │  └────── RD1 / RD2（每个有效像素 1 次）              │
                  └────────────────┼──────────────────────────────────────────────────┘
                                   │ 页选择 / ready 翻转 / 按键翻转（2FF + 边沿）
 50 MHz ─> Sdram_Control_4Port ────┴──── 100 MHz 域
              │  Sdram_PLL: 100 MHz / 100 MHz 270°
              │  RD1 FIFO ← 页 A      RD2 FIFO ← 页 B      WR1 FIFO ← m2_page_wr
              ├── EG_PHY_SDRAM_2M_32（片内 8 MB）
              └── m2_sd_sec（sd_card_control）─> 512×8 扇区缓冲
                        ├─ m2_byte_seq（FAT32 结构 → 寄存器）
                        └─ m2_pix_pump（BMP 负载 → 像素）
                              └─> m2_fat_bmp（主控 FSM）──> m2_page_wr ──WR1──> 页 A/B
```

### 2.1 时钟域

| 时钟 | 频率 | 来源 | 用途 |
|---|---:|---|---|
| `clk` | 50 MHz | 板载晶振 K14 | 两个 PLL 的参考、KEY2 同步 |
| `pixel_clk` | 25.000 MHz | `pll_m2_hdmi` C1 | 光栅/页控制/AXIS、HDMI 核、两个读 FIFO 的读时钟 |
| `serial_clk` | 125.000 MHz | `pll_m2_hdmi` C2（39.375°） | 4 路 TMDS 串行器 |
| `sdram_clk` | 100.000 MHz | `Sdram_Control_4Port` 内部 `Sdram_PLL` C0 | 控制器 + **SD SPI 引擎 + FAT32 FSM + 扇区缓冲 + 写页器** |
| `SDR_CLK` | 100.000 MHz/270° | 同上 C1 | 只送片内 SDRAM 宏 |
| `spi_clk` | 50 MHz（数据）/ 0.8 MHz（初始化） | `sd_card_control` 内 `clk_div_var` | SPI 移位（`spi_driver` 再二分频 → 25 MHz / 400 kHz 的 SCLK） |

**为什么 SD 引擎也放在 100 MHz 域**：`sd_card_control` 的分频是
`spi_div = clock_freq/(freq*2)`，参数必须与真实时钟一致；25 MHz 高速档要 `div=2`，
若主频取 50 MHz 则 `div=1`，而 `clk_div_var` 被例化时 `one_allow=0`（不支持 1 分频）→
`spi_clk` 恒 0。所以沿用厂商的 100 MHz 用法。

### 2.2 跨域（三类，全部显式）

1. **数据流**：写/读 FIFO 是 512×32 异步 FIFO（`EG_LOGIC_FIFO`），真正的跨域通路在宏里；
   扇区缓冲 `RD_RAM` 是**双时钟 RAM**（写 `spi_clk`、读 `sdram_clk`）。
2. **控制**：
   - 25 MHz → 100 MHz：`key_next_tog` / `key_prev_tog`（翻转 + 3FF 同步 + 异或边沿）、
     `disp_page`（整页稳定的电平，2FF）、`ready_tog` / `ready_page`（翻转 + 电平，2FF）。
   - 100 MHz → 25 MHz：`disp_page`、`ready_tog`（2FF + 边沿）、`sdram_ready`（2FF）。
   - `ready_page` 在 `ready_tog` 翻转**前 4 个 100 MHz 周期**就稳定，25 MHz 侧再过 2FF
     （≥80 ns），保证不会被采到中间值。
3. **复位**：KEY2 → 50 MHz 2FF → 与 `pll_lock` 相与 = `S_rst_n_async`；再在每个时钟域
   "异步置位、同步释放"；SDRAM 域额外延后 1.31 ms 等内部 `Sdram_PLL` 锁稳。

### 2.3 复位顺序

```
KEY2 释放 & PLL lock
   ├─ pixel_clk  2FF  → 光栅 + HDMI 核
   ├─ serial_clk 2FF  → TMDS 串行器
   └─ 1.31 ms 后 → sdram_clk 2FF → 控制器 + SD 引擎 + FAT32 FSM + 写页器
                        └─ 控制器 240 µs 初始化 → 读 FIFO 被填满
                        └─ FAT32 FSM 再等 10 ms（1e6 拍）才开始发 CMD0
```

---

## 3. SD SPI 层（`rtl/m2_sd_sec.v`）

厂商 `sd_card_control` 的接口本身就是"一个事务 = 一个 512 B 扇区"，M2 只在外面包一层：

```verilog
m2_sd_sec u_sd (
    .I_init(1 = 初始化卡 / 0 = 读扇区), .I_start(1 拍脉冲), .I_lba(32 bit LBA),
    .O_busy, .O_done(1 拍), .O_err(1 拍),
    .I_ram_addr(9 bit), .O_ram_dout(8 bit),        // 512×8 缓冲区读口（100 MHz 侧）
    .O_sd_clk(M2), .O_sd_mosi(L3), .O_sd_cs_n(R2), .I_sd_miso(K6));
```

* **参数**：`clock_freq=100_000_000, spi_lowfreq=400_000, spi_highfreq=25_000_000`
  → `spi_div = 125`（初始化，SCLK 400 kHz）/ `2`（数据，SCLK 25 MHz）。
* **时序**：SPI **Mode 3**（`spi_driver` 例化时 `mode=2'b11`）。
* **命令**：初始化 `CMD0(0x40) → CMD8(0x48) → CMD55(0x77) → ACMD41(0x69)`
  （`sd_init.v` 里硬编码，未读 OCR、未切 4 bit）；读扇区 `CMD17`（`sd_write_addr` 的
  `8'h58 - mode*7`，mode=1）。写扇区（CMD24）路径保留但**不用**。
* **看门狗**：没有卡时厂商 FSM 会永远等 R1/0xFE（`sd_init` 还会无限重试 CMD0），
  所以加两级超时：
  - 扇区事务 `2^22 = 41.9 ms`（正常 190 µs，余量 220×）；
  - 卡初始化 `2^28 = 2.68 s`（SD 规范允许 1 s）。
  超时后把 `rst` 打一拍**复位整个 SD 引擎**（厂商模块没有 abort），置 `O_err`。
  没有这层，插空卡上电会永久黑屏。
* **缓冲区读口**：`rd_ram_dout(t+1) = RD_RAM[rd_ram_addr(t)]`，即**同步读、1 拍延迟**，
  这是 `m2_byte_seq` / `m2_pix_pump` 时序设计的基准（先给地址、下一拍取数）。

---

## 4. FAT32-lite（`rtl/m2_fat_bmp.v`）

### 4.1 支持范围（**重要**，与验收要求逐条对应）

| 项 | 支持 | 说明 |
|---|---|---|
| 分区表 | ✅ MBR 第一个匹配分区 | 分区类型 `01/04/06/0B/0C/0E`，取**第一个**类型匹配且 LBA≠0 的项；也支持**superfloppy**（BPB 直接在 LBA 0，偏移 82 处是 `"FAT32"`，无分区表） |
| 文件系统 | ✅ **仅 FAT32** | 要求 `BPB_BytsPerSec=512`、`BPB_FATSz16=0`、`BPB_FATSz32≠0`、`BPB_RootClus≥2`、`NumFATs=1..2`、`SecPerClus` 是 2 的幂且 ≤128。exFAT / FAT12 / FAT16 一律拒绝（`err=2`，回退图案） |
| 目录 | ✅ **仅根目录** | 不支持子目录（子目录项被跳过）；**根目录按簇链走**（FAT32 的根目录不是固定区域） |
| 目录项 | 8.3 短名 | 跳过 `0xE5`（删除）、`0x0F`（LFN 长文件名）、`attr&0x10`（目录）、`attr&0x08`（卷标）、`'.'`；`name[0]==0x00` 视为目录结束 |
| 文件数 | **最多 16 个 `*.BMP`** | 收满 16 个立即停止扫描；超出部分不索引 |
| 扩展名 | 大小写都接受 | `BMP` / `bmp`（`0x42/0x62`、`0x4D/0x6D`、`0x50/0x70`） |
| 排序 | 按 `IMGnnnn` 的 4 位编号 | 见 §4.4；不符合 `IMGdddd.BMP` 的名字键值 = `0xFFFF`，排在最后（按目录顺序） |
| 簇号 | 28 bit（`0x0FFFFFFF` 掩码） | 与 FAT32 规范一致 |
| LBA | 28 bit（≤ 128 GB 卡地址空间） | 来自 `sd_card_control` 的 `sector_addr[27:0]` |
| 写操作 | ❌ 完全没有 | 只读，不碰 FAT/目录 |

### 4.2 扇区/簇换算

```
PART_LBA   = MBR 分区项 offset 446+8 的 4 字节（superfloppy 时为 0）
FAT_LBA    = PART_LBA + RsvdSecCnt
DATA_LBA   = PART_LBA + RsvdSecCnt + NumFATs * FATSz32
簇 N 的第 k 个扇区： LBA = DATA_LBA + ((N-2) << log2(SecPerClus)) + k     (N >= 2)
簇 N 的 FAT 项  ： 扇区 FAT_LBA + (N >> 7)，字节偏移 (N & 127) * 4，取低 28 bit
链结束(EOC)     ： 值 >= 0x0FFFFFF8
```

`log2(SecPerClus)` 由 §4.1 的合法性检查保证存在（1..128 → 0..7）。
RTL 里就是一条 32 bit 减法 + 变量移位 + 两级加法：

```verilog
wire [31:0] S_clus_off = (S_clus - 32'd2) << S_log2spc;
wire [31:0] S_dir_sec  = S_data_lba + S_clus_off + {24'd0, S_sec};
```

### 4.3 读一个结构的固定流程

每个扇区/字段的访问都是 `issue → wait → consume` 三拍式，且**参数比 start 脉冲早一拍**：

```
S_xxx    : O_sd_lba <= <算出的 LBA>;  S_rd_ret <= <回来后的状态>;  → S_RD1
S_RD1    : O_sd_start <= 1;                                        → S_RD_W
S_RD_W   : I_sd_done → S_rd_ret   /   I_sd_err → S_ERR
```

（因为 `m2_sd_sec` / `m2_byte_seq` / `m2_pix_pump` / `m2_page_wr` 都在 start 那一拍的
时钟沿采样参数，参数必须在 start 之前就稳定——这是本工程最容易写错的一处，
所以把"发起"单独做成一个状态。）

字节访问用 `m2_byte_seq`：把扇区里从 `off` 起的 `cnt`（≤34）个字节搬进 272 bit 寄存器，
`I_bs_val[8*i +: 8]` 就是偏移 `off+i` 的字节，于是所有字段都是一句常量切片：

```verilog
wire [15:0] W_bps     = {B[1], B[0]};                  // off 11,12 BytsPerSec
wire [31:0] W_fatsz32 = {B[7], B[6], B[5], B[4]};      // off 36..39
wire [31:0] W_rootc   = {B[15],B[14],B[13],B[12]};     // off 44..47
wire [31:0] W_e_clus  = {B[21],B[20],B[27],B[26]};     // 目录项簇号 hi/lo
```

### 4.4 文件列表与"排序"

第一版用 16 项**组合插入排序**（16 个 16 bit 比较器 + 优先级编码 + 16:1 移位），
phy 报 **WNS −5.066 ns**，关键路径 14.8 ns：
`sector byte → 数字检查 → key mux → 16 比较器 → 优先级 → 16:1 写数组`。

改成：**列表按目录顺序追加（不排序）**，"下一张/上一张"用一次**串行 min/max 扫描**
回答（每项 2 拍，一次按键 ~32 拍，完全看不见）：

| 操作 | 规则 |
|---|---|
| 上电第一张 | 键值最小的那一项（扫描时 `ref=0xFFFF`，自然退化为全局最小） |
| KEY0 下一张 | 键值 **> 当前键值**里最小的；没有则回绕到全局最小 |
| KEY1 上一张 | 键值 **< 当前键值**里最大的；没有则回绕到全局最大 |
| 键值 | `IMGdddd.BMP` → 4 个十进制数字拼成 16 bit（每半字节 0..9，数值大小与十进制一致）；其它名字 → `0xFFFF`（排最后） |

扫描一行一个比较器（16 bit），读数组**打一拍寄存**，因此即使 TD 把 16 项数组映射成
RAM 也仍然正确；同时省掉 15 个比较器和 1216 个移位 mux。

---

## 5. BMP 解析与像素流

### 5.1 头校验（34 字节，全在第一扇区里）

| 字段 | 偏移 | 要求 |
|---|---|---|
| `bfType` | 0..1 | `BM` |
| `bfOffBits` | 10..13 | ≥ 54，任意值（调色板/前缀按扇区整块跳过，见 §5.3） |
| `biSize` | 14..17 | 40 |
| `biWidth` | 18..21 | 640 |
| `biHeight` | 22..25 | **+480（自底向上）或 −480（自顶向下）** |
| `biBitCount` | 28..29 | 24 |
| `biCompression` | 30..33 | 0（BI_RGB；RTL 只比较低 16 bit，高 16 bit 非 0 意味着压缩方式极大，现实中不存在） |

任一项不符 → `err=4`，**不写页**，直接换列表里的下一张（最多试 `count` 次），
全部失败才回退图案。目录项的 32 bit 文件大小只做健全性检查（`err=6`，不拒绝），
像素数固定为 640×480×3 = 921 600 B（1800 个整扇区）。

### 5.2 逐扇区流式读 + 像素打包（`rtl/m2_pix_pump.v`）

* **字节相位跨扇区保留**：一行 1920 B、一个扇区 512 B，`512 mod 3 = 2`，所以一个像素
  经常横跨两个扇区。`pump` 的 `phase`(0/1/2) 与已收的 B/G 两个字节是**模块级状态**，
  扇区结束不清零。
* **BGR → RGB**：BMP 负载是 `B,G,R`，输出字 = `{8'h00, R, G, B}`（低 24 位 RGB888），
  与 M1 的帧缓存格式一致。
* **节流**：每 3 字节凑成一个像素后，若写页器暂时不收（行末 `DRAIN` 或 `WR1_FULL`），
  泵停在原地（地址寄存器保持不变，同步 RAM 会一直输出同一个字节，重读安全）。
* **首扇区偏移**：`bfOffBits` 用 32 bit 倒计数处理——`skip ≥ 512` 就整扇区丢掉并前进，
  否则从 `skip` 处开始、本扇区取 `512-skip` 字节。渲染 640×480 24 bit 时典型 `bfOffBits=54`
  → 首扇区从 54 取到 511（458 字节）。

### 5.3 数据扇区的推进（`S_DSEC / S_ADV / S_CFAT`）

```
S_DSEC : pixleft==0 → S_DEND
         skip >= 512 → skip-=512，不读扇区，→ S_ADV      （跳过调色板）
         否则 → 读 (簇,sec) 扇区 → S_PP_W
S_PP_W : pump 完成 → S_ADV
S_ADV  : pixleft==0 → S_DEND                  ← 图已读完就不再走 FAT（省 1 次扇区读）
         sec+1 >= spc → S_CFAT（读 FAT 取下一个簇）
         否则 sec++ → S_DSEC
S_CFAT : 读 FAT 扇区 → 读 4 字节 FAT 项 → 下一个簇 → S_DSEC（EOC 则 err=5 + 黑色补齐）
```

---

## 6. 写页：为什么必须"逐行 `WR1_LOAD`"（M2 最关键的设计决策）

### 6.1 问题：BMP 是自底向上的，而写端口只能顺序写

BMP（`biHeight>0`）文件里第一行是图像的**最后一行**。显示必须自上而下光栅扫描，
所以页里必须 `y=0` 在前。但 `Sdram_Control_4Port` 的写端口是**严格顺序**的地址计数器，
而两个读端口也是顺序的——**任何一侧都无法把整页行序倒过来**，除非整帧缓存一次
（900 KB，片内 BRAM 装不下，也没有第三个读端口能做"回读再倒序"）。

### 6.2 解法：一行一次 `WR1_LOAD`

```
一行的字地址 = 页基址 + y*640          （640 = 5×128，行基址必然 128 字对齐）
行内突发     = 5 个 128 字突发，起址 = 行基址 + {0,128,256,384,512}
```

自底向上时**先写第 479 行**（文件第一行），一路递减到第 0 行。这样文件顺序天然对应
递减的行地址，**像素流不需要任何行缓存**。自顶向下（`biHeight<0`）时行地址递增。

### 6.3 为什么逐行 LOAD 是安全的（M1 §3.4 的坑不会再踩）

M1 之所以不敢用 `WR1_LOAD`，是因为"写 FIFO 里最多残留 127 个上一页的字，LOAD 后会写到
新页开头"。M2 用三条性质把它消掉：

1. **每行恰好 640 字 = 5×128**。FIFO 只会在 `usedw ≥ 128` 时发一个 128 字突发
   （`Sdram_WR_FIFO.v` 的 `AE=127`），所以任何时刻 FIFO 里的字数**永远是 128 的整数倍**；
   一行写完并排空后必为 **0**（不可能残留 1..127 个字）。→ 行边界上 LOAD 绝对干净。
2. **行末等 4096 拍（`DRAIN`）再 LOAD**。最后一个像素被接收时最多还有 3 个突发没发
   （`AF=378` → ≤378 字）；仲裁优先级 `RD1 > RD2 > WR1`，最坏一个写突发被两个读突发
   插队：`3 × (138 + 2×138) = 1242 拍 < 4096`。模型实测每行行末 FIFO 残留 = 0。
3. **`WR1_LOAD` 不影响在飞的突发**：`rWR1_ADDR` 立即更新，但当前突发用的是启动时锁存的
   `mADDR`，所以即使 LOAD 落在突发中间也不会写错地址（我们仍然只在排空后 LOAD）。

代价：480 行 × 41 µs ≈ **19.7 ms/页**，占一张图 0.39 s 的 5%。

### 6.4 失败路径也是确定的

任何中断（链提前结束 `err=5`、扇区读超时 `err=1`）都走 `I_flush`：写页器忽略像素、以
1 字/拍把**剩下的整页填黑**再报完成。这样"每次写页 = 480 次 LOAD + 307 200 字"的
不变量永远成立，下一次写页从干净状态开始；坏页永远不会被标成 ready（不会被显示）。

---

## 7. 显示侧与换页（`rtl/m2_video_src.v`）

沿用 M1 的双读端口 + 场消隐换页架构，**只把"写侧数据源"和"换页触发"换掉**：

* 两个读端口 RD1/RD2 依旧**每有效像素各读 1 字**（`rd1_re = rd2_re = active && rd_en`），
  两路永远与光栅同相；换页只是把 AXIS 数据源从 RD1 切到 RD2（寄存器 mux），
  读 FIFO 相位一动不动 → 不会撕裂、不会偏移。
* **写哪一页**：`target = ~disp_page`（装载前采样 25 MHz 域送来的 `disp_page`）；
  因为换页只由装载器的 ready 触发，装载期间不可能发生换页，所以"**永远不写正在显示的那页**"
  由构造保证。
* **换页时机**：装载完成 → `ready_page` + `ready_tog`（间隔 4 个 100 MHz 周期）→
  25 MHz 域打 2FF，在**帧起始（场消隐）**把 `disp_page` 翻过来。
* **启动丢一帧**（M1 §5.3 的结论照搬）：读 FIFO 在复位时就把 SDRAM 里的旧内容预取了
  ≤512 字，所以第一次消费的那一帧强制黑屏、且正好消费 307 200 字（= 一个页长），
  一帧后读地址计数器回到页基址，第一帧可见画面就是干净对齐的。
* `page_ok[2]`：只有装载器点亮过的页才会被选中，上电第一帧之前一直黑屏。
* 按键：25 MHz 采样 + 18 bit 计数（2^18 × 40 ns = **10.5 ms**）消抖，按下产生一个翻转。

---

## 8. 主控状态机（`rtl/m2_fat_bmp.v`）

```
S_POR ──sdram_ready──> S_BOOT(10 ms) ─> S_INIT1/W(CMD0/CMD8/CMD55/ACMD41)
                                          │ 超时 → S_ERR(err=1) → 图案
                                          ▼
S_MBR ──> S_FS_C ──"FAT32"?──> S_BPB_W（superfloppy 直接用本扇区）
              └─否─> S_PENT_C（4 个分区项逐个查类型）
                        └─找到─> S_BPB ─> S_BPB_W ─> S_BF1_C ─> S_BF2_C（校验 BPB）
                                                                  │ 不合法 → S_ERR(err=2) → 图案
                                                                  ▼
S_DIR ─> S_DIR_W ─> S_ENT ─> S_ENT_C ─┬─ 命中 *.BMP：追加到列表（≤16）
                                       ├─ 0x00 结束 / list full → S_SEL
                                       └─ 本扇区 16 项走完 → S_DIRN ─┬─ 还有扇区 → S_DIR
                                                                     └─ 簇用完 → S_DFAT（FAT 链）
S_SEL（count==0 → 图案）─> 串行扫描选图 ─> S_SCAN_W ─> S_HDR ─> S_HDR_W ─> S_HF_C（BMP 头）
                                                                         │ 好 → S_WR1 → S_DSEC…
                                                                         └ 坏 → 换下一张 / 图案
S_DSEC ⇄ S_PP_W / S_ADV / S_CFAT（逐扇区流式读）──> S_DEND（等写页完成，必要时 flush）
──> S_SW0/S_SW1（ready_page + 翻转）──> S_SHOW（等 25 MHz 域真的换页）──> S_KEY
S_KEY ──KEY0/KEY1──> 扫描选图 ─> …, 无卡时任意键 → 重新 S_BOOT（重试挂载）
S_PAT0/S_PAT/S_PAT_E：M1 测试图案（渐变 + 绿边框）整页写入（无卡/无图/全坏时的回退）
S_ERR：装载中出错 → flush 补黑；否则 → 图案或 S_KEY
```

对应验收要求的 `IDLE → SCAN → LOAD → SWAP → IDLE`：`S_KEY`(=IDLE) → `S_SEL/S_DIR`
(=SCAN) → `S_HDR…S_DEND`(=LOAD) → `S_SW0/S_SHOW`(=SWAP) → `S_KEY`(=IDLE)，
**加载全过程显示旧页**（`disp_page` 只在 SWAP 阶段动）。

### 8.1 错误码与 LED

| `O_err` | 含义 |
|---:|---|
| 0 | 正常 |
| 1 | 卡初始化/扇区读超时（无卡、卡坏、接触不良） |
| 2 | 挂载失败（MBR/BPB 不合法，或不是 FAT32） |
| 3 | 卡里没有 `*.BMP` |
| 4 | BMP 头不合法（这张被跳过，最终回退图案） |
| 5 | FAT 链提前结束（图被截断，其余补黑） |
| 6 | 目录项的文件大小 < `bfOffBits+921600`（仍按 640×480 读，缺的补黑） |

LED（`led[0..3] = M12/R16/R15/T15`，**极性未实测**，代码按高有效驱动）：

| LED | 含义 |
|---|---|
| `led[0]` | 挂载成功（BPB 通过） |
| `led[1]` | 写页器忙（正在加载，~0.4 s 闪一下） |
| `led[2]` | 最近一次操作有错误（`O_err≠0`） |
| `led[3]` | 当前显示页（0=页 A，1=页 B），每次换页翻转 |

---

## 9. PC 侧工具：`E:\fpga-2026\dsh_code\tools\make_bmp.py`

```powershell
python make_bmp.py 图1.jpg 图2.png -o D:\card      # -> IMG0001.BMP IMG0002.BMP
python make_bmp.py 图片目录 --start 7             # -> IMG0007.BMP ...
python make_bmp.py a.png --fit stretch            # 拉伸（默认 pad = 保持比例加黑边）
python make_bmp.py --check IMG0001.BMP            # 只校验，按 RTL 的规则判定
```

* **手写 BMP 头 + BGR 像素**，不依赖 Pillow 的 BMP 编码器 → 输出字节确定（可 `--check` 复核）；
* 输出：921 654 B = 54 B 头 + 640×480×3；`bfOffBits=54`、`biSize=40`、自底向上、未压缩；
* 8.3 文件名 `IMG%04d.BMP`，支持批量与起始编号；
* 打印"拷贝到 FAT32 TF 卡根目录"的完整说明（含 Windows 只能格式化 ≤32 GB 卡为 FAT32 的提醒）。

本机 `C:\Users\31860\...\Python312\python.exe` 为 3.12.10，**Pillow 12.3.0 已安装**，
无需额外 `pip install`（脚本在没有 Pillow 时会打印安装命令）。

---

## 10. 离线验证：`sim/model_fat32_bmp.py`（本机无 Verilog 仿真器）

和 M1 的 `model_sdram_fb.py` 同一思路：**把 RTL 的行为照抄成 Python，用真数据跑通链路**。

### 10.1 三部分

1. `Fat32Builder`：在内存里造一张 FAT32 卡（MBR + BPB + 两份 FAT + 根目录 + 文件），
   可造碎片簇链、LFN 项、0xE5 删除项、子目录项、非 BMP 文件、坏 BMP、带调色板前缀的 BMP、
   截断的簇链；`spc` 与簇数可配。
2. `RtlModel`：逐条照抄 `m2_fat_bmp.v` 的状态机（挂载 → 目录扫描 → 串行选图 → BMP 头校验 →
   逐扇区流式读 → 3 字节装一个 `{0,R,G,B}` → 每行 `LOAD` 写页），并用"128 字突发"模型
   模拟 Sdram 写侧（FIFO 深度、突发数、行末残留）。
3. 检查项：图像方向/颜色、页地址覆盖、每行 LOAD 一次且 128 字对齐、每行正好 5 个突发、
   **每个行边界写 FIFO 残留必须为 0**、`DRAIN` 上界、以及 6 类失败回退。

### 10.2 场景与结果（**80 项检查全部 PASS**）

| 场景 | 内容 | 关键结论 |
|---|---|---|
| 1 | 标准 IMG0001.BMP，spc=8 | 2030 扇区/张，0.386 s；页内容与源图**逐字节相同**（方向/颜色都对） |
| 2 | 碎片簇链（每 2 簇跳一次）+ LFN + 0xE5 + 子目录 + 非 BMP + 坏 BMP | 只索引 3 个真 BMP；碎片链照样解码正确；next/prev/回绕都对 |
| 3 | `bfOffBits=1078`（调色板）+ **spc=1**（最坏簇换算） | 跳过 2 整扇区后从偏移 54 开始；3607 扇区（0.685 s）仍正确 |
| 4 | 卡里只有 README.TXT | `err=3` → 回退图案；左上角 `0x00FF00` 绿边框、中心渐变公式逐字对上 |
| 5 | FAT16 的 BPB | `err=2` 拒绝 → 图案 |
| 6 | 簇链只连了 100 个簇（截断） | `err=5`，缺的 170 685 字**填黑**，页仍写满 |
| 7 | 根目录 20 个 BMP | 只收前 16 个（`MAXF`） |

运行：`python sim\model_fat32_bmp.py`（`-v` 打印每一步扇区/FAT；`--dump-page` 把解码结果
写成 PNG，需要 Pillow）。

---

## 11. 编译

### 11.1 一条命令

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\fpga-2026\dsh_code\proj\m2_sd_tf_bmp\build.ps1
```

等价于（必须分别 `cd` 进两个 run 目录）：

```powershell
cd ...\m2_sd_tf_bmp\m2_sd_tf_bmp_Runs\syn_1
E:\bin\td_commands_prompt.exe E:/fpga-2026/dsh_code/proj/m2_sd_tf_bmp/run_flow.tcl
cd ..\phy_1
E:\bin\td_commands_prompt.exe E:/fpga-2026/dsh_code/proj/m2_sd_tf_bmp/run_flow.tcl
```

### 11.2 耗时（**全清编译**：两个 run 目录只留 `settings.cfg` + `m2_sd_tf_bmp.prj`）

| 阶段 | 内容 |
|---|---|
| syn_1 | read_design(elaborate) + optimize_rtl + optimize_gate |
| phy_1 | opt_place + opt_route + bitgen |
| **合计 wall** | **67.5 s**（另一次 60.4 s / 84.4 s，取决于机器负载） |

### 11.3 bit 与可复现性

```
E:\fpga-2026\dsh_code\proj\m2_sd_tf_bmp\m2_sd_tf_bmp_Runs\phy_1\m2_sd_tf_bmp.bit
  629,635 字节
  SHA256 3A8511593EE12BBA5F79DD1D3C52FCB30FA4A7F3981A40139FAC0E804D8CA209
```

头部：

```
# Anlogic ASCII Bitstream
# Version: Release_2026.1_SP2
# Design name: m2_top
# Architecture: eagle_s20
# Package: EG4S20BG256
# Bitstream CRC: 10000000101100101001001010110011
# USER CODE: 00000000001000000000000000000000
# Transfer CRC: 00000101001110001001100111101010
```

**两次独立的全流程编译**（第二次之前把两个 run 目录清空到只剩 settings.cfg + .prj）：去掉 `#` 头部后的 **1057 行 payload 逐行完全一致**，
`Bitstream CRC` 相同；只有 `# Date:` 不同（所以文件 SHA256 每次都会变，属正常）。

### 11.4 两个 TD 坑（实测，供后续复用）

1. **`set arr_filter true` 在这个 flow 下直接崩**：`TD_FLOW_FAILED: can't read "arr_pwns":
   no such variable`（`phy_1/settings.cfg` 必须保持 `set arr_filter false`）。
   M1 报告里"可以试 arr_filter true 改 hold"的建议在本版本 TD 上**不可用**。
2. **`HDL-8007` 多驱动错误只写进 `td_*.logw`**，`console_ci.log` 与 `run_flow.tcl` 都
   只看到空消息（`TD_FLOW_FAILED: ` 后面什么都没有），容易误判成"随机失败"。
   本次踩了一次：`C_ref`/`C_mode` 同时被两个 always 块驱动。
   **以后 elaborate 失败先看 `td_*.logw` 里的 `ERROR` 行。**
3. `.al`/`.prj` 的 `TD_Version` 必须是数字版号 `6.2.190657`（M0 §7.2）；
   Tcl 路径必须正斜杠（沿用 M1）。

---

## 12. 资源（post-route，`phy_1/m2_sd_tf_bmp_phy.area`）

| 资源 | 用量 | 总量 | 占比 | M1 时 |
|---|---:|---:|---:|---:|
| LUT（`#lut`） | **4,458** | 19,600 | **22.74%** | 1,941 |
| 逻辑单元 LE | 5,355 | — | — | 2,258 |
| 寄存器 FF（`#reg`） | **3,939** | 19,600 | **20.10%** | 1,525 |
| BRAM（bram9k 9 + fifo9k 8） | **17** | 64 | **26.56%** | 16 |
| BRAM32K | 0 | 16 | 0% | 0 |
| DSP | 0 | 29 | 0% | 0 |
| **PLL** | **2** | 4 | **50.00%** | 2 |
| GCLK | 6 | 16 | 37.50% | 5 |
| PAD / IO | 20 / **16** | 188 | 10.64% / 8.51% | 11 / 7 |

层次（le / lut / seq / bram）：

| 模块 | LE | LUT | FF | BRAM |
|---|---:|---:|---:|---:|
| `m2_top` 合计 | 5,355 | 4,458 | 3,939 | 17 |
| ├ `u_fat`（FAT32 FSM） | 2,242 | 1,467 | **1,781** | 0 |
| ├ `u_hdmi_core`（加密 HDMI 核） | 1,390 | 1,036 | 995 | 8 |
| ├ `u_sdram`（Sdram_Control_4Port） | 609 | 528 | 339 | 8 |
| ├ `u_sd`（SD 引擎封装 + 厂商 16 文件） | 349 | 302 | 230 | **1** |
| │ └ `u_sd`（sd_card_control） | 242 | 219 | 167 | 1 |
| ├ `u_bs`（扇区→寄存器） | 278 | 162 | 262 | 0 |
| ├ `u_video_src`（读侧/页控制） | 156 | 134 | 102 | 0 |
| ├ `u_wr`（写页器） | 114 | 98 | 57 | 0 |
| ├ `u_pp`（像素泵） | 95 | 78 | 69 | 0 |
| ├ `u_hdmi_phy`（4×lane） | 44 | 44 | 44 | 0 |
| ├ `u_pll`（宏） | 0 | 0 | 0 | 0 |
| └ `u_sdram_mem`（SDRAM 硬宏） | 0 | 0 | 0 | 0 |

相对 M1：**+2 517 LUT、+2 414 FF、+1 BRAM、+1 GCLK、+9 IO**。BRAM 只多 1 块
（4 Kbit 的 512×8 扇区缓冲占 1 个 bram9k；`sd_card_control` 里未使用的写缓冲 `WR_RAM`
因为 `wea` 恒 0 被综合掉，层次里根本不出现）。FAT 表**没有做缓存**
（每个簇边界重读一次 FAT 扇区），代价是每张图多 ~226 次扇区读（+11% 时间），
换来 0 个额外 BRAM——这是有意的取舍。

---

## 13. 时序（`phy_1/final_timing.rpt`，final / routed，Slow+Fast 角）

```
Setup : WNS  +155 ps   TNS 0 ps   NUM_FEPS 0
Hold  : WNS   +11 ps   TNS 0 ps   NUM_FEPS 0
```

| 时钟 | 约束周期 | 时钟表 fanout | SWNS | HWNS | 实测最短周期 / Fmax |
|---|---:|---:|---:|---:|---:|
| `sdram_clk` 100 MHz | 10.000 ns | 1,677 | **+0.155 ns** | +0.038 ns | 9.845 ns / 101.57 MHz |
| `pixel_clk` 25 MHz | 40.000 ns | 712 | **+31.146 ns** | +0.011 ns | 8.854 ns / 112.94 MHz |
| `clk_50m` 50 MHz | 20.000 ns | 37 | +16.271 ns | +0.198 ns | 3.729 ns / 268.17 MHz |
| `serial_clk` 125 MHz | 8.000 ns | 32 | +4.271 ns | +0.198 ns | 3.729 ns / 268.17 MHz |

* 只有 4 个**域内** path group，**没有跨域 path group**（exclusive 分组生效），
  每个时钟的 `CC-From`/`CC-To` 都是 `no`；
* 全局 WNS = +0.155 ns 来自 100 MHz 域，**关键路径是「1 级 LUT」的连接**：
  `u_sd/u_sd/RD_RAM` 的输出 → `u_bs` 的 `V` 寄存器，逻辑 1 级、数据路径 9.49 ns 中
  **net 占 5.90 ns**。也就是说 100 MHz 域的余量是被**布线/布局**吃掉的，不是逻辑深度。
  同一份 RTL 的重复编译给出**完全相同**的 +0.155 ns（TD 在这个 flow 下是确定性的，
  见 §11.3），但改动 RTL 会让这个数在 0.11…0.35 ns 之间跳（布局变了），
  所以它本质上是「刚好收敛」。
  真要更大余量，最有效的是减少 u_fat 的局部密度（例如 `MAXF=16→8`，见 §15 R2）。
* `pixel_clk` 域余量 31 ns（77%）——M1 的同一条 HDMI 链路完全没被影响。

---

## 14. 上板验证清单

> 前提：`m2_sd_tf_bmp.bit` 用 TD Board Debugger / `bw.exe` 经 JTAG 下载；
> TF 卡是 **FAT32**、根目录里有 `IMG0001.BMP`（用 `tools/make_bmp.py` 生成）。

### 14.1 应该看到什么

| 步骤 | 预期现象 |
|---|---|
| 1. 插卡 + 上电/按 KEY2 | 先黑屏约 **0.5 s**（10 ms 延时 + 卡初始化 + 第一张的 0.39 s 装载），然后出现 `IMG0001.BMP` 的画面 |
| 2. 静态观察 | 方向、颜色与 PC 上看的一致（**不是**上下颠倒、不是红蓝互换）；四周没有 8 px 边框（边框是回退图案才有的） |
| 3. 按 KEY0 | 屏幕保持旧画面约 0.4 s（正在装载），然后**整屏一次性**换成 `IMG0002.BMP`，无撕裂、无中间态 |
| 4. 按 KEY1 | 回到上一张；在编号最小的那张上按 KEY1 → 回绕到编号最大的那张 |
| 5. LED | `led[0]` 常亮（挂载成功）；`led[1]` 每次切图闪一下；`led[2]` 常灭；`led[3]` 每次换页翻转 |
| 6. 拔掉卡再上电 | 约 **2.7 s** 黑屏（卡初始化超时 2.68 s）后显示 **M1 测试图案**（绿边框 + 红/绿渐变 + 蓝底），`led[0]` 灭、`led[2]` 亮 |
| 7. 卡里没有 BMP（只有 txt） | 同样回退图案，`err=3` |
| 8. 卡里放一张非 640×480/非 24 bit 的 BMP | 该图被跳过；如果还有合格的图就显示下一张，全都不合格才回退图案 |

### 14.2 失败判据 → 先查哪里

| 现象 | 最可能原因 | 检查点 |
|---|---|---|
| 全黑，无 HDMI 信号 | PLL 没锁 / 复位没释放 | 量 PLL `extlock`、`S_pll_lock`（同 M0/M1 的第一个怀疑点） |
| 有信号但一直黑 | `page_ok` 永远是 0（装载从未完成） | 量 `u_fat/O_ready_tog` 有没有翻转；量 `u_sd/O_busy`（卡在初始化还是读扇区）；看 `led[1]` 有没有闪 |
| 一直黑 + `led[2]` 亮 | 挂载/读卡失败 | 量 SD_CLK 有没有 400 kHz 的时钟（初始化阶段）；看 `O_err` 的值（ChipWatcher 抓 `u_fat/O_err`）：1=卡、2=FAT、3=无图、4=坏图 |
| 显示旧页但 KEY0 没反应 | 按键引脚/极性 | 量 KEY0(F7) 按下是否为 0；`led[1]` 是否闪（闪说明在装载，按键在装载期间被忽略是**设计行为**） |
| 画面上下颠倒 | 写页行序/`biHeight` 判反 | 检查 BMP 的 `biHeight` 符号（`make_bmp.py` 输出 +480）；`u_wr` 的 `S_bup` |
| 画面左右镜像 / 颜色错（红蓝互换） | BGR→RGB 或位序 | `m2_pix_pump` 的 `{8'h00, I_din, S_b1, S_b0}`；低 24 位是 RGB888 |
| 画面整体横移 N 像素、行首回卷 | 写 FIFO 相位被破坏（LOAD 前没排空） | 重新算 §6.3 的 DRAIN 上界；量 `WR1_LOAD` 与最后一个像素的时间差是否 ≥4096 拍 |
| 每次都是同一张图，KEY0 无效 | 扫描器没动（`S_cur_key` 没更新）或列表只有 1 项 | 量 `u_fat/O_count`（ChipWatcher）；确认卡里有多张图 |
| 图只显示一部分，下半屏黑 | FAT 链提前结束（`err=5`） | 卡是不是用工具重新写过？换一张卡/重新格式化试 |
| 偶发单像素花点 | 100 MHz 域余量只有 0.155 ns + hold 11 ps | 见 §15 R2/R3：先降到 SPI 12.5 MHz（`spi_highfreq=12_500_000`）重编试 |
| SD 卡偶发读错（扇区数据错） | SD 引擎的 50 MHz 分频时钟没有 STA（§15 R1） | 同上：降 SPI 频率到 12.5 MHz |

### 14.3 建议的测量点（ChipWatcher / 临时 LED）

`S_pll_lock`、`S_sdram_ready`、`u_sd/O_busy`、`u_sd/O_err`、`u_fat/O_err[2:0]`、
`u_fat/O_mounted`、`u_fat/O_count`、`u_fat/O_index`、`u_fat/O_ready_tog`、
`u_video_src/S_disp_page`、`u_video_src/S_page_ok`、`u_wr/O_load`（有 LOAD 说明在写页）、
`WR1_FULL`、`S_rd1_empty`/`S_rd2_empty`（正常应恒 0）。

---

## 15. 风险与假设

| # | 假设/风险 | 依据 | 一旦不成立的现象 | 应对 |
|---|---|---|---|---|
| **R1** | **SD 引擎的分频时钟 `spi_clk` 没有时序约束**（TD 里查不到它的 net/pin，`get_pins u_sd/u_sd/SPI_CLK/clk_out` → `USR-6001 No pins matched`，`get_nets *clk_out*` 为空；`create_generated_clock` 一失败还会把整条 `set_clock_groups` 拖失败，所以干脆不写）。该域实际最高 50 MHz | 厂商同一份代码、同一块板、同样 100 MHz 输入在 `02-uart_sd_rw` 例程里跑过 | 卡偶发读错扇区 → 图片局部错色/花块 | 把 `spi_highfreq` 降到 12.5 MHz（`m2_sd_sec` 一个参数，SCLK 12.5 MHz）重编；或按 TP 把该 net 引到顶层 port 再加 SDC |
| **R2** | 100 MHz 域 setup 余量只有 **+0.155 ns**（1.5%），且关键路径是"1 级 LUT + 5.9 ns 布线"——余量由**布局布线**决定 | §13；改 RTL 前后 5 次编译的 WNS 在 0.11…0.35 ns 之间（同一份 RTL 重复编译给出同一数值） | 高低温/批次差异下可能不收敛 | 有效手段：`MAXF=16→8`（u_fat 的数组减半）、或把 u_fat 的状态机拆成两级流水、或把 SD 时钟降到 12.5 MHz。`arr_filter true` **不可用**（§11.4） |
| R3 | Hold WNS 只有 **+11 ps** | 与 M0 (+3 ps)、M1 (+3 ps) 同批路径，`drHoldFix on` 已开 | 上板偶发像素错/数据错 | 同 R2；或降低像素时钟/加重 hold 修复策略 |
| R4 | **"逐行 LOAD 前写 FIFO 必空"** 是靠"每行 640 字 = 5×128 + AE=127 + DRAIN=4096"推出来的，没有上板实测 | §6.3 + 模型 80 项检查（行末残留=0） | 画面横移/行首回卷 | 量 `WR1_LOAD` 与最后像素的间隔；把 DRAIN 加大到 8192 |
| R5 | `WR1_LOAD` 落在突发中间也不会写错（`rWR1_ADDR` 立即更新、在飞突发用锁存的 `mADDR`） | 读 `Sdram_Control_4Port.v` 485-577 行 | 同上 | 同上 |
| R6 | 每张图 **0.39 s 是纯 SPI 时间**，不含卡内读延迟（TAAC 可到几百 µs/次随机读） | 25 MHz × 522 B/扇区 | 实际切图 0.6…1.0 s | 演示时接受；要快就上 CMD18 多扇区读（M3/M5 可选） |
| R7 | 只支持 **FAT32**，且根目录前 16 个 `*.BMP` | §4.1 | 卡是 exFAT/FAT16 → 回退图案 | 用 `make_bmp.py` 的说明格式化卡；或后续加 exFAT/FAT16 |
| R8 | 未读 OCR、未做 CMD58，靠 CMD8/ACMD41 的老流程 | 厂商 `sd_init.v` 原样 | 极少数不兼容卡初始化失败（err=1） | 换卡；或补 CMD58 |
| R9 | 没有卡时黑屏 **2.7 s** 才回退图案 | 初始化超时 2^28 拍 | 用户以为坏了 | 已知行为；可把超时降到 2^27（1.34 s） |
| R10 | **装载期间的按键被忽略**（~0.4 s） | `S_KEY` 只在空闲时看按键边沿 | 快速连按会丢一次 | 演示时慢一点；M3 可加"按键队列" |
| R11 | LED 极性未实测（代码按高有效） | 管脚表只给引脚号 | LED 亮灭相反 | 不影响画面；报告已注明 |
| R12 | 片内 SDRAM 掉电不保、无上板验证 | 同 M1 R2 | — | 同 M1 |
| R13 | 上电 0.5 s 黑屏 + 每次切图 0.4 s 旧画面 | 设计如此（双缓冲只在写完后切页） | — | 可在画面上加"加载中"提示（M3） |

---

## 16. 与 M2 验收要求的逐条对照

| # | 要求 | 结果 | 证据 |
|---|---|---|---|
| 1 | 复制 M1 工程、改工程/顶层名、保留 HDMI 640×480 与页 A/B 地址 | ✅ | `m2_sd_tf_bmp.al` / `m2_top`；`PAGE_A_BASE=0x00000`、`PAGE_B_BASE=0x04B000`、`PAGE_END=0x096000` 与 M1 完全相同 |
| 2 | SD SPI 层：复用 `sd_card_control`（Mode3、400 kHz→25 MHz），封装成"读一个 512B 扇区到内部 buffer" | ✅ | `rtl/m2_sd_sec.v`；16 个厂商文件 SHA256 逐字节相同；`rd_ram_*` 读口直接暴露给上层 |
| 3 | FAT32-lite：MBR→BPB（FAT 起始/扇区大小/簇扇区/根目录簇/FAT 表项大小） | ✅ | §4.2；`S_fat_lba`、`S_data_lba`、`S_spc/log2spc`、`S_fatsz`、`S_root_clus` |
| 4 | 根目录是**簇链**，枚举目录项，跳过 0xE5/LFN，收集 `*.BMP` 短名+起始簇+大小 | ✅ | §4.1/§4.3；模型的"碎片簇链 + LFN + 删除项 + 子目录"场景通过 |
| 5 | 按文件名排序（`IMG0001.BMP` 编号就够） | ✅ | §4.4：串行 min/max 扫描实现"下一张/上一张/第一张"的编号序（不是物理排序，语义等价且更省资源） |
| 6 | 按 FAT 链把簇映射成扇区序列，逐扇区读 | ✅ | §4.2/§5.3；`S_CFAT` 每次簇边界重读 FAT 扇区 |
| 7 | BMP 解析：54 字节头校验（BM/biSize=40/640/480/24bit/comp=0）、自底向上、BGR→RGB | ✅ | §5.1/§5.2；模型场景 1/3 的页内容与源图**逐字节相同** |
| 8 | 写 SDRAM 页 B：32 bit/像素连续写（复用 M1 的 WR 端口思路），**写完整页再切页** | ✅ | `m2_page_wr.v`；`S_DEND` 等 `I_wr_done` 才进 `S_SW0`；模型 307 200 字/480 次 LOAD |
| 9 | KEY0 下一张 / KEY1 上一张，消抖，无卡/无图回退 M1 测试图案 + LED 提示 | ✅ | §7/§8.1/§9；`key_next_tog`/`key_prev_tog` + 10.5 ms 消抖；`S_PAT0` 图案；4 个 LED |
| 10 | 主控状态机 IDLE→SCAN→LOAD→SWAP→IDLE，加载中显示旧页 | ✅ | §8；`disp_page` 只在 SWAP 阶段改 |
| 11 | 写 `tools/make_bmp.py`（Pillow，批量 `IMG%04d.BMP`，打印拷卡说明）+ 离线模型 | ✅ | §9/§10；`make_bmp.py --check` 自校验；模型 80 项检查全通过 |
| 12 | 编译到 `m2_sd_tf_bmp_Runs\phy_1\*.bit`，报告资源与时序 | ✅ | §11/§12/§13；bit 629 635 B，`Design name: m2_top` |

---

## 17. 下一步（M3 衔接）

1. **数码管图号/总数**：`u_fat` 已经输出 `O_index`/`O_count`（本报告 §8.1），
   接 2×74HC595 三线即可；`O_err` 也可以顺带显示。
2. **自动轮播 + 暂停**：在 `S_KEY` 里加一个帧计数器（KEY2 已作复位，可把"暂停"挂在
   长按 KEY0/KEY1 上），复用 `m2_video_src` 的帧起始脉冲。
3. **加载中提示**：M3 可以把 `S_inload` 接到 OSD/边框颜色，解决"0.4 s 没反应"的观感。
4. **提速**（可选）：把 CMD17 换成 CMD18 多扇区连续读，能省掉每扇区 ~26 µs 的命令开销；
   真正的大头是卡内读延迟，提速有限。
5. **上板回归项**（优先级从高到低）：R1（SD 时钟约束）→ R2/R3（100 MHz 余量）→
   R4（LOAD/排空）→ M0 遗留的 `tlast`/串行时钟相位/hold。
