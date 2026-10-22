# 上板验证指南（AC208 / EG4S20BG256）

> 给板子接线、烧录、看现象、排查用的操作手册。工程代码在 `proj/m*/`，每个里程碑都有独立 .bit。
> 环境：安路 TangDynasty **TD 2026.1 SP2**（装在 `E:\`），license `E:\license\Anlogic.lic`（有效至 2026-11-22）。

## 1. 接线与烧录

1. 板子接 **5V 电源**、**USB 下载线**（板载下载器或 AL-LINK 均可）、**HDMI 显示器**（你那台 1024×600 的就行，640×480 会被显示器放大）。
2. 打开 TD → `File → Open Project` 选对应工程的 `.al`（如 `proj\m0_hdmi\m0_hdmi.al`）。
3. 工具栏点 **下载 / Program Device**，选该工程 `*_Runs\phy_1\*.bit`，下载。
4. 下载完成后**不需要任何操作**：配置一结束 PLL 就锁定并自动释放复位，设计自己开始跑（M0 立即出彩条；M2 起约 0.5 s 出第一张图）。
   按 **KEY2**（H14，复位，低有效）= 重新上电，换了卡/换了图之后按它重读一遍。

> 如果找不到下载按钮：TD 里也可以 `Tools → Download`，或直接用独立的下载工具选 .bit。搞不定就把界面截图发我。

## 2. 各里程碑与期望现象

| 里程碑 | 工程 | bit | 应该看到 | 失败先查 |
|---|---|---|---|---|
| M0 | `proj\m0_hdmi` | `m0_hdmi_Runs\phy_1\m0_hdmi.bit` | 8 条竖彩条，稳定 | 全黑→按 KEY2、查显示器是否认 640×480；雪花→相位 |
| M1 | `proj\m1_sdram_fb` | `m1_sdram_fb_Runs\phy_1\m1_sdram_fb.bit` | 渐变底色 + 每秒移动的竖条 + 页色边框；KEY0 换页 | 花屏/错位→SDRAM FIFO；不动→按键 |
| M2 | `proj\m2_sd_tf_bmp` | `m2_sd_tf_bmp_Runs\phy_1\m2_sd_tf_bmp.bit` | 上电自动读卡，显示编号最小的 BMP；KEY0/KEY1 切图；无卡时黑屏 ~2.7 s 后显示 M1 测试图案 | 黑屏/旧图→TF 卡格式/文件名（见 §3）；`led[0]` 亮才算挂载成功 |
| M3 | `proj\m3_interact` | `m3_interact_Runs\phy_1\m3_interact.bit` | M2 的图 + 数码管显示图号 + 按键切图/轮播 | 数码管乱码→`DIG_REV`；按键无反应→消抖/极性问题 |
| M4 | `proj\m4_audio` | `m4_audio_Runs\phy_1\m4_audio.bit` | M3 全部功能 + 耳机里 1 kHz 测试音 | 见 §5 |

**建议顺序**：M0 → M1 → M2 → M3 → M4，每级确认了再下一级（M0 重编只要 18 秒，好调）。

## 3. TF 卡准备（M2 起）

1. TF 卡用 **FAT32** 格式化（≤32 GB 建议，簇大小默认即可）。
2. 根目录放 **8.3 短文件名** 的 BMP：`IMG0001.BMP`、`IMG0002.BMP`……（**最多 16 张**，大写、不要中文/长文件名，不要放子目录）。
3. 图片规格必须是 **640×480、24-bit 无压缩 BMP**。用仓库里的工具生成：
   ```powershell
   python E:\fpga-2026\dsh_code\tools\make_bmp.py 你的图.png -o IMG0001.BMP
   ```
   （工具会顺手做尺寸转换和 BMP 头，`--check` 可自校验）
4. 把生成的 `IMGnnnn.BMP` 拷到卡根目录，插卡上电。

> **现成的 6 张测试图**已经生成在 `dsh_code\demo\`（色条+十字线、灰阶+RGB 渐变、网格棋盘、RGB 三色块、大号图号 5、文字说明）。直接把 `IMG0001.BMP`~`IMG0006.BMP` 拷到卡根目录就能测 M2/M3/M4。想重新生成或改内容：`python tools\make_demo_images.py`。

## 4. 交互（切图 M2 起；长按暂停 / 自动轮播 / 数码管 M3 起）

| 操作 | 功能 |
|---|---|
| KEY0 短按 | 下一张 |
| KEY0 **长按 ≥1 秒** | 暂停 / 恢复自动轮播（3 秒/张，M3 起） |
| KEY1 | 上一张 |
| KEY2 | 复位 |

> M2 已能切图，但装载期间（约 0.4 s）的按键会被忽略（设计行为），演示时慢一点按。
> M2/M3/M4 的上电读卡流程是同一套 FSM，行为完全一致；M4 只多了 WM8960 初始化与测试音。

数码管显示：左边 2 位 = 图片总数，右边 4 位 = 当前图号（`IMGnnnn` 的十进制）；`Er1`~`Er4` 为错误码（详见 M3 报告），`--` 表示正在挂载/没有卡。

⚠️ 数码管的位序是照厂商代码推的，如果上板发现左右颠倒/乱码，改 `m3_interact` 里 `DIG_REV` 一个参数重编即可。

## 5. 音频（M4）

M4 工程上电后应自动播放 **1 kHz 正弦测试音**，从板载 3.5 mm 绿色耳机口输出（插耳机或接音箱）。

设计要点（详见 `docs/research/m4-report.md`）：
- WM8960 用 **I2C 地址 0x34**（厂商例程写的 0x20 是 ES8388 地址，是错的）；
- MCLK 12.288 MHz 由第 3 个 PLL 产生，FPGA 做 I2S 主机（BCLK 3.072 MHz、LRCK 48 kHz），codec 做从机；
- 初始化 13 条寄存器（含 500 ms VMID 等待、解除静音、最后写音量防爆音）。

排查顺序：
1. I2C 有没有 ACK（建议先把 `m4_top` 的 `DEBUG_LED` 参数改 1，led[3] 直接显示"I2C 全部 ACK"）；
2. MCLK 引脚 B8 有没有 12.288 MHz（示波器）；
3. 耳机座假设是 LOUT1/ROUT1——如果听不到，可能是 LOUT2/ROUT2，把寄存器 R40/R41 写成 0x079 再试；
4. 耳机口是否插对（绿色=耳机，蓝色=Line-in）；
5. 音频 PLL 是 725 MHz VCO（12.288 MHz 无法整数分频），如果 PLL 不锁会一直复位 → 黑屏无图；退路：REFCLK_DIV=1、FBCLK_DIV=20、CLKC0_DIV=81、CPHASE=80（→12.3457 MHz，听感无差别），重编约 90 秒。


## 6. 故障速查

| 现象 | 先怀疑 | 处理 |
|---|---|---|
| 全黑 | PLL 没锁 / 没复位 / 显示器不认 | 按 KEY2；换一台显示器试；量 PLL `extlock`（可引到 LED） |
| 雪花、闪、抖 | TMDS 串行时钟相位只有 39.4°（厂商 720p 用 90°） | 改 `CLKC2_FPHASE`（0~7）扫一轮，每次重编 18 秒 |
| 画面左移/滚屏 | AXIS 对齐 / FIFO | 报我，查 tlast/ready |
| 颜色不对（红蓝反向） | RGB 位序 | 报我，改 `video_gen` 输出顺序 |
| 图片显示成旧图/黑屏 | TF 卡 FAT32 或文件名不符 | 重新格式化、确认 `IMGnnnn.BMP`、≤16 张 |
| 偶发读卡错误 | SD SPI 25 MHz 偏快 | 把 `m2_sd_sec` 的 `spi_highfreq` 降到 12.5 MHz 重编 |
| 数码管乱码/倒序 | 595 位序假设 | 改 `DIG_REV` 参数 |
| 没声音 | I2C 地址 / MCLK / 寄存器表 | 见 §5 |

## 7. 重新编译

每个工程目录下都有一键脚本（全清编译，30~80 秒）：
```powershell
cd E:\fpga-2026\dsh_code\proj\m0_hdmi
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```
