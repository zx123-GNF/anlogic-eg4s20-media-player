# TD 2026.1 SP2 + EG4S20BG256 工具链验证报告

- 验证日期：2026-10-21
- 主机：`暗影精灵`（HP OMEN Gaming Laptop 16-ap0xxx，Windows 11 26200，32 逻辑核）
- TD：`TD Release_2026.1_SP2`，Build `6.2.2.200067`，编译于 2026-04-23 16:15:53，安装在 `E:\`
- 测试工程：`02-uart_sd_rw串口读写SD卡\AC201_AL_uart_sd_rw` 的副本（纯 Verilog + 1 个 PLL IP）

## 0. 结论速览

| 问题 | 结论 |
|---|---|
| license 是否生效 | **原始状态没有生效**：`E:\license\` 为空，TD 在 `optimize_rtl` 阶段报 `RUN-8008 ERROR: Cannot find license file E:/license/Anlogic.lic`，流程中止 |
| 能否编译出 .bit | **补装 license 后可以完整编译**，`read_design → opt_rtl → opt_gate → opt_place → opt_route → bitgen` 全部通过，产出 629,632 字节 `.bit` |
| 是否器件不支持 | 不是。license 的 feature 是 `TD`（整个工具链），不按器件收费/限制；EG4S20BG256 可正常布局布线和生成比特流 |
| 有没有免费/试用模式 | 未发现。无 license 时只有 `read_design`（elaborate）能过，之后所有优化/布局布线阶段直接中止，没有降级或试用输出 |
| 怎么修 | 放一个有效的 `Anlogic.lic` 到 `E:\license\Anlogic.lic`（或设 `TD_LICENSE` 指向它）。本次用 YADAN 社区 NODELOCKED license 修复并验证通过，有效期至 **2026-11-22** |
| 命令行怎么跑 | 见第 5 节；**Tcl 路径必须用正斜杠**，且建议用带 `exit` 的 wrapper，否则 `td_commands_prompt.exe` 会停在 `td >` 提示符且失败也返回 0 |
| 耗时 | 本机全流程约 **33 秒**（syn 10.3 s + phy 22.5 s），不是 5–15 分钟 |

---

## 1. 环境与原始状态

### 1.1 安装信息

- 安装根目录：`E:\`（`E:\bin\td.exe`、`E:\bin\td_commands_prompt.exe`、`E:\arch`、`E:\ip`、`E:\pubkey`、`E:\scripts`、`E:\license` 等）
- 注册表：`HKLM\SOFTWARE\WOW6432Node\Anlogic\TD_Release_2026.1_SP2`，`Version=200.067`，`Path=E:\`
- MSI 产品：`TD_Release_2026.1_SP2`，`{2A7C3A75-CAEC-4ADC-85FA-176655E781D7}`，安装日期 2026-10-21
- 安装包仍在：`E:\Anlogic_TD\TD_Release_2026.1_SP2_NL.exe`（2,031,876,408 字节）

> 关于文件名里的 `NL`：常见解释是 node-locked。但本机实测安装完成后 `E:\license` 是**空目录**，TD 首次启动也没有任何联网激活/激活向导，说明这个安装包**不自带可用 license**（也可理解为 No-License 分发包）。不管是哪种解释，处理方式一样：必须单独放 `Anlogic.lic`。

### 1.2 原始 license 状态（关键证据）

| 检查项 | 结果 |
|---|---|
| `E:\license\` | 存在，**0 个文件**；目录创建时间 2026-10-21 09:26:49（正是安装时间） |
| 全盘 `*.lic`（E: 深度 4） | 无 |
| `%APPDATA%`/`%ProgramData%` Anlogic 目录 | 不存在 |
| 安装源目录 `...\Anlogic\TD_Release_2026.1_SP2 200.067\install\5E781D7\` | 已被清理，不存在 |
| `E:\pubkey\` | 有 `anlogic-rsa-008.pubkey`、`anlogic-rsa-009.pubkey` 等，用于本地校验 license 签名 |

### 1.3 流程脚本与例程

- `E:\scripts\DefaultFlow.tcl` **存在**（7,840 字节），与本机 TD 配套。
- `E:\scripts` 里还混着一套 Python 工具（python.exe、jupyter 等），不影响 TD，但说明这个目录不是纯 TD 目录。
- 官方例程的 `run.bat` 内容是作者机器的旧路径：

  ```bat
  E:/Anlogic_TD_6.2.2/bin/td_commands_prompt.exe E:\Anlogic_TD_6.2.2\scripts/DefaultFlow.tcl
  pause
  ```

  本机要改成 `E:\bin\td_commands_prompt.exe`，并且**不要用这个 bat 跑 CI**：末尾的 `pause` 会挂住，第二行的反斜杠还会被 TD 的参数解析吃掉（见 5.5）。

- 测试副本放在纯英文路径：`E:\fpga-2026\dsh_code\proj\td_smoke\`（含 `rtl`、`al_ip`、`uart_sd_rw_Runs\syn_1`、`phy_1`）。原始中文路径下的工程**未做任何修改**。

---

## 2. License 验证（问题 1）

### 2.1 没有 license 时的真实行为

直接跑 syn run（`syn_1`，`start_step=read_design`、`end_step=opt_gate`）：

```text
RUN-1002 : start command "insert_debugger"
RUN-1002 : start command "optimize_rtl"
RUN-1001 : Open license file E:/license/Anlogic.lic
RUN-8008 ERROR: Cannot find license file E:/license/Anlogic.lic

