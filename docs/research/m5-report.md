# M5 里程碑报告：TF 卡视频 + 声音播放（M5V1 软解码 → 双页 SDRAM → 720p HDMI + HDMI 内嵌音频）

> 赛题：安路赛道第 1 题 / 选题一 · AC208 底板（AC201-EG4S20 + AC601 核心板，EG4S20BG256）
> 工具：Tang Dynasty 2026.1 SP2 · 交付路径：`proj/m5_video`（顶层 `m5_top`）
> 状态：**上板验证通过** —— 插卡上电后，1280×720 HDMI 输出连续播放 320×240@15 fps 视频，
> 声音经 HDMI 内嵌音频（LPCM 2ch / ACR）从显示器自带喇叭播出。

---

## 0. 结论速览

| 项目 | 结果 |
|---|---|
| 视频 | 从 TF 卡 FAT32 根目录读 `VID0.M5V`，软解码 RLE → SDRAM 双页 → HDMI 720p 循环播放（19 s 片源，自动循环） |
| 声音 | 每帧 3200 个 48 kHz 单声道样点 → 异步 FIFO → **HDMI 内嵌音频**（LPCM 24 bit 左对齐 + ACR 包）→ 显示器喇叭出声 |
| 片源 | 320×240 RGB332 RLE，15 fps，286 帧，48 kHz mono，文件 7 443 761 B |
| 资源 | LUT 5654/19600 (28.9%)、REG 4221、BRAM 48/64、DSP 4/29、PLL 3/4 |
| 时序 | SWNS **+0.225 ns**、HWNS **+0.003 ns**（100 MHz SDRAM 域 / 73.333 MHz 像素域 / 12.288 MHz 音频域 / 50 MHz 显示域全正） |
| 交付物 | `proj/m5_video`（RTL + 构建脚本）、`tools/m5_encode.py`（片源编码）、`out/VID0.M5V`（示例片源） |

---

## 1. 系统架构

```
TF 卡 (FAT32, SPI 25MHz)
   │  m5_sd_sec.v      : 扇区读 → 512×8 双口 RAM
   ▼
m5_stream.v           : MBR → BPB → 根目录扫 "VID0.M5V" → 线性扇区流
   │  byte 流 (valid/ready 握手, 100 MHz)
   ├──────────────────────────────────────────────┐
   ▼                                              ▼
m5_vdec.v : M5V1 解码                        (无) 
   │  RLE → 行缓冲 → 2×2 放大                     
   ├── 像素 → SDRAM WR1 连续环 (640×480 页 A/B) 
   │            ▼
   │      m5_video_src720.v : 页交换 + 1280×720 中窗 (320,120)
   │            ▼
   │      加密 HDMI 1.4b 核 (AXIS, 1280×720@59.26) → TMDS → 显示器
   │
   └── 音频样点 (48 kHz mono s16)
              ├── m5_aud_fifo #1 → 12.288 MHz 域 → m5_i2s_tx → WM8960（耳机/喇叭 header）
              └── m5_aud_fifo #2 → 73.333 MHz 域 → HDMI 内嵌音频
```

时钟域：`clk` 50 MHz（I2C / 显示）、`S_sdram_clk` 100 MHz（SD/解码/SDRAM）、
`S_pixel_clk` 73.333 MHz（HDMI）、`S_mclk` 12.288 MHz（I2S）。跨域全部是 2FF 同步 +
Gray 码指针（异步 FIFO）。

---

## 2. 片源格式 M5V1 与编码器

### 2.1 文件头（32 B，大端）

| 偏移 | 类型 | 含义 |
|---|---|---|
| 0 | 4 B | `"M5V1"` |
| 4 | u16 | width = 320 |
| 6 | u16 | height = 240 |
| 8 | u16 | fps = 15 |
| 10 | u16 | bpp（1 = RGB332，2 = RGB565） |
| 12 | u32 | frames = 286 |
| 16 | u16 | audio_rate = 48000 |
| 18 | u16 | audio_ch = 1 |
| 20 | u32 | first_frame 偏移 = 32 |
| 24 | u32 | audio_samples_total = 915200 |
| 28 | u32 | 保留 |

### 2.2 帧块（每帧一个）

```
u32 payload_len | u16 audio_samples(本帧, =3200) | u16 bpp(回读校验=1)
payload_len 字节 RLE 数据（含结束 token 0x0000）
audio_samples*2 字节音频（s16le，小端！）
```

### 2.3 RLE token（16 bit 大端）

