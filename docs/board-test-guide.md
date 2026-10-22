# 上板验证指南（AC208 / EG4S20BG256）

> 给板子接线、烧录、看现象、排查用的操作手册。工程代码在 `proj/m*/`，每个里程碑都有独立 .bit。
> 环境：安路 TangDynasty **TD 2026.1 SP2**（装在 `E:\`），license `E:\license\Anlogic.lic`（有效至 2026-11-22）。

## 1. 接线、烧录（第一次上板按这个顺序做）

### 1.1 硬件怎么接

| 项 | 怎么接 |
|---|---|
| 电源 | AC208 底板 DC 电源座 J3 + 电源开关（SS-13F24）；板上 DC-DC 出 5 V / 3.3 V / 2.5 V / 1.5 V，上电后电源灯亮 |
| 下载器 | **AL-LINK**（USB Type-B 线接电脑 + 10 针排线接底板 JTAG 的 IDC 2×5 座）；排线**红线对 1 脚**（座子方焊盘那一端） |
| HDMI | 底板 HDMI 输出 → 显示器（板上无 DDC/EDID，显示器要能盲锁 640×480@60，1024×600 的也能放大显示） |
| TF 卡 | M2 起需要：FAT32 + 根目录 `IMGnnnn.BMP`（见 §3） |
| 耳机 | M4 需要：3.5 mm 绿色耳机口 |

JTAG 信号（查线/量通断用）：**TCK=C14、TDI=C12、TDO=E14、TMS=A15**。
板子**没有板载下载器**；那个 USB-C（CH340E）只是 UART 串口，不能烧录。

### 1.2 装驱动（只做一次，本机已装好）

AL-LINK 的 USB 驱动是 **Microsoft WHQL 签名**的（`E:\driver\al-link\win10\x64`），Win10/11 **不需要关驱动签名**。
本机已装：设备管理器里是 **Anlogic AL-Link**（`USB\VID_336C&PID_1001`，驱动包 `oem59.inf`，服务 `ANLOCYUSB` Running）。

换电脑/重装系统时，三选一：

1. **脚本（推荐）**：管理员权限运行
   `powershell -NoProfile -ExecutionPolicy Bypass -File E:\fpga-2026\dsh_code\tools\install_al_link_driver.ps1`
   —— 会弹一次 UAC，点「是」；日志在 `tools\al-link-driver-install.log`。
2. 设备管理器 → 带感叹号的 **EZ-USB FX2 / AL-LINK** → 更新驱动程序 → 浏览到 `E:\driver\al-link\win10\x64`。
3. 命令行（管理员）：`pnputil /add-driver E:\driver\al-link\win10\x64\anlocyusb.inf /install`。

装好的判据：设备管理器里是 **Anlogic AL-Link**、无感叹号（代码 28 表示还没装）。
（老款下载线用 `E:\driver\dl-cable\`；Linux 免驱，只需给 USB 设备权限。）
板子那个 USB-C（CH340E）只是 UART 串口，**烧板子不需要它**；只有想用串口调试才需要 CH341SER 驱动。

### 1.3 连接检查（每次开工先做）

1. 板子上电（开关 ON），AL-LINK 插好 USB。
2. 打开下载工具：TD 里 **`Tools → BitWriter`**（或工具栏 BitWriter 按钮），**也可以直接双击 `E:\bin\bw.exe` 独立启动**——不打开工程也能烧。
3. 在「器件/下载器信息栏」点 **Refresh**：`Debug Server` 显示 **AL-LINK**、器件型号读出 **EG4S20BG256**，说明链路通。
4. 读不到就依次查：USB 线/驱动、板子是否上电、10 针排线方向（红线对 1 脚）、JTAG 座是否插偏。
5. 不开 GUI 的等价检查（几秒出结果）：`E:\bin\bw_commands_prompt.exe E:/fpga-2026/dsh_code/tools/bw_probe.tcl`，
   打印 `PRG-1000 : Connect device: 0:EG4S20BG256` 就说明链路通。

### 1.4 下载到 SRAM（调试用，掉电丢失，最常用）

1. 工具栏 **Add** → 选 `.bit`（本仓库的 bit 都在各工程 `*_Runs\phy_1\` 下，不是 best_result），在列表里**选中**它。
2. 下载模式选 **Program SRAM**；TCK 速率默认 **5 MHz**（读不稳就降到 2 MHz / 500 kHz）。
3. 点 **Run**，进度到 100% 即完成。
4. 设计**自动开始运行，不用按键**：M0 立即出彩条；M2 起约 0.5 s 出图。没反应按 KEY2 复位一次。
5. **每次烧完，若屏幕停在 "no signal"，把 HDMI 线拔下来等 2 秒再插回**（或 OSD 摇杆重选 HDMI）。
   这块便携屏在 FPGA 重配置导致 TMDS 中断后**不会自己重新锁上**，必须重插才会亮——已实测确认，
   不是设计问题（同一个 bit 重插前后：前 "no signal"、后正常出图）。
6. 判断"FPGA 配置成功没有"**只能看带 LED 的工程**（M2/M3/M4：`led[3:0]` 有驱动）。
   `m0_hdmi`、`m0_720p` 这两个探测工程**没有 LED 端口**，四灯全灭是正常的，不能当判据。
7. 换下一个里程碑的 bit：重复 1–3 即可（不用断电、不用重开 TD）。

### 1.5 固化到 Flash（演示用，掉电保持）

1. 先看核心板上配置 Flash（**U3**，8 脚 SPI Flash）**是否已贴片**、记下丝印型号（W25Q 系列等）。
2. 同 1.4 选文件，下载模式改 **Program Flash**，点 **Run**（写整片 + 校验，要十几秒到几十秒）。
3. 断电 → 重新上电 → **不接下载线**也应自动跑。
4. 想擦掉：**Erase Flash**（整片擦除），或再 Program Flash 烧别的版本。
5. ⚠️ 固化会覆盖板子出厂例程。官方预编译 bit 有备份，随时能烧回去：
   `...\01-board_test基础自检\AC201_AL_board_test\AC201_AL_board_test_Runs\best_result\AC201_AL_board_test.bit`
6. 如果 U3 是空贴 / 型号不在支持列表：Program Flash 会报读 Flash ID 错误（PRG-9516）。那就放弃固化，
   每次上电用 Program SRAM 烧一次——下载线一直插着，演示也能接受。

### 1.6 下载常见报错

| 报错 | 含义 | 处理 |
|---|---|---|
| `PRG-9505 USB device open error` | 电脑没看到下载器 | 插好 AL-LINK、装驱动、换 USB 口 |
| `PRG-9511 打开下载器失败` | 下载器被占用/连接不稳 | 关掉其它 TD / Debug 会话，重插 |
| `PRG-9525 器件 ID 不在库` | 链路上读不到正确 ID | 板子没上电、排线插反/没插、器件选错 |
| `PRG-9516 读 Flash ID 错误` | Flash 不在位或型号不支持 | 确认 U3 贴片；改用 Program SRAM |
| `GUI-8701 下载位流失败` | 码流/链路问题 | 降 TCK、重插 USB、重启 BitWriter |

> TD 新版把老「Download」工具改名为 **BitWriter**（老文档里还叫 Download）；命令行版是 `E:\bin\bw_commands_prompt.exe`（可脚本化，见 §8）。

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
5. 如果手上是**裸 RGB565 帧**（640×480、2 B/像素、无文件头、正好 614400 B，比如 `image_1_640x480_rgb565.bin`）：
   播放器**不认**这种文件（没有 BMP 头 → 判坏图回退测试图案），先一步转成播放器格式（无损）：
   ```powershell
   python E:\fpga-2026\dsh_code\tools\rgb565_to_bmp.py 目录或文件.bin -o 输出目录
   ```
   默认按小端解释 565 字（高字节在前的文件加 `--big-endian`）；输出的 `IMG0001.BMP`… 直接拷卡。

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

## 8. 命令行烧录（一条命令上板，已在本机实测）

`tools\flash.ps1` 封装了 BitWriter 的 Tcl 接口，不用开 GUI：

```powershell
cd E:\fpga-2026\dsh_code\tools
powershell -NoProfile -ExecutionPolicy Bypass -File .\flash.ps1 -Proj m2_720p   # 按工程名 → 烧 SRAM
powershell -NoProfile -ExecutionPolicy Bypass -File .\flash.ps1 -Bit D:\x.bit   # 指定 bit 文件
#   加 -Spd 2            降 TCK（默认 5 MHz），下载不稳时用
#   加 -Mode program_spi 写 SPI Flash（本板未验证）
```

成功时最后一行是 `OK flashed xxx.bit -> SRAM, 19.0 s`，完整日志在 `tools\flash-last.log`。
实测：629 KB 的 720p 位流、5 MHz TCK，**18.7 s** 烧完（GUI 里同样的活也是这个量级）。

底层原理（`tools\bw_program.tcl`；参数走环境变量 `BW_BIT / BW_MODE / BW_SPD / BW_CABLE`）：

* `E:\bin\bw_commands_prompt.exe <脚本.tcl>` 是个 Tcl shell；**多余的命令行词会被当成更多脚本文件**，所以参数只能用环境变量传；
* `list_cable` → `PRG-1000 : Connect device: 0:EG4S20BG256`（下载器 + 目标器件都通）；
* `read_device_id` → `EG4S20BG256`；
* `download -bit <bit> -mode jtag -spd 5 -cable 0` → 内部依次 `bit_to_vec -chip … -m jtag_burst` → `program -mode svf -p`，
  打印进度条和 `PRG-2014 : Chip validation success: EG4S20BG256`；`-mode jtag` = 下到 SRAM；
* 其它可用模式：`program_spi / verify_spi / erase_spi / x_rdbk / refresh`；
* `-h` 帮助是弹 GUI 对话框、抓不到 stdout；参数语法直接从 exe 里的字符串看。