td >
```

同时生成了失败标记文件：

```text
.opt_rtl.begin.f   2026/10/21 12:08:56
.opt_rtl.error.f   2026/10/21 12:08:56   ← 失败
.read_design.end.f 2026/10/21 12:08:56   ← 前面的 read_design 是成功的
```

`read_design` 产出了 `uart_sd_rw_elaborate.db`（657,758 字节），说明：

- **没有 license 也能打开工程、elaborate（读设计/展开 RTL）**；
- 但一进入 `optimize_rtl` 就被 license 挡住；
- 这不是路径问题、不是器件不支持，也不是中文路径问题（副本已在纯英文路径）。

另外注意：**裸调 `td_commands_prompt.exe` 即使流程失败，进程退出码仍是 0**。本次失败的进程 `EXITCODE=0`，只能靠日志或 `.opt_rtl.error.f` 判断。这一点对 CI 很关键（5.4）。

### 2.2 license 检查点

成功编译的日志里，license 一共被打开 4 次：

| Run | 阶段 | 日志行 |
|---|---|---|
| syn_1 | `optimize_rtl` | 第 403 行 `Open license file E:/license/Anlogic.lic` |
| syn_1 | `optimize_gate` | 第 589 行 |
| phy_1 | `place` | 第 60 行 |
| phy_1 | `route` | 第 846 行 |

`read_design`/`elaborate` 不检查 license。所以**不能用“能 elaborate”判断 license 正常**。

### 2.3 有没有免费/试用模式？

没有找到。依据：

- `td.exe`/`run.exe` 里的 license 相关字符串只有严格校验逻辑：`Cannot find license file`、`License expired!`、`Invalid License! #1/#2`、`License file does not support this feature`、`Please contact us to get the target license` 等，没有 trial/demo/grace 分支。
- 二进制里出现的 `trial_route` 是布局布线算法选项（试布线），与 license 无关。
- 无 license 时流程直接 `return -code error` 中止，不会降级成“只能仿真”或“只能综合小器件”。

因此可以认为：**TD 2026.1 没有内置的免费/试用编译模式**；官方 FAQ 说的“自带 6 个月免费 License”，从本机现象看应是指随安装包/申请附带的限期文件，而不是软件内置试用。

> 安路官方 FAQ：“当前 TD 软件一般自带 6 个月的免费的 License，如果没有 License 或过期，可以向安路或者代理商的 Sales、FAE 申请获得。”
> 来源：<https://tech.anlogic.com/Cn/Index/index/tp/1/p/8.html?cate=&tp=1>

### 2.4 license 文件格式与查找顺序

下载到的有效 license（258 字节）内容：

```text
#
# NODELOCKED license for TD, Shanghai Anlogic Info Tech
# Generated on Thu Nov 27 10:52:40 2025
#

FEATURE  TD  Anlogic  2026-11-22  252275e893310f6fdd9ef60074...fa3cbd7ab89c
HOST_ID = ANY
```

要点：

- `FEATURE TD`：授权的是整个 TD 工具链，**没有器件字段**，所以不存在“EG4S20 要单独买 license”的问题。
- `2026-11-22`：到期日。
- `HOST_ID = ANY`：不锁机器（NODELOCKED），任何机器可用。
- 签名由 `E:\pubkey\anlogic-rsa-*.pubkey` 本地校验，**不需要联网、不需要 license server、不需要 root**。