| token | 含义 |
|---|---|
| `01xx_xxxx_xxxx_xxxx` | repeat：count = (tok & 0xFFF)+1，后跟 1 字节像素 |
| `10xx_xxxx_xxxx_xxxx` | literal：count = (tok & 0xFFF)+1，后跟 count 字节像素 |
| `0` | 帧结束 |

320×240 = 76 800 像素，典型 payload 17.7~19 KB；每帧源行写两次（2×2 放大）→ 640×480 页。

### 2.4 编码

```powershell
python tools\m5_encode.py <任意视频> out --fps 15 --width 320 --height 240 --bpp 1
# 输出 out\VID0.M5V，拷到 TF 卡根目录
```

音轨由 ffmpeg 抽成 `s16le` 单声道 48 kHz（**注意：小端，见 §4.6**），每帧正好 3200 样点。

---

## 3. 解码器（`rtl/m5_vdec.v`）

状态机（19 态）：

```
V_WAIT → V_HDR_M/5/V/1/R (重同步 "M5V1" + 32 B 文件头)
       → V_FRAME (15 Hz 定时器对齐) → V_FHDR (8 B 帧块头) → V_PEND (算帧尾)
       → V_TOKEN0/1 → V_PARSE → V_REPPIX/V_WRITE → V_EMIT (行内 2× 放大, 写完两行)
       → V_PSKIP (丢弃 payload 余量) → V_AUDIO (定长消费 2*aud_n, 输出样点) → V_DONE
```

要点：

1. **帧边界由长度决定，不由结束符决定**：`S_pend = 帧块头位置 + 8 + payload_len`，
   每消费一字节比对；end token 只作为提前结束信号，提前出现则丢弃到 `S_pend`（`V_PSKIP`）。
   这样即使一次 RLE 误判也不会把错位带到下一帧。
2. **payload_len 合法性检查**（256…65535）失败 → `err=4` 并回到 `V_HDR_M` 重新同步。
3. 音频定长：`2*audio_samples` 字节，样点配对输出 `O_aud_we/O_aud_data`。
4. 每帧 `O_ready_tog/O_ready_page` 通知显示侧交换页 A/B（显示侧只在 vstart 且目标页就绪时交换）。
5. 100 MHz 域时序：32 bit 加法器（`S_pend`）单独占一个状态 `V_PEND`，不与状态解码/握手叠加。

---

## 4. 六个关键 bug（按发现顺序，全部有波形/显示证据）

### 4.1 字节握手：ready 是寄存器输出 → 丢字节

`O_byte_ready` 原来是寄存器，进入新状态的**第一拍**仍为 0，但状态机却按
`if (I_byte_valid)` 就 latch 并前进 → 同一个流字节被当成两个 token 字节用（handshake 没发生），
随后被消费一次 → **每个触发点多丢 1 个流字节**，RLE 从丢字节处开始错位。

证据：7 段显示 `endv`（首次 end token 的字节位置）= 0x0D74=3444，而正常应为 0x4522=17714；
再把解出的帧块头换算回文件偏移，正好落在一个真实帧块头的**前 1 字节**（24113 vs 24114）。

修复：`O_byte_ready` 改成**组合逻辑**，由状态直接解码：

```verilog
wire S_byte_want = (S_st==V_HDR_M) || ... || ((S_st==V_WRITE) && !S_rep);
assign O_byte_ready = S_byte_want;     // 与 FSM 采样 I_byte_valid 同拍有效
```

### 4.2 文件头字段"早一拍"取值 → bpp 误判 → 多吞 1 字节

`V_HDR_R` 在终止字节那一拍做 bpp 比较，但该字节**正在**移入 `S_hdr`（非阻塞赋值），
此刻 `S_hdr` 还是 28 字节，按"29 字节"的偏移取出来是 `0x0F00` → 判非 RGB332 →
走兜底分支多消费 1 字节 → 帧块头从文件 offset 33 开始读（7 段显示 `00450A0C`，应为 `0000450A`）。

修复：字段从**下一拍值** `S_hdr_nx = {S_hdr[247:0], I_byte}` 提取；
同时保留"28 字节兜底"提取做容错（两者都匹配不到才报 `err=1`）。

### 4.3 帧边界只靠 end token → 一次误判全乱

改为 §3 的定长边界（`S_pend`）+ 余量丢弃（`V_PSKIP`）+ 音频定长消费。

### 4.4 100 MHz 时序违例（-0.455 ns）

