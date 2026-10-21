# M4 : AC208 (EG4S20BG256) — 板载 WM8960 音频输出（I2C 初始化 + I2S 发送 + 1 kHz 正弦测试音）

M4 = **M3 的全部功能**（TF 卡读 BMP → 片内 SDRAM 双缓冲 → HDMI 640×480，
按键切图 / 长按暂停 / 3 s 自动轮播 / 8 位数码管）**+ WM8960 音频**：
上电后 I2C（40 kHz）写 13 条寄存器把 codec 配成 *I2S 从机、48 kHz、16 bit*，
FPGA 做 I2S 主机（BCLK 3.072 MHz / LRCK 48 kHz），DACDAT 上一直送
**1 kHz、−6.02 dBFS 的正弦**。插上耳机就能听到“嘀——”一声。

完整推导、寄存器逐条注释、时序图与上板排查清单见
`docs/research/m4-report.md`。

---

## 1. 一条命令编译

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File E:\fpga-2026\dsh_code\proj\m4_audio\build.ps1
```

输出：`m4_audio_Runs\phy_1\m4_audio.bit`（约 630 KB，`Design name: m4_top`）。
全清编译约 80~90 s；`TD_FLOW_OK` + 退出码 0 才算成功。

重新生成工程文件（`.al` / `.prj` / `settings.cfg`）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\make_proj_files.ps1
```

## 2. 离线验证

```powershell
python sim\gen_sine_rom.py --check     # 正弦表与生成器一致
python sim\model_m4_audio.py -v        # 146 项周期级/位级检查
python sim\model_m4_ctrl.py            # M3 的 75 项交互/数码管检查（逻辑未改）
```

## 3. 端口（26 个 IO）

| 信号 | 引脚 | 说明 |
|---|---|---|
| `clk` | K14 | 50 MHz 板载晶振 |
| `rst_n` | H14 | KEY2，低有效 |
| `key0_n` / `key1_n` | F7 / E7 | KEY0 = 下一张（长按 1 s 暂停），KEY1 = 上一张 |
| `SD_CLK/MOSI/MISO/CS` | M2 / L3 / K6 / R2 | TF 卡（SPI 模式） |
| `led[3:0]` | M12 R16 R15 T15 | led0 挂载、led1 装载中、led2 出错、led3 页 A/B（`DEBUG_LED=1` 时改显示 I2C 初始化结果） |
| `SEG7_SCLK/RCLK/DIO` | T14 / R12 / R14 | 2×74HC595 数码管 |
| `O_tmds_*` | B10 D11 C11 F10 | HDMI（LVDS33_E） |
| **`I2S_MCLK`** | **B8** | 12.288136 MHz（第 3 个 PLL） |
| **`I2S_BCLK`** | **C8** | 3.072034 MHz = MCLK/4 |
| **`I2S_DACLRC`** | **A8** | 48.0005 kHz（低 = 左声道） |
| **`I2S_DACDAT`** | **A7** | I2S 数据 |
| **`I2S_ADCLRC`** | **C7** | 与 DACLRC 同频输出（ADC 未用，但脚不能悬空） |
| **`I2C_SCL` / `I2C_SDA`** | **L16 / M16** | 共用 I2C 总线（codec / 24LC256 / PCF8563），M4 独占 |

> ⚠️ 厂商板测 `IO.adc` 把音频脚写错位（`I2S_DI=C7 / I2S_DO=A8 / I2S_RCLK=A7`）。
> 本工程按**管脚表**接：A8=DACLRC、A7=DACDAT、C7=ADCLRC。

## 4. 时钟

| 时钟 | 频率 | 来源 | 用途 |
|---|---:|---|---|
| `clk_50m` | 50 MHz | 晶振 K14 | 复位同步、I2C 初始化（40 kHz SCL） |
| `pixel_clk` | 25.000 MHz | PLL1 | 光栅 / AXIS / 按键 / 数码管 |
| `serial_clk` | 125.000 MHz | PLL1 | TMDS 串行器 |
| `sdram_clk` | 100.000 MHz | SDRAM 控制器内 PLL2 | SDRAM / SD / FAT32 |
| **`mclk_audio`** | **12.288136 MHz** | **PLL3 (`pll_m4_audio`)** | 正弦发生器 + I2S 发送 |