查找来源（实测）：

1. `TD_LICENSE` 环境变量（直接指向 `.lic` 文件）——已验证可用（默认文件缺失时会读取它）；
2. 默认 `<安装目录>\license\Anlogic.lic`，本机即 `E:\license\Anlogic.lic`。

### 2.5 修复后验证

把 license 放到 `E:\license\Anlogic.lic` 后：

```text
RUN-1002 : start command "val_license"
RUN-1001 : Open license file E:/license/Anlogic.lic
RUN-1001 : License validation success!
```

随后 syn、phy 全流程通过（见第 3 节）。license 文件 SHA256：`E6EA3B029238520868D76EE8BFFE8E9D12DEB7CB1C6132ED9CD1CF93E272E14F`。

---

## 3. 完整编译验证（问题 2）

### 3.1 流程与耗时

TD 的标准流程是“两个 run 目录”：

1. `syn_1`：`read_design → opt_rtl → opt_gate`，产出 `uart_sd_rw_gate.db`；
2. `phy_1`：`opt_place → opt_route → bitgen`，从 `../syn_1/uart_sd_rw_gate.db` 导入，产出 `.bit`。

实测（32 线程，wrapper 计时）：

| 阶段 | wall time | 说明 |
|---|---:|---|
| `read_design`（含 elaborate、读 ADC、导出 db） | < 1 s | `.read_design.begin.f` 与 `.end.f` 同一秒 |
| `opt_rtl` | 1.75 s | 日志 `finish command "optimize_rtl" in 1.746536s wall` |
| `opt_gate` | 7.79 s | 日志 `optimize_gate ... 7.788720s wall` |
| **syn_1 进程总计** | **10.3 s** | 含启动/退出开销 |
| `opt_place` | 5.99 s | 日志 `place ... 5.992911s wall` |
| `opt_route` | 15.09 s | 日志 `route ... 15.088121s wall` |
| `bitgen` | < 1 s | 与 route 同一次进程，统计里显示 0 s |
| **phy_1 进程总计** | **22.5 s** | flow 内部统计 20 s |
| **全流程** | **≈ 32.8 s** | 10.3 + 22.5 |

内存峰值：syn 约 170 MB，phy 约 604 MB。布局器用到 32 线程（`Placer runs in 32 thread(s)`）。

整个命令行编译**没有弹出任何 GUI/许可证对话框**，不需要人工点“确定”；测试期间桌面上一直开着一个 `td.exe` GUI 进程（PID 9440），也不影响命令行编译。

### 3.2 输出文件

- 比特流：`E:\fpga-2026\dsh_code\proj\td_smoke\uart_sd_rw_Runs\phy_1\uart_sd_rw.bit`
  - 大小 **629,632 字节**（ASCII bitstream）
  - SHA256：`9AA4067BF986328E6FE5806CA65AD6EA5D625390952188E7DB4DEA66991D55E0`
  - 头部：

    ```text
    # Anlogic ASCII Bitstream
    # Version: Release_2026.1_SP2
    # Design name: top
    # Architecture: eagle_s20
    # Package: EG4S20BG256
    # Date: 2026/10/21 12:16
    # Bitstream CRC: 00111011100100100001101101100000
    # USER CODE: 00000000001001010000000000000000
    # Transfer CRC: 11100100000010001001101010001010
    ```

- 中间文件：`uart_sd_rw_elaborate.db`、`uart_sd_rw_rtl.db`、`uart_sd_rw_gate.db`、`uart_sd_rw_place.db`、`uart_sd_rw_pr.db`，以及 `*.area`、`*.timing`、`*.ts`、`*.qor`、`flow.status`/`route_flow.status`。

### 3.3 资源摘要

来自 `syn_1\uart_sd_rw_gate.area`（`Device: EG4S20BG256`）：

| 资源 | 用量 | 总量 | 占比 |
|---|---:|---:|---:|
| LUT 总数（`#Total_luts`） | 1,053 | — | — |
| LUT 占用（`#lut`，含进位链等） | 1,157 | 19,600 | 5.90% |
| 寄存器（`#reg`） | 381 | 19,600 | 1.94% |
| BRAM9K | 2 | 64 | 3.12% |
| DSP | 0 | 29 | 0.00% |
| PAD/IO | 8 | 188 | 4.26% |
| PLL | 1 | 4 | 25.00% |
| GCLK | 1 | 16 | 6.25% |