32 bit 加法 `S_vbyt_nx + S_len_w` 叠在"状态解码 → 握手 → 消费计数"之后，
路径 8 级逻辑 10.175 ns > 10 ns。修复：`S_pend` 计算移到独立状态 `V_PEND`
（操作数都是寄存器），SWNS 回到 +0.225 ns。

### 4.5 HDMI 音频采样脉冲：33 bit 累加器 → 半个周期为高

第一版用 `reg [32:0]` 累加器取 bit32 当 48 kHz 脉冲，实际 bit32 有一半时间为高
→ `I_audio_valid` 变成几十 MHz、ACR 全部算错 → 显示器收到的是无效音频包（满幅噪声）。

修复：**32 bit** 累加器（模 2^32），取加法进位 bit32 = 干净的 1 拍脉冲：

```verilog
wire [32:0] S_aph_nx = {1'b0, S_aph} + 33'd2811250;  // 48000*2^32/73333333
wire        S_aud48  = S_aph_nx[32];                 // 47.9999 kHz, 1 拍
```

### 4.6 音频字节序：s16le 当成大端 → 音乐变满幅噪声

`tools/m5_encode.py` 用 `ffmpeg -f s16le` 抽音轨（**小端**），RTL 却按 `{第一字节, 第二字节}`
拼成大端 → 每个样点高低字节互换。用文件数据验证：小端解释是平滑波形（ZCR 0.21），
大端解释是随机跳变（ZCR 0.46、高频能量 3.2 倍）→ 上板就是"很大声的乱码嘈杂"。

修复：

```verilog
O_aud_data <= {I_byte, S_aud_hi};   // {MSB, LSB} = 小端第一个字节作低字节
```

---

## 5. HDMI 内嵌音频（本里程碑的声音交付路径）

### 5.1 官方核的音频接口

加密核（`rtl/hdmi1.4b_transmitter_core/*.enc.v`）暴露：

```
I_audio_valid, I_audio_left_data[23:0], I_audio_right_data[23:0]
I_acr_valid,   I_acr_cts[19:0],        I_acr_n[19:0]
parameter AUDIO_SAMPLE_RATE = "48K"
```

data island 打包、BCH 校验、保护带插入都在核内部（`audio_sample_packet_2_channel`、
`audio_clock_regeneration_packet`、`BCH_32_24_encode`、`BCH_64_56_encode`），
FPGA 侧只需按 48 kHz 送样点 + 送 ACR 参数 —— 与厂商 `design_top_wrapper.v` 的接法一致。

### 5.2 采样脉冲（像素时钟域）

像素时钟 73.333333 MHz（50 MHz × 22/15），48 kHz 样点间隔 1527.9 个像素时钟：

```
step = round(48000 × 2^32 / 73333333) = 2 811 250   → 47.9999 kHz
```

### 5.3 ACR（`rtl/m5_audio_acr.v`，等价厂商 `audio_arc_calculate.v`）

- 每 48 个样点（=1 ms @48 kHz）发一个 ACR 包；
- `N = 6144`（48 kHz 标准值，44.1k → 6272、32k → 4096）；
- `CTS = 两次 ACR 之间实测的像素时钟数`（≈73 333，20 bit 足够）；
- 接收端恢复 `fs = f_pixel × N / (128 × CTS)`，因此**换分辨率/像素时钟不用改参数**。

### 5.4 数据格式

FPGA 侧样点是 16 bit（s16），按 **24 bit 左对齐** 送：`{s16, 8'h00}`（与厂商
`I2S_receiver` 的 `[63:40]` 取法一致）。左右声道送同一样点（片源是单声道）。

### 5.5 异步 FIFO（`rtl/m5_aud_fifo.v`）

- 写：100 MHz（解码域），每次 `O_aud_we` 写一个样点；burst = 3200 样点/帧。
- 读：像素域每 1 ms 48 个样点（`S_aud48`）；MCLK 域每 LRCK 帧 1 个（`m5_i2s_tx O_tick`）。
- Gray 码指针 + 2FF 同步；深度 8192（I2S）/4096（HDMI），只桥接"一帧 + PLL 漂移"。
- 欠载读 0（静音），溢出丢最新样点；欠载/溢出/写入计数都引到调试页。

---

## 6. 资源与时序（最终 release 构建）