12.288 MHz 无法由 50 MHz 整数分频精确得到（12.288/50 = 768/3125，3125 = 5⁵），
所以取**连分数最佳逼近 29/118**：VCO = 50×29/2 = **725 MHz**，C0 = 59 →
**12.288136 MHz（+11 ppm）**。详细推导与“不行就改 4 个数”的退路见报告 §4。

## 5. 文件

```
proj/m4_audio/
├── m4_audio.al / IO.adc / timing.sdc / run_flow.tcl / build.ps1 / make_proj_files.ps1
├── rtl/
│   ├── m4_top.v              M4 顶层（M3 + 音频 5 个实例）
│   ├── m4_wm8960_table.v     ★ 13 条寄存器表（每条都有数据手册依据的注释）
│   ├── m4_i2s_bit_shift.v    ★ 位级 I2C（START/8bit/ACK/STOP，40 kHz）
│   ├── m4_i2s_control.v      ★ 一帧 = dev + {reg,data8} + data7:0（3 字节，ACK 检查）
│   ├── m4_i2s_init_dev.v     ★ 表遍历 + 重试 3 次 + 上电 10 ms + 寄存器间延时
│   ├── m4_sine_rom.v         ★ 1/4 波正弦表 256×16（生成文件）
│   ├── m4_sine_tone.v        ★ 32 bit 相位累加器 + 象限镜像 → 1 kHz/48 kHz/−6 dBFS
│   ├── m4_i2s_tx.v           ★ I2S 主机：BCLK=MCLK/4、LRCK=BCLK/64、下降沿换数据
│   ├── m4_byte_seq / m4_pix_pump / m4_page_wr / m4_sd_sec / m4_fat_bmp
│   ├── m4_video_src / m4_seg7 / m4_hc595        （M3 原样，仅改名）
│   ├── sd_spi/ (16) sdram_ctrl_4p/ (8)          （厂商，逐字节未改）
│   └── hdmi_phy_warpper.v / lane_lvds_10_1.v / *.enc.v （厂商，逐字节未改）
├── al_ip/pll_m4_hdmi/        M3 的 PLL（未改）
├── al_ip/pll_m4_audio/       ★ 音频 PLL（VCO 725 MHz → 12.288136 MHz）
├── sim/gen_sine_rom.py       ★ 正弦表生成器
├── sim/model_m4_audio.py     ★ 146 项模型检查
├── sim/model_fat32_bmp.py    M2 的 80 项 FAT32 检查（保留）
└── sim/model_m4_ctrl.py      M3 的 75 项交互检查（保留，逻辑未改）
```

## 6. 音频行为

1. KEY2 释放且两个 PLL 都锁定 → 音频子系统复位释放；
2. 50 MHz 域等 **10 ms**（codec 自身 POR），然后按表写 13 条寄存器（每帧 3 字节，
   每字节都查 ACK；NACK 重试 3 次）；
3. 表里包含 **R25 VREF+VMID → 等 500 ms → R26 输出使能 → R47 混音器 → R5 解除
   静音 → R2/R3 0 dB 音量**，所以上电没有“砰”声；
4. `init_ok = 1` 才放行测试音；任何一条写失败（3 次都 NACK）就**保持 DACDAT=0**，
   宁可不响也不出噪声；
5. 初始化完成后 SCL/SDA 保持空闲高电平（总线释放），RTC/EEPROM 不再被访问。

## 7. 上板

插耳机（绿色 3.5 mm）→ 应听到 **1 kHz 纯音**。没声音时的排查顺序
（I2C ACK → MCLK → 寄存器表 → 音量）与示波器/万用表测法见
`docs/research/m4-report.md` §11。

`m4_top` 有个参数 `DEBUG_LED`（默认 0 = M3 行为）。把 `rtl/m4_top.v` 里
`parameter DEBUG_LED = 0` 改成 `1` 重编译，`led[3]` 就变成
“WM8960 初始化全部 ACK”指示灯（常亮 = 成功），上板首日非常有用。