物理库口径（`phy_1` 日志）：`1053 luts, 380 seqs, 32 mslices, 20 lslices, 8 pads, 2 brams, 0 dsps`。

### 3.4 时序摘要

`phy_1\route_flow.status` / `uart_sd_rw_phy.ts`：

```text
Timing Mode      : final
Setup            : WNS -2841ps  TNS   -15936ps  NUM_FEPS     8
Hold             : WNS    25ps  TNS        0ps  NUM_FEPS     0
```

- 该例程只有 `io.adc`（管脚约束），**没有 SDC 时钟约束**，布线后还有 `USR-6125 CRITICAL-WARNING: No clock constraint on PLL/clock buffer pin pll_inst/pll_inst.clkc[0]. Please add 'derive_clocks' in sdc.`。所以 WNS 为负**不代表设计真的跑不过**，只说明缺少约束、工具按默认模型算；这份数据只用于和参考结果对照。
- 布局阶段（manhattan）曾显示 `Setup WNS 203ps`，最终 final 模式为 `-2841ps`。

### 3.5 与官方 6.2.2 参考结果的对比（强证据）

例程自带 `uart_sd_rw_Runs\best_result\uart_sd_rw.bit`（6.2.2 生成的参考比特流，629,624 字节）。本次 2026.1 生成的文件比它大 8 字节，差异只在头部：

| 行 | 参考 bit（6.2.2） | 本次 bit（2026.1 SP2） |
|---|---|---|
| Version | `6.2.190657` | `Release_2026.1_SP2` |
| Date | `2026/ 4/22  9: 2` | `2026/10/21 12:16` |

把以 `#` 开头的头部行去掉后，两个文件的 **330 行比特流 payload 逐行完全一致**；`Bitstream CRC`、`USER CODE`、`Transfer CRC` 也完全相同。最终时序 `SWNS -2.841ns / STNS -15.936ns / HWNS 0.025ns` 与参考 `best_result\uart_sd_rw_phy.ts` **逐位一致**。

结论：2026.1 SP2 在这台机器上不仅能出 bit，而且**布局布线结果与厂商 6.2.2 参考结果一致**，不是“能跑但结果不对”。

### 3.6 日志位置

2026.1 不再更新旧版那种 `run.log`，而是在 run 目录下按时间生成：

- `E:\...\syn_1\td_20261021_121525.log`（58,890 字节）
- `E:\...\phy_1\td_20261021_121538.log`（83,374 字节）
- 控制台完整输出（本次保存）：`syn_1\console_ci.log`、`phy_1\console_ci.log`
- 失败时的早期原始日志：`syn_1\console_raw_2026.log`（含 `RUN-8008` 证据）

---

## 4. 怎么修 license（问题 3）

### 4.1 方案 A：社区 license（本次已用，立即可执行）

YADAN（安路 EG4S20 开发板）文档维护了一份可用的 `Anlogic.lic`，**HOST_ID = ANY、NODELOCKED、有效期至 2026-11-22**，在本机 TD 2026.1 SP2 上验证通过。

```powershell
# 1) 下载（GitHub 原始文件，258 字节）
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/CSY-tvgo/YADAN-Docs/main/docs/source/attachments/Anlogic.lic' `
                  -OutFile 'E:\license\Anlogic.lic'

# 2) 确认是 license 文本
Get-Content 'E:\license\Anlogic.lic'    # 应看到 FEATURE TD ... 2026-11-22 和 HOST_ID = ANY