| 项目 | 数值 |
|---|---|
| LUT | 5654 / 19600（28.85%） |
| REG | 4221 / 19600（21.54%） |
| BRAM | 48 / 64（bram9k 40 + fifo9k 8） |
| DSP | 4 / 29 |
| PLL | 3 / 4（SDRAM 100 MHz、HDMI 73.333/366.667 MHz、音频 12.288 MHz） |
| Setup | SWNS **+0.225 ns**，0 violated endpoints |
| Hold | HWNS **+0.003 ns** |

约束见 `timing.sdc`（4 个时钟域 + 跨域 false path/时钟组）。

---

## 7. 上板验证

1. 把 `out/VID0.M5V` 放在 TF 卡根目录（FAT32），插卡上电。
2. 约 2 s 后显示器出现 720p 画面：白桌 + 动漫人物照片 + 上方深蓝布，15 fps 连续播放，
   286 帧（≈19 s）后自动回到第 1 帧循环。
3. 显示器喇叭（SPK 开关拨开）出声，为片源原声；音量与画面同步（音频按帧写入，帧内偏差 < 1 帧）。
4. 板载 7 段：无错误时显示帧序号/图像数布局，出错显示 `E<n>`（n = 错误码）。
5. LED（低有效，亮 = 条件成立）：
   - D1 = TF 卡挂载成功
   - D2 = 出错（streamer 或 decoder）
   - D3 = 正在解码/写帧（播放时闪烁）
   - D4 = HDMI 音频样点在流动

调试通道（无 CH340 时）：7 段显示 4 页调试字（`DEBUG_STREAM=1`）+ 音频调试 LED，
见 `m5_top.v` 参数与 §4 的证据说明；串口状态行 `rtl/m5_dbg_vid.v` 需要 CH340E 线。

---

## 8. 复现流程

```powershell
# 1) 片源
python tools\m5_encode.py <video> out --fps 15 --width 320 --height 240 --bpp 1
#    把 out\VID0.M5V 拷到 TF 卡根目录

# 2) 工程文件 + 构建（建议先删 m5_video_Runs 做干净构建）
cd E:\fpga-2026\dsh_code\proj\m5_video
powershell -NoProfile -ExecutionPolicy Bypass -File .\make_proj_files.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1     # ≈110 s

# 3) JTAG 烧写 SRAM（≈19 s；**不要断电**，SRAM 配置会丢）
cd E:\fpga-2026\dsh_code
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\flash.ps1 -Proj m5_video
```

文件清单由 `proj/m5_video/make_proj_files.ps1` 生成（新增 RTL 必须登记到该脚本的 `$files`）。

---

## 9. 已知问题 / 后续可做

1. **耳机（WM8960/I²S）通路在 M5 调试版上无声**：WM8960 I2C 初始化成功（调试 LED 亮）、
   音频样点也在写入 I2S FIFO，但耳机无声。HDMI 音频路径不受影响（已交付）。
   后续排查方向：耳机插座/耳机本身、WM8960 输出音量与 mixer 寄存器、I²S 数据对齐。
2. **按键交互未接入 M5**（M3 的 KEY0/KEY1 播放控制仍在 M3 工程）：
   可以把 M5 的帧计数/暂停接到按键。
3. 15 fps 源在 60 Hz 屏上是"每 4 刷新换一帧"，后续可做帧率转换或提帧率。
4. 片源码率 ≈ 1.7 Mbit/s 时 SPI 25 MHz 够用；若要更高分辨率/帧率，
   可换 RGB565 + 更低 RLE 压缩或提高 SPI 时钟（卡支持时）。
5. 音频与画面同帧对齐（±1 帧 ≈ 67 ms），若要求严格 AV 同步，可让解码器在帧开始时
   送出该帧音频（提前一帧预缓冲）。

---

## 10. 与 M4 的差异一览

| 项目 | M4 | M5 |
|---|---|---|
| 数据源 | TF 卡 5 张 BMP | TF 卡单个 M5V1 视频文件 |
| 取数路径 | 按需读扇区 + BMP 裁切 | 线性扇区流 + 字节握手（valid/ready） |
| 帧缓冲 | 单页 BMP 直写 | WR1 连续环 + 双页 A/B 交换（15 fps） |
| 声音源 | 1 kHz 正弦测试音 | 片源自带 48 kHz 单声道音轨 |
| 声音出口 | WM8960 → 耳机 | **HDMI 内嵌音频 → 显示器喇叭**（+ 并行的 I²S 通路） |
| 关键新增 | I2C/I2S/正弦 | M5V1 解码、线性流、异步音频 FIFO、ACR |