# 3) 校验（不需要编译，1 秒出结果）
E:\bin\td_commands_prompt.exe E:/fpga-2026/dsh_code/proj/td_smoke/td_selftest.tcl
# 期望输出：License validation success! / TD_SELFTEST rc=0
```

镜像地址（内容相同）：

```text
https://gitee.com/verimaker/yadan-board/raw/master/software/license/Anlogic.lic
```

来源页：<http://docs.yadanboard.com/zh-cn/latest/chap8.html>（页面上写明“当前版本可用至 2026-11-22，过期后请来此处重新下载，此处将持续更新”）。

**注意**：这是社区为 YADAN/EG4S20 维护的限期 license，适合学习、比赛、验证；商用/长期项目建议走 4.2 的官方渠道。到期后（2026-11-22）需要重新下载新版或换官方 license。

### 4.2 方案 B：官方申请（长期、合规）

1. 打开安路官网下载页（需要注册/登录账号）：
   - 英文：<https://www.anlogic.com/en/support/tools-downloads>
   - 中文：<https://www.anlogic.com/support/tools-downloads>
2. 进入 **Software Tools → License**（软件工具 → License），下载 `Anlogic.lic` / `license.zip`。官方 license 通常也是 6 个月有效期，过期可再次下载。
3. 或直接联系安路/代理商的 Sales、FAE 申请。2026 竞赛指南给的技术支持渠道：
   - 平台一&二 QQ 群：`1050628457`
   - 平台三&四 QQ 群：`1009335189`
   - 自制平台/竞赛交流群：`1018913567`
4. 把拿到的文件命名为 **`Anlogic.lic`**，放到 **`E:\license\`**（不是工程目录）。

> 本机 `E:\Doc` 里没有申请流程：`TD_User_Guide_V6.2.pdf` 只在错误码表里提到
> `RUN-9992 license 格式非法`、`PHY-8004 没有找到有效的 license`；
> `release_note.pdf`、`SWUG103_Design_Flow_User_Guide.pdf`、`SWUG105_TCL_Command_User_Guide.pdf`
> 全文都没有 license 申请说明。所以只能走官网账号下载或找 FAE/代理。

> 佐证：Sipeed 的 Tang 文档明确写“下载 TD 安装包和 license……将 `Anlogic_20220130.lic` 改名为 `Anlogic.lic` 放到 `<安装目录>\license` 中”。见 <https://en.wiki.sipeed.com/soft/Tang/zh/get_started/install_TD_win.html>。

### 4.3 申请时需要提供什么？

本次拿到的 license 是 `HOST_ID = ANY`，**不需要 MAC/主机信息**。如果安路给的是 node-locked（绑定机器）版本，通常需要提供：

| 项目 | 本机值 |
|---|---|
| 主机名 | `暗影精灵` |
| 有线 MAC | `AC:F4:66:50:96:DC`（Realtek GbE） |
| 无线 MAC | `9C:C7:D3:DC:DE:4E`（MediaTek MT7922） |
| MachineGuid | `0cc404ba-d462-4fc0-bb38-14e337088876` |
| TD 版本 | `TD Release_2026.1_SP2` / Build `6.2.2.200067` |
| 安装路径 | `E:\` |
| 器件 | `EG4S20BG256`（EG4 系列） |

取 MAC 的命令：

```powershell
Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.MACAddress -and $_.PhysicalAdapter } |
    Select-Object Name, MACAddress
```

> 以上主机信息只应发给安路/代理商；如果本仓库要公开，提交前删掉这段。

### 4.4 放到哪、要不要 root/server？

- 放到：`E:\license\Anlogic.lic`（安装根目录下的 `license` 子目录）。
- 不需要管理员权限，也不需要安装服务/守护进程；`E:\license` 对 `Authenticated Users` 有 Modify 权限，普通用户直接写入即可。
- **不需要 license server**，不需要 flexlm，不需要联网校验；TD 用本地 `E:\pubkey\anlogic-rsa-*.pubkey` 验签。
- 申请环节需要能上网（官网注册/登录，或邮件/QQ 找 FAE）；拿到 `.lic` 之后，编译和验签全程离线。
- 文件名必须是 `Anlogic.lic`（默认查找）；不想动安装目录时，可改用环境变量：

  ```powershell
  $env:TD_LICENSE = 'E:/path/to/Anlogic.lic'
  ```

  已验证：把 `E:\license\Anlogic.lic` 移走后，`TD_LICENSE` 指向的文件仍能通过 `val_license`。

### 4.5 到期检查

```powershell
Select-String -Path 'E:\license\Anlogic.lic' -Pattern '^FEATURE'
```

`FEATURE TD ... 2026-11-22 ...` 里的日期就是到期日。到期后 TD 会报 `License expired!`，换新文件即可，不用重装 TD。

---

## 5. 命令行可复现编译（问题 4）

### 5.1 前置条件

- 工程/run 目录必须是**纯英文路径**（无中文、无空格、无括号）。本测试用 `E:\fpga-2026\dsh_code\proj\td_smoke\`。
- run 目录里要有 TD 生成的 `settings.cfg`（`source ./settings.cfg` 是相对当前目录的）。
- `syn_1` 和 `phy_1` 是两个独立 run，必须**分别 cd 进去跑**；`phy_1\settings.cfg` 里的 `set parent ../syn_1` 会去导入 syn 的 `gate.db`。

### 5.2 关键：用 wrapper 控制退出码

裸 `td_commands_prompt.exe script.tcl` 有两个坑：

1. 流程失败（例如 license 缺失）时**退出码仍是 0**；
2. 脚本跑完后它可能不退出，停在 `td > ` 提示符等输入（本次 phy 运行就挂住了），CI 会一直等。

在工程目录放一个 `run_flow.tcl`（本次已创建：`E:\fpga-2026\dsh_code\proj\td_smoke\run_flow.tcl`）：

```tcl
# CI wrapper for Anlogic TD DefaultFlow.
# 从包含 settings.cfg 的 run 目录运行。
set rc [catch { source E:/scripts/DefaultFlow.tcl } err]
if {$rc} {
    puts "TD_FLOW_FAILED: $err"
    exit 1
}
puts "TD_FLOW_OK"
exit 0
```

- 成功：最后一行 `TD_FLOW_OK`，进程退出码 0；
- 失败：`TD_FLOW_FAILED: ...`，进程退出码 1（已用“移走 license”实测：`TD_SELFTEST rc=1`，`exit=1`）。

### 5.3 完整命令（PowerShell）

```powershell
$td   = 'E:\bin\td_commands_prompt.exe'
$flow = 'E:/fpga-2026/dsh_code/proj/td_smoke/run_flow.tcl'   # 注意：正斜杠！
$runs = 'E:\fpga-2026\dsh_code\proj\td_smoke\uart_sd_rw_Runs'

# --- 综合 ---
Push-Location "$runs\syn_1"
& $td $flow *> console_ci.log
$synRc = $LASTEXITCODE
Pop-Location

# --- 布局布线 + bitgen ---
Push-Location "$runs\phy_1"
& $td $flow *> console_ci.log
$phyRc = $LASTEXITCODE
Pop-Location

if ($synRc -ne 0 -or $phyRc -ne 0) {
    throw "TD flow failed: syn=$synRc phy=$phyRc"
}
# 产物：$runs\phy_1\uart_sd_rw.bit
```

cmd.exe 版本：

```bat
cd /d E:\fpga-2026\dsh_code\proj\td_smoke\uart_sd_rw_Runs\syn_1
E:\bin\td_commands_prompt.exe E:/fpga-2026/dsh_code/proj/td_smoke/run_flow.tcl
if errorlevel 1 exit /b 1

cd /d E:\fpga-2026\dsh_code\proj\td_smoke\uart_sd_rw_Runs\phy_1
E:\bin\td_commands_prompt.exe E:/fpga-2026/dsh_code/proj/td_smoke/run_flow.tcl
if errorlevel 1 exit /b 1
```

### 5.4 退出码、日志与判定

| 方式 | 成功 | 失败 |
|---|---|---|
| 裸 exe | 0，但可能停在 `td >` | **0**（不可靠） |
| `run_flow.tcl` wrapper | 0 + `TD_FLOW_OK` | 1 + `TD_FLOW_FAILED` |

建议 CI 双重判定：退出码 + 日志里必须出现 `TD_FLOW_OK`，且不能出现 `RUN-8008 ERROR` / `ERROR` / `.opt_*.error.f`。

日志：

- 控制台：重定向到 `console_ci.log`；
- TD 自己的详细日志：run 目录下 `td_YYYYMMDD_HHMMSS.log`；
- 失败标记：`.opt_rtl.error.f`、`.opt_place.error.f` 等。

### 5.5 坑清单（都实际踩过）

1. **Tcl 路径必须用正斜杠 `/`**
   传 `E:\scripts\DefaultFlow.tcl` 时，TD 的参数解析把反斜杠当转义：
   - `E:\scripts\DefaultFlow.tcl` → `couldn't read file "E:scriptsDefaultFlow.tcl"`
   - `E:\fpga-2026\...\td_selftest.tcl` → `E:pga-2026dsh_codeproj<TAB>d_smoke...`（`\t` 变制表符）

   用 `E:/scripts/DefaultFlow.tcl`、`E:/fpga-2026/.../run_flow.tcl` 即可。从 cmd.exe 里传反斜杠也一样坏，是 TD 自己的问题，不是 PowerShell。

2. **不要用官方例程的 `run.bat`**：里面是 `E:/Anlogic_TD_6.2.2/...` 旧路径，末尾还有 `pause`。

3. **中文路径**：TD 对中文/空格/括号工程路径支持不好（本次直接复制到纯英文的 `td_smoke`，没有拿原件冒险）。主机名是中文（`暗影精灵`）没问题，日志能正常打印。

4. **license 检查在 opt_rtl/opt_gate/place/route**：`read_design` 能过不代表 license 正常。

5. **`run.log` 不再更新**：2026.1 用 `td_*.log`；不要盯着旧文件名。

6. **环境变量 `TD_LICENSE`**：可以直接指向任意 `.lic`，适合 CI 不想改安装目录的场景。路径同样建议用正斜杠。

7. **中断**：在 run 目录放一个 `.stop.f`，DefaultFlow 会在下一个 step 开始时停止。

### 5.6 耗时参考

| 场景 | 耗时 |
|---|---|
| 本工程 syn（read_design→opt_gate） | ≈ 10 s |
| 本工程 phy（place→bitgen） | ≈ 23 s |
| 全流程 | ≈ 33 s |
| license 校验 | < 1 s |

工程规模：约 1,053 LUT、380 FF、2 BRAM。更大的设计（如 board_test、HDMI）会显著更久；本数据只用于判断“命令行能不能跑通”和量级。

---

## 6. 附录

### 6.1 关键日志片段

无 license（失败）：

```text
RUN-1002 : start command "optimize_rtl"
RUN-1001 : Open license file E:/license/Anlogic.lic
RUN-8008 ERROR: Cannot find license file E:/license/Anlogic.lic
```

有 license（成功）：

```text
RUN-1002 : start command "optimize_rtl"
RUN-1001 : Open license file E:/license/Anlogic.lic
RUN-1003 : finish command "optimize_rtl" in  1.746536s wall ...
...
RUN-1002 : start command "bitgen -bit uart_sd_rw.bit"
BIT-1003 : Start to generate bitstream.
BIT-1004 : Generate bits file uart_sd_rw.bit.
...
TD_FLOW_OK
```

license 校验：

```text
RUN-1001 : Open license file E:/license/Anlogic.lic
RUN-1001 : License validation success!
```

### 6.2 本次产生的文件

| 路径 | 说明 |
|---|---|
| `E:\license\Anlogic.lic` | 已安装的有效 license（258 B，至 2026-11-22） |
| `E:\fpga-2026\dsh_code\proj\td_smoke\` | 测试工程副本（英文路径） |
| `...\td_smoke\run_flow.tcl` | CI wrapper（带 exit code） |
| `...\td_smoke\td_selftest.tcl` | license 自检（val_license + exit code） |
| `...\td_smoke\check_lic.tcl` | 校验指定 `.lic` 文件 |
| `...\uart_sd_rw_Runs\syn_1\console_ci.log` | syn 成功日志 |
| `...\uart_sd_rw_Runs\phy_1\console_ci.log` | phy+bitgen 成功日志 |
| `...\uart_sd_rw_Runs\syn_1\console_raw_2026.log` | 无 license 失败证据 |
| `...\uart_sd_rw_Runs\phy_1\uart_sd_rw.bit` | 最终比特流（629,632 B） |

原始工程 `E:\fpga-2026\选题一-EG4S20-HX4S20C官方例程\...\AC201_AL_uart_sd_rw\` 未修改。

### 6.3 参考链接

- 安路官方 FAQ（TD License 获取/是否收费）：<https://tech.anlogic.com/Cn/Index/index/tp/1/p/8.html?cate=&tp=1>
- 安路官方下载（需登录，Software Tools → License）：<https://www.anlogic.com/en/support/tools-downloads>
- YADAN 文档（社区 license，有效期至 2026-11-22）：<http://docs.yadanboard.com/zh-cn/latest/chap8.html>
- Sipeed Tang 文档（license 放置方法）：<https://en.wiki.sipeed.com/soft/Tang/zh/get_started/install_TD_win.html>
- 社区 issue（官方 license 下载流程）：<https://github.com/sipeed/sipeed_wiki/issues/690>
